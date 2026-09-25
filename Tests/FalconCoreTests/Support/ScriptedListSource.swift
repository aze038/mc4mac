import Foundation
@testable import FalconCore

/// A list source the test drives by hand: it answers with the snapshot it is given, sends the
/// diffs, rows and footers the test sends, and records every request.
final class ScriptedListSource: ListSourceExtras, @unchecked Sendable {
    private let lock = NSLock()
    private var current: ListSnapshot
    private var diffOut: [AsyncStream<ListDiff>.Continuation] = []
    private var footerOut: [AsyncStream<[ListFooter]>.Continuation] = []
    private let rowsOut = RowBroadcast<[RowKey: MessageRowContent]>()
    private var _requests: [(keys: [RowKey], priority: RowPriority)] = []
    private var _expanded: [Set<RowKey>] = []

    init(_ snapshot: ListSnapshot) {
        current = snapshot
    }

    var requests: [(keys: [RowKey], priority: RowPriority)] { lock.withLock { _requests } }
    var expandedRequests: [Set<RowKey>] { lock.withLock { _expanded } }

    func snapshot(of view: ListView) async -> ListSnapshot { lock.withLock { current } }

    func changes(of view: ListView) -> AsyncStream<ListDiff> {
        let (stream, continuation) = AsyncStream.makeStream(of: ListDiff.self)
        lock.withLock { diffOut.append(continuation) }
        return stream
    }

    func footers(of view: ListView) -> AsyncStream<[ListFooter]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [ListFooter].self)
        lock.withLock { footerOut.append(continuation) }
        return stream
    }

    func requestRows(_ keys: [RowKey], priority: RowPriority) {
        lock.withLock { _requests.append((keys, priority)) }
    }

    var rows: AsyncStream<[RowKey: MessageRowContent]> { rowsOut.subscribe() }

    func summary(for key: RowKey, in view: ListView) async -> RowAvailability { .gone }

    func setExpanded(_ keys: Set<RowKey>, in view: ListView) async {
        lock.withLock { _expanded.append(keys) }
    }

    // MARK: Driving it

    func send(_ diff: ListDiff) {
        let out = lock.withLock { () -> [AsyncStream<ListDiff>.Continuation] in
            current = diff.snapshot
            return diffOut
        }
        for c in out { c.yield(diff) }
    }

    func send(rows: [RowKey: MessageRowContent]) { rowsOut.send(rows) }

    func send(footers: [ListFooter]) {
        for c in lock.withLock({ footerOut }) { c.yield(footers) }
    }

    func clearRequests() { lock.withLock { _requests = [] } }
}

enum ListSnapshots {
    static func rows(_ keys: [UInt64], account: UUID, kinds: [UInt64: DisplayKind] = [:], view: ListView = ListView(scope: .allInboxes),
                     itemCount: Int? = nil) -> ListSnapshot {
        ListSnapshot(view: view, rows: ContiguousArray(keys.map { key in
            DisplayRecord(key: key, slot: Int32(key), members: kinds[key] == .conversation ? 2 : 1, kind: kinds[key] ?? .message)
        }), complete: true, itemCount: itemCount ?? keys.count, sources: [account])
    }

    static func content(_ key: RowKey, from name: String = "Ana", subject: String = "Hello",
                        members: [ConversationMember]? = nil) -> MessageRowContent {
        MessageRowContent(key: key, from: EmailAddress(name: name, address: "ana@example.com"), to: [], subject: subject,
                          preview: "Opening words", date: Date(),
                          conversation: members.map { ConversationContent(senders: $0.map(\.from), messageCount: $0.count,
                                                                          newestDate: Date(), members: $0) })
    }
}
