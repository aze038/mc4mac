import XCTest
@testable import FalconCore

/// Each thing asked of an account goes to its own engine (§7.7, §8.1, §4.7): sending, drafts,
/// actions, notifications and the sounds of a Google account on the Gmail API through its Gmail
/// engine, never by IMAP or SMTP, and everything of any other account as before.
final class EngineRoutingTests: XCTestCase {
    private var rigs: [CoordinatorRig] = []

    override func tearDown() async throws {
        for rig in rigs { await rig.finish() }
        rigs = []
    }

    private func rig(fillsCache: Bool = false) throws -> CoordinatorRig {
        let made = try CoordinatorRig(fillsCache: fillsCache)
        rigs.append(made)
        return made
    }

    private func imapAccount(_ rig: CoordinatorRig) -> AccountInfo {
        AccountInfo(email: "office@example.org", displayName: "Office", provider: "imap", imapHost: "127.0.0.1", imapPort: rig.imap.port,
                    smtpHost: "127.0.0.1", smtpPort: 1, authMethod: "password", username: "office@example.org")
    }

    // MARK: - Sending

    func testMailGoesByGmailsOwnSendForAnAccountOnTheGmailAPIAndBySMTPForAnyOther() async throws {
        let rig = try rig()
        let google = rig.googleAccount()
        let gmail = rig.gmail(for: google)
        try rig.writePreviousRelease(google)
        let office = imapAccount(rig)
        try rig.writePreviousRelease(office)
        try await rig.launch()
        let googleRoute = await rig.coordinator.sendRoute(for: google.id)
        if case .gmail = googleRoute {} else { XCTFail("an account on the Gmail API sends through Gmail") }
        let officeRoute = await rig.coordinator.sendRoute(for: office.id)
        if case .smtp = officeRoute {} else { XCTFail("any other account sends by SMTP") }

        let message = OutgoingMessage(from: EmailAddress(address: google.email), to: [EmailAddress(address: "ben@example.com")],
                                      subject: "By Gmail", textBody: "Hello")
        let queued = try await rig.outbox.enqueue(accountID: google.id, from: google.email, message: message)
        try await eventually(timeout: 20, "sent") { await rig.outbox.snapshot().first { $0.id == queued.id }?.status == .sent }
        XCTAssertEqual(gmail.calls[.messagesSend], 1)
        XCTAssertTrue(rig.smtp.accounts.isEmpty)

        let other = OutgoingMessage(from: EmailAddress(address: office.email), to: [EmailAddress(address: "ben@example.com")],
                                    subject: "By SMTP", textBody: "Hello")
        let smtpQueued = try await rig.outbox.enqueue(accountID: office.id, from: office.email, message: other)
        try await eventually(timeout: 20, "sent by SMTP") { await rig.outbox.snapshot().first { $0.id == smtpQueued.id }?.status == .sent }
        XCTAssertEqual(rig.smtp.accounts, [office.id])
    }

    func testAnAccountOnTheGmailAPIWhoseEngineIsNotRunningKeepsItsMailInTheOutboxAndNeverUsesSMTP() async throws {
        let rig = try rig()
        var google = rig.googleAccount()
        rig.gmail(for: google)
        try rig.writePreviousRelease(google)
        try await rig.launch()
        google.isEnabled = false
        try await rig.store.saveAccount(google)
        await rig.coordinator.start(account: google)
        let route = await rig.coordinator.sendRoute(for: google.id)
        if case .gmailUnavailable = route {} else { XCTFail("waits for its engine, never SMTP") }
        let message = OutgoingMessage(from: EmailAddress(address: google.email), to: [EmailAddress(address: "ben@example.com")],
                                      subject: "Waits", textBody: "Hello")
        let queued = try await rig.outbox.enqueue(accountID: google.id, from: google.email, message: message)
        try await Task.sleep(nanoseconds: 300_000_000)
        let item = await rig.outbox.snapshot().first { $0.id == queued.id }
        XCTAssertNotEqual(item?.status, .sent)
        XCTAssertTrue(rig.smtp.accounts.isEmpty, "no SMTP fallback for a Google account")
        XCTAssertEqual(rig.imap.loginCount, 0)
    }

