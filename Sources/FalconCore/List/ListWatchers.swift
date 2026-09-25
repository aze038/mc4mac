import Foundation

/// Who is watching which views of a list source, for its changes and its footers. A watcher is
/// registered the moment it asks, before any change the source makes next, so no change can fall
/// between asking and listening.
public final class ListWatchers: @unchecked Sendable {
    private let lock = NSLock()
    private var diffs: [ListView: [UUID: AsyncStream<ListDiff>.Continuation]] = [:]
    private var footers: [ListView: [UUID: AsyncStream<[ListFooter]>.Continuation]] = [:]
    /// Called, outside the lock, when a view's last watcher has gone.
    private let onEmpty: @Sendable (ListView) -> Void

    public init(onEmpty: @escaping @Sendable (ListView) -> Void = { _ in }) {
        self.onEmpty = onEmpty
    }

    public func diffStream(for view: ListView) -> AsyncStream<ListDiff> {
        let (stream, continuation) = AsyncStream.makeStream(of: ListDiff.self)
        let id = UUID()
        lock.withLock { diffs[view, default: [:]][id] = continuation }
        continuation.onTermination = { [weak self] _ in self?.remove(id, from: view) }
        return stream
    }

    public func footerStream(for view: ListView) -> AsyncStream<[ListFooter]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [ListFooter].self)
        let id = UUID()
        lock.withLock { footers[view, default: [:]][id] = continuation }
        continuation.onTermination = { [weak self] _ in self?.remove(id, from: view) }
        return stream
    }

    /// Views someone watches for changes.
    public var diffViews: [ListView] { lock.withLock { diffs.filter { !$0.value.isEmpty }.map(\.key) } }
    /// Views someone watches for changes or footers.
    public var views: [ListView] {
        lock.withLock { Array(Set(diffs.filter { !$0.value.isEmpty }.keys).union(footers.filter { !$0.value.isEmpty }.keys)) }
    }

    public func isWatched(_ view: ListView) -> Bool {
        lock.withLock { !(diffs[view]?.isEmpty ?? true) || !(footers[view]?.isEmpty ?? true) }
    }

    public func send(_ diff: ListDiff, for view: ListView) {
        let out = lock.withLock { Array(diffs[view]?.values ?? [:].values) }
        for continuation in out { continuation.yield(diff) }
    }

    public func send(_ lines: [ListFooter], for view: ListView) {
        let out = lock.withLock { Array(footers[view]?.values ?? [:].values) }
        for continuation in out { continuation.yield(lines) }
    }

    private func remove(_ id: UUID, from view: ListView) {
        let empty: Bool = lock.withLock {
            diffs[view]?[id] = nil
            footers[view]?[id] = nil
            let none = (diffs[view]?.isEmpty ?? true) && (footers[view]?.isEmpty ?? true)
            if none {
                diffs[view] = nil
                footers[view] = nil
            }
            return none
        }
        if empty { onEmpty(view) }
    }
}
