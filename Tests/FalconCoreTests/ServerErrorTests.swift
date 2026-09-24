import XCTest
@testable import FalconCore

/// Refusals keep the server's response code and become one plain sentence; what kind of refusal
/// it is never depends on how any sentence is worded.
final class ServerErrorTests: XCTestCase {
    private var harness: EngineHarness?

    override func tearDown() async throws {
        await harness?.finish()
    }

    private func started(latency: TimeInterval = 0.002) async throws -> EngineHarness {
        let server = try EngineHarness.gmailServer(latency: latency)
        server.add(FakeIMAPServer.message("first"), to: "INBOX")
        let h = try await EngineHarness(server: server)
        harness = h
        return h
    }

    // MARK: The client

    func testByeAtTheGreetingIsTypedAndClosesTheConnection() async throws {
        let h = try await started()
        // Gmail's answer to one connection too many: BYE where the greeting should be.
        h.server.greetWithBye("Too many simultaneous connections. (Failure)")
        let client = IMAPClient(host: "127.0.0.1", port: h.server.port, tls: false, label: "owner@example.com")
        do {
            try await client.connect()
            XCTFail("the server said BYE")
        } catch let bye as IMAPBye {
            XCTAssertEqual(bye.text, "Too many simultaneous connections. (Failure)")
            XCTAssertEqual(MailServiceError.classify(bye, email: "owner@example.com", isGoogle: true).kind, .tooManyConnections)
        }
        let connected = await client.isConnected
        XCTAssertFalse(connected)
        XCTAssertTrue(h.logText().contains("BYE Too many simultaneous connections"), "every BYE is logged with its text")
    }

    func testTaggedNoKeepsItsResponseCodeAndTheConnection() async throws {
        let h = try await started()
        let client = try await h.server.client()
        _ = try await client.select("INBOX")
        h.server.refuseNext("UID FETCH", code: "UNAVAILABLE", text: "Temporary System Error")
        do {
            _ = try await client.fetchMessage(uid: 1)
            XCTFail("refused")
        } catch let refusal as IMAPServerError {
            XCTAssertEqual(refusal.status, .no)
            XCTAssertEqual(refusal.codeName, "UNAVAILABLE")
            XCTAssertEqual(refusal.command, "UID FETCH")
            XCTAssertEqual(refusal.text, "Temporary System Error")
        }
        let stillThere = await client.isConnected
        XCTAssertTrue(stillThere, "a refusal leaves the conversation in step")
        let body = try await client.fetchMessage(uid: 1)
        XCTAssertEqual(body, FakeIMAPServer.message("first"))
        await client.logout()
    }

    func testRefusedSignInIsTypedAndStopsTheLoop() async throws {
        let h = try await started()
        h.server.refuseLogins(code: "AUTHENTICATIONFAILED", text: "Invalid credentials (Failure)")
        await h.syncer.start()
        await assertEventually { await h.events.healths.contains(.needsSignIn) }
        // The sentence follows the status.
        await assertEventually { await !h.events.errors.isEmpty }
        let errors = await h.events.errors
        XCTAssertEqual(errors.last, "owner@example.com needs you to sign in again.")
        let attempts = h.server.commands.filter { $0.contains(" LOGIN ") || $0.contains(" AUTHENTICATE ") }.count
        try await Task.sleep(nanoseconds: 300_000_000)
        let later = h.server.commands.filter { $0.contains(" LOGIN ") || $0.contains(" AUTHENTICATE ") }.count
        XCTAssertEqual(later, attempts, "a refused sign-in is not retried until the owner signs in again")
    }