    /// Launches `account` once so it moves to the Gmail API, pauses it when `paused`, and quits,
    /// leaving the guard as a new process finds it.
    private func switchedAndQuit(_ account: inout AccountInfo, on first: CoordinatorRig, paused: Bool) async throws {
        first.gmail(for: account)
        try first.writePreviousRelease(account)
        try await first.launch()
        let route = await first.coordinator.sendRoute(for: account.id)
        if case .gmail = route {} else { XCTFail("the account moved to the Gmail API at the first launch") }
        if paused {
            account.isEnabled = false
            try await first.store.saveAccount(account)
        }
        await first.quit()
        TransportGuard.shared.allowMailServers(for: account.id)
    }

    func testAPausedAccountOnTheGmailAPIStaysOnItAfterARelaunchAndNeverUsesSMTPOrIMAP() async throws {
        let earlier = try rig()
        var account = earlier.googleAccount()
        try await switchedAndQuit(&account, on: earlier, paused: true)
        let google = account
        let relaunched = try CoordinatorRig(root: earlier.root, switches: earlier.switches)
        rigs.append(relaunched)
        relaunched.gmail(for: google, mailbox: earlier.gmail(for: google).mailbox)
        try await relaunched.launch()

        let route = await relaunched.coordinator.sendRoute(for: google.id)
        if case .gmailUnavailable = route {} else { XCTFail("a paused account on the Gmail API never sends by SMTP") }
        XCTAssertTrue(TransportGuard.shared.blocks(user: google.email), "IMAP and SMTP are refused for it")
        let sealed = await relaunched.store.isSealed(google.id)
        XCTAssertTrue(sealed, "its IMAP store stays as it was")
        let roster = await relaunched.coordinator.roster
        XCTAssertTrue(roster.gmailAccounts.contains(google.id))
        XCTAssertNil(roster.running[google.id], "a paused account's engine does not run")

        let message = OutgoingMessage(from: EmailAddress(address: google.email), to: [EmailAddress(address: "ben@example.com")],
                                      subject: "Waits", textBody: "Hello")
        let queued = try await relaunched.outbox.enqueue(accountID: google.id, from: google.email, message: message)
        try await eventually(timeout: 10, "an attempt") { (await relaunched.outbox.snapshot().first { $0.id == queued.id }?.attempts ?? 0) > 0 }
        let item = await relaunched.outbox.snapshot().first { $0.id == queued.id }
        XCTAssertNotEqual(item?.status, .sent)
        XCTAssertTrue(relaunched.smtp.accounts.isEmpty, "no SMTP for a Google account on the Gmail API")
        XCTAssertEqual(relaunched.imap.loginCount + earlier.imap.loginCount, 0)
        XCTAssertTrue(relaunched.connector.calls.isEmpty)
    }

