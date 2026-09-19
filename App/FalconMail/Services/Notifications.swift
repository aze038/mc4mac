import SwiftUI
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

@MainActor
final class NotificationService {
    private var authorized = false
    @AppStorage("notificationSound") var soundName = "Ping"
    @AppStorage("notificationsEnabled") var enabled = true

    func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        MailNotificationCategory.register(with: center)
        authorized = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func notify(newMessages: [MessageSummary], account: AccountInfo, folder: FolderInfo, policy: NotificationPolicy) {
        guard enabled, authorized, !newMessages.isEmpty, folder.role == .inbox else { return }
        let mode = policy.mode(for: account.id)
        guard mode != .off else { return }
        let wanted = newMessages.filter { policy.allows($0, mode: mode, accountEmail: account.email) }
        guard !wanted.isEmpty else { return }
        SystemSounds.play(soundName)
        let center = UNUserNotificationCenter.current()
        for m in wanted.prefix(5) {
            let content = UNMutableNotificationContent()
            content.title = m.from.displayName
            content.subtitle = account.email
            content.body = m.subject.isEmpty ? m.snippet : m.subject
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
}