    func testThrottleByeDuringIdleIsAThrottle() async throws {
        let h = try await started()
        await h.syncer.start()
        await assertEventually { h.server.idlingCount == 1 }
        h.server.sendToIdling("* BYE Account exceeded command or bandwidth limits.", close: false)
        await assertEventually {
            await h.events.healths.contains { if case .imapPaused = $0 { return true }; return false }
        }
        await assertEventually { await !h.events.errors.isEmpty }
        let errors = await h.events.errors
        let shown = try XCTUnwrap(errors.last)
        XCTAssertTrue(shown.hasPrefix("Gmail asked FalconMail to slow down for owner@example.com."), shown)
        XCTAssertFalse(shown.contains("Protocol error"))
        XCTAssertTrue(h.logText().contains("BYE Account exceeded command or bandwidth limits."))
    }

    func testNewsBeforeIdlingIsNewMailNotAnError() async throws {
        let h = try await started()
        await h.syncer.start()
        await assertEventually { h.server.idlingCount == 1 }
        // The loop idles again after the delivery wakes it; this message is queued for that IDLE.
        h.server.deliverBeforeIdling(FakeIMAPServer.message("queued"), to: "INBOX")
        h.server.deliver(FakeIMAPServer.message("second"), to: "INBOX")
        await assertEventually { ((try? await h.uids(in: "INBOX")) ?? []).count == 3 }
        await h.settled()
        let errors = await h.events.errors
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        let stillOnline = await h.events.healths.last
        XCTAssertEqual(stillOnline, .online)
    }

    func testFinishIdleBeforeTheServerAgreesStillEndsIt() async throws {
        let server = FakeIMAPServer(latency: 0.25)
        server.addMailbox("INBOX")
        try server.start()
        defer { server.stop() }
        let client = try await server.client()
        _ = try await client.select("INBOX")
        let idling = Task { try await client.idle(maxWait: 60) }
        await assertEventually { server.commands.contains { $0.hasSuffix(" IDLE") } }
        try await client.finishIdle()
        let changed = try await within(5) { try await idling.value }
        XCTAssertFalse(changed)
        await client.logout()
    }

    func testARequestMadeDuringTheSelectBeforeIdleIsNotLost() async throws {
        let h = try await started()
        try await h.syncOnce()
        await h.syncer.start()
        await assertEventually { h.server.idlingCount == 1 }
        let sent = try await h.folder("[Gmail]/Sent Mail")
        let trash = try await h.folder("[Gmail]/Trash")
        h.server.resetCounters()
        // The first stall holds the Sent sync the first request starts, the second the SELECT
        // of INBOX the loop sends before idling again; the second request arrives during that one.
        h.server.stallNext("SELECT", seconds: 0.4)
        h.server.stallNext("SELECT", seconds: 0.6)
        await h.syncer.requestSync(folderID: sent.id)
        await assertEventually { h.server.commands.contains { $0.contains("SELECT \"INBOX\"") } }
        await h.syncer.requestSync(folderID: trash.id)
        await assertEventually("Trash is synced without waiting for IDLE to time out", within: 4) {
            h.server.commands.contains { $0.contains("SELECT \"[Gmail]/Trash\"") }
        }
    }

    func testAFailedOpenPromisesNoRetryAndPausesTheAccount() async throws {
        let h = try await started()
        try await h.syncOnce()
        let message = try await h.message(uid: 1, in: "INBOX")
        h.server.greetWithBye("Too many simultaneous connections. (Failure)")
        do {
            _ = try await h.syncer.body(for: message)
            XCTFail("the server refused the connection")
        } catch let failure as MailServiceError {
            XCTAssertEqual(failure.kind, .tooManyConnections)
            XCTAssertTrue(failure.isOneOff)
            XCTAssertFalse(failure.sentence.contains("Retrying"), failure.sentence)
            XCTAssertTrue(failure.sentence.hasPrefix("Other apps are using owner@example.com's connections. Try again after "), failure.sentence)
        }
        // Both were given before the open failed.
        await h.settled()
        let paused = await h.events.healths.contains { if case .imapPaused = $0 { return true }; return false }
        XCTAssertTrue(paused)
        let status = await h.events.errors.last ?? ""
        XCTAssertTrue(status.hasPrefix("Other apps are using owner@example.com's connections. Retrying in "), "the account's status says what it does: \(status)")

        let logins = h.server.loginCount
        h.server.resetCounters()
        do {
            _ = try await h.syncer.body(for: message)
            XCTFail("paused")
        } catch let failure as MailServiceError {
            XCTAssertEqual(failure.kind, .tooManyConnections)
            XCTAssertFalse(failure.sentence.contains("Retrying"), failure.sentence)
        }
        XCTAssertEqual(h.server.loginCount, logins, "the next open waits instead of asking Gmail again")
        XCTAssertTrue(h.server.commands.isEmpty)
    }

