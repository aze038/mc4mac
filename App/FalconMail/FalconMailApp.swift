import SwiftUI
import FalconCore

@main
struct FalconMailApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("FalconMail") {
            MainWindow()
                .environmentObject(model)
                .environmentObject(model.updates)
                .task {
                    await model.bootstrap()
                    let restore = model.windowsToRestore
                    for id in restore.messages { openWindow(value: id) }
                    for id in restore.drafts { openWindow(value: id) }
                }
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Message") { compose() }
                    .keyboardShortcut("n", modifiers: .command)
                Divider()
                Button("Import Mail…") { NotificationCenter.default.post(name: .falconImport, object: nil) }
                Button("Export Selected as .eml…") { NotificationCenter.default.post(name: .falconExport, object: nil) }
            }
            CommandMenu("Message") {
                Button("Reply") { reply(all: false) }.keyboardShortcut("r", modifiers: .command)
                Button("Reply All") { reply(all: true) }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Forward") { forward() }.keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Open in New Window") { openSelectedInWindow() }.keyboardShortcut("o", modifiers: .command)
                Divider()
                Button("Archive") { model.archive(model.selectedMessages) }.keyboardShortcut("e", modifiers: .command)
                Button("Delete") { model.delete(model.selectedMessages) }.keyboardShortcut(.delete, modifiers: .command)
                Button("Mark as Read") { model.markRead(model.selectedMessages, true) }.keyboardShortcut("u", modifiers: [.command, .shift])
                Button("Mark as Unread") { model.markRead(model.selectedMessages, false) }.keyboardShortcut("u", modifiers: [.command, .option])
                Button("Flag") { model.setFlagged(model.selectedMessages, true) }.keyboardShortcut("l", modifiers: [.command, .shift])
                Divider()
                Button("Check for New Mail") { model.syncNow() }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Load Older Messages") { model.loadOlder() }
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
                MessageWindowView(messageID: id).environmentObject(model).environmentObject(model.updates)
            }
        }
        .defaultSize(width: 720, height: 640)

        WindowGroup("Compose", for: UUID.self) { $draftID in
            if let id = draftID {
                ComposeView(draftID: id).environmentObject(model).environmentObject(model.updates)
            }
        }
        .defaultSize(width: 720, height: 600)

        Settings {
            SettingsView().environmentObject(model).environmentObject(model.updates)
        }
    }

    private func compose() {
        guard let account = model.accounts.first else { return }
        openWindow(value: model.newDraft(.blank(account: account)))
    }

    private func reply(all: Bool) {
        guard let thread = model.currentThread, let account = model.account(for: thread.latest) else { return }
        Task {
            let parsed = await model.parsedBody(for: thread.latest)
            openWindow(value: model.newDraft(.reply(to: thread.latest, parsed: parsed, account: account, all: all)))
        }
    }

    private func forward() {
        guard let thread = model.currentThread, let account = model.account(for: thread.latest) else { return }
        Task {
            let parsed = await model.parsedBody(for: thread.latest)
            openWindow(value: model.newDraft(.forward(thread.latest, parsed: parsed, account: account)))
        }
    }

    private func openSelectedInWindow() {
        guard let thread = model.currentThread else { return }
        openWindow(value: thread.latest.id)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task { @MainActor in
            await model.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

extension Notification.Name {
    static let falconImport = Notification.Name("falcon.import")
    static let falconExport = Notification.Name("falcon.export")
    static let falconArchive = Notification.Name("falcon.archive")
    static let falconExportArchive = Notification.Name("falcon.exportArchive")
    static let falconOpenArchive = Notification.Name("falcon.openArchive")
}
