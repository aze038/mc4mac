import SwiftUI
import FalconCore

/// Outlook's folder pane: flat rows on a grey ground, thirty points for accounts and sections,
/// twenty-four for folders, each level sixteen points further in, the chosen folder a full-width
/// lighter band, unread counts in blue at the right.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var showAddAccount = false
    @State private var smartExpanded = false
    @State private var localExpanded = false
    @AppStorage(Pref.hideLocalFolders) private var hideLocalFolders = false

    private var pendingOutbox: Int {
        model.outboxItems.filter { $0.status == .queued || $0.status == .failed }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) { rows }
            }
            .scrollIndicators(.automatic)
            Rectangle().fill(OLColor.divider).frame(height: 1)
            ModuleRail()
        }
        .background(OLColor.sidebar)
        .sheet(isPresented: $showAddAccount) { AddAccountSheet().environment(model) }
        .onReceive(NotificationCenter.default.publisher(for: .falconAddAccount)) { _ in showAddAccount = true }
    }

    @ViewBuilder private var rows: some View {
        SidebarTopRow(title: "All Accounts",
                      expanded: Binding(get: { model.allAccountsExpanded }, set: { model.allAccountsExpanded = $0 }))
        if model.allAccountsExpanded {
            SidebarFolderRow(level: 1, title: "All Inboxes", symbol: "tray.2", tint: OLColor.inbox,
                             count: model.unifiedUnreadCount, selected: model.selection == .unified) { model.select(.unified) }
        }
        ForEach(model.accounts) { account in
            accountRows(account)
        }
        SidebarTopRow(title: "Smart Folders", expanded: $smartExpanded)
        if smartExpanded {
            SidebarFolderRow(level: 1, title: "Outbox", symbol: "paperplane", count: pendingOutbox,
                             selected: model.selection == .outbox) { model.select(.outbox) }
            SidebarFolderRow(level: 1, title: "Unread", symbol: "envelope.badge", count: model.unifiedUnreadCount,
                             selected: model.selection == .smart(.unread)) { model.select(.smart(.unread)) }
            SidebarFolderRow(level: 1, title: "Flagged", symbol: "flag", count: 0,
                             selected: model.selection == .smart(.flagged)) { model.select(.smart(.flagged)) }
            SidebarFolderRow(level: 1, title: "With Attachments", symbol: "paperclip", count: 0,
                             selected: model.selection == .smart(.attachments)) { model.select(.smart(.attachments)) }
        }
        if !hideLocalFolders {
            SidebarTopRow(title: "On my Computer", expanded: $localExpanded)
            if localExpanded {
                if model.archiveRecords.isEmpty {
                    SidebarFolderRow(level: 1, title: "No local archives yet", symbol: "archivebox", textColor: OLColor.textDim,
                                     count: 0, selected: false) {}
                } else {
                    ForEach(model.archiveRecords) { record in
                        SidebarFolderRow(level: 1, title: record.name, symbol: record.isEncrypted ? "lock.doc" : "archivebox",
                                         count: record.messageCount, selected: model.selection == .archive(record.id)) {
                            model.select(.archive(record.id))
                        }
                    }
                }
            }
        }
        SidebarFolderRow(level: 1, title: model.accounts.isEmpty ? "Add your email account" : "Add account…", symbol: "plus.circle",
                         tint: OLColor.unread, textColor: OLColor.unread, count: 0, selected: false) { showAddAccount = true }
            .padding(.top, 6)
    }

    @ViewBuilder private func accountRows(_ account: AccountInfo) -> some View {
        let folders = model.folders[account.id] ?? []
        let expanded = model.isAccountExpanded(account.id)
        let hiddenUnread = folders.filter { $0.role == .inbox }.reduce(0) { $0 + $1.unreadCount }
        SidebarTopRow(title: account.email,
                      expanded: Binding(get: { model.isAccountExpanded(account.id) }, set: { model.setAccountExpanded(account.id, $0) })) {
            if !account.isEnabled {
                Image(systemName: "pause.circle").foregroundStyle(OLColor.textDim).help("Paused in Settings → Accounts")
            } else if model.online[account.id] == false {
                Image(systemName: "wifi.slash").foregroundStyle(Color.orange)
            }
            if !expanded, hiddenUnread > 0 {
                Text("\(hiddenUnread)").font(.system(size: OL.sidebarCountFont)).foregroundStyle(OLColor.unread)
            }
        }
        .contextMenu {
            Button("New Folder…") { model.createFolderPrompt(for: account) }
            Button("Sync This Account") { model.syncNow() }
        }
        if expanded {
            // Outlook shows a container such as [Gmail] as a folder with its children under it,
            // even when the container itself holds no mail.
            let ordered = SidebarView.treeOrder(folders)
            ForEach(ordered) { folder in
                SidebarFolderRow(level: 1 + folder.depth, title: folder.name, symbol: SidebarView.icon(for: folder),
                                 tint: folder.role == .inbox ? OLColor.inbox : OLColor.icon,
                                 count: folder.unreadCount, selected: model.selection == .folder(folder.id),
                                 disclosure: SidebarView.hasChildren(folder, in: folders) ? .open : .none) {
                    if folder.isSelectable { model.select(.folder(folder.id)) }
                }
                    .contextMenu {
                        Button("Mark All as Read") { model.markAllRead(in: folder) }
                            .disabled(folder.unreadCount == 0)
                        if folder.role == .trash || folder.role == .junk {
                            Button("Delete All", role: .destructive) { model.purgeEverything(in: folder) }
                        }
                    }
            }
        }
    }

    /// The inbox first, then the account's own order, with every container placed just before
    /// the first of its children so the tree reads top down as Outlook draws it.
    static func treeOrder(_ folders: [FolderInfo]) -> [FolderInfo] {
        let shown = folders.filter { $0.isSelectable || hasChildren($0, in: folders) }
        let queue = shown.filter { $0.role == .inbox } + shown.filter { $0.role != .inbox }
        var result: [FolderInfo] = []
        var emitted = Set<UUID>()
        for folder in queue where !emitted.contains(folder.id) {
            let ancestors = shown.filter { $0.id != folder.id && !emitted.contains($0.id) && folder.path.hasPrefix($0.path + ($0.delimiter.isEmpty ? "/" : $0.delimiter)) }
                .sorted { $0.depth < $1.depth }
            for ancestor in ancestors {
                result.append(ancestor)
                emitted.insert(ancestor.id)
            }
            result.append(folder)
            emitted.insert(folder.id)
        }
        return result
    }

    static func hasChildren(_ folder: FolderInfo, in folders: [FolderInfo]) -> Bool {
        let prefix = folder.path + (folder.delimiter.isEmpty ? "/" : folder.delimiter)
        return folders.contains { $0.id != folder.id && $0.path.hasPrefix(prefix) }
    }

    static func icon(for folder: FolderInfo) -> String {
        switch folder.role {
        case .inbox: return "tray"
        case .sent: return "paperplane"
        case .drafts: return "square.and.pencil"
        case .trash: return "trash"
        case .junk: return "xmark.bin"
        case .archive, .all: return "archivebox"
        case .flagged, .important, .other: return "folder"
        }
    }
}