    func testMailQueuedAtLaunchNeverGoesBySMTPBeforeItsAccountStartsAndThenGoesThroughGmail() async throws {
        let earlier = try rig()
        var account = earlier.googleAccount()
        try await switchedAndQuit(&account, on: earlier, paused: false)
        let google = account
        let relaunched = try CoordinatorRig(root: earlier.root, switches: earlier.switches)
        rigs.append(relaunched)
        let gmail = relaunched.gmail(for: google, mailbox: earlier.gmail(for: google).mailbox)
        let sentBefore = gmail.calls[.messagesSend] ?? 0
        try await relaunched.launch { coordinator in
            // The Outbox runs before any account's engine has started, as when the owner clicks
            // Retry or sends at once after launch.
            do {
                let message = OutgoingMessage(from: EmailAddress(address: google.email), to: [EmailAddress(address: "ben@example.com")],
                                              subject: "Early", textBody: "Hello")
                let queued = try await relaunched.outbox.enqueue(accountID: google.id, from: google.email, message: message)
                try await eventually(timeout: 10, "an attempt") {
                    (await relaunched.outbox.snapshot().first { $0.id == queued.id }?.attempts ?? 0) > 0
                }
            } catch {
                XCTFail("could not queue: \(error)")
            }
            let early = await coordinator.sendRoute(for: google.id)
            if case .gmailUnavailable = early {} else { XCTFail("waits for its engine, never SMTP") }
            XCTAssertTrue(relaunched.smtp.accounts.isEmpty, "nothing went by SMTP before the account started")
            await coordinator.prime()
            XCTAssertTrue(TransportGuard.shared.blocks(user: google.email), "held to the Gmail API before any engine starts")
            let sealed = await relaunched.store.isSealed(google.id)
            XCTAssertTrue(sealed)
            let running = await coordinator.assembly(for: google.id)
            XCTAssertNil(running)
        }
        let early = await relaunched.outbox.snapshot().first { $0.subject == "Early" }
        let id = try XCTUnwrap(early?.id)
        try await eventually(timeout: 30, "sent through Gmail") { await relaunched.outbox.snapshot().first { $0.id == id }?.status == .sent }
        XCTAssertEqual((gmail.calls[.messagesSend] ?? 0) - sentBefore, 1)
        XCTAssertTrue(relaunched.smtp.accounts.isEmpty)
        XCTAssertEqual(relaunched.imap.loginCount + earlier.imap.loginCount, 0)
        XCTAssertTrue(relaunched.connector.calls.isEmpty)
    }

    // MARK: - Actions

    func testAnActionForAnAccountWithNoEngineSaysSoInsteadOfSkippingInSilence() async throws {
        let rig = try rig()
        let google = rig.googleAccount()
        rig.gmail(for: google)
        try rig.writePreviousRelease(google)
        try await rig.launch()
        await rig.coordinator.stop(accountID: google.id)
        let request = MailActionRequest(verb: .archive, targets: .items([.message(.gmail(account: google.id, id: GmailMessageID(raw: 1)))]),
                                        context: ListView(scope: .allInboxes))
        do {
            _ = try await rig.coordinator.perform(request, accountID: google.id)
            XCTFail("an account without its engine does nothing in silence")
        } catch {
            XCTAssertEqual(error.localizedDescription, "\(google.email) isn't connected, so this wasn't done.")
        }
    }

    func testNewFolderRulesImportsAndTheArchiveJobGoToTheGmailEngine() async throws {
        let rig = try rig()
        let google = rig.googleAccount()
        let gmail = rig.gmail(for: google)
        gmail.add(subject: "Old invoice", labels: [.inbox], date: Date(timeIntervalSince1970: 1_700_000_000))
        try rig.writePreviousRelease(google)
        try await rig.launch()
        try await rig.backfilled(google)
        let folder = try await rig.coordinator.createFolder(named: "Carriers", in: google)
        XCTAssertEqual(folder?.gmailLabelID.map { gmail.userLabels[$0]?.name }, "Carriers")
        try await rig.coordinator.runRulesOnInbox(google)
        let source = try await rig.coordinator.archiveSource(for: google)
        XCTAssertTrue(source is GmailArchiveSource)
        XCTAssertEqual(rig.imap.loginCount, 0)
        XCTAssertTrue(rig.connector.calls.isEmpty)
    }

    // MARK: - Notifications

