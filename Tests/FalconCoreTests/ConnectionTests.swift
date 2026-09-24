import XCTest
@testable import FalconCore

/// How the sync loop keeps its connection: a throttle pauses it for longer each time and nothing
/// connects meanwhile, a dead path is noticed and left, a quiet connection is kept alive or
/// quietly replaced, and a server that wants the owner in a browser is not asked again and again.
final class ConnectionTests: XCTestCase {
    private var harness: EngineHarness?

    override func tearDown() async throws {
        await harness?.finish()
    }

    private func started(_ pacing: SyncPacing, deadlines: IMAPDeadlines = .standard, root: URL? = nil,
                         prepare: (FakeIMAPServer) -> Void = { _ in }) async throws -> EngineHarness {
        let server = try EngineHarness.gmailServer()
        server.add(FakeIMAPServer.message("first"), to: "INBOX")
        prepare(server)
        let h = try await EngineHarness(server: server, root: root, pacing: pacing, deadlines: deadlines)
        harness = h
        return h
    }

    private var quick: SyncPacing {
        var pacing = SyncPacing()
        pacing.fullSyncInterval = 3600
        pacing.minimumReconnectInterval = 0.05
        pacing.maximumReconnectInterval = 0.4
        return pacing
    }

    private let throttle = "* BYE Account exceeded command or bandwidth limits."

    func testEachThrottleIsOnePauseWithNothingAskedMeanwhileAndTheNextIsLonger() async throws {
        var pacing = quick
        pacing.throttlePauses = [1.0, 2.0, 4.0, 8.0]
        let h = try await started(pacing)
        let server = h.server
        await h.syncer.start()
        await assertEventually { server.idlingCount == 1 }
        let logins = server.loginCount
        server.resetCounters()

        let firstAt = Date()
        server.sendToIdling(throttle, close: false)
        await assertEventually { await h.events.pauses.count == 1 }
        let pauses = await h.events.pauses
        let first = try XCTUnwrap(pauses.first)
        XCTAssertEqual(first.timeIntervalSince(firstAt), 1.0, accuracy: 0.3, "the first cool-down")
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(server.loginCount, logins, "no connection is opened during the pause")
        XCTAssertTrue(server.commands.isEmpty, "nothing is asked of the server during the pause: \(server.commands)")

        await assertEventually(within: 3) { server.idlingCount == 1 && server.loginCount == logins + 1 }
        let signIn = try XCTUnwrap(server.exchanges.first { $0.line.contains("AUTHENTICATE") || $0.line.contains("LOGIN") })
        XCTAssertGreaterThanOrEqual(signIn.at.timeIntervalSince(first), -0.05, "it connects again only once the pause is over")

        // A successful connect in between does not start the escalation again.
        let secondAt = Date()
        server.sendToIdling(throttle, close: false)
        await assertEventually { await h.events.pauses.count == 2 }
        let both = await h.events.pauses
        let second = try XCTUnwrap(both.last)
        XCTAssertEqual(second.timeIntervalSince(secondAt), 2.0, accuracy: 0.3, "the second is twice as long")
        let stored = AtomicFile.readJSON(SyncExtras.self, from: h.layout.syncExtrasFile(h.account.id))
        XCTAssertEqual(stored?.imapPauseLevel, 1)
        XCTAssertEqual(SyncPacing.standard.throttlePauses, [1800, 3600, 7200, 14400], "30, 60, 120 and 240 minutes")
    }

    func testAPauseOutlivesARelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("falcon-pause-\(UUID().uuidString)", isDirectory: true)
        let first = try await started(quick, root: root)
        let server = first.server
        await first.syncer.start()
        await assertEventually { server.idlingCount == 1 }
        server.sendToIdling(throttle, close: false)
        await assertEventually { await !first.events.pauses.isEmpty }
        let paused = await first.events.pauses
        let until = try XCTUnwrap(paused.first)
        await first.syncer.stop()
        let logins = server.loginCount
        server.resetCounters()