    func testAThrottleMetOpeningAMessagePausesTheAccount() async throws {
        let h = try await started()
        h.server.add(FakeIMAPServer.message("second"), to: "INBOX")
        try await h.syncOnce()
        h.server.refuseNext("UID FETCH", code: nil, text: "Account exceeded command or bandwidth limits.")
        do {
            _ = try await h.syncer.body(for: try await h.message(uid: 1, in: "INBOX"))
            XCTFail("refused")
        } catch let failure as MailServiceError {
            XCTAssertEqual(failure.kind, .throttled)
            XCTAssertFalse(failure.sentence.contains("shortly"), failure.sentence)
            XCTAssertTrue(failure.sentence.hasPrefix("Gmail asked FalconMail to slow down for owner@example.com. Try again after "), failure.sentence)
        }
        // The pause was given before the open failed; the listener may not have heard it yet.
        await h.settled()
        let paused = await h.events.healths.last
        guard case .imapPaused(let until) = paused else { return XCTFail("\(String(describing: paused))") }
        XCTAssertGreaterThanOrEqual(until.timeIntervalSinceNow, 1700)
        h.server.resetCounters()
        do {
            _ = try await h.syncer.body(for: try await h.message(uid: 2, in: "INBOX"))
            XCTFail("paused")
        } catch let failure as MailServiceError {
            XCTAssertEqual(failure.kind, .throttled)
        }
        XCTAssertTrue(h.server.commands.isEmpty, "\(h.server.commands)")
    }

    func testARefusedAccessTokenIsRefreshedOnceAndTriedAgain() async throws {
        let h = try await started()
        let port = h.server.port
        let asked = Recorder<Bool>()
        h.server.refuseNext("AUTHENTICATE", code: "AUTHENTICATIONFAILED", text: "Invalid credentials (Failure)")
        let client = try await AccountSyncer.signIn(user: "owner@example.com", isGoogle: true, connect: {
            let c = IMAPClient(host: "127.0.0.1", port: port, tls: false, label: "owner@example.com")
            try await c.connect()
            return c
        }, accessToken: { force in
            asked.append(force)
            return force ? "fresh-token" : "rejected-token"
        })
        XCTAssertEqual(asked.all, [false, true])
        let connected = await client.isConnected
        XCTAssertTrue(connected)
        await client.logout()
    }

    func testAnAccessTokenRefusedAfterItsRefreshStops() async throws {
        let h = try await started()
        let port = h.server.port
        let asked = Recorder<Bool>()
        h.server.refuseLogins(code: "AUTHENTICATIONFAILED", text: "Invalid credentials (Failure)")
        do {
            _ = try await AccountSyncer.signIn(user: "owner@example.com", isGoogle: true, connect: {
                let c = IMAPClient(host: "127.0.0.1", port: port, tls: false, label: "owner@example.com")
                try await c.connect()
                return c
            }, accessToken: { force in
                asked.append(force)
                return "token"
            })
            XCTFail("refused twice")
        } catch {
            XCTAssertEqual(MailServiceError.classify(error, email: "owner@example.com", isGoogle: true).kind, .needsSignIn)
        }
        XCTAssertEqual(asked.all, [false, true], "one refresh, then the owner is asked")
    }

