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

    /// Opens `draft` to be written, in a window of its own or a tab as the owner chose.
    /// `origin` says whether anything else holds it as it opens, which decides whether closing
    /// it unchanged keeps it.
    func openCompose(_ draft: ComposeDraft, origin: UnsentMessage.Origin) {
        var draft = draft
        draft.markOpened(as: origin)
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
        if case .compose(let id) = tab { closeUnsent(id) }
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
        if let t = activeTab { closeTab(t) }
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

    /// Closing a message not yet sent, however it closes: the close button, Command-W, the
    /// tray's close button, or the next launch after a quit. Nothing is asked. What was written
    /// goes to the Drafts folder, on the server as well as here; a message with nothing in it,
    /// or as it was opened, closes and nothing of it is kept. A message only this window holds,
    /// as one called back from the Outbox, is always kept.
    func closeUnsent(_ id: UUID) {
        guard let draft = drafts[id] else { return }
        switch draft.closing {
        case .closeQuietly: drafts[id] = nil
        case .saveToDrafts: saveDraftToServer(id)
        }
    }

    /// Discard, from the compose ribbon, the Message menu or a tab's bar: the message closes
    /// and its copies go, the one kept on this Mac for the next launch and the one in Drafts it
    /// was reopened from, while other drafts stay. It is held in memory for as long as the
    /// mailbox window offers to bring it back. `closesWindow` is false when the compose view
    /// closes itself.
    func discardCompose(_ id: UUID, closesWindow: Bool = true) {
        guard let draft = drafts[id] else { return }
        drafts[id] = nil
        Task { await purgeStoredDraft(draft) }
        // Its copy in Drafts is going, so one brought back is the only copy there is.
        var kept = draft
        kept.sourceMessage = nil
        kept.sourceMessageID = nil
        let held = discarded.discard(kept, now: Date())
        discardExpiry?.cancel()
        discardExpiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(DiscardedMessage<ComposeDraft>.undoWindow * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.discarded.letGo(held.id)
        }
        if (tabs + minimizedTabs).contains(.compose(id)) { closeTab(.compose(id)) }
        if closesWindow { WindowTray.shared.close(.compose(id)) }
    }

    /// Undo on the banner: the message discarded last opens again as it was.
    func undoDiscard() {
        discardExpiry?.cancel()
        discardExpiry = nil
        guard let draft = discarded.undo(at: Date()) else { return }
        openCompose(draft, origin: .undoneDiscard)
    }

    /// Discard Draft in the Message menu, for the message being written in front: in its own
    /// window, or in the tab showing in the mailbox window.
    var frontDraftID: UUID? {
        switch frontWindow {
        case .popup(.compose(let id)): return id
        case .mailbox:
            if case .compose(let id)? = activeTab { return id }
            return nil
        default: return nil
        }
    }

    func discardFrontDraft() {
        if let id = frontDraftID { discardCompose(id) }
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
                Button { model.closeTab(tab) } label: { Image(systemName: "xmark").font(.caption2) }
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
