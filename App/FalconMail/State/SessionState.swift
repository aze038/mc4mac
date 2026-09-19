import Foundation
import FalconCore

struct SessionState: Codable {
    var selection: SidebarSelection?
    var selectedMessageIDs: [String] = []
    var searchText = ""
    var openMessageWindows: [String] = []
    var openDraftIDs: [UUID] = []
    var openTabs: [WorkspaceTab] = []
    var minimizedTabs: [WorkspaceTab] = []
    var activeTab: WorkspaceTab?
    var savedAt = Date()
}

struct SessionStore {
    let layout: FileLayout
    var stateURL: URL { layout.root.appendingPathComponent("session.json") }
    var draftsDirectory: URL { layout.root.appendingPathComponent("Drafts", isDirectory: true) }

    func save(_ state: SessionState) {
        try? AtomicFile.writeJSON(state, to: stateURL)
    }

    func load() -> SessionState? {
        AtomicFile.readJSON(SessionState.self, from: stateURL)
    }

    func saveDraft(_ draft: ComposeDraft) {
        try? AtomicFile.writeJSON(draft, to: draftsDirectory.appendingPathComponent("\(draft.id.uuidString).json"))
    }

    func removeDraft(_ id: UUID) {
        try? FileManager.default.removeItem(at: draftsDirectory.appendingPathComponent("\(id.uuidString).json"))
    }

    func loadDrafts() -> [ComposeDraft] {
        let files = (try? FileManager.default.contentsOfDirectory(at: draftsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { AtomicFile.readJSON(ComposeDraft.self, from: $0) }
    }
}
