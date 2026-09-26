import Foundation

// One switched Google account's engine put together: the sync engine over the transport and the
// store, with the list, the actions, drafts, imports, sending and search, each talking to the
// engine through the contracts between them. The engine stays the store's only writer: the
// others hand it Gmail's answers and it journals them. The app makes one of these per switched
// account (G7); tests make one over the in-memory Gmail.

// MARK: - What the engine does for its actions (G5)

extension GmailAccountEngine: GmailActionsHost {
    public func currentCursor() async -> HistoryID? {
        await historyCursor()
    }

    /// Changes the owner made show at once. They are journaled with the cursor where it stands,
    /// so they survive a relaunch, and the actions show them again at launch until Gmail has them.
    public func applyLocally(_ changes: [GmailChange]) async {
        do {
            try await showNow(changes)
        } catch {
            Log.error("gmail", "\(account.email): a change could not be shown", error: error, account: account)
        }
    }

    public func checkForChanges() async {
        _ = await check(reason: .changeCommitted)
    }

    /// Gmail has a change; a check soon settles the state. The actions go on meanwhile.
    public func changeCommitted() async {
        Task { await self.poke(reason: .changeCommitted) }
    }

    public func labelsChanged() async {
        await refreshLabelList()
    }

    public func needsRelisting() async {
        startResyncIfDue(askedByOwner: true)
    }

    public func notice(_ text: String, names: [String]) async {
        emit(.actionFailed(accountID: accountID, message: text, names: names))
    }

    public func messages(in view: ListView) async -> [GmailMessageID]? {
        guard let list = listSource as? GmailListSource else { return nil }
        return await list.messageIDs(in: view)
    }

    public func draftIDs(for ids: [GmailMessageID]) async -> [GmailMessageID: String] {
        await parts.uploads?.draftIDs(for: ids, engine: self) ?? [:]
    }

    public func updatesAreOther() async -> Bool {
        updatesOther
    }

    /// The owner opened a folder showing `rows` rows at once: the store keeps its first screen,
    /// and while the mailbox is still being listed, that folder is listed first.
    public func noteFolderShown(_ label: GmailLabelID?, rows: Int) async {
        noteSelectedFolder(label)
        await store.noteFolderShown(label, rows: rows, at: now())
    }
}

extension GmailActions: GmailEngineActions {
    static let pinOwner = "actions"

    public func start(engine: GmailAccountEngine) async {
        if host == nil { attach(engine) }
        await start()
        await engine.setPinned(pendingMessageIDs(), for: GmailActions.pinOwner)
    }

    public func stop(engine: GmailAccountEngine) async {
        stop()
    }

    public func perform(_ request: MailActionRequest, engine: GmailAccountEngine) async throws -> ActionReceipt {
        let receipt = try await perform(request)
        // Messages with a change waiting stay on the Mac whatever their age.
        await engine.setPinned(pendingMessageIDs(), for: GmailActions.pinOwner)
        return receipt
    }

    public func undo(_ receiptID: UUID, engine: GmailAccountEngine) async -> Bool {
        let undone = await undo(receiptID)
        await engine.setPinned(pendingMessageIDs(), for: GmailActions.pinOwner)
        return undone
    }

    public func hasPendingChanges(engine: GmailAccountEngine) async -> Bool {
        hasPendingChanges()
    }

    public func flushPending(within seconds: TimeInterval, engine: GmailAccountEngine) async -> Bool {
        await flushPending(within: seconds)
    }

    public func runRulesOnInbox(engine: GmailAccountEngine) async throws {
        try await runRulesOnInbox()
    }

    /// `labels.create`, then the new label's folder as the sidebar shows it: creating it had the
    /// engine read the labels again.
    public func createFolder(named name: String, parent: UUID?, engine: GmailAccountEngine) async throws -> FolderInfo {
        let label = try await createFolder(named: name, parent: parent)
        if let folder = await engine.folders().first(where: { $0.gmailLabelID == label.labelID }) { return folder }
        throw GmailActionError(.unknownFolder, "The new folder “\(label.name)” is on Gmail but isn't shown yet.", names: [label.name])
    }

