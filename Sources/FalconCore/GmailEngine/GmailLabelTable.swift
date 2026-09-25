import CryptoKit
import Foundation

/// `labels.json`: every label of the account, whether it is shown, what `labels.get` last said
/// of it, and its bit in the index.
///
/// Which user label holds which bit is decided here but kept by the index, in the journal, so the
/// bits and their meaning are saved together; the slots written into `labels.json` are a copy for
/// reading, refreshed from the index at every launch.
public enum GmailLabelTable {
    /// A label this much larger than the smallest label with a bit, and larger by at least
    /// `swapMargin` messages, takes that bit over. The margins keep two labels of about the same
    /// size from trading places every time their counts move, since each trade rewrites every
    /// member's bits.
    static let swapFactor = 2
    static let swapMargin = 100

    /// Gives each label its place in the index: the fixed system labels their own bits, shown user
    /// labels a bit while there are bits free, largest first, and every other shown user label an
    /// overflow list. A user label that already has a bit keeps it, so no record has to change,
    /// unless a much larger label has none. Hidden labels take nothing and cost nothing.
    ///
    /// A label that had no place in the index before has no members listed yet, so it is marked
    /// incomplete whatever the entry said.
    static func assign(_ entries: [GmailLabelEntry], current: GmailSlotMap) -> (entries: [GmailLabelEntry], map: GmailSlotMap) {
        var result = entries
        var map = GmailSlotMap()
        var taken = Set<Int>()
        for i in result.indices {
            let entry = result[i]
            if let fixed = entry.id.fixedSlot {
                result[i].slot = fixed
            } else if entry.kind == .user, entry.isShown, let kept = current.userSlots[entry.id], !taken.contains(kept) {
                map.userSlots[entry.id] = kept
                taken.insert(kept)
            }
        }
        func total(_ i: Int) -> Int { result[i].counts?.messagesTotal ?? 0 }
        let waiting = result.indices
            .filter { result[$0].kind == .user && result[$0].isShown && result[$0].id.fixedSlot == nil && map.userSlots[result[$0].id] == nil }
            .sorted { (total($1), result[$0].name) < (total($0), result[$1].name) }
        var free = (GmailLabelID.firstUserSlot..<GmailLabelID.slotCount).filter { !taken.contains($0) }
        var overflow: [Int] = []
        for i in waiting {
            if free.isEmpty {
                overflow.append(i)
            } else {
                map.userSlots[result[i].id] = free.removeFirst()
            }
        }

        // The largest overflow label takes the bit of the smallest slotted one, while it is much
        // larger.
        let slottedIndices = { result.indices.filter { map.userSlots[result[$0].id] != nil } }
        var slotted = slottedIndices()
        while let big = overflow.max(by: { total($0) < total($1) }),
              let small = slotted.min(by: { total($0) < total($1) }),
              total(big) > swapFactor * total(small) + swapMargin {
            let bit = map.userSlots.removeValue(forKey: result[small].id)!
            map.userSlots[result[big].id] = bit
            overflow.removeAll { $0 == big }
            overflow.append(small)
            slotted = slottedIndices()
        }
        map.overflow = Set(overflow.map { result[$0].id })

        for i in result.indices where result[i].id.fixedSlot == nil {
            result[i].slot = map.userSlots[result[i].id]
            let tracked = map.userSlots[result[i].id] != nil || map.overflow.contains(result[i].id)
            if tracked, !current.tracked.contains(result[i].id) { result[i].isComplete = false }
        }
        return (result, map)
    }

    /// The table as saved, with each label's slot as the index has it now.
    static func load(from url: URL, map: GmailSlotMap) -> [GmailLabelEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let entries = try? JSONDecoder().decode([GmailLabelEntry].self, from: data) else {
            Log.warning("Store", "could not read the Gmail label table; it is fetched again", code: "gmailLabelsUnreadable", logAs: "store")
            return []
        }
        return entries.map { entry in
            var entry = entry
            entry.slot = entry.id.fixedSlot ?? map.userSlots[entry.id]
            return entry
        }
    }

    static func save(_ entries: [GmailLabelEntry], to url: URL, io: GmailDiskIO) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try io.replace(try encoder.encode(entries), at: url)
    }

    /// The sidebar folder id of a label that had no IMAP folder to take one from: the same for the
    /// same account and label on every Mac and every launch, so rules and move targets keep
    /// pointing at it. SHA-256 of the account's id and the label's, shaped as a name-based UUID.
    public static func folderID(account: UUID, label: GmailLabelID) -> UUID {
        var hasher = SHA256()
        withUnsafeBytes(of: account.uuid) { hasher.update(bufferPointer: $0) }
        hasher.update(data: Data(label.value.utf8))
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Whether a label of an account added after the switch starts out in the sidebar. Gmail's
    /// `labelShowIfUnread` is shown too: the sidebar keeps a folder's place whether or not it has
    /// unread mail, as Outlook does.
    public static func isShownByDefault(labelListVisibility: String?) -> Bool {
        labelListVisibility != "labelHide"
    }
}
