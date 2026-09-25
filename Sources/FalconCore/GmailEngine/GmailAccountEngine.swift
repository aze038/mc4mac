import Foundation

// The engine for one Google account on the Gmail API (§1.1 decision 6): one actor that owns the
// account's state and is its only writer. It lists the mailbox into the index (§3), checks for
// changes (§4), decides which mail is new and says so the way the IMAP engine does, so
// notifications, sounds and the status line work unchanged. The list, actions, drafts, imports and
// search are built on it by other work items, which plug in through `GmailEngineParts` and call
// the engine API at the end of this file.

// MARK: - What the engine is given

/// The engine's sense of time, which tests replace.
public protocol GmailEngineClock: Sendable {
    func now() -> Date
    /// Returns at `date`, or as soon as the calling task is cancelled.
    func sleep(until date: Date) async
}

public struct SystemGmailClock: GmailEngineClock {
    public init() {}

    public func now() -> Date { Date() }

    public func sleep(until date: Date) async {
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(min(seconds, 86_400 * 365) * 1_000_000_000))
    }
}

/// A transport that knows how far Gmail's clock is from the Mac's, from the Date header of Gmail's
/// answers. New mail is decided by Gmail's time, so a Mac whose clock is wrong still announces it.
/// The engine uses this when the transport offers it, and the Mac's clock otherwise.
public protocol GmailServerClock: Sendable {
    /// Gmail's time less the Mac's, in seconds; nil before any answer has said.
    func gmailClockOffset() async -> TimeInterval?
}

/// Whether Gmail's totals count Junk Email and Deleted Items. Google does not say; G1's probe finds
/// out, and the index's counts are compared by the same rule, or every label with a message in
/// Deleted Items would disagree every day and be listed again for nothing (§2.5).
public struct GmailCountRule: Sendable, Equatable {
    public var labelTotalsCountJunkAndDeleted: Bool
    public var profileTotalCountsJunkAndDeleted: Bool

    public init(labelTotalsCountJunkAndDeleted: Bool = true, profileTotalCountsJunkAndDeleted: Bool = true) {
        self.labelTotalsCountJunkAndDeleted = labelTotalsCountJunkAndDeleted
        self.profileTotalCountsJunkAndDeleted = profileTotalCountsJunkAndDeleted
    }
}

public struct GmailEngineSettings: Sendable {
    public var schedule = GmailPollSchedule.Settings()
    public var countRule = GmailCountRule()
    /// List CHAT too, which only matters if `messages.list` returns chats (a probe item).
    public var listsChats = false
    /// Settings ▸ Accounts ▸ "Show all Gmail labels".
    public var showsAllLabels = false
    /// Above this many messages All Mail is listed in slices by year, side by side.
    public var sliceAbove = 50_000
    public var sliceYears = 7
    /// Listings run side by side; the transport decides how many requests are really in flight.
    public var chainsAtOnce = 8
    public var pageSize = 500
    public var firstScreenRows = 15
    /// Up to this many added messages in one check are fetched whole at once.
    public var fetchedOneByOne = 10
    /// Keeps the newest 1,000 on the Mac; tests of listing alone turn it off.
    public var fillsCache = true
    public var cacheBatch = 10
    /// A full relisting after an expired history runs at most this often, unless the owner asks.
    public var fullRelistEvery: TimeInterval = 6 * 3600
    /// With more removal candidates than this, a second listing confirms them instead of one
    /// fetch each.
    public var confirmByListingAbove = 200
    public var labelCountsEvery: TimeInterval = 60
    public var dailyEvery: TimeInterval = 24 * 3600

    public init() {}
}

/// Why something the owner asked for could not be done by this engine yet.
public struct GmailEngineUnavailable: Error, LocalizedError, Equatable {
    public var email: String
    public var what: String

    public var errorDescription: String? { "\(email) isn't connected, so this wasn't done." }
}

// MARK: - Parts other work items build

/// Actions, rules and mutes (G5).
public protocol GmailEngineActions: Sendable {
    func perform(_ request: MailActionRequest, engine: GmailAccountEngine) async throws -> ActionReceipt
    func undo(_ receiptID: UUID, engine: GmailAccountEngine) async -> Bool
    func hasPendingChanges(engine: GmailAccountEngine) async -> Bool
    func flushPending(within seconds: TimeInterval, engine: GmailAccountEngine) async -> Bool
    func runRulesOnInbox(engine: GmailAccountEngine) async throws
    func createFolder(named name: String, parent: UUID?, engine: GmailAccountEngine) async throws -> FolderInfo
    /// Mail that arrived now, before it is announced, for rules and mutes. Returns the messages
    /// that must not be announced, because a mute or a rule has taken them out of the Inbox.
    func arrived(_ arrivals: [GmailArrival], engine: GmailAccountEngine) async -> Set<GmailMessageID>
}

/// Drafts and imports (G6).
public protocol GmailEngineUploads: Sendable {
    func saveDraft(_ raw: Data, as draft: DraftRef, engine: GmailAccountEngine) async throws -> DraftRef
    func deleteDraft(_ draft: DraftRef, engine: GmailAccountEngine) async throws
    func importMessages(_ messages: [ImportedMessage], into folderID: UUID, engine: GmailAccountEngine,
                        progress: @escaping @Sendable (Int) -> Void) async throws
}

