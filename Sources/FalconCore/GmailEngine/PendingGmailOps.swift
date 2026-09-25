import Foundation

// Changes the owner, or a rule, made to a Google account's mail that have not reached Gmail yet.
// They live in `Accounts/<id>/Gmail/pendingOps.json`, which v1.10.0 never reads, and never in
// `pendingActions.json`: an IMAP build that found a Gmail change there would try to run it as an
// IMAP command on UIDs it does not have.

/// One change on its way to Gmail: what it does to each message, the folder it was made in, and
/// where it has got to.
public struct PendingGmailOp: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable {
        /// Labels added and removed, with `messages.modify` for fewer than ten messages and
        /// `batchModify` for more.
        case labels
        /// Delete in Drafts: `drafts.delete`, which keeps nothing in Deleted Items.
        case discardDrafts
        /// Delete for good in Deleted Items or Junk Email, or Empty Folder: `batchDelete`, only
        /// for messages a fresh listing still finds there.
        case deleteForever
    }

    public enum Phase: Codable, Hashable, Sendable {
        /// Waiting out the undo window; Undo drops it and nothing is sent.
        case held(until: Date)
        /// Being sent, on this attempt. A launch that finds it sends it again: every label change
        /// is idempotent, so a change that did reach Gmail comes to no harm.
        case committing(attempt: Int)
        /// Gmail has it.
        case committed
    }

    /// Messages that change in the same way. A change keeps each message's own delta, grouped,
    /// because `batchModify` applies one set of labels to every id it is given.
    public struct Delta: Hashable, Sendable {
        /// Labels the messages lacked, and gain.
        public var add: Set<GmailLabelID>
        /// Labels the messages had, and lose.
        public var remove: Set<GmailLabelID>
        public var ids: [GmailMessageID]

        public init(add: Set<GmailLabelID>, remove: Set<GmailLabelID>, ids: [GmailMessageID]) {
            self.add = add
            self.remove = remove
            self.ids = ids
        }

        /// The same messages changed back, as Undo after sending needs.
        public var reversed: Delta { Delta(add: remove, remove: add, ids: ids) }
        public var labels: Set<GmailLabelID> { add.union(remove) }
    }

    /// A history record that touched a label this change is about while the change waited, kept
    /// back so the owner's change shows until Gmail has it. Applied if the change ends without
    /// being sent, so nothing done on another device meanwhile is lost.
    public struct KeptRecord: Codable, Hashable, Sendable {
        public var history: HistoryID
        public var id: GmailMessageID
        public var added: Set<GmailLabelID>
        public var removed: Set<GmailLabelID>

        public init(history: HistoryID, id: GmailMessageID, added: Set<GmailLabelID>, removed: Set<GmailLabelID>) {
            self.history = history
            self.id = id
            self.added = added
            self.removed = removed
        }
    }

    /// Which view a change on a whole view covered, as after Select All or Mark All as Read. The
    /// ids it covers are worked out once, when the change is made, so mail that arrives later is
    /// left alone.
    public struct ViewPredicate: Codable, Hashable, Sendable {
        /// The folder's label; nil for Archive, a search or All Inboxes' account.
        public var label: GmailLabelID?
        public var filters: [ListFilter]
        /// Rows the owner left out of the selection.
        public var excluded: Int

        public init(label: GmailLabelID?, filters: [ListFilter], excluded: Int) {
            self.label = label
            self.filters = filters
            self.excluded = excluded
        }
    }

    /// The request's id, which Undo is given.
    public var id: UUID
    public var kind: Kind
    /// What the owner did, such as `archive` or `move`, for the log.
    public var verb: String
    public var deltas: [Delta]
    /// The folder the change was made in; nil for Archive or a search.
    public var contextLabel: GmailLabelID?
    public var createdAt: Date
    /// The history id the index was at when the change was made. After a gap, a message that
    /// history since then touched is left out, since someone has acted on it since.
    public var knownAt: HistoryID?
    public var phase: Phase
    public var wholeView: ViewPredicate?
    public var skippedRecords: [KeptRecord]
    /// A rule's change, or a muted conversation's new mail: no undo window.
    public var isAutomatic: Bool
    public var isUndoable: Bool
    /// Folder names the change's sentences hold, which diagnostics take out.
    public var names: [String]
    /// Conversations this change muted, which Undo unmutes again.
    public var mutedThreadKeys: [String]

    public init(id: UUID, kind: Kind, verb: String, deltas: [Delta], contextLabel: GmailLabelID?, createdAt: Date,
                knownAt: HistoryID?, phase: Phase, wholeView: ViewPredicate? = nil, skippedRecords: [KeptRecord] = [],
                isAutomatic: Bool = false, isUndoable: Bool = true, names: [String] = [], mutedThreadKeys: [String] = []) {
        self.id = id
        self.kind = kind
        self.verb = verb
        self.deltas = deltas
        self.contextLabel = contextLabel
        self.createdAt = createdAt
        self.knownAt = knownAt
        self.phase = phase
        self.wholeView = wholeView
        self.skippedRecords = skippedRecords
        self.isAutomatic = isAutomatic
        self.isUndoable = isUndoable
        self.names = names
        self.mutedThreadKeys = mutedThreadKeys
    }

    /// Every message the change touches.
    public var messageIDs: [GmailMessageID] { deltas.flatMap(\.ids) }
    public var messageCount: Int { deltas.reduce(0) { $0 + $1.ids.count } }

    public var isCommitted: Bool { phase == .committed }

    public var isHeld: Bool {
        if case .held = phase { return true }
        return false
    }

    /// Whole-view changes run as bulk work, which gives way to everything the owner is waiting for.
    public var isBulk: Bool { wholeView != nil }

    /// Pending changes older than this are not sent, as v1.10.0 does with its own: a day later
    /// the mail may well have changed, and a stale change would undo what was done since.
    public static let lifetime: TimeInterval = 24 * 3600
}

