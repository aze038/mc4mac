import XCTest
@testable import FalconCore

/// The proof that a Google account on the Gmail API never opens an IMAP or SMTP connection
/// (§12.5): the coordinator put together as the app does, with a fake IMAP server listening on
/// loopback behind the account's own IMAP settings, an IMAP connector spy and an SMTP spy, runs
/// the whole scenario of a day and more, and not one connection is asked for or made; the guard
/// stops one a mistake would make; and the account's IMAP store is left exactly as it was.
final class ZeroIMAPTests: XCTestCase {
    private var rigs: [CoordinatorRig] = []

    override func tearDown() async throws {
        for rig in rigs { await rig.finish() }
        rigs = []
    }

    private func rig(root: URL? = nil, switches: MemoryGmailEngineSwitchStore = MemoryGmailEngineSwitchStore()) throws -> CoordinatorRig {
        let made = try CoordinatorRig(root: root, switches: switches)
        rigs.append(made)
        return made
    }

    private let longAgo = Date(timeIntervalSince1970: 1_700_000_000)

    /// One action from a folder, undone within its window when `undo`.
    private func act(_ verb: MailActionRequest.Verb, _ id: GmailMessageID, in folder: FolderInfo, undo: Bool, rig: CoordinatorRig,
                     account: AccountInfo) async throws {
        let request = MailActionRequest(verb: verb, targets: .items([.message(.gmail(account: account.id, id: id))]),
                                        context: ListView(scope: .folder(folder.id), conversations: false))
        let receipt = try await rig.coordinator.perform(request, accountID: account.id)
        guard undo else { return }
        let undone = await rig.coordinator.undo(receipt.id, accountID: account.id)
        XCTAssertTrue(undone, "\(verb) is undone within its window")
    }

