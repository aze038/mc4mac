import Foundation
import FalconCore

struct MoveTarget: Codable, Hashable {
    var accountID: UUID
    var folderPath: String
    var useCount: Int
    var lastUsed: Date
}

@MainActor
final class MoveTargets {
    private let url: URL
    private var entries: [MoveTarget]
    private let limit = 50

    init(layout: FileLayout) {
        url = layout.moveTargetsFile
        entries = (AtomicFile.readJSON([MoveTarget].self, from: url) ?? []).sorted { $0.lastUsed > $1.lastUsed }
    }

    var last: MoveTarget? { entries.first }

    func recent(limit: Int = 15) -> [MoveTarget] {
        Array(entries.prefix(limit))
    }

    func entry(for folder: FolderInfo) -> MoveTarget? {
        entries.first { $0.accountID == folder.accountID && $0.folderPath == folder.path }
    }

    func record(folder: FolderInfo) {
        let uses = (entry(for: folder)?.useCount ?? 0) + 1
        entries.removeAll { $0.accountID == folder.accountID && $0.folderPath == folder.path }
        entries.insert(MoveTarget(accountID: folder.accountID, folderPath: folder.path, useCount: uses, lastUsed: Date()), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        try? AtomicFile.writeJSON(entries, to: url)
    }
}

enum FolderMatch {
    static let namePrefix = 0
    static let substring = 1
    static let subsequence = 2

    static func tier(for folder: FolderInfo, accountEmail: String, needle: String) -> Int? {
        if folder.name.lowercased().hasPrefix(needle) { return namePrefix }
        let haystack = "\(accountEmail) \(folder.path)".lowercased()
        if haystack.contains(needle) { return substring }
        return contains(subsequence: needle, in: haystack) ? subsequence : nil
    }

    static func contains(subsequence needle: String, in haystack: String) -> Bool {
        var remaining = needle[...]
        for character in haystack {
            guard let next = remaining.first else { return true }
            if next == character { remaining = remaining.dropFirst() }
        }
        return remaining.isEmpty
    }
}
