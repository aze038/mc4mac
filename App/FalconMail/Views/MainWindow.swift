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
    /// The window this mailbox is in, and the one filling the screen, if any.
    @State private var ownWindow: ObjectIdentifier?
    @State private var fullScreenMailbox: ObjectIdentifier?
    /// Drawn as it looks filling the screen, by the debug snapshots.
    var snapshotFillsScreen = false
    @Environment(\.falconStyle) private var style

    /// Whether this window fills the screen, its message and compose windows floating inside it
    /// and its status bar holding the minimised ones as tabs.
    private var fillsScreen: Bool {
        snapshotFillsScreen || (ownWindow != nil && ownWindow == fullScreenMailbox)
    }

    var body: some View {
        VStack(spacing: 0) {
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
                WindowTrayBar(holdsWindows: !fillsScreen)
            }
            // Filling the screen, opened messages and messages being written are drawn in here,
            // over the mailbox and above the status bar, as Outlook's are.
            .overlay { if fillsScreen { DeskLayer() } }
            StatusBar(fillsScreen: fillsScreen)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background { if style.glass { GlassWindowBackground().ignoresSafeArea() } else { OLColor.reading } }
        .background(MailboxWindowAccessor { ownWindow = ObjectIdentifier($0) })
        .onReceive(WindowTray.shared.$fullScreenMailbox) { fullScreenMailbox = $0 }
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
                    .padding(style.glass ? FalconStyle.paneGap : 0)
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
                // Each reader is made afresh for each row chosen, named by the row and by what it
                // shows, so that nothing of the one before, its text or its web view, stays on
                // screen: a conversation's row and one of its message lines are different rows.
                let row = model.selectedMessageIDs.count == 1 ? model.selectedMessageIDs.first ?? "" : ""
                if let placeholder = model.engineList.readingPlaceholder {
                    // Rows just selected in the table: shown at once by what their rows say,
                    // their messages filling in once read, whatever an earlier read still does.
                    ReadingPlaceholderView(placeholder: placeholder, selectedCount: selectedCount) {
                        model.engineList.retryRead()
                    }
                } else if let thread = model.currentThread, thread.messages.count > 1 {
                    // A conversation's own row: all its messages, one under another.
                    ConversationStackView(messages: thread.messages)
                        .id("stack|\(row)|\(thread.id)")
                } else if let thread = model.currentThread {
                    MessageReaderView(message: thread.latest, conversation: model.currentConversation)
                        .id("reader|\(row)|\(thread.latest.id)")
                } else if selectedCount > 1 {
                    ContentUnavailableView("\(ListStatusText.number(selectedCount)) conversations selected", systemImage: "envelope.badge")
                } else {
                    ContentUnavailableView("No message selected", systemImage: "envelope.open")
                }
            }
        }
    }

    /// How many rows are selected: in the table, however many, above 1,000 too.
    private var selectedCount: Int {
        model.engineList.isShown ? model.engineList.selectionCount : model.selectedMessageIDs.count
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
    /// While the mailbox window fills the screen the bar is Outlook's taller grey one, with a tab
    /// in the middle for each message or compose window minimised.
    var fillsScreen = false
    /// The table, while it shows the list: Items is then every message of the view, not the rows
    /// loaded, and "up to date" waits until every folder shown has been listed in full.
    private var list: ListController? { model.engineList.isShown ? model.engineList.controller : nil }

    /// Outlook's wording for a quiet mailbox, and its "Connected to:" tail. Nothing is claimed
    /// to be up to date while an account cannot sync; what stops it is shown on its own.
    private var stateText: String? {
        guard model.statusText == "Up to date" || model.statusText == "Ready" else {
            // An account's pause is said once, beside Items, not again here.
            return pausedNotices.contains { $0.text == model.statusText } ? nil : model.statusText
        }
        if let list { return list.stateText(everyAccountReachable: model.everyAccountReachable) }
        if !model.gmailEngineAccounts.isEmpty, !model.engineList.everyFolderListed { return nil }
        return model.everyAccountReachable ? ListStatusText.upToDate : nil
    }

    /// While a Google account on the Gmail API lists its mailbox, how far it has got, in the words
    /// its engine gave: "Syncing {email}: 12,000 of 55,000 messages".
    private var listingProgress: String? {
        let text = model.statusText
        guard text.hasPrefix("Syncing ") else { return nil }
        let listing = model.accounts.contains { account in
            model.syncingAccounts.contains(account.id) && model.usesGmailEngine(account.id) && text.hasPrefix("Syncing \(account.email):")
        }
        return listing ? text : nil
    }

    /// Accounts whose server asked FalconMail to wait, or that are stopped until the owner acts, with
    /// the sentence to show: Gmail's pause of a Google account on the Gmail API among them. A pause
    /// is not a failure, so it plays no sound and leaves the account connected.
    private var pausedNotices: [(account: AccountInfo, text: String)] {
        model.accounts.compactMap { account in
            guard account.isEnabled else { return nil }
            let problem = model.accountStatus.problems[account.id]
            switch model.accountStatus.health[account.id] {
            case .imapPaused?, .blocked?:
                return problem.map { (account, $0) }
            case .apiPaused?:
                return (account, problem ?? "Waiting a moment before loading more of \(account.email)'s messages.")
            default:
                return nil
            }
        }
    }

    @ViewBuilder private var itemsLabel: some View {
        if let list {
            Text(verbatim: list.itemsText)
        } else {
            Text("Items: \(model.itemCount)")
        }
    }

    /// An account Gmail asked to wait a while is still connected: its mail on the Mac is there,
    /// and it goes on by itself.
    private var connectedText: String? {
        let online = model.accounts.filter { account in
            guard account.isEnabled else { return false }
            if let health = model.accountStatus.health[account.id] { return health.staysConnected }
            return model.online[account.id] != false
        }.map(\.email)
        return online.isEmpty ? nil : "Connected to: " + online.joined(separator: ", ")
    }

    var body: some View {
        if fillsScreen { fullScreenBody } else { windowBody }
    }

    private var windowBody: some View {
        HStack(spacing: 12) {
            itemCount.padding(.leading, OL.statusLeftX)
            notices
            Spacer()
            capsules
            state
            if let connectedText {
                Text(connectedText).font(.system(size: OL.statusFont)).foregroundStyle(OLColor.text).lineLimit(1)
            }
        }
        .padding(.trailing, OL.statusRightInset)
        .frame(height: OL.status)
        .background(OLColor.status)
        .overlay(alignment: .top) { Rectangle().fill(OLColor.chromeLine).frame(height: 1) }
    }

    /// Outlook's: the item count on the left, the tabs in the middle and the state of the
    /// folders on the right, each side keeping room enough that the tabs stand in the middle.
    private var fullScreenBody: some View {
        HStack(spacing: 0) {
            HStack(spacing: 12) {
                itemCount.fixedSize()
                notices
            }
            .padding(.leading, OL.fullScreenStatusLeftX)
            .frame(minWidth: FullScreenLayout.tabSideRoom, alignment: .leading)
            FullScreenTabStrip()
                .frame(maxWidth: .infinity)
            HStack(spacing: 12) {
                capsules
                state
            }
            .padding(.trailing, OL.fullScreenStatusRightInset)
            .frame(minWidth: FullScreenLayout.tabSideRoom, alignment: .trailing)
        }
        .frame(height: OL.fullScreenStatus)
        .background(OLColor.fullScreenStatus)
        .overlay(alignment: .top) { Rectangle().fill(OLColor.chromeLine).frame(height: 1) }
    }

    private var itemCount: some View {
        itemsLabel
            .font(.system(size: OL.statusFont).monospacedDigit())
            .foregroundStyle(OLColor.text)
    }

    @ViewBuilder private var capsules: some View {
        chordCapsule
        actionErrorCapsule
        undoCapsule
        discardCapsule
        sendingCapsules
    }

    @ViewBuilder private var state: some View {
        if let summary = listingProgress ?? list?.syncProgress?.text ?? model.syncingSummary {
            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
            Text(summary).font(.system(size: OL.statusFont)).foregroundStyle(OLColor.text).lineLimit(1)
        } else if let stateText {
            Text(stateText).font(.system(size: OL.statusFont)).foregroundStyle(OLColor.text).lineLimit(1)
        }
    }

    @ViewBuilder private var notices: some View {
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
        ForEach(pausedNotices, id: \.account.id) { notice in
            Text(notice.text)
                .font(.caption).foregroundStyle(Color.orange).lineLimit(1).truncationMode(.middle)
                .help(notice.text)
        }
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
                Text("Sending “\(item.subject.isEmpty ? "(no subject)" : item.subject)” · \(item.recipientSummary)")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.recipientSummary)
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

/// The reading pane for rows just selected in the table while their messages are read: the
/// sender, subject, date and preview their row already shows, a spinner while the message is
/// read, and, once the read has taken more than ten seconds, a line saying so with Try Again.
struct ReadingPlaceholderView: View {
    let placeholder: ListReadingPlaceholder
    let selectedCount: Int
    let retry: () -> Void

    var body: some View {
        if placeholder.targets.count > 1 {
            ContentUnavailableView("\(ListStatusText.number(max(selectedCount, placeholder.targets.count))) conversations selected",
                                   systemImage: "envelope.badge")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text(placeholder.subject.isEmpty ? " " : placeholder.subject)
                    .font(.system(size: 22))
                    .foregroundStyle(OLColor.text)
                    .lineLimit(2)
                if let from = placeholder.from {
                    HStack(alignment: .top, spacing: 12) {
                        AvatarView(name: from.displayName, address: from.address, size: OL.readingAvatar)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(from.name.isEmpty ? from.address : "\(from.name) <\(from.address)>")
                                .font(.system(size: OL.readingSenderFont, weight: .semibold))
                                .foregroundStyle(OLColor.text)
                                .lineLimit(1)
                            if let date = placeholder.date {
                                Text(date.formatted(date: .complete, time: .shortened))
                                    .font(.system(size: OL.readingSenderFont))
                                    .foregroundStyle(OLColor.textMuted)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                if placeholder.timedOut {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.circle")
                        Text("This message is taking longer than usual to open.")
                        Button("Try Again", action: retry).buttonStyle(.link)
                    }
                    .font(.system(size: OL.statusFont))
                    .foregroundStyle(OLColor.textMuted)
                } else {
                    ProgressView().controlSize(.small)
                }
                if !placeholder.snippet.isEmpty {
                    Text(placeholder.snippet).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(OLColor.reading)
        }
    }
}
