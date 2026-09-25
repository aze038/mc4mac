import Foundation

// The contracts between an account's mail engine and the rest of FalconMail: the list, message
// windows, actions, drafts and the app's routing. The Gmail engine serves Google accounts through
// them; the list also serves IMAP accounts' stored rows through `ListSource`, so the table,
// selection and windows work one way for every account.

// MARK: - The engine

/// One account's engine. It owns everything about the account's mail and is its only writer.
public protocol MailAccountEngine: AnyObject, Sendable {
    var accountID: UUID { get }
    /// The account's list, which the table reads its rows from.
    var listSource: any ListSource { get }

    func start() async
    func stop() async

    /// The one way to ask for a check for changes. At most one check runs at a time, and a poke
    /// during a check schedules exactly one more.
    func poke(reason: PokeReason) async
    /// How often checks run, and how much background work may take, follow the owner's activity.
    func noteOwnerActivity(_ activity: OwnerActivity) async
    func setUndoWindow(_ seconds: TimeInterval) async

    /// The account's folders as the sidebar shows them, with their counts.
    func folders() async -> [FolderInfo]
    /// The folders now, then again each time they or their counts change.
    func folderUpdates() async -> AsyncStream<[FolderInfo]>
    func createFolder(named name: String, parent: UUID?) async throws -> FolderInfo

    /// Shows the change at once, then holds it for the undo window and sends it. Throws only when
    /// the change cannot be made at all, such as Archive in Sent.
    func perform(_ request: MailActionRequest) async throws -> ActionReceipt
    /// Undoes a change: dropped unsent within the window, reversed as a new change after it.
    /// False when it can no longer be undone.
    func undo(_ receiptID: UUID) async -> Bool
    /// Whether any change still waits to reach the server, which keeps the switch between
    /// engines from moving until it has gone.
    func hasPendingChanges() async -> Bool
    /// Ends every undo window and sends what waits, for at most `seconds`, as at quit. True when
    /// nothing is left waiting.
    func flushPending(within seconds: TimeInterval) async -> Bool
    func runRulesOnInbox() async throws

    /// Searches the account's mail on the server, and the list shows the hits as the view
    /// `.search(id)`, as rows every action works on. While the owner types, only the matching ids
    /// are asked for; `fetchRows` fetches the text of hits not known yet as well.
    func search(_ query: String, id: UUID, fetchRows: Bool) async throws
    func endSearch(_ id: UUID) async

    /// The message's text first, then again with its inline pictures once they have arrived.
    func open(_ key: RowKey, purpose: OpenPurpose) async -> AsyncThrowingStream<OpenedMessage, Error>
    func attachmentData(_ attachment: GmailAttachmentStub, of key: RowKey) async throws -> Data
    /// The whole message as Gmail holds it, for View Source, Save as .eml and forwarding it as
    /// an attachment. It is held in memory only.
    func rawMessage(_ key: RowKey) async throws -> Data

    /// Saves a draft to the server: created the first time, updated after. The copy on the Mac
    /// may be deleted only once this returns, since only then does the server have it.
    func saveDraft(_ raw: Data, as draft: DraftRef) async throws -> DraftRef
    /// Deletes the server's copy for good: Gmail keeps nothing in Deleted Items. Discard calls it
    /// only once its undo window has ended.
    func deleteDraft(_ draft: DraftRef) async throws

    /// Imports into a folder, calling `progress` with the number done so far.
    func importMessages(_ messages: [ImportedMessage], into folderID: UUID,
                        progress: @escaping @Sendable (Int) -> Void) async throws
}

/// Why a check for changes was asked for.
public enum PokeReason: String, Hashable, Sendable, CaseIterable {
    /// The regular interval: every 30 seconds while the owner is active, every 2 minutes when not.
    case schedule
    /// The owner's Send & Receive.
    case sendAndReceive
    /// The Mac woke from sleep.
    case wake
    /// The network changed, or came back.
    case networkChange
    /// A message went out a moment ago, so Sent and its conversation are worth a look.
    case messageSent
    /// Gmail confirmed a change the owner made.
    case changeCommitted

