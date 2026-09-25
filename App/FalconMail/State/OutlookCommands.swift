import SwiftUI
import AppKit
import FalconCore

struct MailCategory: Codable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    var colour: String

    var swatch: Color {
        switch colour {
        case "red": return Color(red: 0.86, green: 0.31, blue: 0.27)
        case "orange": return Color(red: 0.89, green: 0.49, blue: 0.18)
        case "yellow": return Color(red: 0.96, green: 0.87, blue: 0.42)
        case "green": return Color(red: 0.45, green: 0.63, blue: 0.28)
        case "teal": return Color(red: 0.45, green: 0.83, blue: 0.75)
        case "blue": return Color(red: 0.42, green: 0.54, blue: 0.9)
        case "purple": return Color(red: 0.6, green: 0.45, blue: 0.85)
        case "grey": return Color(white: 0.78)
        default: return Color.secondary
        }
    }

    static let palette = ["grey", "orange", "yellow", "blue", "teal", "green", "red", "purple"]

    static let defaults: [MailCategory] = [
        MailCategory(name: "Family", colour: "grey"),
        MailCategory(name: "Friends", colour: "orange"),
        MailCategory(name: "Holiday", colour: "yellow"),
        MailCategory(name: "Manager", colour: "blue"),
        MailCategory(name: "Networking", colour: "teal"),
        MailCategory(name: "Personal", colour: "green"),
        MailCategory(name: "Team", colour: "red"),
        MailCategory(name: "Travel", colour: "purple")
    ]
}

enum CategoryStore {
    private static let listKey = "mailCategories"
    private static let assignmentKey = "mailCategoryAssignments"

    static func load() -> [MailCategory] {
        guard let data = UserDefaults.standard.data(forKey: listKey),
              let list = try? JSONDecoder().decode([MailCategory].self, from: data), !list.isEmpty
        else { return MailCategory.defaults }
        return list
    }

    static func save(_ list: [MailCategory]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: listKey)
    }

    static func assignments() -> [String: [String]] {
        guard let data = UserDefaults.standard.data(forKey: assignmentKey),
              let map = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return map
    }

    static func saveAssignments(_ map: [String: [String]]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(data, forKey: assignmentKey)
    }
}

@MainActor
extension AppModel {
    var windowTitle: String {
        let place = listTitle.uppercased()
        guard let email = currentAccountEmail else { return place }
        return "\(place) • \(email)"
    }

    var currentAccountEmail: String? {
        if case .folder(let id) = selection, let folder = folder(id) {
            return accounts.first { $0.id == folder.accountID }?.email
        }
        return accounts.count == 1 ? accounts.first?.email : nil
    }

    var itemCount: Int { messages.count }

    func cycleAppearance() {
        let order: [AppAppearance] = [.light, .dark, .system]
        let current = AppAppearance(rawValue: appearance) ?? .system
        let next = order[((order.firstIndex(of: current) ?? 2) + 1) % order.count]
        appearance = next.rawValue
        AppAppearance.apply(next.rawValue)
    }

    var canEmptyCurrentFolder: Bool {
        guard case .folder(let id) = selection, let folder = folder(id) else { return false }
        return (folder.role == .trash || folder.role == .junk) && !messages.isEmpty
    }

    func emptyCurrentFolder() {
        guard case .folder(let id) = selection, let folder = folder(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete everything in \(folder.name)?"
        alert.informativeText = "\(messages.count) messages are removed from the server and cannot be brought back."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        purgeEverything(in: folder)
    }

    func createFolderPrompt(for account: AccountInfo) {
        promptForNewFolder(in: account)
    }

    func promptForNewFolder(in preferred: AccountInfo? = nil) {
        guard let account = preferred ?? accounts.first(where: { $0.id == newFolderAccountID }) ?? accounts.first else { return }
        let alert = NSAlert()
        alert.messageText = "New folder"
        alert.informativeText = "The folder is created on the server for \(account.email), so it appears on every device."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.placeholderString = "Folder name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        createFolder(named: name, in: account)
    }

    private var newFolderAccountID: UUID? {
        if case .folder(let id) = selection, let folder = folder(id) { return folder.accountID }
        return nil
    }

    /// Handles a mailto: link from another app, prefilling the recipients, subject and body.
    func composeFromMailto(_ url: URL) {
        guard let account = accounts.first else {
            Task {
                for _ in 0..<40 where accounts.isEmpty {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                if !accounts.isEmpty { composeFromMailto(url) }
            }
            return
        }
        let signature = signature(for: account, .newMessages)
        var draft = ComposeDraft.blank(account: account, signature: signature)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let head = (components?.path.isEmpty == false ? components!.path : (url.absoluteString.dropFirst("mailto:".count).split(separator: "?").first.map(String.init) ?? ""))
        draft.to = head.removingPercentEncoding ?? head
        for item in components?.queryItems ?? [] {
            let value = item.value ?? ""
            switch item.name.lowercased() {
            case "cc": draft.cc = value
            case "bcc": draft.bcc = value
            case "subject": draft.subject = value
            case "body": draft.openNew(lead: value + "\n\n", signature: signature)
            case "to": draft.to = draft.to.isEmpty ? value : draft.to + ", " + value
            default: break
            }
        }
        openMainWindow?()
        openCompose(draft, origin: .new)
    }

    func markAllReadEverywhere() {
        for folder in folders.values.flatMap({ $0 }) where folder.unreadCount > 0 {
            markAllRead(in: folder)
        }
    }

    var categories: [MailCategory] {
        get { categoryCache }
        set {
            categoryCache = newValue
            CategoryStore.save(newValue)
        }
    }

    func categories(for message: MessageSummary) -> [MailCategory] {
        let names = Set(categoryAssignments[message.id] ?? [])
        return categories.filter { names.contains($0.name) }
    }

    func selectionHasCategory(_ category: MailCategory) -> Bool {
        let list = selectedMessages
        guard !list.isEmpty else { return false }
        return list.allSatisfy { (categoryAssignments[$0.id] ?? []).contains(category.name) }
    }

    func toggleCategory(_ category: MailCategory, on messages: [MessageSummary]) {
        let messages = actionable(messages)
        guard !messages.isEmpty else { return }
        var map = categoryAssignments
        let adding = !messages.allSatisfy { (map[$0.id] ?? []).contains(category.name) }
        for message in messages {
            var names = Set(map[message.id] ?? [])
            if adding { names.insert(category.name) } else { names.remove(category.name) }
            if names.isEmpty { map[message.id] = nil } else { map[message.id] = Array(names).sorted() }
        }
        categoryAssignments = map
    }

    func clearCategories(on messages: [MessageSummary]) {
        let messages = actionable(messages)
        guard !messages.isEmpty else { return }
        var map = categoryAssignments
        for message in messages { map[message.id] = nil }
        categoryAssignments = map
    }
}
