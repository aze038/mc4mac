import AppKit
import UserNotifications
import FalconCore

enum MailNotificationAction {
    case reveal
    case archive
    case delete
    case markRead
    case flag
}

enum MailNotificationCategory {
    static let newMail = "falcon.newMail"

    private static let archive = "falcon.archive"
    private static let delete = "falcon.delete"
    private static let markRead = "falcon.markRead"
    private static let flag = "falcon.flag"

    static func register(with center: UNUserNotificationCenter) {
        let actions = [
            UNNotificationAction(identifier: archive, title: "Archive", options: []),
            UNNotificationAction(identifier: markRead, title: "Mark as Read", options: []),
            UNNotificationAction(identifier: flag, title: "Flag", options: []),
            UNNotificationAction(identifier: delete, title: "Delete", options: [.destructive])
        ]
        let category = UNNotificationCategory(identifier: newMail, actions: actions, intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }

    static func action(for identifier: String) -> MailNotificationAction? {
        switch identifier {
        case UNNotificationDefaultActionIdentifier: return .reveal
        case archive: return .archive
        case delete: return .delete
        case markRead: return .markRead
        case flag: return .flag
        default: return nil
        }
    }
}

/// What Notifications and Sounds keeps besides the sounds.
enum AlertPrefs {
    /// "Display an alert on my desktop".
    static let desktopAlert = "notificationsEnabled"
    /// Show message subject and preview, Outlook's default, rather than the subject only.
    static let showsPreview = "notificationShowsPreview"
    static let bounceDock = "bounceDockIcon"
}

/// The alerts that ask "Don't show this again", and what their answers are kept under, so Reset
/// Alerts can ask again.
enum AlertSuppressions {
    static let keys = ["declinedMoveToApplications", "updates.skippedVersion"]

    static func reset() {
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }
}

@MainActor
final class NotificationService {
    private var authorized = false

    func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        MailNotificationCategory.register(with: center)
        authorized = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Announces the new messages the account's notify setting lets through: a banner for each
    /// when desktop alerts are on, and a bounce of the Dock icon when that is asked for and
    /// FalconMail is not in front. Returns whether any was let through, which the new message
    /// sound follows whether or not banners are shown, as Outlook's does.
    func announce(_ newMessages: [MessageSummary], account: AccountInfo, folder: FolderInfo, policy: NotificationPolicy) -> Bool {
        guard !newMessages.isEmpty, folder.role == .inbox else { return false }
        let mode = policy.mode(for: account.id)
        guard mode != .off else { return false }
        let wanted = newMessages.filter { policy.allows($0, mode: mode, accountEmail: account.email) }
        guard !wanted.isEmpty else { return false }
        if Preferences.bool(AlertPrefs.bounceDock, default: false), !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
        if Preferences.bool(AlertPrefs.desktopAlert, default: true), authorized { post(wanted, account: account) }
        return true
    }

    private func post(_ wanted: [MessageSummary], account: AccountInfo) {
        let center = UNUserNotificationCenter.current()
        let preview = Preferences.bool(AlertPrefs.showsPreview, default: true)
        for m in wanted.prefix(5) {
            let content = UNMutableNotificationContent()
            content.title = m.from.displayName
            content.subtitle = account.email
            content.body = NotificationService.body(subject: m.subject, snippet: m.snippet, preview: preview)
            content.userInfo = ["messageID": m.id]
            content.categoryIdentifier = MailNotificationCategory.newMail
            if !m.threadKey.isEmpty { content.threadIdentifier = m.threadKey }
            center.add(UNNotificationRequest(identifier: m.id, content: content, trigger: nil))
        }
        if wanted.count > 5 {
            let content = UNMutableNotificationContent()
            content.title = "\(wanted.count) new messages"
            content.subtitle = account.email
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// The subject, with the first words of the message under it when the preview is wanted.
    static func body(subject: String, snippet: String, preview: Bool) -> String {
        let subject = subject.trimmed.isEmpty ? "(no subject)" : subject
        let snippet = snippet.trimmed
        return preview && !snippet.isEmpty ? "\(subject)\n\(snippet)" : subject
    }
}
