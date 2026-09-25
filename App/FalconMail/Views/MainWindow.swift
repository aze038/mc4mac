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
    @AppStorage(Pref.readingPane) private var readingPane = ReadingPanePosition.right.rawValue

    var body: some View {
        VStack(spacing: 0) {
            CommandBar()
            if !model.tabs.isEmpty {
                WorkspaceTabStrip()
                Divider()
            }
            ZStack {
                moduleContent
                if model.showsMovePalette, model.movePaletteWindow == nil {
                    MovePalette()
                }
            }
            WindowTrayBar()
            StatusBar()
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(OLColor.reading)
        .background(MailboxWindowAccessor())
        .background(KeyRouterView(model: model))
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
        .onReceive(WindowTray.shared.$book.removeDuplicates()) { _ in model.saveSession() }
        .onChange(of: model.drafts.count) { _, _ in model.saveSession() }
    }

    private var pane: ReadingPanePosition { ReadingPanePosition(rawValue: readingPane) ?? .right }

    @ViewBuilder private var moduleContent: some View {
        switch model.module {
        case .calendar: CalendarView()
        case .people: ContactsView()
        case .mail:
            switch pane {
            case .right:
                OutlookColumns { SidebarView() } list: { contentColumn } detail: { detailColumn }
            case .below:
                OutlookColumns(showList: false) { SidebarView() } list: { EmptyView() } detail: {
                    VSplitView {
                        contentColumn.frame(minHeight: 180)
                        detailColumn.frame(minHeight: 180)
                    }
                }
            case .off:
                OutlookColumns(showList: false) { SidebarView() } list: { EmptyView() } detail: {
                    if model.activeTab != nil {
                        detailColumn
                    } else {
                        contentColumn
                    }
                }
            }
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
        if let tab = model.activeTab {
            WorkspaceTabContent(tab: tab)
                .id(tab.id)
                .background(Color(nsColor: .textBackgroundColor))
        } else {
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

    /// Outlook's wording for a quiet mailbox, and its "Connected to:" tail. Nothing is claimed
    /// to be up to date while an account cannot sync; what stops it is shown on its own.
    private var stateText: String? {
        guard model.statusText == "Up to date" || model.statusText == "Ready" else { return model.statusText }
        return model.everyAccountReachable ? "All folders are up to date." : nil
    }

    private var connectedText: String? {
        let online = model.accounts.filter { $0.isEnabled && model.online[$0.id] != false }.map(\.email)
        return online.isEmpty ? nil : "Connected to: " + online.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("Items: \(model.itemCount)")
                .font(.system(size: OL.statusFont).monospacedDigit())
                .foregroundStyle(OLColor.text)
                .padding(.leading, OL.statusLeftX)
            ForEach(model.accounts.filter { model.accountsNeedingSignIn.contains($0.id) }) { account in
                if account.usesPassword {
                    // Its password is changed in Settings → Accounts, which restarts its sync.
                    Button("Update the password for \(account.email)") {
                        SettingsWindows.shared.show(.accounts)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                } else {
                    Button("Sign in to \(account.email) again") { signInAgain(account) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            ForEach(model.offlineAccounts) { account in
                Button("\(account.email) is offline · Retry") { model.syncNow() }
                    .buttonStyle(.link).font(.caption).foregroundStyle(Color.orange)
            }
            ForEach(model.pausedAccountNotices, id: \.account.id) { notice in
                Text(notice.text)
                    .font(.caption).foregroundStyle(Color.orange).lineLimit(1).truncationMode(.middle)
                    .help(notice.text)
            }
            Spacer()
            chordCapsule
            actionErrorCapsule
            undoCapsule
            discardCapsule
            sendingCapsules
            if let summary = model.syncingSummary {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                Text(summary).font(.system(size: OL.statusFont)).foregroundStyle(OLColor.text).lineLimit(1)
            } else if let stateText {
                Text(stateText).font(.system(size: OL.statusFont)).foregroundStyle(OLColor.text).lineLimit(1)
            }
            if let connectedText {
                Text(connectedText).font(.system(size: OL.statusFont)).foregroundStyle(OLColor.text).lineLimit(1)
            }
        }
        .padding(.trailing, OL.statusRightInset)
        .frame(height: OL.status)
        .background(OLColor.status)
        .overlay(alignment: .top) { Rectangle().fill(OLColor.chromeLine).frame(height: 1) }
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

    /// Offered for ten seconds after Discard, so a message thrown away by mistake comes back.
    @ViewBuilder private var discardCapsule: some View {
        if model.discarded.held != nil {
            DiscardedBanner(undo: { model.undoDiscard() })
        }
    }

    private func signInAgain(_ account: AccountInfo) {
        Task {
            do { try await model.addGoogleAccount(loginHint: account.email) } catch { model.showAlert(for: error) }
        }
    }

    private var sendingCapsules: some View {
        ForEach(model.sendingSoonItems) { item in
            HStack(spacing: 6) {
                Text("Sending “\(item.subject.isEmpty ? "(no subject)" : item.subject)”").font(.caption)
                Button("Undo") { model.cancelAndReopen(item) }.buttonStyle(.link).font(.caption)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
        }
    }
}

/// "Message discarded" with Undo, in the status bar's capsule style.
struct DiscardedBanner: View {
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "trash").font(.caption)
            Text("Message discarded").font(.caption)
            Button("Undo", action: undo).buttonStyle(.link).font(.caption)
                .help("Open the discarded message again")
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color.secondary.opacity(0.14), in: Capsule())
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
