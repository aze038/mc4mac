import XCTest
@testable import FalconCore

/// The mailbox window's whole round for a Google account on the Gmail API, put together as the
/// app puts it: the coordinator and the Outbox over the in-memory Gmail, and the message table's
/// controller over the list the app reads the account's folders from (`AppModel.listSource`).
///
/// Every message of the Inbox is in the list at once, a row grey until its text arrives with its
/// unread dot already right; a message opens; Archive takes its row out, the next row is where
/// the selection goes, and Undo brings it back; a reply goes by Gmail's own send into the
/// conversation it answers; a draft is saved, saved again, discarded with Undo and discarded;
/// new mail is announced from the Inbox with the new message sound, and its notification finds
/// its row; Send & Receive with nothing new says so; turning the switch off takes the account to
/// IMAP, and turning it back on returns it to the Gmail API with its list as it was. Nothing goes by SMTP, and no IMAP
/// connection is asked for while the account is on the Gmail API.
@MainActor
final class AppFlowTests: XCTestCase {
    private var rigs: [CoordinatorRig] = []

    override func tearDown() async throws {
        for rig in rigs { await rig.finish() }
        rigs = []
    }

    private let longAgo = Date(timeIntervalSince1970: 1_700_000_000)

    private func checked(_ rig: CoordinatorRig) -> Bool {
        rig.events.events.contains { if case .checked = $0 { return true } else { return false } }
    }

