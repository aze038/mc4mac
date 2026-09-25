import Foundation

/// What a Google account keeps on the Mac: the index of every message, the journal that makes it
/// survive a crash, the label table, date anchors, the newest 1,000 with their bodies,
/// conversation summaries and the import log.
///
/// The account's engine is its only writer. The history cursor lives only in the journal, written
/// in the same flush as the changes it covers, so a crash can make FalconMail apply changes twice
/// but never skip one. Applying a change twice is harmless: every change here says what the state
/// becomes, not what to add to it.
public protocol GmailStore: AnyObject, Sendable {
    var accountID: UUID { get }
    var files: GmailFiles { get }

    /// Reads what was saved: the snapshot, then the journal, applying listing pages wherever they
    /// stand and change records only up to the last complete cursor record.
    func load() async throws -> GmailStoreLoad

    // MARK: The index

    /// The whole index as an immutable value, for building views off the main thread.
    func index() async -> GmailIndexSnapshot
    func record(for id: GmailMessageID) async -> GmailIndexRecord?
    /// A message's labels, from its bits and the overflow lists; nil when it is not in the index.
    func labels(of id: GmailMessageID) async -> Set<GmailLabelID>?

    // MARK: The journal

    /// Appends the changes, then the cursor record when there is one, and flushes them together,
    /// in order. Changes are applied at once.
    func commit(_ batch: GmailJournalBatch) async throws
    /// Appends one page of a listing, which counts on load whether or not a cursor follows. A page
    /// only places messages and sets bits; it never removes anything.
    func appendListingPage(_ page: GmailListingPage) async throws
    /// Rewrites the snapshot and empties the journal. The store also does this by itself once the
    /// journal is long; the engine asks at quit.
    func compact() async throws

    // MARK: Labels

    func labelTable() async -> [GmailLabelEntry]
    /// Replaces the table and returns it with each label's bit slot as the store gave it. System
    /// labels keep their fixed slots, and the largest shown user labels take the rest; any
    /// others are kept in overflow lists. A label taken out of the table leaves every record.
    @discardableResult
    func saveLabelTable(_ entries: [GmailLabelEntry]) async throws -> [GmailLabelEntry]

    // MARK: Date anchors

    func dateAnchors() async -> [GmailDateAnchor]
    func saveDateAnchors(_ anchors: [GmailDateAnchor]) async throws

    // MARK: The newest 1,000

    func cachedMessages(_ ids: [GmailMessageID]) async -> [GmailMessageID: GmailCachedMessage]
    func cachedIDs() async -> Set<GmailMessageID>
    /// Keeps a message and its reduced body, then evicts past the limits: back to 1,000 once the
    /// count reaches 1,050, and the oldest bodies once they pass 32 MB, keeping their rows.
    /// Returns the messages that left, whose Spotlight entries and summaries go with them.
    @discardableResult
    func cache(_ message: GmailCachedMessage, body: GmailReducedBody?) async throws -> [GmailMessageID]
    func body(of id: GmailMessageID) async throws -> GmailReducedBody?
    func uncache(_ ids: [GmailMessageID]) async throws
    /// Messages that must stay whatever their age: drafts, messages with a change waiting, and
    /// those open in a window or tab.
    func setPinned(_ ids: Set<GmailMessageID>) async
    /// The owner opened a folder showing `rows` rows. The Inbox and the 12 folders used most
    /// recently keep their first screen on the Mac. Archive, which has no label, is nil.
    func noteFolderShown(_ label: GmailLabelID?, rows: Int, at date: Date) async
    /// Messages that belong in the cache and are not in it yet, the most wanted first.
    func messagesToCache(limit: Int) async -> [GmailMessageID]
    /// Kept messages whose headers or preview hold every word of `query`, newest first: search
    /// offline, or while Gmail has asked FalconMail to wait.
    func searchCached(_ query: String, limit: Int) async -> [GmailMessageID]

    // MARK: Conversation summaries

    func threadSummaries(_ ids: [GmailThreadID]) async -> [GmailThreadID: GmailThreadSummary]
    func saveThreadSummaries(_ summaries: [GmailThreadSummary]) async throws
    func removeThreadSummaries(_ ids: [GmailThreadID]) async throws

    // MARK: The import log

    /// Messages FalconMail imported itself: their echo in the history is never new mail, never
    /// starts flood mode, and never runs rules or notifications. Kept for 7 days.
    func noteImported(_ ids: [GmailMessageID], at date: Date) async throws
    func wasImported(_ id: GmailMessageID) async -> Bool
}

