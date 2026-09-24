import XCTest
@testable import FalconCore

/// The sounds as the app plays them, from what the engine says while it syncs against the fake
/// server. Every event goes through `MailSoundGate` in the order it arrived and at the time it
/// arrived, on a clock `scale` times faster than the test's own, the engine's pacing shrunk to
/// match; a message that arrived plays the new message sound as the app's does when the account's
/// notify setting lets it through, and the app's second look at an account that cannot sync
/// comes a minute later on the same clock. Nothing here reaches a real server.
final class EngineSoundTests: XCTestCase {
    private var harness: EngineHarness?

    override func tearDown() async throws {
        await harness?.finish()
    }

    /// One second of the test is this many on the gate's clock.
    private static let scale: TimeInterval = 50

    /// The engine's pacing on the gate's clock: ten seconds between attempts to connect at
    /// least, five minutes at most, two minutes of quiet retries after a dropped connection.
    private var pacing: SyncPacing {
        var p = SyncPacing()
        p.fullSyncInterval = 3600
        p.idleRefresh = 3600
        p.minimumReconnectInterval = 10 / Self.scale
        p.maximumReconnectInterval = 300 / Self.scale
        p.quietReconnectPeriod = 120 / Self.scale
        p.throttlePauses = [150 / Self.scale]
        p.connectionLimitWait = (100 / Self.scale)...(100 / Self.scale)
        p.sentSyncDelays = [5 / Self.scale, 30 / Self.scale]
        return p
    }

    private let throttle = "* BYE Account exceeded command or bandwidth limits."
    private let tooMany = "Too many simultaneous connections. (Failure)"
    private let unavailable = "Temporary System Problem. Try again later. (Failure)"

    /// A synced account idling on INBOX, and the time its clock starts from.
    private func started(_ pacing: SyncPacing? = nil, prepare: (FakeIMAPServer) -> Void = { _ in }) async throws -> (EngineHarness, Date) {
        let clock = Date()
        let server = try EngineHarness.gmailServer()
        server.add(FakeIMAPServer.message("first"), to: "INBOX")
        prepare(server)
        let h = try await EngineHarness(server: server, pacing: pacing ?? self.pacing)
        harness = h
        await h.syncer.start()
        await assertEventually { server.idlingCount == 1 }
        return (h, clock)
    }

    private func fresh(_ tag: String, from: String = "ana@example.com", daysOld: Double = 0) -> Data {
        FakeIMAPServer.message(tag, from: from, date: Date().addingTimeInterval(-daysOld * 24 * 3600))
    }

    private func finishedCount(_ h: EngineHarness) async -> Int {
        await h.events.all.filter { if case .finished = $0 { return true }; return false }.count
    }

    private func checkedCount(_ h: EngineHarness) async -> Int {
        await h.events.all.filter { if case .checked = $0 { return true }; return false }.count
    }

    private func isOffline(_ health: AccountHealth?) -> Bool {
        if case .offline = health { return true }
        return false
    }

