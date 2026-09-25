import XCTest
@testable import FalconCore

/// The first load (§3): its steps in order, its units against the design's table for the three
/// fixtures, resuming after a stop, a listing that skips a message, the sidebar's folders, the
/// newest 1,000 and date anchors.
final class GmailBackfillTests: XCTestCase {
    private let day: TimeInterval = 86_400

    private func listingOnly() -> GmailEngineSettings {
        var settings = GmailEngineSettings()
        settings.fillsCache = false
        return settings
    }

    // MARK: - The steps

    func testTheStepsComeInOrder() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let start = clock.now()
        var refs: [GmailRef] = []
        for i in 0..<40 {
            // Every fifth message is a reply in the conversation of the one before it.
            let thread = i % 5 == 4 ? refs.last?.threadID : nil
            refs.append(gmail.add(subject: "Mail \(i)", labels: [.inbox, .unread], date: start.addingTimeInterval(-Double(40 - i) * 3600),
                                  thread: thread))
        }
        let rig = GmailEngineRig(transport: gmail, clock: clock, settings: listingOnly())
        let rows = await rig.engine.rowUpdates()
        let startHistory = gmail.historyID
        await rig.engine.runBackfill()
        let phase = await rig.engine.state.backfill?.phase
        XCTAssertEqual(phase, .complete)

        let trace = rig.transport.trace
        XCTAssertEqual(Array(trace.prefix(2)), ["profile", "labelsList"], "step 0: the profile, with the base history id, and the labels")
        let firstScreen = try XCTUnwrap(trace.firstIndex { $0 == "threadsGet" || $0 == "messagesGet" })
        let inboxPage = try XCTUnwrap(trace.firstIndex(of: "list:INBOX:100"))
        let counts = try XCTUnwrap(trace.firstIndex(of: "labelsGet"))
        let firstChain = try XCTUnwrap(trace.firstIndex { $0.hasSuffix(":500") })
        XCTAssertLessThan(inboxPage, firstScreen, "step 1 then step 2")
        XCTAssertLessThan(counts, firstScreen)
        XCTAssertLessThan(firstScreen, firstChain, "the first screen before the index")
        let lastChain = try XCTUnwrap(trace.lastIndex { $0.hasSuffix(":500") })
        let afterListing = Array(trace[(lastChain + 1)...])
        XCTAssertEqual(afterListing.first, "historyList", "step 4 begins with a check")
        XCTAssertTrue(afterListing.contains("profile"), "step 4 compares with the profile's total")
        XCTAssertEqual(afterListing.last, "historyList", "step 7: the changes since the start, applied again")
        XCTAssertEqual(afterListing.filter { $0 == "historyList" }.count, 3)

        let batches = await rig.store.batches
        XCTAssertEqual(batches.first?.cursor, startHistory, "the base cursor is journaled before anything is listed")
        XCTAssertEqual(batches.first?.changes, [])

        // The first screen: fifteen rows, a conversation with two messages on the page fetched whole.
        let conversations = gmail.calls[.threadsGet] ?? 0
        let singles = gmail.calls[.messagesGet] ?? 0
        XCTAssertEqual(conversations + singles, 15)
        XCTAssertGreaterThan(conversations, 0)
        var iterator = rows.makeAsyncIterator()
        let published = await iterator.next()
        XCTAssertEqual(published?.count, 15)
        XCTAssertNotNil(published?.values.first { $0.conversation?.messageCount == 2 }, "a conversation row carries its senders and count")