/// "All Accounts", an account, "Smart Folders", "On my Computer": thirty points tall, a thin
/// chevron at five points, the name at twenty-three and a half, fourteen point text.
struct SidebarTopRow<Trailing: View>: View {
    let title: String
    @Binding var expanded: Bool
    @ViewBuilder var trailing: () -> Trailing

    init(title: String, expanded: Binding<Bool>, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        _expanded = expanded
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(OLColor.icon)
                .frame(width: 12, height: 12)
                .padding(.leading, OL.sidebarChevronX - 2)
            Text(title)
                .font(.system(size: OL.sidebarTopFont))
                .foregroundStyle(OLColor.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, OL.sidebarTopTextX - OL.sidebarChevronX - 10)
            Spacer(minLength: 4)
            trailing()
                .padding(.trailing, OL.sidebarCountRight)
        }
        .frame(height: OL.sidebarRowTop)
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
    }
}

enum SidebarDisclosure { case none, open, closed }

/// A folder: twenty-four points tall, icon at thirty-seven and text at sixty-one for the first
/// level, sixteen further in per level, the count in blue at the right.
struct SidebarFolderRow: View {
    let level: Int
    let title: String
    let symbol: String
    var tint: Color = OLColor.icon
    var textColor: Color = OLColor.text
    let count: Int
    let selected: Bool
    var disclosure: SidebarDisclosure = .none
    let action: () -> Void

    private var indent: CGFloat { CGFloat(max(level, 1) - 1) * OL.sidebarIndent }

    var body: some View {
        HStack(spacing: 0) {
            if disclosure != .none {
                Image(systemName: disclosure == .open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(OLColor.icon)
                    .frame(width: 10, height: 10)
                    .padding(.leading, OL.sidebarLevelChevronX + indent)
                    .padding(.trailing, OL.sidebarLevelIconX - OL.sidebarLevelChevronX - 10)
            } else {
                Color.clear.frame(width: OL.sidebarLevelIconX + indent, height: 1)
            }
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: OL.sidebarIcon, height: OL.sidebarIcon)
            Text(title)
                .font(.system(size: OL.sidebarFolderFont))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .padding(.leading, OL.sidebarLevelTextX - OL.sidebarLevelIconX - OL.sidebarIcon)
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: OL.sidebarCountFont))
                    .foregroundStyle(OLColor.unread)
                    .padding(.trailing, OL.sidebarCountRight)
            }
        }
        .frame(height: OL.sidebarRowFolder)
        .background(selected ? OLColor.sidebarSelected : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { action() }
    }
}