    /// Waits `seconds` on the gate's clock.
    private func wait(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds / Self.scale * 1_000_000_000))
    }

    /// The app's side of the sounds, heard afterwards from what the engine said.
    private final class Listener {
        let start: Date
        var gate = MailSoundGate { _ in true }
        private(set) var played: [(sound: MailSoundEvent, at: TimeInterval)] = []
        private var checks: [(accounts: Set<UUID>, at: Date)] = []
        private var timers: [(account: UUID, at: TimeInterval)] = []

        init(start: Date) {
            self.start = start
        }

        var sounds: [MailSoundEvent] { played.map(\.sound) }

        /// The gate's clock at `date`.
        func uptime(_ date: Date) -> TimeInterval {
            date.timeIntervalSince(start) * EngineSoundTests.scale
        }

        /// The owner asked these accounts for new mail at `date`, as Send & Receive does.
        func check(_ accounts: Set<UUID>, at date: Date = Date()) {
            checks.append((accounts, date))
        }

        /// Hears every event in `timed` as AppModel does, and then waits on the gate's clock
        /// until `end` for the second look at an account that cannot sync.
        func hear(_ timed: [(event: SyncEvent, at: Date)], until end: Date = Date()) {
            var asked = checks.sorted { $0.at < $1.at }
            for (event, at) in timed {
                while let first = asked.first, first.at <= at {
                    asked.removeFirst()
                    fireTimers(upTo: uptime(first.at))
                    gate.manualCheckStarted(accounts: first.accounts, at: start.addingTimeInterval(uptime(first.at)))
                }
                let now = uptime(at)
                fireTimers(upTo: now)
                if case .newMessages = event {
                    note(gate.newMailArrived(), at: now)
                } else {
                    note(gate.hear(event, uptime: now, now: start.addingTimeInterval(now)), at: now)
                }
                if case .health(let account, let health) = event, health.isFailing {
                    timers.append((account, now + MailSoundGate.lastingFailure + 1))
                }
            }
            for first in asked { gate.manualCheckStarted(accounts: first.accounts, at: start.addingTimeInterval(uptime(first.at))) }
            fireTimers(upTo: uptime(end))
        }

        private func fireTimers(upTo now: TimeInterval) {
            timers.sort { $0.at < $1.at }
            while let first = timers.first, first.at <= now {
                timers.removeFirst()
                note(gate.failureLasted(first.account, uptime: first.at), at: first.at)
            }
        }

        private func note(_ sound: MailSoundEvent?, at: TimeInterval) {
            if let sound { played.append((sound, at)) }
        }
    }

    // MARK: - (a) Mailbox sync error follows the engine's account health

    func testAQuietReconnectAfterTheIdleDropNeverSounds() async throws {
        // Something between FalconMail and the server closes a quiet IDLE, here after 25
        // seconds; the engine connects again at once and finishes a pass each time.
        let (h, clock) = try await started { $0.closeAfterSilence(25 / Self.scale) }
        let logins = h.server.loginCount
        await assertEventually(within: 15) { h.server.loginCount >= logins + 5 && h.server.idlingCount == 1 }
        await h.settled()

        let healths = await h.events.healths
        XCTAssertGreaterThanOrEqual(healths.filter { $0 == .connecting }.count, 4, "the gate heard each drop: \(healths)")
        XCTAssertFalse(healths.contains { $0.isFailing }, "each was retried quietly: \(healths)")
        let listener = Listener(start: clock)
        listener.hear(await h.events.timed, until: Date().addingTimeInterval(2 * MailSoundGate.lastingFailure / Self.scale))
        XCTAssertGreaterThan(listener.uptime(Date()), 2 * MailSoundGate.lastingFailure, "the drops went on for minutes")
        XCTAssertEqual(listener.sounds, [])
    }

    func testAPlannedThrottlePauseNeverSounds() async throws {
        let (h, clock) = try await started()
        let before = await finishedCount(h)
        h.server.sendToIdling(throttle, close: false)
        await assertEventually { await !h.events.pauses.isEmpty }
        // The first connection after the pause of 150 seconds meets the throttle again, so a
        // second pause follows the first with no pass between; then a pass finishes.
        h.server.greetWithBye(String(throttle.dropFirst("* BYE ".count)))
        await assertEventually(within: 10) { await h.events.pauses.count == 2 }
        await assertEventually(within: 10) { await self.finishedCount(h) > before && h.server.idlingCount == 1 }
        await h.settled()

        let told = await h.events.errors.filter { $0.hasPrefix("Gmail asked FalconMail to slow down for owner@example.com.") }
        XCTAssertEqual(told.count, 2, "each pause is told")
        let listener = Listener(start: clock)
        listener.hear(await h.events.timed, until: Date().addingTimeInterval(2 * MailSoundGate.lastingFailure / Self.scale))
        XCTAssertEqual(listener.sounds, [])
    }

    func testAConnectionLimitPauseNeverSounds() async throws {
        let (h, clock) = try await started()
        let before = await finishedCount(h)
        // The idle connection is dropped and the server, asked again, allows no more.
        h.server.greetWithBye(tooMany)
        h.server.sendToIdling("* BYE Session expired", close: true)
        await assertEventually { await !h.events.pauses.isEmpty }
        // After the wait of 100 seconds the server still allows none, and then it does.
        h.server.greetWithBye(tooMany)
        await assertEventually(within: 10) { await h.events.pauses.count == 2 }
        await assertEventually(within: 10) { await self.finishedCount(h) > before && h.server.idlingCount == 1 }
        await h.settled()

        let told = await h.events.errors.filter { $0.hasPrefix("Other apps are using owner@example.com's connections.") }
        XCTAssertEqual(told.count, 2, "each wait is told")
        let listener = Listener(start: clock)
        listener.hear(await h.events.timed, until: Date().addingTimeInterval(2 * MailSoundGate.lastingFailure / Self.scale))
        XCTAssertEqual(listener.sounds, [], "the waits, over three minutes in all, are kept on purpose")
    }

    /// The server turns every sign-in down as temporarily unavailable, so the account goes
    /// offline at the first failure, until `recover` lets it in and asks for mail.
    private func outage(_ h: EngineHarness, lasting seconds: TimeInterval) async throws {
        let before = await finishedCount(h)
        h.server.refuseLogins(code: "UNAVAILABLE", text: unavailable)
        h.server.sendToIdling("* BYE Session expired", close: true)
        await assertEventually { self.isOffline(await h.events.healths.last) }
        try await wait(seconds)
        h.server.acceptLogins()
        await h.syncer.requestSync()
        await assertEventually(within: 10) { await self.finishedCount(h) > before && h.server.idlingCount == 1 }
    }

    func testASyncFailingForAMinuteSoundsOnceAnEpisode() async throws {
        let (h, clock) = try await started()
        // Over within half a minute: quiet.
        try await outage(h, lasting: 10)
        await h.settled()
        let short = Listener(start: clock)
        short.hear(await h.events.timed, until: Date().addingTimeInterval(2 * MailSoundGate.lastingFailure / Self.scale))
        XCTAssertEqual(short.sounds, [], "an outage over within the minute is not heard")

        // Two outages of well over a minute, a finished pass between them: one sound each.
        let firstLong = Date()
        try await outage(h, lasting: 150)
        let secondLong = Date()
        try await outage(h, lasting: 150)
        await h.settled()

        let errors = await h.events.errors
        XCTAssertTrue(errors.contains("Gmail had a temporary problem. Retrying."), "\(errors)")
        let listener = Listener(start: clock)
        listener.hear(await h.events.timed, until: Date().addingTimeInterval(2 * MailSoundGate.lastingFailure / Self.scale))
        XCTAssertEqual(listener.sounds, [.syncError, .syncError])
        let at = listener.played.map(\.at)
        XCTAssertEqual(at.count, 2)
        if at.count == 2 {
            XCTAssertGreaterThanOrEqual(at[0], listener.uptime(firstLong) + MailSoundGate.lastingFailure, "only once the failure lasted a minute")
            XCTAssertLessThan(at[0], listener.uptime(secondLong), "and within the first episode")
            XCTAssertGreaterThanOrEqual(at[1], listener.uptime(secondLong) + MailSoundGate.lastingFailure)
        }
    }

    func testAnAccountToSignInAgainSoundsOnceItHasWaitedAMinute() async throws {
        let clock = Date()
        let server = try EngineHarness.gmailServer()
        server.refuseLogins()
        let h = try await EngineHarness(server: server, pacing: pacing)
        harness = h
        await h.syncer.start()
        await assertEventually { await h.events.healths.last == .needsSignIn }
        // The engine says so once and waits for the owner: nothing more comes.
        try await wait(30)
        await h.settled()
        let timed = await h.events.timed
        let told = try XCTUnwrap(timed.last { if case .health(_, .needsSignIn) = $0.event { return true }; return false }?.at)

        let early = Listener(start: clock)
        early.hear(timed, until: told.addingTimeInterval(50 / Self.scale))
        XCTAssertEqual(early.sounds, [], "not before it has lasted a minute")
        let later = Listener(start: clock)
        later.hear(timed, until: told.addingTimeInterval(600 / Self.scale))
        XCTAssertEqual(later.sounds, [.syncError], "once, a minute on")
    }

    func testASyncWhosePassesAreAllCutPartOfTheWaySoundsOnceAnEpisode() async throws {
        let (h, clock) = try await started()
        let before = await finishedCount(h)
        let logins = h.server.loginCount
        // Each sign-in works, and each pass loses its connection at its first SELECT, as when
        // something on the way drops the connection at the same reply every time.
        h.server.cutEveryAfter("SELECT")
        let cut = Date()
        await h.syncer.requestSync()
        try await wait(400)
        let finishedWhileCut = await finishedCount(h)
        h.server.cutEveryAfter(nil)
        await h.syncer.requestSync()
        await assertEventually(within: 10) { await self.finishedCount(h) > before && h.server.idlingCount == 1 }
        await h.settled()

        XCTAssertEqual(finishedWhileCut, before, "no pass finished while every one was cut")
        XCTAssertGreaterThanOrEqual(h.server.loginCount, logins + 4, "each attempt signed in")
        let healths = await h.events.healths
        XCTAssertTrue(healths.contains { self.isOffline($0) }, "said to be offline once the quiet retries were over: \(healths)")
        let listener = Listener(start: clock)
        listener.hear(await h.events.timed)
        XCTAssertEqual(listener.sounds, [.syncError], "once, however many passes were cut")
        if let at = listener.played.first?.at {
            XCTAssertGreaterThanOrEqual(at, listener.uptime(cut) + MailSoundGate.lastingFailure, "only once it had lasted a minute")
        }
    }

    func testAFailureJustAfterAConnectionLimitWaitMustLastAMinuteOfItsOwn() async throws {
        let (h, clock) = try await started()
        let before = await finishedCount(h)
        // The idle connection is dropped and the server, asked again, allows no more.
        h.server.greetWithBye(tooMany)
        h.server.sendToIdling("* BYE Session expired", close: true)
        await assertEventually { await !h.events.pauses.isEmpty }
        // After the wait of 100 seconds, one sign-in is turned down; the next gets in.
        h.server.refuseLogins(code: "UNAVAILABLE", text: unavailable)
        await assertEventually(within: 10) { self.isOffline(await h.events.healths.last) }
        h.server.acceptLogins()
        await assertEventually(within: 10) { await self.finishedCount(h) > before && h.server.idlingCount == 1 }
        await h.settled()

        let timed = await h.events.timed
        let paused = try XCTUnwrap(timed.first { if case .health(_, .imapPaused) = $0.event { return true }; return false }?.at)
        let since = timed.compactMap { item -> Date? in if case .health(_, .offline(let since)) = item.event { return since }; return nil }
        XCTAssertEqual(since.count, 1)
        XCTAssertTrue(since.allSatisfy { $0 > paused }, "offline from the failure after the wait, not from the drop before it")
        let listener = Listener(start: clock)
        listener.hear(timed, until: Date().addingTimeInterval(2 * MailSoundGate.lastingFailure / Self.scale))
        XCTAssertEqual(listener.sounds, [], "the drop and the wait, well over a minute, count towards no failure")
    }

    func testAConnectionDroppedJustAfterAThrottlePauseIsRetriedQuietly() async throws {
        let (h, clock) = try await started()
        let before = await finishedCount(h)
        // The idle connection is dropped and the server throttles the next at its greeting.
        h.server.greetWithBye(String(throttle.dropFirst("* BYE ".count)))
        h.server.sendToIdling("* BYE Session expired", close: true)
        await assertEventually { await !h.events.pauses.isEmpty }
        // The first connection after the pause of 150 seconds is dropped at once; the next gets in.
        h.server.greetWithBye("Session expired")
        await assertEventually(within: 10) { await self.finishedCount(h) > before && h.server.idlingCount == 1 }
        await h.settled()

        let healths = await h.events.healths
        XCTAssertFalse(healths.contains { $0.isFailing }, "the drop after the pause was a quiet retry of its own: \(healths)")
        let listener = Listener(start: clock)
        listener.hear(await h.events.timed, until: Date().addingTimeInterval(2 * MailSoundGate.lastingFailure / Self.scale))
        XCTAssertEqual(listener.sounds, [])
    }

    func testARuleThatFailsInsideAPassNeverSounds() async throws {
        let (h, clock) = try await started()
        try await h.rules.save([RuleDefinition(name: "Flag news", conditions: [RuleCondition(field: .subject, op: .contains, value: "Message")],
                                               actions: [RuleAction(kind: .flag)])])
        // Three messages half a minute apart, the rule refused on each.
        for n in 1...3 {
            // The fake tells only a connection in IDLE of what arrives.
            await assertEventually { h.server.idlingCount == 1 }
            h.server.refuseNext("UID STORE", code: nil, text: "Could not store flags (Failure)")
            let before = await h.events.announced.count
            h.server.deliver(fresh("news-\(n)"), to: "INBOX")
            await assertEventually { await h.events.announced.count == before + 1 }
            try await wait(30)
        }
        await h.settled()

        let problems = await h.events.all.filter { if case .problem = $0 { return true }; return false }
        XCTAssertEqual(problems.count, 3, "each refusal is told as a problem inside the pass")
        let errors = await h.events.errors
        XCTAssertEqual(errors, [], "and none as a failed sync")
        let listener = Listener(start: clock)
        listener.hear(await h.events.timed, until: Date().addingTimeInterval(2 * MailSoundGate.lastingFailure / Self.scale))
        XCTAssertEqual(listener.sounds, [.newMessage, .newMessage, .newMessage])
    }

    // MARK: - (b) The new message sound follows the engine's announcements

    func testTheNewMessageSoundSkipsYourOwnMailAndOldMail() async throws {
        let (h, clock) = try await started()
        // Both are on the server before the idling connection hears of the second, so one
        // pass of INBOX brings them together.
        h.server.add(fresh("mine", from: "owner@example.com"), to: "INBOX")
        h.server.deliver(fresh("imported", from: "bob@example.com", daysOld: 3), to: "INBOX")
        await assertEventually { ((try? await h.uids(in: "INBOX")) ?? []).count == 3 }
        // The fake tells only a connection in IDLE of what arrives.
        await assertEventually { h.server.idlingCount == 1 }
        await h.settled()
        let quiet = Listener(start: clock)
        quiet.hear(await h.events.timed)
        XCTAssertEqual(quiet.sounds, [], "neither your own message nor one dated days ago is news")
        let none = await h.events.announced
        XCTAssertEqual(none.map(\.messageID), [], "and no banner is asked for")

        h.server.deliver(fresh("hello"), to: "INBOX")
        await assertEventually { await !h.events.announced.isEmpty }
        await h.settled()
        let announced = await h.events.announced
        XCTAssertEqual(announced.map(\.messageID), ["<hello@example.com>"])
        let listener = Listener(start: clock)
        listener.hear(await h.events.timed)
        XCTAssertEqual(listener.sounds, [.newMessage])
    }

    func testACheckThatFindsOnlyYourOwnOrOldMailPlaysNeitherSound() async throws {
        let (h, clock) = try await started()
        // Stored on the server without a word to the idling connection, as another program's
        // copy to the owner or an import would be.
        h.server.add(fresh("mine", from: "owner@example.com"), to: "INBOX")
        h.server.add(fresh("imported", from: "bob@example.com", daysOld: 3), to: "INBOX")
        let listener = Listener(start: clock)
        listener.check([h.account.id])
        await h.syncer.requestSync(check: true)
        await assertEventually { await self.checkedCount(h) == 1 }
        await h.settled()

        let found = await h.events.all.compactMap { if case .checked(_, let found) = $0 { return found }; return nil }
        XCTAssertEqual(found, [true], "mail did arrive")
        listener.hear(await h.events.timed)
        XCTAssertEqual(listener.sounds, [], "so No new messages would be wrong, and none of it is news")
    }

    func testMailThatArrivesWhileSentIsSyncedOnItsOwnIsFetchedBeforeIdlingAgain() async throws {
        let (h, clock) = try await started()
        // Sent is brought up to date on its own, as after a send, and while it is selected a
        // reply reaches INBOX, of which the server tells no connection.
        h.server.stallNext("SELECT", seconds: 0.4)
        await h.syncer.requestSync(role: .sent)
        await assertEventually { h.server.commands.last?.contains("SELECT \"[Gmail]/Sent Mail\"") == true }
        h.server.add(fresh("reply"), to: "INBOX")
        await assertEventually(within: 3) { await h.events.announced.count == 1 }
        await h.settled()

        let announced = await h.events.announced
        XCTAssertEqual(announced.map(\.messageID), ["<reply@example.com>"], "at once, not with the next whole pass an hour on")
        let listener = Listener(start: clock)
        listener.hear(await h.events.timed)
        XCTAssertEqual(listener.sounds, [.newMessage])
    }

    func testMailThatArrivesWhileAPassIsOnAnotherFolderIsFetchedBeforeIdlingAgain() async throws {
        let (h, _) = try await started()
        // A whole pass has done INBOX and is on the next folder when the mail arrives.
        h.server.stallNext("SELECT", seconds: 0)
        h.server.stallNext("SELECT", seconds: 0.4)
        await h.syncer.requestSync()
        await assertEventually { h.server.commands.filter { $0.contains("SELECT") }.count >= 1
            && h.server.commands.last?.contains("SELECT") == true && h.server.commands.last?.contains("INBOX") == false }
        h.server.add(fresh("late"), to: "INBOX")
        await assertEventually(within: 3) { await h.events.announced.count == 1 }
        await h.settled()

        let announced = await h.events.announced
        XCTAssertEqual(announced.map(\.messageID), ["<late@example.com>"])
        let stored = try await h.uids(in: "INBOX")
        XCTAssertEqual(stored.count, 2)
    }

    // MARK: - (c) No new messages with IDLE, new-mail-only passes and folders synced on their own

    func testACheckThatFindsNothingSaysSoWithoutWaitingOutIdle() async throws {
        let (h, clock) = try await started()
        let asked = Date()
        let listener = Listener(start: clock)
        listener.check([h.account.id], at: asked)
        await h.syncer.requestSync(check: true)
        await assertEventually(within: 3) { await self.checkedCount(h) == 1 }
        XCTAssertLessThan(Date().timeIntervalSince(asked), 3, "IDLE, an hour long here, was ended for it")
        await h.settled()
        listener.hear(await h.events.timed)
        XCTAssertEqual(listener.sounds, [.noNewMessages])
    }

    func testACheckAskedDuringAPassIsAnsweredByThePassAfterIt() async throws {
        let (h, clock) = try await started()
        let listener = Listener(start: clock)
        h.server.stallNext("LIST", seconds: 0.5)
        await h.syncer.requestSync()
        await assertEventually { h.server.commands.last?.contains("LIST") == true }
        let asked = Date()
        listener.check([h.account.id], at: asked)
        await h.syncer.requestSync(check: true)
        await assertEventually(within: 3) { await self.checkedCount(h) == 1 }
        XCTAssertLessThan(Date().timeIntervalSince(asked), 3, "the pass after it began at once, not after an IDLE")
        await h.settled()

        let all = await h.events.all
        let started = all.indices.filter { if case .started = all[$0] { return true }; return false }
        let checked = try XCTUnwrap(all.firstIndex { if case .checked = $0 { return true }; return false })
        XCTAssertGreaterThanOrEqual(started.count, 3)
        XCTAssertGreaterThan(checked, started[started.count - 1], "the pass under way when it was asked does not answer it")
        listener.hear(await h.events.timed)
        XCTAssertEqual(listener.sounds, [.noNewMessages])
    }

    func testMailAnIdleWakeBroughtDoesNotCountForALaterCheck() async throws {
        let (h, clock) = try await started()
        let listener = Listener(start: clock)
        h.server.resetCounters()
        h.server.deliver(fresh("woke"), to: "INBOX")
        await assertEventually { await h.events.announced.count == 1 }
        let commands = h.server.commands.joined(separator: "\n")
        XCTAssertFalse(commands.contains("LIST"), "IDLE brought it in a pass of INBOX alone:\n\(commands)")

        listener.check([h.account.id])
        await h.syncer.requestSync(check: true)
        await assertEventually { await self.checkedCount(h) == 1 }

        // Mail the idling connection was not told of is found by the check itself.
        h.server.add(fresh("unannounced"), to: "INBOX")
        listener.check([h.account.id])
        await h.syncer.requestSync(check: true)
        await assertEventually { await self.checkedCount(h) == 2 }
        await h.settled()

        listener.hear(await h.events.timed)
        XCTAssertEqual(listener.sounds, [.newMessage, .noNewMessages, .newMessage])
    }

    func testTheSentSyncsAfterASendNeitherAnswerNorConfuseACheck() async throws {
        let (h, clock) = try await started()
        let listener = Listener(start: clock)
        let server = h.server
        let sentSelects: @Sendable () -> Int = { server.commands.filter { $0.contains("SELECT") && $0.contains("Sent Mail") }.count }

        // A send with no check: Sent is synced twice on its own and nothing is said.
        let beforeSend = sentSelects()
        h.server.add(fresh("sent-1", from: "owner@example.com"), to: "[Gmail]/Sent Mail")
        await h.syncer.messageWentOut()
        await assertEventually { sentSelects() >= beforeSend + 2 }
        try await wait(10)
        let unasked = await checkedCount(h)
        XCTAssertEqual(unasked, 0, "a folder synced on its own answers no check")

        // Send & Receive with a send just before it: one answer, from the check's own pass.
        let beforeCheck = sentSelects()
        h.server.add(fresh("sent-2", from: "owner@example.com"), to: "[Gmail]/Sent Mail")
        await h.syncer.messageWentOut()
        listener.check([h.account.id])
        await h.syncer.requestSync(check: true)
        await assertEventually { await self.checkedCount(h) == 1 && sentSelects() >= beforeCheck + 3 }
        try await wait(10)
        await h.settled()

        let answers = await checkedCount(h)
        XCTAssertEqual(answers, 1)
        let found = await h.events.all.compactMap { if case .checked(_, let found) = $0 { return found }; return nil }
        XCTAssertEqual(found, [false], "a message in Sent is no new mail")
        let stored = try await h.uids(in: "[Gmail]/Sent Mail")
        XCTAssertEqual(stored.count, 2, "both sent copies were synced")
        listener.hear(await h.events.timed)
        XCTAssertEqual(listener.sounds, [.noNewMessages])
    }

    func testACheckWhosePassIsCutIsAnsweredAfterTheQuietReconnect() async throws {
        let (h, clock) = try await started()
        let listener = Listener(start: clock)
        let logins = h.server.loginCount
        // The connection drops just after the check's pass selects INBOX.
        h.server.cutAfter("SELECT", count: 1)
        listener.check([h.account.id])
        await h.syncer.requestSync(check: true)
        await assertEventually(within: 5) { await self.checkedCount(h) == 1 }
        await h.settled()

        XCTAssertGreaterThan(h.server.loginCount, logins, "the pass was cut and the engine connected again")
        let healths = await h.events.healths
        XCTAssertFalse(healths.contains { $0.isFailing }, "quietly: \(healths)")
        listener.hear(await h.events.timed)
        XCTAssertEqual(listener.sounds, [.noNewMessages])
    }

    func testACheckWhosePassIsCutAfterItBroughtMailSaysItFoundSome() async throws {
        let (h, clock) = try await started()
        let listener = Listener(start: clock)
        let logins = h.server.loginCount
        // Stored without a word to the idling connection; the check's pass brings it from INBOX
        // and loses its connection at the next folder.
        h.server.add(fresh("news"), to: "INBOX")
        h.server.cutAfter("SELECT", count: 2)
        listener.check([h.account.id])
        await h.syncer.requestSync(check: true)
        await assertEventually(within: 5) { await self.checkedCount(h) == 1 }
        await h.settled()

        XCTAssertGreaterThan(h.server.loginCount, logins, "the pass was cut and the engine connected again")
        let all = await h.events.all
        let announcedAt = try XCTUnwrap(all.firstIndex { if case .newMessages = $0 { return true }; return false })
        let lastStart = try XCTUnwrap(all.lastIndex { if case .started = $0 { return true }; return false })
        XCTAssertLessThan(announcedAt, lastStart, "the cut pass brought it, before the pass that answered")
        let found = all.compactMap { if case .checked(_, let found) = $0 { return found }; return nil }
        XCTAssertEqual(found, [true], "the answer carries what the cut pass found")
        listener.hear(await h.events.timed)
        XCTAssertEqual(listener.sounds, [.newMessage], "and No new messages never follows the new message sound")
    }

    func testACheckDuringACatchUpFetchesWhatArrivedSinceAndSaysMailCame() async throws {
        var pacing = self.pacing
        pacing.catchUpWindow = 5
        pacing.catchUpInterval = 3600
        let (h, clock) = try await started(pacing)
        // Another program files twelve messages at once: a pass takes the newest five and holds
        // the rest back for the catch-up interval, an hour here.
        let bulk = h.server.addMany(12, to: "INBOX") { self.fresh("bulk-\($0)") }
        await h.syncer.requestSync()
        await assertEventually { ((try? await h.uids(in: "INBOX")) ?? []).count == 6 }
        await assertEventually { await self.finishedCount(h) >= 2 && h.server.idlingCount == 1 }

        // The message the owner is waiting for arrives, and they ask for it.
        let listener = Listener(start: clock)
        h.server.resetCounters()
        let urgent = h.server.add(fresh("urgent"), to: "INBOX")
        listener.check([h.account.id])
        await h.syncer.requestSync(check: true)
        await assertEventually { await self.checkedCount(h) == 1 }
        let stored = try await h.uids(in: "INBOX")
        XCTAssertTrue(stored.contains(urgent), "fetched for the check, catch-up or not")
        XCTAssertEqual(stored.count, 7, "the backlog still waits for its turn")
        XCTAssertEqual(FakeIMAPServer.headerFetchUIDs(h.server.exchanges), [urgent], "nothing of the backlog was fetched")
        let cursor = try await h.folder("INBOX").lastSyncedUID
        XCTAssertLessThan(cursor, bulk[0], "the cursor stays below the backlog")

        // Asked again with nothing newer, the answer is that mail is on its way, not none.
        listener.check([h.account.id])
        await h.syncer.requestSync(check: true)
        await assertEventually { await self.checkedCount(h) == 2 }
        await h.settled()
        let after = try await h.uids(in: "INBOX")
        XCTAssertEqual(after.count, 7)
        let found = await h.events.all.compactMap { if case .checked(_, let found) = $0 { return found }; return nil }
        XCTAssertEqual(found, [true, true])
        let announced = await h.events.announced.map(\.messageID)
        XCTAssertEqual(announced.last, "<urgent@example.com>")
        listener.hear(await h.events.timed)
        XCTAssertEqual(listener.sounds, [.newMessage, .newMessage], "the bulk's newest and the one asked for; never No new messages")
    }

    func testACheckOnAServerWithoutIdleIsAnsweredAtOnce() async throws {
        let clock = Date()
        let server = try EngineHarness.gmailServer(capabilities: ["IMAP4rev1", "AUTH=PLAIN", "MOVE", "UIDPLUS", "SPECIAL-USE"])
        server.add(FakeIMAPServer.message("first"), to: "INBOX")
        let h = try await EngineHarness(server: server, pacing: pacing)
        harness = h
        await h.syncer.start()
        await assertEventually { await self.finishedCount(h) == 1 }
        // Between polls the engine waits up to a minute for a server that cannot idle.
        try await Task.sleep(nanoseconds: 300_000_000)
        let listener = Listener(start: clock)
        let asked = Date()
        listener.check([h.account.id], at: asked)
        await h.syncer.requestSync(check: true)
        await assertEventually(within: 5) { await self.checkedCount(h) == 1 }
        XCTAssertLessThan(Date().timeIntervalSince(asked), 5, "the wait between polls was ended for it")
        await h.settled()
        listener.hear(await h.events.timed)
        XCTAssertEqual(listener.sounds, [.noNewMessages])
    }
}
