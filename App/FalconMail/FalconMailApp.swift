import SwiftUI
import AppKit
import UserNotifications
import FalconCore

@main
struct FalconMailApp: App {
    static let mailboxWindowID = "mailbox"

    @State private var model: AppModel
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    init() {
        #if DEBUG
        ComposeSnapshot.runIfRequested()
        #endif
        // Before the model, so that what it finds as it loads, such as a message held in the
        // Outbox or a file set aside, reaches diagnostics.
        DiagnosticsService.shared.start()
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup("FalconMail", id: FalconMailApp.mailboxWindowID) {
            MainWindow()
                .themedRoot()
                .environment(model)
                .environmentObject(model.updates)
                .task {
                    await model.bootstrap()
                    let restored = model.messageWindowsToRestore
                    for id in restored.open { openWindow(value: id) }
                    await model.shelveMessageWindows(restored.tray)
                    #if DEBUG
                    if ComposeRibbonDemo.isRequested { openWindow(value: ComposeRibbonDemo.draft(in: model)) }
                    #endif
                }
                .onAppear {
                    model.openMainWindow = { openWindow(id: FalconMailApp.mailboxWindowID) }
                    model.openComposeWindow = { openWindow(value: $0) }
                    WindowTray.shared.openWindow = { key in
                        switch key {
                        case .message(let id): openWindow(value: id)
                        case .compose(let id): openWindow(value: id)
                        }
                    }
                    WindowTray.shared.frontChanged = { model.frontWindow = $0 }
                    appDelegate.model = model
                    SettingsWindows.shared.model = model
                    SettingsWindows.shared.updates = model.updates
                    AppAppearance.apply(model.appearance)
                }
                .onOpenURL { url in
                    if url.scheme?.lowercased() == "mailto" {
                        model.composeFromMailto(url)
                        return
                    }
                    Task { _ = await URLCallbackRouter.shared.deliver(url) }
                }
                .onChange(of: model.appearance) { _, new in AppAppearance.apply(new) }
        }
        .defaultSize(width: 1728, height: 1084)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Message") { model.composeNew() }
                    .keyboardShortcut("n", modifiers: .command)
                // As Outlook's File menu has it: the selected message, in a window of its own
                // unless Settings → Reading says tabs.
                Button("Open") { openSelected() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(model.currentThread == nil)
                Divider()
                Button("Add Account…") { NotificationCenter.default.post(name: .falconAddAccount, object: nil) }
                Divider()
                Button("Import Mail…") { NotificationCenter.default.post(name: .falconImport, object: nil) }
                Button("Export Selected as .eml…") { NotificationCenter.default.post(name: .falconExport, object: nil) }
            }
            CommandGroup(replacing: .undoRedo) {
                Button(undoTitle) { undo() }.keyboardShortcut("z", modifiers: .command)
                Button("Redo") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("Message") {
                replyCommands
                windowCommands
                Divider()
                fileCommands
                Divider()
                readStateCommands
                Divider()
                navigationCommands
                Divider()
                syncCommands
            }
            CommandGroup(after: .sidebar) {
                Divider()
                Button("Search Mail") { model.focusSearch() }.keyboardShortcut("f", modifiers: .command)
                Menu("Go To") {
                    Button("All Inboxes") { model.jumpToAllInboxes() }
                    Button("Sent") { model.jump(to: .sent) }
                    Button("Drafts") { model.jump(to: .drafts) }
                    Button("Archive") { model.jump(to: .archive) }
                    Button("Junk") { model.jump(to: .junk) }
                    Button("Trash") { model.jump(to: .trash) }
                }
                Divider()
                filterCommands
                Toggle("Group by Conversation", isOn: $model.groupByThread)
                Divider()
                Button("Expand All Conversations") { model.expandAll() }.disabled(!model.hasExpandableThreads)
                Button("Collapse All Conversations") { model.collapseAll() }.disabled(!model.canCollapseSomething)
                Divider()
                Button("Mail") { model.showModule(.mail) }.keyboardShortcut("1", modifiers: .command)
                Button("Calendar") { model.showModule(.calendar) }.keyboardShortcut("2", modifiers: .command)
                Button("People") { model.showModule(.people) }.keyboardShortcut("3", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await model.updates.check(userInitiated: true) } }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { SettingsWindows.shared.show() }.keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Archive") {
                Button("Archive Mail to Cloud…") { NotificationCenter.default.post(name: .falconArchive, object: nil) }
                Button("Export Folder to Local Archive…") { NotificationCenter.default.post(name: .falconExportArchive, object: nil) }
                Button("Open Archive from Google Drive…") { NotificationCenter.default.post(name: .falconOpenArchive, object: nil) }
            }
        }

        WindowGroup("Message", for: String.self) { $messageID in
            if let id = messageID {
                MessageWindowView(messageID: id).themedRoot().environment(model).environmentObject(model.updates)
            }
        }
        .defaultSize(width: 917, height: 1006)
        .windowStyle(.hiddenTitleBar)