    // MARK: Classification

    /// RFC 3501 gives a NO to LOGIN one meaning, "user name or password rejected"; a server
    /// with a passing problem says so with a code of its own.
    func testARefusedLoginIsASignInProblemUnlessItsCodeSaysOtherwise() {
        func kind(_ code: String?, _ text: String, _ command: String = "LOGIN") -> MailServiceError.Kind {
            MailServiceError.classify(IMAPServerError(status: .no, code: code, text: text, command: command),
                                      email: "owner@example.com", isGoogle: false).kind
        }
        XCTAssertEqual(kind(nil, "LOGIN failed."), .needsSignIn)
        XCTAssertEqual(kind("AUTHENTICATIONFAILED", "Authentication failed."), .needsSignIn)
        XCTAssertEqual(kind("UNAVAILABLE", "Temporary authentication failure"), .temporary)
        XCTAssertEqual(kind("INUSE", "Mailbox in use"), .temporary)
        XCTAssertEqual(kind(nil, "Too many simultaneous connections. (Failure)", "AUTHENTICATE"), .tooManyConnections)
        XCTAssertEqual(kind(nil, "Account exceeded command or bandwidth limits.", "AUTHENTICATE"), .throttled)
    }

    func testOneOffFailuresPromiseNothingTheEngineDoesNotDo() {
        let later = Date().addingTimeInterval(1800)
        let laterText = DateFormatter.localizedString(from: later, dateStyle: .none, timeStyle: .short)
        func said(_ kind: MailServiceError.Kind, retryAfter: Date? = nil) -> String {
            MailServiceError(kind: kind, email: "owner@example.com", isGoogle: true, retryAfter: retryAfter, isOneOff: true).sentence
        }
        XCTAssertEqual(said(.throttled, retryAfter: later), "Gmail asked FalconMail to slow down for owner@example.com. Try again after \(laterText).")
        XCTAssertEqual(said(.throttled), "Gmail asked FalconMail to slow down for owner@example.com. Try again later.")
        XCTAssertEqual(said(.tooManyConnections), "Other apps are using owner@example.com's connections. Try again in a few minutes.")
        XCTAssertEqual(said(.webSignInRequired), "Google wants you to sign in to owner@example.com in a web browser first.")
        XCTAssertEqual(said(.connectionDropped), "FalconMail lost the connection to owner@example.com. Try again in a moment.")
        XCTAssertEqual(said(.temporary), "Gmail had a temporary problem. Try again in a moment.")
        for kind in MailServiceError.Kind.allCases where kind != .local {
            let sentence = said(kind, retryAfter: later)
            XCTAssertFalse(sentence.contains("Retrying") || sentence.contains("will retry") || sentence.contains("Reconnecting")
                           || sentence.contains("resume"), sentence)
        }
    }

