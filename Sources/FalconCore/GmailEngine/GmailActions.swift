import Foundation

// Actions on a Google account's mail, in Gmail's terms. Every change shows at once, is held for
// the undo window, and reaches Gmail as label changes: `messages.modify` for fewer than ten
// messages, `batchModify` in chunks of 1,000 for more. A Gmail message is in many folders at
// once, so what an action does is read from the folder it was taken in, never from a stored row:
// Archive in the Inbox removes INBOX, and Archive in a label removes that label.

// MARK: - Folders in Gmail's terms

/// The folder an action was taken in.
public enum GmailActionFolder: Hashable, Sendable {
    case inbox
    /// A search, which acts as the Inbox does.
    case search
    case userLabel(GmailLabelID)
    /// All Mail, which Outlook calls Archive: every message but Junk Email and Deleted Items.
    case archive
    case starred
    case important
    case sent
    case drafts
    case junkEmail
    case deletedItems

    /// The folder a Google account's sidebar folder shows; nil for a folder that is not one.
    public init?(folder: FolderInfo) {
        guard let label = folder.gmailLabelID else {
            guard folder.role == .all else { return nil }
            self = .archive
            return
        }
        switch label {
        case .inbox: self = .inbox
        case .sent: self = .sent
        case .draft: self = .drafts
        case .spam: self = .junkEmail
        case .trash: self = .deletedItems
        case .starred: self = .starred
        case .important: self = .important
        default:
            guard label.isUserLabel else { return nil }
            self = .userLabel(label)
        }
    }

    /// The label the folder shows; nil for Archive and a search, which have none.
    public var label: GmailLabelID? {
        switch self {
        case .inbox: return .inbox
        case .search, .archive: return nil
        case .userLabel(let label): return label
        case .starred: return .starred
        case .important: return .important
        case .sent: return .sent
        case .drafts: return .draft
        case .junkEmail: return .spam
        case .deletedItems: return .trash
        }
    }

    /// Whether a message in the index belongs in the folder's view. Every view leaves out Junk
    /// Email, Deleted Items and chats, except Junk Email and Deleted Items themselves.
    func shows(_ has: (GmailLabelID) -> Bool) -> Bool {
        if has(.chat) { return false }
        switch self {
        case .junkEmail: return has(.spam)
        case .deletedItems: return has(.trash)
        default:
            if has(.spam) || has(.trash) { return false }
            return label.map(has) ?? true
        }
    }
}

/// What a folder means as the destination of Move or Copy.
public enum GmailMoveDestination: Hashable, Sendable {
    /// The Inbox, Important or a user label: the label is added.
    case label(GmailLabelID)
    /// Moving to Archive is the Archive action.
    case archive
    /// Moving to Starred flags the message and takes it out of nothing.
    case starred
    /// Moving to Deleted Items is Delete.
    case deletedItems
    /// Moving to Junk Email is Junk.
    case junkEmail
}

/// Focused and Other follow Gmail's categories: Other is Promotions, Social and Forums, and
/// Focused everything else in the Inbox. One setting moves Updates to Other.
public struct GmailFocusRule: Hashable, Sendable {
    public var updatesAreOther: Bool

    public init(updatesAreOther: Bool = false) {
        self.updatesAreOther = updatesAreOther
    }

    public var otherCategories: Set<GmailLabelID> {
        updatesAreOther ? GmailLabelID.otherCategories.union([.categoryUpdates]) : GmailLabelID.otherCategories
    }

    /// Focused mail that carries a category of its own, which Move to Other takes away.
    public var focusedCategories: Set<GmailLabelID> {
        updatesAreOther ? [.categoryPersonal] : [.categoryPersonal, .categoryUpdates]
    }
}

/// Labels an action adds and removes. Each message changes only by what it really lacks or has:
/// a flag or Important is never removed unless the action is about it.
public struct GmailLabelRule: Hashable, Sendable {
    public var add: Set<GmailLabelID>
    public var remove: Set<GmailLabelID>
    /// When not empty, only messages carrying at least one of these change, as Not Junk changes
    /// only mail in Junk Email.
    public var onlyIfAny: Set<GmailLabelID>
    /// Messages carrying any of these do not change, as Move to Other leaves mail already there.
    public var unlessAny: Set<GmailLabelID>

    public init(add: Set<GmailLabelID> = [], remove: Set<GmailLabelID> = [], onlyIfAny: Set<GmailLabelID> = [],
                unlessAny: Set<GmailLabelID> = []) {
        self.add = add
        // A label both added and removed, as Move to Inbox from Archive would give, is added.
        self.remove = remove.subtracting(add)
        self.onlyIfAny = onlyIfAny
        self.unlessAny = unlessAny
    }

    /// Every label the rule looks at.
    public var consulted: Set<GmailLabelID> { add.union(remove).union(onlyIfAny).union(unlessAny) }

    /// What the rule changes on a message; nil when it changes nothing.
    public func delta(_ has: (GmailLabelID) -> Bool) -> (add: Set<GmailLabelID>, remove: Set<GmailLabelID>)? {
        if !onlyIfAny.isEmpty, !onlyIfAny.contains(where: has) { return nil }
        if unlessAny.contains(where: has) { return nil }
        let adding = add.filter { !has($0) }
        let removing = remove.filter(has)
        return adding.isEmpty && removing.isEmpty ? nil : (adding, removing)
    }

    public func delta(for labels: Set<GmailLabelID>) -> (add: Set<GmailLabelID>, remove: Set<GmailLabelID>)? {
        delta { labels.contains($0) }
    }
}

/// What an action comes to in one folder.
public enum GmailActionPlan: Hashable, Sendable {
    /// Labels added and removed. `notice` is a sentence for the status line, such as a move out
    /// of Sent, which Gmail keeps a copy of there.
    case labels(GmailLabelRule, notice: String?, names: [String])
    /// Delete in Drafts: the Gmail drafts are deleted once the undo window ends.
    case discardDrafts
    /// For good, from the folder with this label: Deleted Items or Junk Email.
    case deleteForever(GmailLabelID)
    /// The conversation's later mail is filed away too, and this mail now.
    case mute(GmailLabelRule)
    case unmute
    /// Nothing to do, as moving a message to the folder it is in.
    case nothing
}

/// Why an action cannot be done at all. The rows stay as they were and the sentence says why.
public struct GmailActionError: Error, LocalizedError, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        /// Not offered in this folder, such as Archive in Sent.
        case notAvailable
        /// Deleting for good cannot be undone, so it must be asked for as `deleteForever`,
        /// after the owner has confirmed it.
        case needsConfirmation
        /// More than 1,000 rows, which a command either takes as the whole view or refuses.
        case tooManySelected
        case unknownFolder
        case folderExists
        case emptyName
    }

    public var kind: Kind
    public var sentence: String
    /// Folder names the sentence holds, which diagnostics take out.
    public var names: [String]

    public init(_ kind: Kind, _ sentence: String, names: [String] = []) {
        self.kind = kind
        self.sentence = sentence
        self.names = names
    }

    public var errorDescription: String? { sentence }

    static let tooMany = GmailActionError(.tooManySelected, "Select 1,000 messages or fewer for this command.")
}

/// Outlook's actions by the folder they are used in, as the design's table gives them.
public enum GmailActionRules {
    /// What `verb` does in `folder`. `destination` is the resolved folder of a Move or Copy, and
    /// `destinationName` its sidebar name for the sentences.
    public static func plan(_ verb: MailActionRequest.Verb, in folder: GmailActionFolder,
                            to destination: GmailMoveDestination? = nil, destinationName: String? = nil,
                            focus: GmailFocusRule = GmailFocusRule()) throws -> GmailActionPlan {
        switch verb {
        case .markRead: return .labels(GmailLabelRule(remove: [.unread]), notice: nil, names: [])
        case .markUnread: return .labels(GmailLabelRule(add: [.unread]), notice: nil, names: [])
        case .flag: return .labels(GmailLabelRule(add: [.starred]), notice: nil, names: [])
        case .unflag: return .labels(GmailLabelRule(remove: [.starred]), notice: nil, names: [])
        case .archive: return try archive(in: folder)
        case .delete: return try delete(in: folder)
        case .deleteForever:
            switch folder {
            case .deletedItems: return .deleteForever(.trash)
            case .junkEmail: return .deleteForever(.spam)
            default:
                throw GmailActionError(.notAvailable, "Messages are deleted for good only from Deleted Items or Junk Email.")
            }
        case .junk:
            if folder == .drafts { throw GmailActionError(.notAvailable, "A draft can't be marked as junk.") }
            if folder == .junkEmail { return .nothing }
            return .labels(GmailLabelRule(add: [.spam], remove: [.inbox]), notice: nil, names: [])
        case .notJunk:
            return .labels(GmailLabelRule(add: [.inbox], remove: [.spam], onlyIfAny: [.spam]), notice: nil, names: [])
        case .mute:
            if folder == .drafts { throw GmailActionError(.notAvailable, "A draft can't be muted.") }
            return .mute(GmailLabelRule(remove: [.unread, .inbox]))
        case .unmute:
            return .unmute
        case .moveToFocused:
            if folder == .drafts { throw GmailActionError(.notAvailable, "Move to Focused isn't available in Drafts.") }
            let other = focus.otherCategories
            return .labels(GmailLabelRule(add: [.categoryPersonal], remove: other, onlyIfAny: other), notice: nil, names: [])
        case .moveToOther:
            if folder == .drafts { throw GmailActionError(.notAvailable, "Move to Other isn't available in Drafts.") }
            return .labels(GmailLabelRule(add: [.categoryPromotions], remove: focus.focusedCategories, unlessAny: focus.otherCategories),
                           notice: nil, names: [])
        case .move:
            guard let destination else { throw GmailActionError(.unknownFolder, "That folder isn't there any more.") }
            return try move(in: folder, to: destination, named: destinationName)
        case .copy:
            guard let destination else { throw GmailActionError(.unknownFolder, "That folder isn't there any more.") }
            return try copy(in: folder, to: destination, named: destinationName)
        }
    }