/// Search (G4).
public protocol GmailEngineSearch: Sendable {
    func search(_ query: String, id: UUID, fetchRows: Bool, engine: GmailAccountEngine) async throws
    func endSearch(_ id: UUID, engine: GmailAccountEngine) async
}

public struct GmailEngineParts: Sendable {
    public var listSource: any ListSource
    public var actions: (any GmailEngineActions)?
    public var uploads: (any GmailEngineUploads)?
    public var search: (any GmailEngineSearch)?

    public init(listSource: any ListSource = UnbuiltListSource(), actions: (any GmailEngineActions)? = nil,
                uploads: (any GmailEngineUploads)? = nil, search: (any GmailEngineSearch)? = nil) {
        self.listSource = listSource
        self.actions = actions
        self.uploads = uploads
        self.search = search
    }
}

/// Stands in for the list until G4's is installed: every view is empty and still loading.
public final class UnbuiltListSource: ListSource, @unchecked Sendable {
    public init() {}
    public func snapshot(of view: ListView) async -> ListSnapshot { .empty(view) }
    public func changes(of view: ListView) -> AsyncStream<ListDiff> { AsyncStream { $0.finish() } }
    public func requestRows(_ keys: [RowKey], priority: RowPriority) {}
    public var rows: AsyncStream<[RowKey: MessageRowContent]> { AsyncStream { $0.finish() } }
    public func summary(for key: RowKey, in view: ListView) async -> RowAvailability {
        .unavailable(reason: "The list for this account is not ready yet.")
    }
}

/// Which messages of the index changed, for the list to rebuild what shows them.
public struct GmailIndexChange: Sendable, Equatable {
    public var ids: Set<GmailMessageID>
    /// So much changed, as after a listing, that every view is built again.
    public var everything: Bool

    public init(ids: Set<GmailMessageID> = [], everything: Bool = false) {
        self.ids = ids
        self.everything = everything
    }
}

/// A change the owner made that Gmail has not confirmed yet (§4.6, §7.5). While it is held or on
/// its way, history records and listings leave alone the labels it touches on its messages, so a
/// row he has just archived never comes back; the records skipped are kept with it.
public struct GmailHeldChange: Codable, Hashable, Sendable {
    public var id: UUID
    public var labels: [GmailMessageID: Set<GmailLabelID>]

    public init(id: UUID, labels: [GmailMessageID: Set<GmailLabelID>]) {
        self.id = id
        self.labels = labels
    }
}

/// A history record skipped because a held change touched its labels, kept so that it can be
/// applied if the change ends without reaching Gmail. G5 keeps them in its pending changes.
public struct GmailKeptRecord: Codable, Hashable, Sendable {
    public var id: GmailMessageID
    public var adding: Set<GmailLabelID>
    public var removing: Set<GmailLabelID>

    public init(id: GmailMessageID, adding: Set<GmailLabelID>, removing: Set<GmailLabelID>) {
        self.id = id
        self.adding = adding
        self.removing = removing
    }
}

/// What the engine keeps in `state.json`. Never the history cursor, which lives only in the
/// journal, flushed with the changes it covers.
struct GmailEngineState: Codable, Equatable {
    struct Band: Codable, Equatable {
        var chain: GmailListingChain
        var run: UInt32
        /// The order of the newest message the listing gives; each older one is a step less.
        var top: UInt32
    }

    enum Phase: String, Codable {
        case listing, counting, replaying, complete
    }

    struct Backfill: Codable, Equatable {
        /// The history id at the start, from which the changes made during the listing are applied
        /// again at the end.
        var startHistory: HistoryID
        var startedAt: Date
        var run: UInt32
        var bands: [Band]
        var phase: Phase
        var total: Int
    }

    var lastCheckStart: Date?
    var backfill: Backfill?
    var lastFullRelist: Date?
    var floodBegan: Date?
    var lastDailyCheck: Date?
    var sendAs: [String]?
    var sendAsAt: Date?
    var anchorsDay: Date?
    var dateGroupsWanted: Bool?
}

// MARK: - The engine

