import Darwin
import XCTest
@testable import FalconCore

/// The index of every message: 32 bytes each, built from listings, kept in order, and read back
/// from its snapshot. Built in memory here; the journal's own tests cover the disk.
final class GmailIndexTests: XCTestCase {
    static func ref(_ n: Int, thread: Int? = nil) -> GmailRef {
        GmailRef(id: GmailMessageID(raw: 0x18a0_0000_0000_0000 + UInt64(n)),
                 threadID: GmailThreadID(raw: 0x18a0_0000_0000_0000 + UInt64(thread ?? n)))
    }

    private func ref(_ n: Int, thread: Int? = nil) -> GmailRef { GmailIndexTests.ref(n, thread: thread) }

    /// The ids in the order the index keeps them, oldest first.
    static func orderedIDs(_ index: GmailIndex) -> [GmailMessageID] {
        index.byOrder.map { index.records[Int($0)].gmailID }
    }

    /// What must hold after anything: the order holds every live record once, sorted, and no
    /// tombstone; each overflow list is sorted and holds only live records.
    static func assertConsistent(_ index: GmailIndex, file: StaticString = #filePath, line: UInt = #line) {
        let live = index.records.indices.filter { !index.records[$0].attributes.contains(.tombstone) }.map(Int32.init)
        XCTAssertEqual(index.byOrder.count, live.count, "the order holds every live record", file: file, line: line)
        XCTAssertEqual(Set(index.byOrder), Set(live), file: file, line: line)
        XCTAssertEqual(index.liveCount, live.count, file: file, line: line)
        for i in index.byOrder.indices.dropFirst() {
            let a = index.records[Int(index.byOrder[i - 1])]
            let b = index.records[Int(index.byOrder[i])]
            XCTAssertTrue((a.order, a.id) < (b.order, b.id), "the order is sorted at \(i)", file: file, line: line)
        }
        for (slot, record) in index.records.enumerated() {
            XCTAssertEqual(index.slotByID[record.id], Int32(slot), file: file, line: line)
        }
        for (label, members) in index.overflow {
            XCTAssertEqual(Array(members), members.sorted(), "\(label) is sorted", file: file, line: line)
            XCTAssertEqual(Set(members).count, members.count, file: file, line: line)
            XCTAssertTrue(members.allSatisfy { !index.records[Int($0)].attributes.contains(.tombstone) }, file: file, line: line)
        }
    }

    // MARK: - Size

    func testARecordIsThirtyTwoBytes() {
        XCTAssertEqual(MemoryLayout<GmailIndexRecord>.size, 32)
        XCTAssertEqual(MemoryLayout<GmailIndexRecord>.stride, 32)
    }

