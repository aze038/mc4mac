import Foundation

/// What the engine keeps about an account beside folders.json, in `Accounts/<id>/syncExtras.json`,
/// a file earlier builds do not know and so ignore: where the last flag check of each folder got
/// to and its CONDSTORE mark, which keep a pass small, and how far Gmail's cool-down has
/// escalated, which must outlive a relaunch. Every field is optional, so any build reads what
/// any other wrote, and losing the file costs one larger pass, never mail.
struct SyncExtras: Codable, Equatable {
    /// How far the throttle cool-down has escalated, 0 for the first step.
    var imapPauseLevel: Int?
    var lastThrottleAt: Date?
    var imapPausedUntil: Date?
    /// The `MailServiceError.Kind` the pause is for.
    var imapPauseReason: String?
    /// Keyed by folder id.
    var folders: [String: FolderSyncExtras]?
}

struct FolderSyncExtras: Codable, Equatable {
    /// The numbering the rest belongs to: under another UIDVALIDITY none of it holds.
    var uidValidity: UInt32
    /// HIGHESTMODSEQ when the folder's flags were last brought up to date.
    var highestModSeq: UInt64?
    /// The next slice of older messages whose flags are checked ends just below this UID; nil
    /// starts again just below the newest.
    var flagSliceBelow: UInt32?
    /// Under CONDSTORE, true once every older message has been checked since `highestModSeq`
    /// was first taken, after which the changes since it are all a pass asks for.
    var flagsSwept: Bool?
    /// How many messages the server held that are neither stored nor waiting to be fetched,
    /// below the oldest one listed or in a gap above it, when last counted.
    var belowWindow: Int?
    /// Set when the folder was emptied because the server reported it empty and its cursors
    /// started again: the highest UID listed before. Whatever the server shows there later is
    /// listed afresh, and only mail above this is news, until the cursor passes it.
    var newAbove: UInt32?

    init(uidValidity: UInt32) {
        self.uidValidity = uidValidity
    }
}

/// The account's syncExtras.json, written on every change. One that could not be decoded is
/// set aside like any other stored file, and one that could not be read is never written over.
struct SyncExtrasFile {
    private let url: URL
    private let writable: Bool
    private(set) var value: SyncExtras

    init(layout: FileLayout, account: AccountInfo) {
        url = layout.syncExtrasFile(account.id)
        let stored = AtomicFile.loadJSON(SyncExtras.self, from: url, what: "the sync state for \(account.email)")
        value = stored.value ?? SyncExtras()
        writable = stored.canSave
    }

    mutating func update(_ change: (inout SyncExtras) -> Void) {
        var next = value
        change(&next)
        guard next != value else { return }
        value = next
        guard writable else { return }
        do {
            try AtomicFile.writeJSON(next, to: url)
        } catch {
            Log.error("Store", "could not save \(url.lastPathComponent): \(error.localizedDescription)", error: error, logAs: "store")
        }
    }

    /// The folder's extras under its present numbering.
    func folder(_ folder: FolderInfo) -> FolderSyncExtras {
        if let known = value.folders?[folder.id.uuidString], known.uidValidity == folder.uidValidity { return known }
        return FolderSyncExtras(uidValidity: folder.uidValidity)
    }

    /// Changes one folder's extras, starting afresh when they were kept under another numbering.
    mutating func updateFolder(_ id: UUID, uidValidity: UInt32, _ change: (inout FolderSyncExtras) -> Void) {
        update { all in
            var map = all.folders ?? [:]
            var entry = map[id.uuidString].flatMap { $0.uidValidity == uidValidity ? $0 : nil } ?? FolderSyncExtras(uidValidity: uidValidity)
            change(&entry)
            map[id.uuidString] = entry
            all.folders = map
        }
    }

    /// Forgets folders the server no longer lists.
    mutating func keepFolders(_ ids: Set<UUID>) {
        update { all in
            guard let map = all.folders else { return }
            let kept = map.filter { UUID(uuidString: $0.key).map(ids.contains) ?? false }
            all.folders = kept.isEmpty ? nil : kept
        }
    }
}