// MARK: - The index

/// One message in the index: 32 bytes, so 200,000 messages take 6.4 MB. It holds no text and no
/// dates; those come with a row's text.
public struct GmailIndexRecord: Hashable, Sendable {
    public var id: UInt64
    public var threadID: UInt64
    /// Slots 0–15 are the fixed system labels, 16–63 the largest shown user labels.
    public var labelBits: UInt64
    /// The place in the account's order: newer is larger, and gaps of 16 leave room to insert.
    public var order: UInt32
    public var attributes: GmailRecordAttributes
    public var spare: UInt16

    public static let orderStep: UInt32 = 16

    public init(id: GmailMessageID, threadID: GmailThreadID, labelBits: UInt64 = 0, order: UInt32,
                attributes: GmailRecordAttributes = []) {
        self.id = id.raw
        self.threadID = threadID.raw
        self.labelBits = labelBits
        self.order = order
        self.attributes = attributes
        self.spare = 0
    }

    public var gmailID: GmailMessageID { GmailMessageID(raw: id) }
    public var gmailThreadID: GmailThreadID { GmailThreadID(raw: threadID) }
    public var ref: GmailRef { GmailRef(id: gmailID, threadID: gmailThreadID) }

    public func has(slot: Int) -> Bool { labelBits & (1 << UInt64(slot)) != 0 }
    /// For the labels with a fixed slot only; a user label's slot is the store's, and is read
    /// through `GmailIndexSnapshot`.
    public func hasSystemLabel(_ label: GmailLabelID) -> Bool { label.fixedSlot.map(has(slot:)) ?? false }
}

public struct GmailRecordAttributes: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// Gone from Gmail. Its slot stays until compaction.
    public static let tombstone = GmailRecordAttributes(rawValue: 1 << 0)
    /// Known but not shown yet, such as mail another app is importing.
    public static let provisional = GmailRecordAttributes(rawValue: 1 << 1)
    /// Among the messages kept on the Mac.
    public static let cached = GmailRecordAttributes(rawValue: 1 << 2)
    public static let attachmentKnown = GmailRecordAttributes(rawValue: 1 << 3)
    public static let hasAttachment = GmailRecordAttributes(rawValue: 1 << 4)
    private static let sizeShift: UInt16 = 5
    private static let sizeMask: UInt16 = 0b111 << sizeShift
    public static let sizeKnown = GmailRecordAttributes(rawValue: 1 << 8)
    /// Every bit `sizeBand` uses, for clearing an old band before setting a new one.
    public static let allSizeBands = GmailRecordAttributes(rawValue: sizeMask)

    /// Meaningful only with `sizeKnown`.
    public var sizeBand: SizeBand {
        get { SizeBand(rawValue: UInt8((rawValue & GmailRecordAttributes.sizeMask) >> GmailRecordAttributes.sizeShift)) ?? .tiny }
        set {
            self = GmailRecordAttributes(rawValue: (rawValue & ~GmailRecordAttributes.sizeMask)
                                         | (UInt16(newValue.rawValue) << GmailRecordAttributes.sizeShift))
        }
    }
}

/// The index at one moment, for building views. Holding it costs nothing until the store next
/// changes, which then copies what it changes.
public struct GmailIndexSnapshot: Sendable {
    /// By slot. A slot never moves; a deleted message is a tombstone until compaction.
    public let records: ContiguousArray<GmailIndexRecord>
    /// Slots in the account's order, oldest first, with no tombstones. A view is one pass over it.
    public let byOrder: ContiguousArray<Int32>
    public let slotByID: [UInt64: Int32]
    /// Which label each bit slot holds.
    public let labelSlots: [GmailLabelID: Int]
    /// The members of shown labels that have no bit slot, as sorted record slots.
    public let overflow: [GmailLabelID: ContiguousArray<Int32>]

    public init(records: ContiguousArray<GmailIndexRecord>, byOrder: ContiguousArray<Int32>, slotByID: [UInt64: Int32],
                labelSlots: [GmailLabelID: Int], overflow: [GmailLabelID: ContiguousArray<Int32>]) {
        self.records = records
        self.byOrder = byOrder
        self.slotByID = slotByID
        self.labelSlots = labelSlots
        self.overflow = overflow
    }

