import XCTest
@testable import FalconCore

/// The store on disk keeps the promises the in-memory double keeps, and keeps them across a
/// relaunch: every scenario here is checked again on a new store reading the same folder.
final class GmailFileStoreTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    /// A fresh account folder in the temporary directory, removed after the test.
    func makeFiles() -> GmailFiles {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GmailFileStoreTests-\(UUID().uuidString)", isDirectory: true)
        directories.append(directory)
        return GmailFiles(directory: directory.appendingPathComponent("Gmail", isDirectory: true))
    }

    private func ref(_ n: UInt64, thread: UInt64? = nil) -> GmailRef {
        GmailRef(id: GmailMessageID(raw: 0x18a0_0000_0000_0000 + n), threadID: GmailThreadID(raw: 0x18a0_0000_0000_0000 + (thread ?? n)))
    }

    private func place(_ n: UInt64, order: UInt32? = nil, labels: Set<GmailLabelID> = [.inbox]) -> GmailChange {
        .place(ref(n), order: order ?? UInt32(n) * 16, labels: labels, attributes: [])
    }

    private func entry(_ id: GmailLabelID, name: String, total: Int, shown: Bool = true) -> GmailLabelEntry {
        GmailLabelEntry(id: id, name: name, kind: id.isUserLabel ? .user : .system, isShown: shown,
                        folderID: GmailLabelTable.folderID(account: UUID(), label: id),
                        counts: GmailLabelCounts(messagesTotal: total, messagesUnread: 0, asOf: Date(timeIntervalSince1970: 1_790_000_000.25)))
    }

    private func reopen(_ store: GmailFileStore) -> GmailFileStore {
        GmailFileStore(accountID: store.accountID, files: store.files)
    }

    // MARK: - The journal and the cursor

    func testChangesApplyAndTheCursorFollowsThemAcrossARelaunch() async throws {
        let store = GmailFileStore(accountID: UUID(), files: makeFiles())
        let empty = try await store.load()
        XCTAssertNil(empty.cursor)
        XCTAssertEqual(empty.messageCount, 0)
        try await store.commit(GmailJournalBatch(changes: [place(1, labels: [.inbox, .unread]), place(2), place(3)], cursor: HistoryID(raw: 10)))
        try await store.commit(GmailJournalBatch(changes: [.relabel(ref(1).id, adding: [.starred], removing: [.unread]),
                                                           .tombstone(ref(2).id)], cursor: HistoryID(raw: 11)))
        try await store.commit(GmailJournalBatch(changes: [.awaitingPlacement(ref(9)), .awaitingPlacement(ref(3))]))

        for current in [store, reopen(store)] {
            let load = try await current.load()
            XCTAssertEqual(load.cursor, HistoryID(raw: 11), "a batch without a cursor leaves it where it was")
            XCTAssertEqual(load.messageCount, 2)
            XCTAssertEqual(load.awaitingPlacement, [ref(9)], "a message already placed does not wait")
            let labels = await current.labels(of: ref(1).id)
            XCTAssertEqual(labels, [.inbox, .starred])
            let index = await current.index()
            XCTAssertEqual(index.byOrder.map { index.records[Int($0)].gmailID }, [ref(1).id, ref(3).id], "oldest first, no tombstones")
            XCTAssertTrue(index.record(for: ref(1).id)?.hasSystemLabel(.starred) == true)
        }
    }

    func testAResyncThatBeganAndDidNotEndIsFoundAtLaunch() async throws {
        let store = GmailFileStore(accountID: UUID(), files: makeFiles())
        try await store.commit(GmailJournalBatch(changes: [place(1)], cursor: HistoryID(raw: 400)))
        try await store.commit(GmailJournalBatch(changes: [.resyncBegan(HistoryID(raw: 500))]))
        var load = try await reopen(store).load()
        XCTAssertEqual(load.resyncBegan, HistoryID(raw: 500))
        XCTAssertEqual(load.cursor, HistoryID(raw: 400), "the cursor does not move until the resync ends")
        try await store.commit(GmailJournalBatch(changes: [.resyncEnded(HistoryID(raw: 500))], cursor: HistoryID(raw: 500)))
        try await store.compact()
        load = try await reopen(store).load()
        XCTAssertNil(load.resyncBegan)
        XCTAssertEqual(load.cursor, HistoryID(raw: 500))
        try await store.commit(GmailJournalBatch(changes: [.resyncBegan(HistoryID(raw: 600))]))
        try await store.compact()
        load = try await reopen(store).load()
        XCTAssertEqual(load.resyncBegan, HistoryID(raw: 600), "the snapshot keeps an unfinished resync too")
    }

    func testListingPagesResumeWhereTheyStoppedAndLeaveLabelsForMessagesNotPlacedYet() async throws {
        let store = GmailFileStore(accountID: UUID(), files: makeFiles())
        try await store.appendListingPage(GmailListingPage(chain: .label(.starred), nextPageToken: "p2", refs: [ref(1), ref(2)],
                                                           labels: [.starred]))
        var load = try await reopen(store).load()
        XCTAssertTrue(load.awaitingPlacement.isEmpty, "All Mail's listing will place them")
        let waiting = await reopen(store).pendingLabels()
        XCTAssertEqual(waiting, [ref(1).id: [.starred], ref(2).id: [.starred]])

        try await store.appendListingPage(GmailListingPage(chain: .label(.starred), pageToken: "p2", refs: [ref(3)], labels: [.starred]))
        try await store.appendListingPage(GmailListingPage(chain: .allMail(after: nil, before: nil), nextPageToken: "a2",
                                                           refs: [ref(3), ref(1)], firstOrder: 1_000))
        load = try await reopen(store).load()
        XCTAssertEqual(load.chains[.label(.starred)], GmailChainProgress(run: 0, nextPageToken: nil, isComplete: true, listed: 3))
        XCTAssertEqual(load.chains[.allMail(after: nil, before: nil)], GmailChainProgress(run: 0, nextPageToken: "a2", isComplete: false, listed: 2))
        XCTAssertNil(load.cursor, "listing pages never move the cursor")
        XCTAssertTrue(load.awaitingPlacement.isEmpty)

        // All Mail's listing ends without message 2, which a label listed: it was skipped, and
        // has to be placed on its own.
        try await store.appendListingPage(GmailListingPage(chain: .allMail(after: nil, before: nil), pageToken: "a2", refs: [],
                                                           firstOrder: 968))
        load = try await reopen(store).load()
        XCTAssertEqual(load.awaitingPlacement, [ref(2)])
        let record = await reopen(store).record(for: ref(3).id)
        XCTAssertEqual(record?.order, 1_000)
        XCTAssertTrue(record?.hasSystemLabel(.starred) == true, "the label listed first is kept")
    }

    // MARK: - Labels

    func testTheLargestShownLabelsTakeTheSlotsAndKeepThemAcrossARelaunch() async throws {
        let store = GmailFileStore(accountID: UUID(), files: makeFiles())
        var entries = [entry(.inbox, name: "INBOX", total: 900), entry(.starred, name: "STARRED", total: 3)]
        for n in 1...50 { entries.append(entry(GmailLabelID("Label_\(n)"), name: "Folder \(n)", total: n * 10)) }
        entries.append(entry("Label_hidden", name: "Hidden", total: 10_000, shown: false))
        let saved = try await store.saveLabelTable(entries)
        let slots = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0.slot) })
        XCTAssertEqual(slots[.inbox], 0)
        XCTAssertEqual(slots[.starred], 6)
        XCTAssertEqual(slots[GmailLabelID("Label_hidden")] ?? nil, nil, "a hidden label costs nothing")
        XCTAssertEqual(Set(saved.filter { $0.kind == .user && $0.slot != nil }.compactMap(\.slot)), Set(16..<64))
        XCTAssertEqual(saved.filter { $0.kind == .user && $0.isShown && $0.slot == nil }.map(\.name).sorted(), ["Folder 1", "Folder 2"])

        let small = GmailLabelID("Label_1")
        let large = GmailLabelID("Label_50")
        try await store.commit(GmailJournalBatch(changes: [place(1, labels: [.inbox, small, large, "Label_hidden"])], cursor: HistoryID(raw: 1)))
        var labels = await reopen(store).labels(of: ref(1).id)
        XCTAssertEqual(labels, [.inbox, small, large])
        let table = await reopen(store).labelTable()
        XCTAssertEqual(table, saved, "the table reads back as saved")

        entries.removeAll { $0.id == large }
        entries[entries.firstIndex { $0.id == GmailLabelID("Label_2") }!].counts?.messagesTotal = 5_000
        try await store.commit(GmailJournalBatch(changes: [.relabel(ref(1).id, adding: ["Label_2"], removing: [])]))
        let resaved = try await store.saveLabelTable(entries)
        XCTAssertNotNil(resaved.first { $0.id == GmailLabelID("Label_2") }?.slot)
        XCTAssertEqual(resaved.first { $0.id == GmailLabelID("Label_49") }?.slot, slots[GmailLabelID("Label_49")] ?? nil)
        for current in [store, reopen(store)] {
            labels = await current.labels(of: ref(1).id)
            XCTAssertEqual(labels, [.inbox, small, "Label_2"], "moving from an overflow list to a bit keeps the members")
            let index = await current.index()
            XCTAssertNil(index.labelSlots[large])
        }

        // The bits and their meaning are saved together: after compaction too.
        try await store.compact()
        labels = await reopen(store).labels(of: ref(1).id)
        XCTAssertEqual(labels, [.inbox, small, "Label_2"])
    }

    func testALabelNewToTheIndexHasNoMembersListedYet() async throws {
        let store = GmailFileStore(accountID: UUID(), files: makeFiles())
        let clients: GmailLabelID = "Label_7"
        var table = [entry(.inbox, name: "INBOX", total: 10), entry(clients, name: "Clients", total: 5, shown: false)]
        table[0].isComplete = true
        table[1].isComplete = true
        var saved = try await store.saveLabelTable(table)
        XCTAssertTrue(saved[0].isComplete, "the engine says when a system label is complete")
        table[1].isShown = true
        saved = try await store.saveLabelTable(table)
        XCTAssertFalse(saved[1].isComplete, "shown now, but nothing of it is listed yet")
        table[1].isComplete = true
        saved = try await store.saveLabelTable(table)
        XCTAssertTrue(saved[1].isComplete)
    }

    func testFolderIDsAreTheSameForTheSameLabelOfTheSameAccount() {
        let account = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        let a = GmailLabelTable.folderID(account: account, label: "Label_12")
        XCTAssertEqual(a, GmailLabelTable.folderID(account: account, label: "Label_12"))
        XCTAssertNotEqual(a, GmailLabelTable.folderID(account: account, label: "Label_13"))
        XCTAssertNotEqual(a, GmailLabelTable.folderID(account: UUID(), label: "Label_12"))
        XCTAssertEqual(a.uuidString.dropFirst(14).first, "5", "shaped as a name-based UUID")
        XCTAssertTrue(GmailLabelTable.isShownByDefault(labelListVisibility: "labelShow"))
        XCTAssertTrue(GmailLabelTable.isShownByDefault(labelListVisibility: "labelShowIfUnread"))
        XCTAssertTrue(GmailLabelTable.isShownByDefault(labelListVisibility: nil))
        XCTAssertFalse(GmailLabelTable.isShownByDefault(labelListVisibility: "labelHide"))
    }

    // MARK: - Compaction

    func testCompactionWritesTheSnapshotAndALeftoverJournalIsNeverAppliedTwice() async throws {
        let files = makeFiles()
        let store = GmailFileStore(accountID: UUID(), files: files)
        try await store.commit(GmailJournalBatch(changes: (1...20).map { place($0) }, cursor: HistoryID(raw: 5)))
        let oldJournal = try Data(contentsOf: files.indexJournal)
        try await store.compact()
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.indexSnapshot.path))
        XCTAssertEqual(try Data(contentsOf: files.indexJournal).count, GmailJournalCodec.headerLength)

        // Deleted and placed again since: replaying the old journal would bring the old record
        // back over the new one.
        try await store.commit(GmailJournalBatch(changes: [.tombstone(ref(3).id)], cursor: HistoryID(raw: 6)))
        try await store.compact()
        // As if the process died after writing the snapshot and before starting the new journal.
        try oldJournal.write(to: files.indexJournal)
        let load = try await reopen(store).load()
        XCTAssertEqual(load.messageCount, 19)
        XCTAssertEqual(load.cursor, HistoryID(raw: 6))
        let gone = await reopen(store).record(for: ref(3).id)
        XCTAssertNil(gone, "the journal of the earlier generation was not applied")
    }

    func testAWriteThatFailsHalfWayIsCutBackAndTheStoreCarriesOn() async throws {
        let files = makeFiles()
        let io = GmailDiskIO()
        let store = GmailFileStore(accountID: UUID(), files: files, io: io)
        try await store.commit(GmailJournalBatch(changes: [place(1)], cursor: HistoryID(raw: 1)))
        let before = try Data(contentsOf: files.indexJournal)
        io.refuse = { if case .append = $0 { return true }; return false }
        do {
            try await store.commit(GmailJournalBatch(changes: [place(2), place(3)], cursor: HistoryID(raw: 2)))
            XCTFail("a full disk refuses the write")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: files.indexJournal), before, "half a batch is never left behind")
        var load = try await store.load()
        XCTAssertEqual(load.cursor, HistoryID(raw: 1), "and nothing of it is applied")
        XCTAssertEqual(load.messageCount, 1)
        io.refuse = nil
        try await store.commit(GmailJournalBatch(changes: [place(2), place(3)], cursor: HistoryID(raw: 2)))
        load = try await reopen(store).load()
        XCTAssertEqual(load.cursor, HistoryID(raw: 2))
        XCTAssertEqual(load.messageCount, 3)
    }

    func testAJournalThatCouldNotStartAfreshIsStartedBeforeTheNextAppend() async throws {
        let files = makeFiles()
        let io = GmailDiskIO()
        let store = GmailFileStore(accountID: UUID(), files: files, io: io)
        try await store.commit(GmailJournalBatch(changes: [place(1), place(2)], cursor: HistoryID(raw: 1)))
        // The snapshot is written; starting the new journal fails.
        io.refuse = { if case .replace(let url, _) = $0 { return url == files.indexJournal }; return false }
        do {
            try await store.compact()
            XCTFail("the new journal could not be started")
        } catch {}
        io.refuse = nil
        // The old journal is the snapshot's now; this must not go into it.
        try await store.commit(GmailJournalBatch(changes: [place(3), .tombstone(ref(1).id)], cursor: HistoryID(raw: 2)))
        let load = try await reopen(store).load()
        XCTAssertEqual(load.cursor, HistoryID(raw: 2))
        XCTAssertEqual(load.messageCount, 2)
        let gone = await reopen(store).record(for: ref(1).id)
        XCTAssertTrue(gone?.attributes.contains(.tombstone) == true, "deleted after the snapshot: a tombstone until the next")
    }

    func testTheStoreCompactsByItselfOnceTheJournalIsLong() async throws {
        var limits = GmailFileStore.Limits()
        limits.compactOperations = 50
        let files = makeFiles()
        let store = GmailFileStore(accountID: UUID(), files: files, limits: limits)
        for n in 1...49 {
            try await store.commit(GmailJournalBatch(changes: [place(UInt64(n))], cursor: HistoryID(raw: UInt64(n))))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.indexSnapshot.path))
        try await store.commit(GmailJournalBatch(changes: [place(50)], cursor: HistoryID(raw: 50)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.indexSnapshot.path))
        let load = try await reopen(store).load()
        XCTAssertEqual(load.messageCount, 50)
        XCTAssertEqual(load.cursor, HistoryID(raw: 50))
    }

    func testAnUnreadableIndexIsSetAsideAndListedAgainFromGmail() async throws {
        let files = makeFiles()
        let store = GmailFileStore(accountID: UUID(), files: files)
        try await store.commit(GmailJournalBatch(changes: (1...5).map { place($0) }, cursor: HistoryID(raw: 5)))
        try await store.compact()
        try await store.commit(GmailJournalBatch(changes: [place(6)], cursor: HistoryID(raw: 6)))
        var snapshot = try Data(contentsOf: files.indexSnapshot)
        snapshot[40] ^= 0xFF
        try snapshot.write(to: files.indexSnapshot)

        let load = try await reopen(store).load()
        XCTAssertNil(load.cursor, "no cursor, so the engine lists everything again")
        XCTAssertEqual(load.messageCount, 0)
        let aside = AtomicFile.setAsideCopies(of: files.indexSnapshot)
        XCTAssertEqual(aside.count, 1, "the damaged file is kept, not written over")
        XCTAssertEqual(AtomicFile.setAsideCopies(of: files.indexJournal).count, 1, "and so is the journal that followed it")
        _ = StoredFileNotices.take()
    }

    // MARK: - Keeping what the double keeps

    /// The same random work given to the double and to the store on disk, which is closed and read
    /// again now and then, and compacted now and then: every answer the engine reads agrees.
    func testTheStoreAgreesWithTheDoubleAcrossRelaunchesAndCompactions() async throws {
        continueAfterFailure = false
        var generator = GmailStoreRandom(seed: 0x6732_7374)
        let files = makeFiles()
        let double = MemoryGmailStore()
        var store = GmailFileStore(accountID: UUID(), files: files)
        let userLabels = (1...52).map { GmailLabelID("Label_\($0)") }
        let labels: [GmailLabelID] = [.inbox, .unread, .starred, .spam, .trash, .sent] + userLabels
        let entries = userLabels.enumerated().map { i, label in entry(label, name: "Folder \(i)", total: 100 - i) }
        try await double.saveLabelTable(entries)
        try await store.saveLabelTable(entries)

        func randomLabels() -> Set<GmailLabelID> {
            Set((0..<Int.random(in: 0...3, using: &generator)).map { _ in labels.randomElement(using: &generator)! })
        }
        // Gmail never gives a deleted message's id to another, and a snapshot forgets deleted
        // messages where the double keeps them, so a deleted id is never used again here.
        var pool = Array(UInt64(0)..<80)
        var fresh: UInt64 = 80
        func randomRef() -> GmailRef {
            let n = pool.randomElement(using: &generator)!
            return ref(n, thread: n % 40)
        }
        func retire(_ id: GmailMessageID) {
            guard let at = pool.firstIndex(of: id.raw - 0x18a0_0000_0000_0000) else { return }
            pool[at] = fresh
            fresh += 1
        }
        var run: UInt32 = 0
        var cursor: UInt64 = 0
        for step in 0..<1_500 {
            switch Int.random(in: 0..<12, using: &generator) {
            case 0...5:
                var changes: [GmailChange] = []
                for _ in 0..<Int.random(in: 1...4, using: &generator) {
                    switch Int.random(in: 0..<6, using: &generator) {
                    case 0, 1:
                        changes.append(.place(randomRef(), order: UInt32.random(in: 0...2_000, using: &generator), labels: randomLabels(),
                                              attributes: Bool.random(using: &generator) ? [.provisional] : []))
                    case 2, 3:
                        let adding = randomLabels()
                        changes.append(.relabel(randomRef().id, adding: adding, removing: randomLabels().subtracting(adding)))
                    case 4:
                        let gone = randomRef()
                        retire(gone.id)
                        changes.append(.tombstone(gone.id))
                    default:
                        changes.append(.awaitingPlacement(randomRef()))
                    }
                }
                cursor += 1
                let batch = GmailJournalBatch(changes: changes, cursor: Bool.random(using: &generator) ? HistoryID(raw: cursor) : nil)
                try await double.commit(batch)
                try await store.commit(batch)
            case 6, 7:
                if Int.random(in: 0..<4, using: &generator) == 0 { run += 1 }
                let page = GmailListingPage(chain: .allMail(after: nil, before: nil), run: run,
                                            nextPageToken: Bool.random(using: &generator) ? "more" : nil,
                                            refs: (0..<Int.random(in: 1...40, using: &generator)).map { _ in randomRef() },
                                            firstOrder: UInt32.random(in: 700...3_000, using: &generator))
                try await double.appendListingPage(page)
                try await store.appendListingPage(page)
            case 8, 9:
                let label = labels.randomElement(using: &generator)!
                let page = GmailListingPage(chain: .label(label), pageToken: "\(step)", nextPageToken: Bool.random(using: &generator) ? "n" : nil,
                                            refs: (0..<Int.random(in: 1...30, using: &generator)).map { _ in randomRef() }, labels: [label])
                try await double.appendListingPage(page)
                try await store.appendListingPage(page)
            case 10:
                try await store.compact()
            default:
                store = reopen(store)
            }
            if step % 50 == 0 || step == 1_499 {
                try await assertSame(store, double, step: step)
            }
        }
        store = reopen(store)
        try await assertSame(store, double, step: -1)
    }

    private func assertSame(_ store: GmailFileStore, _ double: MemoryGmailStore, step: Int,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        let mine = await store.index()
        let theirs = await double.index()
        let ids = { (s: GmailIndexSnapshot) in s.byOrder.map { s.records[Int($0)].gmailID } }
        XCTAssertEqual(ids(mine), ids(theirs), "order at step \(step)", file: file, line: line)
        for slot in theirs.byOrder {
            let record = theirs.records[Int(slot)]
            let own = mine.record(for: record.gmailID)
            XCTAssertEqual(own?.order, record.order, file: file, line: line)
            XCTAssertEqual(own?.threadID, record.threadID, file: file, line: line)
            XCTAssertEqual(own?.attributes, record.attributes, "attributes of \(record.gmailID) at step \(step)", file: file, line: line)
            let a = await store.labels(of: record.gmailID)
            let b = await double.labels(of: record.gmailID)
            XCTAssertEqual(a, b, "labels of \(record.gmailID) at step \(step)", file: file, line: line)
        }
        let a = try await store.load()
        let b = try await double.load()
        XCTAssertEqual(a.cursor, b.cursor, "cursor at step \(step)", file: file, line: line)
        XCTAssertEqual(a.resyncBegan, b.resyncBegan, file: file, line: line)
        XCTAssertEqual(a.chains, b.chains, "listings at step \(step)", file: file, line: line)
        XCTAssertEqual(a.messageCount, b.messageCount, file: file, line: line)
        let waiting = await store.pendingLabels()
        let theirWaiting = await double.awaitingLabels()
        XCTAssertEqual(waiting, theirWaiting, "messages waiting at step \(step)", file: file, line: line)
    }

    // MARK: - Summaries, anchors and imports

    func testSummariesAnchorsAndTheImportLogAreKeptAcrossARelaunch() async throws {
        let store = GmailFileStore(accountID: UUID(), files: makeFiles())
        try await store.commit(GmailJournalBatch(changes: [place(1), place(3)], cursor: HistoryID(raw: 1)))
        let thread = ref(1).threadID
        let summary = GmailThreadSummary(threadID: thread, senders: [EmailAddress(address: "ana@example.com")], messageCount: 2,
                                         newestDate: Date(timeIntervalSince1970: 1_790_000_000.125),
                                         members: [GmailThreadMember(id: ref(1).id, from: EmailAddress(address: "ana@example.com"),
                                                                     date: Date(timeIntervalSince1970: 1_789_000_000.5))])
        // A summary is kept for a conversation with a kept message.
        try await store.cache(cachedMessage(1), body: nil)
        try await store.saveThreadSummaries([summary])
        var summaries = await reopen(store).threadSummaries([thread, ref(2).threadID])
        XCTAssertEqual(summaries, [thread: summary], "dates come back to the millisecond")
        try await store.removeThreadSummaries([thread])
        summaries = await reopen(store).threadSummaries([thread])
        XCTAssertTrue(summaries.isEmpty)

        let anchor = GmailDateAnchor(boundary: Date(timeIntervalSince1970: 1_789_000_000), id: ref(3).id, order: 48,
                                     askedAt: Date(timeIntervalSince1970: 1_790_000_000.75))
        try await store.saveDateAnchors([anchor])
        var anchors = await reopen(store).dateAnchors()
        XCTAssertEqual(anchors, [anchor])
        // The anchor's message is deleted: the next older message is now the newest one older
        // than the boundary.
        try await store.commit(GmailJournalBatch(changes: [.tombstone(ref(3).id)], cursor: HistoryID(raw: 2)))
        anchors = await reopen(store).dateAnchors()
        XCTAssertEqual(anchors.first?.id, ref(1).id)
        XCTAssertEqual(anchors.first?.order, 16)

        let now = Date()
        try await store.noteImported([ref(1).id], at: now.addingTimeInterval(-8 * 86_400))
        try await store.noteImported([ref(2).id, ref(4).id], at: now)
        let old = await store.wasImported(ref(1).id)
        XCTAssertFalse(old, "kept for 7 days")
        let reopened = reopen(store)
        let recent = await reopened.wasImported(ref(2).id)
        let other = await reopened.wasImported(ref(4).id)
        let never = await reopened.wasImported(ref(9).id)
        XCTAssertTrue(recent)
        XCTAssertTrue(other)
        XCTAssertFalse(never)
    }

    func testAnImportOverAWeekOldIsForgottenAtLaunch() async throws {
        let store = GmailFileStore(accountID: UUID(), files: makeFiles())
        try await store.noteImported([ref(1).id], at: Date().addingTimeInterval(-8 * 86_400))
        let stale = await store.wasImported(ref(1).id)
        XCTAssertTrue(stale, "nothing newer has been imported to expire it yet")
        let later = await reopen(store).wasImported(ref(1).id)
        XCTAssertFalse(later)
    }

    // MARK: - The whole mailbox through the store

    /// 200,000 messages listed through the store, flushed page by page as the engine lists them,
    /// then read back at the next launch.
    func testTwoHundredThousandMessagesThroughTheStoreReadBackAtLaunch() async throws {
        let files = makeFiles()
        let store = GmailFileStore(accountID: UUID(), files: files)
        let total = 200_000
        let started = Date()
        var offset = 0
        while offset < total {
            let count = min(500, total - offset)
            let refs = (offset..<(offset + count)).map { GmailIndexTests.ref($0, thread: $0 - $0 % 3) }
            try await store.appendListingPage(GmailListingPage(chain: .allMail(after: nil, before: nil),
                                                               pageToken: offset == 0 ? nil : "\(offset)",
                                                               nextPageToken: offset + count < total ? "\(offset + count)" : nil,
                                                               refs: refs, firstOrder: UInt32(total - offset) * 16))
            offset += count
        }
        let listed = Date().timeIntervalSince(started)
        try await store.commit(GmailJournalBatch(changes: [], cursor: HistoryID(raw: 77)))
        let memory = await store.indexMemory()
        print("GmailFileStoreTests: 400 pages of 200,000 messages listed and flushed in \(String(format: "%.2f", listed)) s, "
              + "journal \(try Data(contentsOf: files.indexJournal).count / 1_024) KB, index \(memory / 1_024) KB")
        XCTAssertLessThan(memory, 15 * 1_024 * 1_024)

        var launched = Date()
        var load = try await reopen(store).load()
        print("GmailFileStoreTests: launch from the journal alone in \(String(format: "%.3f", Date().timeIntervalSince(launched))) s")
        XCTAssertEqual(load.messageCount, total)
        XCTAssertEqual(load.cursor, HistoryID(raw: 77))

        try await store.compact()
        // The best of three launches, since other work on the Mac can slow any one of them.
        var fromSnapshot = Double.infinity
        var reopened = reopen(store)
        for _ in 0..<3 {
            launched = Date()
            reopened = reopen(store)
            load = try await reopened.load()
            fromSnapshot = min(fromSnapshot, Date().timeIntervalSince(launched))
        }
        print("GmailFileStoreTests: launch from the snapshot in \(String(format: "%.3f", fromSnapshot)) s; "
              + "Gmail folder \(files.diskUsage() / 1_024) KB")
        XCTAssertLessThan(fromSnapshot, 1.0)
        XCTAssertEqual(load.messageCount, total)
        let reopenedMemory = await reopened.indexMemory()
        XCTAssertLessThan(reopenedMemory, 15 * 1_024 * 1_024)
        XCTAssertLessThan(files.diskUsage(), 7 * 1_024 * 1_024, "6.4 MB on disk at 200,000")
    }

    private func cachedMessage(_ n: UInt64) -> GmailCachedMessage {
        GmailCachedMessage(id: ref(n).id, threadID: ref(n).threadID, from: EmailAddress(address: "ana@example.com"), subject: "Mail \(n)",
                           preview: "Hello", date: Date(timeIntervalSince1970: 1_790_000_000 + Double(n)), size: 100,
                           hasAttachments: false, messageID: "<\(n)@x>", cachedAt: Date())
    }
}