public actor GmailAccountEngine: MailAccountEngine {
    public nonisolated let accountID: UUID
    public nonisolated let account: AccountInfo
    nonisolated let transport: any GmailTransport
    nonisolated let store: any GmailStore
    nonisolated let settings: GmailEngineSettings
    nonisolated let clock: any GmailEngineClock
    nonisolated let sink: @Sendable (SyncEvent) -> Void
    nonisolated let folderHints: [FolderInfo]
    /// Whether a conversation is muted, which G5's mutes answer; nil mutes nothing.
    nonisolated let mutedCheck: (@Sendable (MessageSummary) async -> Bool)?
    private nonisolated let partsBox: PartsBox

    // What was loaded, and the cursor.
    var loaded = false
    var running = false
    var cursor: HistoryID?
    var state = GmailEngineState()
    private var stateSavedAt: Date?
    /// The top of the order: new mail goes above it.
    var ceiling: UInt32 = 0
    /// Known to exist but not placed yet: tried again at each check.
    var awaiting: [UInt64: GmailRef] = [:]
    /// Placed while another app imports, not shown until a listing settles them.
    var provisional: Set<UInt64> = []
    /// A resync that began and has not ended: the history id it will end at.
    var resyncBegan: HistoryID?
    /// The history expired while a full relisting was not allowed yet: checks look at the top of
    /// All Mail until one is.
    var resyncWanted = false
    /// Messages placed by checks while a relisting runs, which the relisting must not take for
    /// gone or strip of labels it listed before they came.
    var placedDuringRelist: Set<UInt64>?
    var held = HeldChanges()
    var flood = GmailFloodDetector()
    var importLog = GmailImportLog()
    var schedule: GmailPollSchedule
    var healthTracker: GmailHealthTracker
    var labelEntries: [GmailLabelEntry] = []
    /// What `labels.get` said last, by label.
    var labelCounts: [GmailLabelID: GmailLabelCounts] = [:]
    var labelCountsAsked: [GmailLabelID: Date] = [:]
    var labelsToRefresh: Set<GmailLabelID> = []
    var labelsListWanted = false
    /// Where each listing chain has got, as the store keeps it.
    var chainProgress: [GmailListingChain: GmailChainProgress] = [:]
    var backfillRetryAt: Date?
    var pendingFloodEnd = false
    /// The last wait the transport reported, read at the start of each check.
    var lastPause: GmailPause?
    var sendAsAddresses: Set<String> = []
    var selectedLabel: GmailLabelID??
    var undoWindow: TimeInterval = 10
    public private(set) var checksCompleted = 0

    // Work in progress.
    private var loopTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    var backfillTask: Task<Void, Never>?
    var cacheTask: Task<Void, Never>?
    var relistTask: Task<Void, Never>?
    private var currentCheck: Task<GmailCheckReport, Never>?
    private var currentToken: UUID?
    private var queuedCheck: Task<GmailCheckReport, Never>?
    private var queuedReasons: Set<PokeReason> = []

    // Those who listen.
    private var indexListeners: [UUID: AsyncStream<GmailIndexChange>.Continuation] = [:]
    private var folderListeners: [UUID: AsyncStream<[FolderInfo]>.Continuation] = [:]
    private var rowListeners: [UUID: AsyncStream<[RowKey: MessageRowContent]>.Continuation] = [:]

    public init(account: AccountInfo, transport: any GmailTransport, store: any GmailStore,
                settings: GmailEngineSettings = GmailEngineSettings(), clock: any GmailEngineClock = SystemGmailClock(),
                folderHints: [FolderInfo] = [], parts: GmailEngineParts = GmailEngineParts(),
                muted: (@Sendable (MessageSummary) async -> Bool)? = nil,
                events: @escaping @Sendable (SyncEvent) -> Void) {
        accountID = account.id
        self.account = account
        self.transport = transport
        self.store = store
        self.settings = settings
        self.clock = clock
        self.folderHints = folderHints
        mutedCheck = muted
        sink = events
        partsBox = PartsBox(parts)
        schedule = GmailPollSchedule(settings: settings.schedule, now: clock.now())
        healthTracker = GmailHealthTracker(email: account.email)
    }

    // MARK: - MailAccountEngine: the list and the parts

    public nonisolated var listSource: any ListSource { partsBox.value.listSource }
    public nonisolated var parts: GmailEngineParts { partsBox.value }

    /// Puts in the parts other work items build, which then call back into this engine.
    public nonisolated func install(_ parts: GmailEngineParts) {
        partsBox.value = parts
    }

    // MARK: - Starting and stopping

    public func start() async {
        guard !running else { return }
        running = true
        await loadIfNeeded()
        if let first = healthTracker.starting() { setHealth(first) }
        loopTask = Task { await self.loop() }
        if state.backfill?.phase != .complete {
            backfillTask = Task { await self.runBackfill() }
        } else {
            startCacheFill()
        }
    }

    public func stop() async {
        running = false
        loopTask?.cancel()
        sleepTask?.cancel()
        backfillTask?.cancel()
        cacheTask?.cancel()
        relistTask?.cancel()
        _ = await currentCheck?.value
        _ = await queuedCheck?.value
        loopTask = nil
        backfillTask = nil
        cacheTask = nil
        relistTask = nil
        saveState(force: true)
        do { try await store.compact() } catch {
            Log.warning("gmail", "\(account.email): compacting the index at stop failed", error: error, account: account)
        }
        for listener in indexListeners.values { listener.finish() }
        for listener in folderListeners.values { listener.finish() }
        for listener in rowListeners.values { listener.finish() }
        indexListeners = [:]
        folderListeners = [:]
        rowListeners = [:]
    }

    /// Reads what the store and `state.json` kept: the cursor, a resync left unfinished, messages
    /// waiting to be placed, the top of the order and the label table.
    func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        do {
            let load = try await store.load()
            cursor = load.cursor
            resyncBegan = load.resyncBegan
            chainProgress = load.chains
            for ref in load.awaitingPlacement { awaiting[ref.id.raw] = ref }
        } catch {
            Log.error("gmail", "\(account.email): the index could not be read", error: error, account: account)
        }
        state = AtomicFile.loadJSON(GmailEngineState.self, from: store.files.state, what: "the Gmail engine's state").value ?? GmailEngineState()
        labelEntries = await store.labelTable()
        for entry in labelEntries { if let counts = entry.counts { labelCounts[entry.id] = counts } }
        sendAsAddresses = Set((state.sendAs ?? []).map { $0.lowercased() })
        if let began = state.floodBegan { flood = GmailFloodDetector.resumed(began: began, at: now()) }
        let snapshot = await store.index()
        var top: UInt32 = 0
        for slot in snapshot.byOrder {
            let record = snapshot.records[Int(slot)]
            if record.attributes.contains(.provisional) { provisional.insert(record.id) } else { top = max(top, record.order) }
        }
        ceiling = max(top, state.backfill?.bands.map(\.top).max() ?? 0)
    }

    // MARK: - Checks: one at a time

    public func poke(reason: PokeReason) async {
        _ = await check(reason: reason)
    }

    /// Runs a check now, or, while one runs, once more after it; the report is that of the check
    /// that covered the request. A message that just went out is looked for 2 and 10 seconds
    /// later instead of at once, when Gmail has filed it.
    @discardableResult
    public func check(reason: PokeReason) async -> GmailCheckReport {
        await loadIfNeeded()
        switch reason {
        case .messageSent:
            schedule.messageSent(at: now())
            wakeLoop()
            return GmailCheckReport(reason: reason, skipped: true)
        case .sendAndReceive, .wake, .networkChange:
            schedule.clearHolds()
        case .schedule, .changeCommitted:
            break
        }
        if let running = currentCheck {
            queuedReasons.insert(reason)
            if let queued = queuedCheck { return await queued.value }
            let queued = Task<GmailCheckReport, Never> {
                _ = await running.value
                return await self.runQueuedCheck()
            }
            queuedCheck = queued
            return await queued.value
        }
        return await runCheck(reason)
    }

    private func runQueuedCheck() async -> GmailCheckReport {
        let reasons = queuedReasons
        queuedReasons = []
        queuedCheck = nil
        let order: [PokeReason] = [.sendAndReceive, .wake, .networkChange, .changeCommitted, .schedule]
        return await runCheck(order.first(where: reasons.contains) ?? .schedule)
    }

    private func runCheck(_ reason: PokeReason) async -> GmailCheckReport {
        let report = await exclusively { await self.performCheck(reason: reason) }
        checksCompleted += 1
        return report
    }

    /// Runs work that reads or moves the cursor, such as a check or the replay at the end of the
    /// first listing, once nothing else of the kind runs.
    func exclusively(_ operation: @escaping @Sendable () async -> GmailCheckReport) async -> GmailCheckReport {
        while let running = currentCheck { _ = await running.value }
        let token = UUID()
        currentToken = token
        // The task lets go of the slot itself, on the actor, before anyone waiting for it resumes:
        // a waiter that found the slot still taken by a finished task would wait on it forever.
        let task = Task { () -> GmailCheckReport in
            let report = await operation()
            self.releaseSlot(token)
            return report
        }
        currentCheck = task
        return await task.value
    }

    private func releaseSlot(_ token: UUID) {
        guard currentToken == token else { return }
        currentToken = nil
        currentCheck = nil
    }

    // MARK: - The loop

    private func loop() async {
        while running && !Task.isCancelled {
            let current = now()
            await maintenance(at: current)
            guard running, !Task.isCancelled else { break }
            guard cursor != nil || resyncBegan != nil else {
                // The first listing sets the cursor, and wakes the loop when it has.
                await sleep(until: .distantFuture)
                continue
            }
            guard let due = schedule.nextCheck(after: current) else {
                await sleep(until: nextMaintenance(after: current))
                continue
            }
            if due > current {
                await sleep(until: min(due, nextMaintenance(after: current)))
                continue
            }
            _ = await check(reason: .schedule)
        }
    }

    private func sleep(until date: Date) async {
        let clock = self.clock
        let task = Task { await clock.sleep(until: date) }
        sleepTask = task
        await task.value
        if sleepTask == task { sleepTask = nil }
    }

    /// Something changed when the next check is due, so the loop looks again.
    func wakeLoop() {
        sleepTask?.cancel()
    }

    public func noteOwnerActivity(_ activity: OwnerActivity) async {
        let wasAsleep = schedule.activity == .asleep
        schedule.noteActivity(activity)
        if case .active(let at) = activity { await transport.noteOwnerActivity(at: at) }
        if wasAsleep, activity != .asleep {
            // Mail that came in during sleep shows within a few seconds of opening the lid.
            Task { await self.poke(reason: .wake) }
        }
        wakeLoop()
    }

    public func setUndoWindow(_ seconds: TimeInterval) async {
        undoWindow = seconds
    }

    /// The view the owner has open, whose folder is listed first while the index is built.
    public func noteSelectedFolder(_ label: GmailLabelID?) {
        selectedLabel = .some(label)
    }

    // MARK: - Time

    /// The Mac's time.
    nonisolated func now() -> Date { clock.now() }

    /// Gmail's time, which decides what mail is new, so a wrong clock on the Mac does not matter.
    func gmailNow() async -> Date {
        let offset = await (transport as? any GmailServerClock)?.gmailClockOffset() ?? 0
        return now().addingTimeInterval(offset)
    }

    // MARK: - State

    /// `state.json` is written at once for anything that matters after a crash, and at most every
    /// five minutes when only the time of the last check moved: an older time only widens the
    /// window of what counts as new by as much, and new mail is found by the cursor, not by it.
    func saveState(force: Bool = false) {
        let current = now()
        if !force, let saved = stateSavedAt, current.timeIntervalSince(saved) < 300 { return }
        do {
            try AtomicFile.writeJSON(state, to: store.files.state)
            stateSavedAt = current
        } catch {
            Log.warning("gmail", "\(account.email): the engine's state could not be saved", error: error, account: account)
        }
    }

    // MARK: - Events

    func emit(_ event: SyncEvent) {
        sink(event)
    }

    func setHealth(_ health: AccountHealth) {
        Log.info("health", "\(account.email): \(health.logName)")
        emit(.health(accountID: accountID, health))
    }

    func publishIndexChange(ids: Set<GmailMessageID>, everything: Bool = false) {
        guard !ids.isEmpty || everything else { return }
        let change = GmailIndexChange(ids: ids, everything: everything)
        for listener in indexListeners.values { listener.yield(change) }
        if !folderListeners.isEmpty { Task { await self.publishFolders() } }
    }

    func publishRows(_ rows: [RowKey: MessageRowContent]) {
        guard !rows.isEmpty else { return }
        for listener in rowListeners.values { listener.yield(rows) }
    }

    private func publishFolders() async {
        guard !folderListeners.isEmpty else { return }
        let list = await folders()
        for listener in folderListeners.values { listener.yield(list) }
    }

    // MARK: - Folders

    public func folders() async -> [FolderInfo] {
        await loadIfNeeded()
        let snapshot = await store.index()
        let tally = GmailLabelTally(snapshot: snapshot, forFolders: true, rule: settings.countRule)
        return GmailLabelMapping.folders(entries: labelEntries, accountID: accountID, hints: folderHints, tally: tally,
                                         counts: labelCounts, allMailComplete: allMailComplete)
    }

    public func folderUpdates() async -> AsyncStream<[FolderInfo]> {
        let (stream, continuation) = AsyncStream<[FolderInfo]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        folderListeners[id] = continuation
        continuation.onTermination = { _ in Task { await self.dropFolderListener(id) } }
        continuation.yield(await folders())
        return stream
    }

    private func dropFolderListener(_ id: UUID) { folderListeners[id] = nil }

    /// Which messages change, as they change.
    public func indexChanges() -> AsyncStream<GmailIndexChange> {
        let (stream, continuation) = AsyncStream<GmailIndexChange>.makeStream()
        let id = UUID()
        indexListeners[id] = continuation
        continuation.onTermination = { _ in Task { await self.dropIndexListener(id) } }
        return stream
    }

    private func dropIndexListener(_ id: UUID) { indexListeners[id] = nil }

    /// Row text the engine fetched for its own reasons, the first screen and new mail, for the
    /// list to show without asking again.
    public func rowUpdates() -> AsyncStream<[RowKey: MessageRowContent]> {
        let (stream, continuation) = AsyncStream<[RowKey: MessageRowContent]>.makeStream()
        let id = UUID()
        rowListeners[id] = continuation
        continuation.onTermination = { _ in Task { await self.dropRowListener(id) } }
        return stream
    }

    private func dropRowListener(_ id: UUID) { rowListeners[id] = nil }

    public func createFolder(named name: String, parent: UUID?) async throws -> FolderInfo {
        guard let actions = parts.actions else { throw unavailable("New Folder") }
        return try await actions.createFolder(named: name, parent: parent, engine: self)
    }

    // MARK: - Actions, drafts, imports and search: the parts

    public func perform(_ request: MailActionRequest) async throws -> ActionReceipt {
        guard let actions = parts.actions else { throw unavailable("actions") }
        return try await actions.perform(request, engine: self)
    }

    public func undo(_ receiptID: UUID) async -> Bool {
        await parts.actions?.undo(receiptID, engine: self) ?? false
    }

    public func hasPendingChanges() async -> Bool {
        await parts.actions?.hasPendingChanges(engine: self) ?? false
    }

    public func flushPending(within seconds: TimeInterval) async -> Bool {
        await parts.actions?.flushPending(within: seconds, engine: self) ?? true
    }

    public func runRulesOnInbox() async throws {
        try await parts.actions?.runRulesOnInbox(engine: self)
    }

    public func search(_ query: String, id: UUID, fetchRows: Bool) async throws {
        guard let search = parts.search else { throw unavailable("search") }
        try await search.search(query, id: id, fetchRows: fetchRows, engine: self)
    }

    public func endSearch(_ id: UUID) async {
        await parts.search?.endSearch(id, engine: self)
    }

    public func saveDraft(_ raw: Data, as draft: DraftRef) async throws -> DraftRef {
        guard let uploads = parts.uploads else { throw unavailable("drafts") }
        return try await uploads.saveDraft(raw, as: draft, engine: self)
    }

    public func deleteDraft(_ draft: DraftRef) async throws {
        guard let uploads = parts.uploads else { throw unavailable("drafts") }
        try await uploads.deleteDraft(draft, engine: self)
    }

    public func importMessages(_ messages: [ImportedMessage], into folderID: UUID,
                               progress: @escaping @Sendable (Int) -> Void) async throws {
        guard let uploads = parts.uploads else { throw unavailable("imports") }
        try await uploads.importMessages(messages, into: folderID, engine: self, progress: progress)
    }

    private func unavailable(_ what: String) -> GmailEngineUnavailable {
        GmailEngineUnavailable(email: account.email, what: what)
    }

    // MARK: - Opening

    public func open(_ key: RowKey, purpose: OpenPurpose) async -> AsyncThrowingStream<OpenedMessage, Error> {
        let (stream, continuation) = AsyncThrowingStream<OpenedMessage, Error>.makeStream()
        guard let id = key.gmailID else {
            continuation.finish(throwing: GmailEngineUnavailable(email: account.email, what: "open"))
            return stream
        }
        let work: WorkClass = .interactive
        Task {
            do {
                if let cached = await self.store.cachedMessages([id])[id], let body = try await self.store.body(of: id) {
                    continuation.yield(OpenedMessage(key: key, content: Self.opened(cached, body), isComplete: true, fromCache: true))
                    continuation.finish()
                    return
                }
                let full = try await self.transport.message(id, format: .full, work: work)
                var opened = GmailMessageContent.textStage(full)
                let pictures = opened.pendingInlineImages
                continuation.yield(OpenedMessage(key: key, content: opened, isComplete: pictures.isEmpty, fromCache: false))
                if !pictures.isEmpty {
                    opened = await self.withPictures(opened, answer: full, work: work, limit: 20)
                    continuation.yield(OpenedMessage(key: key, content: opened, isComplete: true, fromCache: false))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        return stream
    }

    public func attachmentData(_ attachment: GmailAttachmentStub, of key: RowKey) async throws -> Data {
        guard let id = key.gmailID else { throw GmailEngineUnavailable(email: account.email, what: "attachments") }
        if let data = attachment.inlineData { return data }
        if let attachmentID = attachment.attachmentID {
            do {
                return try await transport.attachment(attachmentID, of: id, work: .interactive)
            } catch let error as GoogleAPIError where error.kind == .notFound {
                // A stored attachment id Gmail no longer takes: a fresh structure gives a new one.
                let full = try await transport.message(id, format: .full, work: .interactive)
                let fresh = GmailMessageContent.textStage(full).attachments.first { $0.id == attachment.id }
                guard let newID = fresh?.attachmentID else { throw error }
                return try await transport.attachment(newID, of: id, work: .interactive)
            }
        }
        throw GoogleAPIError(kind: .notFound, httpStatus: 404, reason: "notFound", detail: "attachment without an id")
    }

    public func rawMessage(_ key: RowKey) async throws -> Data {
        guard let id = key.gmailID else { throw GmailEngineUnavailable(email: account.email, what: "the whole message") }
        let answer = try await transport.message(id, format: .raw, work: .interactive)
        guard let data = answer.rawData else {
            throw GoogleAPIError(kind: .other, detail: "format=raw answer without the message")
        }
        return data
    }

    static func opened(_ cached: GmailCachedMessage, _ body: GmailReducedBody) -> GmailOpenedMessage {
        var headers = MIMEHeaders()
        headers.add("From", cached.from.rfc5322)
        if !cached.to.isEmpty { headers.add("To", cached.to.map(\.rfc5322).joined(separator: ", ")) }
        if !cached.cc.isEmpty { headers.add("Cc", cached.cc.map(\.rfc5322).joined(separator: ", ")) }
        if !cached.replyTo.isEmpty { headers.add("Reply-To", cached.replyTo.map(\.rfc5322).joined(separator: ", ")) }
        headers.add("Subject", cached.subject)
        headers.add("Date", RFC5322Date.format(cached.date))
        if !cached.messageID.isEmpty { headers.add("Message-ID", "<\(cached.messageID)>") }
        if !cached.inReplyTo.isEmpty { headers.add("In-Reply-To", "<\(cached.inReplyTo)>") }
        if !cached.references.isEmpty { headers.add("References", cached.references.map { "<\($0)>" }.joined(separator: " ")) }
        let pictures = body.inlineImages.map {
            MIMEAttachment(id: $0.contentID, filename: "", mimeType: $0.mimeType, contentID: $0.contentID, isInline: true, data: $0.data)
        }
        let root = MIMEPart(headers: headers, contentType: ContentType.parse(nil), disposition: nil, dispositionParams: [:],
                            transferEncoding: nil, contentID: nil, body: Data(), children: [])
        let message = MIMEMessage(headers: headers, root: root, textPlain: body.textPlain, textHTML: body.textHTML, attachments: pictures)
        let stubs = cached.attachments.map {
            GmailAttachmentStub(id: $0.partID, attachmentID: $0.attachmentID, filename: $0.filename, mimeType: $0.mimeType,
                                size: $0.size, contentID: $0.contentID, isInline: $0.isInline, inlineData: nil)
        }
        return GmailOpenedMessage(gmailID: cached.id.hex, message: message, attachments: stubs)
    }

    /// The pictures the HTML shows inline: with two or more in a message of 1 MB or less, one
    /// `format=raw` call (20 units) brings them all; otherwise each costs one `attachments.get`.
    /// So no message costs more than 40 units, however many signature logos it carries (§2.4).
    func withPictures(_ opened: GmailOpenedMessage, answer: GmailMessage, work: WorkClass, limit: Int) async -> GmailOpenedMessage {
        var opened = opened
        let pending = opened.pendingInlineImages
        guard !pending.isEmpty, let id = answer.gmailID else { return opened }
        if pending.count >= 2, (answer.sizeEstimate ?? .max) <= 1_000_000 {
            if let raw = try? await transport.message(id, format: .raw, work: work).rawData {
                let parts = MIMEParser.parse(raw).attachments
                for stub in pending {
                    guard let cid = stub.contentID?.lowercased(),
                          let part = parts.first(where: { $0.contentID?.lowercased() == cid }) else { continue }
                    opened.add(part.data, for: stub)
                }
            }
            return opened
        }
        guard pending.count == 1 || limit > 1 else { return opened }
        for stub in pending.prefix(limit) {
            if let data = stub.inlineData {
                opened.add(data, for: stub)
            } else if let attachmentID = stub.attachmentID,
                      let data = try? await transport.attachment(attachmentID, of: id, work: work) {
                opened.add(data, for: stub)
            }
        }
        return opened
    }
}

// MARK: - The engine API other work items build on

extension GmailAccountEngine {
    /// The whole index, for building views.
    public func index() async -> GmailIndexSnapshot { await store.index() }

    public func labels() async -> [GmailLabelEntry] {
        await loadIfNeeded()
        return labelEntries
    }

    /// The newest history id the index is known to match, which a send saves before it goes as
    /// the point to look for it from (§8.2).
    public func historyCursor() async -> HistoryID? {
        await loadIfNeeded()
        return cursor
    }

    /// The owner's own addresses: the account's, and every send-as address Gmail gave.
    public func ownAddresses() -> Set<String> {
        account.ownAddresses.union(sendAsAddresses)
    }

    /// Shows a change the owner made at once (§7.3 step 1). It is journaled without a cursor, so
    /// a crash before the next check drops it, and the pending change it belongs to, which G5
    /// keeps, shows it again.
    public func showNow(_ changes: [GmailChange]) async throws {
        guard !changes.isEmpty else { return }
        try await store.commit(GmailJournalBatch(changes: changes))
        publishIndexChange(ids: Set(changes.compactMap(\.messageID)))
    }

    /// From now until `endHold`, history records and listings leave alone the labels this change
    /// touches on its messages; records skipped are kept with it. `kept` brings back records kept
    /// before a relaunch.
    public func hold(_ change: GmailHeldChange, kept: [GmailKeptRecord] = []) {
        held.hold(change, kept: kept)
    }

    /// The records skipped so far for a held change, for G5 to keep with it.
    public func keptRecords(for changeID: UUID) -> [GmailKeptRecord] {
        held.kept(for: changeID)
    }

    /// The change reached Gmail (`sent`), and the next check settles the state; or it ended
    /// without being sent, by Undo, a refusal or a 404, and the records kept with it are applied
    /// so nothing done on another device meanwhile is lost. With more than 50 messages kept,
    /// their labels are taken from Gmail instead, one `format=minimal` each.
    public func endHold(_ changeID: UUID, sent: Bool) async {
        let kept = held.end(changeID)
        guard !sent, !kept.isEmpty else {
            if sent { Task { await self.poke(reason: .changeCommitted) } }
            return
        }
        var changes: [GmailChange] = []
        let ids = Set(kept.map(\.id))
        if ids.count > 50 {
            for chunk in Array(ids).sorted().chunked(10) {
                guard let answers = try? await transport.batch(chunk.map { .message($0, .minimal) }, work: .interactive) else { continue }
                for id in chunk {
                    switch answers[.message(id, .minimal)] {
                    case .success(let answer)?:
                        guard let message = answer.message, let ref = message.ref,
                              let current = await store.labels(of: id), let record = await store.record(for: id) else { continue }
                        let adding = message.labels.subtracting(current).filter { held.protects(id, $0) == nil }
                        let removing = current.subtracting(message.labels).filter { held.protects(id, $0) == nil }
                        if !adding.isEmpty || !removing.isEmpty {
                            changes.append(.relabel(ref.id, adding: Set(adding), removing: Set(removing)))
                        }
                        _ = record
                    case .failure(let error)? where error.kind == .notFound:
                        changes.append(.tombstone(id))
                    default:
                        continue
                    }
                }
            }
        } else {
            for record in kept {
                let adding = record.adding.filter { held.protects(record.id, $0) == nil }
                let removing = record.removing.filter { held.protects(record.id, $0) == nil }
                if !adding.isEmpty || !removing.isEmpty {
                    changes.append(.relabel(record.id, adding: Set(adding), removing: Set(removing)))
                }
            }
        }
        guard !changes.isEmpty else { return }
        do {
            try await store.commit(GmailJournalBatch(changes: changes))
            publishIndexChange(ids: ids)
        } catch {
            Log.error("gmail", "\(account.email): records kept with an undone change could not be applied", error: error, account: account)
        }
    }

    /// A message Gmail just gave FalconMail in an answer, such as a sent message or a saved draft,
    /// goes into the index at once, above everything, so Sent and the conversation update before
    /// the send returns; its echo in the history then changes nothing (§4.6, §8.1).
    public func placeAtTop(_ answer: GmailMessage) async throws {
        guard let ref = answer.ref else { return }
        await loadIfNeeded()
        if let record = await store.record(for: ref.id), !record.attributes.contains(.tombstone) {
            try await store.commit(GmailJournalBatch(changes: [.relabel(ref.id, adding: answer.labels, removing: [])]))
        } else {
            let order = GmailOrderSpace.top(count: 1, above: ceiling)[0]
            ceiling = order
            try await store.commit(GmailJournalBatch(changes: [.place(ref, order: order, labels: answer.labels,
                                                                      attributes: Self.attributes(of: answer))]))
        }
        placedDuringRelist?.insert(ref.id.raw)
        publishIndexChange(ids: [ref.id])
    }

    /// A message Gmail deleted on FalconMail's behalf, such as the draft a save replaced.
    public func removeFromIndex(_ ids: [GmailMessageID]) async throws {
        guard !ids.isEmpty else { return }
        try await store.commit(GmailJournalBatch(changes: ids.map { .tombstone($0) }))
        publishIndexChange(ids: Set(ids))
    }

    /// What a message's answer tells the index beyond its labels: its size band, and whether it
    /// has attachments when the answer shows its parts.
    static func attributes(of message: GmailMessage) -> GmailRecordAttributes {
        var attributes: GmailRecordAttributes = []
        if let size = message.sizeEstimate {
            attributes.insert(.sizeKnown)
            attributes.sizeBand = SizeBand(bytes: size)
        }
        if message.payload?.parts != nil || message.payload?.body != nil {
            attributes.insert(.attachmentKnown)
            if !GmailMessageContent.textStage(message).listedAttachments.isEmpty { attributes.insert(.hasAttachment) }
        }
        return attributes
    }
}

// MARK: - Held changes

/// The owner's changes on their way to Gmail, and the history records they held back.
struct HeldChanges: Sendable {
    private var changes: [UUID: GmailHeldChange] = [:]
    private var keptRecords: [UUID: [GmailKeptRecord]] = [:]
    /// Which change protects each message's labels.
    private var owners: [UInt64: [GmailLabelID: UUID]] = [:]

    var isEmpty: Bool { changes.isEmpty }

    mutating func hold(_ change: GmailHeldChange, kept: [GmailKeptRecord]) {
        changes[change.id] = change
        keptRecords[change.id, default: []] += kept
        for (id, labels) in change.labels {
            for label in labels { owners[id.raw, default: [:]][label] = change.id }
        }
    }

    func protects(_ id: GmailMessageID, _ label: GmailLabelID) -> UUID? {
        owners[id.raw]?[label]
    }

    func protectsAny(_ id: GmailMessageID) -> Bool { owners[id.raw] != nil }

    func kept(for id: UUID) -> [GmailKeptRecord] { keptRecords[id] ?? [] }

    /// A label change from the history or a listing, with what a held change protects taken out
    /// and kept with that change.
    mutating func filter(_ id: GmailMessageID, adding: Set<GmailLabelID>, removing: Set<GmailLabelID>)
        -> (adding: Set<GmailLabelID>, removing: Set<GmailLabelID>) {
        guard let protected = owners[id.raw] else { return (adding, removing) }
        var keep: [UUID: (adding: Set<GmailLabelID>, removing: Set<GmailLabelID>)] = [:]
        var outAdding = adding
        var outRemoving = removing
        for label in adding { if let owner = protected[label] { keep[owner, default: ([], [])].adding.insert(label); outAdding.remove(label) } }
        for label in removing { if let owner = protected[label] { keep[owner, default: ([], [])].removing.insert(label); outRemoving.remove(label) } }
        for (owner, record) in keep {
            keptRecords[owner, default: []].append(GmailKeptRecord(id: id, adding: record.adding, removing: record.removing))
        }
        return (outAdding, outRemoving)
    }

    mutating func end(_ id: UUID) -> [GmailKeptRecord] {
        guard let change = changes.removeValue(forKey: id) else { return keptRecords.removeValue(forKey: id) ?? [] }
        for (message, labels) in change.labels {
            for label in labels where owners[message.raw]?[label] == id { owners[message.raw]?[label] = nil }
            if owners[message.raw]?.isEmpty == true { owners[message.raw] = nil }
        }
        return keptRecords.removeValue(forKey: id) ?? []
    }
}

// MARK: - Small helpers

/// The parts, which other work items may put in after the engine exists.
final class PartsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: GmailEngineParts

    init(_ parts: GmailEngineParts) { stored = parts }

    var value: GmailEngineParts {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

extension GmailChange {
    /// The message a change is about; nil for the resync markers.
    public var messageID: GmailMessageID? {
        switch self {
        case .place(let ref, _, _, _), .awaitingPlacement(let ref): return ref.id
        case .relabel(let id, _, _), .attributes(let id, _, _), .tombstone(let id): return id
        case .resyncBegan, .resyncEnded: return nil
        }
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

extension GmailFloodDetector {
    /// A flood that was under way when FalconMail quit: it goes on until half an hour passes with
    /// no deep mail, as if the last deep mail had come at launch.
    static func resumed(began: Date, at now: Date) -> GmailFloodDetector {
        var detector = GmailFloodDetector()
        _ = detector.noteDeep(GmailFloodDetector.deepInOneCheck + 1, at: now)
        detector.restore(began: began)
        return detector
    }
}
