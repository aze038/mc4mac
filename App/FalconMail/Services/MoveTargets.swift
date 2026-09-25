import Foundation
import FalconCore

struct MoveTarget: Codable, Hashable {
    var accountID: UUID
    var folderPath: String
    var useCount: Int
    var lastUsed: Date
    /// The folder's id as well as its path. A Google account on the Gmail engine keeps its
    /// folders' ids but shows Outlook's names, so a recent target is still found after the switch.
    /// Optional, so a file an earlier build wrote still reads, and an earlier build reads this one.
    var folderID: UUID?
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
        entries.first { MoveTargets.names($0, folder) }
    }

    func record(folder: FolderInfo) {
        let uses = (entry(for: folder)?.useCount ?? 0) + 1
        entries.removeAll { MoveTargets.names($0, folder) }
        entries.insert(MoveTarget(accountID: folder.accountID, folderPath: folder.path, useCount: uses, lastUsed: Date(),
                                  folderID: folder.id), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        try? AtomicFile.writeJSON(entries, to: url)
    }

    /// The folder a recent target names among an account's folders: by its id when it was
    /// recorded with one, otherwise by its path, as every earlier build recorded it.
    static func folder(for target: MoveTarget, in folders: [FolderInfo]) -> FolderInfo? {
        let selectable = folders.filter { $0.accountID == target.accountID && $0.isSelectable }
        if let id = target.folderID, let found = selectable.first(where: { $0.id == id }) { return found }
        return selectable.first { $0.path == target.folderPath }
    }

    /// Whether the Move palette offers `folder`. A Google account on the Gmail engine never
    /// offers Drafts or Sent, since Gmail does not let an app put mail in either; every other
    /// account's folders are all offered, as before.
    static func offers(_ folder: FolderInfo) -> Bool {
        folder.isSelectable && GmailActionRules.isMoveTarget(folder)
    }

    private static func names(_ entry: MoveTarget, _ folder: FolderInfo) -> Bool {
        guard entry.accountID == folder.accountID else { return false }
        if let id = entry.folderID, id == folder.id { return true }
        return entry.folderPath == folder.path
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