    public static let empty = GmailIndexSnapshot(records: [], byOrder: [], slotByID: [:], labelSlots: [:], overflow: [:])

    public func record(for id: GmailMessageID) -> GmailIndexRecord? {
        slotByID[id.raw].map { records[Int($0)] }
    }

    /// Whether the record in `slot` carries `label`, by its bit or its overflow list.
    public func record(atSlot slot: Int32, has label: GmailLabelID) -> Bool {
        if let bit = labelSlots[label] { return records[Int(slot)].has(slot: bit) }
        guard let members = overflow[label] else { return false }
        var low = 0
        var high = members.count
        while low < high {
            let mid = (low + high) / 2
            if members[mid] < slot { low = mid + 1 } else { high = mid }
        }
        return low < members.count && members[low] == slot
    }

    public func labels(atSlot slot: Int32) -> Set<GmailLabelID> {
        let bits = records[Int(slot)].labelBits
        var out = Set(labelSlots.compactMap { bits & (1 << UInt64($0.value)) != 0 ? $0.key : nil })
        for label in overflow.keys where record(atSlot: slot, has: label) { out.insert(label) }
        return out
    }
}

// MARK: - The journal

/// One change record. Each says what the state becomes, so applying it again changes nothing.
public enum GmailChange: Hashable, Sendable {
    /// A message placed in the order with all of its labels, which replace any it had.
    case place(GmailRef, order: UInt32, labels: Set<GmailLabelID>, attributes: GmailRecordAttributes)
    /// Labels added, then labels removed, on a message the index holds.
    case relabel(GmailMessageID, adding: Set<GmailLabelID>, removing: Set<GmailLabelID>)
    /// Something learnt later, such as whether it has an attachment or how large it is.
    case attributes(GmailMessageID, setting: GmailRecordAttributes, clearing: GmailRecordAttributes)
    /// Gone from Gmail. It leaves the cache too.
    case tombstone(GmailMessageID)
    /// Known to exist but not placed yet, because its fetch failed for now. It is tried again at
    /// the next check, and never holds the cursor back.
    case awaitingPlacement(GmailRef)
    /// A full listing began because the history had expired. The cursor stays where it was until
    /// `resyncEnded`, so a launch that finds a begin without an end lists again.
    case resyncBegan(HistoryID)
    case resyncEnded(HistoryID)
}

public struct GmailJournalBatch: Hashable, Sendable {
    public var changes: [GmailChange]
    /// Written after the changes and flushed with them. On load, changes count only up to the
    /// last cursor record, and the next check brings the rest again.
    public var cursor: HistoryID?

    public init(changes: [GmailChange], cursor: HistoryID? = nil) {
        self.changes = changes
        self.cursor = cursor
    }
}

/// One list the index is built from, read page by page.
public enum GmailListingChain: Hashable, Sendable, Codable {
    /// All Mail, with Junk Email and Deleted Items, which gives every message its place in the
    /// order. A large mailbox is listed in slices of received dates, `after` inclusive.
    case allMail(after: Date?, before: Date?)
    /// One label's members, with Junk Email and Deleted Items so the bits stay exact.
    case label(GmailLabelID)
    /// Messages carrying every one of these, such as the Inbox with one category.
    case labels([GmailLabelID])
    /// A search that teaches the index something about each message it lists, such as
    /// `has:attachment` or `larger:1M`.
    case search(String)
}

/// One page of a listing: self-contained, so a quit or a crash resumes from the last one saved.
public struct GmailListingPage: Hashable, Sendable {
    public var chain: GmailListingChain
    /// Which listing of the chain this is; a relisting starts a new one.
    public var run: UInt32
    /// The token the page was asked for with, nil for the first page.
    public var pageToken: String?
    /// Nil when this was the chain's last page.
    public var nextPageToken: String?
    /// As listed, newest first.
    public var refs: [GmailRef]
    /// For All Mail: the order of the first message on the page, each next one `orderStep` below.
    public var firstOrder: UInt32?
    public var orderStep: UInt32
    /// Labels every listed message carries. A message the index does not hold yet keeps them
    /// until it is placed, since a label may be listed before All Mail reaches the message.
    public var labels: Set<GmailLabelID>
    /// Attributes every listed message has.
    public var attributes: GmailRecordAttributes

