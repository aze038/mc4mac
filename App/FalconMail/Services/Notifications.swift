import Foundation
import UserNotifications
import FalconCore

@MainActor
final class NotificationService {
    private var authorized = false

    func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        authorized = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func notify(newMessages: [MessageSummary], accountEmail: String) {
        guard authorized, !newMessages.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        for m in newMessages.prefix(5) {
            let content = UNMutableNotificationContent()
            content.title = m.from.displayName
            content.subtitle = accountEmail
            content.body = m.subject.isEmpty ? m.snippet : m.subject
            content.sound = .default
            content.userInfo = ["messageID": m.id]
            center.add(UNNotificationRequest(identifier: m.id, content: content, trigger: nil))
        }
        if newMessages.count > 5 {
            let content = UNMutableNotificationContent()
            content.title = "\(newMessages.count) new messages"
            content.subtitle = accountEmail
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
