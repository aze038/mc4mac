import SwiftUI
import FalconCore

enum NotifyMode: String, Codable, CaseIterable, Identifiable {
    case off, all, direct, vip

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .off: return "Never"
        case .all: return "All new mail"
        case .direct: return "Only when I am in the To line"
        case .vip: return "Only from VIPs"
        }
    }
}

struct NotificationPolicy: Codable {
    var modes: [String: NotifyMode] = [:]
    var vip: [String] = []

    func mode(for accountID: UUID) -> NotifyMode {
        modes[accountID.uuidString] ?? .all
    }

    mutating func setMode(_ mode: NotifyMode, for accountID: UUID) {
        modes[accountID.uuidString] = mode
    }

    mutating func addVIP(_ entry: String) {
        let cleaned = NotificationPolicy.normalizedVIPEntry(entry)
        guard cleaned.contains("@"), !vip.contains(cleaned) else { return }
        vip.append(cleaned)
        vip.sort()
    }

    mutating func removeVIP(_ entry: String) {
        vip.removeAll { $0 == entry }
    }

    func allows(_ message: MessageSummary, mode: NotifyMode, accountEmail: String) -> Bool {
        switch mode {
        case .off:
            return false
        case .all:
            return true
        case .direct:
            let mine = NotificationPolicy.canonical(accountEmail)
            return message.to.contains { NotificationPolicy.canonical($0.address) == mine }
        case .vip:
            return isVIP(message.from.address)
        }
    }

    func isVIP(_ address: String) -> Bool {
        let sender = address.lowercased().trimmed
        guard !sender.isEmpty else { return false }
        return vip.contains { entry in
            entry.hasPrefix("@") ? sender.hasSuffix(entry) : sender == entry
        }
    }

    static func normalizedVIPEntry(_ entry: String) -> String {
        let text = entry.lowercased().trimmed
        if text.hasPrefix("@") { return text }
        return AddressParser.parse(text).first?.address.lowercased().trimmed ?? text
    }

    static func canonical(_ address: String) -> String {
        let lower = address.lowercased().trimmed
        guard let at = lower.lastIndex(of: "@") else { return lower }
        let local = lower[lower.startIndex..<at]
        guard let plus = local.firstIndex(of: "+") else { return lower }
        return String(local[local.startIndex..<plus]) + String(lower[at...])
    }
}

extension NotificationPolicy {
    static func load(layout: FileLayout) -> NotificationPolicy {
        AtomicFile.readJSON(NotificationPolicy.self, from: layout.notificationPolicyFile) ?? NotificationPolicy()
    }

    func save(layout: FileLayout) {
        try? AtomicFile.writeJSON(self, to: layout.notificationPolicyFile)
    }
}