    /// What a folder means as a Move or Copy destination. Drafts and Sent are refused, because
    /// Gmail does not let an app add either label.
    public static func destination(for folder: FolderInfo) throws -> GmailMoveDestination {
        guard let kind = GmailActionFolder(folder: folder) else {
            throw GmailActionError(.unknownFolder, "Messages can only be moved to a folder of the same Gmail account.")
        }
        switch kind {
        case .inbox: return .label(.inbox)
        case .important: return .label(.important)
        case .userLabel(let label): return .label(label)
        case .archive: return .archive
        case .starred: return .starred
        case .deletedItems: return .deletedItems
        case .junkEmail: return .junkEmail
        case .drafts:
            throw GmailActionError(.notAvailable, "Gmail doesn't let apps put messages in Drafts.")
        case .sent:
            throw GmailActionError(.notAvailable, "Gmail doesn't let apps put messages in Sent.")
        case .search:
            throw GmailActionError(.unknownFolder, "That folder isn't there any more.")
        }
    }

    /// Whether the Move palette offers `folder` for a Google account. Drafts and Sent never are.
    /// Every folder that is not a Google account's is left to the IMAP rules.
    public static func isMoveTarget(_ folder: FolderInfo) -> Bool {
        guard let label = folder.gmailLabelID else { return true }
        return !GmailLabelID.fixedByGmail.contains(label)
    }

    /// Whether `verb` can be used at all in `folder`, for greying out commands.
    public static func isAvailable(_ verb: MailActionRequest.Verb, in folder: GmailActionFolder) -> Bool {
        switch verb {
        case .move(let to), .copy(let to):
            _ = to
            return folder != .drafts
        default:
            do {
                _ = try plan(verb, in: folder, to: .label(.inbox))
                return true
            } catch let error as GmailActionError {
                // Delete in Deleted Items is offered: it asks first, then deletes for good.
                return error.kind == .needsConfirmation
            } catch {
                return false
            }
        }
    }

    private static func archive(in folder: GmailActionFolder) throws -> GmailActionPlan {
        let rule: GmailLabelRule
        switch folder {
        case .inbox, .search, .archive, .starred, .important: rule = GmailLabelRule(remove: [.inbox])
        case .userLabel(let label): rule = GmailLabelRule(remove: [label])
        case .junkEmail: rule = GmailLabelRule(remove: [.spam])
        case .deletedItems: rule = GmailLabelRule(remove: [.trash])
        case .sent: throw GmailActionError(.notAvailable, "Archive isn't available in Sent.")
        case .drafts: throw GmailActionError(.notAvailable, "Archive isn't available in Drafts.")
        }
        return .labels(rule, notice: nil, names: [])
    }

    private static func delete(in folder: GmailActionFolder) throws -> GmailActionPlan {
        switch folder {
        case .drafts: return .discardDrafts
        case .deletedItems:
            throw GmailActionError(.needsConfirmation, "Messages deleted from Deleted Items are gone for good, so FalconMail asks first.")
        case .junkEmail: return .labels(GmailLabelRule(add: [.trash], remove: [.spam]), notice: nil, names: [])
        default: return .labels(GmailLabelRule(add: [.trash]), notice: nil, names: [])
        }
    }

    private static func move(in folder: GmailActionFolder, to destination: GmailMoveDestination,
                             named name: String?) throws -> GmailActionPlan {
        if folder == .drafts { throw GmailActionError(.notAvailable, "A draft can't be moved to another folder.") }
        switch destination {
        case .archive:
            return try archive(in: folder)
        case .deletedItems:
            return folder == .deletedItems ? .nothing : try delete(in: folder)
        case .junkEmail:
            return folder == .junkEmail ? .nothing : try plan(.junk, in: folder)
        case .starred:
            return .labels(GmailLabelRule(add: [.starred]), notice: nil, names: [])
        case .label(let target):
            if folder.label == target { return .nothing }
            let removing: Set<GmailLabelID>
            switch folder {
            case .inbox, .search, .archive, .starred, .important: removing = [.inbox]
            case .userLabel(let label): removing = [label]
            case .junkEmail: removing = [.spam]
            case .deletedItems: removing = [.trash]
            case .sent:
                let shown = name ?? "the folder"
                return .labels(GmailLabelRule(add: [target]), notice: "Moved to \(shown). Gmail keeps a copy in Sent.",
                               names: name.map { [$0] } ?? [])
            case .drafts: return .nothing
            }
            return .labels(GmailLabelRule(add: [target], remove: removing), notice: nil, names: [])
        }
    }

    private static func copy(in folder: GmailActionFolder, to destination: GmailMoveDestination,
                             named name: String?) throws -> GmailActionPlan {
        if folder == .drafts { throw GmailActionError(.notAvailable, "A draft can't be copied to another folder.") }
        switch destination {
        case .archive:
            // Every message is in Archive already.
            return .nothing
        case .starred:
            return .labels(GmailLabelRule(add: [.starred]), notice: nil, names: [])
        case .label(let target):
            return folder.label == target ? .nothing : .labels(GmailLabelRule(add: [target]), notice: nil, names: [])
        case .deletedItems:
            throw GmailActionError(.notAvailable, "Messages can't be copied to Deleted Items. Delete moves them there.")
        case .junkEmail:
            throw GmailActionError(.notAvailable, "Messages can't be copied to Junk Email. Junk moves them there.")
        }
    }
}

// MARK: - What the engine gives the actions

/// What the account's engine does for its actions. It is the store's only writer, so changes
/// shown at once go through it, journaled with its cursor.
public protocol GmailActionsHost: AnyObject, Sendable {
    /// The history id the index has reached, which a change keeps as the point it was made at.
    func currentCursor() async -> HistoryID?
    /// The account's folders as the sidebar shows them, each Google folder with its label.
    func folders() async -> [FolderInfo]
    /// Applies changes to the index at once and redraws their rows. They must survive a
    /// relaunch, so the engine journals them with its current cursor.
    func applyLocally(_ changes: [GmailChange]) async
    /// Runs a check for changes now and returns once it is done. Deleting for good asks for one
    /// first, so a message restored on the phone a moment ago is seen to be restored.
    func checkForChanges() async
    /// Gmail has a change: a check soon settles the state.
    func changeCommitted() async
    /// A label was created, or one was found gone: the label table is read again.
    func labelsChanged() async
    /// Changes could not be squared with the history, which Gmail no longer keeps that far
    /// back: the account is listed again.
    func needsRelisting() async
    /// A sentence for the status line, with the folder names it holds.
    func notice(_ text: String, names: [String]) async
    /// The messages a view shows, for a change on a whole view the index cannot work out by
    /// itself, such as a search. Nil when the host cannot say.
    func messages(in view: ListView) async -> [GmailMessageID]?
    /// Gmail's draft ids for draft messages, where the engine knows them already.
    func draftIDs(for ids: [GmailMessageID]) async -> [GmailMessageID: String]
    /// The owner's own addresses, which rules never act on.
    func ownAddresses() async -> Set<String>
    /// Settings ▸ Reading: Updates counts as Other rather than Focused.
    func updatesAreOther() async -> Bool
}

extension GmailActionsHost {
    public func messages(in view: ListView) async -> [GmailMessageID]? { nil }
    public func draftIDs(for ids: [GmailMessageID]) async -> [GmailMessageID: String] { [:] }
    public func updatesAreOther() async -> Bool { false }
}

/// The time and the waiting the actions use, so tests can run a day, or seven minutes of bulk
/// work, in a moment.
public struct GmailActionClock: Sendable {
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (TimeInterval) async throws -> Void

    public init(now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (TimeInterval) async throws -> Void) {
        self.now = now
        self.sleep = sleep
    }

    public static let system = GmailActionClock(now: { Date() }, sleep: { seconds in
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(min(seconds, 86_400 * 7) * 1_000_000_000))
    })
}

/// Which labels changes still on their way to Gmail are about, message by message. While a
/// change waits, history records and listings leave those labels alone, so a row the owner has
/// just archived never comes back before his change reaches Gmail.
public struct GmailHeldLabels: Sendable {
    struct Group: Sendable {
        var labels: Set<GmailLabelID>
        var ids: Set<UInt64>
    }

    let groups: [Group]

    public static let none = GmailHeldLabels(groups: [])

    public var isEmpty: Bool { groups.isEmpty }

    public func labels(for id: GmailMessageID) -> Set<GmailLabelID> {
        var out: Set<GmailLabelID> = []
        for group in groups where group.ids.contains(id.raw) { out.formUnion(group.labels) }
        return out
    }
}

