import XCTest
@testable import FalconCore

/// The newest 1,000 kept on the Mac: which messages belong, the limits, the bodies' cap, offline
/// search and conversation summaries, all read back after a relaunch.
final class GmailMessageCacheTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    private func makeStore(limits: GmailFileStore.Limits = GmailFileStore.Limits()) -> GmailFileStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GmailMessageCacheTests-\(UUID().uuidString)", isDirectory: true)
        directories.append(directory)
        return GmailFileStore(accountID: UUID(), files: GmailFiles(directory: directory.appendingPathComponent("Gmail")), limits: limits)
    }

    private func reopen(_ store: GmailFileStore) -> GmailFileStore {
        GmailFileStore(accountID: store.accountID, files: store.files, limits: store.limits)
    }

    private func limits(cache: Int, ceiling: Int, bodies: Int = 32 * 1_024 * 1_024) -> GmailFileStore.Limits {
        var limits = GmailFileStore.Limits()
        limits.cacheLimit = cache
        limits.cacheCeiling = ceiling
        limits.bodyBytesCap = bodies
        return limits
    }

    private func ref(_ n: UInt64, thread: UInt64? = nil) -> GmailRef {
        GmailRef(id: GmailMessageID(raw: 0x18a0_0000_0000_0000 + n), threadID: GmailThreadID(raw: 0x18a0_0000_0000_0000 + (thread ?? n)))
    }

    private func place(_ n: UInt64, labels: Set<GmailLabelID> = [.inbox], thread: UInt64? = nil) -> GmailChange {
        .place(ref(n, thread: thread), order: UInt32(n) * 16, labels: labels, attributes: [])
    }

    private func message(_ n: UInt64, thread: UInt64? = nil, from: String = "ana@example.com") -> GmailCachedMessage {
        GmailCachedMessage(id: ref(n).id, threadID: ref(n, thread: thread).threadID, from: EmailAddress(name: "Ana", address: from),
                           to: [EmailAddress(address: "owner@example.com")], subject: "Mail \(n)", preview: "Hello",
                           date: Date(timeIntervalSince1970: 1_790_000_000 + Double(n)), size: 100, hasAttachments: false,
                           messageID: "<\(n)@x>", references: ["<0@x>"],
                           attachments: [GmailCachedAttachment(partID: "1", attachmentID: "att-\(n)", filename: "a.pdf",
                                                               mimeType: "application/pdf", size: 10)],
                           cachedAt: Date(timeIntervalSince1970: 1_790_000_000.5))
    }

    private func randomBody(_ bytes: Int) -> GmailReducedBody {
        var generator = SystemRandomNumberGenerator()
        let data = Data((0..<bytes).map { _ in UInt8.random(in: 0...255, using: &generator) })
        return GmailReducedBody(textPlain: "Hi", textHTML: "<img src=\"cid:logo\">",
                                inlineImages: [GmailInlineImage(contentID: "logo", mimeType: "image/png", data: data)])
    }

    // MARK: - The limits

    /// The owner allows up to 2 GB for mail on the Mac: the store's own limits keep within it.
    func testTheAppsLimitsStayWithinTwoGigabytes() {
        let limits = GmailFileStore.Limits()
        XCTAssertGreaterThanOrEqual(limits.cacheLimit, 20_000, "enough kept that lists and opens rarely wait for Gmail")
        // A kept row with its reply headers and summary takes about 2 KB on disk.
        let rows = Int64(limits.cacheCeiling) * 2 * 1_024
        XCTAssertLessThanOrEqual(Int64(limits.bodyBytesCap) + rows, 2 * 1_024 * 1_024 * 1_024)
    }

    func testTheCacheGoesBackToAThousandAndKeepsWhatIsPinned() async throws {
        // The eviction rule at a limit of 1,000; the app's own limit is larger (see the next test).
        let store = makeStore(limits: limits(cache: 1_000, ceiling: 1_050))
        try await store.commit(GmailJournalBatch(changes: (1...1_050).map { place(UInt64($0)) }, cursor: HistoryID(raw: 1)))
        let oldest = ref(1).id
        await store.setPinned([oldest])
        for n in 1...1_049 {
            try await store.cache(message(UInt64(n)), body: nil)
        }
        var ids = await store.cachedIDs()
        XCTAssertEqual(ids.count, 1_049, "up to 1,050 before anything goes")
        let evicted = try await store.cache(message(1_050), body: nil)
        XCTAssertEqual(evicted, (2...51).map { ref(UInt64($0)).id }, "the store says which left, oldest first")
        ids = await store.cachedIDs()
        XCTAssertEqual(ids.count, 1_000)
        XCTAssertTrue(ids.contains(oldest), "a pinned message stays however old")

        let reopened = reopen(store)
        let kept = await reopened.cachedIDs()
        XCTAssertEqual(kept, ids, "the same 1,000 after a relaunch")
        let second = await reopened.record(for: ref(2).id)
        XCTAssertFalse(second?.attributes.contains(.cached) ?? true)
        let newest = await reopened.record(for: ref(1_050).id)
        XCTAssertTrue(newest?.attributes.contains(.cached) ?? false, "the index says which are kept")
        let row = await reopened.cachedMessages([ref(1_050).id])[ref(1_050).id]
        XCTAssertEqual(row, message(1_050), "a row comes back exactly as kept")
    }

    func testBodiesPastTheCapGoOldestFirstButTheirRowsStay() async throws {
        // Pictures do not compress, so each body takes about 40 KB on disk.
        let store = makeStore(limits: limits(cache: 1_000, ceiling: 1_050, bodies: 100_000))
        try await store.commit(GmailJournalBatch(changes: (1...4).map { place(UInt64($0)) }, cursor: HistoryID(raw: 1)))
        await store.setPinned([ref(1).id])
        for n in 1...4 {
            try await store.cache(message(UInt64(n)), body: randomBody(40_000))
        }
        let rows = await store.cachedIDs()
        XCTAssertEqual(rows.count, 4, "every row stays")
        let pinned = try await store.body(of: ref(1).id)
        XCTAssertNotNil(pinned, "a pinned message keeps its body")
        let oldest = try await store.body(of: ref(2).id)
        XCTAssertNil(oldest, "the oldest body went")
        let newest = try await store.body(of: ref(4).id)
        XCTAssertEqual(newest?.inlineImages.first?.data.count, 40_000)
        let files = store.files
        let onDisk = (try FileManager.default.contentsOfDirectory(at: files.bodiesDirectory, includingPropertiesForKeys: [.fileSizeKey]))
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        XCTAssertLessThanOrEqual(onDisk, 100_000, "the cap is on what the bodies take on disk")

        let reopened = reopen(store)
        let back = try await reopened.body(of: ref(4).id)
        XCTAssertEqual(back, newest)
        let gone = try await reopened.body(of: ref(2).id)
        XCTAssertNil(gone)
    }

    func testAReducedBodyIsCompressedAndReadsBackWhole() throws {
        let body = GmailReducedBody(textPlain: String(repeating: "Freight invoice for March. ", count: 400),
                                    textHTML: "<p>" + String(repeating: "Freight invoice for March. ", count: 400) + "</p>",
                                    inlineImages: [GmailInlineImage(contentID: "logo@x", mimeType: "image/png", data: Data(repeating: 7, count: 5_000))])
        let data = try GmailBodyStore.encode(body)
        XCTAssertLessThan(data.count, body.byteCount / 10, "LZFSE keeps text small")
        XCTAssertEqual(try GmailBodyStore.decode(data), body)
    }

    func testAnUnreadableBodyIsDroppedAndFetchedAgainLater() async throws {
        let store = makeStore()
        try await store.commit(GmailJournalBatch(changes: [place(1)], cursor: HistoryID(raw: 1)))
        try await store.cache(message(1), body: randomBody(100))
        try Data("not lzfse".utf8).write(to: store.files.body(ref(1).id))
        let body = try await store.body(of: ref(1).id)
        XCTAssertNil(body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.files.body(ref(1).id).path))
        let row = await store.cachedIDs()
        XCTAssertEqual(row, [ref(1).id], "the row stays")
    }

    // MARK: - Which messages belong

    func testWhatToCacheFollowsTheFirstScreenRule() async throws {
        let store = makeStore(limits: limits(cache: 60, ceiling: 63))
        let clients: GmailLabelID = "Label_1"
        try await store.saveLabelTable([GmailLabelEntry(id: clients, name: "Clients", kind: .user, isShown: true, folderID: UUID(),
                                                        counts: GmailLabelCounts(messagesTotal: 5, messagesUnread: 0, asOf: Date()))])
        var changes: [GmailChange] = []
        for n in 1...100 { changes.append(place(UInt64(n), labels: n <= 5 ? [clients] : [.inbox])) }
        changes.append(place(200, labels: [.inbox, .spam]))
        changes.append(place(201, labels: [.inbox, .trash]))
        changes.append(.place(ref(202), order: 202 * 16, labels: [.inbox], attributes: [.provisional]))
        try await store.commit(GmailJournalBatch(changes: changes, cursor: HistoryID(raw: 1)))
        await store.setPinned([ref(50).id])
        await store.noteFolderShown(clients, rows: 25, at: Date())

        let wanted = await store.messagesToCache(limit: 1_000)
        XCTAssertEqual(wanted.count, 60)
        XCTAssertEqual(wanted.first, ref(50).id, "pinned messages first")
        XCTAssertFalse(wanted.contains(ref(200).id), "never Junk Email")
        XCTAssertFalse(wanted.contains(ref(201).id), "never Deleted Items")
        XCTAssertFalse(wanted.contains(ref(202).id), "never mail not shown yet")
        XCTAssertTrue(Set((1...5).map { ref(UInt64($0)).id }).isSubset(of: wanted), "the first screen of a folder in use, however old")
        XCTAssertTrue(wanted.contains(ref(100).id), "then the newest")
        let few = await store.messagesToCache(limit: 3)
        XCTAssertEqual(few.count, 3)

        try await store.cache(message(50), body: nil)
        let after = await store.messagesToCache(limit: 1_000)
        XCTAssertFalse(after.contains(ref(50).id), "only what is not cached yet")
        let remembered = await reopen(store).messagesToCache(limit: 1_000)
        XCTAssertTrue(Set((1...5).map { ref(UInt64($0)).id }).isSubset(of: remembered), "the folders used are remembered")
    }

    /// A mailbox moved from Outlook, with 150 folders all opened: only the Inbox and the 12
    /// folders used most recently keep a screen, 390 messages at most, however long each list is.
    func testTheFirstScreenRuleWithAHundredAndFiftyFoldersStaysWithinThreeHundredAndNinetySlots() async throws {
        let store = makeStore(limits: limits(cache: 5_000, ceiling: 5_050))
        let folders = (1...150).map { GmailLabelID("Label_\($0)") }
        try await store.saveLabelTable(folders.enumerated().map { i, label in
            GmailLabelEntry(id: label, name: "Folder \(i)", kind: .user, isShown: true, folderID: UUID(),
                            counts: GmailLabelCounts(messagesTotal: 40, messagesUnread: 0, asOf: Date()))
        })
        // Old mail: 40 messages in each folder, all older than the 5,000 newest Inbox messages.
        var changes: [GmailChange] = []
        for (f, label) in folders.enumerated() {
            for k in 0..<40 { changes.append(place(UInt64(f * 40 + k + 1), labels: [label])) }
        }
        let newestStart = UInt64(folders.count * 40 + 1)
        for n in newestStart..<(newestStart + 5_000) { changes.append(place(n, labels: [.inbox])) }
        try await store.commit(GmailJournalBatch(changes: changes, cursor: HistoryID(raw: 1)))
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        for (f, label) in folders.enumerated() {
            await store.noteFolderShown(label, rows: 45, at: start.addingTimeInterval(Double(f)))
        }
        await store.noteFolderShown(.inbox, rows: 12, at: start)

        let wanted = await store.messagesToCache(limit: 5_000)
        let old = wanted.filter { $0.raw < 0x18a0_0000_0000_0000 + newestStart }
        XCTAssertEqual(old.count, 12 * 30, "12 folders, each one screen of at most 30 rows")
        XCTAssertLessThanOrEqual(old.count + 30, 390)
        let kept = Set(old.map { Int(($0.raw - 0x18a0_0000_0000_0001) / 40) })
        XCTAssertEqual(kept, Set(138..<150), "the 12 opened most recently")
        let inboxScreen = wanted.prefix(20)
        XCTAssertEqual(Array(inboxScreen), (0..<20).map { ref(newestStart + 4_999 - UInt64($0)).id },
                       "the Inbox keeps at least 20 rows, and comes first")
    }

    func testAConversationInAFirstScreenIsKeptByItsNewestMessageFirst() async throws {
        let store = makeStore(limits: limits(cache: 25, ceiling: 26))
        let project: GmailLabelID = "Label_1"
        try await store.saveLabelTable([GmailLabelEntry(id: project, name: "Project", kind: .user, isShown: true, folderID: UUID())])
        // Conversation 1 has 30 messages in the folder, then 25 conversations of one message each.
        var changes: [GmailChange] = []
        for n in 1...25 { changes.append(place(UInt64(n), labels: [project])) }
        for n in 26...55 { changes.append(place(UInt64(n), labels: [project], thread: 1_000)) }
        for n in 1_001...1_100 { changes.append(place(UInt64(n), labels: [.inbox])) }
        try await store.commit(GmailJournalBatch(changes: changes, cursor: HistoryID(raw: 1)))
        await store.noteFolderShown(project, rows: 20, at: Date())
        let wanted = await store.messagesToCache(limit: 25)
        // The Inbox's 20 first, then the folder's screen: the conversation's newest message, then
        // the next conversations, as the default Conversations view shows them.
        XCTAssertEqual(Array(wanted.dropFirst(20)), [ref(55).id, ref(25).id, ref(24).id, ref(23).id, ref(22).id])
    }

    /// New mail arriving must not push a kept first screen out only for the fill to fetch it
    /// again: what the rule wants stays, and once it is all kept nothing more is wanted.
    func testAFirstScreenIsNotEvictedByNewerMail() async throws {
        let store = makeStore(limits: limits(cache: 40, ceiling: 45))
        let archive: GmailLabelID = "Label_1"
        try await store.saveLabelTable([GmailLabelEntry(id: archive, name: "2019", kind: .user, isShown: true, folderID: UUID())])
        try await store.commit(GmailJournalBatch(changes: (1...20).map { place(UInt64($0), labels: [archive]) }, cursor: HistoryID(raw: 1)))
        await store.noteFolderShown(archive, rows: 20, at: Date())
        var n: UInt64 = 100
        for round in 0..<10 {
            try await store.commit(GmailJournalBatch(changes: (0..<10).map { place(n + UInt64($0)) }, cursor: HistoryID(raw: UInt64(round + 2))))
            n += 10
            for id in await store.messagesToCache(limit: 100) {
                try await store.cache(message(id.raw - 0x18a0_0000_0000_0000), body: nil)
            }
            let more = await store.messagesToCache(limit: 100)
            XCTAssertTrue(more.isEmpty, "everything wanted is kept, round \(round)")
            let kept = await store.cachedIDs()
            XCTAssertTrue(Set((1...20).map { ref(UInt64($0)).id }).isSubset(of: kept), "the folder's screen stays, round \(round)")
            XCTAssertLessThanOrEqual(kept.count, 45)
        }
    }

    // MARK: - Deleted, gone, and offline

    func testADeletedMessageLeavesTheCacheWithItsBody() async throws {
        let store = makeStore()
        try await store.commit(GmailJournalBatch(changes: [place(1), place(2)], cursor: HistoryID(raw: 1)))
        try await store.cache(message(1), body: randomBody(100))
        try await store.cache(message(2), body: randomBody(100))
        try await store.commit(GmailJournalBatch(changes: [.tombstone(ref(1).id)], cursor: HistoryID(raw: 2)))
        let ids = await store.cachedIDs()
        XCTAssertEqual(ids, [ref(2).id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.files.body(ref(1).id).path))
        let reopenedIDs = await reopen(store).cachedIDs()
        XCTAssertEqual(reopenedIDs, [ref(2).id])
    }

    func testRowsWhoseMessagesTheIndexLostAreDroppedAtLaunch() async throws {
        let store = makeStore()
        try await store.commit(GmailJournalBatch(changes: [place(1), place(2)], cursor: HistoryID(raw: 1)))
        try await store.cache(message(1), body: randomBody(100))
        try await store.cache(message(2), body: nil)
        // As if the process died after saving the deletion and before letting go of the row.
        let rows = try Data(contentsOf: store.files.cacheRowsJournal)
        let bodyFile = try Data(contentsOf: store.files.body(ref(1).id))
        try await store.commit(GmailJournalBatch(changes: [.tombstone(ref(1).id)], cursor: HistoryID(raw: 2)))
        try rows.write(to: store.files.cacheRowsJournal)
        try bodyFile.write(to: store.files.body(ref(1).id))
        // And a body whose row was never written.
        try bodyFile.write(to: store.files.body(ref(7).id))

        let reopened = reopen(store)
        let ids = await reopened.cachedIDs()
        XCTAssertEqual(ids, [ref(2).id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.files.body(ref(1).id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.files.body(ref(7).id).path))
    }

    func testATornRowLineIsCutAndTheNextRowFollowsIt() async throws {
        let store = makeStore()
        try await store.commit(GmailJournalBatch(changes: [place(1), place(2), place(3)], cursor: HistoryID(raw: 1)))
        try await store.cache(message(1), body: nil)
        try await store.cache(message(2), body: nil)
        var rows = try Data(contentsOf: store.files.cacheRowsJournal)
        rows.removeLast(40)
        try rows.write(to: store.files.cacheRowsJournal)
        let reopened = reopen(store)
        var ids = await reopened.cachedIDs()
        XCTAssertEqual(ids, [ref(1).id])
        try await reopened.cache(message(3), body: nil)
        ids = await reopen(store).cachedIDs()
        XCTAssertEqual(ids, [ref(1).id, ref(3).id])
    }

    func testKeptMessagesCanBeSearchedOffline() async throws {
        let store = makeStore()
        try await store.commit(GmailJournalBatch(changes: (1...3).map { place(UInt64($0)) }, cursor: HistoryID(raw: 1)))
        var invoice = message(1)
        invoice.subject = "Freight invoice March"
        invoice.from = EmailAddress(name: "Carrier Billing", address: "billing@carrier.example")
        var later = message(2)
        later.subject = "Invoice April"
        later.preview = "Freight charges attached"
        var accents = message(3)
        accents.subject = "Café Zürich booking"
        accents.cc = [EmailAddress(name: "Rıza Öztürk", address: "riza@example.com")]
        for m in [invoice, later, accents] { try await store.cache(m, body: nil) }
        let both = await store.searchCached("freight INVOICE", limit: 10)
        XCTAssertEqual(both, [ref(2).id, ref(1).id], "every word, in any field, newest first")
        let sender = await store.searchCached("carrier march", limit: 10)
        XCTAssertEqual(sender, [ref(1).id])
        let one = await store.searchCached("invoice", limit: 1)
        XCTAssertEqual(one, [ref(2).id])
        let folded = await reopen(store).searchCached("cafe zurich ozturk", limit: 10)
        XCTAssertEqual(folded, [ref(3).id], "accents and case do not matter, and names in Cc count")
        let none = await store.searchCached("  ", limit: 10)
        XCTAssertTrue(none.isEmpty)
    }

    // MARK: - Conversation summaries

    func testSummariesAreMadeFromKeptRowsAndKeptCurrent() async throws {
        let store = makeStore(limits: limits(cache: 4, ceiling: 5))
        let thread: UInt64 = 900
        try await store.commit(GmailJournalBatch(changes: [place(1, thread: thread), place(2, thread: thread), place(3)],
                                                 cursor: HistoryID(raw: 1)))
        let conversation = ref(1, thread: thread).threadID
        try await store.cache(message(1, thread: thread, from: "ana@example.com"), body: nil)
        var summaries = await store.threadSummaries([conversation])
        XCTAssertTrue(summaries.isEmpty, "not every message of the conversation is kept yet")
        try await store.cache(message(2, thread: thread, from: "bob@example.com"), body: nil)
        summaries = await store.threadSummaries([conversation])
        XCTAssertEqual(summaries[conversation]?.messageCount, 2, "made from the kept rows")
        XCTAssertEqual(summaries[conversation]?.senders.map(\.address), ["ana@example.com", "bob@example.com"], "oldest first")

        // A reply arrives and is kept: it joins the summary.
        try await store.commit(GmailJournalBatch(changes: [place(4, thread: thread)], cursor: HistoryID(raw: 2)))
        try await store.cache(message(4, thread: thread, from: "ana@example.com"), body: nil)
        summaries = await reopen(store).threadSummaries([conversation])
        XCTAssertEqual(summaries[conversation]?.messageCount, 3)
        XCTAssertEqual(summaries[conversation]?.newestDate, message(4).date)
        XCTAssertEqual(summaries[conversation]?.senders.map(\.address), ["ana@example.com", "bob@example.com"])

        // One is deleted on the phone: it leaves the summary.
        try await store.commit(GmailJournalBatch(changes: [.tombstone(ref(2).id)], cursor: HistoryID(raw: 3)))
        summaries = await store.threadSummaries([conversation])
        XCTAssertEqual(summaries[conversation]?.messageCount, 2)
        XCTAssertEqual(summaries[conversation]?.senders.map(\.address), ["ana@example.com"])

        // A summary the engine made from threads.get, for a conversation with older members not
        // kept, is kept current the same way.
        let other = ref(3).threadID
        try await store.cache(message(3), body: nil)
        let fromGmail = GmailThreadSummary(threadID: other, senders: [EmailAddress(address: "carl@example.com")], messageCount: 5,
                                           newestDate: message(3).date)
        try await store.saveThreadSummaries([fromGmail])
        summaries = await store.threadSummaries([other])
        XCTAssertEqual(summaries[other], fromGmail)

        // The last kept message of a conversation goes: so does its summary.
        try await store.uncache([ref(3).id])
        summaries = await reopen(store).threadSummaries([other, conversation])
        XCTAssertNil(summaries[other])
        XCTAssertNotNil(summaries[conversation])
    }

    func testASummaryGoesWithTheLastKeptMessageOfItsConversationWhenTheCacheFills() async throws {
        let store = makeStore(limits: limits(cache: 3, ceiling: 4))
        try await store.commit(GmailJournalBatch(changes: (1...5).map { place(UInt64($0)) }, cursor: HistoryID(raw: 1)))
        for n in 1...3 { try await store.cache(message(UInt64(n)), body: nil) }
        var summaries = await store.threadSummaries([ref(1).threadID])
        XCTAssertNotNil(summaries[ref(1).threadID], "a conversation of one message, kept whole")
        // Message 5 belongs among the newest 3 as well, so 1 and 2 both go: keeping 2 until 5 is
        // fetched would only mean letting it go then.
        let evicted = try await store.cache(message(4), body: nil)
        XCTAssertEqual(evicted, [ref(1).id, ref(2).id])
        summaries = await store.threadSummaries([ref(1).threadID, ref(2).threadID, ref(4).threadID])
        XCTAssertNil(summaries[ref(1).threadID])
        XCTAssertNil(summaries[ref(2).threadID])
        XCTAssertNotNil(summaries[ref(4).threadID])
    }

    // MARK: - Disk

    /// The typical account: 55,000 messages in the index and the newest 1,000 kept with bodies of
    /// the usual size. The design allows about 20 MB.
    func testATypicalAccountTakesLessThanTwentyMegabytes() async throws {
        let store = makeStore(limits: limits(cache: 1_000, ceiling: 1_050))
        let total = 55_000
        var offset = 0
        while offset < total {
            let count = min(500, total - offset)
            let refs = (offset..<(offset + count)).map { GmailIndexTests.ref($0) }
            try await store.appendListingPage(GmailListingPage(chain: .allMail(after: nil, before: nil), pageToken: "\(offset)",
                                                               nextPageToken: offset + count < total ? "\(offset + count)" : nil,
                                                               refs: refs, firstOrder: UInt32(total - offset) * 16))
            offset += count
        }
        try await store.commit(GmailJournalBatch(changes: [], cursor: HistoryID(raw: 1)))
        let wanted = await store.messagesToCache(limit: 2_000)
        XCTAssertEqual(wanted.count, 1_000)
        // Mail of the usual size: about 8 KB of text, as text and as HTML, and a 4 KB logo that
        // does not compress. Twenty of each, taken in turn, keep the test quick.
        var generator = GmailStoreRandom(seed: 42)
        let words = ["freight", "invoice", "delivery", "container", "customs", "the", "and", "Baku", "Rotterdam", "shipment", "please", "attached"]
        let texts = (0..<20).map { _ in (0..<1_200).map { _ in words.randomElement(using: &generator)! }.joined(separator: " ") }
        let logos = (0..<20).map { _ in Data((0..<4_000).map { _ in UInt8.random(in: 0...255, using: &generator) }) }
        for (i, id) in wanted.enumerated() {
            let n = id.raw - 0x18a0_0000_0000_0000
            let text = texts[i % texts.count]
            let logo = logos[i % logos.count]
            var row = message(n)
            row.preview = String(text.prefix(100))
            try await store.cache(row, body: GmailReducedBody(textPlain: text, textHTML: "<div>\(text)</div>",
                                                              inlineImages: [GmailInlineImage(contentID: "logo", mimeType: "image/png", data: logo)]))
        }
        try await store.compact()
        let bytes = store.files.diskUsage()
        print("GmailMessageCacheTests: 55,000 indexed and 1,000 kept take \(bytes / 1_024) KB")
        XCTAssertLessThan(bytes, 20 * 1_024 * 1_024)
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        XCTAssertFalse(store.files.directory.path.hasPrefix(cachesDirectory.path), "nothing under ~/Library/Caches")
    }
}