    public init(chain: GmailListingChain, run: UInt32 = 0, pageToken: String? = nil, nextPageToken: String? = nil,
                refs: [GmailRef], firstOrder: UInt32? = nil, orderStep: UInt32 = GmailIndexRecord.orderStep,
                labels: Set<GmailLabelID> = [], attributes: GmailRecordAttributes = []) {
        self.chain = chain
        self.run = run
        self.pageToken = pageToken
        self.nextPageToken = nextPageToken
        self.refs = refs
        self.firstOrder = firstOrder
        self.orderStep = orderStep
        self.labels = labels
        self.attributes = attributes
    }
}

public struct GmailChainProgress: Hashable, Sendable, Codable {
    public var run: UInt32
    /// Where to carry on; nil once the chain is complete, or before its first page.
    public var nextPageToken: String?
    public var isComplete: Bool
    public var listed: Int

    public init(run: UInt32, nextPageToken: String?, isComplete: Bool, listed: Int) {
        self.run = run
        self.nextPageToken = nextPageToken
        self.isComplete = isComplete
        self.listed = listed
    }
}

/// What a launch finds.
public struct GmailStoreLoad: Sendable {
    /// The last complete cursor record; nil before the first check.
    public var cursor: HistoryID?
    /// A resync that began and did not end, which has to run again.
    public var resyncBegan: HistoryID?
    public var awaitingPlacement: [GmailRef]
    public var chains: [GmailListingChain: GmailChainProgress]
    /// Messages in the index, tombstones left out.
    public var messageCount: Int

    public init(cursor: HistoryID? = nil, resyncBegan: HistoryID? = nil, awaitingPlacement: [GmailRef] = [],
                chains: [GmailListingChain: GmailChainProgress] = [:], messageCount: Int = 0) {
        self.cursor = cursor
        self.resyncBegan = resyncBegan
        self.awaitingPlacement = awaitingPlacement
        self.chains = chains
        self.messageCount = messageCount
    }
}

// MARK: - Labels

public struct GmailLabelEntry: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable { case system, user }

    public var id: GmailLabelID
    public var name: String
    public var kind: Kind
    /// Gmail's `labelListVisibility`: `labelShow`, `labelShowIfUnread` or `labelHide`.
    public var labelListVisibility: String?
    /// Gmail's `messageListVisibility`: `show` or `hide`.
    public var messageListVisibility: String?
    /// Shown in the sidebar. A label that is not takes no slot and costs nothing.
    public var isShown: Bool
    /// The sidebar folder's id: the one the account's IMAP folder of the same role or path had,
    /// so rules, move targets and the selection survive the switch.
    public var folderID: UUID
    /// The label's bit in every record, given by the store; nil for a label in the overflow
    /// lists, or one not shown.
    public var slot: Int?
    /// What `labels.get` said last.
    public var counts: GmailLabelCounts?
    /// Every member has been listed, so its bits, and the counts from them, are exact.
    public var isComplete: Bool

    public init(id: GmailLabelID, name: String, kind: Kind, labelListVisibility: String? = nil,
                messageListVisibility: String? = nil, isShown: Bool, folderID: UUID, slot: Int? = nil,
                counts: GmailLabelCounts? = nil, isComplete: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.labelListVisibility = labelListVisibility
        self.messageListVisibility = messageListVisibility
        self.isShown = isShown
        self.folderID = folderID
        self.slot = slot
        self.counts = counts
        self.isComplete = isComplete
    }
}

public struct GmailLabelCounts: Codable, Hashable, Sendable {
    public var messagesTotal: Int
    public var messagesUnread: Int
    public var threadsTotal: Int?
    public var threadsUnread: Int?
    public var asOf: Date

    public init(messagesTotal: Int, messagesUnread: Int, threadsTotal: Int? = nil, threadsUnread: Int? = nil, asOf: Date) {
        self.messagesTotal = messagesTotal
        self.messagesUnread = messagesUnread
        self.threadsTotal = threadsTotal
        self.threadsUnread = threadsUnread
        self.asOf = asOf
    }
}

// MARK: - Date anchors

/// Where a date group begins. The header for a boundary goes before the first message older than
/// it, found with one `before:` search, so no other message needs a date.
public struct GmailDateAnchor: Codable, Hashable, Sendable {
    public var boundary: Date
    /// The newest message older than the boundary; nil when none is.
    public var id: GmailMessageID?
    public var order: UInt32?
    public var askedAt: Date

    public init(boundary: Date, id: GmailMessageID?, order: UInt32?, askedAt: Date) {
        self.boundary = boundary
        self.id = id
        self.order = order
        self.askedAt = askedAt
    }
}