    /// The whole mailbox of 200,000 messages, listed newest first 500 at a time as All Mail's
    /// listing gives it, then the Inbox and Unread listings. The design allows a second and 15 MB.
    func testTwoHundredThousandRecordsBuildInUnderASecondWithinFifteenMegabytes() throws {
        continueAfterFailure = false
        let total = 200_000
        // The best of three builds, since other work on the Mac can slow any one of them.
        var built = Double.infinity
        for _ in 0..<2 {
            let trial = GmailIndex()
            let started = Date()
            GmailIndexTests.listAllMail(total, into: trial)
            built = min(built, Date().timeIntervalSince(started))
        }
        let before = GmailIndexTests.footprint()
        let index = GmailIndex()
        let started = Date()
        GmailIndexTests.listAllMail(total, into: index)
        built = min(built, Date().timeIntervalSince(started))
        XCTAssertLessThan(built, 1.0, "200,000 records built in \(built) s")
        XCTAssertEqual(index.liveCount, total)
        XCTAssertEqual(index.records.count, total)

        // Counted from what the index's arrays hold and its table of ids whole. The process's
        // footprint is printed too, but cannot be asserted on: memory freed by earlier tests is
        // used again, so it understates.
        let memory = index.approximateMemory
        let grown = GmailIndexTests.footprint() - before
        print("GmailIndexTests: 200,000 records built in \(String(format: "%.3f", built)) s; "
              + "index \(memory / 1_024) KB, footprint grew \(grown / 1_024) KB")
        XCTAssertLessThan(memory, 15 * 1_024 * 1_024, "the index's arrays and table fit in 15 MB")

        // Order: record i of All Mail's listing is (N − i) × 16, so the oldest comes first.
        XCTAssertEqual(index.records[Int(index.byOrder[0])].gmailID, ref(total - 1).id)
        XCTAssertEqual(index.records[Int(index.byOrder[total - 1])].gmailID, ref(0).id)
        XCTAssertEqual(index.record(for: ref(0).id)?.order, UInt32(total) * 16)

        // Labels listed afterwards set bits on records already placed.
        let labelStart = Date()
        for label: GmailLabelID in [.inbox, .unread] {
            let members = stride(from: 0, to: total, by: label == .inbox ? 2 : 7).map { ref($0) }
            for (p, chunk) in members.storeChunks(500).enumerated() {
                index.apply(GmailListingPage(chain: .label(label), pageToken: p == 0 ? nil : "\(p)",
                                             nextPageToken: (p + 1) * 500 < members.count ? "\(p + 1)" : nil, refs: chunk, labels: [label]))
            }
        }
        print("GmailIndexTests: Inbox and Unread listings applied in \(String(format: "%.3f", Date().timeIntervalSince(labelStart))) s")
        XCTAssertTrue(index.record(for: ref(4).id)!.hasSystemLabel(.inbox))
        XCTAssertFalse(index.record(for: ref(3).id)!.hasSystemLabel(.inbox))
        XCTAssertTrue(index.record(for: ref(14).id)!.hasSystemLabel(.unread))
        let inbox = index.records.reduce(0) { $0 + ($1.hasSystemLabel(.inbox) ? 1 : 0) }
        XCTAssertEqual(inbox, total / 2, "Items is the folder's real total")

        // The snapshot reads back to the same index, in well under a second.
        let data = index.encodedSnapshot(nextGeneration: 2)
        XCTAssertEqual(data.count / 1_024 / 1_024, 6, "6.4 MB on disk at 200,000")
        var read = Double.infinity
        for _ in 0..<2 {
            let readStart = Date()
            _ = try GmailIndex.decodeSnapshot(data)
            read = min(read, Date().timeIntervalSince(readStart))
        }
        let readStart = Date()
        let (loaded, generation) = try GmailIndex.decodeSnapshot(data)
        read = min(read, Date().timeIntervalSince(readStart))
        print("GmailIndexTests: snapshot of \(data.count / 1_024) KB read in \(String(format: "%.3f", read)) s")
        XCTAssertLessThan(read, 1.0)
        XCTAssertEqual(generation, 2)
        XCTAssertTrue(loaded.records.elementsEqual(index.byOrder.lazy.map { index.records[Int($0)] }),
                      "the records come back oldest first, each as it was")
        XCTAssertEqual(GmailIndexTests.orderedIDs(loaded), GmailIndexTests.orderedIDs(index))
        XCTAssertEqual(loaded.chains, index.chains)
        XCTAssertLessThan(loaded.approximateMemory, 15 * 1_024 * 1_024)
    }

