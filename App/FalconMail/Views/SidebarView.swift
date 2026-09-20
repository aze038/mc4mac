import SwiftUI
import FalconCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var showAddAccount = false
    @AppStorage(Pref.hideLocalFolders) private var hideLocalFolders = false

    private var selectionBinding: Binding<SidebarSelection?> {
        Binding(get: { model.selection }, set: { model.select($0) })
    }

    private var pendingOutbox: Int {
        model.outboxItems.filter { $0.status == .queued || $0.status == .failed }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selectionBinding) {
                allAccountsSection
                ForEach(model.accounts) { account in
                    AccountFolderSection(account: account,
                                         folders: model.folders[account.id] ?? [],
                                         offline: model.online[account.id] == false,
                                         expanded: Binding(get: { model.isAccountExpanded(account.id) },
                                                           set: { model.setAccountExpanded(account.id, $0) }))
                }
                SmartFoldersSection(pendingOutbox: pendingOutbox)
                if !hideLocalFolders {
                    LocalFoldersSection(records: model.archiveRecords)
                }
                Section {
                    Button { showAddAccount = true } label: {
                        Label(model.accounts.isEmpty ? "Add your email account" : "Add account…", systemImage: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            .listStyle(.sidebar)
            Divider()
            ModuleRail()
        }
        .sheet(isPresented: $showAddAccount) { AddAccountSheet().environment(model) }
        .onReceive(NotificationCenter.default.publisher(for: .falconAddAccount)) { _ in showAddAccount = true }
    }

    private var allAccountsSection: some View {
        DisclosureGroup(isExpanded: Binding(get: { model.allAccountsExpanded }, set: { model.allAccountsExpanded = $0 })) {
            Label("All Inboxes", systemImage: "tray.2")
                .tag(SidebarSelection.unified)
                .badge(model.unifiedUnreadCount)
        } label: {
            Text("All Accounts").font(.system(size: 13, weight: .medium))
        }
    }
}

struct SmartFoldersSection: View {
    @Environment(AppModel.self) private var model
    let pendingOutbox: Int
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Label("Outbox", systemImage: "paperplane")
                .tag(SidebarSelection.outbox)
                .badge(pendingOutbox)
            Label("Unread", systemImage: "envelope.badge")
                .tag(SidebarSelection.smart(.unread))
                .badge(model.unifiedUnreadCount)
            Label("Flagged", systemImage: "flag")
                .tag(SidebarSelection.smart(.flagged))
            Label("With Attachments", systemImage: "paperclip")
                .tag(SidebarSelection.smart(.attachments))
        } label: {
            Text("Smart Folders").font(.system(size: 13, weight: .medium))
        }
    }
}

struct LocalFoldersSection: View {
    let records: [ArchiveRecord]
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if records.isEmpty {
                Text("No local archives yet").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(records) { record in
                    Label(record.name, systemImage: record.isEncrypted ? "lock.doc" : "archivebox")
                        .tag(SidebarSelection.archive(record.id))
                        .badge(record.messageCount)
                }
            }
        } label: {
            Text("On my Computer").font(.system(size: 13, weight: .medium))
        }
    }
}

struct AccountFolderSection: View {
    @Environment(AppModel.self) private var model
    let account: AccountInfo
    let folders: [FolderInfo]
    let offline: Bool
    @Binding var expanded: Bool

    private var hiddenUnread: Int {
        folders.filter { $0.role == .inbox }.reduce(0) { $0 + $1.unreadCount }
    }

    private var inbox: FolderInfo? { folders.first { $0.role == .inbox && $0.isSelectable } }

    private var rest: [FolderInfo] {
        folders.filter { $0.isSelectable && $0.role != .inbox }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if let inbox {
                FolderRow(folder: inbox).tag(SidebarSelection.folder(inbox.id))
            }
            ForEach(rest) { folder in
                FolderRow(folder: folder).tag(SidebarSelection.folder(folder.id))
            }
        } label: {
            HStack(spacing: 5) {
                Text(account.email).lineLimit(1).truncationMode(.middle)
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 4)
                if !account.isEnabled {
                    Image(systemName: "pause.circle").foregroundStyle(.secondary).help("Paused in Settings → Accounts")
                } else if offline {
                    Image(systemName: "wifi.slash").foregroundStyle(.orange)
                }
                if !expanded, hiddenUnread > 0 {
                    Text("\(hiddenUnread)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .contextMenu {
                Button("New Folder…") { model.createFolderPrompt(for: account) }
                Button("Sync This Account") { model.syncNow() }
            }
        }
    }
}

struct FolderRow: View {
    @Environment(AppModel.self) private var model
    let folder: FolderInfo

    private var icon: String {
        switch folder.role {
        case .inbox: return "tray"
        case .sent: return "paperplane"
        case .drafts: return "square.and.pencil"
        case .trash: return "trash"
        case .junk: return "xmark.bin"
        case .archive, .all: return "archivebox"
        case .flagged: return "star"
        case .important: return "exclamationmark.circle"
        case .other: return "folder"
        }
    }

    private var tint: Color {
        folder.role == .inbox ? Color.accentColor : Color.secondary
    }

    var body: some View {
        Label {
            Text(folder.name).lineLimit(1)
        } icon: {
            Image(systemName: icon).foregroundStyle(tint)
        }
        .padding(.leading, CGFloat(folder.depth) * 12)
        .badge(folder.unreadCount)
        .contextMenu {
            Button("Mark All as Read") { model.markAllRead(in: folder) }
                .disabled(folder.unreadCount == 0)
            if folder.role == .trash || folder.role == .junk {
                Button("Delete All", role: .destructive) { model.purgeEverything(in: folder) }
            }
        }
    }
}