    /// Mutes and rules see new mail before it is announced; what they filed away is not.
    public func arrived(_ arrivals: [GmailArrival], engine: GmailAccountEngine) async -> Set<GmailMessageID> {
        let outcome = await handleArrivals(arrivals)
        return outcome.muted.union(outcome.filedAway)
    }

    public func screen(_ records: [GmailHistoryRecord], engine: GmailAccountEngine) async -> [GmailHistoryRecord] {
        await screen(records)
    }

    public func heldLabels(engine: GmailAccountEngine) async -> GmailHeldLabels {
        heldLabels()
    }

    public func setUndoWindow(_ seconds: TimeInterval, engine: GmailAccountEngine) async {
        setUndoWindow(seconds)
    }

    public func networkChanged(engine: GmailAccountEngine) async {
        networkChanged()
    }
}

// MARK: - Drafts and imports (G6)

/// Drafts and imports as the engine offers them through `MailAccountEngine`. The app also talks
/// to `drafts` and `importer` directly, for Bcc, closing without saving, Discard with Undo and
/// imports that resume.
public struct GmailUploadsPart: GmailEngineUploads {
    public let drafts: GmailDrafts
    public let importer: GmailImporter

    public init(drafts: GmailDrafts, importer: GmailImporter) {
        self.drafts = drafts
        self.importer = importer
    }

    public func start(engine: GmailAccountEngine) async {
        await drafts.start()
    }

    public func saveDraft(_ raw: Data, as draft: DraftRef, engine: GmailAccountEngine) async throws -> DraftRef {
        try await drafts.save(raw, as: draft)
    }

    public func deleteDraft(_ draft: DraftRef, engine: GmailAccountEngine) async throws {
        try await drafts.delete(draft)
    }

    /// Into the folder's label, or Archive (All Mail) for a folder without one.
    public func importMessages(_ messages: [ImportedMessage], into folderID: UUID, engine: GmailAccountEngine,
                               progress: @escaping @Sendable (Int) -> Void) async throws {
        guard let folder = await engine.folders().first(where: { $0.id == folderID }) else {
            throw GmailEngineUnavailable(email: engine.account.email, what: "imports")
        }
        _ = try await importer.run(messages, into: folder.gmailLabelID) { step in
            if case .imported(let done, _) = step { progress(done) }
        }
    }

    public func draftIDs(for ids: [GmailMessageID], engine: GmailAccountEngine) async -> [GmailMessageID: String] {
        var out: [GmailMessageID: String] = [:]
        for id in ids {
            if let draftID = try? await drafts.draftID(forMessage: id) { out[id] = draftID }
        }
        return out
    }

    public func draftsChanged(engine: GmailAccountEngine) async {
        await drafts.draftsChanged()
    }

    public func flush(within seconds: TimeInterval, engine: GmailAccountEngine) async -> Bool {
        await drafts.flush(within: seconds)
    }
}

// MARK: - Search (G4)