    func testANotificationsMessageIsFoundInTheInboxAndItsButtonsActThroughGmail() async throws {
        let rig = try rig()
        let google = rig.googleAccount()
        let gmail = rig.gmail(for: google)
        try rig.writePreviousRelease(google)
        try await rig.launch(undoWindow: 0)
        try await rig.backfilled(google)
        let engine = try await rig.assembly(google).engine
        let arrived = gmail.mailbox.deliver(subject: "Booking confirmed", date: rig.clock.now())
        let report = await engine.check(reason: .schedule)
        let announced = try XCTUnwrap(report.announced.first)
        XCTAssertEqual(announced.subject, "Booking confirmed")
        let target = await rig.coordinator.notificationTarget(messageID: announced.id)
        let inbox = try await rig.folder(.inbox, of: google)
        XCTAssertEqual(target?.inbox.id, inbox.id)
        let receipt = try await rig.coordinator.actOnNotification(.flag, messageID: announced.id)
        XCTAssertNotNil(receipt)
        _ = await engine.flushPending(within: 10)
        XCTAssertTrue(gmail.mailbox.message(arrived.id)?.labels.contains("STARRED") ?? false, "Flag reached Gmail")
        let archived = try await rig.coordinator.actOnNotification(.archive, messageID: announced.id)
        XCTAssertNotNil(archived)
        _ = await engine.flushPending(within: 10)
        XCTAssertEqual(gmail.mailbox.message(arrived.id)?.labels.contains("INBOX"), false, "Archive reached Gmail")

        gmail.delete(GmailMessageID(hex: arrived.id)!)
        _ = await engine.check(reason: .schedule)
        do {
            _ = try await rig.coordinator.actOnNotification(.markRead, messageID: announced.id)
            XCTFail("a message deleted elsewhere is said to be gone")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This message was moved or deleted on another device.")
        }
        let stored = "\(UUID().uuidString):\(UUID().uuidString):12"
        let none = await rig.coordinator.notificationTarget(messageID: stored)
        XCTAssertNil(none, "a stored row's notification stays with the stored rows")
    }

    // MARK: - Sounds

    func testSendAndReceiveOnTheGmailEngineSoundsAsOnIMAP() async throws {
        let rig = try rig()
        let google = rig.googleAccount()
        let gmail = rig.gmail(for: google)
        try rig.writePreviousRelease(google)
        try await rig.launch()
        try await rig.backfilled(google)
        var gate = MailSoundGate(isEnabled: { _ in true })
        // Nothing new: "No new messages", once the account has answered.
        rig.events.clear()
        gate.manualCheckStarted(accounts: [google.id], at: Date())
        await rig.coordinator.checkForNewMail()
        try await eventually(timeout: 20, "the check answers") {
            rig.events.events.contains { if case .checked = $0 { return true } else { return false } }
        }
        let quiet = rig.events.events.compactMap { gate.hear($0, uptime: 100, now: Date()) }
        XCTAssertEqual(quiet, [.noNewMessages])
        // New mail: announced from the Inbox, which plays the new message sound, and no "No new messages".
        rig.events.clear()
        gmail.mailbox.deliver(subject: "Fresh", date: rig.clock.now())
        gate.manualCheckStarted(accounts: [google.id], at: Date())
        await rig.coordinator.checkForNewMail()
        try await eventually(timeout: 20, "the check answers") {
            rig.events.events.contains { if case .checked = $0 { return true } else { return false } }
        }
        XCTAssertEqual(rig.events.announcedSubjects, ["Fresh"])
        let sounds = rig.events.events.compactMap { gate.hear($0, uptime: 200, now: Date()) }
        XCTAssertTrue(sounds.isEmpty, "the new message sound follows the announcement, and nothing says there is none")
        let inbox = try await rig.folder(.inbox, of: google)
        for case .newMessages(let account, let folder, _) in rig.events.events {
            XCTAssertEqual(account, google.id)
            XCTAssertEqual(folder, inbox.id)
        }
    }

    // MARK: - Drafts