    func testClassificationNeverReadsDisplayText() {
        func kind(_ e: Error) -> MailServiceError.Kind { MailServiceError.classify(e, email: "owner@example.com", isGoogle: true).kind }
        // Every sentence FalconMail can show, and the old wordings, dressed as errors: none is
        // taken for what it says.
        var sentences: [String] = MailServiceError.Kind.allCases.map {
            MailServiceError(kind: $0, email: "owner@example.com", isGoogle: true, detail: "x", retryAfter: Date(), name: "INBOX").sentence
        }
        sentences += ["Protocol error: Account exceeded command or bandwidth limits.", "Not signed in.",
                      "server closed session: Account exceeded command or bandwidth limits.", "Too many simultaneous connections"]
        for sentence in sentences {
            XCTAssertEqual(kind(DisplayOnly(text: sentence)), .local, sentence)
            XCTAssertEqual(kind(FalconError.protocolError(sentence)), .refused, sentence)
            XCTAssertEqual(kind(FalconError.network(sentence)), .connectionDropped, sentence)
            XCTAssertEqual(kind(FalconError.storage(sentence)), .local, sentence)
        }
        // Typed values decide, whatever their text says.
        XCTAssertEqual(kind(IMAPServerError(status: .no, code: "AUTHENTICATIONFAILED", text: "Welcome!", command: "AUTHENTICATE")), .needsSignIn)
        XCTAssertEqual(kind(IMAPServerError(status: .no, code: "TRYCREATE", text: "anything", command: "UID MOVE", mailbox: "Labels/Old")), .folderGone)
        XCTAssertEqual(kind(IMAPBye(code: nil, text: "Idle for too long")), .connectionDropped)
        XCTAssertEqual(kind(IMAPMessageMissing(mailbox: "INBOX", uid: 9)), .messageGone)
        XCTAssertEqual(kind(IMAPMailboxRenumbered(mailbox: "INBOX", expected: 1, found: 2)), .mailboxRenumbered)
        XCTAssertEqual(kind(SMTPServerError(stage: .authentication, code: 535, text: "5.7.8 Username and Password not accepted")), .needsSignIn)
    }

    func testFalconMailNeverSaysProtocolError() {
        XCTAssertEqual(FalconError.protocolError("empty line").localizedDescription, "The mail server refused the request.")
        for kind in MailServiceError.Kind.allCases where kind != .local {
            let sentence = MailServiceError(kind: kind, email: "owner@example.com", isGoogle: true, detail: "Protocol error: x").sentence
            XCTAssertFalse(sentence.localizedCaseInsensitiveContains("protocol"), sentence)
        }
    }