/// Searches of one switched account, each a `GmailSearchSession` named by the id the app gave it,
/// so its hits show as the view `.search(id)`, as rows every action works on.
public actor GmailSearchPart: GmailEngineSearch {
    private let list: GmailListSource
    private let store: any GmailStore
    private let transport: any GmailTransport
    private var sessions: [UUID: GmailSearchSession] = [:]

    public init(list: GmailListSource, store: any GmailStore, transport: any GmailTransport) {
        self.list = list
        self.store = store
        self.transport = transport
    }

    /// While the owner types, only ids are asked for (5 units a page); `fetchRows` fetches the
    /// text of the first hits not known yet as well.
    public func search(_ query: String, id: UUID, fetchRows: Bool, engine: GmailAccountEngine) async throws {
        let session: GmailSearchSession
        if let running = sessions[id], running.query == query {
            session = running
        } else {
            if let old = sessions[id] { await old.end() }
            session = GmailSearchSession(id: id, query: query, source: list, store: store, transport: transport)
            sessions[id] = session
        }
        await session.lookUp()
        // Hits the index does not hold yet would be left out of the view until the first listing
        // reached them, which on a large mailbox takes minutes: they go in now.
        let unplaced = await session.unplacedHits()
        if !unplaced.isEmpty { await engine.placeSearchHits(unplaced) }
        if fetchRows { await session.fetchRows() }
    }

    public func endSearch(_ id: UUID, engine: GmailAccountEngine) async {
        await sessions.removeValue(forKey: id)?.end()
    }

    /// The search behind a view, for Show more and for whole-view actions.
    public func session(_ id: UUID) -> GmailSearchSession? {
        sessions[id]
    }
}

// MARK: - The whole account

/// A switched Google account's engine with every part installed. `start()` on the engine begins
/// the first listing or carries on from the last run; the Outbox sends through `sender` by way
/// of `RoutingSender`.
public struct GmailAccountAssembly: Sendable {
    public let engine: GmailAccountEngine
    public let list: GmailListSource
    public let actions: GmailActions
    public let drafts: GmailDrafts
    public let importer: GmailImporter
    public let sender: GmailSender
    public let search: GmailSearchPart
    public let transport: any GmailTransport
    public let store: any GmailStore

    /// - Parameters:
    ///   - listIndex: one for every account, so All Inboxes and searches over several accounts
    ///     are built in one place.
    ///   - rowBudget: the list's view of the account's bucket; with the HTTP transport, the real
    ///     one's.
    ///   - meter: the app's traffic meter, which the transport's budget books into; imports then
    ///     keep to its day's allowance instead of a ledger of their own.
    ///   - sentBcc: where the Bcc recipients of what the account sends are written down, the
    ///     Outbox's own sentBcc.json, so the reader shows them on the copy in Sent.
    ///   - events: what the engine says, as the IMAP engine says it, for the app's coordinator.
    public init(account: AccountInfo, transport: any GmailTransport, store: any GmailStore, listIndex: ListIndex = ListIndex(),
                mutes: MuteStore, rules: RuleStore?, settings: GmailEngineSettings = GmailEngineSettings(),
                clock: any GmailEngineClock = SystemGmailClock(), actionClock: GmailActionClock = .system,
                folderHints: [FolderInfo] = [], undoWindow: TimeInterval = 5, importAllowance: (any GmailImportAllowance)? = nil,
                meter: TrafficMeter? = nil, keepsOwnMessageID: Bool = false, rowBudget: RowFetchBudget? = nil,
                sentBcc: SentBccStore? = nil, events: @escaping @Sendable (SyncEvent) -> Void) async {
        let reachability = ReachabilityRelay()
        let engine = GmailAccountEngine(account: account, transport: transport, store: store, settings: settings, clock: clock,
                                        folderHints: folderHints, events: { event in
                                            if case .health(_, let health) = event { reachability.send(health) }
                                            events(event)
                                        })
        let budget = rowBudget ?? (transport as? GmailHTTPTransport).map { GmailBudgetEstimate(budget: $0.budget) } ?? TokenBucketEstimate()
        let list = GmailListSource(accountID: account.id, email: account.email, store: store, transport: transport,
                                   archiveFolderID: GmailLabelMapping.archiveFolderID(accountID: account.id, hints: folderHints),
                                   index: listIndex, ownAddresses: account.ownAddresses, budget: budget, now: { clock.now() },
                                   sleep: GmailWait.sleepQuietly)
        let actions = GmailActions(accountID: account.id, transport: transport, store: store, mutes: mutes, rules: rules, host: engine,
                                   undoWindow: undoWindow, clock: actionClock)
        let drafts = GmailDrafts(accountID: account.id, email: account.email, transport: transport, placer: engine,
                                 file: store.files.drafts, cursor: { await engine.historyCursor() }, now: { clock.now() })
        let allowance: any GmailImportAllowance = importAllowance
            ?? meter.map { TrafficMeterImportAllowance(meter: $0, accountID: account.id) }
            ?? RollingImportAllowance(file: store.files.importBytes, now: { clock.now() })
        let importer = GmailImporter(accountID: account.id, email: account.email, transport: transport, store: store, placer: engine,
                                     allowance: allowance, jobFile: store.files.importJob, now: { clock.now() },
                                     sleep: GmailWait.sleep)
        let sender = GmailSender(accountID: account.id, email: account.email, transport: transport, placer: engine,
                                 deleteDraft: { draftID in try await drafts.sent(draftID) },
                                 cursor: { await engine.historyCursor() },
                                 wentOut: { await engine.poke(reason: .messageSent) }, keepsOwnMessageID: keepsOwnMessageID,
                                 sentBcc: sentBcc)
        let search = GmailSearchPart(list: list, store: store, transport: transport)
        engine.install(GmailEngineParts(listSource: list, actions: actions, uploads: GmailUploadsPart(drafts: drafts, importer: importer),
                                        search: search))
        self.engine = engine
        self.list = list
        self.actions = actions
        self.drafts = drafts
        self.importer = importer
        self.sender = sender
        self.search = search
        self.transport = transport
        self.store = store
        // Connected before anyone can ask the list for a view, so no need a view finds is lost.
        await GmailAccountAssembly.connect(list: list, to: engine, reachability: reachability)
    }

