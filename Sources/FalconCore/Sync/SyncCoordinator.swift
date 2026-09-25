import Foundation
import Network

/// Makes one Google account's Gmail engine. The app's makes it over HTTP to Gmail; tests make it
/// over the in-memory Gmail.
public typealias GmailEngineMaker = @Sendable (_ account: AccountInfo, _ setup: GmailEngineSetup) async -> GmailAccountAssembly

/// What the coordinator gives each Gmail engine it starts.
public struct GmailEngineSetup: Sendable {
    /// The account's folders as v1.10 kept them, read from memory only, whose ids the engine's
    /// folders keep, so rules, move targets and the selection survive the switch.
    public var folderHints: [FolderInfo]
    public var listIndex: ListIndex
    public var settings: GmailEngineSettings
    public var undoWindow: TimeInterval
    /// Where the engine says what it does, as the IMAP engine says it.
    public var events: @Sendable (SyncEvent) -> Void
}

/// Runs the read-only part of the probe (§14.4) once for an account over its engine's transport,
/// and says what it found; nil when it could not run.
public typealias GmailProbeRunner = @Sendable (_ account: AccountInfo, _ assembly: GmailAccountAssembly) async -> GmailProbeFindings?

/// Which accounts are on the Gmail API, which of their engines run, and why a switch waits.
public struct GmailEngineRoster: Sendable {
    /// Google accounts on the Gmail API, whose engine may not be running yet: nothing for them
    /// goes by IMAP or SMTP.
    public var gmailAccounts: Set<UUID> = []
    public var running: [UUID: GmailAccountAssembly] = [:]
    /// Why an account stays on IMAP although its switch is on, or why its switch could not be
    /// turned off, in the sentence Settings shows.
    public var notices: [UUID: String] = [:]

    public init() {}
}