    /// Each row of the design's table of refusals that today's engine can meet, from the typed
    /// value to the sentence the owner reads.
    func testEveryRefusalBecomesItsSentence() {
        let resume = Date().addingTimeInterval(1800)
        let resumeText = DateFormatter.localizedString(from: resume, dateStyle: .none, timeStyle: .short)
        func said(_ e: Error, google: Bool = true, retryAfter: Date? = nil) -> String {
            var failure = MailServiceError.classify(e, email: "owner@example.com", isGoogle: google)
            if let retryAfter { failure.retryAfter = retryAfter }
            return failure.sentence
        }
        XCTAssertEqual(said(IMAPBye(code: "THROTTLED", text: "Account exceeded command or bandwidth limits."), retryAfter: resume),
                       "Gmail asked FalconMail to slow down for owner@example.com. Mail on this Mac stays available; downloads resume at \(resumeText).")
        XCTAssertEqual(said(IMAPServerError(status: .no, code: nil, text: "Service temporarily unavailable: lockdown", command: "UID FETCH"), retryAfter: resume),
                       "Gmail asked FalconMail to slow down for owner@example.com. Mail on this Mac stays available; downloads resume at \(resumeText).")
        XCTAssertEqual(said(MailServiceError(kind: .overBudget, email: "owner@example.com", isGoogle: true, retryAfter: resume)),
                       "owner@example.com has used today's download allowance. Mail on this Mac and new mail stay available; older messages open again at \(resumeText).")
        XCTAssertEqual(said(IMAPServerError(status: .no, code: "ALERT", text: "Too many simultaneous connections. (Failure)", command: "AUTHENTICATE"),
                            retryAfter: Date().addingTimeInterval(420)),
                       "Other apps are using owner@example.com's connections. Retrying in 7 minutes.")
        XCTAssertEqual(said(IMAPServerError(status: .no, code: "ALERT", text: "Please log in via your web browser: https://support.google.com/mail/accounts/answer/78754 (Failure)",
                                            command: "AUTHENTICATE")),
                       "Google wants you to sign in to owner@example.com in a web browser first. FalconMail will retry after that.")
        XCTAssertEqual(said(IMAPServerError(status: .no, code: "WEBALERT https://accounts.google.com/x", text: "Web login required", command: "LOGIN")),
                       "Google wants you to sign in to owner@example.com in a web browser first. FalconMail will retry after that.")
        XCTAssertEqual(said(FalconError.network("connection closed by peer")), "Reconnecting to owner@example.com…")
        XCTAssertEqual(said(IMAPBye(code: nil, text: "Session expired")), "Reconnecting to owner@example.com…")
        XCTAssertEqual(said(IMAPServerError(status: .no, code: "AUTHENTICATIONFAILED", text: "Invalid credentials (Failure)", command: "AUTHENTICATE")),
                       "owner@example.com needs you to sign in again.")
        XCTAssertEqual(said(FalconError.notAuthenticated), "owner@example.com needs you to sign in again.")
        XCTAssertEqual(said(IMAPMessageMissing(mailbox: "INBOX", uid: 12)), "This message was moved or deleted on the server.")
        XCTAssertEqual(said(IMAPServerError(status: .no, code: "NONEXISTENT", text: "Unknown Mailbox: Clients/Old (Failure)", command: "SELECT",
                                            mailbox: "Clients/Old")),
                       "The folder “Clients/Old” no longer exists on the server.")
        XCTAssertEqual(said(IMAPServerError(status: .no, code: "TRYCREATE", text: "No folder Clients/Old (Failure)", command: "UID MOVE",
                                            mailbox: "Clients/Old")),
                       "The folder “Clients/Old” no longer exists on the server.")
        XCTAssertEqual(said(IMAPServerError(status: .no, code: "UNAVAILABLE", text: "Temporary System Error", command: "UID FETCH")),
                       "Gmail had a temporary problem. Retrying.")
        XCTAssertEqual(said(SMTPServerError(stage: .message, code: 550, text: "5.4.5 Daily user sending limit exceeded.")),
                       "Gmail's daily sending limit for owner@example.com was reached. The message stays in the Outbox.")
        XCTAssertEqual(said(SMTPServerError(stage: .recipient, code: 553, text: "5.1.3 The recipient address is not valid", recipient: "ana@exmple")),
                       "Gmail refused the address ana@exmple.")
        XCTAssertEqual(said(IMAPServerError(status: .bad, code: nil, text: "Could not parse command", command: "UID FETCH")),
                       "owner@example.com: the server refused a request. Details are in the log.")
        XCTAssertEqual(said(IMAPExpungeRefused(mailbox: "Trash", others: [7])),
                       "Nothing was deleted from “Trash”: another message there is marked for deletion, and this server can only delete them all at once.")
        XCTAssertEqual(said(IMAPServerError(status: .no, code: nil, text: "Server Unavailable", command: "SELECT"), google: false),
                       "owner@example.com: the server refused a request. Details are in the log.")
        XCTAssertEqual(said(IMAPServerError(status: .no, code: "UNAVAILABLE", text: "Maintenance", command: "SELECT"), google: false),
                       "The mail server had a temporary problem. Retrying.")
    }

    func testOnlyPassingTroubleIsTriedAgainByTheOutbox() {
        XCTAssertTrue(Outbox.isTransient(SMTPServerError(stage: .data, code: 421, text: "4.7.0 Try again later")))
        XCTAssertTrue(Outbox.isTransient(MailServiceError(kind: .temporary, email: "a@b.c", isGoogle: true)))
        XCTAssertFalse(Outbox.isTransient(SMTPServerError(stage: .recipient, code: 550, text: "5.1.1 No such user", recipient: "x@y.z")))
        XCTAssertFalse(Outbox.isTransient(SMTPServerError(stage: .message, code: 550, text: "5.4.5 Daily user sending quota exceeded.")))
    }
}

/// An error whose only content is its description, as any error from outside the engine is.
private struct DisplayOnly: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

/// Collects values from closures that may run on any thread.
final class Recorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func append(_ value: Value) { lock.withLock { values.append(value) } }
    var all: [Value] { lock.withLock { values } }
}
