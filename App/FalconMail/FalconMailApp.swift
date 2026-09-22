import SwiftUI
import AppKit
import UserNotifications
import FalconCore

@main
struct FalconMailApp: App {
    static let mailboxWindowID = "mailbox"

    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("FalconMail", id: FalconMailApp.mailboxWindowID) {
            MainWindow()
                .themedRoot()
                .environment(model)
                .environmentObject(model.updates)
                .task {
                    await model.bootstrap()
                    for id in model.windowsToRestore { openWindow(value: id) }
                }
                .onAppear {
                    model.openMainWindow = { openWindow(id: FalconMailApp.mailboxWindowID) }
                    model.openComposeWindow = { openWindow(value: $0) }
                    appDelegate.model = model
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
        .defaultSize(width: 917, height: 1006)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView().themedRoot().environment(model).environmentObject(model.updates)
        }
    }

    @ViewBuilder private var replyCommands: some View {
        Button("Reply") { model.replyToSelection(all: false) }.keyboardShortcut("r", modifiers: .command)
        Button("Reply All") { model.replyToSelection(all: true) }.keyboardShortcut("r", modifiers: [.command, .shift])
        Button("Forward") { model.forwardSelection() }.keyboardShortcut("f", modifiers: [.command, .shift])
    }

    @ViewBuilder private var windowCommands: some View {
        Button("Open") { openSelectedInTab() }.keyboardShortcut("o", modifiers: .command)
        Button("Open in Separate Window") { openSelectedInWindow() }.keyboardShortcut("o", modifiers: [.command, .shift])
        Button("Close Tab") { model.closeActiveTab() }.keyboardShortcut("w", modifiers: .command).disabled(model.activeTab == nil)
        if let tab = model.activeTab {
            Button("Minimize Tab") { model.minimizeTab(tab) }.keyboardShortcut("m", modifiers: .command)
        }
    }

    @ViewBuilder private var fileCommands: some View {
        Button("Archive") { model.archive(model.selectedMessages) }.keyboardShortcut("e", modifiers: .command)
        Button("Delete") { model.delete(model.selectedMessages) }.keyboardShortcut(.delete, modifiers: .command)
        Button("Move to Folder…") { model.openMovePalette() }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(model.selectedMessageIDs.isEmpty)
        Button(moveAgainTitle) { model.moveToLastTarget() }
            .keyboardShortcut("y", modifiers: [.command, .shift])
            .disabled(model.lastMoveTarget == nil || model.selectedMessageIDs.isEmpty)
        Button("Move to Junk") { model.moveToJunk(model.selectedMessages) }
            .disabled(model.selectedMessageIDs.isEmpty)
        Button("Not Junk") { model.markNotJunk(model.selectedMessages) }
            .disabled(!model.selectionIsAllInJunk)
    }

    @ViewBuilder private var readStateCommands: some View {
        Button("Mark as Read") { model.markRead(model.selectedMessages, true) }.keyboardShortcut("u", modifiers: [.command, .shift])
        Button("Mark as Unread") { model.markRead(model.selectedMessages, false) }.keyboardShortcut("u", modifiers: [.command, .option])
        Button("Mark All as Read") { model.markAllReadInSelection() }
            .disabled(!model.canMarkAllRead)
            .help("Marks every unread message in the selected mailbox as read.")
        Button(flagTitle) { model.toggleFlagOnSelection() }.keyboardShortcut("l", modifiers: [.command, .shift])
        Button("Mute Conversation") { model.muteSelection() }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(model.selectedMessageIDs.isEmpty)
            .help("Outlook calls this Ignore. New replies are marked read and archived as they arrive.")
    }

    @ViewBuilder private var navigationCommands: some View {
        Button("Next Conversation") { model.selectNextThread() }
        Button("Previous Conversation") { model.selectPreviousThread() }
        Button("Next Unread Message") { model.selectNextUnread() }.keyboardShortcut("n", modifiers: [.command, .control])
        Button("Previous Unread Message") { model.selectPreviousUnread() }.keyboardShortcut("p", modifiers: [.command, .control])
    }

    @ViewBuilder private var syncCommands: some View {
        Button("Check for New Mail") { model.syncNow() }.keyboardShortcut("n", modifiers: [.command, .shift])
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
        model.firstSelectedMessage?.isFlagged == true ? "Unflag" : "Flag"
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

    private func openSelectedInTab() {
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
        didSet { MainActor.assumeIsolated { deliverQueuedActions() } }
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
            let failure = NSAlert()
            failure.messageText = "Could not move FalconMail"
            failure.informativeText = error.localizedDescription
            failure.runModal()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

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
