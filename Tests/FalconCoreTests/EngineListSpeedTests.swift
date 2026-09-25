import XCTest
@testable import FalconCore

/// The work the mailbox window does on the main thread each time the selection or the list
/// changes, at 200,000 messages: a conversation's messages found from its own slots, a row found
/// by its key in one pass without building a key for every row, and the selected rows counted
/// without counting the list.
final class EngineListSpeedTests: XCTestCase {
    #if DEBUG
    static let slack = 3.0
    #else
    static let slack = 1.0
    #endif

    private func milliseconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func thread(_ n: Int) -> UInt64 { ListFixtures.baseID + UInt64(n) * 16 + 1 }

    /// `count` messages in conversations of one to a dozen, spread through the mailbox, in the
    /// Inbox, Sent, Junk Email and Deleted Items as a real one is.
    private static func mailbox(_ count: Int, threads: Int) -> [ListFixtures.Message] {
        (0..<count).map { i in
            // A fixed scatter, so a conversation's messages lie far apart in the order.
            let thread = (i &* 7_919) % threads
            var labels: Set<GmailLabelID> = []
            switch i % 11 {
            case 0, 1, 2, 3: labels.insert(.inbox)
            case 4, 5: labels.insert(.sent)
            case 6: labels.insert(.trash)
            case 7: labels.insert(.spam)
            case 8: labels = [.inbox, .trash]
            default: break
            }
            if i % 5 == 0 { labels.insert(.unread) }
            return ListFixtures.Message(labels: labels, thread: thread)
        }
    }

    // MARK: - A conversation's messages

    func testAConversationsMessagesFromItsOwnSlotsAreThoseTheWholeIndexGives() {
        let threads = 1_000
        let index = ListFixtures.index(EngineListSpeedTests.mailbox(5_000, threads: threads))
        let labels: [GmailLabelID?] = [.inbox, .sent, .trash, .spam, nil, GmailLabelID("Label_9")]
        var nonEmpty = 0
        for n in stride(from: 0, to: threads, by: 5) {
            for label in labels {
                let thread = EngineListSpeedTests.thread(n)
                let fast = index.conversationMembers(thread: thread, label: label)
                XCTAssertEqual(fast, index.conversationMembersByScan(thread: thread, label: label), "thread \(n), \(String(describing: label))")
                if !fast.isEmpty { nonEmpty += 1 }
                XCTAssertEqual(index.conversationMembers(thread: thread, label: label, limit: 2),
                               index.conversationMembersByScan(thread: thread, label: label, limit: 2))
            }
        }
        XCTAssertGreaterThan(nonEmpty, 300, "the comparison saw conversations with messages")
        XCTAssertEqual(index.conversationMembers(thread: EngineListSpeedTests.thread(threads + 5), label: nil), [],
                       "a conversation the index does not hold has none")
    }

    func testAThousandConversationsOfA200000MessageMailboxAreReadInUnderFiftyMilliseconds() {
        let threads = 70_000
        let index = ListFixtures.index(EngineListSpeedTests.mailbox(200_000, threads: threads))
        // The grouping is built once, the first time, off the main thread in the engine.
        let built = milliseconds { _ = index.conversationMembers(thread: EngineListSpeedTests.thread(0), label: .inbox) }
        XCTAssertTrue(index.threadOrder.isBuilt)
        print("EngineListSpeedTests: conversations of 200,000 grouped in \(String(format: "%.1f", built)) ms")
        var best = Double.infinity
        var found = 0
        for _ in 0..<5 where best >= 50 * Self.slack {
            found = 0
            best = min(best, milliseconds {
                for k in 0..<1_000 {
                    found += index.conversationMembers(thread: EngineListSpeedTests.thread((k &* 131) % threads), label: .inbox).count
                }
            })
        }
        XCTAssertGreaterThan(found, 0)
        XCTAssertLessThan(best, 50 * Self.slack, "1,000 conversations took \(best) ms")
    }