    /// A mailbox moved from Outlook by olm2cloud: 200,000 messages, 150 labels, 70% of the mail in
    /// them. The 48 largest labels take bits; the rest keep lists of 4 bytes a member.
    func testAHundredAndFiftyLabelsTakeFortyEightBitsAndTheRestOverflow() throws {
        let total = 200_000
        let index = GmailIndex()
        GmailIndexTests.listAllMail(total, into: index)
        var entries: [GmailLabelEntry] = []
        var membership: [GmailLabelID: [Int]] = [:]
        // Label k holds every message n with n % 150 == k among the labelled 70%, and sizes vary
        // with k so that the largest are clear.
        for k in 0..<150 {
            let label = GmailLabelID("Label_\(k + 1)")
            let members = stride(from: k, to: total * 7 / 10, by: 150).filter { $0 % 1_000 < 400 + k * 4 }
            membership[label] = members
            entries.append(GmailLabelEntry(id: label, name: "Folder \(k + 1)", kind: .user, isShown: true,
                                           folderID: GmailLabelTable.folderID(account: UUID(), label: label),
                                           counts: GmailLabelCounts(messagesTotal: members.count, messagesUnread: 0, asOf: Date())))
        }
        let (assigned, map) = GmailLabelTable.assign(entries, current: index.slotMap)
        index.apply(map)
        XCTAssertEqual(map.userSlots.count, 48)
        XCTAssertEqual(map.overflow.count, 102)
        let slotted = Set(map.userSlots.keys)
        let largest = Set(entries.sorted { $0.counts!.messagesTotal > $1.counts!.messagesTotal }.prefix(48).map(\.id))
        XCTAssertEqual(slotted, largest, "the 48 largest take the bits")
        XCTAssertTrue(assigned.allSatisfy { ($0.slot != nil) == slotted.contains($0.id) })

        let started = Date()
        for (label, members) in membership {
            let refs = members.map { ref($0) }
            for (p, chunk) in refs.storeChunks(500).enumerated() {
                index.apply(GmailListingPage(chain: .label(label), pageToken: p == 0 ? nil : "\(p)",
                                             nextPageToken: (p + 1) * 500 < refs.count ? "\(p + 1)" : nil, refs: chunk, labels: [label]))
            }
        }
        print("GmailIndexTests: 150 label listings applied in \(String(format: "%.3f", Date().timeIntervalSince(started))) s")
        let memberships = index.overflow.values.reduce(0) { $0 + $1.count }
        print("GmailIndexTests: \(memberships) overflow memberships, index \(index.approximateMemory / 1_024) KB")
        XCTAssertLessThan(index.approximateMemory, 15 * 1_024 * 1_024)
        GmailIndexTests.assertConsistent(index)

        for n in [0, 1, 149, 150, 151, 7_777, 139_999, 140_000, 199_999] {
            let expected = Set(membership.filter { $0.value.contains(n) }.map(\.key))
            XCTAssertEqual(index.labels(atSlot: index.slot(of: ref(n).id)!), expected, "message \(n)")
        }
        let snapshot = index.snapshot()
        let small = GmailLabelID("Label_1")
        XCTAssertNotNil(snapshot.overflow[small])
        XCTAssertTrue(snapshot.record(atSlot: snapshot.slotByID[ref(0).id.raw]!, has: small))
        XCTAssertFalse(snapshot.record(atSlot: snapshot.slotByID[ref(1).id.raw]!, has: small))

        // A label that grows past the smallest slotted one by far takes its bit, and every
        // message keeps every label through the move.
        var grown = assigned
        grown[0].counts?.messagesTotal = 10_000
        let (_, regrown) = GmailLabelTable.assign(grown, current: index.slotMap)
        XCTAssertNotNil(regrown.userSlots[small])
        index.apply(regrown)
        GmailIndexTests.assertConsistent(index)
        for n in [0, 150, 7_777, 139_999] {
            let expected = Set(membership.filter { $0.value.contains(n) }.map(\.key))
            XCTAssertEqual(index.labels(atSlot: index.slot(of: ref(n).id)!), expected, "message \(n) after the move")
        }

        let (loaded, _) = try GmailIndex.decodeSnapshot(index.encodedSnapshot(nextGeneration: 1))
        GmailIndexTests.assertConsistent(loaded)
        for n in [0, 150, 7_777, 139_999, 199_999] {
            XCTAssertEqual(loaded.labels(atSlot: loaded.slot(of: ref(n).id)!), index.labels(atSlot: index.slot(of: ref(n).id)!))
        }
    }

    // MARK: - Keeping the order

    func testNewMailGoesOnTopAndDeepPlacementsSlotIn() {
        let index = GmailIndex()
        index.apply(GmailListingPage(chain: .allMail(after: nil, before: nil), refs: (0..<100).map { ref($0) }, firstOrder: 100 * 16))
        index.apply(.place(ref(500), order: 100 * 16 + 16, labels: [.inbox, .unread], attributes: []))
        index.apply(.place(ref(501), order: 50 * 16 + 8, labels: [.inbox], attributes: []))
        GmailIndexTests.assertConsistent(index)
        let ids = GmailIndexTests.orderedIDs(index)
        XCTAssertEqual(ids.last, ref(500).id, "new mail on top")
        let deep = ids.firstIndex(of: ref(501).id)!
        XCTAssertEqual(ids[deep - 1], ref(50).id)
        XCTAssertEqual(ids[deep + 1], ref(49).id)

        // A relisting gives everything a new place at once.
        let relisted = [ref(500)] + (0..<50).map { ref($0) } + [ref(501)] + (50..<100).map { ref($0) }
        index.apply(GmailListingPage(chain: .allMail(after: nil, before: nil), run: 1, refs: relisted, firstOrder: 200 * 16))
        GmailIndexTests.assertConsistent(index)
        XCTAssertEqual(GmailIndexTests.orderedIDs(index), relisted.reversed().map(\.id))
        XCTAssertTrue(index.record(for: ref(500).id)!.hasSystemLabel(.unread), "a listing never takes a label away")
        XCTAssertEqual(index.chains[.allMail(after: nil, before: nil)]?.run, 1)
        XCTAssertEqual(index.chains[.allMail(after: nil, before: nil)]?.listed, 102, "a new run counts from the start")
    }