    /// Whether the check says it has started and finished. A check every half minute must not
    /// make the status line flicker, so only the owner's own request and waking do.
    public var reportsProgress: Bool { self == .sendAndReceive || self == .wake }

    /// Whether the check ends by saying if it found new mail, which Send & Receive's sounds wait for.
    public var reportsNewMail: Bool { self == .sendAndReceive }
}

/// What the owner is doing, which sets how often checks run.
public enum OwnerActivity: Hashable, Sendable {
    /// Input at this moment, in FalconMail or any other app.
    case active(at: Date)
    /// No input since this moment, or the screen locked then.
    case idle(since: Date)
    /// Asleep: nothing is checked until the Mac wakes.
    case asleep
}

/// The order in which work may take the account's API budget. Checks for changes and the fetch
/// of new mail come first, so no amount of scrolling can delay new mail.
public enum WorkClass: Hashable, Sendable, Comparable {
    /// Change checks, fetching mail that arrived, and the look at the top while a resync runs.
    case checks
    /// What the owner is waiting for: visible rows, opens, attachments, actions, sends, drafts
    /// and search.
    case interactive
    /// Actions on a whole view, which give way to everything the owner is waiting for.
    case bulk
    /// Work nobody is waiting for, ranked, which never takes the budget below a reserve.
    case background(BackgroundWork)

    public var isBackground: Bool {
        if case .background = self { return true }
        return false
    }
}

/// Background work, most wanted first.
public enum BackgroundWork: Int, Hashable, Sendable, Comparable, CaseIterable {
    /// One screen ahead of the scroll, once it settles.
    case readAhead
    /// Filling the newest 1,000 kept on the Mac, and conversation summaries.
    case cacheFill
    /// Listing the mailbox for its index, and date anchors.
    case index
    /// Imports and the archive job.
    case transfer

    public static func < (a: BackgroundWork, b: BackgroundWork) -> Bool { a.rawValue < b.rawValue }
}

// MARK: - The list

public enum ListFilter: String, Hashable, Sendable, CaseIterable, Codable {
    case unread, flagged, attachments, focused, other, mentionsMe
}

/// What a list can be sorted by. The raw values are those of the app's own sort menu.
public enum ListSortKey: String, Hashable, Sendable, CaseIterable, Codable {
    case date, from, to, subject, size, flag, status, attachments, account, folder
}

public struct ListSortSpec: Hashable, Sendable, Codable {
    public var key: ListSortKey
    public var ascending: Bool

    public init(key: ListSortKey, ascending: Bool) {
        self.key = key
        self.ascending = ascending
    }

    public static let newestFirst = ListSortSpec(key: .date, ascending: false)
}

/// One way of looking at mail: which messages, filtered and sorted how, and grouped how.
public struct ListView: Hashable, Sendable {
    public enum Scope: Hashable, Sendable {
        case folder(UUID)
        case allInboxes
        /// The results of one search, named by the id the search was started with.
        case search(UUID)
    }

    public var scope: Scope
    public var filters: Set<ListFilter>
    public var sort: ListSortSpec
    public var conversations: Bool
    /// Outlook's "Show in groups": Today, Yesterday and so on.
    public var dateGroups: Bool

    /// Conversations with no date groups is the look of the owner's Outlook, and the default.
    public init(scope: Scope, filters: Set<ListFilter> = [], sort: ListSortSpec = .newestFirst,
                conversations: Bool = true, dateGroups: Bool = false) {
        self.scope = scope
        self.filters = filters
        self.sort = sort
        self.conversations = conversations
        self.dateGroups = dateGroups
    }
}

/// Outlook's size bands, the same limits as the list's Size sort: under 25 KB, under 100 KB,
/// under 1 MB, under 5 MB, and 5 MB and over.
public enum SizeBand: UInt8, Hashable, Sendable, CaseIterable, Comparable {
    case tiny, small, medium, large, huge

