import XCTest
@testable import FalconCore

/// The engine's failures reach diagnostics as warnings and errors, each with an area that does
/// not change, a signature and title made from its typed kind rather than from the server's
/// words, and every folder name, address and server reply in it redacted before it is queued.
/// The engine's own log goes on as before: the same lines, started, rotated and kept alive the
/// same way, and nothing but warnings and errors ever reaches diagnostics.
final class EngineDiagnosticsTests: XCTestCase {
    private var harness: EngineHarness?
    private var center: DiagnosticsCenter?
    private var directory: URL!
    private var root: URL!
    private let seen = SeenRecords()

    override func setUp() {
        directory = DiagnosticsFixtures.temporaryDirectory("engine-diag")
        root = DiagnosticsFixtures.temporaryDirectory("engine-log")
        FakeDiagnosticsServer.reset()
    }

    override func tearDown() async throws {
        center?.stop()
        Log.observer = nil
        Log.isEnabled = true
        await harness?.finish()
        FakeDiagnosticsServer.reset()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: root)
    }

    /// A centre as a release build with the switch on has it, whose uploads reach only the fake
    /// server, and which hands this test every record it is given as well.
    @discardableResult
    private func startCenter() -> DiagnosticsCenter {
        let made = DiagnosticsCenter(directory: directory, gate: DiagnosticsFixtures.gate(), environment: DiagnosticsFixtures.environment(),
                                     crashReportsDirectory: nil, session: FakeDiagnosticsServer.session(), clock: ManualClock(),
                                     random: { 0.5 })
        made.start()
        let forward = Log.observer
        let seen = seen
        Log.observer = { record in
            seen.add(record)
            forward?(record)
        }
        center = made
        return made
    }

    private func events(area: String) -> [DiagnosticsEvent] {
        center?.waitUntilIdle()
        return (center?.pendingRecords ?? []).map(\.event).filter { $0.area == area }
    }

    private func started(_ server: FakeIMAPServer) async throws -> EngineHarness {
        let h = try await EngineHarness(server: server)
        harness = h
        return h
    }

    /// Everything that would be uploaded now, exactly as the fake server receives it.
    private func uploaded() async throws -> String {
        FakeDiagnosticsServer.respond { _, _ in DiagnosticsFixtures.okReply }
        let outcome = try await XCTUnwrap(center).uploadNow()
        guard case .sent = outcome else {
            XCTFail("nothing was sent: \(outcome)")
            return ""
        }
        return FakeDiagnosticsServer.requests.map { String(decoding: $0.body, as: UTF8.self) }.joined(separator: "\n")
    }

    // MARK: (a) Every failure that matters reaches diagnostics, named by its kind

    func testAThrottleDuringASyncIsAWarningNamedByItsKind() async throws {
        let server = try EngineHarness.gmailServer()
        server.add(FakeIMAPServer.message("first"), to: "INBOX")
        let h = try await started(server)
        startCenter()
        await h.syncer.start()
        await assertEventually { server.idlingCount == 1 }
        server.sendToIdling("* BYE Account exceeded command or bandwidth limits.", close: false)
        await assertEventually { await h.events.healths.contains { if case .imapPaused = $0 { return true }; return false } }

        let event = try XCTUnwrap(events(area: "IMAP").first)
        XCTAssertEqual(event.kind, .warning, "it passes by itself")
        XCTAssertEqual(event.signature, "IMAP.throttled@AccountSyncer.swift:loop")
        XCTAssertEqual(event.title, "The mail server paused the connection: too many requests")
        XCTAssertEqual(event.context["failure"], .string("throttled"))
        XCTAssertEqual(event.context["health"], .string("online"), "it happened while the account was online")
        XCTAssertTrue(event.message.contains("Account exceeded command or bandwidth limits"), "the server's words stay, redacted: \(event.message)")
        XCTAssertFalse(event.message.contains("owner@example.com"))
        XCTAssertEqual(event.account?.provider, "google")
    }

    /// The server's words would read as a throttle, "try again later"; its response code says
    /// the sign-in was refused, and the code decides.
    func testARefusedSignInIsAnErrorWhateverTheServerSays() async throws {
        let server = try EngineHarness.gmailServer()
        let h = try await started(server)
        startCenter()
        server.refuseLogins(code: "AUTHENTICATIONFAILED", text: "Sign-in refused for owner@example.com, try again later")
        await h.syncer.start()
        await assertEventually { await h.events.healths.contains(.needsSignIn) }

        let event = try XCTUnwrap(events(area: "IMAP").first)
        XCTAssertEqual(event.kind, .error)
        XCTAssertEqual(event.signature, "IMAP.notSignedIn@AccountSyncer.swift:loop", "never throttled, whatever the words")
        XCTAssertEqual(event.title, "Checking for new mail failed: the account needs to sign in again")
        XCTAssertEqual(event.context["health"], .string("connecting"))
        XCTAssertFalse(event.message.contains("owner@example.com"))
    }

    func testTooManyConnectionsIsAWarningAboutTheConnectionLimit() async throws {
        let server = try EngineHarness.gmailServer()
        let h = try await started(server)
        startCenter()
        server.greetWithBye("Too many simultaneous connections. (Failure)")
        await h.syncer.start()
        await assertEventually { await h.events.healths.contains { if case .imapPaused = $0 { return true }; return false } }

        let event = try XCTUnwrap(events(area: "IMAP").first)
        XCTAssertEqual(event.kind, .warning)
        XCTAssertEqual(event.signature, "IMAP.tooManyConnections@AccountSyncer.swift:loop")
        XCTAssertEqual(event.title, "The mail server refused a connection: other apps were using all it allows")
    }

    func testOpeningAMessageMovedOrDeletedIsAWarningAndItsFolderStaysOut() async throws {
        let server = try EngineHarness.gmailServer()
        server.addMailbox("HR")
        server.add(FakeIMAPServer.message("review", subject: "Salary review for Ana"), to: "HR")
        let h = try await started(server)
        try await h.syncOnce()
        let message = try await h.message(uid: 1, in: "HR")
        server.remove(uid: 1, from: "HR")
        startCenter()

        do {
            _ = try await h.syncer.body(for: message)
            XCTFail("the message is gone")
        } catch let failure as MailServiceError {
            XCTAssertEqual(failure.kind, .messageGone)
        }
        let event = try XCTUnwrap(events(area: "Open").first)
        XCTAssertEqual(event.kind, .warning)
        XCTAssertEqual(event.signature, "Open.messageGone@AccountSyncer.swift:body")
        XCTAssertEqual(event.title, "Opening a message failed: the message was no longer there")
        XCTAssertFalse(event.message.contains("HR"), "a short folder name the engine names goes too: \(event.message)")
        XCTAssertTrue(event.message.contains("<label:"), event.message)
        XCTAssertTrue(h.logText().contains("[sync] owner@example.com: opening a message in HR failed: messageGone"),
                      "the engine's own line is as it was")
    }

    func testAnActionTheServerRefusesIsAnErrorWithoutTheFoldersItNames() async throws {
        let server = try EngineHarness.gmailServer()
        server.addMailbox("Clients/ACME Contracts")
        server.addMailbox("HR")
        server.add(FakeIMAPServer.message("contract", subject: "ACME renewal"), to: "Clients/ACME Contracts")
        let h = try await started(server)
        try await h.syncOnce()
        await h.syncer.setUndoWindow(0)
        let message = try await h.message(uid: 1, in: "Clients/ACME Contracts")
        let destination = try await h.folder("HR")
        startCenter()
        server.refuseNext("UID MOVE", code: "TRYCREATE", text: "No folder HR, ask ana.lima@partner.example (Failure)")

        _ = try await h.syncer.move([message], to: destination)
        await assertEventually { await !h.events.actionFailures.isEmpty }

        let event = try XCTUnwrap(events(area: "Actions").first)
        XCTAssertEqual(event.kind, .error)
        XCTAssertEqual(event.signature, "Actions.noMailbox@AccountSyncer.swift:commit")
        XCTAssertEqual(event.title, "Changing messages on the server failed: a folder is missing on the server")
        for word in ["ACME", "Contracts", "Clients", "HR", "ana.lima", "partner.example", "owner@example.com"] {
            XCTAssertFalse(event.message.contains(word), "\(word) in \(event.message)")
        }
    }

    func testAFailedImportIsAnErrorOfTheImport() async throws {
        let server = try EngineHarness.gmailServer()
        server.addMailbox("Imported")
        let h = try await started(server)
        try await h.syncOnce()
        let folder = try await h.folder("Imported")
        startCenter()
        server.refuseNext("APPEND", code: "OVERQUOTA", text: "Quota exceeded for owner@example.com")

        do {
            try await h.syncer.importMessage(ImportedMessage(raw: FakeIMAPServer.message("old"), flags: [], date: nil), into: folder)
            XCTFail("refused")
        } catch {}
        let event = try XCTUnwrap(events(area: "Import").first)
        XCTAssertEqual(event.kind, .error)
        XCTAssertEqual(event.signature, "Import.serverRefused@AccountSyncer.swift:importMessage")
        XCTAssertEqual(event.title, "Importing mail failed: the server refused the request")
        XCTAssertFalse(event.message.contains("owner@example.com"))
    }

    func testMailKeptOnTheServerByAnArchiveIsAWarningWithoutItsFolder() async throws {
        let server = try EngineHarness.gmailServer(capabilities: ["IMAP4rev1", "AUTH=PLAIN", "IDLE", "MOVE", "SPECIAL-USE"])
        server.addMailbox("Clients/ACME Contracts")
        let longAgo = Date(timeIntervalSince1970: 1_600_000_000)
        server.add(FakeIMAPServer.message("old"), to: "Clients/ACME Contracts", date: longAgo)
        server.add(FakeIMAPServer.message("marked"), to: "Clients/ACME Contracts", flags: ["\\Deleted"])
        defer { server.stop() }
        Log.start(in: root)
        startCenter()
        let account = AccountInfo(email: "owner@example.com", displayName: "Owner")
        let request = ArchiveRequest(accountID: account.id, folderPaths: ["Clients/ACME Contracts"],
                                     olderThan: Date(timeIntervalSince1970: 1_700_000_000), name: "Old mail", password: nil,
                                     removeFromServer: true, parentID: nil)
        let source = ArchiveSource(connect: { try await server.client() }, allowance: { _ in false }, failed: { $0 })
        let outcome = try await ArchiveJob.run(request: request, account: account, source: source,
                                               storage: LocalFolderStorage(root: root.appendingPathComponent("Archives"))) { _ in }
        XCTAssertEqual(outcome.keptOnServer, ["Clients/ACME Contracts"])

        let event = try XCTUnwrap(events(area: "Archive").first)
        XCTAssertEqual(event.kind, .warning)
        XCTAssertEqual(event.signature, "Archive.expungeRefused@ArchiveJob.swift:archive")
        XCTAssertEqual(event.title, "Archived mail was kept on the server: another message there was marked for deletion")
        XCTAssertFalse(event.message.contains("ACME"), event.message)
    }

    func testAMessageHeldByTheSendingLimitIsAnErrorAndARetryAWarning() async throws {
        Log.start(in: root)
        startCenter()
        let layout = FileLayout(root: root)
        let limit = SMTPServerError(stage: .message, code: 550,
                                    text: "5.4.5 Daily user sending limit exceeded for owner@example.com. Ask ana@example.com")
        let held = Outbox(layout: layout, sender: FailingSender(limit), undoWindow: 0)
        _ = try await held.enqueue(accountID: UUID(), from: "owner@example.com", message: SendTests.outgoing(), sendAt: Date())
        await held.startPump()
        await assertEventually { await held.snapshot().first?.heldBack == true }

        let event = try XCTUnwrap(events(area: "SMTP").first)
        XCTAssertEqual(event.kind, .error)
        XCTAssertEqual(event.signature, "SMTP.sendingLimit@Outbox.swift:tick")
        XCTAssertEqual(event.title, "Sending a message failed: the daily sending limit was reached, so it is held in the Outbox")
        XCTAssertEqual(event.context["outcome"], .string("held"))
        XCTAssertFalse(event.message.contains("@example.com"), event.message)
        XCTAssertFalse(event.message.contains("Quarterly"), "the subject never goes")

        let busy = SMTPServerError(stage: .data, code: 421, text: "4.7.0 Try again later")
        let other = DiagnosticsFixtures.temporaryDirectory("outbox")
        defer { try? FileManager.default.removeItem(at: other) }
        let retrying = Outbox(layout: FileLayout(root: other), sender: FailingSender(busy), undoWindow: 0)
        _ = try await retrying.enqueue(accountID: UUID(), from: "owner@example.com", message: SendTests.outgoing(), sendAt: Date())
        await retrying.startPump()
        await assertEventually { await retrying.snapshot().first?.attempts == 1 }
        let again = try XCTUnwrap(events(area: "SMTP").first { $0.signature.hasPrefix("SMTP.temporary@") })
        XCTAssertEqual(again.kind, .warning, "tried again by itself")
        XCTAssertEqual(again.context["outcome"], .string("retrying"))
        XCTAssertEqual(again.title, "Sending a message failed: the server had a temporary problem")
    }

    func testAMessageHeldAfterFalconMailStoppedMidSendIsReported() throws {
        let layout = FileLayout(root: root)
        try FileManager.default.createDirectory(at: layout.outboxDirectory, withIntermediateDirectories: true)
        var item = OutboxItem(accountID: UUID(), subject: "Quarterly report", recipients: ["ana@example.com"], sender: "owner@example.com",
                              sendAt: Date(), undoWindow: 0)
        item.status = .sending
        try AtomicFile.writeJSON(item, to: layout.outboxDirectory.appendingPathComponent("\(item.id.uuidString).json"))
        Log.start(in: root)
        startCenter()
        _ = Outbox(layout: layout, sender: FailingSender(FalconError.cancelled), undoWindow: 0)

        let event = try XCTUnwrap(events(area: "Outbox").first)
        XCTAssertEqual(event.kind, .warning)
        XCTAssertEqual(event.signature, "Outbox.interrupted@Outbox.swift:init")
        XCTAssertEqual(event.title, "A message was being sent when FalconMail stopped, so it is held in the Outbox")
        XCTAssertFalse(event.message.contains("Quarterly"))
    }

    func testAFileSetAsideIsAnError() throws {
        Log.start(in: root)
        startCenter()
        let url = root.appendingPathComponent("rules.json")
        try Data("{ not json".utf8).write(to: url)
        let loaded = AtomicFile.loadJSON([String].self, from: url, what: "the rules for owner@example.com")
        guard case .setAside = loaded else { return XCTFail("\(loaded)") }

        let event = try XCTUnwrap(events(area: "Store").first)
        XCTAssertEqual(event.kind, .error)
        XCTAssertEqual(event.signature, "Store.setAside@FileLayout.swift:load")
        XCTAssertEqual(event.title, "A file FalconMail keeps could not be read, so it was set aside and kept")
        XCTAssertTrue(event.message.contains("rules.json.unreadable-"), "FalconMail's own file names stay: \(event.message)")
        XCTAssertFalse(event.message.contains("owner@example.com"))
    }

    /// As the app reports a Gmail search that fell back to this Mac: the API's typed refusal
    /// names it, not Google's words.
    func testASearchGmailRefusedIsNamedByTheRefusal() throws {
        startCenter()
        let refusal = GoogleAPIError(kind: .rateLimited, httpStatus: 429, reason: "rateLimitExceeded",
                                     detail: #"{"error":{"message":"Quota exceeded for quota metric 'Queries' for owner@example.com"}}"#)
        Log.warning("Search", "owner@example.com searched on this Mac: \(refusal.kind.rawValue) 429 rateLimitExceeded \(refusal.detail)",
                    error: refusal, logAs: "search")
        let event = try XCTUnwrap(events(area: "Search").first)
        XCTAssertEqual(event.kind, .warning)
        XCTAssertEqual(event.signature, "Search.throttled@EngineDiagnosticsTests.swift:testASearchGmailRefusedIsNamedByTheRefusal")
        XCTAssertEqual(event.title, "Searching on the server failed: the server asked FalconMail to slow down")
        XCTAssertEqual(event.context["httpStatus"], .int(429))
        XCTAssertFalse(event.message.contains("owner@example.com"))
    }

    /// Every kind of failure, in every area the engine reports under, has a title of its own that
    /// fits, and a code of its own that the server's words never change.
    func testEveryKindHasATitleAndACodeOfItsOwn() {
        let areas = ["IMAP", "Sync", "SMTP", "Outbox", "Actions", "Rules", "Mute", "Open", "Save", "Import", "Older", "Archive",
                     "Folders", "Store", "Search", "SignIn", "OAuth"]
        var codes: Set<String> = []
        for kind in MailServiceError.Kind.allCases {
            let plain = MailServiceError(kind: kind, email: "owner@example.com", isGoogle: true)
            let code = DiagnosticsSignature.code(for: plain, message: "")
            codes.insert(code)
            if kind != .local {
                // What only a server says: the kind was decided from its response code already.
                let worded = MailServiceError(kind: kind, email: "owner@example.com", isGoogle: true,
                                              detail: "try again later: bandwidth limit, invalid credentials, connection reset")
                XCTAssertEqual(DiagnosticsSignature.code(for: worded, message: worded.detail), code, "\(kind)")
            }
            for area in areas {
                let title = DiagnosticsTitle.make(kind: plain.logLevel == .error ? .error : .warning, area: area, code: code)
                XCTAssertLessThan(title.count, DiagnosticsEvent.maxTitle, title)
                XCTAssertFalse(title.contains("something unexpected"), "\(kind) in \(area): \(title)")
            }
        }
        XCTAssertEqual(codes.count, MailServiceError.Kind.allCases.count, "no two kinds share a code: \(codes.sorted())")
        // Something on this Mac is named by what macOS said, which no server writes.
        let full = MailServiceError(kind: .local, email: "owner@example.com", isGoogle: true, detail: "No space left on device")
        XCTAssertEqual(DiagnosticsSignature.code(for: full, message: ""), "diskFull")
    }

    /// Debug, snapshot and test builds hear the engine's failures and keep nothing of them.
    func testEngineFailuresInBuildsThatMayNotSendStayOffTheQueue() async throws {
        FakeDiagnosticsServer.respond { _, _ in DiagnosticsFixtures.okReply }
        Log.start(in: root)
        for gate in [DiagnosticsFixtures.gate(release: false), DiagnosticsFixtures.gate(bundle: "com.falconmail.app.snapshot"),
                     DiagnosticsFixtures.gate(bundle: nil)] {
            let folder = DiagnosticsFixtures.temporaryDirectory("engine-gate")
            defer { try? FileManager.default.removeItem(at: folder) }
            let made = DiagnosticsCenter(directory: folder, gate: gate, environment: DiagnosticsFixtures.environment(),
                                         crashReportsDirectory: nil, session: FakeDiagnosticsServer.session(), clock: ManualClock())
            made.start()
            let url = root.appendingPathComponent("\(UUID().uuidString).json")
            try Data("{ not json".utf8).write(to: url)
            _ = AtomicFile.loadJSON([String].self, from: url, what: "the rules")
            Log.failure("IMAP", MailServiceError(kind: .throttled, email: "owner@example.com", isGoogle: true), "owner@example.com: throttled",
                        logAs: "sync")
            made.waitUntilIdle()
            XCTAssertEqual(made.pendingCount, 0)
            let outcome = await made.uploadNow()
            XCTAssertEqual(outcome, .notAllowed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("queue.jsonl").path))
            made.stop()
        }
        XCTAssertTrue(FakeDiagnosticsServer.requests.isEmpty)
    }

    // MARK: (b) The engine's own log goes on as before

    func testInfoLinesTheHeartbeatIncludedNeverReachTheObserver() {
        Log.start(in: root)
        let seen = seen
        Log.observer = { seen.add($0) }
        let failure = MailServiceError(kind: .throttled, email: "owner@example.com", isGoogle: true, detail: "BYE [THROTTLED]")
        Log.info("sync", "owner@example.com Clients/ACME Contracts: 3 new messages")
        Log.info("app", "alive accounts=2 imapDown24h=12MB imapUp24h=0MB")
        Log.warning("Update", "Checking for updates failed")
        Log.error("Alert", "Could not move the message")
        Log.failure("IMAP", failure, "owner@example.com: throttled: BYE [THROTTLED]", logAs: "sync")
        Log.flush()

        XCTAssertEqual(seen.all.map(\.level), [.warning, .error, .warning])
        XCTAssertEqual(seen.all.map(\.area), ["Update", "Alert", "IMAP"])
        let log = (try? String(contentsOf: root.appendingPathComponent("falconmail.log"), encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("[app] alive accounts=2 imapDown24h=12MB imapUp24h=0MB\n"), "the heartbeat is written as before")
        XCTAssertTrue(log.contains("[sync] owner@example.com Clients/ACME Contracts: 3 new messages\n"))
    }

    func testAnEngineLineIsWrittenExactlyAsBeforeAndOthersWithTheirLevel() throws {
        Log.start(in: root)
        let failure = MailServiceError(kind: .throttled, email: "owner@example.com", isGoogle: true, detail: "BYE [THROTTLED] slow down")
        Log.failure("IMAP", failure, "owner@example.com: throttled: BYE [THROTTLED] slow down", logAs: "sync")
        Log.warning("Update", "Checking for updates failed: ana@example.com's server said no")
        Log.error("SignIn", "Checking a new password failed for owner@example.com: bo@example.org refused",
                  account: AccountInfo(email: "owner@example.com", displayName: "Owner"))
        Log.flush()

        let lines = try String(contentsOf: root.appendingPathComponent("falconmail.log"), encoding: .utf8)
            .split(separator: "\n").map { $0.split(separator: " ", maxSplits: 1).last.map(String.init) ?? "" }
        XCTAssertEqual(lines, [
            "[sync] owner@example.com: throttled: BYE [THROTTLED] slow down",
            "[Update] warning: Checking for updates failed: <address>'s server said no",
            "[SignIn] error: Checking a new password failed for owner@example.com: <address> refused",
        ], "the engine's line has no level added, and only the account's own address reaches the log")
    }

    func testLinesGoWhereTheLogWasLastStartedAndARotationKeepsTheOlderFile() throws {
        let other = DiagnosticsFixtures.temporaryDirectory("engine-log-other")
        defer { try? FileManager.default.removeItem(at: other) }
        Log.start(in: other)
        Log.warning("Update", "before")
        Log.start(in: root)
        let current = root.appendingPathComponent("falconmail.log")
        let full = Data(("the lead-up\n" + String(repeating: "x", count: Log.maxFileBytes)).utf8)
        try full.write(to: current)
        Log.error("Alert", "after the turn")
        Log.flush()

        XCTAssertFalse(try String(contentsOf: other.appendingPathComponent("falconmail.log"), encoding: .utf8).contains("after the turn"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("falconmail.1.log")), full, "the full log is kept whole")
        XCTAssertTrue(try String(contentsOf: current, encoding: .utf8).hasSuffix("[Alert] error: after the turn\n"))
    }

    // MARK: (d) Nothing the engine logs reaches an upload unredacted

    /// Real failures on folders with names of every shape, whose server replies name folders,
    /// the owner and other people: every record the observer is handed is a line the engine
    /// wrote to its log, and the upload holds none of what those lines named.
    func testRealEngineLinesReachAnUploadOnlyRedacted() async throws {
        let server = try EngineHarness.gmailServer()
        let folders = ["Clients/ACME Contracts", "HR", "Проекты", "2024"]
        for path in folders { server.addMailbox(path) }
        server.add(FakeIMAPServer.message("a", from: "ana.lima@partner.example", subject: "Salary review"), to: "HR")
        server.add(FakeIMAPServer.message("b", subject: "ACME renewal"), to: "Clients/ACME Contracts")
        server.add(FakeIMAPServer.message("c", subject: "Проект Альфа"), to: "Проекты")
        server.add(FakeIMAPServer.message("d"), to: "2024")
        let h = try await started(server)
        try await h.syncOnce()
        await h.syncer.setUndoWindow(0)
        startCenter()

        // Opened after it was deleted, from the folder with the short name.
        let review = try await h.message(uid: 1, in: "HR")
        server.remove(uid: 1, from: "HR")
        _ = try? await h.syncer.body(for: review)
        // Moved into a folder the server says it lacks, in the modified UTF-7 it writes names in.
        let renewal = try await h.message(uid: 1, in: "Clients/ACME Contracts")
        let wire = ModifiedUTF7.encode("Проекты")
        server.refuseNext("UID MOVE", code: "TRYCREATE",
                          text: "Mailbox \(wire) doesn't exist; owner@example.com, see ana.lima@partner.example")
        _ = try await h.syncer.move([renewal], to: try await h.folder("Проекты"))
        await assertEventually { await !h.events.actionFailures.isEmpty }
        // A draft saved to a folder named only by digits, refused with the name echoed.
        server.refuseNext("APPEND", code: nil, text: "Folder 2024 is read-only for Ana Lima <ana.lima@partner.example>")
        _ = try? await h.syncer.append(raw: FakeIMAPServer.message("draft", subject: "Board minutes"), to: try await h.folder("2024"),
                                       flags: [.draft], date: nil)

        center?.waitUntilIdle()
        let records = seen.all.filter { $0.account?.email == "owner@example.com" }
        XCTAssertEqual(Set(records.map(\.area)), ["Open", "Actions", "Save"])
        let log = h.logText()
        for record in records {
            // The observer gets the engine's own line whole; its log file, with only the owner's address.
            XCTAssertTrue(log.contains("[sync] \(Log.redacted(record.message, keeping: "owner@example.com"))\n"),
                          "the observer got the engine's own line: \(record.message)")
        }
        XCTAssertTrue(records.contains { $0.message.contains("Ana Lima <ana.lima@partner.example>") },
                      "the redactor sees the address, and so the name written beside it")
        XCTAssertFalse(log.contains("ana.lima@partner.example"), "while the log keeps only the owner's address")
        XCTAssertTrue(log.contains("opening a message in HR failed"), "the engine's log names its folders as before")

        let upload = try await uploaded()
        XCTAssertFalse(upload.isEmpty)
        for word in ["ACME", "Contracts", "Clients", "\"HR", " HR", "Проект", wire, "ana.lima", "partner.example",
                     "owner@example.com", "Ana Lima", "Salary", "renewal", "Board minutes"] {
            XCTAssertFalse(upload.contains(word), "\(word) reached the upload")
        }
        // Not inside an ID or a reference, where four digits can stand by chance.
        XCTAssertNil(upload.range(of: #"(?<![0-9A-Za-z-])2024(?![0-9A-Za-z-])"#, options: .regularExpression), "2024 reached the upload")
        for signature in ["Open.messageGone@AccountSyncer.swift:body", "Actions.noMailbox@AccountSyncer.swift:commit",
                          "Save.serverRefused@AccountSyncer.swift:append"] {
            XCTAssertTrue(upload.contains(signature), "\(signature) in \(upload)")
        }
    }

    /// A folder named after the owner's domain, as a company's folder often is, or after their
    /// mail service, is part of the owner's address in every line the engine writes: the address
    /// still becomes a reference, and nothing of it reaches the upload.
    func testAFolderNamedLikePartOfTheOwnersAddressLeavesTheAddressWhole() async throws {
        for (email, folder) in [("kamal.muradov@acme.example", "ACME"), ("kamal.muradov@gmail.com", "Gmail")] {
            FakeDiagnosticsServer.reset()
            let server = try EngineHarness.gmailServer()
            server.addMailbox(folder)
            server.add(FakeIMAPServer.message("review", subject: "Salary review"), to: folder)
            let h = try await EngineHarness(server: server, email: email)
            harness = h
            try await h.syncOnce()
            let message = try await h.message(uid: 1, in: folder)
            server.remove(uid: 1, from: folder)
            let made = startCenter()
            _ = try? await h.syncer.body(for: message)

            let event = try XCTUnwrap(events(area: "Open").first, email)
            XCTAssertEqual(event.signature, "Open.messageGone@AccountSyncer.swift:body")
            XCTAssertNotNil(event.message.range(of: #"^<addr:[0-9a-f]{8}>: opening a message in <label:[0-9a-f]{8}> failed"#,
                                                 options: .regularExpression), event.message)
            let upload = try await uploaded()
            for word in ["kamal", "muradov", "acme.", "@<label"] {
                XCTAssertFalse(upload.localizedCaseInsensitiveContains(word), "\(word) reached the upload for \(email)")
            }
            // The account's kind, "gmail", is sent; the folder's name is not.
            XCTAssertFalse(upload.contains(folder), "\(folder) reached the upload")
            made.stop()
            center = nil
            Log.observer = nil
            await h.finish()
            harness = nil
        }
    }

    /// The same lines, fed to the observer as the app would hand them over with only the folder
    /// names it knows: the redactor still takes out every one that stands as a word.
    func testEngineLinesWithTheAppsFolderNamesAloneAreRedacted() throws {
        let made = startCenter()
        made.updateRedaction(serverHosts: ["imap.gmail.com"], labels: ["Clients/ACME Contracts", "ACME Contracts", "Проекты"])
        let lines = [
            "owner@example.com: opening a message in Clients/ACME Contracts failed: messageGone: UID 12 not returned",
            "owner@example.com: move of 1 failed: folderGone: UID MOVE NO [TRYCREATE] Mailbox \(ModifiedUTF7.encode("Проекты")) doesn't exist",
            "owner@example.com: throttled: BYE [THROTTLED] Account exceeded command or bandwidth limits. From ana@example.com",
        ]
        for line in lines {
            Log.failure("Actions", MailServiceError(kind: .refused, email: "owner@example.com", isGoogle: true), line,
                        names: ["Проекты"], logAs: "sync")
        }
        let text = made.pendingDescription()
        for word in ["ACME", "Clients", "Проекты", ModifiedUTF7.encode("Проекты"), "owner@", "ana@"] {
            XCTAssertFalse(text.contains(word), "\(word) in \(text)")
        }
        XCTAssertTrue(text.contains("UID 12 not returned"), "what is not personal stays")
    }
}

/// Every record the observer was handed, in order.
private final class SeenRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [LogRecord] = []

    func add(_ record: LogRecord) { lock.withLock { records.append(record) } }

    var all: [LogRecord] { lock.withLock { records } }
}

private struct FailingSender: MessageSender {
    let failure: Error

    init(_ failure: Error) {
        self.failure = failure
    }

    func send(accountID: UUID, from: String, recipients: [String], message: Data) async throws {
        throw failure
    }
}