    func testTombstonesLeaveTheOrderAndComeBackWhenListedAgain() {
        let index = GmailIndex()
        let starred: GmailLabelID = "Label_9"
        index.apply(GmailSlotMap(userSlots: [:], overflow: [starred]))
        index.apply(GmailListingPage(chain: .allMail(after: nil, before: nil), refs: (0..<10).map { ref($0) }, firstOrder: 160))
        index.apply(.relabel(ref(3).id, adding: [starred], removing: []))
        XCTAssertEqual(index.overflow[starred], [index.slot(of: ref(3).id)!])
        index.apply(.tombstone(ref(3).id))
        index.apply(.tombstone(ref(3).id))
        GmailIndexTests.assertConsistent(index)
        XCTAssertEqual(index.liveCount, 9)
        XCTAssertEqual(index.overflow[starred], [], "a deleted message leaves every list")
        XCTAssertFalse(index.isLive(ref(3).id))
        XCTAssertNotNil(index.record(for: ref(3).id), "its slot stays until the snapshot is read again")

        index.apply(.place(ref(3), order: 999, labels: [.inbox, starred], attributes: [.hasAttachment, .attachmentKnown]))
        GmailIndexTests.assertConsistent(index)
        XCTAssertEqual(index.liveCount, 10)
        XCTAssertEqual(index.slot(of: ref(3).id), 3, "it comes back in its own slot")
        XCTAssertEqual(GmailIndexTests.orderedIDs(index).last, ref(3).id)
        XCTAssertEqual(index.labels(atSlot: 3), [.inbox, starred])

        let (loaded, _) = try! GmailIndex.decodeSnapshot(index.encodedSnapshot(nextGeneration: 1))
        index.apply(.tombstone(ref(5).id))
        let (compacted, _) = try! GmailIndex.decodeSnapshot(index.encodedSnapshot(nextGeneration: 1))
        XCTAssertEqual(loaded.records.count, 10)
        XCTAssertEqual(compacted.records.count, 9, "a snapshot leaves tombstones out")
        XCTAssertNil(compacted.record(for: ref(5).id))
        GmailIndexTests.assertConsistent(compacted)
    }

    func testTheCacheAndTombstoneBitsBelongToTheIndexAlone() {
        let index = GmailIndex()
        index.apply(.place(ref(1), order: 16, labels: [.inbox], attributes: [.cached, .tombstone, .hasAttachment]))
        XCTAssertEqual(index.record(for: ref(1).id)?.attributes, [.hasAttachment])
        XCTAssertTrue(index.isLive(ref(1).id))
        index.apply(.attributes(ref(1).id, setting: [.tombstone, .cached, .sizeKnown], clearing: [.hasAttachment]))
        XCTAssertEqual(index.record(for: ref(1).id)?.attributes, [.sizeKnown])
        index.setCached(ref(1).id, true)
        index.apply(.place(ref(1), order: 32, labels: [.inbox], attributes: []))
        XCTAssertEqual(index.record(for: ref(1).id)?.attributes, [.cached], "placing again keeps a kept message's bit")
        index.apply(GmailListingPage(chain: .search("larger:1M"), refs: [ref(1)], attributes: {
            var a: GmailRecordAttributes = [.sizeKnown, .cached]
            a.sizeBand = .large
            return a
        }()))
        let attributes = index.record(for: ref(1).id)!.attributes
        XCTAssertEqual(attributes.sizeBand, .large)
        XCTAssertTrue(attributes.contains(.cached))
    }

    func testALabelBothAddedAndRemovedIsRemovedWhetherItHasABitOrAList() {
        let index = GmailIndex()
        let listed: GmailLabelID = "Label_2"
        index.apply(GmailSlotMap(userSlots: ["Label_1": 16], overflow: [listed]))
        index.apply(.place(ref(1), order: 16, labels: [.inbox], attributes: []))
        index.apply(.relabel(ref(1).id, adding: ["Label_1", listed, .starred], removing: ["Label_1", listed]))
        XCTAssertEqual(index.labels(atSlot: 0), [.inbox, .starred], "labels added, then labels removed")
        XCTAssertEqual(index.overflow[listed], [])
    }

