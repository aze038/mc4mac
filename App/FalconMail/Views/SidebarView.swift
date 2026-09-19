import SwiftUI
import FalconCore

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @State private var addingAccount = false

    private var selectionBinding: Binding<SidebarSelection?> {
        Binding(get: { model.selection }, set: { model.select($0) })
    }

    private var inboxUnread: Int {
        var total = 0
        for list in model.folders.values {
            for f in list where f.role == .inbox { total += f.unreadCount }
        }
        return total
    }

    private var pendingOutbox: Int {
        model.outboxItems.filter { $0.status == .queued || $0.status == .failed }.count
    }

    var body: some View {
        List(selection: selectionBinding) {
            topSection
            ForEach(model.accounts) { account in
                AccountFolderSection(account: account, folders: model.folders[account.id] ?? [], offline: model.online[account.id] == false)
            }
            if !model.archiveRecords.isEmpty {
                archiveSection
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { addAccountBar }
    }

    private var topSection: some View {
        Section {
            Label("All Inboxes", systemImage: "tray.2")
                .tag(SidebarSelection.unified)
                .badge(inboxUnread)
            Label("Calendar", systemImage: "calendar")
                .tag(SidebarSelection.calendar)
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

    private var addAccountBar: some View {
        HStack {
            Button(action: addAccount) {
                Label(model.accounts.isEmpty ? "Add Google Workspace account" : "Add account", systemImage: "plus.circle")
            }
            .buttonStyle(.plain)
            .disabled(addingAccount)
            if addingAccount { ProgressView().controlSize(.small) }
            Spacer()
        }
        .padding(10)
        .background(.bar)
    }

    private func addAccount() {
        addingAccount = true
        Task {
            defer { addingAccount = false }
            do { try await model.addGoogleAccount() } catch { model.errorMessage = error.localizedDescription }
        }
    }
}

struct AccountFolderSection: View {
    let account: AccountInfo
    let folders: [FolderInfo]
    let offline: Bool

    var body: some View {
        Section {
            ForEach(folders.filter { $0.isSelectable }) { folder in
                FolderRow(folder: folder).tag(SidebarSelection.folder(folder.id))
            }
        } header: {
            HStack {
                Text(account.email)
                Spacer()
                if offline { Image(systemName: "wifi.slash").foregroundStyle(.orange) }
            }
        }
    }
}

struct FolderRow: View {
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
    }
}
