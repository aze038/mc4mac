import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FalconCore

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject var updates: UpdateManager
    @Environment(\.openWindow) private var openWindow
    @State private var showArchiveSheet = false
    @State private var showExportArchiveSheet = false
    @State private var showOpenArchiveSheet = false
    @State private var showImportPicker = false
    @State private var importTarget: FolderInfo?

    var body: some View {
        VStack(spacing: 0) {
            if !model.tabs.isEmpty {
                WorkspaceTabStrip()
                Divider()
            }
            ZStack {
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
                } content: {
                    contentColumn
                        .navigationSplitViewColumnWidth(min: 320, ideal: 420, max: 640)
                } detail: {
                    detailColumn
                }
                .opacity(model.activeTab == nil ? 1 : 0)
                .allowsHitTesting(model.activeTab == nil)
                if let tab = model.activeTab {
                    WorkspaceTabContent(tab: tab)
                        .id(tab.id)
                        .background(Color(nsColor: .windowBackgroundColor))
                }
            }
        }
        .toolbar { toolbarItems }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                WindowTrayBar()
                StatusBar()
            }
        }
        .sheet(isPresented: Binding(get: { updates.shouldPrompt }, set: { _ in })) { UpdateSheet().environmentObject(updates) }
        .disabled(updates.isMandatory)
        .sheet(isPresented: $showArchiveSheet) { ArchiveSheet().environment(model) }
        .sheet(isPresented: $showExportArchiveSheet) { ArchiveSheet(localExport: true).environment(model) }
        .sheet(isPresented: $showOpenArchiveSheet) { OpenArchiveSheet().environment(model) }
        .sheet(item: $importTarget) { folder in ImportSheet(folder: folder).environment(model) }
        .alert("FalconMail", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .falconArchive)) { _ in showArchiveSheet = true }
        .onReceive(NotificationCenter.default.publisher(for: .falconExportArchive)) { _ in showExportArchiveSheet = true }
        .onReceive(NotificationCenter.default.publisher(for: .falconOpenArchive)) { _ in showOpenArchiveSheet = true }
        .onReceive(NotificationCenter.default.publisher(for: .falconImport)) { _ in startImport() }
        .onReceive(NotificationCenter.default.publisher(for: .falconExport)) { _ in exportSelected() }
        .onChange(of: model.selectedMessageIDs) { _, _ in model.saveSession() }
        .onChange(of: model.openMessageWindows) { _, _ in model.saveSession() }
        .onChange(of: model.drafts.count) { _, _ in model.saveSession() }
    }

    @ViewBuilder private var contentColumn: some View {
        switch model.selection {
        case .calendar: CalendarView()
        case .contacts: ContactsView()
        case .outbox: OutboxView()
        case .archive(let id):
            if let record = model.archiveRecords.first(where: { $0.id == id }) { ArchiveBrowserView(record: record) } else { Text("Archive not found") }
        default: MessageListView()
        }
    }

    @ViewBuilder private var detailColumn: some View {
        switch model.selection {
        case .calendar, .contacts, .outbox, .archive: EmptyView()
        default:
            if let thread = model.currentThread {
                MessageDetailView(thread: thread)
            } else if model.selectedMessageIDs.count > 1 {
                ContentUnavailableView("\(model.selectedMessageIDs.count) conversations selected", systemImage: "envelope.badge")
            } else {
                ContentUnavailableView("No message selected", systemImage: "envelope.open")
            }
        }
    }

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { compose() } label: { Label("New Message", systemImage: "square.and.pencil") }
                .disabled(model.accounts.isEmpty)
            Button { model.syncNow() } label: { Label("Check Mail", systemImage: "arrow.clockwise") }
        }
        if model.activeTab == nil {
            ToolbarItemGroup(placement: .primaryAction) {
                ReplyToolbar(reply: reply, forward: forward)
                MessageActionsToolbar()
            }
        }
    }

    private func compose() {
        guard let account = model.accounts.first else { return }
        model.openCompose(.blank(account: account))
    }

    private func reply(all: Bool) {
        guard let thread = model.currentThread, let account = model.account(for: thread.latest) else { return }
        Task {
            let parsed = await model.parsedBody(for: thread.latest)
            model.openCompose(.reply(to: thread.latest, parsed: parsed, account: account, all: all))
        }
    }

    private func forward() {
        guard let thread = model.currentThread, let account = model.account(for: thread.latest) else { return }
        Task {
            let parsed = await model.parsedBody(for: thread.latest)
            model.openCompose(.forward(thread.latest, parsed: parsed, account: account))
        }
    }

    private func startImport() {
        if case .folder(let id) = model.selection, let f = model.folder(id) {
            importTarget = f
        } else if let inbox = model.folders.values.flatMap({ $0 }).first(where: { $0.role == .inbox }) {
            importTarget = inbox
        }
    }

    private func exportSelected() {
        guard !model.selectedMessages.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        if panel.runModal() == .OK, let url = panel.url { model.exportSelectedAsEML(to: url) }
    }
}