    public init(bytes: Int) {
        switch bytes {
        case ..<25_000: self = .tiny
        case ..<100_000: self = .small
        case ..<1_000_000: self = .medium
        case ..<5_000_000: self = .large
        default: self = .huge
        }
    }

    public static func < (a: SizeBand, b: SizeBand) -> Bool { a.rawValue < b.rawValue }
}

public enum DisplayKind: UInt8, Hashable, Sendable {
    /// One message.
    case message
    /// A conversation: every message of the view in one Gmail thread, where its newest sits.
    case conversation
    /// One compact line of an expanded conversation, which may be in another folder.
    case child
    /// A group header, such as a date group.
    case header
}

/// What a row shows without its text: everything the index knows, so a row not yet fetched is
/// drawn with its unread dot, flag and clip already right.
public struct DisplayBits: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let unread = DisplayBits(rawValue: 1 << 0)
    public static let flagged = DisplayBits(rawValue: 1 << 1)
    public static let hasAttachment = DisplayBits(rawValue: 1 << 2)
    /// Whether `hasAttachment` is known; it is learnt only when first needed.
    public static let attachmentKnown = DisplayBits(rawValue: 1 << 3)
    public static let draft = DisplayBits(rawValue: 1 << 4)
    /// A draft saved on the Mac while Gmail could not be reached, not yet on Gmail.
    public static let provisional = DisplayBits(rawValue: 1 << 5)
    /// A conversation row whose members are shown below it.
    public static let expanded = DisplayBits(rawValue: 1 << 6)
    /// The row's `slot` indexes the snapshot's `storedKeys`: an IMAP account's stored row.
    public static let storedRow = DisplayBits(rawValue: 1 << 7)
    public static let inDeletedItems = DisplayBits(rawValue: 1 << 8)
    public static let inJunkEmail = DisplayBits(rawValue: 1 << 9)
    /// Whether `sizeBand` is known.
    public static let sizeKnown = DisplayBits(rawValue: 1 << 10)

    private static let sizeShift: UInt32 = 11
    private static let sizeMask: UInt32 = 0b111 << sizeShift
    /// Every bit `sizeBand` uses.
    public static let allSizeBands = DisplayBits(rawValue: sizeMask)
    /// Bits 16–31 are the list's own, for whatever it needs to draw.
    public static let listOwned = DisplayBits(rawValue: 0xFFFF_0000)

    /// Meaningful only with `sizeKnown`.
    public var sizeBand: SizeBand {
        get { SizeBand(rawValue: UInt8((rawValue & DisplayBits.sizeMask) >> DisplayBits.sizeShift)) ?? .tiny }
        set { self = DisplayBits(rawValue: (rawValue & ~DisplayBits.sizeMask) | (UInt32(newValue.rawValue) << DisplayBits.sizeShift)) }
    }
}

/// One row of a list, 24 bytes, so a view of 200,000 rows costs 4.8 MB. The fields are ordered
/// largest first: in any other order padding makes it 32.
public struct DisplayRecord: Hashable, Sendable {
    /// For a Google row, its Gmail message id; for a conversation, that of its newest member in
    /// the view. For a stored row, whatever number its source gives it.
    public var key: UInt64
    /// Where the source keeps the record, so it is read without a lookup: the index slot for a
    /// Google row, the place in the snapshot's `storedKeys` for a stored one, and -1 for a header.
    public var slot: Int32
    /// `DisplayBits`.
    public var bits: UInt32
    /// Messages the row stands for: 1, or a conversation's members in the view.
    public var members: UInt16
    /// How many of those are unread, for the conversation's count badge.
    public var unread: UInt16
    /// The group the row falls under; `ListSnapshot.headers` gives its title.
    public var group: UInt16
    /// `DisplayKind`.
    public var kind: UInt8
    /// The row's account, as a place in `ListSnapshot.sources`. It uses a byte that would
    /// otherwise be padding, so All Inboxes can say whose each row is.
    public var source: UInt8

