import SwiftUI
import FalconCore

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @State private var addingAccount = false

    var body: some View {
        List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
            Section {
                Label("All Inboxes", systemImage: "tray.2").tag(SidebarSelection.unified)
                    .badge(model.folders.values.flatMap { $0 }.filter { $0.role == .inbox }.reduce(0) { $0 + $1.unreadCount })
                Label("Calendar", systemImage: "calendar").tag(SidebarSelection.calendar)
                Label("Outbox", systemImage: "paperplane").tag(SidebarSelection.outbox)
                    .badge(model.outboxItems.filter { $0.status == .queued || $0.status == .failed }.count)
            }
            ForEach(model.accounts) { account in
                Section {
                    ForEach(model.folders[account.id] ?? []) { folder in
                        if folder.isSelectable {
                            FolderRow(folder: folder).tag(SidebarSelection.folder(folder.id))
                        }
                    }
                } header: {
                    HStack {
                        Text(account.email)
                        Spacer()
                        if model.online[account.id] == false { Image(systemName: "wifi.slash").foregroundStyle(.orange) }
                    }
                }
            }
            if !model.archiveRecords.isEmpty {
                Section("Archives") {
                    ForEach(model.archiveRecords) { record in
                        Label(record.name, systemImage: record.isEncrypted ? "lock.doc" : "archivebox")
                            .tag(SidebarSelection.archive(record.id))
                            .badge(record.messageCount)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    addingAccount = true
                    Task {
                        defer { addingAccount = false }
                        do { try await model.addGoogleAccount() } catch { model.errorMessage = error.localizedDescription }
                    }
                } label: {
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
    }
}

struct FolderRow: View {
    let folder: FolderInfo

    var icon: String {
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
