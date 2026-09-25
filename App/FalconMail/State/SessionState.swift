import Foundation
import FalconCore

struct SessionState: Codable {
    var selection: SidebarSelection?
    var selectedMessageIDs: [String] = []
    var searchText = ""
    /// Every message window open at the last quit, whether on screen or in the tray, so that an
    /// earlier build, which reads only this, opens them all.
    var openMessageWindows: [String] = []
    /// Those of them that were in the tray. Absent from sessions saved by earlier builds.
    var trayMessageWindows: [String]?
    var openDraftIDs: [UUID] = []
    var openTabs: [WorkspaceTab] = []
    var minimizedTabs: [WorkspaceTab] = []
    var activeTab: WorkspaceTab?
    var savedAt = Date()

    // The Gmail engine's own, kept apart so an earlier FalconMail never finds a Gmail row in the
    // lists it reads (§5.9, §12.2). Absent from sessions saved by earlier builds.
    /// Message windows of Google accounts on the Gmail API, by row key, with whether each was in
    /// the tray and its title.
    var gmailWindows: [GmailWindowEntry]?
    var gmailSelectedMessageIDs: [String]?
    var gmailTabs: [WorkspaceTab]?
    var gmailMinimizedTabs: [WorkspaceTab]?
    var gmailActiveTab: WorkspaceTab?
}

/// A message window of a Google account on the Gmail API, as the session keeps it.
struct GmailWindowEntry: Codable, Hashable {
    /// `"<account>:gm:<hex>"`.
    var rowKey: String
    /// The Gmail label of the folder it was opened from, which Archive and Move in it act from;
    /// nil for the Inbox.
    var contextLabel: String?
    var inTray: Bool
    var title: String?
}

struct SessionStore {
    let layout: FileLayout
    var stateURL: URL { layout.root.appendingPathComponent("session.json") }
    /// Where messages being written are kept, one `<id>.json` each, which `UnsentDrafts` looks after.
    var draftsDirectory: URL { layout.root.appendingPathComponent("Drafts", isDirectory: true) }

    func save(_ state: SessionState) {
        try? AtomicFile.writeJSON(state, to: stateURL)
    }

    func load() -> SessionState? {
        AtomicFile.readJSON(SessionState.self, from: stateURL)
    }
}