    func testADraftSavedOverIMAPBeforeTheSwitchIsUpdatedNotAddedAgain() async throws {
        let rig = try rig()
        let google = rig.googleAccount()
        let gmail = rig.gmail(for: google)
        // v1.10 saved this draft over IMAP; Gmail keeps it as a draft with that Message-ID.
        let raw = Data("From: \(google.email)\r\nTo: ben@example.com\r\nSubject: Quote\r\nMessage-ID: <old-draft@freight.example>\r\n\r\nFirst version\r\n".utf8)
        let old = try await gmail.createDraft(raw, threadID: nil, work: .interactive)
        try rig.writePreviousRelease(google)
        try await rig.launch()
        try await rig.backfilled(google)
        let assembly = try await rig.assembly(google)
        var row = MessageSummary(accountID: google.id, folderID: UUID(), uid: 7, messageID: "<old-draft@freight.example>", inReplyTo: "",
                                 references: [], subject: "Quote", from: EmailAddress(address: google.email), to: [], cc: [], date: Date(),
                                 flags: [.draft, .seen], size: 100, hasAttachments: false)
        row.threadKey = "old-draft"
        let localID = UUID()
        let ref = await GmailDraftLinking.ref(localID: localID, accountID: google.id, email: google.email, threadID: nil, reopenedFrom: row,
                                              drafts: assembly.drafts)
        XCTAssertEqual(ref.gmailDraftID, old.id, "found by its Message-ID")
        XCTAssertEqual(ref.stableMessageID, "<old-draft@freight.example>")
        let second = Data("From: \(google.email)\r\nTo: ben@example.com\r\nSubject: Quote\r\n\r\nSecond version\r\n".utf8)
        let saved = try await assembly.drafts.save(second, as: ref)
        XCTAssertEqual(saved.gmailDraftID, old.id)
        XCTAssertEqual(gmail.draftIDs.count, 1, "one draft, updated, not a second beside it")
        XCTAssertEqual(gmail.calls[.draftsUpdate], 1)
        XCTAssertNil(gmail.calls[.draftsCreate].flatMap { $0 > 1 ? $0 : nil })
        // A new message gets one Message-ID for every save.
        let fresh = await GmailDraftLinking.ref(localID: UUID(), accountID: google.id, email: google.email, threadID: nil, reopenedFrom: nil,
                                                drafts: assembly.drafts)
        XCTAssertNil(fresh.gmailDraftID)
        XCTAssertTrue(fresh.stableMessageID.hasSuffix("@\(google.email.split(separator: "@").last!)>"))
    }

    // MARK: - Spotlight

    func testSpotlightHoldsOnlyTheMessagesKeptOnTheMac() async throws {
        let rig = try rig(fillsCache: true)
        let google = rig.googleAccount()
        let gmail = rig.gmail(for: google)
        for i in 0..<30 { gmail.add(subject: "Kept \(i)", labels: [.inbox], date: Date(timeIntervalSince1970: 1_789_000_000 + Double(i))) }
        let previous = try rig.writePreviousRelease(google)
        // v1.10 indexed the IMAP store's rows.
        await rig.indexer.index(previous.rows.map { row in
            MessageSummary(accountID: google.id, folderID: row.folderID, uid: row.uid, messageID: row.messageID, inReplyTo: "", references: [],
                           subject: row.subject, from: EmailAddress(address: row.from.address), to: [], cc: [], date: row.date, flags: [],
                           size: row.size, hasAttachments: false)
        })
        try await rig.launch()
        try await rig.backfilled(google)
        let assembly = try await rig.assembly(google)
        try await eventually(timeout: 30, "the newest are kept") { await assembly.store.cachedIDs().count == 30 }
        let kept = await assembly.store.cachedIDs()
        let expected = Set(kept.map { RowKey.gmail(account: google.id, id: $0).stringValue })
        try await eventually(timeout: 30, "Spotlight follows them") { await rig.indexer.entries(for: google.id) == expected }
        let entries = await rig.indexer.entries(for: google.id)
        XCTAssertFalse(entries.contains { !$0.contains(":gm:") }, "none of the IMAP store's rows is left")
    }
}
