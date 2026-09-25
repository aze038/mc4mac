import Foundation

/// Waiting for work that may not stop when asked, such as a save waiting on a server's answer,
/// for no longer than a limit. A task group cannot do this: it waits for every child, cancelled
/// or not, and a child awaiting another task's value goes on waiting however it is cancelled.
public enum Waiting {
    /// Waits until every task in `work` has finished or `seconds` have passed, whichever comes
    /// first, and says whether they all finished. The tasks go on either way.
    public static func upTo(_ seconds: TimeInterval, for work: [Task<Void, Never>]) async -> Bool {
        guard !work.isEmpty else { return true }
        let answer = FirstAnswer()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if answer.claim() { continuation.resume(returning: false) }
            }
            Task {
                for task in work { await task.value }
                timer.cancel()
                if answer.claim() { continuation.resume(returning: true) }
            }
        }
    }

    /// Lets only the first of several racers answer.
    private final class FirstAnswer: @unchecked Sendable {
        private let lock = NSLock()
        private var answered = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !answered else { return false }
            answered = true
            return true
        }
    }
}