// MARK: - Coding

extension PendingGmailOp.Delta: Codable {
    private enum CodingKeys: String, CodingKey { case add, remove, ids, packed }

    /// Past this many ids a group is written as packed bytes, 8 a message, rather than as a list of
    /// hex strings: a change on a whole view of 200,000 messages then takes 1.6 MB, not 4.
    static let largestListed = 1_000

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        add = Set(try c.decodeIfPresent([GmailLabelID].self, forKey: .add) ?? [])
        remove = Set(try c.decodeIfPresent([GmailLabelID].self, forKey: .remove) ?? [])
        if let packed = try c.decodeIfPresent(String.self, forKey: .packed) {
            guard let data = Data(base64Encoded: packed), data.count % 8 == 0 else {
                throw DecodingError.dataCorruptedError(forKey: .packed, in: c, debugDescription: "not packed message ids")
            }
            ids = PendingGmailOp.Delta.unpack(data)
        } else {
            ids = try c.decodeIfPresent([GmailMessageID].self, forKey: .ids) ?? []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(add.sorted(), forKey: .add)
        try c.encode(remove.sorted(), forKey: .remove)
        if ids.count > PendingGmailOp.Delta.largestListed {
            try c.encode(PendingGmailOp.Delta.pack(ids).base64EncodedString(), forKey: .packed)
        } else {
            try c.encode(ids, forKey: .ids)
        }
    }

    static func pack(_ ids: [GmailMessageID]) -> Data {
        var data = Data(capacity: ids.count * 8)
        for id in ids {
            withUnsafeBytes(of: id.raw.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func unpack(_ data: Data) -> [GmailMessageID] {
        data.withUnsafeBytes { buffer in
            stride(from: 0, to: buffer.count, by: 8).map { offset in
                GmailMessageID(raw: UInt64(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self)))
            }
        }
    }
}

// MARK: - The file

/// `pendingOps.json`: the changes still on their way, oldest first, rewritten whole at each step
/// so a crash leaves either the step before or the step after.
public struct PendingGmailOpsFile: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public init(files: GmailFiles) {
        self.init(url: files.pendingOps)
    }

    /// What was saved, and whether saving is safe: a file that is there but could not be read is
    /// never written over, and one that could not be decoded has been set aside whole.
    public func load() -> (ops: [PendingGmailOp], canSave: Bool) {
        let stored = AtomicFile.loadJSON([PendingGmailOp].self, from: url, what: "the Gmail changes waiting to be sent")
        return (stored.value ?? [], stored.canSave)
    }

    public func save(_ ops: [PendingGmailOp]) throws {
        let waiting = ops.filter { !$0.isCommitted }
        if waiting.isEmpty {
            // No file at all is the usual state, and the one an earlier build leaves.
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try AtomicFile.writeJSON(waiting, to: url)
    }
}