    public init(key: UInt64, slot: Int32, bits: DisplayBits = [], members: UInt16 = 1, unread: UInt16 = 0,
                group: UInt16 = 0, kind: DisplayKind = .message, source: UInt8 = 0) {
        self.key = key
        self.slot = slot
        self.bits = bits.rawValue
        self.members = members
        self.unread = unread
        self.group = group
        self.kind = kind.rawValue
        self.source = source
    }

    public static func header(group: UInt16) -> DisplayRecord {
        DisplayRecord(key: 0, slot: -1, members: 0, group: group, kind: .header)
    }

    public var displayBits: DisplayBits {
        get { DisplayBits(rawValue: bits) }
        set { bits = newValue.rawValue }
    }

    public var displayKind: DisplayKind { DisplayKind(rawValue: kind) ?? .message }
}

/// An immutable picture of one view, built off the main thread. The table reads it without
/// waiting for anything.
public struct ListSnapshot: Sendable {
    public let view: ListView
    public let rows: ContiguousArray<DisplayRecord>
    /// Group titles by group number.
    public let headers: [Int: String]
    /// Every message of the view is listed. False while a folder is still being listed, when
    /// `itemCount` is Gmail's own count of the folder rather than the rows listed so far.
    public let complete: Bool
    /// The status bar's Items: the messages in the view, in Conversations view too, as Outlook
    /// counts them. Never the number of rows loaded.
    public let itemCount: Int
    /// The accounts whose rows the snapshot holds, which each row's `source` points into.
    public let sources: [UUID]
    /// Stored rows' ids, which their `slot` points into. Empty for a view of Google rows.
    public let storedKeys: [String]

    public init(view: ListView, rows: ContiguousArray<DisplayRecord>, headers: [Int: String] = [:],
                complete: Bool, itemCount: Int, sources: [UUID], storedKeys: [String] = []) {
        self.view = view
        self.rows = rows
        self.headers = headers
        self.complete = complete
        self.itemCount = itemCount
        self.sources = sources
        self.storedKeys = storedKeys
    }

    public static func empty(_ view: ListView) -> ListSnapshot {
        ListSnapshot(view: view, rows: [], complete: false, itemCount: 0, sources: [])
    }

    /// The key of the message a row stands for; nil for a header or a row out of range.
    public func rowKey(at index: Int) -> RowKey? {
        guard rows.indices.contains(index) else { return nil }
        let record = rows[index]
        if record.displayKind == .header { return nil }
        if record.displayBits.contains(.storedRow) {
            let slot = Int(record.slot)
            return storedKeys.indices.contains(slot) ? .stored(storedKeys[slot]) : nil
        }
        let source = Int(record.source)
        guard sources.indices.contains(source) else { return nil }
        return .gmail(account: sources[source], id: GmailMessageID(raw: record.key))
    }
}

/// How a view changed, for the table to animate. Removed indexes are in the old snapshot,
/// inserted and reloaded ones in the new, as `NSTableView` applies them.
public struct ListDiff: Sendable {
    public let inserted: IndexSet
    public let removed: IndexSet
    public let reloaded: IndexSet
    public let snapshot: ListSnapshot

    /// Past this many rows, animating costs more than reloading the table.
    public static let reloadThreshold = 500

    public init(inserted: IndexSet = [], removed: IndexSet = [], reloaded: IndexSet = [], snapshot: ListSnapshot) {
        self.inserted = inserted
        self.removed = removed
        self.reloaded = reloaded
        self.snapshot = snapshot
    }

    /// A diff that replaces every row, which the table applies as a reload.
    public static func replacing(_ old: ListSnapshot, with new: ListSnapshot) -> ListDiff {
        ListDiff(inserted: IndexSet(integersIn: 0..<new.rows.count), removed: IndexSet(integersIn: 0..<old.rows.count),
                 snapshot: new)
    }

    public var reloadsTable: Bool { inserted.count + removed.count + reloaded.count > ListDiff.reloadThreshold }
}

/// Whether a message can be shown. Only Gmail's 404 means gone; offline, or while Gmail has
/// asked FalconMail to wait, it is unavailable, and a window showing it stays open.
public enum RowAvailability: Sendable {
    case available(MessageSummary)
    case gone
    case unavailable(reason: String)
}