    /// A message placed or deleted gives the index's next snapshot a fresh grouping; an earlier
    /// snapshot keeps its own.
    func testTheGroupingFollowsTheIndexAsMessagesArriveAndGo() {
        let index = GmailIndex()
        let thread = 77
        index.apply(.place(GmailIndexTests.ref(1, thread: thread), order: 100, labels: [.inbox], attributes: []))
        index.apply(.place(GmailIndexTests.ref(2, thread: thread), order: 200, labels: [.inbox], attributes: []))
        let raw = GmailIndexTests.ref(1, thread: thread).threadID.raw
        let before = index.snapshot()
        XCTAssertEqual(before.conversationMembers(thread: raw, label: .inbox), [GmailIndexTests.ref(2).id, GmailIndexTests.ref(1).id])

        index.apply(.place(GmailIndexTests.ref(3, thread: thread), order: 300, labels: [.inbox], attributes: []))
        let after = index.snapshot()
        XCTAssertEqual(after.conversationMembers(thread: raw, label: .inbox),
                       [GmailIndexTests.ref(3).id, GmailIndexTests.ref(2).id, GmailIndexTests.ref(1).id])
        XCTAssertEqual(before.conversationMembers(thread: raw, label: .inbox), [GmailIndexTests.ref(2).id, GmailIndexTests.ref(1).id],
                       "a snapshot taken before keeps what it held")

        index.apply(.tombstone(GmailIndexTests.ref(2).id))
        XCTAssertEqual(index.snapshot().conversationMembers(thread: raw, label: .inbox),
                       [GmailIndexTests.ref(3).id, GmailIndexTests.ref(1).id])

        // A relabel moves nothing in the order: the grouping is kept, and the labels read afresh.
        let kept = index.snapshot()
        _ = kept.conversationMembers(thread: raw, label: .inbox)
        index.apply(.relabel(GmailIndexTests.ref(3).id, adding: [], removing: [.inbox]))
        let relabelled = index.snapshot()
        XCTAssertTrue(relabelled.threadOrder === kept.threadOrder)
        XCTAssertEqual(relabelled.conversationMembers(thread: raw, label: .inbox), [GmailIndexTests.ref(1).id])
        XCTAssertEqual(relabelled.conversationMembers(thread: raw, label: .inbox),
                       relabelled.conversationMembersByScan(thread: raw, label: .inbox))
    }

    // MARK: - Rows by their keys, and counts

    private let account = UUID()
    private let other = UUID()

    /// Headers, conversations opened with their lines, and two accounts' rows as All Inboxes has.
    private func snapshot(_ count: Int) -> ListSnapshot {
        var rows = ContiguousArray<DisplayRecord>()
        var headers: [Int: String] = [:]
        for i in 0..<count {
            if i % 50 == 0 {
                rows.append(.header(group: UInt16(i / 50)))
                headers[i / 50] = "Group \(i / 50)"
            }
            let source: UInt8 = i % 7 == 0 ? 1 : 0
            if i % 10 == 3 {
                rows.append(DisplayRecord(key: 0x1000 + UInt64(i), slot: Int32(i), bits: .expanded, members: 2, kind: .conversation, source: source))
                rows.append(DisplayRecord(key: 0x1000 + UInt64(i), slot: Int32(i), kind: .child, source: source))
                rows.append(DisplayRecord(key: 0x9000_0000 + UInt64(i), slot: Int32(i), kind: .child, source: source))
            } else {
                rows.append(DisplayRecord(key: 0x1000 + UInt64(i), slot: Int32(i), source: source))
            }
        }
        return ListSnapshot(view: ListView(scope: .allInboxes), rows: rows, headers: headers, complete: true,
                            itemCount: count, sources: [account, other])
    }

    private func linear(_ snapshot: ListSnapshot, _ key: RowKey, line: Bool?) -> Int? {
        guard let line else { return snapshot.rows.indices.first { snapshot.rowKey(at: $0) == key } }
        return snapshot.rows.indices.first { snapshot.rowKey(at: $0) == key && (snapshot.rows[$0].displayKind == .child) == line }
            ?? snapshot.rows.indices.first { snapshot.rowKey(at: $0) == key }
    }