// MARK: - The newest 1,000

/// A message kept on the Mac: its row and what a reply or forward needs. Never its flags or
/// labels, which are always read from the index, so a cache behind the journal can be incomplete
/// but never wrong.
public struct GmailCachedMessage: Codable, Hashable, Sendable {
    public var id: GmailMessageID
    public var threadID: GmailThreadID
    public var from: EmailAddress
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var replyTo: [EmailAddress]
    public var subject: String
    /// At most 100 characters.
    public var preview: String
    /// When Gmail received it.
    public var date: Date
    public var size: Int
    public var hasAttachments: Bool
    public var messageID: String
    public var inReplyTo: String
    public var references: [String]
    /// Stubs only: the bytes are fetched when the owner opens or saves one.
    public var attachments: [GmailCachedAttachment]
    public var cachedAt: Date

    public init(id: GmailMessageID, threadID: GmailThreadID, from: EmailAddress, to: [EmailAddress] = [],
                cc: [EmailAddress] = [], bcc: [EmailAddress] = [], replyTo: [EmailAddress] = [], subject: String,
                preview: String, date: Date, size: Int, hasAttachments: Bool, messageID: String, inReplyTo: String = "",
                references: [String] = [], attachments: [GmailCachedAttachment] = [], cachedAt: Date) {
        self.id = id
        self.threadID = threadID
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.replyTo = replyTo
        self.subject = subject
        self.preview = preview
        self.date = date
        self.size = size
        self.hasAttachments = hasAttachments
        self.messageID = messageID
        self.inReplyTo = inReplyTo
        self.references = references
        self.attachments = attachments
        self.cachedAt = cachedAt
    }
}

public struct GmailCachedAttachment: Codable, Hashable, Sendable {
    public var partID: String
    /// Gmail's attachment id, which may stop working; a fresh `format=full` gives a new one.
    public var attachmentID: String?
    public var filename: String
    public var mimeType: String
    public var size: Int
    public var contentID: String?
    public var isInline: Bool

    public init(partID: String, attachmentID: String?, filename: String, mimeType: String, size: Int,
                contentID: String? = nil, isInline: Bool = false) {
        self.partID = partID
        self.attachmentID = attachmentID
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.contentID = contentID
        self.isInline = isInline
    }
}

/// A cached message's text and HTML, with the inline pictures of 100 KB or less that the HTML
/// shows. Attachments are left out.
public struct GmailReducedBody: Codable, Hashable, Sendable {
    public var textPlain: String?
    public var textHTML: String?
    public var inlineImages: [GmailInlineImage]

    public init(textPlain: String?, textHTML: String?, inlineImages: [GmailInlineImage] = []) {
        self.textPlain = textPlain
        self.textHTML = textHTML
        self.inlineImages = inlineImages
    }

    /// Roughly what it takes on disk before compression, for the cap on bodies.
    public var byteCount: Int {
        (textPlain?.utf8.count ?? 0) + (textHTML?.utf8.count ?? 0) + inlineImages.reduce(0) { $0 + $1.data.count }
    }
}

public struct GmailInlineImage: Codable, Hashable, Sendable {
    public var contentID: String
    public var mimeType: String
    public var data: Data

    public init(contentID: String, mimeType: String, data: Data) {
        self.contentID = contentID
        self.mimeType = mimeType
        self.data = data
    }
}

// MARK: - Conversation summaries

/// Enough of a conversation to draw its row and expand it without asking Gmail, kept for each
/// conversation with a message among the newest 1,000.
public struct GmailThreadSummary: Codable, Hashable, Sendable {
    public var threadID: GmailThreadID
    /// Oldest first, as Outlook lists them.
    public var senders: [EmailAddress]
    public var messageCount: Int
    public var newestDate: Date
    /// Oldest first.
    public var members: [GmailThreadMember]

    public init(threadID: GmailThreadID, senders: [EmailAddress], messageCount: Int, newestDate: Date,
                members: [GmailThreadMember] = []) {
        self.threadID = threadID
        self.senders = senders
        self.messageCount = messageCount
        self.newestDate = newestDate
        self.members = members
    }
}

public struct GmailThreadMember: Codable, Hashable, Sendable {
    public var id: GmailMessageID
    public var from: EmailAddress
    public var date: Date

    public init(id: GmailMessageID, from: EmailAddress, date: Date) {
        self.id = id
        self.from = from
        self.date = date
    }
}
