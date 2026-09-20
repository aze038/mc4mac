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
    case date, from, to, subject, size, flag, status, attachments, account, folder

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .date: return "Date"
        case .from: return "From"
        case .to: return "To"
        case .subject: return "Subject"
        case .size: return "Size"
        case .flag: return "Flag Status"
        case .status: return "Status"
        case .attachments: return "Attachments"
        case .account: return "Account"
        case .folder: return "Folder"
        }
    }

    /// The label for the "ascending" end of this field, shown like Outlook's "Oldest at Top".
    var ascendingTitle: LocalizedStringKey {
        switch self {
        case .date: return "Oldest at Top"
        case .size: return "Smallest at Top"
        default: return "A at Top"
        }
    }

    var descendingTitle: LocalizedStringKey {
        switch self {
        case .date: return "Newest at Top"
        case .size: return "Largest at Top"
        default: return "Z at Top"
        }
    }

    func key(_ thread: MessageThread, names: (UUID) -> String, folders: (UUID) -> String) -> String {
        let m = thread.latest
        switch self {
        case .date: return ListSort.dayKey(m.date)
        case .from: return m.from.displayName.isEmpty ? m.from.address : m.from.displayName
        case .to: return m.to.first.map { $0.displayName.isEmpty ? $0.address : $0.displayName } ?? "No recipient"
        case .subject: return m.subject.isEmpty ? "(no subject)" : String(m.subject.prefix(1)).uppercased()
        case .size: return ListSort.sizeBand(m.size)
        case .flag: return m.isFlagged ? "Flagged" : "Not flagged"
        case .status: return thread.unreadCount > 0 ? "Unread" : "Read"
        case .attachments: return m.hasAttachments ? "With attachments" : "No attachments"
        case .account: return names(m.accountID)
        case .folder: return folders(m.folderID)
        }
    }

    static func dayKey(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if let week = cal.date(byAdding: .day, value: -7, to: Date()), date > week { return "Earlier this week" }
        if let month = cal.date(byAdding: .month, value: -1, to: Date()), date > month { return "Earlier this month" }
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: date)
    }

    static func sizeBand(_ bytes: Int) -> String {
        switch bytes {
        case ..<25_000: return "Tiny (under 25 KB)"
        case ..<100_000: return "Small (under 100 KB)"
        case ..<1_000_000: return "Medium (under 1 MB)"
        case ..<5_000_000: return "Large (under 5 MB)"
        default: return "Huge (5 MB and over)"
        }
    }

    func apply(_ threads: [MessageThread], ascending: Bool, names: (UUID) -> String, folders: (UUID) -> String) -> [MessageThread] {
        let sorted: [MessageThread]
        switch self {
        case .date:
            sorted = threads.sorted { $0.latest.date > $1.latest.date }
        case .size:
            sorted = threads.sorted { $0.latest.size > $1.latest.size }
        case .flag:
            sorted = threads.sorted { ($0.latest.isFlagged ? 0 : 1, $0.latest.date.timeIntervalSince1970 * -1) < ($1.latest.isFlagged ? 0 : 1, $1.latest.date.timeIntervalSince1970 * -1) }
        case .status:
            sorted = threads.sorted { ($0.unreadCount > 0 ? 0 : 1, $0.latest.date.timeIntervalSince1970 * -1) < ($1.unreadCount > 0 ? 0 : 1, $1.latest.date.timeIntervalSince1970 * -1) }
        case .attachments:
            sorted = threads.sorted { ($0.latest.hasAttachments ? 0 : 1, $0.latest.date.timeIntervalSince1970 * -1) < ($1.latest.hasAttachments ? 0 : 1, $1.latest.date.timeIntervalSince1970 * -1) }
        default:
            sorted = threads.sorted {
                let a = key($0, names: names, folders: folders)
                let b = key($1, names: names, folders: folders)
                if a.localizedCaseInsensitiveCompare(b) == .orderedSame { return $0.latest.date > $1.latest.date }
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
        }
        return ascending ? sorted.reversed() : sorted
    }
}

enum ListRow: Identifiable, Hashable {
    case group(String)
    case thread(MessageThread)
    case message(MessageSummary, threadID: String)

    static let childPrefix = "child:"
    static let groupPrefix = "group:"

    var id: String {
        switch self {
        case .group(let title): return ListRow.groupPrefix + title
        case .thread(let t): return t.id
        case .message(let m, _): return ListRow.childTag(m.id)
        }
    }

    var isGroup: Bool { if case .group = self { return true } else { return false } }

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
        var lastGroup: String?
        let sort = ListSort(rawValue: listSort) ?? .date
        for thread in threads {
            if showInGroups {
                let title = sort.key(thread, names: { self.accountName($0) }, folders: { self.folder($0)?.name ?? "Folder" })
                if title != lastGroup {
                    out.append(.group(title))
                    lastGroup = title
                }
            }
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
        case .group: return false
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
