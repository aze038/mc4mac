import Foundation

/// Settings → Accounts' and the sidebar's "Show All Gmail Labels", one Google account at a time:
/// labels Gmail hides from its own list are shown as folders too.
enum GmailLabelsShown {
    static func key(_ accountID: UUID) -> String { "gmailShowAllLabels.\(accountID.uuidString)" }

    static func all(for accountID: UUID) -> Bool { Preferences.bool(key(accountID), default: false) }

    static func set(_ shown: Bool, for accountID: UUID) {
        Preferences.set(shown, key(accountID))
        NotificationCenter.default.post(name: .falconGmailLabelsShownChanged, object: accountID)
    }
}

extension Notification.Name {
    /// "Show All Gmail Labels" changed for the account in `object`.
    static let falconGmailLabelsShownChanged = Notification.Name("falconGmailLabelsShownChanged")
}