        WindowGroup("Compose", for: UUID.self) { $draftID in
            if let id = draftID {
                ComposeView(draftID: id).themedRoot().environment(model).environmentObject(model.updates)
            }
        }
        .defaultSize(width: OL.composeWindowWidth, height: OL.composeWindowHeight)
        .windowStyle(.hiddenTitleBar)
    }

    @ViewBuilder private var replyCommands: some View {
        // Every command in this menu acts on the window in front: a message window's own message,
        // nothing while a message is being written, else the selection.
        Button("Reply") { model.menuReply(all: false) }.keyboardShortcut("r", modifiers: .command)
            .disabled(model.menuTarget == .nothing)
        Button("Reply All") { model.menuReply(all: true) }.keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.menuTarget == .nothing)
        Button("Forward") { model.menuForward() }.keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(model.menuTarget == .nothing)
    }

    @ViewBuilder private var windowCommands: some View {
        Button("Open in Separate Window") { openSelectedInWindow() }.keyboardShortcut("o", modifiers: [.command, .shift])
        // Command-W and Command-M act on the window in front: a message or compose window of its
        // own closes, or goes into the tray through Minimize in the Window menu, and only in the
        // mailbox window do they close or minimise the tab showing there.
        Button(model.frontWindow.popup == nil ? "Close Tab" : "Close Window") { model.closeFront() }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(!model.canCloseFront)
        if model.frontWindow == .mailbox, let tab = model.activeTab {
            Button("Minimize Tab") { model.minimizeTab(tab) }.keyboardShortcut("m", modifiers: .command)
        }
        // No shortcut: Command-Delete is Delete, and in the message's text it deletes to the
        // start of the line.
        Button("Discard Draft") { model.discardFrontDraft() }
            .disabled(model.frontDraftID == nil)
            .help("Closes the message being written and deletes its draft. Undo brings it back for ten seconds.")
    }

    @ViewBuilder private var fileCommands: some View {
        Button("Archive") { model.menuMoves { model.archive($0) } }.keyboardShortcut("e", modifiers: .command)
            .disabled(model.menuCannotChange)
        // Disabled while a message is being written, so that Command-Delete there deletes text.
        Button("Delete") { model.menuMoves { model.delete($0) } }.keyboardShortcut(.delete, modifiers: .command)
            .disabled(model.menuCannotChange)
        Button("Move to Folder…") { model.menuMove() }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(model.menuCannotChange)
        Button(moveAgainTitle) { model.menuMoveAgain() }
            .keyboardShortcut("y", modifiers: [.command, .shift])
            .disabled(model.lastMoveTarget == nil || model.menuCannotChange)
        Button("Move to Junk") { model.menuMoves { model.moveToJunk($0) } }
            .disabled(model.menuCannotChange)
        Button("Not Junk") { model.menuMoves { model.markNotJunk($0) } }
            .disabled(model.menuCannotChange || !model.isInJunk(model.menuMessages))
    }

    @ViewBuilder private var readStateCommands: some View {
        Button("Mark as Read") { model.markRead(model.menuMessages, true) }.keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(model.menuCannotChange)
        Button("Mark as Unread") { model.markRead(model.menuMessages, false) }.keyboardShortcut("u", modifiers: [.command, .option])
            .disabled(model.menuCannotChange)
        Button("Mark All as Read") { model.markAllReadInSelection() }
            .disabled(!model.canMarkAllRead)
            .help("Marks every unread message in the selected mailbox as read.")
        Button(flagTitle) { model.menuToggleFlag() }.keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(model.menuCannotChange)
        Button("Mute Conversation") { model.menuMute() }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(model.menuCannotChange)
            .help("Outlook calls this Ignore. New replies are marked read and archived as they arrive.")
    }

    @ViewBuilder private var navigationCommands: some View {
        Button("Next Conversation") { model.selectNextThread() }
        Button("Previous Conversation") { model.selectPreviousThread() }
        Button("Next Unread Message") { model.selectNextUnread() }.keyboardShortcut("n", modifiers: [.command, .control])
        Button("Previous Unread Message") { model.selectPreviousUnread() }.keyboardShortcut("p", modifiers: [.command, .control])
    }

    @ViewBuilder private var syncCommands: some View {
        Button("Check for New Mail") { model.checkForNewMail() }.keyboardShortcut("n", modifiers: [.command, .shift])
        Button("Load Older Messages") { model.loadOlder() }
    }

    @ViewBuilder private var filterCommands: some View {
        Toggle("Only Unread", isOn: filterBinding(.unread))
            .keyboardShortcut("1", modifiers: [.command, .control])
        Toggle("Only Flagged", isOn: filterBinding(.flagged))
            .keyboardShortcut("2", modifiers: [.command, .control])
        Button("Clear Filters") { model.clearFilters() }
            .keyboardShortcut("0", modifiers: [.command, .control])
            .disabled(model.filters.isEmpty)
        Toggle("Keep Filters When Switching Folders", isOn: $model.pinFilters)
    }

    private func filterBinding(_ filter: MessageFilter) -> Binding<Bool> {
        Binding(get: { model.filters.contains(filter) }, set: { _ in model.toggleFilter(filter) })
    }

    private var moveAgainTitle: String {
        guard let target = model.lastMoveTarget else { return "Move Again" }
        return "Move Again to \(target.name)"
    }

    private var flagTitle: String {
        model.menuMessages.first?.isFlagged == true ? "Unflag" : "Flag"
    }

    private var undoTitle: String {
        guard let undo = model.pendingUndo else { return "Undo" }
        return "Undo \(undo.verbTitle)"
    }

    private func undo() {
        guard model.canUndoAction, WindowTray.shared.mailboxWindowTakesUndo else {
            NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
            return
        }
        model.undoLastAction()
    }

    private func openSelected() {
        guard let thread = model.currentThread else { return }
        model.openMessage(thread.latest) { openWindow(value: $0) }
    }

    private func openSelectedInWindow() {
        guard let thread = model.currentThread else { return }
        model.openMessage(thread.latest, forceWindow: true) { openWindow(value: $0) }
    }
}

