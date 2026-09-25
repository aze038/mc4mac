import Foundation

/// Sends each batch of rows' text to everyone listening. A source's rows are read by the table's
/// controller and, for All Inboxes, by the source that merges the accounts; an `AsyncStream` has
/// one reader, so each gets a stream of its own.
public final class RowBroadcast<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var listeners: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var finished = false

    public init() {}

    /// A new stream that gets everything sent from now on.
    public func subscribe() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self)
        let id = UUID()
        let alive: Bool = lock.withLock {
            guard !finished else { return false }
            listeners[id] = continuation
            return true
        }
        guard alive else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { _ = self.listeners.removeValue(forKey: id) }
        }
        return stream
    }

    public func send(_ element: Element) {
        let current = lock.withLock { Array(listeners.values) }
        for continuation in current { continuation.yield(element) }
    }

    public func finish() {
        let current: [AsyncStream<Element>.Continuation] = lock.withLock {
            finished = true
            defer { listeners = [:] }
            return Array(listeners.values)
        }
        for continuation in current { continuation.finish() }
    }

    public var listenerCount: Int { lock.withLock { listeners.count } }
}
