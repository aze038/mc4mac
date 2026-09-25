import Foundation

// What the table's selection means to the rest of the app: which messages the reading pane shows,
// which one reading marks read, where the selection goes when the selected rows leave the list,
// and which messages of a conversation a view holds.

/// One selected row of the table, as the reading pane and the commands take it.
public struct SelectedListRow: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A lone message's row.
        case message
        /// A conversation's own row: its messages stacked, the newest open.
        case conversation
        /// One message line of an opened conversation, whose row is `parent`.
        case member(parent: RowKey)
    }

    public var row: Int
    public var key: RowKey
    public var kind: Kind

    public init(row: Int, key: RowKey, kind: Kind) {
        self.row = row
        self.key = key
        self.kind = kind
    }
}

extension ListSnapshot {
    /// The conversation row a message line belongs to; nil for any other row.
    public func parentRow(of row: Int) -> Int? {
        guard rows.indices.contains(row), rows[row].displayKind == .child else { return nil }
        var i = row - 1
        while i >= 0 {
            switch rows[i].displayKind {
            case .child: i -= 1
            case .header: return nil
            case .conversation, .message: return i
            }
        }
        return nil
    }

    /// The selected rows in the list's order, as the reading pane takes them; nil above 1,000
    /// rows, where nothing may be handed a part of the selection.
    public func selectedRows(_ selection: ListSelection) -> [SelectedListRow]? {
        guard selection.count(in: self) <= ActionTargets.largestItemList else { return nil }
        return selection.indexes(in: self).compactMap { row -> SelectedListRow? in
            guard let key = rowKey(at: row) else { return nil }
            switch rows[row].displayKind {
            case .header: return nil
            case .message: return SelectedListRow(row: row, key: key, kind: .message)
            case .conversation: return SelectedListRow(row: row, key: key, kind: .conversation)
            case .child:
                guard let parent = parentRow(of: row), let parentKey = rowKey(at: parent) else {
                    return SelectedListRow(row: row, key: key, kind: .message)
                }
                return SelectedListRow(row: row, key: key, kind: .member(parent: parentKey))
            }
        }
    }

    /// The first row, from `start` in the direction given, that can be selected: any but a
    /// group's header.
    public func selectableRow(from start: Int, forward: Bool) -> Int? {
        var i = start
        while rows.indices.contains(i) {
            if rows[i].displayKind != .header { return i }
            i += forward ? 1 : -1
        }
        return nil
    }
}

/// Where the selection goes when every selected row leaves the list, as after Delete, Archive or
/// Move: to the row that followed them, or the one before, as Settings → Reading says, as
/// Outlook does.
public enum ListAdvance {
    /// The row of `new` to select once `removed`, rows of the list before the change, took every
    /// row of `selected` with them; nil when some selected row stayed, when nothing was selected,
    /// and when the list is empty.
    public static func row(selected: IndexSet, removed: IndexSet, in new: ListSnapshot, forward: Bool) -> Int? {
        guard let first = selected.first, !selected.isEmpty, selected.isSubset(of: removed), !new.rows.isEmpty else { return nil }
        // The rows before the first selected one that went too move the place up.
        let gone = removed.count(in: 0..<first)
        let place = min(first - gone, new.rows.count)
        if forward {
            return new.selectableRow(from: place, forward: true) ?? new.selectableRow(from: place - 1, forward: false)
        }
        return new.selectableRow(from: place - 1, forward: false) ?? new.selectableRow(from: place, forward: true)
    }
}

extension GmailIndexSnapshot {
    /// The messages of a Gmail conversation that a folder shows, newest first: those with the
    /// folder's label, or, for Archive (`label` nil), every one. Messages in Junk Email, Deleted
    /// Items and chats are left out, except from Junk Email and Deleted Items themselves, as
    /// Outlook leaves them out of a conversation.
    ///
    /// These are the messages the reading pane stacks and a command on the conversation's row acts
    /// on, so a Delete in the Inbox never reaches the owner's own replies in Sent.
    ///
    /// Only the conversation's own messages are looked at, found in `threadOrder`, which is built
    /// once per change of the index: a conversation in a mailbox of 200,000 costs its own size.
    public func conversationMembers(thread: UInt64, label: GmailLabelID?, limit: Int = 200) -> [GmailMessageID] {
        let grouped = threadOrder.slots(in: self)
        // The first of the conversation's slots, by binary search on the thread.
        var low = 0
        var high = grouped.count
        while low < high {
            let mid = (low + high) / 2
            if records[Int(grouped[mid])].threadID < thread { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < grouped.count, records[Int(grouped[end])].threadID == thread { end += 1 }
        return conversationMembers(slots: grouped[low..<end].reversed(), thread: thread, label: label, limit: limit)
    }

    /// The same by a pass over the whole order, as it was worked out before `threadOrder`: kept
    /// for the tests, which check the two agree.
    func conversationMembersByScan(thread: UInt64, label: GmailLabelID?, limit: Int = 200) -> [GmailMessageID] {
        conversationMembers(slots: byOrder.reversed(), thread: thread, label: label, limit: limit)
    }

    /// The members among `slots`, which go newest first.
    private func conversationMembers<S: Sequence>(slots: S, thread: UInt64, label: GmailLabelID?, limit: Int) -> [GmailMessageID]
        where S.Element == Int32 {
        let hidden: [GmailLabelID] = [.spam, .trash, .chat]
        var out: [GmailMessageID] = []
        for slot in slots {
            let record = records[Int(slot)]
            guard record.threadID == thread, !record.attributes.contains(.tombstone) else { continue }
            if let label {
                guard self.record(atSlot: slot, has: label) else { continue }
                if label != .spam, label != .trash, hidden.contains(where: { record.hasSystemLabel($0) }) { continue }
            } else if hidden.contains(where: { record.hasSystemLabel($0) }) {
                continue
            }
            out.append(record.gmailID)
            if out.count >= limit { break }
        }
        return out
    }
}

extension ListStatusText {
    /// Whether every folder the sidebar shows for a Google account has been listed in full, so
    /// that "All folders are up to date." is true of it: All Mail, every folder shown, and the
    /// read state of every message.
    public static func everyFolderListed(allMailComplete: Bool, labels: [GmailLabelEntry]) -> Bool {
        guard allMailComplete else { return false }
        return labels.allSatisfy { !($0.isShown || $0.id == .unread) || $0.isComplete }
    }
}