    func testLabelsListedBeforeAllMailWaitForTheMessage() {
        let index = GmailIndex()
        index.apply(GmailListingPage(chain: .label(.inbox), refs: [ref(1), ref(2)], labels: [.inbox]))
        index.apply(.relabel(ref(2).id, adding: [.starred], removing: [.inbox]))
        index.apply(.awaitingPlacement(ref(3)))
        XCTAssertEqual(index.pending[ref(1).id.raw]?.labels, [.inbox])
        XCTAssertEqual(index.pending[ref(1).id.raw]?.awaiting, false, "All Mail's listing will place it")
        XCTAssertEqual(index.pending[ref(2).id.raw]?.labels, [.starred])
        XCTAssertEqual(index.pending[ref(3).id.raw]?.awaiting, true)
        XCTAssertFalse(index.allMailListed)

        index.apply(GmailListingPage(chain: .allMail(after: nil, before: nil), refs: [ref(2), ref(1)], firstOrder: 32))
        XCTAssertTrue(index.allMailListed)
        XCTAssertNil(index.pending[ref(1).id.raw])
        XCTAssertEqual(index.labels(atSlot: index.slot(of: ref(1).id)!), [.inbox])
        XCTAssertEqual(index.labels(atSlot: index.slot(of: ref(2).id)!), [.starred])
        XCTAssertEqual(index.pending.count, 1)
        index.apply(.place(ref(3), order: 48, labels: [.sent], attributes: []))
        XCTAssertTrue(index.pending.isEmpty)
    }

    /// The index and the in-memory double agree, operation by operation, on everything the
    /// engine reads: which messages are live, their order, their labels and attributes, the
    /// listings' progress and the cursor.
    func testTheIndexAgreesWithTheStoreDoubleOverRandomWork() async throws {
        continueAfterFailure = false
        var generator = GmailStoreRandom(seed: 0x6d61_696c)
        let double = MemoryGmailStore()
        let index = GmailIndex()
        let userLabels = (1...52).map { GmailLabelID("Label_\($0)") }
        let labels: [GmailLabelID] = [.inbox, .unread, .starred, .spam, .trash, .sent] + userLabels
        let entries = userLabels.enumerated().map { i, label in
            GmailLabelEntry(id: label, name: "Folder \(i)", kind: .user, isShown: true, folderID: UUID(),
                            counts: GmailLabelCounts(messagesTotal: 100 - i, messagesUnread: 0, asOf: Date()))
        }
        try await double.saveLabelTable(entries)
        index.apply(GmailLabelTable.assign(entries, current: index.slotMap).map)
        XCTAssertEqual(index.slotMap.overflow.count, 4)

        func randomLabels() -> Set<GmailLabelID> {
            Set((0..<Int.random(in: 0...3, using: &generator)).map { _ in labels.randomElement(using: &generator)! })
        }
        func randomRef() -> GmailRef { ref(Int.random(in: 0..<60, using: &generator), thread: Int.random(in: 0..<20, using: &generator)) }
        var run: UInt32 = 0
        for step in 0..<3_000 {
            switch Int.random(in: 0..<10, using: &generator) {
            case 0, 1:
                let change = GmailChange.place(randomRef(), order: UInt32.random(in: 0...2_000, using: &generator), labels: randomLabels(),
                                               attributes: Bool.random(using: &generator) ? [.hasAttachment, .attachmentKnown] : [])
                index.apply(change)
                try await double.commit(GmailJournalBatch(changes: [change]))
            case 2, 3:
                // A label both added and removed is removed, as the contract says; the double adds
                // it to an overflow list and takes its bit away, so the two are only compared on
                // changes that do not name a label twice.
                let adding = randomLabels()
                let change = GmailChange.relabel(randomRef().id, adding: adding, removing: randomLabels().subtracting(adding))
                index.apply(change)
                try await double.commit(GmailJournalBatch(changes: [change]))
            case 4:
                let change = GmailChange.tombstone(randomRef().id)
                index.apply(change)
                try await double.commit(GmailJournalBatch(changes: [change]))
            case 5:
                let change = GmailChange.awaitingPlacement(randomRef())
                index.apply(change)
                try await double.commit(GmailJournalBatch(changes: [change]))
            case 6:
                let change = GmailChange.attributes(randomRef().id, setting: [.provisional], clearing: [.hasAttachment])
                index.apply(change)
                try await double.commit(GmailJournalBatch(changes: [change]))
            case 7:
                if Bool.random(using: &generator) { run += 1 }
                let refs = (0..<Int.random(in: 1...40, using: &generator)).map { _ in randomRef() }
                let page = GmailListingPage(chain: .allMail(after: nil, before: nil), run: run,
                                            nextPageToken: Bool.random(using: &generator) ? "more" : nil, refs: refs,
                                            firstOrder: UInt32.random(in: 700...3_000, using: &generator))
                index.apply(page)
                try await double.appendListingPage(page)
            case 8:
                let label = labels.randomElement(using: &generator)!
                let page = GmailListingPage(chain: .label(label), refs: (0..<Int.random(in: 1...30, using: &generator)).map { _ in randomRef() },
                                            labels: [label])
                index.apply(page)
                try await double.appendListingPage(page)
            default:
                var attributes: GmailRecordAttributes = [.sizeKnown]
                attributes.sizeBand = SizeBand(rawValue: UInt8.random(in: 0...4, using: &generator)) ?? .tiny
                let page = GmailListingPage(chain: .search("larger:\(step)"), refs: (0..<5).map { _ in randomRef() }, attributes: attributes)
                index.apply(page)
                try await double.appendListingPage(page)
            }
            if step % 100 == 0 || step == 2_999 {
                GmailIndexTests.assertConsistent(index)
                try await GmailIndexTests.assertSame(index, double, step: step)
            }
        }
        let (loaded, _) = try GmailIndex.decodeSnapshot(index.encodedSnapshot(nextGeneration: 1))
        try await GmailIndexTests.assertSame(loaded, double, step: -1)
    }

