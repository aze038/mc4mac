import XCTest
@testable import FalconCore

/// A switched Google account from end to end, as the app will put it together: every work item's
/// part over the real transport and budget, the real store on disk, and the in-memory Gmail over
/// HTTP. Nothing here opens an IMAP or SMTP connection.
final class GmailEngineEndToEndTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("falcon-gmail-e2e-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Log.start(in: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    /// One account with everything installed, and what the test watches it by.
    private struct Account {
        let gmail: FakeGmail
        let assembly: GmailAccountAssembly
        let clock: ManualGmailClock
        let events: GmailEventRecorder
        let smtp: CountingSender
        let outbox: Outbox
        let layout: FileLayout

        var engine: GmailAccountEngine { assembly.engine }
        var mailbox: FakeGmailMailbox { gmail.mailbox }

        func folder(_ role: FolderRole) async throws -> FolderInfo {
            let folders = await engine.folders()
            return try XCTUnwrap(folders.first { $0.role == role })
        }

        func key(_ id: GmailMessageID) -> RowKey { .gmail(account: gmail.accountID, id: id) }
    }

    private func account(_ mailbox: FakeGmailMailbox, now: Date, accountID: UUID = UUID()) async -> Account {
        let gmail = FakeGmail(email: mailbox.email, accountID: accountID, mailbox: mailbox)
        let layout = FileLayout(root: root)
        let clock = ManualGmailClock(now)
        let events = GmailEventRecorder()
        let store = GmailFileStore(accountID: gmail.accountID, files: GmailFiles(layout: layout, accountID: gmail.accountID))
        var settings = GmailEngineSettings()
        // The newest 1,000 fill in the background in the app; here what is on the Mac stays what
        // the steps below put there, so each step's cost can be read.
        settings.fillsCache = false
        let actionClock = GmailActionClock(now: { clock.now() }, sleep: { seconds in
            try await Task.sleep(nanoseconds: UInt64(min(max(seconds, 0), 0.02) * 1_000_000_000))
        })
        let info = AccountInfo(id: gmail.accountID, email: mailbox.email, displayName: "Owner", authMethod: "oauth")
        let assembly = await GmailAccountAssembly(account: info, transport: gmail, store: store, mutes: MuteStore(layout: layout),
                                            rules: RuleStore(layout: layout), settings: settings, clock: clock, actionClock: actionClock,
                                            undoWindow: 5, events: { events.record($0) })
        let smtp = CountingSender()
        let accountID = gmail.accountID
        let sender = assembly.sender
        let outbox = Outbox(layout: layout, sender: RoutingSender(smtp: smtp, route: { id in id == accountID ? .gmail(sender) : .smtp }),
                            undoWindow: 0, confirmAfter: [0.05, 0.15], retryDelay: { _ in 0 })
        return Account(gmail: gmail, assembly: assembly, clock: clock, events: events, smtp: smtp, outbox: outbox, layout: layout)
    }

    // swiftlint:disable:next function_body_length
    func testA55kMailboxIsListedReadChangedRepliedToAndKeptUpWithOverTheGmailAPIAlone() async throws {
        let connections = StreamConnection.connectionsOpened
        let newest = Date(timeIntervalSince1970: 1_790_000_000)
        let a = await account(FakeGmailMailbox.typical55k(now: { newest }), now: newest.addingTimeInterval(120))

        // 1. Started as the app starts it, and backfilled: every message listed, within the
        // design's units for 55,000. The clock stands still, so the loop's own checks wait for it.
        await a.engine.start()
        try await eventually(timeout: 120, "every message listed") { await a.engine.state.backfill?.phase == .complete }
        let index = await a.assembly.store.index()
        XCTAssertEqual(index.byOrder.count, 55_000, "every message has its place")
        XCTAssertLessThanOrEqual(a.gmail.units[.messagesList] ?? 0, 1_500, "listing 55,000 stays within §14.6")
        let first = await a.engine.check(reason: .schedule)
        XCTAssertNil(first.failure)

        // 2. Listed: the Inbox's Items is its real total, and its first screen fills in.
        let inbox = try await a.folder(.inbox)
        let inboxCount = a.mailbox.messages.filter { $0.labels.contains("INBOX") && !$0.labels.contains("SPAM") && !$0.labels.contains("TRASH") }.count
        let view = ListView(scope: .folder(inbox.id), conversations: false)
        let listed = await a.assembly.list.snapshot(of: view)
        XCTAssertTrue(listed.complete)
        XCTAssertEqual(listed.itemCount, inboxCount)
        XCTAssertEqual(listed.rows.count, inboxCount)
        let screen = (0..<25).compactMap { listed.rowKey(at: $0) }
        XCTAssertEqual(screen.count, 25)
        var rows: [RowKey: MessageRowContent] = [:]
        let arriving = a.assembly.list.rows
        a.assembly.list.requestRows(screen, priority: .visible)
        for await batch in arriving {
            rows.merge(batch) { _, new in new }
            if screen.allSatisfy({ rows[$0] != nil }) { break }
        }
        XCTAssertTrue(screen.allSatisfy { rows[$0]?.subject.isEmpty == false }, "every row of the first screen has its text")

        // 3. A message opened: its text from Gmail, once.
        let opened = try XCTUnwrap(screen[3].gmailID)
        let gets = a.gmail.calls[.messagesGet] ?? 0
        var stages: [OpenedMessage] = []
        for try await stage in await a.engine.open(a.key(opened), purpose: .window) { stages.append(stage) }
        let text = try XCTUnwrap(stages.last?.content.message.bestText)
        XCTAssertTrue(text.contains("Text of fixture message \(opened.hex)"), text)
        XCTAssertEqual((a.gmail.calls[.messagesGet] ?? 0) - gets, 1, "one format=full")

        // 4. Archived, undone within the window with nothing sent, then archived for good.
        let archived = try XCTUnwrap(screen[5].gmailID)
        let archive = MailActionRequest(verb: .archive, targets: .items([.message(a.key(archived))]), context: view)
        let receipt = try await a.engine.perform(archive)
        let shown = await a.assembly.store.labels(of: archived)
        XCTAssertEqual(shown?.contains(.inbox), false, "the row leaves the Inbox at once")
        let undone = await a.engine.undo(receipt.id)
        XCTAssertTrue(undone)
        let back = await a.assembly.store.labels(of: archived)
        XCTAssertEqual(back?.contains(.inbox), true)
        XCTAssertNil(a.gmail.attempts[.messagesModify], "undone within the window, nothing was sent")
        _ = try await a.engine.perform(MailActionRequest(verb: .archive, targets: .items([.message(a.key(archived))]), context: view))
        let flushed = await a.engine.flushPending(within: 10)
        XCTAssertTrue(flushed)
        XCTAssertEqual(a.mailbox.message(archived.hex)?.labels.contains("INBOX"), false, "Gmail has the archive")
        _ = await a.engine.check(reason: .schedule)
        let afterEcho = await a.assembly.store.labels(of: archived)
        XCTAssertEqual(afterEcho?.contains(.inbox), false, "its echo changes nothing")

        // 5. A reply sent through Gmail's own send, into its conversation, and in Sent at once.
        let original = try XCTUnwrap(a.mailbox.message(opened.hex))
        let reply = OutgoingMessage(from: EmailAddress(name: "Owner", address: a.mailbox.email), to: [EmailAddress(address: "ana@example.com")],
                                    subject: "Re: \(original.subject)", textBody: "Thank you, agreed.", inReplyTo: original.messageID,
                                    references: [original.messageID])
        let sentBefore = try await a.folder(.sent).totalCount
        let queued = try await a.outbox.enqueue(accountID: a.gmail.accountID, from: a.mailbox.email, message: reply,
                                                gmailThreadID: GmailThreadID(hex: original.threadID))
        try await eventually(timeout: 20, "the reply is sent") { await a.outbox.snapshot().first { $0.id == queued.id }?.status == .sent }
        let item = await a.outbox.snapshot().first { $0.id == queued.id }
        let sentID = try XCTUnwrap(item?.gmailSentID)
        let sent = try XCTUnwrap(a.mailbox.message(sentID.hex))
        XCTAssertEqual(sent.threadID, original.threadID, "the reply is in its conversation")
        XCTAssertTrue(sent.labels.contains("SENT"))
        let placed = await a.assembly.store.labels(of: sentID)
        XCTAssertEqual(placed?.contains(.sent), true, "the Sent row is in the index from Gmail's answer")
        let sentAfter = try await a.folder(.sent).totalCount
        XCTAssertEqual(sentAfter, sentBefore + 1)
        XCTAssertTrue(a.smtp.accounts.isEmpty, "nothing went by SMTP")

        // 6. A draft saved to Gmail, then discarded.
        let draftsBefore = try await a.folder(.drafts).totalCount
        let draftMessage = OutgoingMessage(from: EmailAddress(name: "Owner", address: a.mailbox.email),
                                           to: [EmailAddress(address: "ben@example.com")], subject: "Rates for November",
                                           textBody: "Draft of the rates.")
        let ref = DraftRef(localID: UUID(), accountID: a.gmail.accountID, stableMessageID: "<draft-rates@falconmail.test>")
        let saved = try await a.engine.saveDraft(MIMEBuilder.build(draftMessage), as: ref)
        let draftID = try XCTUnwrap(saved.gmailDraftID)
        XCTAssertNotNil(a.gmail.draftIDs[draftID], "Gmail has the draft")
        let draftsSaved = try await a.folder(.drafts).totalCount
        XCTAssertEqual(draftsSaved, draftsBefore + 1, "and Drafts shows it at once")
        await a.assembly.drafts.discard(saved, undoWindow: 0)
        try await eventually(timeout: 10, "the discarded draft is deleted on Gmail") { a.gmail.draftIDs[draftID] == nil }
        try await eventually(timeout: 10, "and leaves Drafts") { (try? await a.folder(.drafts).totalCount) == draftsBefore }

        // 7. A check picks up new mail, announces it, and the list shows it.
        let itemsBefore = await a.assembly.list.snapshot(of: view).itemCount
        let arrived = a.mailbox.deliver(subject: "New order 4471", from: "Supplier <orders@supplier.example>", date: a.clock.now())
        let report = await a.engine.check(reason: .schedule)
        XCTAssertNil(report.failure)
        XCTAssertEqual(report.announced.map(\.subject), ["New order 4471"])
        XCTAssertTrue(a.events.announcedSubjects.contains("New order 4471"))
        try await eventually(timeout: 10, "the new mail is in the list") {
            let now = await a.assembly.list.snapshot(of: view)
            return now.itemCount == itemsBefore + 1 && now.rowKey(at: 0)?.gmailID == GmailMessageID(hex: arrived.id)
        }

        // 8. Not one IMAP or SMTP connection.
        XCTAssertEqual(StreamConnection.connectionsOpened, connections, "no IMAP or SMTP connection was opened")
        XCTAssertTrue(a.smtp.accounts.isEmpty)
        let units = a.gmail.totalUnits
        print("end to end: \(units) units, \(a.gmail.calls.values.reduce(0, +)) calls")
        await a.engine.stop()
    }

    /// Relaunched over the same files, the account carries on from its index and cursor: nothing
    /// is listed again, and a change made while it was away arrives with the next check.
    func testARelaunchCarriesOnFromTheStoreWithoutListingAgain() async throws {
        let newest = Date(timeIntervalSince1970: 1_790_000_000)
        let mailbox = FakeGmailMailbox.fixture(FakeGmailMailbox.FixtureSpec.typical55k.scaled(to: 2_000), now: { newest })
        let accountID = UUID()
        let first = await account(mailbox, now: newest.addingTimeInterval(120), accountID: accountID)
        await first.engine.runBackfill()
        _ = await first.engine.check(reason: .schedule)
        await first.engine.stop()
        let listed = first.gmail.calls[.messagesList] ?? 0

        let starred = try XCTUnwrap(mailbox.messages.first { $0.labels.contains("INBOX") })
        mailbox.relabel(starred.id, adding: ["STARRED"])
        let again = await account(mailbox, now: newest.addingTimeInterval(600), accountID: accountID)
        let report = await again.engine.check(reason: .wake)
        XCTAssertNil(report.failure)
        XCTAssertFalse(report.skipped, "the cursor was read back")
        XCTAssertEqual((again.gmail.calls[.messagesList] ?? 0) - listed, 0, "the index and cursor were read back, so nothing is listed")
        XCTAssertGreaterThan(listed, 0)
        let labels = await again.assembly.store.labels(of: try XCTUnwrap(GmailMessageID(hex: starred.id)))
        XCTAssertEqual(labels?.contains(.starred), true, "the change made meanwhile arrived by the history")
        let count = await again.assembly.store.index().byOrder.count
        XCTAssertEqual(count, 2_000)
        await again.engine.stop()
    }

    /// Search and an import through `MailAccountEngine`, as the app's search field and File ▸
    /// Import use every account: the hits are the index's own rows, and an import is placed among
    /// old mail and never announced.
    func testSearchAndAnImportGoThroughTheEngine() async throws {
        let newest = Date(timeIntervalSince1970: 1_790_000_000)
        let mailbox = FakeGmailMailbox.fixture(FakeGmailMailbox.FixtureSpec.typical55k.scaled(to: 2_000), now: { newest })
        let wanted = mailbox.add(subject: "Invoice ZX-9 for October", labels: ["INBOX"], date: newest.addingTimeInterval(-40 * 86_400))
        let a = await account(mailbox, now: newest.addingTimeInterval(120))
        await a.engine.start()
        try await eventually(timeout: 60, "every message listed") { await a.engine.state.backfill?.phase == .complete }

        let search = UUID()
        try await a.engine.search("ZX-9", id: search, fetchRows: true)
        let hits = await a.assembly.list.snapshot(of: ListView(scope: .search(search), conversations: false))
        XCTAssertEqual(hits.rows.count, 1)
        XCTAssertEqual(hits.rowKey(at: 0)?.gmailID, GmailMessageID(hex: wanted.id), "the hit is the index's own row, which every action works on")
        await a.engine.endSearch(search)

        let inbox = try await a.folder(.inbox)
        let old = newest.addingTimeInterval(-400 * 86_400)
        let eml = MIMEBuilder.build(OutgoingMessage(from: EmailAddress(name: "Shop", address: "shop@example.com"),
                                                    to: [EmailAddress(address: mailbox.email)], subject: "Receipt from 2025",
                                                    textBody: "Thank you for your order.", date: old))
        let progress = SleepLog()
        try await a.engine.importMessages([ImportedMessage(raw: eml, flags: [.seen], date: old)], into: inbox.id) { progress.append(TimeInterval($0)) }
        XCTAssertEqual(progress.all, [1])
        let imported = try XCTUnwrap(a.mailbox.messages.first { $0.subject == "Receipt from 2025" })
        XCTAssertTrue(imported.labels.contains("INBOX"))
        let id = try XCTUnwrap(GmailMessageID(hex: imported.id))
        let record = await a.assembly.store.record(for: id)
        XCTAssertNotNil(record, "placed from Gmail's answer at once")
        let wasImported = await a.assembly.store.wasImported(id)
        XCTAssertTrue(wasImported)
        let placed = await a.assembly.store.index()
        XCTAssertNotEqual(placed.byOrder.last, placed.slotByID[id.raw], "among old mail, not at the top")
        let report = await a.engine.check(reason: .schedule)
        XCTAssertTrue(report.announced.isEmpty, "its echo is never new mail")
        XCTAssertFalse(report.floodBegan)
        await a.engine.stop()
    }

    /// A Mac whose clock is an hour fast still announces new mail: the transport reads Gmail's
    /// time from the Date header of its answers, and the engine decides what is new by it (§4.3).
    /// By the Mac's clock alone, mail Gmail received now would look an hour old.
    func testNewMailIsJudgedByGmailsClockWhenTheMacsIsWrong() async throws {
        let now = Date()
        let mailbox = FakeGmailMailbox.fixture(FakeGmailMailbox.FixtureSpec.typical55k.scaled(to: 500),
                                               newest: now.addingTimeInterval(-7_200), now: { now })
        mailbox.serverClockSkew = -3_600
        let a = await account(mailbox, now: now)
        await a.engine.runBackfill()
        _ = await a.engine.check(reason: .schedule)
        let offset = await a.gmail.gmailClockOffset()
        XCTAssertEqual(offset ?? 0, -3_600, accuracy: 5, "an hour, from the Date header")
        mailbox.deliver(subject: "Received just now", date: now.addingTimeInterval(-3_600))
        let report = await a.engine.check(reason: .schedule)
        XCTAssertEqual(report.announced.map(\.subject), ["Received just now"])
        await a.engine.stop()
    }

    /// The Has attachments filter and the Size sort ask the engine, once, for the listings that
    /// fill every message's attachment bit and size band.
    func testTheListAsksOnceForAttachmentsAndSizesAndTheirBitsFillIn() async throws {
        let newest = Date(timeIntervalSince1970: 1_790_000_000)
        let mailbox = FakeGmailMailbox.fixture(FakeGmailMailbox.FixtureSpec.typical55k.scaled(to: 300), now: { newest })
        let withFile = mailbox.add(subject: "Rates attached", labels: ["INBOX"], date: newest.addingTimeInterval(-86_400),
                                   attachments: [FakeGmailMailbox.Attachment(filename: "rates.pdf", mimeType: "application/pdf",
                                                                             data: Data(count: 2_000_000))])
        let a = await account(mailbox, now: newest.addingTimeInterval(120))
        await a.engine.runBackfill()
        let inbox = try await a.folder(.inbox)
        let filtered = ListView(scope: .folder(inbox.id), filters: [.attachments], conversations: false)
        let before = await a.assembly.list.snapshot(of: filtered)
        XCTAssertFalse(before.complete, "not known yet for every message")
        try await eventually(timeout: 10, "the engine is asked") { await !a.engine.viewListingsWanted.isEmpty }
        await a.engine.maintenance(at: a.clock.now())
        await a.engine.relistTask?.value
        let state = await a.engine.listingState()
        XCTAssertTrue(state.attachmentsKnown)
        let id = try XCTUnwrap(GmailMessageID(hex: withFile.id))
        let record = await a.assembly.store.record(for: id)
        XCTAssertEqual(record?.attributes.contains(.hasAttachment), true)
        try await eventually(timeout: 10, "the filtered view is complete") {
            let now = await a.assembly.list.snapshot(of: filtered)
            return now.complete && now.rows.contains { $0.key == id.raw }
        }
        let sized = ListView(scope: .folder(inbox.id), sort: ListSortSpec(key: .size, ascending: false), conversations: false)
        _ = await a.assembly.list.snapshot(of: sized)
        try await eventually(timeout: 10, "the engine is asked for sizes") { await a.engine.viewListingsWanted.contains(.sizes) }
        await a.engine.maintenance(at: a.clock.now())
        await a.engine.relistTask?.value
        let sizes = await a.engine.listingState()
        XCTAssertTrue(sizes.sizesKnown)
        let band = await a.assembly.store.record(for: id)?.attributes
        XCTAssertEqual(band?.contains(.sizeKnown), true)
        XCTAssertEqual(band?.sizeBand, .large, "2 MB is in the band from 1 MB")
        let lists = a.gmail.calls[.messagesList] ?? 0
        _ = await a.assembly.list.snapshot(of: sized)
        _ = await a.assembly.list.snapshot(of: filtered)
        await a.engine.maintenance(at: a.clock.now())
        await a.engine.relistTask?.value
        XCTAssertEqual(a.gmail.calls[.messagesList] ?? 0, lists, "asked once only")
        await a.engine.stop()
    }
}