/// Runs every account's engine: the Gmail engine for a Google account on the Gmail API, and the
/// IMAP engine (`AccountSyncer`) for every other account (§12.5). A Google account on the Gmail
/// API never gets an `AccountSyncer`, so it never opens an IMAP connection, and `TransportGuard`
/// refuses any that a mistake might open.
public actor SyncCoordinator {
    public let store: MailStore
    public let tokens: TokenStore
    public let rules: RuleStore
    public let mutes: MuteStore
    public let indexer: SpotlightIndexer
    public let pendingActions: PendingActionStore
    public let meter: TrafficMeter
    /// The one index every Google account's list on the Gmail engine builds its views in, so All
    /// Inboxes and a search over several accounts are built in one place.
    public nonisolated let listIndex = ListIndex()
    /// The owner's switch for each Google account, on unless he turned it off.
    public nonisolated let switches: any GmailEngineSwitchStore
    private let makeEngine: GmailEngineMaker
    private let probe: GmailProbeRunner?
    private let connector: IMAPConnector?
    private let pacing: SyncPacing
    private let guardian: TransportGuard
    /// The first wait before a switch held back by IMAP actions is tried again; it doubles after
    /// each try, up to half an hour, so an account offline for long is not asked every minute.
    private let switchRetry: TimeInterval
    /// How long turning the switch off waits for Gmail to take what waits.
    private let switchOffWait: TimeInterval
    private var syncers: [UUID: AccountSyncer] = [:]
    private var engines: [UUID: GmailAccountAssembly] = [:]
    private var gmailAccounts: Set<UUID> = []
    private var notices: [UUID: String] = [:]
    /// Accounts whose switch is on but whose IMAP actions still wait: tried again now and then.
    private var switchRetries: [UUID: Task<Void, Never>] = [:]
    private var probes: [UUID: Task<Void, Never>] = [:]
    private var turns: [UUID: Task<Void, Never>] = [:]
    private var spotlightFeeds: [UUID: Task<Void, Never>] = [:]
    /// Accounts whose "Show All Gmail Labels" is on.
    private var labelsShownAll: Set<UUID> = []
    private var rosterListeners: [UUID: AsyncStream<GmailEngineRoster>.Continuation] = [:]
    private var heartbeat: Task<Void, Never>?
    private var meterSaves: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private let eventContinuation: AsyncStream<SyncEvent>.Continuation
    public nonisolated let events: AsyncStream<SyncEvent>

    /// - Parameters:
    ///   - switches: the owner's switch per Google account.
    ///   - makeEngine: makes a Google account's Gmail engine; by default over HTTP to Gmail, with
    ///     its files under `Accounts/<id>/Gmail/`.
    ///   - probe: the read-only probe, run once per account when its engine first starts; nil
    ///     runs none, as in tests.
    ///   - connector, pacing: the IMAP engine's, for tests.
    public init(store: MailStore, tokens: TokenStore, rules: RuleStore, mutes: MuteStore, indexer: SpotlightIndexer,
                pendingActions: PendingActionStore, meter: TrafficMeter = .shared,
                switches: any GmailEngineSwitchStore = DefaultsGmailEngineSwitchStore(),
                makeEngine: GmailEngineMaker? = nil, probe: GmailProbeRunner? = nil,
                connector: IMAPConnector? = nil, pacing: SyncPacing = .standard, transportGuard: TransportGuard = .shared,
                switchRetry: TimeInterval = 60, switchOffWait: TimeInterval = 15) {
        self.store = store
        self.tokens = tokens
        self.rules = rules
        self.mutes = mutes
        self.indexer = indexer
        self.pendingActions = pendingActions
        self.meter = meter
        self.switches = switches
        self.makeEngine = makeEngine ?? SyncCoordinator.httpEngine(tokens: tokens, layout: store.layout, mutes: mutes, rules: rules, meter: meter)
        self.probe = probe
        self.connector = connector
        self.pacing = pacing
        self.guardian = transportGuard
        self.switchRetry = switchRetry
        self.switchOffWait = switchOffWait
        var cont: AsyncStream<SyncEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.eventContinuation = cont
    }

    /// A Google account's Gmail engine over HTTP to Gmail, within its own budget, booking its
    /// bytes into the traffic meter, with its files under `Accounts/<id>/Gmail/`.
    public static func httpEngine(tokens: TokenStore, layout: FileLayout, mutes: MuteStore, rules: RuleStore,
                                  meter: TrafficMeter) -> GmailEngineMaker {
        { account, setup in
            // The budget's wait is given rather than left to its default: a debug build of Swift
            // 6.2 miscompiles an async closure given as a default argument.
            let budget = GmailBudget(accountID: account.id, meter: meter, sleep: { seconds in
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            })
            let transport = GmailHTTPTransport(api: GoogleAPI(tokens: tokens, accountID: account.id), budget: budget)
            let store = GmailFileStore(accountID: account.id, files: GmailFiles(layout: layout, accountID: account.id))
            return await GmailAccountAssembly(account: account, transport: transport, store: store, listIndex: setup.listIndex,
                                              mutes: mutes, rules: rules, settings: setup.settings, folderHints: setup.folderHints,
                                              undoWindow: setup.undoWindow, meter: meter, events: setup.events)
        }
    }

    /// The read-only part of the probe over the engine's own transport and budget. Its write
    /// part never runs here.
    public static let readOnlyProbe: GmailProbeRunner = { account, assembly in
        guard let transport = assembly.transport as? GmailHTTPTransport else { return nil }
        do {
            let report = try await GmailProbe(transport: transport, testAccount: account.email, writesApproved: false).run()
            return GmailProbeFindings(report)
        } catch {
            Log.info("probe", "\(account.email): the read-only probe stopped: \(error.localizedDescription)")
            return nil
        }
    }

    public func startAll() async {
        for account in await store.allAccounts() where account.isEnabled {
            await start(account: account)
        }
        startHeartbeat()
        startSavingTheMeter()
        watchTheNetwork()
    }

    /// The download count is saved every minute, so that a crash loses at most a minute of it
    /// and a relaunch cannot hand an account a fresh allowance.
    private func startSavingTheMeter() {
        guard meterSaves == nil else { return }
        let meter = meter
        meterSaves = Task(priority: .background) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                meter.persist()
            }
        }
    }

    /// A new network, or the one back after a gap, leaves connections that may be dead without
    /// knowing it; every account opens fresh ones, and every Gmail engine checks for changes.
    private func watchTheNetwork() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        let seen = PathMemory()
        monitor.pathUpdateHandler = { [weak self] path in
            guard seen.changed(to: path), path.status == .satisfied else { return }
            Task { await self?.networkChanged() }
        }
        monitor.start(queue: DispatchQueue(label: "falconmail.network"))
        pathMonitor = monitor
    }

    /// The network changed, or came back.
    public func networkChanged() async {
        await reconnectAll(reason: "the network changed")
        for assembly in engines.values {
            let engine = assembly.engine
            Task {
                await engine.parts.actions?.networkChanged(engine: engine)
                await assembly.drafts.retryWaiting()
                await engine.poke(reason: .networkChange)
            }
        }
        for id in switchRetries.keys { await retrySwitch(id) }
    }

    /// The Mac woke: every IMAP account opens fresh connections and every Gmail engine checks for
    /// changes at once, so mail that came in during sleep shows within seconds.
    public func macWoke() async {
        await reconnectAll(reason: "the Mac woke")
        for assembly in engines.values {
            let engine = assembly.engine
            Task { await engine.poke(reason: .wake) }
        }
    }

    /// Every running IMAP account closes its connections and opens them again, as after the Mac
    /// wakes, unless Gmail has asked it to wait.
    public func reconnectAll(reason: String) async {
        for s in syncers.values { await s.reconnect(reason: reason) }
    }

    /// A line every half hour while FalconMail runs, so a log that goes quiet means FalconMail
    /// was not running rather than that nothing went wrong.
    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        heartbeat = Task(priority: .background) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.logAlive()
            }
        }
    }

    private func logAlive() async {
        var downloaded = 0
        var uploaded = 0
        for id in syncers.keys {
            downloaded += meter.used(.download, by: id)
            uploaded += meter.used(.upload, by: id)
        }
        let google = guardian.connectionsToGoogle.values.reduce(0, +)
        Log.info("app", "alive accounts=\(syncers.count + engines.count) gmailAPI=\(engines.count) imapDown24h=\(downloaded / 1_000_000)MB "
                 + "imapUp24h=\(uploaded / 1_000_000)MB googleIMAPConnections=\(google) blocked=\(guardian.refusals.count)")
    }

    public var bodyPrefetch = 150
    public var maxOfflineBodyBytes = 5 * 1024 * 1024
    public var undoWindow: TimeInterval = 5

    public func setBodyPrefetch(_ count: Int, maxBytes: Int? = nil) async {
        bodyPrefetch = count
        if let maxBytes { maxOfflineBodyBytes = maxBytes }
        for s in syncers.values { await s.setBodyPrefetch(count, maxBytes: maxOfflineBodyBytes) }
    }

    /// "Show All Gmail Labels" for a Google account, from Settings → Accounts or the sidebar: its
    /// engine is started with it, and the engine running now reads its labels again at once.
    public func setShowsAllLabels(_ shown: Bool, accountID: UUID) async {
        if shown { labelsShownAll.insert(accountID) } else { labelsShownAll.remove(accountID) }
        await engines[accountID]?.engine.setShowsAllLabels(shown)
    }

    public func setUndoWindow(_ seconds: TimeInterval) async {
        undoWindow = max(0, seconds)
        for s in syncers.values { await s.setUndoWindow(undoWindow) }
        for a in engines.values { await a.engine.setUndoWindow(undoWindow) }
    }

    /// Ends every undo window and sends what waits, as at quit: the IMAP accounts' actions, and
    /// each Gmail engine's changes and draft deletes, for at most five seconds.
    public func flushPendingActions() async {
        for s in syncers.values { await s.flushPending() }
        let running = Array(engines.values)
        await withTaskGroup(of: Void.self) { group in
            for assembly in running {
                group.addTask {
                    _ = await assembly.engine.flushPending(within: 5)
                    _ = await assembly.drafts.flush(within: 5)
                }
            }
        }
    }

    // MARK: - Starting an account on its engine

    public func start(account: AccountInfo) async {
        await inTurn(account.id) { await $0.startNow(account) }
    }

    /// One start or stop of an account at a time, in the order asked: two engines on one
    /// account at once would both write its store.
    private func inTurn(_ accountID: UUID, _ work: @escaping @Sendable (SyncCoordinator) async -> Void) async {
        let previous = turns[accountID]
        let turn = Task { [self] in
            await previous?.value
            await work(self)
        }
        turns[accountID] = turn
        await turn.value
        if turns[accountID] == turn { turns[accountID] = nil }
    }

    private func startNow(_ account: AccountInfo) async {
        guard account.isEnabled else { await stopNow(account.id); return }
        await stopRunning(account.id)
        if GmailEngineSwitch.isOn(account, in: switches) {
            if await moveToGmail(account) {
                await startEngine(account)
            } else {
                await startSyncer(account)
            }
        } else if await leaveGmail(account) {
            await startSyncer(account)
        } else {
            await startEngine(account)
        }
        if !account.usesPassword { await tokens.keepFresh(account.id) }
    }

    private func startSyncer(_ account: AccountInfo) async {
        let s = AccountSyncer(account: account, store: store, tokens: tokens, rules: rules, mutes: mutes, indexer: indexer,
                              pendingActions: pendingActions, events: eventContinuation, meter: meter, pacing: pacing, connector: connector)
        await s.setBodyPrefetch(bodyPrefetch, maxBytes: maxOfflineBodyBytes)
        await s.setUndoWindow(undoWindow)
        syncers[account.id] = s
        await s.start()
    }

    private func startEngine(_ account: AccountInfo) async {
        let migration = GmailMigrationFile(files: GmailFiles(layout: store.layout, accountID: account.id))
        let record = migration.load()
        var settings = GmailEngineSettings()
        if let findings = record.probe { settings = findings.adapted(settings) }
        settings.showsAllLabels = labelsShownAll.contains(account.id)
        let continuation = eventContinuation
        let setup = GmailEngineSetup(folderHints: await store.folders(for: account.id), listIndex: listIndex, settings: settings,
                                     undoWindow: undoWindow, events: { continuation.yield($0) })
        let assembly = await makeEngine(account, setup)
        engines[account.id] = assembly
        await assembly.engine.setUndoWindow(undoWindow)
        await assembly.engine.start()
        // Spotlight holds the messages kept on the Mac, the newest 1,000, and nothing else.
        let indexer = indexer
        let changes = await assembly.engine.indexChanges()
        spotlightFeeds[account.id] = Task(priority: .utility) {
            await indexer.follow(accountID: account.id, store: assembly.store, changes: changes)
        }
        Log.info("gmail", "\(account.email): started on the Gmail API")
        publish()
        if record.probeRanAt == nil { runProbe(account, assembly) }
    }

    /// The read-only probe, once per account, when its engine first starts; its findings are
    /// logged and the engine follows them from its next start.
    private func runProbe(_ account: AccountInfo, _ assembly: GmailAccountAssembly) {
        guard let probe, probes[account.id] == nil else { return }
        let files = GmailFiles(layout: store.layout, accountID: account.id)
        probes[account.id] = Task(priority: .utility) { [weak self] in
            // A probe that could not finish, as when the Mac went offline, runs again at the
            // engine's next start; one that did never runs again.
            if let findings = await probe(account, assembly), !Task.isCancelled {
                GmailMigrationFile(files: files).update { record in
                    record.probeRanAt = Date()
                    record.probe = findings
                }
                Log.info("probe", "\(account.email): \(findings.logLine)")
                let before = GmailEngineSettings()
                let after = findings.adapted(before)
                if after.countRule != before.countRule || after.listsChats != before.listsChats {
                    Log.info("probe", "\(account.email): counts and chats follow the findings from the engine's next start")
                }
            }
            await self?.probeEnded(account.id)
        }
    }

    private func probeEnded(_ accountID: UUID) {
        probes[accountID] = nil
    }

    // MARK: - The switch (§12.1, §12.6)

    /// Moves the account to the Gmail API unless IMAP actions still wait, which are sent first,
    /// the account's last use of IMAP. False while any still waits: the account stays on IMAP
    /// and the switch is tried again later.
    private func moveToGmail(_ account: AccountInfo) async -> Bool {
        let migration = GmailMigrationFile(files: GmailFiles(layout: store.layout, accountID: account.id))
        var record = migration.load()
        if !record.isOnGmail {
            if await hasWaitingIMAPActions(account.id) {
                let syncer = AccountSyncer(account: account, store: store, tokens: tokens, rules: rules, mutes: mutes, indexer: indexer,
                                           pendingActions: pendingActions, events: eventContinuation, meter: meter, pacing: pacing,
                                           connector: connector)
                let left = await syncer.sendWaitingActions()
                await syncer.stop()
                if left > 0 {
                    Log.info("gmail", "\(account.email): \(left) IMAP actions still wait, so it stays on IMAP until they have gone")
                    notices[account.id] = GmailEngineSwitch.waitingNotice(account.email)
                    gmailAccounts.remove(account.id)
                    scheduleSwitchRetry(account.id)
                    publish()
                    return false
                }
            }
            let now = Date()
            record.switchedAt = now
            record.firstSwitchedAt = record.firstSwitchedAt ?? now
            record.spotlightCleared = false
            migration.save(record)
            Log.info("gmail", "\(account.email): moved to the Gmail API; its IMAP store is kept as it was")
        }
        switchRetries.removeValue(forKey: account.id)?.cancel()
        notices[account.id] = nil
        gmailAccounts.insert(account.id)
        guardian.blockMailServers(for: account)
        await store.seal(account.id)
        if record.spotlightCleared != true {
            // The cached 1,000 are indexed again as they arrive.
            await indexer.removeAccount(account.id)
            migration.update { $0.spotlightCleared = true }
        }
        publish()
        return true
    }

    /// Takes the account off the Gmail API unless changes still wait to reach Gmail, which would
    /// otherwise be undone by the IMAP engine's next pass. False while any waits: the account
    /// stays on the Gmail API and the switch stays on.
    private func leaveGmail(_ account: AccountInfo) async -> Bool {
        let files = GmailFiles(layout: store.layout, accountID: account.id)
        let migration = GmailMigrationFile(files: files)
        var record = migration.load()
        guard record.isOnGmail || gmailAccounts.contains(account.id) else {
            unblock(account.id)
            return true
        }
        let waiting = PendingGmailOpsFile(files: files).load().ops.contains { !$0.isCommitted }
        if waiting {
            Log.info("gmail", "\(account.email): changes wait to reach Gmail, so it stays on the Gmail API")
            notices[account.id] = GmailEngineSwitch.cannotTurnOffNotice(account.email)
            switches.setChoice(true, for: account.id)
            publish()
            return false
        }
        record.switchedAt = nil
        record.switchedOffAt = Date()
        record.spotlightCleared = nil
        migration.save(record)
        Log.info("gmail", "\(account.email): back on IMAP; the Gmail engine's files are kept for the next time")
        unblock(account.id)
        return true
    }

    private func unblock(_ accountID: UUID) {
        gmailAccounts.remove(accountID)
        guardian.allowMailServers(for: accountID)
        notices[accountID] = nil
        Task { await store.unseal(accountID) }
        publish()
    }

    /// Turns the account's switch on or off, as Settings → Accounts does. Turning it off sends
    /// the changes still waiting for Gmail first, and refuses, keeping the switch on, while any
    /// cannot be sent (§12.6). Turning it on sends the IMAP actions still waiting first, and the
    /// account stays on IMAP until they have gone (§12.1). Returns the sentence to show when the
    /// switch did not move, nil when it did.
    @discardableResult
    public func setGmailEngine(_ on: Bool, for account: AccountInfo) async -> String? {
        guard GmailEngineSwitch.isEligible(account) else { return nil }
        if on {
            switches.setChoice(true, for: account.id)
            if let syncer = syncers[account.id] { await syncer.flushPending() }
            await start(account: account)
            return gmailAccounts.contains(account.id) ? nil : notices[account.id]
        }
        if let assembly = engines[account.id] {
            let sent = await assembly.engine.flushPending(within: switchOffWait)
            _ = await assembly.drafts.flush(within: switchOffWait)
            guard sent else {
                notices[account.id] = GmailEngineSwitch.cannotTurnOffNotice(account.email)
                publish()
                return notices[account.id]
            }
        }
        switches.setChoice(false, for: account.id)
        await start(account: account)
        guard !gmailAccounts.contains(account.id) else { return notices[account.id] }
        return nil
    }

    private func hasWaitingIMAPActions(_ accountID: UUID) async -> Bool {
        await pendingActions.all().contains { $0.accountID == accountID }
    }

    private func scheduleSwitchRetry(_ accountID: UUID) {
        guard switchRetries[accountID] == nil else { return }
        let first = switchRetry
        switchRetries[accountID] = Task { [weak self] in
            var wait = first
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await self.retrySwitch(accountID)
                wait = min(wait * 2, 30 * 60)
            }
        }
    }

    /// Tries the switch again: the IMAP actions still waiting are sent, as at the first try, and
    /// the account moves once none is left. The IMAP engine is stopped meanwhile, so no action
    /// is sent twice.
    private func retrySwitch(_ accountID: UUID) async {
        guard !gmailAccounts.contains(accountID), let account = await store.account(accountID), account.isEnabled,
              GmailEngineSwitch.isOn(account, in: switches) else { return }
        await start(account: account)
        if gmailAccounts.contains(accountID) { switchRetries.removeValue(forKey: accountID)?.cancel() }
    }

    // MARK: - Stopping

    private func stopRunning(_ accountID: UUID) async {
        probes.removeValue(forKey: accountID)?.cancel()
        spotlightFeeds.removeValue(forKey: accountID)?.cancel()
        if let s = syncers.removeValue(forKey: accountID) { await s.stop() }
        if let a = engines.removeValue(forKey: accountID) {
            await a.engine.stop()
            publish()
        }
    }

    public func stop(accountID: UUID) async {
        await inTurn(accountID) { await $0.stopNow(accountID) }
    }

    private func stopNow(_ accountID: UUID) async {
        await tokens.stopKeepingFresh(accountID)
        switchRetries.removeValue(forKey: accountID)?.cancel()
        await stopRunning(accountID)
    }

    public func stopAll() async {
        heartbeat?.cancel()
        heartbeat = nil
        meterSaves?.cancel()
        meterSaves = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        for task in switchRetries.values { task.cancel() }
        switchRetries.removeAll()
        for id in Set(syncers.keys).union(engines.keys) {
            await inTurn(id) { await $0.stopNow(id) }
        }
        meter.persist()
    }

    // MARK: - Asking which engine

    public func syncer(for accountID: UUID) -> AccountSyncer? { syncers[accountID] }

    /// The Gmail engine of a Google account on the Gmail API, while it runs.
    public func assembly(for accountID: UUID) -> GmailAccountAssembly? { engines[accountID] }

    /// Whether the account is on the Gmail API, running or not.
    public func usesGmail(_ accountID: UUID) -> Bool { gmailAccounts.contains(accountID) }

    /// How the Outbox sends for the account: by Gmail's own send for an account on the Gmail API,
    /// never by SMTP, even while its engine is not running; by SMTP for every other.
    public func sendRoute(for accountID: UUID) -> SendRoute {
        if let assembly = engines[accountID] { return .gmail(assembly.sender) }
        return gmailAccounts.contains(accountID) ? .gmailUnavailable : .smtp
    }

    public var roster: GmailEngineRoster {
        var roster = GmailEngineRoster()
        roster.gmailAccounts = gmailAccounts
        roster.running = engines
        roster.notices = notices
        return roster
    }

    /// The roster now, then again each time it changes.
    public func rosterUpdates() -> AsyncStream<GmailEngineRoster> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: GmailEngineRoster.self, bufferingPolicy: .bufferingNewest(1))
        rosterListeners[id] = continuation
        continuation.onTermination = { _ in Task { await self.dropRosterListener(id) } }
        continuation.yield(roster)
        return stream
    }

    private func dropRosterListener(_ id: UUID) { rosterListeners[id] = nil }

    private func publish() {
        let now = roster
        for listener in rosterListeners.values { listener.yield(now) }
    }

    // MARK: - Checking

    /// Every account: IMAP accounts sync, and each Gmail engine checks for changes.
    public func syncNow() async {
        for s in syncers.values { await s.requestSync() }
        for a in engines.values {
            let engine = a.engine
            Task { await engine.poke(reason: .sendAndReceive) }
        }
    }

    /// The accounts being kept in sync, which a check for new mail asks.
    public var runningAccountIDs: Set<UUID> { Set(syncers.keys).union(engines.keys) }

    /// Send & Receive: a sync of every IMAP account whose pass ends with `checked`, and a check of
    /// every Gmail engine, which ends with `checked` too.
    public func checkForNewMail() async {
        for s in syncers.values { await s.requestSync(check: true) }
        for a in engines.values {
            let engine = a.engine
            Task { await engine.poke(reason: .sendAndReceive) }
        }
    }

    /// How active the owner is, which sets how often each Gmail engine checks for changes.
    public func noteOwnerActivity(_ activity: OwnerActivity) async {
        for a in engines.values { await a.engine.noteOwnerActivity(activity) }
    }
}

