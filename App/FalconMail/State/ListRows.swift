import SwiftUI
import FalconCore

enum AppModule: String, CaseIterable, Identifiable {
    case mail, calendar, people

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .mail: return "Mail"
        case .calendar: return "Calendar"
        case .people: return "People"
        }
    }

    var symbol: String {
        switch self {
        case .mail: return "envelope.fill"
        case .calendar: return "calendar"
        case .people: return "person.2.fill"
        }
    }
}

enum ListSort: String, CaseIterable, Identifiable {
    case newest, oldest, unreadFirst, sender

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .newest: return "Recent"
        case .oldest: return "Oldest"
        case .unreadFirst: return "Unread first"
        case .sender: return "Sender"
        }
    }

    func apply(_ threads: [MessageThread]) -> [MessageThread] {
        switch self {
        case .newest: return threads
        case .oldest: return threads.reversed()
        case .unreadFirst: return threads.filter { $0.unreadCount > 0 } + threads.filter { $0.unreadCount == 0 }
        case .sender: return threads.sorted { $0.latest.from.displayName.localizedCaseInsensitiveCompare($1.latest.from.displayName) == .orderedAscending }
        }
    }
}

enum ListRow: Identifiable, Hashable {
    case thread(MessageThread)
    case message(MessageSummary, threadID: String)

    static let childPrefix = "child:"

    var id: String {
        switch self {
        case .thread(let t): return t.id
        case .message(let m, _): return ListRow.childTag(m.id)
        }
    }

    static func childTag(_ messageID: String) -> String { childPrefix + messageID }

    static func childMessageID(_ tag: String) -> String? {
        tag.hasPrefix(childPrefix) ? String(tag.dropFirst(childPrefix.count)) : nil
    }
}

extension AppModel {
    var module: AppModule {
        switch selection {
        case .calendar: return .calendar
        case .contacts: return .people
        default: return .mail
        }
    }

    func showModule(_ target: AppModule) {
        switch target {
        case .calendar: select(.calendar)
        case .people: select(.contacts)
        case .mail: if module != .mail { select(lastMailSelection ?? .unified) }
        }
    }

    func folder(accountID: UUID, role: FolderRole) -> FolderInfo? {
        folders[accountID]?.first { $0.role == role }
    }

    var listTitle: String {
        if !searchText.trimmed.isEmpty { return "Search results" }
        switch selection {
        case .unified: return "All Inboxes"
        case .folder(let id): return folder(id)?.name ?? "Folder"
        default: return ""
        }
    }

    var rows: [ListRow] {
        var out: [ListRow] = []
        out.reserveCapacity(threads.count)
        for thread in threads {
            out.append(.thread(thread))
            if thread.messages.count > 1, expandedThreadIDs.contains(thread.id) {
                for message in thread.messages { out.append(.message(message, threadID: thread.id)) }
            }
        }
        return out
    }

    var currentConversation: MessageThread? {
        guard selectedMessageIDs.count == 1, let id = selectedMessageIDs.first else { return nil }
        if let thread = threads.first(where: { $0.id == id }) { return thread }
        guard let messageID = ListRow.childMessageID(id) else { return nil }
        return threads.first { $0.messages.contains { $0.id == messageID } }
    }

    var hasExpandableThreads: Bool { threads.contains { $0.messages.count > 1 } }

    var canCollapseSomething: Bool { !expandedThreadIDs.isEmpty }

    func isExpanded(_ thread: MessageThread) -> Bool { expandedThreadIDs.contains(thread.id) }

    func toggleExpanded(_ thread: MessageThread) {
        if expandedThreadIDs.contains(thread.id) { collapse(thread) } else { expand(thread) }
    }

    func expand(_ thread: MessageThread) {
        guard thread.messages.count > 1 else { return }
        expandedThreadIDs.insert(thread.id)
    }

    func collapse(_ thread: MessageThread) {
        expandedThreadIDs.remove(thread.id)
        let childTags = Set(thread.messages.map { ListRow.childTag($0.id) })
        if !selectedMessageIDs.isDisjoint(with: childTags) { selectedMessageIDs = [thread.id] }
    }

    func expandAll() {
        expandedThreadIDs = Set(threads.filter { $0.messages.count > 1 }.map(\.id))
    }

    func collapseAll() {
        for thread in threads where expandedThreadIDs.contains(thread.id) { collapse(thread) }
        expandedThreadIDs = []
    }

    @discardableResult
    func expandCurrent() -> Bool {
        guard let conversation = currentConversation, conversation.messages.count > 1, !isExpanded(conversation) else { return false }
        expand(conversation)
        return true
    }

    @discardableResult
    func collapseCurrent() -> Bool {
        guard let conversation = currentConversation, isExpanded(conversation) else { return false }
        collapse(conversation)
        return true
    }

    private var selectedRowIndices: [Int] {
        let current = rows
        return current.indices.filter { selectedMessageIDs.contains(current[$0].id) }
    }

    private func selectRow(at index: Int) {
        let current = rows
        guard current.indices.contains(index) else { return }
        selectedMessageIDs = [current[index].id]
    }

    func selectNextThread() {
        let current = rows
        guard !current.isEmpty else { return }
        guard let last = selectedRowIndices.max() else { return selectRow(at: 0) }
        selectRow(at: min(last + 1, current.count - 1))
    }

    func selectPreviousThread() {
        let current = rows
        guard !current.isEmpty else { return }
        guard let first = selectedRowIndices.min() else { return selectRow(at: current.count - 1) }
        selectRow(at: max(first - 1, 0))
    }

    private func rowIsUnread(_ row: ListRow) -> Bool {
        switch row {
        case .thread(let t): return t.unreadCount > 0
        case .message(let m, _): return !m.isRead
        }
    }

    func selectNextUnread() {
        let current = rows
        let start = selectedRowIndices.max().map { $0 + 1 } ?? 0
        guard start < current.count, let next = current[start...].first(where: rowIsUnread) else {
            statusText = "No more unread conversations"
            return
        }
        selectedMessageIDs = [next.id]
    }

    func selectPreviousUnread() {
        let current = rows
        let end = min(selectedRowIndices.min() ?? current.count, current.count)
        guard let previous = current[..<end].last(where: rowIsUnread) else {
            statusText = "No earlier unread conversations"
            return
        }
        selectedMessageIDs = [previous.id]
    }
}