    /// Keeps the list in step with the engine: rebuilt after every change it commits, given the
    /// rows it fetched for its own reasons, told what the listings know and whether Gmail can be
    /// reached, and its needs passed on. It returns once connected; the engine's streams, and the
    /// tasks that follow them, end when it stops.
    static func connect(list: GmailListSource, to engine: GmailAccountEngine, reachability: ReachabilityRelay) async {
        await list.setAnchorFiller(engine.anchorFiller)
        await list.setOnNeed { need in
            Task {
                switch need {
                case .attachments: await engine.wantListing(.attachments)
                case .sizes: await engine.wantListing(.sizes)
                case .anchors: await engine.setDateGroupsWanted(true)
                }
            }
        }
        await list.setOnFolderShown { label, rows in
            Task { await engine.noteFolderShown(label, rows: rows) }
        }
        let changes = await engine.indexChanges()
        let rows = await engine.rowUpdates()
        reachability.attach { health in
            // Paused by Google is the list's own to judge from the transport; only a Mac that
            // cannot reach Gmail, or an account that must sign in again, stops rows filling.
            let reachable: ListReachability
            switch health {
            case .offline, .needsSignIn, .blocked: reachable = .offline
            default: reachable = .online
            }
            Task { await list.setReachability(reachable) }
        }
        let initial = await engine.listingState()
        await list.setListingState(initial)
        Task {
            for await batch in rows { await list.engineRows(batch) }
        }
        Task {
            var known = initial
            for await _ in changes {
                let state = await engine.listingState()
                if state != known {
                    known = state
                    await list.setListingState(state)
                } else {
                    await list.refresh()
                }
            }
        }
    }
}

/// Hands the engine's health to the list once the two are connected; health said before then is
/// kept and handed over at once.
final class ReachabilityRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((AccountHealth) -> Void)?
    private var last: AccountHealth?

    func send(_ health: AccountHealth) {
        let handler = lock.withLock { () -> ((AccountHealth) -> Void)? in
            last = health
            return self.handler
        }
        handler?(health)
    }

    func attach(_ handler: @escaping (AccountHealth) -> Void) {
        let last = lock.withLock { () -> AccountHealth? in
            self.handler = handler
            return self.last
        }
        if let last { handler(last) }
    }
}
