import Foundation

/// The real waits, given explicitly wherever FalconCore takes a wait as a closure.
///
/// An async closure must never be a default argument in FalconCore: a debug build of Swift 6.2
/// miscompiles one, and calling it brings the app down ("freed pointer was not the last
/// allocation"). Callers pass these instead; `NoAsyncClosureDefaultsTests` keeps the pattern out.
public enum GmailWait {
    /// Waits `seconds` (none if negative); throws if the task is cancelled.
    public static let sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    /// Waits `seconds` (none if negative); a cancelled wait simply ends early.
    public static let sleepQuietly: @Sendable (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
