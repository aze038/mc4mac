import Foundation

/// A lock that async code holds across suspension points, handed on in the order it was asked
/// for. An actor alone cannot keep a conversation with a server in one piece: every `await`
/// inside it lets another caller in.
final class AsyncMutex: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var waiters: [(id: UInt64, turn: CheckedContinuation<Void, Error>)] = []
    private var lastID: UInt64 = 0

    /// Waits for the lock. A caller cancelled while it waits leaves the queue and throws.
    func acquire() async throws {
        let id = lock.withLock { lastID += 1; return lastID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (turn: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    turn.resume(throwing: CancellationError())
                } else if !held {
                    held = true
                    lock.unlock()
                    turn.resume()
                } else {
                    waiters.append((id, turn))
                    lock.unlock()
                }
            }
        } onCancel: {
            let waiter: CheckedContinuation<Void, Error>? = lock.withLock {
                guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters.remove(at: index).turn
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    /// Takes the lock only if nobody holds it.
    func tryAcquire() -> Bool {
        lock.withLock {
            guard !held else { return false }
            held = true
            return true
        }
    }

    /// Hands the lock straight to the next in line, so nobody can slip in between.
    func release() {
        let next: CheckedContinuation<Void, Error>? = lock.withLock {
            guard !waiters.isEmpty else {
                held = false
                return nil
            }
            return waiters.removeFirst().turn
        }
        next?.resume()
    }
}