public enum RowPriority: Hashable, Sendable {
    /// On screen now.
    case visible
    /// One screen ahead in the direction of the scroll, once it has settled.
    case ahead
}

/// What a row shows beyond its bits: its text. Flags and folders are never part of it; they
/// always come from the index, so a row can lag behind but never contradict it.
public struct MessageRowContent: Hashable, Sendable {
    public var key: RowKey
    public var from: EmailAddress
    public var to: [EmailAddress]
    public var subject: String
    /// At most 100 characters.
    public var preview: String
    public var date: Date
    public var size: Int?
    public var hasAttachments: Bool?
    /// For a conversation row.
    public var conversation: ConversationContent?

    public init(key: RowKey, from: EmailAddress, to: [EmailAddress], subject: String, preview: String, date: Date,
                size: Int? = nil, hasAttachments: Bool? = nil, conversation: ConversationContent? = nil) {
        self.key = key
        self.from = from
        self.to = to
        self.subject = subject
        self.preview = preview
        self.date = date
        self.size = size
        self.hasAttachments = hasAttachments
        self.conversation = conversation
    }
}

public struct ConversationContent: Hashable, Sendable {
    /// Oldest first, as Outlook lists them.
    public var senders: [EmailAddress]
    public var messageCount: Int
    public var newestDate: Date
    /// For the expanded child rows, oldest first. Empty when only the senders are known.
    public var members: [ConversationMember]

    public init(senders: [EmailAddress], messageCount: Int, newestDate: Date, members: [ConversationMember] = []) {
        self.senders = senders
        self.messageCount = messageCount
        self.newestDate = newestDate
        self.members = members
    }
}

public struct ConversationMember: Hashable, Sendable {
    public var key: RowKey
    public var from: EmailAddress
    public var date: Date
    /// The sidebar name of the folder it is in when that is not the view's, such as Sent for the
    /// owner's own replies.
    public var folderName: String?

    public init(key: RowKey, from: EmailAddress, date: Date, folderName: String? = nil) {
        self.key = key
        self.from = from
        self.date = date
        self.folderName = folderName
    }
}

/// Where the list's rows come from: the Gmail engine for a Google account, the stored rows for
/// an IMAP one.
public protocol ListSource: AnyObject, Sendable {
    func snapshot(of view: ListView) async -> ListSnapshot
    /// A diff each time the view changes, for as long as the stream is kept.
    func changes(of view: ListView) -> AsyncStream<ListDiff>
    /// Asks for rows' text. It returns at once; the text arrives on `rows`.
    func requestRows(_ keys: [RowKey], priority: RowPriority)
    var rows: AsyncStream<[RowKey: MessageRowContent]> { get }
    /// What reply, forward, a message window and a notification need, with the folder the
    /// message is seen in taken from `view`.
    func summary(for key: RowKey, in view: ListView) async -> RowAvailability
}

// MARK: - Actions

/// A change the owner, or a rule, made to messages.
public struct MailActionRequest: Hashable, Sendable, Identifiable {
    public enum Verb: Hashable, Sendable {
        case markRead, markUnread
        case flag, unflag
        case archive
        case move(to: UUID)
        case copy(to: UUID)
        /// To Deleted Items; in Drafts, Discard.
        case delete
        /// For good, from Deleted Items or Junk Email, after the owner has confirmed it.
        case deleteForever
        case junk, notJunk
        case mute, unmute
        case moveToFocused, moveToOther
    }

    public var id: UUID
    public var verb: Verb
    public var targets: ActionTargets
    /// The view the action was taken in. The folder rules of each action are read from it, never
    /// from a stored row, because a Gmail message is in many folders at once.
    public var context: ListView
    /// A rule's action: no undo window, sent at once.
    public var isAutomatic: Bool
    public var date: Date

