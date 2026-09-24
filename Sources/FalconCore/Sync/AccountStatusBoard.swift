import Foundation

/// What the status line says about each account, built from the engine's events. The sentence
/// given with an account's failure stays until that account can sync again, so an "up to date"
/// from another account, or a message about something else, never hides that one is paused,
/// blocked or offline.
public struct AccountStatusBoard: Sendable, Equatable {
    public private(set) var health: [UUID: AccountHealth] = [:]
    /// The sentence for each account that cannot sync now.
    public private(set) var problems: [UUID: String] = [:]

    public init() {}

    public mutating func apply(_ event: SyncEvent) {
        switch event {
        case .health(let id, let new):
            health[id] = new
            if new.isReachable {
                problems[id] = nil
            } else if case .blocked(let reason) = new {
                problems[id] = reason
            }
        case .error(let id, let message):
            // The engine gives the reason just after the account stops being reachable. An
            // error while it is reachable is about one pass or one rule, and passes.
            if let current = health[id], !current.isReachable { problems[id] = message }
        default:
            break
        }
    }

    /// False while any of these accounts cannot sync, when "All folders are up to date" would
    /// not be true.
    public func allReachable(_ ids: [UUID]) -> Bool {
        ids.allSatisfy { health[$0]?.isReachable ?? true }
    }
}