struct QueuedNotificationAction {
    let action: MailNotificationAction
    let messageID: String
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        if let hidden = sender.windows.first(where: { $0.isMiniaturized }) {
            hidden.deminiaturize(nil)
            hidden.makeKeyAndOrderFront(nil)
            return false
        }
        return true
    }

    var model: AppModel? {
        didSet {
            MainActor.assumeIsolated {
                if let model { DiagnosticsService.shared.attach(model) }
                deliverQueuedActions()
            }
        }
    }

    private var queuedActions: [QueuedNotificationAction] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        WindowTray.installMinimizeHook()
        #if DEBUG
        MainActor.assumeIsolated { RecipientDemo.startIfRequested() }
        #endif
        offerMoveToApplications()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let messageID = response.notification.request.content.userInfo["messageID"] as? String ?? ""
        let identifier = response.actionIdentifier
        MainActor.assumeIsolated {
            guard let action = MailNotificationCategory.action(for: identifier) else { return }
            deliver(QueuedNotificationAction(action: action, messageID: messageID))
        }
        completionHandler()
    }

    @MainActor private func deliver(_ queued: QueuedNotificationAction) {
        guard let model else {
            queuedActions.append(queued)
            return
        }
        model.handleNotificationAction(queued.action, messageID: queued.messageID)
    }

    @MainActor private func deliverQueuedActions() {
        guard let model, !queuedActions.isEmpty else { return }
        let pending = queuedActions
        queuedActions = []
        for queued in pending { model.handleNotificationAction(queued.action, messageID: queued.messageID) }
    }

    private func offerMoveToApplications() {
        #if DEBUG
        guard !RecipientDemo.isRequested else { return }
        #endif
        let current = Bundle.main.bundleURL
        guard !UpdateInstaller.isInApplicationsFolder(current) || UpdateInstaller.isTranslocated(current) else { return }
        guard !UserDefaults.standard.bool(forKey: "declinedMoveToApplications") else { return }
        let target = UpdateInstaller.preferredInstallLocation()
        let alert = NSAlert()
        alert.messageText = "Move FalconMail to the Applications folder?"
        alert.informativeText = "FalconMail is running from \(UpdateInstaller.isTranslocated(current) ? "a temporary read-only location" : current.deletingLastPathComponent().path). Moving it to \(target.deletingLastPathComponent().path) lets it update itself and keeps it in Launchpad."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            UserDefaults.standard.set(true, forKey: "declinedMoveToApplications")
            return
        }
        do {
            let installed = try UpdateInstaller.moveToApplications(from: current)
            UpdateInstaller.relaunch(installed)
            NSApp.terminate(nil)
        } catch {
            Log.error("Install", "Moving FalconMail to Applications failed: \(error.localizedDescription)", error: error)
            let failure = NSAlert()
            failure.messageText = "Could not move FalconMail"
            failure.informativeText = error.localizedDescription
            failure.runModal()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { DiagnosticsService.shared.endSession() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task { @MainActor in
            let shutdown = Task { await model.shutdown() }
            let timeout = Task { _ = try? await Task.sleep(nanoseconds: 3_000_000_000) }
            _ = await Task.select(shutdown, timeout)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

extension Task where Success == Void, Failure == Never {
    static func select(_ a: Task<Void, Never>, _ b: Task<Void, Never>) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await a.value }
            group.addTask { await b.value }
            await group.next()
            group.cancelAll()
        }
    }
}

extension Notification.Name {
    static let falconAddAccount = Notification.Name("falcon.addAccount")
    static let falconNewMeeting = Notification.Name("falcon.newMeeting")
    static let falconImport = Notification.Name("falcon.import")
    static let falconExport = Notification.Name("falcon.export")
    static let falconArchive = Notification.Name("falcon.archive")
    static let falconExportArchive = Notification.Name("falcon.exportArchive")
    static let falconOpenArchive = Notification.Name("falcon.openArchive")
}