    public init(id: UUID = UUID(), verb: Verb, targets: ActionTargets, context: ListView,
                isAutomatic: Bool = false, date: Date = Date()) {
        self.id = id
        self.verb = verb
        self.targets = targets
        self.context = context
        self.isAutomatic = isAutomatic
        self.date = date
    }
}

public enum ActionItem: Hashable, Sendable {
    case message(RowKey)
    /// Every member of the conversation that the view holds.
    case conversation(RowKey)

    public var key: RowKey {
        switch self {
        case .message(let key), .conversation(let key): return key
        }
    }
}

public enum ActionTargets: Hashable, Sendable {
    case items([ActionItem])
    /// Everything in the view except these, as after Select All: described by the view, never by
    /// a list of every id in it.
    case wholeView(except: [ActionItem])

    /// Past this many selected rows, a command either acts on the whole view or refuses; it never
    /// acts on the first thousand and silently leaves the rest.
    public static let largestItemList = 1_000
}

/// What a change did, for the undo toast and the status line.
public struct ActionReceipt: Hashable, Sendable, Identifiable {
    /// The request's id, which Undo takes.
    public var id: UUID
    public var accountID: UUID
    public var verb: MailActionRequest.Verb
    /// Messages whose state the change really flips.
    public var messageCount: Int
    public var isUndoable: Bool
    /// When the undo window ends and the change is sent; nil when it was sent at once.
    public var heldUntil: Date?
    /// A sentence for the status line, such as "Moved to Clients. Gmail keeps a copy in Sent."
    public var notice: String?
    /// The folder names `notice` holds, which diagnostics take out of it.
    public var names: [String]

    public init(id: UUID, accountID: UUID, verb: MailActionRequest.Verb, messageCount: Int, isUndoable: Bool,
                heldUntil: Date? = nil, notice: String? = nil, names: [String] = []) {
        self.id = id
        self.accountID = accountID
        self.verb = verb
        self.messageCount = messageCount
        self.isUndoable = isUndoable
        self.heldUntil = heldUntil
        self.notice = notice
        self.names = names
    }
}

// MARK: - Opening

public enum OpenPurpose: Hashable, Sendable {
    /// The reading pane: the arrow keys pass over rows nobody reads, so the open waits for the
    /// selection to settle before it costs anything.
    case readingPane
    /// Double-click, Return or ⌘O: at once.
    case window
    /// Reply or Forward: at once.
    case replyOrForward

    public var waitsToSettle: Bool { self == .readingPane }
}

public struct OpenedMessage: Sendable {
    public var key: RowKey
    public var content: GmailOpenedMessage
    /// False while inline pictures are still on their way; another value follows with them.
    public var isComplete: Bool
    /// Read from the copy kept on this Mac: at no cost, and offline too.
    public var fromCache: Bool

    public init(key: RowKey, content: GmailOpenedMessage, isComplete: Bool, fromCache: Bool) {
        self.key = key
        self.content = content
        self.isComplete = isComplete
        self.fromCache = fromCache
    }
}

// MARK: - Drafts

/// One draft's link between the Mac and the server, kept for the draft's whole life so that
/// every save updates the same server draft instead of adding another.
public struct DraftRef: Codable, Hashable, Sendable {
    /// The draft on this Mac, and the value of its `X-FalconMail-Draft` header.
    public var localID: UUID
    public var accountID: UUID
    /// Gmail's draft id, once Gmail has the draft.
    public var gmailDraftID: String?
    /// The id of the message the draft is now. Gmail gives it a new one at every save.
    public var gmailMessageID: GmailMessageID?
    /// The conversation a reply or forward belongs to.
    public var threadID: GmailThreadID?
    /// One Message-ID for every save of the draft.
    public var stableMessageID: String

    public init(localID: UUID, accountID: UUID, gmailDraftID: String? = nil, gmailMessageID: GmailMessageID? = nil,
                threadID: GmailThreadID? = nil, stableMessageID: String) {
        self.localID = localID
        self.accountID = accountID
        self.gmailDraftID = gmailDraftID
        self.gmailMessageID = gmailMessageID
        self.threadID = threadID
        self.stableMessageID = stableMessageID
    }
}