/// A change on a whole view on its way, such as Mark All as Read in a large folder.
public struct GmailBulkProgress: Hashable, Sendable {
    public var id: UUID
    public var verb: String
    public var done: Int
    public var total: Int
}

// MARK: - The actions

/// One Google account's changes: shown at once, held for the undo window, sent, retried until
/// they succeed or are refused, and kept in `pendingOps.json` until Gmail has them.
public actor GmailActions {
    public nonisolated let accountID: UUID
    let transport: any GmailTransport
    let store: any GmailStore
    let mutes: MuteStore
    let rules: RuleStore?
    let clock: GmailActionClock
    private let file: PendingGmailOpsFile
    private let bulkUnitsPerMinute: Int
    private(set) weak var host: (any GmailActionsHost)?
    private var undoWindow: TimeInterval
    private var canSave = true

    /// Changes not yet confirmed by Gmail, in the order they were made.
    private var ops: [PendingGmailOp] = []
    /// Changes Gmail has, kept a while so Undo can reverse them.
    private var sentOps: [PendingGmailOp] = []
    private var runtime: [UUID: Runtime] = [:]
    private var lanes: [Lane: Task<Void, Never>] = [:]
    /// Which run of each lane is the live one, so a lane left over from before a stop never
    /// sends beside a new one.
    private var laneRuns: [Lane: UUID] = [:]
    private var dozing: [Lane: Task<Void, Error>] = [:]
    private var flushing = false
    private var started = false
    private var stopped = false
    private var bulkLedger: [(at: Date, units: Int)] = []
    private var heldCache: GmailHeldLabels?
    /// Muted conversations whose subject and Message-IDs are still being fetched. Undo takes a
    /// conversation out, so a fetch that answers late never brings its record back.
    var awaitingMuteDetails: Set<String> = []
    /// History since the oldest change found at launch, read once for the gap check.
    private var gapHistory: (since: HistoryID, touched: [(history: HistoryID, id: UInt64)])?

    /// Whole-view changes run apart from the rest, so seven minutes of bulk work never holds up
    /// a flag the owner sets meanwhile.
    enum Lane: Hashable { case interactive, bulk }

    struct Runtime {
        var nextAttempt: Date?
        var failures = 0
        var inFlight = false
        var undoRequested = false
        /// Loaded at launch: history since the change was made is looked at before it is sent.
        var needsGapCheck = false
        /// Ids Gmail has confirmed, by group.
        var confirmed: [Int: Set<UInt64>] = [:]
        /// Ids a call was made for, answered or not, by group: what an Undo in the middle of
        /// sending has to reverse.
        var attempted: [Int: Set<UInt64>] = [:]
    }

    /// Undo after sending is offered for this long, and for at most this many changes.
    static let sentKeptFor: TimeInterval = PendingGmailOp.lifetime
    static let sentKept = 50
    /// Fewer messages than this go one `modify` each; more go in `batchModify` calls.
    static let batchFrom = 10
    static let batchSize = 1_000
    /// Past this many kept records, the messages' labels are read from Gmail instead.
    static let keptApplied = 50

    public init(accountID: UUID, transport: any GmailTransport, store: any GmailStore, mutes: MuteStore,
                rules: RuleStore? = nil, host: (any GmailActionsHost)? = nil, undoWindow: TimeInterval = 5,
                clock: GmailActionClock = .system, bulkUnitsPerMinute: Int = 1_500) {
        self.accountID = accountID
        self.transport = transport
        self.store = store
        self.mutes = mutes
        self.rules = rules
        self.host = host
        self.undoWindow = max(0, undoWindow)
        self.clock = clock
        self.bulkUnitsPerMinute = bulkUnitsPerMinute
        file = PendingGmailOpsFile(files: store.files)
    }

    public func attach(_ host: any GmailActionsHost) {
        self.host = host
    }

    public func setUndoWindow(_ seconds: TimeInterval) {
        undoWindow = max(0, seconds)
    }

    // MARK: Starting and stopping

    /// Reads the changes a previous run left. Those older than a day are dropped and their rows
    /// put back from Gmail's state; the rest show again and are sent at once, since their undo
    /// window ended with the run that made them. Before each is sent, the history since it was
    /// made is looked at, and a message someone has acted on since is left out of it.
    public func start() async {
        guard !started else { return }
        started = true
        stopped = false
        let loaded = file.load()
        canSave = loaded.canSave
        let now = clock.now()
        var kept: [PendingGmailOp] = []
        var expired: [PendingGmailOp] = []
        for var op in loaded.ops where !op.isCommitted {
            if now.timeIntervalSince(op.createdAt) > PendingGmailOp.lifetime {
                expired.append(op)
                continue
            }
            op.phase = .held(until: now)
            kept.append(op)
            runtime[op.id] = Runtime(needsGapCheck: op.knownAt != nil)
        }
        ops = kept
        invalidateHeld()
        if !expired.isEmpty {
            Log.info("gmail", "dropping \(expired.count) changes older than a day, \(expired.reduce(0) { $0 + $1.messageCount }) messages")
            for op in expired { await settle(Set(op.messageIDs.map(\.raw)), clearing: op.kind == .deleteForever) }
            // Written only once their rows are back, so a stop in the middle drops them again at
            // the next start rather than leave the rows as the change showed them.
            if !Task.isCancelled { save() }
        }
        for op in kept { await show(op) }
        if !kept.isEmpty { Log.info("gmail", "sending \(kept.count) changes left from the last run") }
        wakeLanes()
    }

    /// Stops sending. Whatever waits stays in `pendingOps.json` for the next start.
    public func stop() {
        stopped = true
        started = false
        for (_, task) in lanes { task.cancel() }
        for (_, task) in dozing { task.cancel() }
        lanes = [:]
        laneRuns = [:]
        dozing = [:]
    }

    public func hasPendingChanges() -> Bool { !ops.isEmpty }

    /// Ends every undo window and sends what waits, for at most `seconds`, as at quit. True when
    /// nothing is left waiting.
    public func flushPending(within seconds: TimeInterval) async -> Bool {
        guard !ops.isEmpty else { return true }
        flushing = true
        for id in runtime.keys { runtime[id]?.nextAttempt = nil }
        wakeLanes()
        // Quitting is about the wall clock, whatever clock the actions were given.
        let deadline = Date().addingTimeInterval(seconds)
        while !ops.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        flushing = false
        return ops.isEmpty
    }

    /// The network came back: changes waiting to retry try again now.
    public func networkChanged() {
        for id in runtime.keys where runtime[id]?.inFlight == false { runtime[id]?.nextAttempt = nil }
        wakeLanes()
    }

    // MARK: Changes held back

    /// Messages with a change waiting, which the cache keeps whatever their age. Changes on a
    /// whole view are left out: pinning 200,000 messages would crowd out everything else.
    public func pendingMessageIDs(limit: Int = 500) -> Set<GmailMessageID> {
        var out: Set<GmailMessageID> = []
        for op in ops where !op.isBulk {
            for id in op.messageIDs {
                guard out.count < limit else { return out }
                out.insert(id)
            }
        }
        return out
    }

    /// How far each change on a whole view has got, for the status bar's progress line.
    public func bulkProgress() -> [GmailBulkProgress] {
        ops.filter(\.isBulk).map { op in
            let done = (runtime[op.id]?.confirmed.values.reduce(0) { $0 + $1.count }) ?? 0
            return GmailBulkProgress(id: op.id, verb: op.verb, done: min(done, op.messageCount), total: op.messageCount)
        }
    }

    /// The labels each message's waiting changes are about. Listings and resyncs leave them alone.
    /// A message Gmail has confirmed already is not held: Gmail's state is the owner's for it.
    public func heldLabels() -> GmailHeldLabels {
        if let heldCache { return heldCache }
        var groups: [GmailHeldLabels.Group] = []
        for op in ops where op.kind == .labels {
            for (g, delta) in op.deltas.enumerated() where !delta.ids.isEmpty {
                let confirmed = runtime[op.id]?.confirmed[g] ?? []
                let waiting = confirmed.isEmpty ? Set(delta.ids.map(\.raw)) : Set(delta.ids.map(\.raw)).subtracting(confirmed)
                if !waiting.isEmpty { groups.append(GmailHeldLabels.Group(labels: delta.labels, ids: waiting)) }
            }
        }
        let held = GmailHeldLabels(groups: groups)
        heldCache = held
        return held
    }

    /// Takes out of a check's history records the label changes that touch a change of the
    /// owner's still on its way, and keeps them with it: the owner's change shows until Gmail has
    /// it. If the change ends without being sent, they are applied then, so nothing done on
    /// another device meanwhile is lost. A message deleted for good leaves every change.
    public func screen(_ records: [GmailHistoryRecord]) async -> [GmailHistoryRecord] {
        guard !ops.isEmpty else { return records }
        let held = heldLabels()
        var out: [GmailHistoryRecord] = []
        var gone: Set<UInt64> = []
        var keptAny = false
        for record in records {
            var screened = record
            for message in record.messagesDeleted { gone.insert(message.ref.id.raw) }
            if !held.isEmpty {
                screened.labelsAdded = record.labelsAdded.compactMap { change in
                    keep(change, added: true, at: record.id, held: held, kept: &keptAny)
                }
                screened.labelsRemoved = record.labelsRemoved.compactMap { change in
                    keep(change, added: false, at: record.id, held: held, kept: &keptAny)
                }
            }
            if !screened.isEmpty { out.append(screened) }
        }
        if !gone.isEmpty { drop(gone) }
        if keptAny || !gone.isEmpty { save() }
        return out
    }

    private func keep(_ change: GmailLabelChange, added: Bool, at history: HistoryID, held: GmailHeldLabels,
                      kept: inout Bool) -> GmailLabelChange? {
        let id = change.message.ref.id
        let touched = Set(change.labels).intersection(held.labels(for: id))
        guard !touched.isEmpty else { return change }
        var holding: Set<GmailLabelID> = []
        for i in ops.indices where ops[i].kind == .labels {
            for (g, delta) in ops[i].deltas.enumerated() where delta.ids.contains(id) {
                // Gmail has the owner's change for this message already: what comes now is its
                // echo, or someone's later change, and either is Gmail's state to show.
                if runtime[ops[i].id]?.confirmed[g]?.contains(id.raw) == true { continue }
                let mine = touched.intersection(delta.labels)
                guard !mine.isEmpty else { continue }
                ops[i].skippedRecords.append(PendingGmailOp.KeptRecord(history: history, id: id, added: added ? mine : [],
                                                                        removed: added ? [] : mine))
                holding.formUnion(mine)
                kept = true
                break
            }
        }
        let passed = change.labels.filter { !holding.contains($0) }
        return passed.isEmpty ? nil : GmailLabelChange(message: change.message, labels: passed)
    }

    /// Takes messages Gmail no longer has out of every change.
    private func drop(_ gone: Set<UInt64>) {
        for i in ops.indices {
            for g in ops[i].deltas.indices {
                ops[i].deltas[g].ids.removeAll { gone.contains($0.raw) }
            }
        }
        invalidateHeld()
    }

    // MARK: Performing

    /// Shows the change at once, then holds it for the undo window and sends it. Throws only
    /// when the change cannot be made at all, such as Archive in Sent; the rows are then left
    /// as they were.
    public func perform(_ request: MailActionRequest) async throws -> ActionReceipt {
        let folders = await host?.folders() ?? []
        let context = try folder(for: request.context, in: folders)
        var destination: GmailMoveDestination?
        var destinationName: String?
        switch request.verb {
        case .move(let to), .copy(let to):
            guard let target = folders.first(where: { $0.id == to }) else {
                throw GmailActionError(.unknownFolder, "That folder isn't there any more.")
            }
            guard target.accountID == accountID else {
                throw GmailActionError(.notAvailable, "Messages can only be moved to a folder of the same account.")
            }
            destination = try GmailActionRules.destination(for: target)
            destinationName = target.name
        default:
            break
        }
        let focus = GmailFocusRule(updatesAreOther: await host?.updatesAreOther() ?? false)
        let plan = try GmailActionRules.plan(request.verb, in: context, to: destination, destinationName: destinationName,
                                             focus: focus)
        if case .nothing = plan { return receipt(for: request, count: 0, undoable: false) }
        let snapshot = await store.index()
        let targets = try await targets(of: request, in: context, snapshot: snapshot, conversationsWhole: plan.isMuting)
        switch plan {
        case .nothing:
            return receipt(for: request, count: 0, undoable: false)
        case .unmute:
            let count = await unmute(targets, snapshot: snapshot)
            return receipt(for: request, count: count, undoable: false)
        case .labels(let rule, let notice, let names):
            let deltas = await deltas(for: targets, rule: rule, snapshot: snapshot)
            return await record(request, kind: .labels, deltas: deltas, context: context, notice: notice, names: names)
        case .mute(let rule):
            let deltas = await deltas(for: targets, rule: rule, snapshot: snapshot)
            let keys = await mute(targets, snapshot: snapshot)
            return await record(request, kind: .labels, deltas: deltas, context: context, notice: nil, names: [], mutedKeys: keys)
        case .discardDrafts:
            let drafts = targets.filter { labels(of: $0, in: snapshot)?.contains(.draft) ?? false }
            let deltas = drafts.isEmpty ? [] : [PendingGmailOp.Delta(add: [], remove: [.draft], ids: drafts)]
            return await record(request, kind: .discardDrafts, deltas: deltas, context: context, notice: nil, names: [])
        case .deleteForever(let label):
            let doomed = targets.filter { labels(of: $0, in: snapshot)?.contains(label) ?? false }
            let deltas = doomed.isEmpty ? [] : [PendingGmailOp.Delta(add: [], remove: [], ids: doomed)]
            return await record(request, kind: .deleteForever, deltas: deltas, context: context, notice: nil, names: [])
        }
    }

    private func receipt(for request: MailActionRequest, count: Int, undoable: Bool, heldUntil: Date? = nil,
                         notice: String? = nil, names: [String] = []) -> ActionReceipt {
        ActionReceipt(id: request.id, accountID: accountID, verb: request.verb, messageCount: count, isUndoable: undoable,
                      heldUntil: heldUntil, notice: notice, names: names)
    }

    /// Makes the change: saved first, so a quit from here on still sends it, then shown.
    private func record(_ request: MailActionRequest, kind: PendingGmailOp.Kind, deltas: [PendingGmailOp.Delta],
                        context: GmailActionFolder, notice: String?, names: [String],
                        mutedKeys: [String] = []) async -> ActionReceipt {
        let count = deltas.reduce(0) { $0 + $1.ids.count }
        let now = clock.now()
        guard count > 0 else {
            guard !mutedKeys.isEmpty, !request.isAutomatic else { return receipt(for: request, count: 0, undoable: false) }
            // A conversation muted with nothing left to file away: only its record changed, and
            // Undo takes that away again.
            keepForUndo(PendingGmailOp(id: request.id, kind: .labels, verb: "mute", deltas: [], contextLabel: context.label,
                                       createdAt: now, knownAt: nil, phase: .committed, mutedThreadKeys: mutedKeys))
            return receipt(for: request, count: 0, undoable: true, notice: notice, names: names)
        }
        let wholeView: PendingGmailOp.ViewPredicate?
        if case .wholeView(let except) = request.targets {
            wholeView = PendingGmailOp.ViewPredicate(label: context.label, filters: request.context.filters.sorted { $0.rawValue < $1.rawValue },
                                                     excluded: except.count)
        } else {
            wholeView = nil
        }
        // Mark All as Read has never been undone, and deleting for good cannot be.
        let markAllRead: Bool = {
            guard request.verb == .markRead, case .wholeView(let except) = request.targets else { return false }
            return except.isEmpty
        }()
        let undoable = !request.isAutomatic && kind != .deleteForever && !markAllRead
        let holds = undoable && undoWindow > 0
        let until = holds ? now.addingTimeInterval(undoWindow) : now
        let op = PendingGmailOp(id: request.id, kind: kind, verb: GmailActions.name(of: request.verb), deltas: deltas,
                                contextLabel: context.label, createdAt: now, knownAt: await host?.currentCursor(),
                                phase: .held(until: until), wholeView: wholeView, isAutomatic: request.isAutomatic,
                                isUndoable: undoable, names: names, mutedThreadKeys: mutedKeys)
        enqueue(op)
        await show(op)
        wakeLanes()
        return receipt(for: request, count: count, undoable: undoable, heldUntil: holds ? until : nil, notice: notice, names: names)
    }

    /// A change a rule or a muted conversation makes: no undo window, sent at once.
    func performAutomatically(_ verb: String, deltas: [PendingGmailOp.Delta]) async {
        let deltas = deltas.filter { !$0.ids.isEmpty }
        guard !deltas.isEmpty else { return }
        let now = clock.now()
        let op = PendingGmailOp(id: UUID(), kind: .labels, verb: verb, deltas: deltas, contextLabel: .inbox, createdAt: now,
                                knownAt: await host?.currentCursor(), phase: .held(until: now), isAutomatic: true, isUndoable: false)
        enqueue(op)
        await show(op)
        wakeLanes()
    }

    private func enqueue(_ op: PendingGmailOp) {
        ops.append(op)
        runtime[op.id] = Runtime()
        invalidateHeld()
        save()
    }

    static func name(of verb: MailActionRequest.Verb) -> String {
        switch verb {
        case .markRead: return "markRead"
        case .markUnread: return "markUnread"
        case .flag: return "flag"
        case .unflag: return "unflag"
        case .archive: return "archive"
        case .move: return "move"
        case .copy: return "copy"
        case .delete: return "delete"
        case .deleteForever: return "deleteForever"
        case .junk: return "junk"
        case .notJunk: return "notJunk"
        case .mute: return "mute"
        case .unmute: return "unmute"
        case .moveToFocused: return "moveToFocused"
        case .moveToOther: return "moveToOther"
        }
    }

    // MARK: Which messages

    private func folder(for view: ListView, in folders: [FolderInfo]) throws -> GmailActionFolder {
        switch view.scope {
        case .allInboxes: return .inbox
        case .search: return .search
        case .folder(let id):
            guard let info = folders.first(where: { $0.id == id }) else {
                throw GmailActionError(.unknownFolder, "The folder this was done in isn't there any more.")
            }
            guard info.accountID == accountID, let kind = GmailActionFolder(folder: info) else {
                throw GmailActionError(.unknownFolder, "The folder this was done in isn't one of this account's Gmail folders.")
            }
            return kind
        }
    }

    /// The messages a request acts on. A conversation row stands for the members its view shows;
    /// for Mute and Unmute, for the whole conversation. A whole view is worked out here, once, so
    /// mail that arrives later is left alone.
    private func targets(of request: MailActionRequest, in context: GmailActionFolder, snapshot: GmailIndexSnapshot,
                         conversationsWhole: Bool) async throws -> [GmailMessageID] {
        let membership: (Int32) -> Bool = { slot in
            let whole = conversationsWhole ? GmailActionFolder.archive : context
            return whole.shows { snapshot.record(atSlot: slot, has: $0) }
        }
        var threads: [UInt64: [Int32]]?
        func members(of id: GmailMessageID) -> [GmailMessageID] {
            guard let slot = snapshot.slotByID[id.raw] else { return [id] }
            if threads == nil {
                var built: [UInt64: [Int32]] = [:]
                for s in snapshot.byOrder { built[snapshot.records[Int(s)].threadID, default: []].append(s) }
                threads = built
            }
            let thread = snapshot.records[Int(slot)].threadID
            let found = (threads?[thread] ?? []).filter(membership).map { snapshot.records[Int($0)].gmailID }
            return found.isEmpty ? [id] : found.reversed()
        }
        func expand(_ items: [ActionItem]) -> [GmailMessageID] {
            var out: [GmailMessageID] = []
            var seen: Set<UInt64> = []
            for item in items {
                guard case .gmail(let account, let id) = item.key, account == accountID else { continue }
                let ids: [GmailMessageID]
                switch item {
                case .message: ids = [id]
                case .conversation: ids = members(of: id)
                }
                for id in ids where seen.insert(id.raw).inserted { out.append(id) }
            }
            return out
        }
        learnt = [:]
        switch request.targets {
        case .items(let items):
            guard items.count <= ActionTargets.largestItemList else { throw GmailActionError.tooMany }
            let ids = expand(items)
            let unknown = ids.filter { snapshot.slotByID[$0.raw] == nil }
            if !unknown.isEmpty { await learnLabels(of: unknown) }
            return ids
        case .wholeView(let except):
            let excluded = Set(expand(except).map(\.raw))
            if case .search = context {
                guard let listed = await host?.messages(in: request.context) else { throw GmailActionError.tooMany }
                return listed.filter { !excluded.contains($0.raw) }
            }
            if request.context.filters.contains(.mentionsMe) {
                guard let listed = await host?.messages(in: request.context) else { throw GmailActionError.tooMany }
                return listed.filter { !excluded.contains($0.raw) }
            }
            let focus = GmailFocusRule(updatesAreOther: await host?.updatesAreOther() ?? false)
            let filters = request.context.filters
            var out: [GmailMessageID] = []
            for slot in snapshot.byOrder.reversed() {
                let record = snapshot.records[Int(slot)]
                if record.attributes.contains(.provisional) || excluded.contains(record.id) { continue }
                let has: (GmailLabelID) -> Bool = { snapshot.record(atSlot: slot, has: $0) }
                guard context.shows(has), GmailActions.passes(filters, record: record, has: has, focus: focus) else { continue }
                out.append(record.gmailID)
            }
            return out
        }
    }

    static func passes(_ filters: Set<ListFilter>, record: GmailIndexRecord, has: (GmailLabelID) -> Bool,
                       focus: GmailFocusRule) -> Bool {
        for filter in filters {
            switch filter {
            case .unread: if !has(.unread) { return false }
            case .flagged: if !has(.starred) { return false }
            case .attachments: if !record.attributes.contains(.hasAttachment) { return false }
            case .focused: if !has(.inbox) || focus.otherCategories.contains(where: has) { return false }
            case .other: if !has(.inbox) || !focus.otherCategories.contains(where: has) { return false }
            case .mentionsMe: return false
            }
        }
        return true
    }

    /// Labels of messages the index does not hold yet, such as a search hit not yet placed.
    private var learnt: [UInt64: Set<GmailLabelID>] = [:]

    private func learnLabels(of ids: [GmailMessageID]) async {
        for chunk in stride(from: 0, to: ids.count, by: 25).map({ Array(ids[$0..<min($0 + 25, ids.count)]) }) {
            guard let answers = try? await transport.batch(chunk.map { .message($0, .minimal) }, work: .interactive) else { continue }
            for id in chunk {
                if case .success(let answer)? = answers[.message(id, .minimal)], let message = answer.message {
                    learnt[id.raw] = message.labels
                }
            }
        }
    }

    private func labels(of id: GmailMessageID, in snapshot: GmailIndexSnapshot) -> Set<GmailLabelID>? {
        if let slot = snapshot.slotByID[id.raw] { return snapshot.labels(atSlot: slot) }
        return learnt[id.raw]
    }

    /// Each message's own change, grouped by what it is, since one `batchModify` applies the
    /// same labels to every id. A message the rule does not change is left out.
    private func deltas(for ids: [GmailMessageID], rule: GmailLabelRule, snapshot: GmailIndexSnapshot) async -> [PendingGmailOp.Delta] {
        struct Key: Hashable { var add: [GmailLabelID]; var remove: [GmailLabelID] }
        var order: [Key] = []
        var grouped: [Key: [GmailMessageID]] = [:]
        for id in ids {
            let has: (GmailLabelID) -> Bool
            if let slot = snapshot.slotByID[id.raw] {
                has = { snapshot.record(atSlot: slot, has: $0) }
            } else if let known = learnt[id.raw] {
                has = { known.contains($0) }
            } else {
                continue
            }
            guard let change = rule.delta(has) else { continue }
            let key = Key(add: change.add.sorted(), remove: change.remove.sorted())
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(id)
        }
        return order.map { PendingGmailOp.Delta(add: Set($0.add), remove: Set($0.remove), ids: grouped[$0] ?? []) }
    }

    // MARK: Showing

    /// Applies a change to the index at once. Applying it again is harmless, which a launch
    /// relies on.
    private func show(_ op: PendingGmailOp, only: Set<UInt64>? = nil) async {
        var changes: [GmailChange] = []
        for delta in op.deltas {
            for id in delta.ids where only?.contains(id.raw) ?? true {
                switch op.kind {
                case .labels, .discardDrafts: changes.append(.relabel(id, adding: delta.add, removing: delta.remove))
                case .deleteForever: changes.append(.attributes(id, setting: .provisional, clearing: []))
                }
            }
        }
        await apply(changes)
    }

    /// Puts rows back as they were before the change.
    private func unshow(_ op: PendingGmailOp, only: Set<UInt64>? = nil) async {
        var changes: [GmailChange] = []
        for delta in op.deltas {
            for id in delta.ids where only?.contains(id.raw) ?? true {
                switch op.kind {
                case .labels, .discardDrafts: changes.append(.relabel(id, adding: delta.remove, removing: delta.add))
                case .deleteForever: changes.append(.attributes(id, setting: [], clearing: .provisional))
                }
            }
        }
        await apply(changes)
    }

    private func apply(_ changes: [GmailChange]) async {
        guard let host, !changes.isEmpty else { return }
        // In slices, so a change on a whole view never builds one enormous journal batch.
        for start in stride(from: 0, to: changes.count, by: 5_000) {
            await host.applyLocally(Array(changes[start..<min(start + 5_000, changes.count)]))
        }
    }

    /// Kept history records, applied when the change they were kept for ends without being sent.
    /// Past a few dozen, the messages' labels are read from Gmail instead.
    private func applyKept(_ records: [PendingGmailOp.KeptRecord]) async {
        guard !records.isEmpty else { return }
        if records.count > GmailActions.keptApplied {
            await settle(Set(records.map(\.id.raw)))
            return
        }
        let ordered = records.sorted { $0.history < $1.history }
        await apply(ordered.map { .relabel($0.id, adding: $0.added, removing: $0.removed) })
    }

    /// Makes the index hold Gmail's own labels for `ids`, as after a change was dropped. A
    /// message Gmail no longer has leaves the index. Past a thousand, the account is listed
    /// again instead, which costs far less than reading each message.
    private func settle(_ ids: Set<UInt64>, clearing clearsProvisional: Bool = false) async {
        guard !ids.isEmpty else { return }
        guard ids.count <= 1_000 else {
            await host?.needsRelisting()
            return
        }
        let snapshot = await store.index()
        let list = ids.sorted().map(GmailMessageID.init(raw:))
        var changes: [GmailChange] = []
        for start in stride(from: 0, to: list.count, by: 25) {
            let chunk = Array(list[start..<min(start + 25, list.count)])
            guard let answers = try? await transport.batch(chunk.map { .message($0, .minimal) }, work: .interactive) else {
                // Gmail cannot be asked now: the next resync puts them right.
                continue
            }
            for id in chunk {
                guard let record = snapshot.record(for: id) else { continue }
                switch answers[.message(id, .minimal)] {
                case .success(let answer)?:
                    guard let message = answer.message else { continue }
                    var attributes = record.attributes
                    if clearsProvisional { attributes.remove(.provisional) }
                    changes.append(.place(record.ref, order: record.order, labels: message.labels, attributes: attributes))
                case .failure(let error)? where error.kind == .notFound:
                    changes.append(.tombstone(id))
                default:
                    continue
                }
            }
        }
        await apply(changes)
    }

    // MARK: Undo

    /// Undoes a change: dropped unsent within the window, reversed as a new change after it.
    /// False when it can no longer be undone.
    public func undo(_ id: UUID) async -> Bool {
        if let i = ops.firstIndex(where: { $0.id == id }) {
            let op = ops[i]
            guard op.isUndoable else { return false }
            if op.isHeld {
                ops.remove(at: i)
                runtime[id] = nil
                invalidateHeld()
                save()
                await unshow(op)
                await unmuteAdded(op)
                await applyKept(op.skippedRecords)
                return true
            }
            // A deleted draft or a message deleted for good cannot be brought back, and Gmail
            // refuses to add DRAFT, so only label changes are reversed once on their way.
            guard op.kind == .labels else { return false }
            // Already on its way: whatever reached Gmail is reversed once the call answers.
            runtime[id, default: Runtime()].undoRequested = true
            await unshow(op)
            await unmuteAdded(op)
            if runtime[id]?.inFlight != true { await replaceWithReverse(id) }
            wakeLanes()
            return true
        }
        guard let i = sentOps.firstIndex(where: { $0.id == id }) else { return false }
        let op = sentOps.remove(at: i)
        guard op.isUndoable, op.kind == .labels,
              clock.now().timeIntervalSince(op.createdAt) < GmailActions.sentKeptFor else { return false }
        let reverse = await reversed(op, ids: nil)
        if !reverse.deltas.isEmpty {
            enqueue(reverse)
            await show(reverse)
        }
        await unmuteAdded(op)
        wakeLanes()
        return true
    }

    /// The change reversed, as a new change sent at once and not itself undone. `ids` limits it,
    /// by group, to the messages a call was made for.
    private func reversed(_ op: PendingGmailOp, ids: [Int: Set<UInt64>]?, keeping kept: [PendingGmailOp.KeptRecord] = [])
        async -> PendingGmailOp {
        let now = clock.now()
        var deltas: [PendingGmailOp.Delta] = []
        for (g, delta) in op.deltas.enumerated() {
            var back = delta.reversed
            if let ids { back.ids = delta.ids.filter { ids[g]?.contains($0.raw) ?? false } }
            if !back.ids.isEmpty { deltas.append(back) }
        }
        return PendingGmailOp(id: UUID(), kind: .labels, verb: "undo-" + op.verb, deltas: deltas, contextLabel: op.contextLabel,
                              createdAt: now, knownAt: await host?.currentCursor(), phase: .held(until: now),
                              wholeView: op.wholeView, skippedRecords: kept, isAutomatic: true, isUndoable: false,
                              names: op.names)
    }

    /// An Undo that came while a change was being sent, and the call has answered: what may have
    /// reached Gmail is reversed, and the rest is simply not sent. The rows already show the
    /// state before the change.
    private func replaceWithReverse(_ id: UUID) async {
        guard let i = ops.firstIndex(where: { $0.id == id }) else { return }
        let op = ops[i]
        let attempted = runtime[id]?.attempted ?? [:]
        // Records kept while the change waited go with the reversal: read back from Gmail once it
        // is sent, or applied if it is refused.
        let reverse = await reversed(op, ids: attempted, keeping: op.skippedRecords)
        guard let j = ops.firstIndex(where: { $0.id == id }) else { return }
        ops.remove(at: j)
        runtime[id] = nil
        if !reverse.deltas.isEmpty {
            ops.insert(reverse, at: j)
            runtime[reverse.id] = Runtime()
        }
        invalidateHeld()
        save()
        if reverse.deltas.isEmpty { await applyKept(op.skippedRecords) }
    }

    // MARK: Sending

    private func lane(of op: PendingGmailOp) -> Lane { op.isBulk ? .bulk : .interactive }

    private func wakeLanes() {
        guard started, !stopped else { return }
        for lane in [Lane.interactive, .bulk] {
            dozing[lane]?.cancel()
            guard lanes[lane] == nil, ops.contains(where: { self.lane(of: $0) == lane }) else { continue }
            let run = UUID()
            laneRuns[lane] = run
            lanes[lane] = Task { await self.run(lane, run: run) }
        }
    }

    private func run(_ lane: Lane, run: UUID) async {
        defer {
            if laneRuns[lane] == run {
                lanes[lane] = nil
                laneRuns[lane] = nil
            }
        }
        while !stopped, !Task.isCancelled, laneRuns[lane] == run {
            let now = clock.now()
            switch next(in: lane, at: now) {
            case .none:
                return
            case .wait(let until):
                await doze(lane, for: until.timeIntervalSince(now))
            case .send(let id):
                await attempt(id, lane: lane)
            }
        }
    }

    private enum Next { case none, wait(until: Date), send(UUID) }

    /// The oldest change that is ready to go. A later change may go before an earlier one that
    /// still waits, as a rule's change before the undo window of an archive ends, but never when
    /// they share a message: each message's changes reach Gmail in the order they were made.
    private func next(in lane: Lane, at now: Date) -> Next {
        var blocked: Set<UInt64> = []
        var earliest: Date?
        for op in ops where self.lane(of: op) == lane {
            var ready = now
            if case .held(let until) = op.phase, !flushing { ready = max(ready, until) }
            if let next = runtime[op.id]?.nextAttempt { ready = max(ready, next) }
            let isReady = ready <= now && runtime[op.id]?.inFlight != true
            if isReady, blocked.isEmpty { return .send(op.id) }
            let ids = op.messageIDs.map(\.raw)
            if isReady, blocked.isDisjoint(with: ids) { return .send(op.id) }
            if !isReady { earliest = min(earliest ?? ready, ready) }
            blocked.formUnion(ids)
        }
        guard let earliest else { return .none }
        return .wait(until: max(earliest, now.addingTimeInterval(0.001)))
    }

    private func doze(_ lane: Lane, for seconds: TimeInterval) async {
        let clock = clock
        let sleeper = Task { try await clock.sleep(seconds) }
        dozing[lane] = sleeper
        _ = try? await sleeper.value
        if dozing[lane] == sleeper { dozing[lane] = nil }
    }

    private enum Outcome {
        case sent
        case retry(after: TimeInterval, GoogleAPIError?)
        case refused(GoogleAPIError, sentence: String, names: [String])
        /// Undo came while it was being sent: stop, and reverse what went.
        case undone
        case cancelled
    }

    private func attempt(_ id: UUID, lane: Lane) async {
        guard let op = ops.first(where: { $0.id == id }) else { return }
        if clock.now().timeIntervalSince(op.createdAt) > PendingGmailOp.lifetime {
            await expire(id)
            return
        }
        if runtime[id]?.needsGapCheck == true {
            switch await gapCheck(id) {
            case .checked: break
            case .retry(let after):
                runtime[id]?.nextAttempt = clock.now().addingTimeInterval(after)
                return
            case .dropped:
                return
            }
        }
        guard let index = ops.firstIndex(where: { $0.id == id }) else { return }
        runtime[id, default: Runtime()].inFlight = true
        ops[index].phase = .committing(attempt: (runtime[id]?.failures ?? 0) + 1)
        save()
        let outcome: Outcome
        switch op.kind {
        case .labels: outcome = await sendLabels(id, lane: lane)
        case .discardDrafts: outcome = await sendDiscard(id)
        case .deleteForever: outcome = await sendDeleteForever(id, lane: lane)
        }
        runtime[id]?.inFlight = false
        switch outcome {
        case .sent:
            await committed(id)
        case .retry(let after, let error):
            if runtime[id]?.undoRequested == true {
                await replaceWithReverse(id)
                return
            }
            runtime[id]?.failures += 1
            runtime[id]?.nextAttempt = clock.now().addingTimeInterval(after)
            Log.info("gmail", "change \(op.verb) waits \(Int(after.rounded())) s to retry: \(error.map { $0.kind.rawValue } ?? "no answer")")
        case .refused(let error, let sentence, let names):
            await refused(id, error: error, sentence: sentence, names: names)
        case .undone:
            await replaceWithReverse(id)
        case .cancelled:
            return
        }
    }

    private func work(for lane: Lane) -> WorkClass { lane == .bulk ? .bulk : .interactive }

    private func markAttempted(_ id: UUID, group: Int, _ ids: [GmailMessageID]) {
        runtime[id, default: Runtime()].attempted[group, default: []].formUnion(ids.map(\.raw))
    }

    private func markConfirmed(_ id: UUID, group: Int, _ ids: [GmailMessageID]) {
        runtime[id, default: Runtime()].confirmed[group, default: []].formUnion(ids.map(\.raw))
        invalidateHeld()
    }

    private func sendLabels(_ id: UUID, lane: Lane) async -> Outcome {
        var g = 0
        while true {
            guard let op = ops.first(where: { $0.id == id }) else { return .sent }
            guard g < op.deltas.count else { return .sent }
            if runtime[id]?.undoRequested == true { return .undone }
            let delta = op.deltas[g]
            let done = runtime[id]?.confirmed[g] ?? []
            let remaining = delta.ids.filter { !done.contains($0.raw) }
            if remaining.isEmpty {
                g += 1
                continue
            }
            if remaining.count < GmailActions.batchFrom {
                let message = remaining[0]
                markAttempted(id, group: g, [message])
                do {
                    _ = try await transport.modify(message, adding: delta.add, removing: delta.remove, work: work(for: lane))
                    markConfirmed(id, group: g, [message])
                } catch {
                    if let outcome = await handle(error, sending: [message], delta: delta, op: id) { return outcome }
                }
            } else {
                let chunk = Array(remaining.prefix(GmailActions.batchSize))
                if lane == .bulk { await admitBulk(GmailMethod.messagesBatchModify.units) }
                if stopped { return .cancelled }
                markAttempted(id, group: g, chunk)
                do {
                    try await transport.batchModify(chunk, adding: delta.add, removing: delta.remove, work: work(for: lane))
                    markConfirmed(id, group: g, chunk)
                } catch {
                    if let outcome = await handle(error, sending: chunk, delta: delta, op: id) { return outcome }
                }
            }
        }
    }

    /// Sorts a failed call. Nil when the messages Gmail no longer has were taken out of the
    /// change and the rest can be sent again at once.
    private func handle(_ error: Error, sending ids: [GmailMessageID], delta: PendingGmailOp.Delta, op: UUID) async -> Outcome? {
        switch disposition(of: error, for: op) {
        case .cancelled: return .cancelled
        case .retry(let after, let refusal): return .retry(after: after, refusal)
        case .refused(let refusal):
            return .refused(refusal, sentence: GmailActions.refusedSentence(refusal), names: [])
        case .notFound(let refusal):
            if let gone = await goneLabel(among: delta.labels) {
                await host?.labelsChanged()
                let name = await folderName(of: gone)
                return .refused(refusal, sentence: "The folder “\(name)” no longer exists on the server.", names: [name])
            }
            // A message that went meanwhile: it leaves the change and the list. One that is still
            // there means the refusal was about something else.
            var gone: [GmailMessageID] = []
            for start in stride(from: 0, to: ids.count, by: 25) {
                let chunk = Array(ids[start..<min(start + 25, ids.count)])
                let answers: [GmailBatchPart: Result<GmailBatchAnswer, GoogleAPIError>]
                do {
                    answers = try await transport.batch(chunk.map { .message($0, .minimal) }, work: .interactive)
                } catch {
                    if case .retry(let after, let refusal) = disposition(of: error, for: op) { return .retry(after: after, refusal) }
                    return .retry(after: backoff(for: op), refusal)
                }
                for id in chunk {
                    if case .failure(let e)? = answers[.message(id, .minimal)], e.kind == .notFound { gone.append(id) }
                }
            }
            guard !gone.isEmpty else {
                return .refused(refusal, sentence: GmailActions.refusedSentence(refusal), names: [])
            }
            Log.info("gmail", "\(gone.count) messages of a change were gone from Gmail; left out of it")
            drop(Set(gone.map(\.raw)))
            save()
            await apply(gone.map { .tombstone($0) })
            return nil
        }
    }

    private enum Disposition {
        case retry(after: TimeInterval, GoogleAPIError?)
        case refused(GoogleAPIError)
        case notFound(GoogleAPIError)
        case cancelled
    }

    /// Adding or removing a label is idempotent, so anything that might be temporary is tried
    /// again, however long it takes within the change's day: a 403 for a rate or a quota never
    /// puts the owner's rows back. Only a definite refusal does.
    private func disposition(of error: Error, for id: UUID) -> Disposition {
        if error is CancellationError || stopped { return .cancelled }
        guard let refusal = error as? GoogleAPIError else {
            return .retry(after: backoff(for: id), nil)
        }
        switch refusal.kind {
        case .notFound: return .notFound(refusal)
        case .rateLimited, .downloadLimit, .uploadLimit, .sendingLimit:
            return .retry(after: max(1, refusal.retryAfter ?? backoff(for: id)), refusal)
        case .quotaExhausted:
            // A daily cap waits for midnight Pacific, when Google resets it.
            return .retry(after: max(60, GoogleAPIError.quotaReset(after: clock.now()).timeIntervalSince(clock.now())), refusal)
        case .apiDisabled: return .retry(after: 600, refusal)
        case .needsSignIn, .clientRejected: return .retry(after: 300, refusal)
        case .temporary, .offline, .historyExpired: return .retry(after: max(refusal.retryAfter ?? 0, backoff(for: id)), refusal)
        case .other:
            // No status at all is a network failure that was not recognised, not Gmail's answer.
            return refusal.httpStatus == 0 ? .retry(after: backoff(for: id), refusal) : .refused(refusal)
        case .domainPolicy, .insufficientPermissions, .gmailNotEnabled, .tooLarge:
            return .refused(refusal)
        }
    }

    /// Google's backoff: 2ⁿ seconds and up to one more at random, at most 64.
    private func backoff(for id: UUID) -> TimeInterval {
        let failures = runtime[id]?.failures ?? 0
        return min(64, max(1, pow(2, Double(min(failures, 6))) + Double.random(in: 0..<1)))
    }

    private func goneLabel(among labels: Set<GmailLabelID>) async -> GmailLabelID? {
        for label in labels.sorted() where label.isUserLabel {
            do {
                _ = try await transport.label(label, work: .interactive)
            } catch let error as GoogleAPIError where error.kind == .notFound {
                return label
            } catch {
                continue
            }
        }
        return nil
    }

    private func folderName(of label: GmailLabelID) async -> String {
        if let folder = await host?.folders().first(where: { $0.gmailLabelID == label }) { return folder.name }
        if let entry = await store.labelTable().first(where: { $0.id == label }) { return entry.name }
        return label.value
    }

    static func refusedSentence(_ refusal: GoogleAPIError) -> String {
        let reason = refusal.errorDescription ?? ""
        return "Gmail didn't accept that change, so the messages are back as they were. \(reason)"
            .trimmingCharacters(in: .whitespaces)
    }

    /// Delete in Drafts, once the undo window has ended. Gmail keeps nothing of a deleted draft.
    private func sendDiscard(_ id: UUID) async -> Outcome {
        guard let op = ops.first(where: { $0.id == id }) else { return .sent }
        if runtime[id]?.undoRequested == true { return .undone }
        let messages = op.messageIDs
        var draftIDs = await host?.draftIDs(for: messages) ?? [:]
        if draftIDs.count < messages.count {
            let wanted = Set(messages.map(\.raw))
            var token: String?
            repeat {
                do {
                    let page = try await transport.drafts(pageToken: token, work: .interactive)
                    for draft in page.drafts ?? [] {
                        guard let message = draft.message?.gmailID, wanted.contains(message.raw) else { continue }
                        draftIDs[message] = draft.id
                    }
                    token = page.nextPageToken
                } catch {
                    return failed(error, op: id)
                }
            } while token != nil
        }
        for message in messages {
            guard let draft = draftIDs[message] else { continue }
            markAttempted(id, group: 0, [message])
            do {
                try await transport.deleteDraft(draft, work: .interactive)
            } catch let error as GoogleAPIError where error.kind == .notFound {
                // Sent or deleted on another device meanwhile.
            } catch {
                return failed(error, op: id)
            }
            markConfirmed(id, group: 0, [message])
        }
        await apply(messages.map { .tombstone($0) })
        return .sent
    }

    private func failed(_ error: Error, op: UUID) -> Outcome {
        switch disposition(of: error, for: op) {
        case .cancelled: return .cancelled
        case .retry(let after, let refusal): return .retry(after: after, refusal)
        case .refused(let refusal), .notFound(let refusal):
            return .refused(refusal, sentence: GmailActions.refusedSentence(refusal), names: [])
        }
    }

    /// Delete for good. Just before, a check for changes runs and the folder is listed afresh:
    /// only messages both the index and Gmail still have there are deleted, so a message
    /// restored on the phone a moment ago stays. It goes in chunks of 1,000, with a check
    /// between them.
    private func sendDeleteForever(_ id: UUID, lane: Lane) async -> Outcome {
        guard let op = ops.first(where: { $0.id == id }), let label = op.contextLabel else { return .sent }
        await host?.checkForChanges()
        var listed: Set<UInt64> = []
        var token: String?
        repeat {
            do {
                let page = try await transport.list(GmailListQuery(labels: [label], includeSpamTrash: true, maxResults: 500,
                                                                   pageToken: token), work: work(for: lane))
                listed.formUnion(page.refs.map(\.id.raw))
                token = page.nextPageToken
            } catch {
                return failed(error, op: id)
            }
        } while token != nil
        var deleted = 0
        var kept = 0
        let wanted = op.messageIDs
        for start in stride(from: 0, to: wanted.count, by: GmailActions.batchSize) {
            if start > 0 { await host?.checkForChanges() }
            let chunk = Array(wanted[start..<min(start + GmailActions.batchSize, wanted.count)])
            if runtime[id]?.confirmed[0]?.isSuperset(of: chunk.map(\.raw)) == true { continue }
            let snapshot = await store.index()
            var doomed: [GmailMessageID] = []
            var spared: [GmailMessageID] = []
            for message in chunk {
                let stillThere = snapshot.slotByID[message.raw].map { snapshot.record(atSlot: $0, has: label) } ?? false
                if stillThere, listed.contains(message.raw) { doomed.append(message) } else { spared.append(message) }
            }
            if !spared.isEmpty {
                kept += spared.count
                await apply(spared.map { .attributes($0, setting: [], clearing: .provisional) })
            }
            if !doomed.isEmpty {
                if lane == .bulk { await admitBulk(GmailMethod.messagesBatchDelete.units) }
                markAttempted(id, group: 0, doomed)
                do {
                    try await transport.batchDelete(doomed, work: work(for: lane))
                } catch {
                    return failed(error, op: id)
                }
                deleted += doomed.count
                await apply(doomed.map { .tombstone($0) })
            }
            markConfirmed(id, group: 0, chunk)
        }
        let folder = label == .trash ? "Deleted Items" : "Junk Email"
        Log.info("gmail", "deleted for good from \(folder): asked \(wanted.count), deleted \(deleted), "
                 + "left \(kept) that had moved meanwhile")
        return .sent
    }

    /// Bulk work takes at most `bulkUnitsPerMinute` in any minute.
    private func admitBulk(_ units: Int) async {
        while !stopped {
            let now = clock.now()
            bulkLedger.removeAll { now.timeIntervalSince($0.at) >= 60 }
            let used = bulkLedger.reduce(0) { $0 + $1.units }
            if used + units <= bulkUnitsPerMinute || bulkLedger.isEmpty {
                bulkLedger.append((now, units))
                return
            }
            let wait = 60 - now.timeIntervalSince(bulkLedger[0].at)
            try? await clock.sleep(max(0.01, wait))
        }
    }

    // MARK: Endings

    private func committed(_ id: UUID) async {
        guard let i = ops.firstIndex(where: { $0.id == id }) else { return }
        var op = ops.remove(at: i)
        let undoRequested = runtime[id]?.undoRequested ?? false
        let attempted = runtime[id]?.attempted ?? [:]
        runtime[id] = nil
        op.phase = .committed
        invalidateHeld()
        if undoRequested, op.kind == .labels {
            let reverse = await reversed(op, ids: attempted, keeping: op.skippedRecords)
            op.skippedRecords = []
            if !reverse.deltas.isEmpty {
                ops.insert(reverse, at: min(i, ops.count))
                runtime[reverse.id] = Runtime()
                invalidateHeld()
            }
        } else if op.isUndoable, op.kind == .labels {
            keepForUndo(op)
        }
        save()
        // Records kept while it waited may have come from after Gmail applied it; reading the
        // messages back settles which came last.
        if !op.skippedRecords.isEmpty { await settle(Set(op.skippedRecords.map(\.id.raw))) }
        await host?.changeCommitted()
        wakeLanes()
    }

    private func keepForUndo(_ op: PendingGmailOp) {
        sentOps.append(op)
        let now = clock.now()
        sentOps.removeAll { now.timeIntervalSince($0.createdAt) >= GmailActions.sentKeptFor }
        if sentOps.count > GmailActions.sentKept { sentOps.removeFirst(sentOps.count - GmailActions.sentKept) }
    }

    /// A definite refusal: the rows go back as they were, what was kept back is applied, and the
    /// owner is told why.
    private func refused(_ id: UUID, error: GoogleAPIError, sentence: String, names: [String]) async {
        guard let i = ops.firstIndex(where: { $0.id == id }) else { return }
        let op = ops.remove(at: i)
        let state = runtime[id]
        runtime[id] = nil
        invalidateHeld()
        save()
        Log.info("gmail", "change \(op.verb) refused by Gmail: \(error.kind.rawValue) \(error.httpStatus) \(error.reason ?? "")")
        if state?.undoRequested != true {
            // What Gmail confirmed stays; the rest goes back.
            var unsent: Set<UInt64> = []
            for (g, delta) in op.deltas.enumerated() {
                let done = state?.confirmed[g] ?? []
                unsent.formUnion(delta.ids.map(\.raw).filter { !done.contains($0) })
            }
            await unshow(op, only: unsent)
            await unmuteAdded(op)
            await host?.notice(sentence, names: names)
        }
        await applyKept(op.skippedRecords)
    }

    /// A change older than a day: dropped, and its rows put back from Gmail's state.
    private func expire(_ id: UUID) async {
        guard let op = ops.first(where: { $0.id == id }) else { return }
        // Its rows go back from Gmail's state first: a stop meanwhile leaves the change on disk,
        // and the next start drops it and puts them back then.
        await settle(Set(op.messageIDs.map(\.raw)), clearing: op.kind == .deleteForever)
        guard !Task.isCancelled, let i = ops.firstIndex(where: { $0.id == id }) else { return }
        ops.remove(at: i)
        runtime[id] = nil
        invalidateHeld()
        save()
        Log.info("gmail", "change \(op.verb) dropped after a day unsent: \(op.messageCount) messages")
    }

    private enum GapResult { case checked, retry(after: TimeInterval), dropped }

    /// After a gap, as a relaunch or a spell on an earlier FalconMail, a message the history
    /// since the change touched is left out of it, because someone has acted on it since, and its
    /// row is read back from Gmail. If that history has expired, the whole change is dropped and
    /// the account listed again.
    private func gapCheck(_ id: UUID) async -> GapResult {
        guard let op = ops.first(where: { $0.id == id }), let knownAt = op.knownAt else {
            runtime[id]?.needsGapCheck = false
            return .checked
        }
        if gapHistory == nil || gapHistory!.since > knownAt {
            let oldest = ops.compactMap { runtime[$0.id]?.needsGapCheck == true ? $0.knownAt : nil }.min() ?? knownAt
            var touched: [(history: HistoryID, id: UInt64)] = []
            var token: String?
            do {
                repeat {
                    let page = try await transport.history(since: oldest, types: Set(GmailHistoryType.allCases), label: nil,
                                                           pageToken: token, work: .checks)
                    for record in page.records {
                        let messages = record.messagesAdded + record.messagesDeleted
                            + record.labelsAdded.map(\.message) + record.labelsRemoved.map(\.message)
                        touched += messages.map { (record.id, $0.ref.id.raw) }
                    }
                    token = page.nextPageToken
                } while token != nil
            } catch let error as GoogleAPIError where error.kind == .historyExpired {
                let dropped = ops.filter { runtime[$0.id]?.needsGapCheck == true }
                ops.removeAll { runtime[$0.id]?.needsGapCheck == true }
                for op in dropped { runtime[op.id] = nil }
                invalidateHeld()
                save()
                // The rows go back to how they were before; the listing then puts them right.
                for op in dropped { await unshow(op) }
                Log.info("gmail", "dropped \(dropped.count) changes from the last run: the history since them has expired")
                await host?.notice("Changes made before FalconMail last closed were not sent, because the mail may have changed "
                                   + "since. FalconMail is listing the mailbox again.", names: [])
                await host?.needsRelisting()
                return .dropped
            } catch {
                switch disposition(of: error, for: id) {
                case .retry(let after, _): return .retry(after: after)
                case .cancelled: return .retry(after: 1)
                default: return .retry(after: 60)
                }
            }
            gapHistory = (oldest, touched)
        }
        runtime[id]?.needsGapCheck = false
        let touchedIDs = Set((gapHistory?.touched ?? []).filter { $0.history > knownAt }.map(\.id))
        guard let i = ops.firstIndex(where: { $0.id == id }) else { return .dropped }
        let hit = Set(ops[i].messageIDs.map(\.raw)).intersection(touchedIDs)
        guard !hit.isEmpty else { return .checked }
        let clearing = ops[i].kind == .deleteForever
        for g in ops[i].deltas.indices { ops[i].deltas[g].ids.removeAll { hit.contains($0.raw) } }
        let empty = ops[i].messageCount == 0
        if empty {
            ops.remove(at: i)
            runtime[id] = nil
        }
        invalidateHeld()
        save()
        Log.info("gmail", "left \(hit.count) messages out of a change from the last run: they changed since")
        await host?.notice("Some changes made before FalconMail last closed were not sent, because the mail has changed since.", names: [])
        await settle(hit, clearing: clearing)
        return empty ? .dropped : .checked
    }

    // MARK: Saving

    private func invalidateHeld() {
        heldCache = nil
    }

    private func save() {
        guard canSave else { return }
        do {
            try file.save(ops)
        } catch {
            Log.error("Store", "could not save the Gmail changes waiting to be sent: \(error.localizedDescription)", error: error,
                      logAs: "store")
        }
    }

    // MARK: New folders

    /// New Folder: `labels.create`, nested under `parent` with Gmail's `/` when the parent is a
    /// label of the owner's own.
    public func createFolder(named name: String, parent: UUID?) async throws -> GmailLabel {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GmailActionError(.emptyName, "A folder needs a name.") }
        var full = trimmed
        if let parent, let folder = await host?.folders().first(where: { $0.id == parent }),
           let label = folder.gmailLabelID, label.isUserLabel {
            let parentName = await store.labelTable().first(where: { $0.id == label })?.name ?? folder.path
            full = parentName + "/" + trimmed
        }
        do {
            let label = try await transport.createLabel(named: full, work: .interactive)
            Log.info("gmail", "created a label")
            await host?.labelsChanged()
            return label
        } catch let error as GoogleAPIError where error.httpStatus == 409 {
            throw GmailActionError(.folderExists, "A folder named “\(full)” already exists.", names: [full])
        }
    }
}

extension GmailActionPlan {
    /// Mute and Unmute act on whole conversations, not only the members a view shows.
    var isMuting: Bool {
        switch self {
        case .mute, .unmute: return true
        default: return false
        }
    }
}
