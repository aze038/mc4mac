import SwiftUI
import FalconCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var showAddAccount = false

    private var selectionBinding: Binding<SidebarSelection?> {
        Binding(get: { model.selection }, set: { model.select($0) })
    }

    private var pendingOutbox: Int {
        model.outboxItems.filter { $0.status == .queued || $0.status == .failed }.count
    }

    var body: some View {
        List(selection: selectionBinding) {
            topSection
            ForEach(model.accounts) { account in
                AccountFolderSection(account: account, folders: model.folders[account.id] ?? [], offline: model.online[account.id] == false,
                                     expanded: Binding(get: { model.isAccountExpanded(account.id) },
                                                       set: { model.setAccountExpanded(account.id, $0) }))
            }
            if !model.archiveRecords.isEmpty {
                archiveSection
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
        .sheet(isPresented: $showAddAccount) { AddAccountSheet().environment(model) }
        .onReceive(NotificationCenter.default.publisher(for: .falconAddAccount)) { _ in showAddAccount = true }
    }

    private var topSection: some View {
        Section("Favorites") {
            Label("All Inboxes", systemImage: "tray.2")
                .tag(SidebarSelection.unified)
                .badge(model.unifiedUnreadCount)
            Label("Outbox", systemImage: "paperplane")
                .tag(SidebarSelection.outbox)
                .badge(pendingOutbox)
        }
    }

    private var archiveSection: some View {
        Section("Archives") {
            ForEach(model.archiveRecords) { record in
                Label(record.name, systemImage: record.isEncrypted ? "lock.doc" : "archivebox")
                    .tag(SidebarSelection.archive(record.id))
                    .badge(record.messageCount)
            }
        }
    }
}

struct AccountFolderSection: View {
    let account: AccountInfo
    let folders: [FolderInfo]
    let offline: Bool
    @Binding var expanded: Bool

    private var hiddenUnread: Int {
        folders.filter { $0.role == .inbox }.reduce(0) { $0 + $1.unreadCount }
    }

    var body: some View {
        Section {
            if expanded {
                ForEach(folders.filter { $0.isSelectable }) { folder in
                    FolderRow(folder: folder).tag(SidebarSelection.folder(folder.id))
                }
            }
        } header: {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 10)
                    Text(account.email).lineLimit(1).truncationMode(.middle)
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide the folders of \(account.email)" : "Show the folders of \(account.email)")
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
        case .drafts: return "doc"
        case .trash: return "trash"
        case .junk: return "xmark.bin"
        case .archive, .all: return "archivebox"
        case .flagged: return "flag"
        case .important: return "exclamationmark.circle"
        case .other: return "folder"
        }
    }

    var body: some View {
        Label(folder.name, systemImage: icon)
            .padding(.leading, CGFloat(folder.depth) * 12)
            .badge(folder.unreadCount)
            .contextMenu {
                Button("Mark All as Read") { model.markAllRead(in: folder) }
                    .disabled(folder.unreadCount == 0)
            }
    }
}
