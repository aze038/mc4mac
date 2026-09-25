import SwiftUI
import AppKit
import FalconCore

enum WorkspaceTab: Hashable, Codable, Identifiable {
    case message(String)
    case compose(UUID)

    var id: String {
        switch self {
        case .message(let id): return "m:" + id
        case .compose(let id): return "c:" + id.uuidString
        }
    }
}

extension AppModel {
    func openMessageTab(_ message: MessageSummary) {
        tabTitles[WorkspaceTab.message(message.id).id] = message.subject.isEmpty ? "(no subject)" : message.subject
        openTab(.message(message.id))
    }

    /// Opens `draft` to be written. `onlyCopy` says nothing else holds what it says, as with a
    /// send called back from the Outbox, so closing it always asks before dropping it.
    func openCompose(_ draft: ComposeDraft, onlyCopy: Bool = false) {
        var draft = draft
        if !onlyCopy { draft.markOpened() }
        let id = newDraft(draft)
        if Preferences.bool(Pref.composeInWindow, default: true), let open = openComposeWindow {
            open(id)
        } else {
            openTab(.compose(id))
        }
    }

    func openTab(_ tab: WorkspaceTab) {
        minimizedTabs.removeAll { $0 == tab }
        if !tabs.contains(tab) { tabs.append(tab) }
        activeTab = tab
        saveSession()
    }

    func closeTab(_ tab: WorkspaceTab) {
        tabs.removeAll { $0 == tab }
        minimizedTabs.removeAll { $0 == tab }
        if activeTab == tab { activeTab = tabs.last }
        if case .compose(let id) = tab { saveDraftToServer(id) }
        saveSession()
    }

    func minimizeTab(_ tab: WorkspaceTab) {
        tabs.removeAll { $0 == tab }
        if !minimizedTabs.contains(tab) { minimizedTabs.append(tab) }
        if activeTab == tab { activeTab = nil }
        saveSession()
    }

    func showMail() {
        activeTab = nil
        saveSession()
    }

    func closeActiveTab() {
        if let t = activeTab { closeTabAsked(t) }
    }

    /// Whether Command-W has something to close: the message or compose window in front, or the
    /// tab showing in the mailbox window in front.
    var canCloseFront: Bool {
        switch frontWindow {
        case .popup: return true
        case .mailbox: return activeTab != nil
        case .other: return false
        }
    }

    /// Command-W. A window in front that is not FalconMail's own, as Settings is, closes the way
    /// every window does, through the File menu.
    func closeFront() {
        switch frontWindow {
        case .popup(let key): WindowTray.shared.performClose(key)
        case .mailbox: closeActiveTab()
        case .other: break
        }
    }

    /// Closes `tab` as the user asked to: a message not yet sent closes as Outlook closes one,
    /// with its alert over the mailbox window when there is something to lose.
    func closeTabAsked(_ tab: WorkspaceTab) {
        guard case .compose(let id) = tab else { return closeTab(tab) }
        if mayCloseUnsent(id, over: WindowTray.shared.frontMailboxWindow, close: { [weak self] in self?.closeTab(tab) }) {
            closeTab(tab)
        }
    }

    /// Whether the compose window or tab holding draft `id` may close now. A message as it was
    /// opened, or with nothing in it, closes at once and nothing of it is kept. Otherwise
    /// Outlook's alert goes up over `window` and this says no. `close` runs once the answer has
    /// kept the draft or dropped it, and closing saves whatever is still held to the Drafts
    /// folder as it always has; Continue Writing leaves the message open.
    func mayCloseUnsent(_ id: UUID, over window: NSWindow?, close: @escaping @MainActor () -> Void) -> Bool {
        guard let draft = drafts[id] else { return true }
        switch UnsentMessage.closing(untouched: draft.isUntouched, blank: draft.isBlank) {
        case .discardQuietly:
            drafts[id] = nil
            return true
        case .ask:
            UnsentMessageAlert.ask(over: window) { [weak self] choice in
                guard choice.closes else { return }
                if !choice.keepsDraft { self?.drafts[id] = nil }
                close()
            }
            return false
        }
    }

    func title(for tab: WorkspaceTab) -> String {
        switch tab {
        case .message(let id):
            return tabTitles[tab.id] ?? messages.first { $0.id == id }?.subject ?? "Message"
        case .compose(let id):
            let subject = drafts[id]?.subject ?? ""
            return subject.isEmpty ? "New Message" : subject
        }
    }

    func icon(for tab: WorkspaceTab) -> String {
        switch tab {
        case .message: return "envelope.open"
        case .compose: return "square.and.pencil"
        }
    }

    func restoreTabs(_ open: [WorkspaceTab], minimized: [WorkspaceTab], active: WorkspaceTab?) async {
        var kept: [WorkspaceTab] = []
        for t in open + minimized {
            switch t {
            case .compose: continue
            case .message(let id):
                if let m = try? await store.message(id: id) {
                    tabTitles[t.id] = m.subject.isEmpty ? "(no subject)" : m.subject
                    kept.append(t)
                }
            }
        }
        tabs = kept.filter { open.contains($0) }
        minimizedTabs = kept.filter { minimized.contains($0) }
        activeTab = active.flatMap { tabs.contains($0) ? $0 : nil }
    }
}

struct WorkspaceTabStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                tabChip(title: "Mail", icon: "tray.2", active: model.activeTab == nil, closable: false, tab: nil)
                ForEach(model.tabs) { tab in
                    tabChip(title: model.title(for: tab), icon: model.icon(for: tab), active: model.activeTab == tab, closable: true, tab: tab)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(.bar)
    }

    private func tabChip(title: String, icon: String, active: Bool, closable: Bool, tab: WorkspaceTab?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption)
            Text(title).font(.callout).lineLimit(1).frame(maxWidth: 240)
            if closable, let tab {
                Button { model.minimizeTab(tab) } label: { Image(systemName: "minus").font(.caption2) }
                    .buttonStyle(.plain).help("Minimize to the tray")
                Button { model.closeTabAsked(tab) } label: { Image(systemName: "xmark").font(.caption2) }
                    .buttonStyle(.plain).help("Close")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(active ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? Color.accentColor.opacity(0.5) : Color.clear))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture { if let tab { model.openTab(tab) } else { model.showMail() } }
    }
}

struct WorkspaceTabContent: View {
    @Environment(AppModel.self) private var model
    let tab: WorkspaceTab

    var body: some View {
        switch tab {
        case .message(let id):
            MessageTabView(messageID: id)
        case .compose(let id):
            ComposeView(draftID: id, embedded: true, onClose: { model.closeTab(tab) })
        }
    }
}

struct MessageTabView: View {
    @Environment(AppModel.self) private var model
    let messageID: String
    @State private var message: MessageSummary?

    var body: some View {
        Group {
            if let message {
                MessageReaderView(message: message, context: .tab, onDidAct: { model.closeTab(.message(messageID)) })
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: messageID) { message = await model.message(id: messageID) }
    }
}
