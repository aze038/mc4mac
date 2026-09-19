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
            if model.activeTab == nil {
                CommandBar()
                Divider()
            }
            if !model.tabs.isEmpty {
                WorkspaceTabStrip()
                Divider()
            }
            HStack(spacing: 0) {
                ModuleRail()
                Divider()
                ZStack {
                    moduleContent
                        .opacity(model.activeTab == nil ? 1 : 0)
                        .allowsHitTesting(model.activeTab == nil)
                    if let tab = model.activeTab {
                        WorkspaceTabContent(tab: tab)
                            .id(tab.id)
                            .background(Color(nsColor: .windowBackgroundColor))
                    }
                    if model.showsMovePalette {
                        MovePalette()
                    }
                }
            }
        }
        .background(MailboxWindowAccessor())
        .background(KeyRouterView(model: model))
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

    @ViewBuilder private var moduleContent: some View {
        switch model.module {
        case .calendar: CalendarView()
        case .people: ContactsView()
        case .mail:
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 340)
            } content: {
                contentColumn
                    .navigationSplitViewColumnWidth(min: 340, ideal: 400, max: 600)
            } detail: {
                detailColumn
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    @ViewBuilder private var contentColumn: some View {
        switch model.selection {
        case .outbox: OutboxView()
        case .archive(let id):
            if let record = model.archiveRecords.first(where: { $0.id == id }) { ArchiveBrowserView(record: record) } else { Text("Archive not found") }
        default: MessageListView()
        }
    }

    @ViewBuilder private var detailColumn: some View {
        switch model.selection {
        case .outbox, .archive: EmptyView()
        default:
            if let thread = model.currentThread {
                MessageReaderView(message: thread.latest, conversation: model.currentConversation)
                    .id(thread.latest.id)
            } else if model.selectedMessageIDs.count > 1 {
                ContentUnavailableView("\(model.selectedMessageIDs.count) conversations selected", systemImage: "envelope.badge")
            } else {
                ContentUnavailableView("No message selected", systemImage: "envelope.open")
            }
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

struct StatusBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(model.online.values.contains(false) ? Color.orange : Color.green).frame(width: 8, height: 8)
            Text(model.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if model.online.values.contains(false) {
                Button("Offline · Retry") { model.syncNow() }.buttonStyle(.link).font(.caption).foregroundStyle(Color.orange)
            }
            Spacer()
            chordCapsule
            actionErrorCapsule
            undoCapsule
            sendingCapsules
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(.bar)
    }

    @ViewBuilder private var chordCapsule: some View {
        if let hint = model.keyChordHint {
            Text(hint)
                .font(.caption.monospaced())
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.18), in: Capsule())
                .help("Waiting for the second key of a shortcut")
        }
    }

    @ViewBuilder private var actionErrorCapsule: some View {
        if let message = model.actionError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle").font(.caption)
                Text(message).font(.caption).lineLimit(1)
                if model.actionErrorNeedsDismissal {
                    Button { model.dismissActionError() } label: { Image(systemName: "xmark.circle.fill").font(.caption) }
                        .buttonStyle(.plain)
                        .help("This happened while FalconMail was in the background. Dismiss it once you have read it.")
                }
            }
            .foregroundStyle(Color.red)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.red.opacity(0.12), in: Capsule())
        }
    }

    @ViewBuilder private var undoCapsule: some View {
        if let undo = model.pendingUndo {
            HStack(spacing: 6) {
                Text(undo.summary).font(.caption)
                Button("Undo") { model.undoLastAction() }.buttonStyle(.link).font(.caption)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.secondary.opacity(0.14), in: Capsule())
        }
    }

    private var sendingCapsules: some View {
        ForEach(model.sendingSoonItems) { item in
            HStack(spacing: 6) {
                Text("Sending “\(item.subject.isEmpty ? "(no subject)" : item.subject)”").font(.caption)
                Button("Undo") { model.cancelAndReopen(item) { openWindow(value: $0) } }.buttonStyle(.link).font(.caption)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
        }
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