    // swiftlint:disable:next function_body_length
    func testAGoogleAccountOnTheGmailAPIThroughTheMailboxWindowsWholeRound() async throws {
        let rig = try CoordinatorRig()
        rigs.append(rig)
        let account = rig.googleAccount()
        let gmail = rig.gmail(for: account)
        let older = 120
        for i in 0..<older {
            gmail.add(subject: "Order \(i)", labels: i % 4 == 0 ? [.inbox, .unread] : [.inbox], date: longAgo.addingTimeInterval(Double(i) * 3_600))
        }
        let rates = gmail.add(subject: "Rates for November", labels: [.inbox, .unread], date: longAgo.addingTimeInterval(1_000_000))
        try rig.writePreviousRelease(account)
        let digest = rig.imapStoreDigest(account)
        try await rig.launch(undoWindow: 30)
        try await rig.backfilled(account)
        let assembly = try await rig.assembly(account)
        let inbox = try await rig.folder(.inbox, of: account)
        func key(_ id: GmailMessageID) -> RowKey { .gmail(account: account.id, id: id) }
        func request(_ verb: MailActionRequest.Verb, _ row: RowKey, in view: ListView) -> MailActionRequest {
            MailActionRequest(verb: verb, targets: .items([.message(row)]), context: view)
        }

        // The table shows the Inbox from the account's engine: every message at once, newest
        // first, grey rows with their unread dot, filling in once they scroll into view.
        let list = ListController()
        let inboxView = ListView(scope: .folder(inbox.id), conversations: false)
        await list.show(inboxView, from: assembly.list)
        XCTAssertEqual(list.itemCount, older + 1, "every message of the Inbox is in the list")
        XCTAssertEqual(list.rowCount, older + 1)
        XCTAssertEqual(list.key(at: 0), key(rates.id), "newest first")
        XCTAssertNil(list.rowContent(at: 0), "a row not seen yet is grey")
        XCTAssertGreaterThan(list.record(at: 0)?.unread ?? 0, 0, "with its unread dot already right")
        list.scrolled(visible: 0..<25)
        try await eventually(timeout: 20, "the first screen fills in") { (0..<25).allSatisfy { list.rowContent(at: $0) != nil } }
        XCTAssertEqual(list.rowContent(at: 0)?.subject, "Rates for November")
        XCTAssertNil(list.rowContent(at: older), "a row far below is not fetched until it is seen")

        // Opening it: its details, as the reading pane and a window read them, then its text.
        guard case .available(let original) = await assembly.list.summary(for: key(rates.id), in: inboxView) else {
            return XCTFail("the selected row is read")
        }
        XCTAssertEqual(original.subject, "Rates for November")
        XCTAssertEqual(original.gmailThreadID, rates.threadID)
        var stages: [OpenedMessage] = []
        for try await stage in await assembly.engine.open(key(rates.id), purpose: .window) { stages.append(stage) }
        XCTAssertEqual(stages.last?.content.message.textPlain?.trimmingCharacters(in: .whitespacesAndNewlines), "Hello")
        _ = try await rig.coordinator.perform(request(.markRead, key(rates.id), in: inboxView), accountID: account.id)
        try await eventually(timeout: 20, "reading it marks the row read") { list.record(at: 0)?.unread == 0 }

        // Archive from the table, with the next row selected as the row leaves, and Undo.
        var applied: [(change: ListControllerChange, before: ListSelection)] = []
        list.onApplied = { applied.append(($0, $1)) }
        list.select(rows: [1])
        let second = try XCTUnwrap(list.key(at: 1))
        let third = try XCTUnwrap(list.key(at: 2))
        let archived = try await rig.coordinator.perform(request(.archive, second, in: inboxView), accountID: account.id)
        XCTAssertNotNil(archived.heldUntil, "held for its undo window")
        try await eventually(timeout: 20, "the row leaves the list") { list.itemCount == older }
        XCTAssertFalse((0..<list.rowCount).contains { list.key(at: $0) == second })
        let removal = applied.compactMap { entry -> (ListDiff, ListSelection)? in
            if case .diff(let diff) = entry.change, !diff.removed.isEmpty { return (diff, entry.before) }
            return nil
        }.last
        let (diff, before) = try XCTUnwrap(removal, "the table is told which rows left, with the selection before")
        XCTAssertEqual(before, ListSelection(rows: [1]))
        let next = try XCTUnwrap(ListAdvance.row(selected: [1], removed: diff.removed, in: list.snapshot, forward: true))
        XCTAssertEqual(list.key(at: next), third, "the next row takes the selection")
        let undone = await rig.coordinator.undo(archived.id, accountID: account.id)
        XCTAssertTrue(undone)
        try await eventually(timeout: 20, "Undo brings the row back") { list.itemCount == older + 1 && list.key(at: 1) == second }
        XCTAssertEqual(gmail.message(try XCTUnwrap(second.gmailID))?.labels.contains(.inbox), true, "Gmail never had the archive")
        _ = try await rig.coordinator.perform(request(.archive, second, in: inboxView), accountID: account.id)
        let flushed = await assembly.engine.flushPending(within: 20)
        XCTAssertTrue(flushed)
        XCTAssertEqual(gmail.message(try XCTUnwrap(second.gmailID))?.labels.contains(.inbox), false, "archived on Gmail")
        try await eventually(timeout: 20, "and gone from the list") { list.itemCount == older }

        // A reply goes by Gmail's own send, in the conversation it answers.
        var reply = OutgoingMessage(from: EmailAddress(name: "Owner", address: account.email), to: [original.from],
                                    subject: "Re: Rates for November", textBody: "Thanks, agreed.")
        if !original.messageID.isEmpty {
            reply.inReplyTo = original.messageID
            reply.references = [original.messageID]
        }
        let queued = try await rig.outbox.enqueue(accountID: account.id, from: account.email, message: reply,
                                                  gmailThreadID: original.gmailThreadID)
        try await eventually(timeout: 20, "the reply is sent") { await rig.outbox.snapshot().first { $0.id == queued.id }?.status == .sent }
        let sent = try XCTUnwrap(gmail.mailbox.messages.first { $0.subject == "Re: Rates for November" })
        XCTAssertEqual(sent.threadID, rates.threadID.hex, "in the conversation it answers")
        XCTAssertTrue(sent.labels.contains("SENT"))
        XCTAssertGreaterThan(gmail.attempts[.messagesSend] ?? 0, 0)

        // A draft saved, saved again as the same draft, discarded with Undo, and discarded.
        let localID = UUID()
        let ref = DraftRef(localID: localID, accountID: account.id,
                           stableMessageID: GmailDraftLinking.stableMessageID(for: localID, email: account.email))
        var draft = OutgoingMessage(from: EmailAddress(name: "Owner", address: account.email), to: [EmailAddress(address: "ben@example.com")],
                                    subject: "Quote for December", textBody: "First words.")
        let draftsBefore = gmail.draftIDs.count
        let saved = try await assembly.drafts.save(MIMEBuilder.build(draft), as: ref)
        let draftID = try XCTUnwrap(saved.gmailDraftID)
        draft.textBody = "First words, and more."
        _ = try await assembly.drafts.save(MIMEBuilder.build(draft), as: saved)
        XCTAssertEqual(gmail.draftIDs.count, draftsBefore + 1, "saved again, it is still one draft")
        XCTAssertNotNil(gmail.draftIDs[draftID])
        await assembly.drafts.discard(saved, undoWindow: 30)
        let kept = await assembly.drafts.undoDiscard(localID)
        XCTAssertEqual(kept?.gmailDraftID, draftID, "Undo keeps Gmail's copy, still linked")
        await assembly.drafts.discard(saved, undoWindow: 0)
        try await eventually(timeout: 20, "the discarded draft is deleted") { gmail.draftIDs[draftID] == nil }

        // New mail: announced from the Inbox with the new message sound, at the top of the list,
        // and its notification finds its row.
        var gate = MailSoundGate(isEnabled: { _ in true })
        rig.events.clear()
        let fresh = gmail.mailbox.deliver(subject: "New order 4471", date: rig.clock.now())
        let freshKey = key(try XCTUnwrap(GmailMessageID(hex: fresh.id)))
        gate.manualCheckStarted(accounts: [account.id], at: Date())
        await rig.coordinator.checkForNewMail()
        try await eventually(timeout: 20, "the new mail is announced") { rig.events.announcedSubjects.contains("New order 4471") }
        try await eventually(timeout: 20, "the check answers") { self.checked(rig) }
        for case .newMessages(let id, let folderID, _) in rig.events.events {
            XCTAssertEqual(id, account.id)
            XCTAssertEqual(folderID, inbox.id, "from the Inbox, which a notification is for")
        }
        XCTAssertEqual(gate.newMailArrived(), .newMessage)
        let heard = rig.events.events.compactMap { gate.hear($0, uptime: 100, now: Date()) }
        XCTAssertFalse(heard.contains(.noNewMessages), "nothing says there is no new mail")
        try await eventually(timeout: 20, "the new mail heads the list") { list.key(at: 0) == freshKey }
        let target = await rig.coordinator.notificationTarget(messageID: freshKey.stringValue)
        XCTAssertEqual(target?.inbox.id, inbox.id)
        XCTAssertEqual(target?.key, freshKey)
        XCTAssertTrue((0..<list.rowCount).contains { list.key(at: $0) == target?.key }, "the notification's click finds its row")

        // Send & Receive with nothing new.
        rig.events.clear()
        gate.manualCheckStarted(accounts: [account.id], at: Date())
        await rig.coordinator.checkForNewMail()
        try await eventually(timeout: 20, "the check answers") { self.checked(rig) }
        let quiet = rig.events.events.compactMap { gate.hear($0, uptime: 200, now: Date()) }
        XCTAssertEqual(quiet, [.noNewMessages])

        // Nothing went by IMAP or SMTP, and the account's IMAP store is as v1.10 left it.
        XCTAssertEqual(rig.imap.loginCount, 0)
        XCTAssertTrue(rig.connector.calls.isEmpty)
        XCTAssertTrue(rig.smtp.accounts.isEmpty)
        XCTAssertEqual(rig.imapStoreDigest(account), digest)

        // The switch off: the account goes to IMAP, its Gmail files kept; back on: the Gmail API
        // again, carrying on from those files with the list as it was.
        list.stop()
        let items = older + 1
        let off = await rig.coordinator.setGmailEngine(false, for: account)
        XCTAssertNil(off)
        let onGmailAfterOff = await rig.coordinator.usesGmail(account.id)
        XCTAssertFalse(onGmailAfterOff)
        let rosterOff = await rig.coordinator.roster
        XCTAssertNil(rosterOff.running[account.id], "the app's list reads the stored rows again")
        try await eventually(timeout: 20, "IMAP takes the account again") { rig.imap.loginCount > 0 }
        let on = await rig.coordinator.setGmailEngine(true, for: account)
        XCTAssertNil(on)
        let onGmail = await rig.coordinator.usesGmail(account.id)
        XCTAssertTrue(onGmail)
        let back = try await rig.assembly(account)
        XCTAssertFalse(back.engine === assembly.engine, "a new engine")
        try await rig.backfilled(account)
        let again = ListController()
        await again.show(inboxView, from: back.list)
        XCTAssertEqual(again.itemCount, items, "the same Inbox, from the files kept")
        XCTAssertEqual(again.key(at: 0), freshKey)
        again.stop()
        XCTAssertTrue(rig.smtp.accounts.isEmpty, "and nothing ever went by SMTP")
    }
}
