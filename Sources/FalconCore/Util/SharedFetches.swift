import Foundation

/// Fetches that several readers may ask for at once, such as a message's text wanted by the
/// reading pane and by its own window, each waited for no longer than a limit.
///
/// A second reader asking for what is already on its way waits for the same fetch instead of
/// queueing a second one behind it on the account's connection. A reader stops waiting at once
/// when it is cancelled, as a reading pane that moves on is, or when its limit passes, whatever
/// the fetch is doing. A fetch nobody waits for any more because every reader was cancelled is
/// cancelled too, so moving through the list leaves no queue of fetches for messages no longer
/// shown. One whose readers only ran out of time goes on, so that asking again joins it; but a
/// fetch still unfinished `replacedAfter` seconds after it began is left to itself, and the
/// next reader starts a fresh one rather than waiting behind it.
public final class SharedFetches<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    public enum Outcome: Sendable {
        case finished(Value)
        /// The limit passed first. The fetch goes on, and asking again joins it.
        case timedOut
        /// The reader was cancelled.
        case cancelled

        public var value: Value? {
            if case .finished(let value) = self { return value }
            return nil
        }
    }

    private final class Entry: @unchecked Sendable {
        let id = UUID()
        let started: Date
        var task: Task<Value, Never>?
        var waiters = 0
        init(started: Date) { self.started = started }
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private let replacedAfter: TimeInterval
    private let now: @Sendable () -> Date

    public init(replacedAfter: TimeInterval = 45, now: @escaping @Sendable () -> Date = { Date() }) {
        self.replacedAfter = replacedAfter
        self.now = now
    }

    /// How many fetches are on their way.
    public var inFlight: Int { lock.withLock { entries.count } }

    /// `key`'s value from the fetch already on its way for it, or from `fetch`, started now.
    /// Waits `seconds` at most.
    public func value(for key: Key, within seconds: TimeInterval,
                      _ fetch: @escaping @Sendable () async -> Value) async -> Outcome {
        let (entry, task) = join(key, fetch)
        let answer = FirstOfAnswers<Outcome>()
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            if !Task.isCancelled { answer.give(.timedOut) }
        }
        let watcher = Task {
            let value = await task.value
            answer.give(.finished(value))
        }
        let outcome: Outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                answer.install(continuation)
            }
        } onCancel: {
            answer.give(.cancelled)
        }
        timer.cancel()
        watcher.cancel()
        var cancelled = false
        if case .cancelled = outcome { cancelled = true }
        leave(key, entry, cancelled: cancelled)
        return outcome
    }

    private func join(_ key: Key, _ fetch: @escaping @Sendable () async -> Value) -> (Entry, Task<Value, Never>) {
        var replaced: Task<Value, Never>?
        let joined: (Entry, Task<Value, Never>) = lock.withLock {
            if let running = entries[key], let task = running.task {
                if now().timeIntervalSince(running.started) < replacedAfter {
                    running.waiters += 1
                    return (running, task)
                }
                // Stuck: nobody is to wait behind it any more, and with no reader left it goes.
                entries[key] = nil
                if running.waiters <= 0 { replaced = task }
            }
            let entry = Entry(started: now())
            entry.waiters = 1
            let id = entry.id
            let task = Task { [weak self] () -> Value in
                let value = await fetch()
                self?.finished(key, id)
                return value
            }
            entry.task = task
            entries[key] = entry
            return (entry, task)
        }
        replaced?.cancel()
        return joined
    }

    private func finished(_ key: Key, _ id: UUID) {
        lock.withLock { if entries[key]?.id == id { entries[key] = nil } }
    }

    private func leave(_ key: Key, _ entry: Entry, cancelled: Bool) {
        let abandoned: Task<Value, Never>? = lock.withLock {
            entry.waiters -= 1
            guard cancelled, entry.waiters <= 0 else { return nil }
            if entries[key] === entry { entries[key] = nil }
            return entry.task
        }
        abandoned?.cancel()
    }
}

/// The first of several answers to a continuation, whichever comes first, even one that
/// comes before the continuation is there to take it.
final class FirstOfAnswers<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var early: T?
    private var done = false

    func install(_ continuation: CheckedContinuation<T, Never>) {
        lock.lock()
        if let early, !done {
            done = true
            lock.unlock()
            continuation.resume(returning: early)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func give(_ value: T) {
        lock.lock()
        guard !done else { return lock.unlock() }
        guard let continuation else {
            if early == nil { early = value }
            return lock.unlock()
        }
        done = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
    }
}