        let snapshot = await rig.store.index()
        XCTAssertEqual(snapshot.byOrder.map { snapshot.records[Int($0)].gmailID }, refs.map(\.id), "newest last, in received order")
        await rig.finish()
    }

    // MARK: - Units, against the design's table

    private func listAndMeasure(_ spec: GmailFixtureMailbox.Spec, file: StaticString = #filePath, line: UInt = #line) async throws
        -> (rig: GmailEngineRig, gmail: GmailFixtureMailbox, listing: Int, firstScreen: Int, total: Int, seconds: TimeInterval) {
        let gmail = GmailFixtureMailbox.fixture(spec)
        let rig = GmailEngineRig(transport: gmail, clock: ManualGmailClock(gmail.now), settings: listingOnly())
        let began = Date()
        await rig.engine.runBackfill()
        let seconds = Date().timeIntervalSince(began)
        let phase = await rig.engine.state.backfill?.phase
        XCTAssertEqual(phase, .complete, file: file, line: line)
        let units = gmail.units
        let firstScreen = (units[.messagesGet] ?? 0) + (units[.threadsGet] ?? 0)
        // The Inbox's first page (5 units) belongs to the first screen.
        let listing = (units[.messagesList] ?? 0) - 5
        return (rig, gmail, listing, firstScreen, gmail.totalUnits, seconds)
    }

    /// Every message in the index, in Gmail's order, and every label exactly as Gmail has it.
    private func assertMirrors(_ gmail: GmailFixtureMailbox, _ rig: GmailEngineRig, labels: [GmailLabelID],
                               file: StaticString = #filePath, line: UInt = #line) async {
        let snapshot = await rig.store.index()
        XCTAssertEqual(snapshot.byOrder.count, gmail.count, file: file, line: line)
        let order = snapshot.byOrder.reversed().map { snapshot.records[Int($0)].id }
        XCTAssertEqual(order, gmail.newestFirst.map(\.id.raw), "the index keeps Gmail's order", file: file, line: line)
        for label in labels {
            let members = Set(snapshot.byOrder.filter { snapshot.record(atSlot: $0, has: label) }.map { snapshot.records[Int($0)].id })
            XCTAssertEqual(members, gmail.members(of: label), "the members of \(label)", file: file, line: line)
        }
    }

    func testListing55kStaysWithinTheTable() async throws {
        let run = try await listAndMeasure(.typical)
        // §3: about 237 pages, about 1,200 units; §14.6: at most 1,500 for every message listed.
        XCTAssertLessThanOrEqual(run.listing, 1_300)
        XCTAssertLessThanOrEqual(run.total - run.firstScreen, 1_500)
        XCTAssertLessThanOrEqual(run.firstScreen, 600)
        let users = run.gmail.userLabelIDs
        await assertMirrors(run.gmail, run.rig, labels: [.inbox, .sent, .unread, .important, .starred, .spam, .trash, .draft,
                                                         .categorySocial, .categoryUpdates, users[0], users[7], users[19]])
        print("55k: listing \(run.listing), first screen \(run.firstScreen), total \(run.total) units, \(String(format: "%.1f", run.seconds)) s")
        await run.rig.finish()
    }

    func testListing200kStaysWithinTheTable() async throws {
        let run = try await listAndMeasure(.large)
        // §3: about 970 pages, about 4,900 units; §14.6: at most 5,500 for every message listed.
        XCTAssertLessThanOrEqual(run.listing, 5_100)
        XCTAssertLessThanOrEqual(run.total - run.firstScreen, 5_500)
        let users = run.gmail.userLabelIDs
        await assertMirrors(run.gmail, run.rig, labels: [.inbox, .unread, .sent, .categoryPromotions, users[0], users[39]])
        print("200k: listing \(run.listing), first screen \(run.firstScreen), total \(run.total) units, \(String(format: "%.1f", run.seconds)) s")
        await run.rig.finish()
    }

    func testListing200kMigratedFromOutlookStaysWithinTheTable() async throws {
        let run = try await listAndMeasure(.migrated)
        // §3: about 1,017 pages, about 5,100 units, with 150 labels, 102 of them in overflow lists.
        XCTAssertLessThanOrEqual(run.listing, 5_300)
        XCTAssertLessThanOrEqual(run.total - run.firstScreen, 5_500)
        let users = run.gmail.userLabelIDs
        await assertMirrors(run.gmail, run.rig, labels: [.inbox, .important, users[0], users[60], users[149]])
        let snapshot = await run.rig.store.index()
        XCTAssertEqual(snapshot.overflow.count, 150 - 48, "the 48 largest labels take bits, the rest overflow lists")
        print("migrated: listing \(run.listing), first screen \(run.firstScreen), total \(run.total) units, \(String(format: "%.1f", run.seconds)) s")
        await run.rig.finish()
    }

    // MARK: - Resuming, and repairing a listing

    func testAStoppedListingResumesFromTheLastSavedPage() async throws {
        let spec = GmailFixtureMailbox.Spec(total: 12_000, inbox: 4_000, sent: 1_000, unread: 500, important: 2_000, starred: 100,
                                            drafts: 5, spam: 50, trash: 100, userLabels: 6, labelled: 3_000, otherCategories: 1_000)
        let gmail = GmailFixtureMailbox.fixture(spec)
        let clock = ManualGmailClock(gmail.now)
        let rig = GmailEngineRig(transport: gmail, clock: clock, settings: listingOnly())
        var chainPages = 0
        rig.transport.onList { query in
            guard query.maxResults == 500 else { return }
            chainPages += 1
            if chainPages == 12 { rig.transport.fail(.messagesList, with: GoogleAPIError(kind: .offline, detail: "the Mac went offline")) }
        }
        await rig.engine.runBackfill()
        let stopped = await rig.engine.state.backfill?.phase
        XCTAssertEqual(stopped, .listing)
        await rig.engine.stop()
        rig.transport.onList(nil)
        let firstRun = rig.transport.listCalls.filter { $0.maxResults == 500 }.count

        let relaunched = rig.relaunched(settings: listingOnly())
        relaunched.transport.clearLog()
        await relaunched.engine.runBackfill()
        let phase = await relaunched.engine.state.backfill?.phase
        XCTAssertEqual(phase, .complete)
        let secondRun = relaunched.transport.listCalls.filter { $0.maxResults == 500 }
        XCTAssertFalse(secondRun.contains { $0.labels.isEmpty && $0.pageToken == nil }, "All Mail is not listed from the top again")
        let pages = firstRun + secondRun.count
        func pagesOf(_ count: Int) -> Int { max(1, (count + 499) / 500) }
        var needed = pagesOf(gmail.count)
        for label: GmailLabelID in [.inbox, .sent, .unread, .starred, .important, .draft, .spam, .trash] + gmail.userLabelIDs {
            needed += pagesOf(gmail.members(of: label).count)
        }
        for category: GmailLabelID in [.categorySocial, .categoryPromotions, .categoryUpdates, .categoryForums] {
            needed += pagesOf(gmail.members(of: category).intersection(gmail.members(of: .inbox)).count)
        }
        // The refused page is asked again, and so may a page of each other listing in flight.
        XCTAssertGreaterThanOrEqual(pages, needed + 1)
        XCTAssertLessThanOrEqual(pages, needed + 1 + GmailEngineSettings().chainsAtOnce)
        let snapshot = await relaunched.store.index()
        XCTAssertEqual(snapshot.byOrder.count, gmail.count)
        await relaunched.finish()
    }

    func testAMessageDeletedAboveThePageBeingReadLeavesTheNextInTheIndex() async throws {
        var settings = listingOnly()
        settings.pageSize = 10
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let start = clock.now()
        // Archived mail, which only All Mail lists.
        let refs = (0..<60).map { gmail.add(subject: "Archived \($0)", labels: [], date: start.addingTimeInterval(-Double(60 - $0) * 3600)) }
        let newestFirst = Array(refs.reversed())
        let deleted = newestFirst[5]
        let skipped = newestFirst[20]
        var fired = false
        let rig = GmailEngineRig(transport: gmail, clock: clock, settings: settings)
        rig.transport.onList { query in
            if !fired, query.labels.isEmpty, query.query == nil, query.pageToken == "20" {
                fired = true
                gmail.delete(deleted.id)
            }
        }
        await rig.engine.runBackfill()
        XCTAssertTrue(fired)
        let phase = await rig.engine.state.backfill?.phase
        XCTAssertEqual(phase, .complete)
        let kept = await rig.store.record(for: skipped.id)
        XCTAssertFalse(try XCTUnwrap(kept, "the message the page skipped is in the index").attributes.contains(.tombstone))
        let gone = await rig.store.record(for: deleted.id)
        XCTAssertTrue(gone?.attributes.contains(.tombstone) ?? true)
        let snapshot = await rig.store.index()
        XCTAssertEqual(snapshot.byOrder.map { snapshot.records[Int($0)].gmailID }, refs.filter { $0 != deleted }.map(\.id),
                       "and in its place")
        await rig.finish()
    }

    // MARK: - The sidebar (§2.2)

    func testFoldersTakeOutlooksNamesAndOrder() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let clients = gmail.addUserLabel(named: "Clients")
        let acme = gmail.addUserLabel(named: "Clients/Acme")
        gmail.addUserLabel(named: "Receipts", visibility: "labelHide")
        let start = clock.now()
        gmail.add(subject: "One", labels: [.inbox, .unread, clients], date: start.addingTimeInterval(-4000))
        gmail.add(subject: "Two", labels: [.inbox, acme, .starred], date: start.addingTimeInterval(-3000))
        gmail.add(subject: "Junk", labels: [.spam, .unread], date: start.addingTimeInterval(-2000))
        gmail.add(subject: "Draft", labels: [.draft], date: start.addingTimeInterval(-1000))
        gmail.add(subject: "Draft 2", labels: [.draft], date: start.addingTimeInterval(-900))
        let rig = GmailEngineRig(transport: gmail, clock: clock, settings: listingOnly())
        await rig.engine.runBackfill()
        let folders = await rig.engine.folders()
        XCTAssertEqual(folders.map(\.name), ["Inbox", "Drafts", "Archive", "Sent", "Deleted Items", "Junk Email", "Important", "Starred",
                                             "Clients", "Acme"])
        XCTAssertEqual(folders.map(\.path), ["INBOX", "[Gmail]/Drafts", "[Gmail]/Archive", "[Gmail]/Sent", "[Gmail]/Deleted Items",
                                             "[Gmail]/Junk Email", "[Gmail]/Important", "[Gmail]/Starred", "Clients", "Clients/Acme"])
        XCTAssertEqual(folders.map(\.role), [.inbox, .drafts, .all, .sent, .trash, .junk, .important, .flagged, .other, .other])
        func folder(_ name: String) -> FolderInfo? { folders.first { $0.name == name } }
        XCTAssertEqual(folder("Inbox")?.totalCount, 2)
        XCTAssertEqual(folder("Inbox")?.unreadCount, 1)
        XCTAssertEqual(folder("Drafts")?.unreadCount, 2, "Drafts counts its drafts, as Outlook does")
        XCTAssertEqual(folder("Archive")?.totalCount, 4, "everything but Junk Email and Deleted Items")
        XCTAssertEqual(folder("Junk Email")?.unreadCount, 1)
        XCTAssertEqual(folder("Starred")?.totalCount, 1)
        XCTAssertEqual(folder("Inbox")?.gmailLabelID, .inbox)
        XCTAssertNil(folder("Archive")?.gmailLabelID)
        XCTAssertEqual(folder("Inbox")?.id, GmailLabelMapping.folderID(accountID: rig.account.id, key: "INBOX"), "the same id on every Mac")
        await rig.finish()
    }

    func testTheSwitchKeepsTheFoldersTheOwnerHad() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let clients = gmail.addUserLabel(named: "Clients")
        gmail.addUserLabel(named: "Clients/Acme")
        gmail.add(subject: "One", labels: [.inbox, clients], date: clock.now().addingTimeInterval(-100))
        let account = gmail.accountID
        func imap(_ path: String, _ role: FolderRole) -> FolderInfo {
            FolderInfo(accountID: account, path: path, name: path, delimiter: "/", role: role, attributes: [], isSelectable: true)
        }
        let hints = [imap("INBOX", .inbox), imap("[Google Mail]/Sent Mail", .sent), imap("[Google Mail]/All Mail", .all),
                     imap("[Google Mail]/Trash", .trash), imap("Clients", .other)]
        let rig = GmailEngineRig(transport: gmail, clock: clock, settings: listingOnly(), hints: hints)
        await rig.engine.runBackfill()
        let folders = await rig.engine.folders()
        XCTAssertEqual(folders.first { $0.role == .inbox }?.id, hints[0].id)
        XCTAssertEqual(folders.first { $0.role == .sent }?.id, hints[1].id)
        XCTAssertEqual(folders.first { $0.role == .all }?.id, hints[2].id)
        XCTAssertEqual(folders.first { $0.role == .trash }?.id, hints[3].id)
        XCTAssertEqual(folders.first { $0.name == "Clients" }?.id, hints[4].id)
        XCTAssertEqual(folders.first { $0.role == .sent }?.path, "[Google Mail]/Sent", "the group keeps the account's own name")
        XCTAssertNil(folders.first { $0.name == "Acme" }, "a label the owner's IMAP folders did not show stays hidden at the switch")
        await rig.finish()
    }

    // MARK: - The newest 1,000 (§2.4)

    func testTheNewestAreKeptWithTheirConversations() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let start = clock.now()
        var refs: [GmailRef] = []
        for i in 0..<30 {
            // The 22nd is a reply to the 5th, so one conversation has a member too old to keep, and
            // the 28th to the 26th, a conversation the first screen fetches whole and keeps.
            let thread = i == 22 ? refs[5].threadID : i == 28 ? refs[26].threadID : nil
            refs.append(gmail.add(subject: "Mail \(i)", labels: [.inbox], date: start.addingTimeInterval(-Double(30 - i) * 3600), thread: thread))
        }
        var settings = GmailEngineSettings()
        settings.fillsCache = true
        let store = MemoryGmailStore(accountID: gmail.accountID, cacheLimit: 10, cacheCeiling: 12)
        let rig = GmailEngineRig(transport: gmail, store: store, clock: clock, settings: settings)
        await rig.engine.start()
        try await eventually(timeout: 20, "the newest kept") {
            let complete = await rig.engine.state.backfill?.phase == .complete
            let filling = await rig.engine.cacheTask != nil
            let kept = await store.cachedIDs().count
            return complete && !filling && kept == 10
        }
        let cached = await store.cachedIDs()
        XCTAssertEqual(cached, Set(refs.suffix(10).map(\.id)))
        XCTAssertEqual(gmail.units[.threadsGet], 80,
                       "the first screen's conversation is summarised once; the one with a member not kept costs one threads.get")
        let summaries = await store.threadSummaries([refs[5].threadID, refs[26].threadID, refs[29].threadID])
        XCTAssertEqual(summaries[refs[5].threadID]?.messageCount, 2)
        XCTAssertEqual(summaries[refs[26].threadID]?.messageCount, 2)
        XCTAssertEqual(summaries[refs[29].threadID]?.messageCount, 1)
        let body = try await store.body(of: refs[29].id)
        XCTAssertEqual(body?.textPlain, "Hello")
        await rig.finish()
    }

    // MARK: - Date groups (§5.6)

    func testDateAnchorsFindTheNewestMessageBeforeEachBoundary() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let start = clock.now()
        let refs = (0..<90).map { gmail.add(subject: "Mail \($0)", labels: [.inbox], date: start.addingTimeInterval(-Double(90 - $0) * day + 60)) }
        let rig = GmailEngineRig(transport: gmail, clock: clock, settings: listingOnly())
        await rig.engine.runBackfill()
        try await rig.engine.refreshDateAnchors(only: nil)
        let anchors = await rig.store.dateAnchors()
        let boundaries = GmailDateGroups.boundaries(now: clock.now(), oldest: gmail.message(refs[0].id)?.date)
        XCTAssertEqual(Set(anchors.map(\.boundary)), Set(boundaries))
        for anchor in anchors {
            let expected = refs.last { gmail.message($0.id)!.date < anchor.boundary }
            XCTAssertEqual(anchor.id, expected?.id, "the newest message before \(anchor.boundary)")
            if let id = expected?.id {
                let order = await rig.store.record(for: id)?.order
                XCTAssertEqual(anchor.order, order)
            }
        }
        XCTAssertEqual(gmail.units[.messagesList].map { $0 >= anchors.count * 5 }, true)
        await rig.finish()
    }
}