    static func assertSame(_ index: GmailIndex, _ double: MemoryGmailStore, step: Int,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let theirs = await double.index()
        XCTAssertEqual(orderedIDs(index), theirs.byOrder.map { theirs.records[Int($0)].gmailID }, "order at step \(step)", file: file, line: line)
        for record in theirs.records {
            let id = record.gmailID
            guard let mine = index.record(for: id) else {
                // A tombstone the snapshot has already dropped.
                XCTAssertTrue(record.attributes.contains(.tombstone), "message \(id) at step \(step)", file: file, line: line)
                continue
            }
            XCTAssertEqual(mine.order, record.order, "order of \(id) at step \(step)", file: file, line: line)
            XCTAssertEqual(mine.threadID, record.threadID, file: file, line: line)
            XCTAssertEqual(mine.attributes, record.attributes, "attributes of \(id) at step \(step)", file: file, line: line)
            if !record.attributes.contains(.tombstone) {
                let their = await double.labels(of: id)
                XCTAssertEqual(index.labels(atSlot: index.slot(of: id)!), their, "labels of \(id) at step \(step)", file: file, line: line)
            }
        }
        let load = try await double.load()
        XCTAssertEqual(index.chains, load.chains, "listings at step \(step)", file: file, line: line)
        XCTAssertEqual(index.liveCount, load.messageCount, file: file, line: line)
        let theirWaiting = await double.awaitingLabels()
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: index.pending.values.map { ($0.ref.id, $0.labels) }), theirWaiting,
                       "messages waiting at step \(step)", file: file, line: line)
    }

    // MARK: - Fixtures

    /// Lists All Mail as Gmail gives it: newest first, 500 a page, message i at (N − i) × 16.
    static func listAllMail(_ total: Int, into index: GmailIndex, threadEvery: Int = 3) {
        var offset = 0
        while offset < total {
            let count = min(500, total - offset)
            var refs: [GmailRef] = []
            refs.reserveCapacity(count)
            for n in offset..<(offset + count) { refs.append(ref(n, thread: n - n % threadEvery)) }
            index.apply(GmailListingPage(chain: .allMail(after: nil, before: nil), pageToken: offset == 0 ? nil : "\(offset)",
                                         nextPageToken: offset + count < total ? "\(offset + count)" : nil, refs: refs,
                                         firstOrder: UInt32(total - offset) * 16))
            offset += count
        }
    }

    /// The process's physical footprint, as Activity Monitor counts memory.
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}

/// A repeatable source of randomness, so a failing run can be run again as it was.
struct GmailStoreRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension Array {
    func storeChunks(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