    private func mbox(_ subjects: [String]) -> Data {
        let text = subjects.enumerated().map { i, subject in
            "From ana@example.com Mon Jan  1 10:00:00 2024\nFrom: Ana <ana@example.com>\nTo: owner@example.com\nSubject: \(subject)\n"
                + "Date: Mon, 1 Jan 2024 10:0\(i):00 +0000\nMessage-ID: <import-\(i)@example.com>\n\nImported text \(i)\n"
        }.joined(separator: "\n")
        return Data(text.utf8)
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func testASwitchedAccountOpensNoIMAPOrSMTPConnectionThroughAFullScenario() async throws {
        let connections = StreamConnection.connectionsOpened
        let rig = try rig()
        let account = rig.googleAccount()
        let gmail = rig.gmail(for: account)
        let clients = gmail.addUserLabel(named: "Clients")
        // Clients stays under the archive job's 60 messages a minute, so the job never waits here.
        for i in 0..<60 {
            gmail.add(subject: "Older message \(i)", labels: i % 3 == 0 ? [.inbox] : [.inbox, clients],
                      date: longAgo.addingTimeInterval(Double(i) * 3_600))
        }
        let thread = gmail.add(subject: "Rates for November", labels: [.inbox, .unread], date: longAgo.addingTimeInterval(500_000))
        let withFile = gmail.add(subject: "Signed contract", labels: [.inbox], date: longAgo.addingTimeInterval(510_000), hasAttachment: true)
        let sent = gmail.add(subject: "My quote", from: "Owner <\(account.email)>", labels: [.sent], date: longAgo.addingTimeInterval(520_000))
        let spam = gmail.add(subject: "You won", labels: [.spam], date: longAgo.addingTimeInterval(530_000))
        let trashed = gmail.add(subject: "Old notice", labels: [.trash], date: longAgo.addingTimeInterval(540_000))
        let archived = gmail.add(subject: "Filed away", labels: [], date: longAgo.addingTimeInterval(550_000))
        try rig.writePreviousRelease(account)
        let digest = rig.imapStoreDigest(account)
        try await rig.rules.save([RuleDefinition(name: "Invoices", conditions: [RuleCondition(field: .subject, op: .contains, value: "Invoice")],
                                                 actions: [RuleAction(kind: .moveToFolder, value: "Clients")])])

        // Added, and listed in full.
        try await rig.launch(undoWindow: 60)
        try await rig.backfilled(account)
        let assembly = try await rig.assembly(account)
        let engine = assembly.engine
        let inbox = try await rig.folder(.inbox, of: account)
        let allFolders = await engine.folders()
        let clientsFolder = try XCTUnwrap(allFolders.first { $0.gmailLabelID == clients })
        let key = { (id: GmailMessageID) in RowKey.gmail(account: account.id, id: id) }
        func view(_ folder: FolderInfo) -> ListView { ListView(scope: .folder(folder.id), conversations: false) }
        let allMail = try await rig.folder(.all, of: account)
        let sentFolder = try await rig.folder(.sent, of: account)
        let junkFolder = try await rig.folder(.junk, of: account)
        let trashFolder = try await rig.folder(.trash, of: account)

        // A check with new mail announces it, as the app hears the IMAP engine.
        let first = gmail.mailbox.deliver(subject: "New order 4471", date: rig.clock.now())
        await rig.coordinator.checkForNewMail()
        try await eventually(timeout: 20, "the new mail is announced") { rig.events.announcedSubjects.contains("New order 4471") }
        try await eventually(timeout: 20, "Send & Receive answers") {
            rig.events.events.contains { if case .checked(let id, true) = $0 { return id == account.id } else { return false } }
        }
        let announcedIn = rig.events.events.compactMap { event -> UUID? in
            if case .newMessages(_, let folderID, _) = event { return folderID } else { return nil }
        }
        XCTAssertEqual(Set(announcedIn), [inbox.id], "announced from the Inbox, as the IMAP engine does")

        // Waking and a change of network check at once.
        let checks = await engine.checksCompleted
        await rig.coordinator.macWoke()
        await rig.coordinator.networkChanged()
        try await eventually(timeout: 20, "waking and the network check") { await engine.checksCompleted >= checks + 1 }

        // Opening a message, and an attachment.
        var opened: [OpenedMessage] = []
        for try await stage in await engine.open(key(thread.id), purpose: .window) { opened.append(stage) }
        XCTAssertFalse(opened.isEmpty)
        var stages: [OpenedMessage] = []
        for try await stage in await engine.open(key(withFile.id), purpose: .window) { stages.append(stage) }
        let stub = try XCTUnwrap(stages.last?.content.listedAttachments.first)
        let bytes = try await engine.attachmentData(stub, of: key(withFile.id))
        XCTAssertEqual(bytes.count, 50_000)

        // Every action, from every kind of folder, with Undo.
        let older = gmail.messages.filter { $0.labels == [.inbox] }.map(\.ref.id)
        try await act(.markRead, thread.id, in: inbox, undo: true, rig: rig, account: account)
        try await act(.markRead, thread.id, in: inbox, undo: false, rig: rig, account: account)
        try await act(.flag, thread.id, in: inbox, undo: false, rig: rig, account: account)
        try await act(.archive, older[0], in: inbox, undo: true, rig: rig, account: account)
        try await act(.archive, older[0], in: inbox, undo: false, rig: rig, account: account)
        try await act(.move(to: clientsFolder.id), older[1], in: inbox, undo: false, rig: rig, account: account)
        try await act(.junk, older[2], in: inbox, undo: false, rig: rig, account: account)
        try await act(.delete, older[3], in: inbox, undo: false, rig: rig, account: account)
        try await act(.markUnread, older[4], in: inbox, undo: false, rig: rig, account: account)
        try await act(.copy(to: clientsFolder.id), older[5], in: inbox, undo: false, rig: rig, account: account)
        let inClients = gmail.messages.filter { $0.labels == [.inbox, clients] }.map(\.ref.id)
        try await act(.archive, inClients[0], in: clientsFolder, undo: false, rig: rig, account: account)
        try await act(.move(to: inbox.id), archived.id, in: allMail, undo: false, rig: rig, account: account)
        try await act(.move(to: clientsFolder.id), sent.id, in: sentFolder, undo: false, rig: rig, account: account)
        try await act(.notJunk, spam.id, in: junkFolder, undo: false, rig: rig, account: account)
        try await act(.move(to: inbox.id), trashed.id, in: trashFolder, undo: false, rig: rig, account: account)
        try await act(.moveToOther, inClients[1], in: inbox, undo: false, rig: rig, account: account)
        let flushed = await engine.flushPending(within: 20)
        XCTAssertTrue(flushed)
        XCTAssertEqual(gmail.message(thread.id)?.labels, [.inbox, .starred], "read and flagged on Gmail")
        XCTAssertEqual(gmail.message(older[0])?.labels, [], "archived")
        XCTAssertEqual(gmail.message(older[1])?.labels, [clients], "moved")
        XCTAssertEqual(gmail.message(older[2])?.labels, [.spam], "junk")
        XCTAssertTrue(gmail.message(older[3])?.labels.contains(.trash) ?? false, "deleted")
        XCTAssertEqual(gmail.message(archived.id)?.labels, [.inbox])
        XCTAssertEqual(gmail.message(sent.id)?.labels, [.sent, clients], "Gmail keeps a copy in Sent")
        XCTAssertEqual(gmail.message(spam.id)?.labels, [.inbox])
        XCTAssertEqual(gmail.message(trashed.id)?.labels, [.inbox])

        // New Folder.
        let made = try await rig.coordinator.createFolder(named: "Projects", in: account)
        XCTAssertEqual(made?.name, "Projects")
        XCTAssertTrue(gmail.userLabels.values.contains { $0.name == "Projects" })

        // A rule firing on new mail, and a mute and unmute.
        let invoice = gmail.mailbox.deliver(subject: "Invoice 99", date: rig.clock.now())
        _ = await engine.check(reason: .schedule)
        _ = await engine.flushPending(within: 20)
        XCTAssertEqual(gmail.mailbox.message(invoice.id)?.labels.contains("INBOX"), false, "the rule filed it in Clients")
        _ = try await rig.coordinator.perform(MailActionRequest(verb: .mute, targets: .items([.conversation(key(thread.id))]),
                                                                context: view(inbox)), accountID: account.id)
        _ = await engine.flushPending(within: 20)
        let reply = gmail.mailbox.deliver(subject: "Re: Rates for November", date: rig.clock.now(), threadID: thread.threadID.hex)
        let muteReport = await engine.check(reason: .schedule)
        XCTAssertFalse(muteReport.announced.map(\.subject).contains("Re: Rates for November"), "a muted conversation is not announced")
        _ = await engine.flushPending(within: 20)
        XCTAssertEqual(gmail.mailbox.message(reply.id)?.labels.contains("INBOX"), false)
        _ = try await rig.coordinator.perform(MailActionRequest(verb: .unmute, targets: .items([.conversation(key(thread.id))]),
                                                                context: view(inbox)), accountID: account.id)
        let mutes = await rig.mutes.all()
        let stillMuted = mutes.filter { $0.accountID == account.id }
        XCTAssertTrue(stillMuted.isEmpty, "Unmute leaves no twin record")

        // Search, as rows every action works on.
        let searchID = UUID()
        let searched = await rig.coordinator.search("Invoice", id: searchID, accounts: [account.id], fetchRows: true)
        XCTAssertEqual(searched, [account.id])
        let hits = await assembly.list.snapshot(of: ListView(scope: .search(searchID), conversations: false))
        XCTAssertTrue(hits.itemCount > 0)
        await rig.coordinator.endSearch(searchID, accounts: [account.id])

        // A notification's click and each of its buttons.
        let notified = gmail.mailbox.deliver(subject: "Container arrived", date: rig.clock.now())
        _ = await engine.check(reason: .schedule)
        let notifiedKey = key(GmailMessageID(hex: notified.id)!).stringValue
        let target = await rig.coordinator.notificationTarget(messageID: notifiedKey)
        XCTAssertEqual(target?.inbox.id, inbox.id)
        if case .available(let summary)? = target?.availability {
            XCTAssertEqual(summary.subject, "Container arrived")
            XCTAssertEqual(summary.folderID, inbox.id)
        } else {
            XCTFail("the notification's message is found")
        }
        for verb in MailNotificationVerb.allCases {
            let message = gmail.mailbox.deliver(subject: "Notified \(verb.rawValue)", date: rig.clock.now())
            _ = await engine.check(reason: .schedule)
            let receipt = try await rig.coordinator.actOnNotification(verb, messageID: key(GmailMessageID(hex: message.id)!).stringValue)
            XCTAssertNotNil(receipt, "\(verb)")
        }
        _ = await engine.flushPending(within: 20)

        // Sending, through Gmail's own send.
        let outgoing = OutgoingMessage(from: EmailAddress(name: "Owner", address: account.email), to: [EmailAddress(address: "ben@example.com")],
                                       subject: "Quote for December", textBody: "Please find the quote.")
        let queued = try await rig.outbox.enqueue(accountID: account.id, from: account.email, message: outgoing)
        try await eventually(timeout: 20, "the message is sent") { await rig.outbox.snapshot().first { $0.id == queued.id }?.status == .sent }

        // Drafts: saved, saved again, discarded, and one sent.
        let draft = OutgoingMessage(from: EmailAddress(name: "Owner", address: account.email), to: [EmailAddress(address: "ben@example.com")],
                                    subject: "Draft of the rates", textBody: "First words.")
        let ref = DraftRef(localID: UUID(), accountID: account.id, stableMessageID: "<draft-\(UUID().uuidString)@falconmail.test>")
        let saved = try await assembly.drafts.save(MIMEBuilder.build(draft), as: ref)
        var more = draft
        more.textBody = "First words, and more."
        _ = try await assembly.drafts.save(MIMEBuilder.build(more), as: saved)
        await assembly.drafts.discard(saved, undoWindow: 0)
        let savedID = try XCTUnwrap(saved.gmailDraftID)
        try await eventually(timeout: 20, "the discarded draft is deleted") { gmail.draftIDs[savedID] == nil }
        let toSend = DraftRef(localID: UUID(), accountID: account.id, stableMessageID: "<send-\(UUID().uuidString)@falconmail.test>")
        let kept = try await assembly.drafts.save(MIMEBuilder.build(draft), as: toSend)
        let handed = await assembly.drafts.handOver(toSend.localID)
        let draftQueued = try await rig.outbox.enqueue(accountID: account.id, from: account.email, message: draft,
                                                       gmailDraftID: handed?.gmailDraftID ?? kept.gmailDraftID)
        try await eventually(timeout: 20, "the draft is sent") { await rig.outbox.snapshot().first { $0.id == draftQueued.id }?.status == .sent }
        let keptID = try XCTUnwrap(kept.gmailDraftID)
        try await eventually(timeout: 20, "and its Gmail draft deleted") { gmail.draftIDs[keptID] == nil }

        // An .mbox import.
        let file = rig.root.appendingPathComponent("Old mail.mbox")
        try mbox(["Imported one", "Imported two"]).write(to: file)
        let imported = await rig.coordinator.importFiles([file], into: clientsFolder)
        XCTAssertEqual(imported.imported, 2)
        XCTAssertTrue(imported.failures.isEmpty)

        // The archive job, removing what it archived from the folder.
        let source = try await rig.coordinator.archiveSource(for: account)
        let request = ArchiveRequest(accountID: account.id, folderPaths: [clientsFolder.path], olderThan: rig.clock.now().addingTimeInterval(-86_400),
                                     name: "Clients archive", password: nil, removeFromServer: true, parentID: nil)
        let outcome = try await ArchiveJob.run(request: request, account: account, source: source,
                                               storage: LocalFolderStorage(root: rig.root.appendingPathComponent("Archives"))) { _ in }
        XCTAssertGreaterThan(outcome.manifest.messageCount, 0)

        // The history expires, and the mailbox is listed again, with new mail meanwhile.
        gmail.expireHistory()
        gmail.mailbox.deliver(subject: "During the resync", date: rig.clock.now())
        _ = await engine.check(reason: .schedule)
        try await eventually(timeout: 60, "the resync ends") { await engine.state.backfill?.phase == .complete }

        // Another app imports a flood of old mail.
        for i in 0..<60 { gmail.add(subject: "Imported elsewhere \(i)", labels: [], date: longAgo.addingTimeInterval(Double(i))) }
        _ = await engine.check(reason: .schedule)

        // Relaunch, on the same files.
        await rig.quit()
        let again = try self.rig(root: rig.root, switches: rig.switches)
        again.gmail(for: account, mailbox: gmail.mailbox)
        try await again.launch()
        let relaunched = try await again.assembly(account)
        _ = await relaunched.engine.check(reason: .wake)

        // Not one IMAP or SMTP connection, asked for or made.
        XCTAssertEqual(rig.imap.peakConnections, 0, "no IMAP connection reached the fake server")
        XCTAssertEqual(rig.imap.loginCount, 0)
        XCTAssertEqual(again.imap.peakConnections, 0)
        XCTAssertTrue(rig.connector.calls.isEmpty && again.connector.calls.isEmpty, "the IMAP engine never asked for a connection")
        XCTAssertTrue(rig.smtp.accounts.isEmpty && again.smtp.accounts.isEmpty, "nothing went by SMTP")
        XCTAssertFalse(TransportGuard.shared.refusals.contains { $0.accountID == account.id }, "the guard refused nothing: nothing tried")
        XCTAssertEqual(StreamConnection.connectionsOpened, connections, "no mail server connection at all")
        XCTAssertNil(TransportGuard.shared.connectionsToGoogle[account.email.lowercased()])
        // Every entry point reached the in-memory Gmail.
        let reached = gmail.attempts
        for method: GmailMethod in [.historyList, .messagesGet, .attachmentsGet, .labelsCreate, .messagesSend, .draftsCreate, .draftsUpdate,
                                    .draftsDelete, .messagesImport, .messagesList] {
            XCTAssertGreaterThan(reached[method] ?? 0, 0, "\(method) reached Gmail")
        }
        XCTAssertGreaterThan((reached[.messagesModify] ?? 0) + (reached[.messagesBatchModify] ?? 0), 0, "the actions reached Gmail")
        _ = first
        // And the account's IMAP store is as v1.10 left it.
        await again.quit()
        XCTAssertEqual(rig.imapStoreDigest(account), digest)
    }

    func testTheGuardRefusesAForcedIMAPOrSMTPConnectionForASwitchedAccount() async throws {
        let rig = try rig()
        let account = rig.googleAccount()
        rig.gmail(for: account)
        try rig.writePreviousRelease(account)
        try await rig.launch()
        let connections = StreamConnection.connectionsOpened
        let imap = IMAPClient(host: "127.0.0.1", port: rig.imap.port, tls: false, label: account.email)
        do {
            try await imap.connect()
            XCTFail("the guard lets no IMAP connection through")
        } catch let error as MailServiceError {
            XCTAssertEqual(error.kind, .local)
            XCTAssertEqual(error.sentence, "IMAP is not used for Google accounts on the Gmail API.")
        }
        let smtp = SMTPClient(host: "smtp.gmail.com", port: 465, user: account.email.uppercased())
        do {
            try await smtp.connect()
            XCTFail("the guard lets no SMTP connection through")
        } catch let error as MailServiceError {
            XCTAssertEqual(error.sentence, "SMTP is not used for Google accounts on the Gmail API.")
        }
        XCTAssertEqual(rig.imap.peakConnections, 0, "refused before anything was sent")
        XCTAssertEqual(StreamConnection.connectionsOpened, connections)
        let refused = TransportGuard.shared.refusals.filter { $0.accountID == account.id }
        XCTAssertEqual(refused.map(\.transport), [.imap, .smtp])
        XCTAssertEqual(refused.map(\.host), ["127.0.0.1", "smtp.gmail.com"])
        // The IMAP engine's own way in is stopped too.
        let syncerStyle = IMAPClient(host: account.imapHost, port: account.imapPort, tls: false, label: account.email)
        await XCTAssertThrowsErrorAsync(try await syncerStyle.connect())
    }

    func testAnotherAccountOnGooglesIMAPIsLetThroughAndLogged() throws {
        let guardian = TransportGuard()
        let custom = AccountInfo.custom(email: "app-password@gmail.com", displayName: "C", imapHost: "imap.gmail.com", imapPort: 993,
                                        smtpHost: "smtp.gmail.com", smtpPort: 465, username: "app-password@gmail.com")
        XCTAssertNoThrow(try guardian.check(.imap, host: "imap.gmail.com", user: custom.loginName))
        XCTAssertNoThrow(try guardian.check(.imap, host: "IMAP.GMAIL.COM", user: custom.loginName))
        XCTAssertNoThrow(try guardian.check(.imap, host: "imap.example.org", user: "someone@example.org"))
        XCTAssertEqual(guardian.connectionsToGoogle, ["app-password@gmail.com": 2], "counted for the daily report")
        XCTAssertTrue(guardian.refusals.isEmpty)
        let switched = AccountInfo(email: "owner@gmail.com", displayName: "Owner", authMethod: "oauth")
        guardian.blockMailServers(for: switched)
        XCTAssertThrowsError(try guardian.check(.imap, host: "imap.gmail.com", user: "Owner@Gmail.com"))
        guardian.allowMailServers(for: switched.id)
        XCTAssertNoThrow(try guardian.check(.imap, host: "imap.gmail.com", user: "owner@gmail.com"))
    }

    func testAGmailAccountIsNotAddedByIMAPButByGoogleSignIn() async {
        let settings = CustomServerSettings.guess(for: "someone@gmail.com")
        do {
            try await AccountProbe.test(CustomServerSettings(imapHost: settings.imapHost, smtpHost: settings.smtpHost, username: "someone@gmail.com",
                                                             password: "secret"))
            XCTFail("a new Gmail account is not checked over IMAP")
        } catch {
            XCTAssertEqual(error.localizedDescription, AccountProbe.useGoogleSignIn)
        }
    }
}

func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {}
}