struct ReplyToolbar: View {
    @Environment(AppModel.self) private var model
    let reply: (Bool) -> Void
    let forward: () -> Void

    var body: some View {
        let disabled = model.currentThread == nil
        Button { reply(false) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }.disabled(disabled)
        Button { reply(true) } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }.disabled(disabled)
        Button { forward() } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }.disabled(disabled)
    }
}

struct MessageActionsToolbar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selected = model.selectedMessages
        let none = selected.isEmpty
        Button { model.archive(selected) } label: { Label("Archive", systemImage: "archivebox") }.disabled(none)
        Button { model.delete(selected) } label: { Label("Delete", systemImage: "trash") }.disabled(none)
        Button { model.setFlagged(selected, !(selected.first?.isFlagged ?? false)) } label: { Label("Flag", systemImage: "flag") }.disabled(none)
        MoveMenu(selected: selected)
        Button { model.markRead(selected, !(selected.first?.isRead ?? true)) } label: { Label("Read/Unread", systemImage: "envelope.open") }.disabled(none)
    }
}

struct MoveMenu: View {
    @Environment(AppModel.self) private var model
    let selected: [MessageSummary]

    var body: some View {
        Menu {
            ForEach(model.accounts) { account in
                Section(account.email) {
                    ForEach(model.folders[account.id] ?? []) { folder in
                        Button(folder.path) { model.move(selected, to: folder) }
                    }
                }
            }
        } label: {
            Label("Move", systemImage: "folder")
        }
        .disabled(selected.isEmpty)
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(model.online.values.contains(false) ? Color.orange : Color.green).frame(width: 8, height: 8)
            Text(model.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            ForEach(model.outboxItems.filter { $0.canUndo }) { item in
                HStack(spacing: 6) {
                    Text("Sending “\(item.subject.isEmpty ? "(no subject)" : item.subject)”").font(.caption)
                    Button("Undo") { model.undoSend(item) }.buttonStyle(.link).font(.caption)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(.bar)
    }
}

struct ImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let folder: FolderInfo
    @State private var target: FolderInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import mail").font(.title2.bold())
            Text("Choose .eml or .mbox files. Messages are uploaded to the selected folder on the server, so they appear on every device.")
                .foregroundStyle(.secondary)
            Picker("Into folder", selection: $target) {
                ForEach(model.folders[folder.accountID] ?? []) { f in Text(f.path).tag(Optional(f)) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Choose Files…") {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = true
                    panel.allowedContentTypes = [UTType(filenameExtension: "eml") ?? .emailMessage, UTType(filenameExtension: "mbox") ?? .data]
                    if panel.runModal() == .OK, let t = target ?? Optional(folder) {
                        model.importFiles(panel.urls, into: t)
                        dismiss()
                    }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 460)
        .onAppear { target = folder }
    }
}
