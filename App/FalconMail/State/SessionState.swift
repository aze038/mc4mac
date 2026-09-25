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