        let second = try await EngineHarness(server: server, root: root, pacing: quick)
        await second.syncer.start()
        await assertEventually { await !second.events.pauses.isEmpty }
        let again = await second.events.pauses
        let resumed = try XCTUnwrap(again.first)
        XCTAssertEqual(resumed.timeIntervalSince1970, until.timeIntervalSince1970, accuracy: 1)
        await assertEventually { await !second.events.errors.isEmpty }
        let told = await second.events.errors.last ?? ""
        XCTAssertTrue(told.hasPrefix("Gmail asked FalconMail to slow down for owner@example.com."), told)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(server.loginCount, logins, "a relaunch during the pause does not connect")
        XCTAssertTrue(server.commands.isEmpty)
        await second.finish()
    }

    func testADeadPathIsNoticedWithinTheDeadlineAndTheLoopRecovers() async throws {
        var pacing = quick
        pacing.idleRefresh = 0.5
        let deadlines = IMAPDeadlines(connect: 0.5, response: 0.5, idleGrace: 0.5)
        let h = try await started(pacing, deadlines: deadlines)
        let server = h.server
        try await h.syncOnce()
        let message = try await h.message(uid: 1, in: "INBOX")
        await h.syncer.start()
        await assertEventually { server.idlingCount == 1 }

        let lost = Date()
        server.blackHole()
        // A command in flight gives up after the response deadline.
        do {
            _ = try await within(10) { try await h.syncer.body(for: message) }
            XCTFail("nothing answers")
        } catch let failure as MailServiceError {
            XCTAssertEqual(failure.kind, .connectionDropped)
            XCTAssertLessThan(Date().timeIntervalSince(lost), 2.5)
        }
        // The idling connection gives up once its refresh goes unanswered.
        await assertEventually(within: 3) { h.logText().contains("owner@example.com: connectionDropped: no reply within 1 s") }
        XCTAssertLessThan(Date().timeIntervalSince(lost), 60)
        XCTAssertLessThanOrEqual(IMAPDeadlines.standard.response, 60)

        server.blackHole(false)
        await assertEventually(within: 5) { server.idlingCount == 1 }
        await h.settled()
        let health = await h.events.healths.last
        XCTAssertEqual(health, .online)
        let errors = await h.events.errors
        XCTAssertTrue(errors.isEmpty, "a short outage is reconnected quietly: \(errors)")
    }

    func testAConnectionClosedAfterSilenceIsKeptAliveOrQuietlyReplaced() async throws {
        var pacing = quick
        pacing.idleRefresh = 0.3
        let kept = try await started(pacing) { $0.closeAfterSilence(0.8) }
        await kept.syncer.start()
        await assertEventually { kept.server.idlingCount == 1 }
        let logins = kept.server.loginCount
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(kept.server.loginCount, logins, "IDLE begun again before the silence runs out keeps the connection")
        await kept.settled()
        let keptErrors = await kept.events.errors
        XCTAssertTrue(keptErrors.isEmpty)
        await kept.finish()

        pacing.idleRefresh = 5
        let dropped = try await started(pacing) { $0.closeAfterSilence(0.6) }
        await dropped.syncer.start()
        await assertEventually { dropped.server.idlingCount == 1 }
        let before = dropped.server.loginCount
        await assertEventually(within: 3) { dropped.server.loginCount > before && dropped.server.idlingCount == 1 }
        await dropped.settled()
        let errors = await dropped.events.errors
        XCTAssertTrue(errors.isEmpty, "a connection dropped in silence is replaced without a word: \(errors)")
        let healths = await dropped.events.healths
        XCTAssertFalse(healths.contains { if case .offline = $0 { return true }; return false })
    }

    func testAServerWantingTheBrowserIsNotAskedAgainAndAgain() async throws {
        let alert = "Your account is not enabled for IMAP use. Please visit your Gmail settings page and enable your account for IMAP access. (Failure)"
        let h = try await started(quick) { $0.refuseLogins(code: "ALERT", text: alert) }
        let server = h.server
        await h.syncer.start()
        await assertEventually { await h.events.healths.contains { if case .blocked = $0 { return true }; return false } }
        await assertEventually { await !h.events.errors.isEmpty }
        let shown = await h.events.errors.last ?? ""
        XCTAssertEqual(shown, "Google wants you to sign in to owner@example.com in a web browser first. FalconMail will retry after that.")
        try await Task.sleep(nanoseconds: 500_000_000)
        let attempts = server.commands.filter { $0.contains("AUTHENTICATE") || $0.contains(" LOGIN ") }.count
        XCTAssertEqual(attempts, 1, "no reconnect loop")

        server.acceptLogins()
        await h.syncer.requestSync()
        await assertEventually { server.idlingCount == 1 }
        await h.settled()
        let health = await h.events.healths.last
        XCTAssertEqual(health, .online, "asking for mail tries again")
    }

    func testReconnectingAfterAWakeKeepsItsSpacingAndWaitsOutAPause() async throws {
        var pacing = quick
        pacing.minimumReconnectInterval = 0.6
        let h = try await started(pacing)
        let server = h.server
        await h.syncer.start()
        await assertEventually { server.idlingCount == 1 }
        let logins = server.loginCount
        let asked = Date()
        await h.syncer.reconnect(reason: "the Mac woke")
        await assertEventually(within: 3) { server.loginCount == logins + 1 && server.idlingCount == 1 }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(asked), 0.3, "never sooner than the least interval after the last attempt")
        await h.settled()
        let errors = await h.events.errors
        XCTAssertTrue(errors.isEmpty)

        server.sendToIdling(throttle, close: false)
        await assertEventually { await !h.events.pauses.isEmpty }
        let during = server.loginCount
        await h.syncer.reconnect(reason: "the network changed")
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(server.loginCount, during, "no reconnect during a pause Gmail asked for")
    }

    // MARK: The connection limit

    private let tooMany = "Too many simultaneous connections. (Failure)"

    /// A sync loop idling, an op connection opened by one message and INBOX holding `count`
    /// messages in all, all listed.
    private func withBothConnections(_ pacing: SyncPacing, count: Int = 4) async throws -> EngineHarness {
        let h = try await started(pacing) { server in
            for n in 2...count { server.add(FakeIMAPServer.message("m\(n)"), to: "INBOX") }
        }
        try await h.syncOnce()
        await h.syncer.setUndoWindow(0)
        await h.syncer.start()
        await assertEventually { h.server.idlingCount == 1 }
        let first = try await h.syncer.body(for: try await h.message(uid: 1, in: "INBOX"))
        XCTAssertEqual(first, FakeIMAPServer.message("first"))
        return h
    }

    /// The sync connection is dropped and, asking again, told the account has too many.
    private func refuseTheSyncConnection(_ h: EngineHarness) async {
        h.server.greetWithBye(tooMany)
        h.server.sendToIdling("* BYE Session expired", close: true)
        await assertEventually { await h.events.healths.contains { if case .imapPaused = $0 { return true }; return false } }
        await assertEventually { await h.events.errors.contains { $0.hasPrefix("Other apps are using owner@example.com's connections. Retrying in ") } }
    }

    func testAConnectionLimitMetByTheSyncConnectionLeavesTheOpConnectionWorking() async throws {
        var pacing = quick
        pacing.connectionLimitWait = 1.5...1.5
        let h = try await withBothConnections(pacing)
        let server = h.server
        let limited = Date()
        await refuseTheSyncConnection(h)
        let logins = server.loginCount

        // The op connection is still open, and the server still answers on it.
        let second = try await h.syncer.body(for: try await h.message(uid: 2, in: "INBOX"))
        XCTAssertEqual(second, FakeIMAPServer.message("m2"), "a message opens on the connection already open")
        _ = try await h.syncer.archive([try await h.message(uid: 3, in: "INBOX")])
        await assertEventually { server.messages(in: "[Gmail]/All Mail").count == 1 }
        XCTAssertEqual(server.messages(in: "[Gmail]/All Mail").first?.data, FakeIMAPServer.message("m3"), "and an action is carried out")
        _ = try await h.syncer.setFlag(.flagged, on: [try await h.message(uid: 4, in: "INBOX")], enabled: true)
        await assertEventually { server.messages(in: "INBOX").contains { $0.uid == 4 && $0.flags.contains("\\Flagged") } }
        await h.settled()
        let failures = await h.events.actionFailures
        XCTAssertTrue(failures.isEmpty, "\(failures)")
        // A wake closes nothing it could not open again.
        await h.syncer.reconnect(reason: "the Mac woke")
        let fourth = try await h.syncer.body(for: try await h.message(uid: 4, in: "INBOX"))
        XCTAssertEqual(fourth, FakeIMAPServer.message("m4"))
        XCTAssertEqual(server.loginCount, logins, "no new connection meanwhile")

        // The sync connection is opened again only once the limit has passed.
        await assertEventually(within: 4) { server.idlingCount == 1 }
        let signIn = try XCTUnwrap(server.exchanges.last { $0.line.contains(" LOGIN ") || $0.line.contains("AUTHENTICATE") })
        XCTAssertGreaterThanOrEqual(signIn.at.timeIntervalSince(limited), 1.4, "not before the limit passed")
        await h.settled()
        let health = await h.events.healths.last
        XCTAssertEqual(health, .online)
    }

    func testAConnectionLimitMetOpeningTheOpConnectionLeavesTheSyncConnectionAlone() async throws {
        var pacing = quick
        pacing.connectionLimitWait = 1.0...1.0
        let h = try await started(pacing)
        let server = h.server
        try await h.syncOnce()
        await h.syncer.start()
        await assertEventually { server.idlingCount == 1 }
        let message = try await h.message(uid: 1, in: "INBOX")
        let logins = server.loginCount

        server.greetWithBye(tooMany)
        do {
            _ = try await h.syncer.body(for: message)
            XCTFail("the server refused the connection")
        } catch let failure as MailServiceError {
            XCTAssertEqual(failure.kind, .tooManyConnections)
            XCTAssertTrue(failure.sentence.hasPrefix("Other apps are using owner@example.com's connections. Try again after "), failure.sentence)
        }
        await h.settled()
        let health = await h.events.healths.last
        XCTAssertEqual(health, .online, "the account still syncs, so its status does not change")
        let errors = await h.events.errors
        XCTAssertTrue(errors.isEmpty, "nothing is retried for the owner, so nothing says so: \(errors)")

        // New mail still arrives over the sync connection, which was never closed.
        server.deliver(FakeIMAPServer.message("news"), to: "INBOX")
        await assertEventually { ((try? await h.uids(in: "INBOX")) ?? []).count == 2 }
        XCTAssertEqual(server.loginCount, logins)

        // Another open during the limit is refused without asking the server.
        server.resetCounters()
        let connections = server.peakConnections
        do {
            _ = try await h.syncer.body(for: message)
            XCTFail("no new connection yet")
        } catch let failure as MailServiceError {
            XCTAssertEqual(failure.kind, .tooManyConnections)
        }
        XCTAssertEqual(server.peakConnections, connections, "no connection was attempted")
        XCTAssertFalse(server.commands.contains { $0.contains("UID FETCH") })

        try await Task.sleep(nanoseconds: 1_100_000_000)
        let body = try await h.syncer.body(for: message)
        XCTAssertEqual(body, FakeIMAPServer.message("first"), "once the limit has passed a connection is opened again")
    }

    func testAThrottleMetDuringAConnectionLimitIsAThrottle() async throws {
        var pacing = quick
        pacing.connectionLimitWait = 60...60
        let h = try await withBothConnections(pacing)
        let server = h.server
        await refuseTheSyncConnection(h)

        server.refuseNext("UID FETCH", code: "THROTTLED", text: "Account exceeded command or bandwidth limits. (Failure)")
        do {
            _ = try await h.syncer.body(for: try await h.message(uid: 2, in: "INBOX"))
            XCTFail("throttled")
        } catch let failure as MailServiceError {
            XCTAssertEqual(failure.kind, .throttled, "the server's own word, not the connection limit")
            let until = try XCTUnwrap(failure.retryAfter)
            XCTAssertEqual(until.timeIntervalSinceNow, SyncPacing.standard.throttlePauses[0], accuracy: 5, "a throttle's cool-down, not the limit's")
        }
        let stored = try XCTUnwrap(AtomicFile.readJSON(SyncExtras.self, from: h.layout.syncExtrasFile(h.account.id)))
        XCTAssertEqual(stored.imapPauseLevel, 0, "it counts towards the next, longer cool-down")
        XCTAssertNotNil(stored.lastThrottleAt)
        XCTAssertEqual(stored.imapPauseReason, MailServiceError.Kind.throttled.rawValue, "and it is the pause a relaunch keeps")

        server.resetCounters()
        do {
            _ = try await h.syncer.body(for: try await h.message(uid: 3, in: "INBOX"))
            XCTFail("paused")
        } catch let failure as MailServiceError {
            XCTAssertEqual(failure.kind, .throttled)
        }
        XCTAssertTrue(server.commands.isEmpty, "nothing is asked of the server during the pause: \(server.commands)")
    }

    func testAThrottleMetOnTheOpConnectionLeavesTheSyncLoopsReconnectPacingAlone() async throws {
        var pacing = quick
        pacing.throttlePauses = [0.6, 1.2, 2.4, 4.8]
        pacing.minimumReconnectInterval = 0.05
        pacing.maximumReconnectInterval = 10
        let h = try await withBothConnections(pacing)
        let server = h.server
        server.refuseNext("UID FETCH", code: "THROTTLED", text: "Account exceeded command or bandwidth limits. (Failure)")
        server.resetCounters()
        do {
            _ = try await h.syncer.body(for: try await h.message(uid: 2, in: "INBOX"))
            XCTFail("throttled")
        } catch let failure as MailServiceError {
            XCTAssertEqual(failure.kind, .throttled)
        }
        await h.settled()
        let pauses = await h.events.pauses
        let until = try XCTUnwrap(pauses.last)
        // The sync connection went quiet for the pause, and not as a failure of its own: it is
        // opened again as soon as the pause is over, not after a longer step of its backoff.
        let signingIn = { server.exchanges.filter { $0.line.contains(" LOGIN ") || $0.line.contains("AUTHENTICATE") } }
        await assertEventually(within: 3) { server.idlingCount == 1 && !signingIn().isEmpty }
        let again = try XCTUnwrap(signingIn().first)
        XCTAssertGreaterThanOrEqual(again.at.timeIntervalSince(until), -0.05)
        XCTAssertLessThan(again.at.timeIntervalSince(until), 0.5, "no reconnect backoff on top of the pause")
        await h.settled()
        let health = await h.events.healths.last
        XCTAssertEqual(health, .online)
    }

    func testAGoogleSendSyncsOnlySentAndTwice() async throws {
        var pacing = quick
        pacing.sentSyncDelays = [0.2, 0.6]
        let h = try await started(pacing)
        let server = h.server
        await h.syncer.start()
        await assertEventually { server.idlingCount == 1 }
        server.resetCounters()
        let syncer = h.syncer
        let sender = SMTPSender(store: h.store, syncer: { _ in syncer }) { _, _, _, message in
            // Gmail files the copy in Sent Mail itself.
            server.add(message, to: "[Gmail]/Sent Mail")
        }
        let sent = Date()
        let raw = FakeIMAPServer.message("reply", from: "owner@example.com", to: "ana@example.com", date: Date())
        try await sender.send(accountID: h.account.id, from: "owner@example.com", recipients: ["ana@example.com"], message: raw)

        await assertEventually(within: 3) { server.exchanges.filter { $0.line.contains("SELECT \"[Gmail]/Sent Mail\"") }.count == 2 }
        try await Task.sleep(nanoseconds: 300_000_000)
        let selects = server.exchanges.filter { $0.line.contains(" SELECT ") }
        let sentSelects = selects.filter { $0.line.contains("[Gmail]/Sent Mail") }
        XCTAssertEqual(sentSelects.count, 2)
        XCTAssertGreaterThanOrEqual(sentSelects[0].at.timeIntervalSince(sent), 0.15)
        XCTAssertGreaterThanOrEqual(sentSelects[1].at.timeIntervalSince(sent), 0.55)
        XCTAssertTrue(selects.allSatisfy { $0.line.contains("[Gmail]/Sent Mail") || $0.line.contains("\"INBOX\"") },
                      "only Sent is synced, INBOX selected again to idle: \(selects.map(\.line))")
        XCTAssertFalse(server.commands.contains { $0.contains(" LIST ") }, "no pass over every folder")
        let rows = try await h.uids(in: "[Gmail]/Sent Mail")
        XCTAssertEqual(rows.count, 1)
    }
}