public struct SMTPSender: MessageSender {
    let store: MailStore
    private let syncer: @Sendable (UUID) async -> AccountSyncer?
    private let deliver: @Sendable (_ account: AccountInfo, _ from: String, _ recipients: [String], _ message: Data) async throws -> Void

    public init(store: MailStore, tokens: TokenStore, coordinator: SyncCoordinator? = nil) {
        self.init(store: store, syncer: { await coordinator?.syncer(for: $0) }) { account, from, recipients, message in
            try await SMTPSender.deliver(message, from: from, to: recipients, account: account, tokens: tokens)
        }
    }

    /// Tests hand over the message here instead of to an SMTP server.
    init(store: MailStore, syncer: @escaping @Sendable (UUID) async -> AccountSyncer?,
         deliver: @escaping @Sendable (_ account: AccountInfo, _ from: String, _ recipients: [String], _ message: Data) async throws -> Void) {
        self.store = store
        self.syncer = syncer
        self.deliver = deliver
    }

    public func send(accountID: UUID, from: String, recipients: [String], message: Data) async throws {
        guard let account = await store.account(accountID) else { throw FalconError.storage("account missing") }
        try await deliver(account, from, recipients, message)
        guard let syncer = await syncer(account.id) else { return }
        if account.provider == "google" {
            // Gmail files what went out in Sent Mail itself; only that folder is synced for it.
            await syncer.messageWentOut()
        } else {
            await appendToSentFolder(message, account: account, syncer: syncer)
        }
    }