    func testARowFoundByItsKeyIsTheOneAPassFromTheTopFinds() {
        let snapshot = snapshot(2_000)
        var keys: [RowKey] = []
        for i in stride(from: 0, to: 2_000, by: 1) {
            keys.append(.gmail(account: account, id: GmailMessageID(raw: 0x1000 + UInt64(i))))
            keys.append(.gmail(account: other, id: GmailMessageID(raw: 0x1000 + UInt64(i))))
            if i % 10 == 3 { keys.append(.gmail(account: i % 7 == 0 ? other : account, id: GmailMessageID(raw: 0x9000_0000 + UInt64(i)))) }
        }
        keys.append(.gmail(account: UUID(), id: GmailMessageID(raw: 0x1005)))
        keys.append(.stored("nowhere"))
        for key in keys {
            for line: Bool? in [nil, true, false] {
                XCTAssertEqual(snapshot.row(of: key, line: line), linear(snapshot, key, line: line), "\(key) line \(String(describing: line))")
            }
        }
        let some = Array(keys.prefix(300))
        let together = snapshot.rowIndexes(of: some, line: false)
        for key in some { XCTAssertEqual(together[key], linear(snapshot, key, line: false)) }
    }

    func testAStoredRowIsFoundByItsId() {
        let rows = ContiguousArray((0..<5).map { DisplayRecord(key: UInt64($0), slot: Int32(4 - $0), bits: .storedRow) })
        let snapshot = ListSnapshot(view: ListView(scope: .allInboxes), rows: rows, complete: true, itemCount: 5, sources: [account],
                                    storedKeys: ["a", "b", "c", "d", "e"])
        XCTAssertEqual(snapshot.row(of: .stored("e")), 0)
        XCTAssertEqual(snapshot.row(of: .stored("a")), 4)
        XCTAssertNil(snapshot.row(of: .stored("f")))
    }

    func testMessageRowsAndSelectAllAreCountedAsTheRowsSay() {
        let snapshot = snapshot(5_000)
        let brute = snapshot.rows.filter { $0.displayKind != .header }.count
        XCTAssertEqual(snapshot.messageRowCount, brute)
        XCTAssertEqual(snapshot.headerCount, 100)
        let except = IndexSet([0, 1, 2, 51, 52, 700, 99_999])
        let bruteExcept = snapshot.rows.indices.filter { !except.contains($0) && snapshot.rows[$0].displayKind != .header }.count
        XCTAssertEqual(ListSelection.all(except: except).count(in: snapshot), bruteExcept)
        XCTAssertEqual(ListSelection.all().count(in: snapshot), brute)
    }

    func testAViewBuiltWithHeadersKnowsHowManyItHas() async {
        let index = ListFixtures.index(ListFixtures.large(20_000))
        let account = ListFixtures.account(index)
        let list = ListIndex(clock: { Date() })
        await list.setAccount(account)
        let build = await list.build(ListView(scope: .folder(account.archiveFolderID!), conversations: true, dateGroups: true))
        let snapshot = build.snapshot
        XCTAssertEqual(snapshot.headerCount, snapshot.rows.filter { $0.displayKind == .header }.count)
        XCTAssertEqual(snapshot.messageRowCount, snapshot.rows.count - snapshot.headerCount)
    }

    func testARowOf200000IsFoundAndTheSelectionCountedInUnderAMillisecondEach() {
        let snapshot = snapshot(200_000)
        let last = RowKey.gmail(account: account, id: GmailMessageID(raw: 0x1000 + 199_999))
        var best = Double.infinity
        for _ in 0..<5 {
            best = min(best, milliseconds { XCTAssertNotNil(snapshot.row(of: last)) })
        }
        print("EngineListSpeedTests: the last of 200,000 rows found in \(String(format: "%.2f", best)) ms")
        XCTAssertLessThan(best, 20 * Self.slack)
        let counted = milliseconds {
            for _ in 0..<100 { _ = snapshot.messageRowCount; _ = ListSelection.all().count(in: snapshot) }
        }
        XCTAssertLessThan(counted, 1 * Self.slack, "a hundred counts took \(counted) ms")
    }
}