    private static func deliver(_ message: Data, from: String, to recipients: [String], account: AccountInfo, tokens: TokenStore) async throws {
        let smtp = SMTPClient(host: account.smtpHost, port: account.smtpPort, user: account.usesPassword ? account.loginName : account.email)
        do {
            try await smtp.connect()
            if account.usesPassword {
                try await smtp.authenticatePlain(user: account.loginName, password: try await tokens.password(for: account.id))
            } else {
                let token = try await tokens.validAccessToken(for: account.id)
                try await smtp.authenticateXOAuth2(user: account.email, accessToken: token)
            }
            try await smtp.send(from: from, recipients: recipients, message: message)
        } catch {
            await smtp.quit()
            throw MailServiceError.classify(error, account: account)
        }
        await smtp.quit()
    }

    private func appendToSentFolder(_ message: Data, account: AccountInfo, syncer: AccountSyncer) async {
        let folders = await store.folders(for: account.id)
        guard let sent = folders.first(where: { $0.role == .sent && $0.isSelectable }) else { return }
        try? await syncer.append(raw: message, to: sent, flags: .seen, date: Date())
    }
}

/// The last network path seen, to tell a real change from the monitor repeating itself.
private final class PathMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var last: String?

    /// False for the first path, which is the one FalconMail started on.
    func changed(to path: NWPath) -> Bool {
        let now = "\(path.status) \(path.availableInterfaces.map(\.name).joined(separator: ","))"
        return lock.withLock {
            defer { last = now }
            return last != nil && last != now
        }
    }
}
