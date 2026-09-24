import Foundation

public enum SyncEvent: Sendable {
    case started(accountID: UUID)
    case progress(accountID: UUID, text: String)
    case folderSynced(folderID: UUID)
    case newMessages(accountID: UUID, folderID: UUID, messages: [MessageSummary])
    case error(accountID: UUID, message: String)
    case actionFailed(accountID: UUID, message: String)
    case health(accountID: UUID, AccountHealth)
    case finished(accountID: UUID)
}

/// Opens and signs in an IMAP connection for an account, counting its bytes through the tap.
/// Tests connect to a fake server here.
public typealias IMAPConnector = @Sendable (AccountInfo, TrafficTap) async throws -> IMAPClient

/// How much the engine asks of a server, and how often. Tests shrink the times, so that a
/// cool-down of half an hour takes a second.
public struct SyncPacing: Sendable {
    /// Every folder is looked at this often.
    public var fullSyncInterval: TimeInterval = 5 * 60
    /// IDLE is ended and begun again this often, inside the 265–275 s after which something
    /// between FalconMail and Gmail drops a silent connection.
    public var idleRefresh: TimeInterval = 240
    /// A folder with more new mail than one pass takes gets its next pass no sooner than this.
    public var catchUpInterval: TimeInterval = 5 * 60
    /// A folder the server reports empty, where many messages are listed, is emptied only when
    /// a pass at least this much later finds it empty too.
    public var emptyFolderConfirmation: TimeInterval = 60
    /// The least time between two attempts to connect, so that flapping Wi-Fi cannot make a
    /// burst of sign-ins.
    public var minimumReconnectInterval: TimeInterval = 30
    /// The longest wait between attempts while they keep failing.
    public var maximumReconnectInterval: TimeInterval = 300
    /// How long a dropped connection is retried quietly before the owner is told.
    public var quietReconnectPeriod: TimeInterval = 120
    /// Gmail's successive cool-downs; a throttle within `throttleMemory` of the last one takes
    /// the next, longer step.
    public var throttlePauses: [TimeInterval] = [30, 60, 120, 240].map { $0 * 60 }
    public var throttleMemory: TimeInterval = 24 * 60 * 60
    /// How long no new connection is opened after the server refused one because other
    /// programs hold all it allows, a time picked at random from this range.
    public var connectionLimitWait: ClosedRange<TimeInterval> = 300...600
    /// A server that wants the owner in a web browser is asked again after this, or sooner when
    /// the owner asks for mail or the Mac wakes.
    public var blockedRetry: TimeInterval = 60 * 60
    /// However many messages are saved to a folder, it is synced for them at most this often.
    public var appendSyncSpacing: TimeInterval = 30
    /// After a message goes out through Gmail, Sent is synced these many seconds later, twice
    /// because Gmail can take a while to show it there over IMAP.
    public var sentSyncDelays: [TimeInterval] = [5, 30]
    /// A job waiting for its allowance looks again at least this often.
    public var budgetRecheck: TimeInterval = 60
    /// Rules and mutes run on mail dated within this, and new-mail notifications go out for mail
    /// dated within `notifyWindow`: old mail arriving now, as an import brings, is filed as it is.
    public var ruleWindow: TimeInterval = 48 * 60 * 60
    public var notifyWindow: TimeInterval = 24 * 60 * 60
    /// A folder's first pass lists this many of its newest messages.
    public var initialWindow = 1000
    /// The most new messages one pass takes.
    public var catchUpWindow = 2000
    /// A pass checks the flags of this many of the newest messages, and of one slice of this
    /// many older ones, a different slice each pass.
    public var flagWindow = 1000

    public init() {}

    public static let standard = SyncPacing()
}

/// How much of a folder a pass looks at.
public enum FolderPass: Sendable {
    /// New messages, flags and deletions.
    case full
    /// New messages only, as when IDLE says something arrived.
    case newOnly
}

public actor AccountSyncer {
    public let account: AccountInfo
    private let store: MailStore
    private let tokens: TokenStore
    private let rules: RuleStore
    private let mutes: MuteStore
    /// Nil for a syncer that indexes nothing in Spotlight, as in the tests, which must not add
    /// to the index of the Mac they run on.
    private let indexer: SpotlightIndexer?
    private let pendingActions: PendingActionStore
    private let events: AsyncStream<SyncEvent>.Continuation
    private let connector: IMAPConnector
    private let pacing: SyncPacing
    private var extras: SyncExtrasFile
    private var syncClient: IMAPClient?
    /// Everything the reader asks for (opening a message, actions, drafts, rules, older mail)
    /// shares this connection, one unit of work at a time.
    private var opClient: IMAPClient?
    private var opConnecting: Task<IMAPClient, Error>?
    private var loopTask: Task<Void, Never>?
    private var syncRequested = false
    /// Folders to bring up to date on their own, without a whole pass over the account.
    private var requestedFolders: [UUID] = []
    private var health: AccountHealth?
    /// Set when the server asked FalconMail to slow down, on whichever connection it said so,
    /// or when the day's download is used up: until then nothing more is asked of it and no
    /// connection is opened.
    private var imapPause: (kind: MailServiceError.Kind, until: Date)?
    /// Set when the server refused a new connection because other programs hold all it
    /// allows: until then no connection is opened, while those already open go on working.
    private var connectionLimit: Date?
    private var downSince: Date?
    private var isStopped = false
    /// Attempts to connect that failed since the account last synced.
    private var failures = 0
    private var lastConnectAttempt: Date?
    /// The loop opens no connection before this.
    private var nextConnect: Date?
    /// Set while the sync connection is being closed on purpose, so that its end is not taken
    /// for a failure.
    private var reconnecting = false
    private var nap: (task: Task<Void, Never>, wakesEarly: Bool)?
    /// Folders with more new mail than one pass takes: when the next pass may take more, and
    /// the messages still to fetch.
    private var catchUps: [UUID: (notBefore: Date, unfetched: [UInt32])] = [:]
    /// Folders whose full passes have found the server reporting none of the messages listed,
    /// and since when.
    private var reportedEmpty: [UUID: Date] = [:]
    private var appendSyncs: [UUID: Task<Void, Never>] = [:]
    private var lastAppendSync: [UUID: Date] = [:]
    private var sentSyncs: Task<Void, Never>?
    public var bodyPrefetch = 150
    public var maxOfflineBodyBytes = 5 * 1024 * 1024
    public var bodyPrefetchBudget = 64 * 1024 * 1024
    public var maxEagerPrefetchBytes = 1024 * 1024
    private let meter: TrafficMeter
    private var budgetNoticeGiven = false

    public var undoWindow: TimeInterval = 5
    private let batchSize = 100
    private var held: [UUID: HeldAction] = [:]
    private var suppressedUIDs: [UUID: [UInt32: Int]] = [:]
    private static let staleOperationAge: TimeInterval = 24 * 60 * 60

    private struct HeldAction {
        let record: MailActionRecord
        let pending: PendingServerOperation
        var task: Task<Void, Never>?
    }

    public init(account: AccountInfo, store: MailStore, tokens: TokenStore, rules: RuleStore, mutes: MuteStore,
                indexer: SpotlightIndexer?, pendingActions: PendingActionStore, events: AsyncStream<SyncEvent>.Continuation,
                meter: TrafficMeter? = nil, pacing: SyncPacing = .standard, connector: IMAPConnector? = nil) {
        self.account = account
        self.store = store
        self.tokens = tokens
        self.rules = rules
        self.mutes = mutes
        self.indexer = indexer
        self.pendingActions = pendingActions
        self.events = events
        self.meter = meter ?? .shared
        self.pacing = pacing
        self.extras = SyncExtrasFile(layout: store.layout, account: account)
        self.connector = connector ?? { account, traffic in try await AccountSyncer.signIn(account, tokens: tokens, traffic: traffic) }
    }

    public func setUndoWindow(_ seconds: TimeInterval) {
        undoWindow = max(0, seconds)
    }

    public func start() {
        guard loopTask == nil else { return }
        // Background priority so a long sync always yields to anything the reader is doing.
        loopTask = Task(priority: .utility) { [weak self] in
            await self?.loop()
        }
    }

    public func stop() async {
        isStopped = true
        loopTask?.cancel()
        loopTask = nil
        opConnecting?.cancel()
        nap?.task.cancel()
        for task in appendSyncs.values { task.cancel() }
        appendSyncs.removeAll()
        sentSyncs?.cancel()
        for action in held.values { action.task?.cancel() }
        held.removeAll()
        suppressedUIDs.removeAll()
        try? await syncClient?.finishIdle()
        await syncClient?.logout()
        await opClient?.logout()
        syncClient = nil
        opClient = nil
    }

    /// A whole pass over the account soon. Asked for by the owner, it also cuts short a wait
    /// between failed attempts to connect, or one for the owner to sign in on the web.
    public func requestSync() async {
        syncRequested = true
        wakeEarly()
        try? await syncClient?.finishIdle()
    }

    /// Brings one folder up to date soon, on its own, for example after a message in it turned
    /// out to be gone.
    public func requestSync(folderID: UUID) async {
        if !requestedFolders.contains(folderID) { requestedFolders.append(folderID) }
        try? await syncClient?.finishIdle()
    }

    /// Brings the folder with `role` up to date soon, on its own.
    public func requestSync(role: FolderRole) async {
        guard let folder = await store.folder(accountID: account.id, role: role), folder.isSelectable else { return }
        await requestSync(folderID: folder.id)
    }

    /// Closes the account's connections and opens them again, as after the Mac wakes or the
    /// network changes, when they may be dead without knowing it. Not during a pause Gmail
    /// asked for, nor while the server allows no new connection, which would leave the account
    /// with none; and never sooner than the least time between attempts.
    public func reconnect(reason: String) async {
        guard loopTask != nil, pauseRemaining() == nil, connectionLimitRemaining() == nil else { return }
        Log.info("sync", "\(account.email): reconnecting, \(reason)")
        failures = 0
        wakeEarly()
        if let c = syncClient {
            reconnecting = true
            syncClient = nil
            await c.logout()
        }
        if let c = opClient {
            opClient = nil
            await c.logout()
        }
    }

    /// After a message went out through Gmail's SMTP, which files it in Sent Mail itself.
    public func messageWentOut() {
        guard account.provider == "google" else { return }
        sentSyncs?.cancel()
        let delays = pacing.sentSyncDelays
        sentSyncs = Task { [weak self] in
            var waited: TimeInterval = 0
            for delay in delays {
                try? await Task.sleep(nanoseconds: UInt64(max(0, delay - waited) * 1_000_000_000))
                waited = delay
                guard !Task.isCancelled else { return }
                await self?.requestSync(role: .sent)
            }
        }
    }

    private func setHealth(_ new: AccountHealth) {
        guard health != new else { return }
        health = new
        Log.info("health", "\(account.email): \(new.logName)")
        events.yield(.health(accountID: account.id, new))
    }

    private func loop() async {
        resumeStoredPause()
        while !Task.isCancelled {
            if let problem = await store.folderListProblem(account.id) {
                // Syncing would write a new folder list and orphan every folder stored under the old one.
                let failure = MailServiceError(kind: .folderListUnreadable, account: account, detail: problem.detail, name: problem.fileName)
                Log.info("sync", "\(account.email): not syncing, \(problem.detail)")
                setHealth(.blocked(reason: failure.sentence))
                events.yield(.error(accountID: account.id, message: failure.sentence))
                return
            }
            if let left = pauseRemaining() {
                await rest(left, wakesEarly: false)
                continue
            }
            if !meter.allows(.download, for: account.id) {
                let until = pauseIMAP(for: .overBudget)
                let failure = MailServiceError(kind: .overBudget, account: account, retryAfter: until)
                Log.info("sync", "\(account.email): \(meter.used(.download, by: account.id) / 1_000_000) MB downloaded in the last 24 hours; pausing")
                events.yield(.error(accountID: account.id, message: failure.sentence))
                continue
            }
            if syncClient == nil, let left = connectionLimitRemaining() {
                await rest(left, wakesEarly: false)
                continue
            }
            if syncClient == nil, let at = nextConnect, at > Date() {
                await rest(at.timeIntervalSinceNow, wakesEarly: true)
                continue
            }
            do {
                if syncClient == nil, health == nil { setHealth(.connecting) }
                let client = try await connectedSyncClient()
                reconnecting = false
                setHealth(.online)
                downSince = nil
                await replayPendingOperations()
                try await syncAll(client)
                failures = 0
                lastFullSync = Date()
                events.yield(.finished(accountID: account.id))
                try await idleLoop(client)
            } catch is CancellationError {
                break
            } catch {
                if Task.isCancelled { break }
                await syncClient?.logout()
                syncClient = nil
                // Closed on purpose, for a pause begun on the op connection or a reconnect.
                if pauseRemaining() != nil { continue }
                if reconnecting {
                    reconnecting = false
                    scheduleReconnect()
                    continue
                }
                let failure = MailServiceError.classify(error, account: account)
                Log.info("sync", "\(account.email): \(failure.kind.rawValue): \(Log.redacted(failure.detail, keeping: account.email))")
                guard handle(failure) else { return }
            }
        }
    }

    /// Decides what follows a failed pass and what the owner is told. False when the loop
    /// should stop until the owner acts, as when the account must be signed in again.
    private func handle(_ failure: MailServiceError) -> Bool {
        let now = Date()
        var shown = failure
        switch failure.kind {
        case .throttled:
            shown.retryAfter = pauseIMAP(for: .throttled)
        case .tooManyConnections:
            // Only this connection was refused: the op connection, if open, goes on.
            let until = limitConnections()
            shown.retryAfter = until
            setHealth(.imapPaused(until: until))
        case .needsSignIn:
            setHealth(.needsSignIn)
            events.yield(.error(accountID: account.id, message: failure.sentence))
            return false
        case .webSignInRequired:
            // Nothing FalconMail sends helps until the owner has been to the browser: it asks
            // again when they ask for mail or the Mac wakes, or else only now and then.
            nextConnect = now.addingTimeInterval(pacing.blockedRetry)
            setHealth(.blocked(reason: failure.sentence))
        case .connectionDropped:
            failures += 1
            scheduleReconnect()
            let since = downSince ?? now
            downSince = since
            guard now.timeIntervalSince(since) >= pacing.quietReconnectPeriod else {
                setHealth(.connecting)
                return true
            }
            setHealth(.offline(since: since))
        default:
            failures += 1
            scheduleReconnect()
            setHealth(.offline(since: downSince ?? now))
        }
        events.yield(.error(accountID: account.id, message: shown.sentence))
        return true
    }

    /// When the loop may connect again: never sooner than the least interval after the last
    /// attempt, and after a second failure in a row 30 s, then 60 s, 120 s and so on up to the
    /// longest, each a little shorter or longer at random so that accounts do not ask in step.
    private func scheduleReconnect() {
        let now = Date()
        var at = (lastConnectAttempt ?? .distantPast).addingTimeInterval(pacing.minimumReconnectInterval)
        if failures > 1 {
            let step = min(pacing.minimumReconnectInterval * pow(2, Double(min(failures - 2, 16))), pacing.maximumReconnectInterval)
            at = max(at, now.addingTimeInterval(step * Double.random(in: 0.85...1.15)))
        }
        nextConnect = max(at, now)
    }

    /// Ends a wait between attempts early, for a reason to believe the next may work; still no
    /// sooner than the least interval after the last one.
    private func wakeEarly() {
        guard let nap, nap.wakesEarly else { return }
        failures = 0
        nextConnect = (lastConnectAttempt ?? .distantPast).addingTimeInterval(pacing.minimumReconnectInterval)
        nap.task.cancel()
    }

    /// Waits `seconds`, or less when `wakesEarly` and something calls `wakeEarly`, or when the
    /// loop is stopped.
    private func rest(_ seconds: TimeInterval, wakesEarly: Bool) async {
        guard seconds > 0 else { return }
        let task = Task { _ = try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        nap = (task, wakesEarly)
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        nap = nil
    }

    /// Stops asking the server for anything until the returned time, for a throttle or a day's
    /// download used up. Gmail's throttle is the account's, not one connection's, and every
    /// command meanwhile only prolongs it. A second refusal while paused, from a command already
    /// on its way, neither lengthens the pause nor counts as another throttle. A refused
    /// connection is not a pause: see `limitConnections`.
    @discardableResult
    private func pauseIMAP(for kind: MailServiceError.Kind) -> Date {
        let now = Date()
        if let current = imapPause, current.until > now { return current.until }
        let until: Date
        switch kind {
        case .throttled:
            // Each throttle within a day of the last waits longer; a successful connect in
            // between changes nothing, since Gmail counts the day, not the connection.
            var level = 0
            if let last = extras.value.lastThrottleAt, now.timeIntervalSince(last) < pacing.throttleMemory,
               let previous = extras.value.imapPauseLevel {
                level = min(previous + 1, pacing.throttlePauses.count - 1)
            }
            until = now.addingTimeInterval(pacing.throttlePauses[level])
            extras.update {
                $0.imapPauseLevel = level
                $0.lastThrottleAt = now
            }
            Log.info("sync", "\(account.email): throttled, pausing IMAP for \(Int(pacing.throttlePauses[level] / 60)) minutes")
        default:
            until = meter.whenAllows(.download, for: account.id)
        }
        imapPause = (kind, until)
        extras.update {
            $0.imapPausedUntil = until
            $0.imapPauseReason = kind.rawValue
        }
        setHealth(.imapPaused(until: until))
        return until
    }

    /// Opens no new connection until the returned time, 5 to 10 minutes from now as a rule,
    /// since the server refused one because other programs hold every connection it allows. The
    /// connections open meanwhile go on as before: nothing they send adds to the count. A second
    /// refusal meanwhile, from an attempt already on its way, changes nothing.
    @discardableResult
    private func limitConnections() -> Date {
        if connectionLimitRemaining() != nil, let until = connectionLimit { return until }
        let until = Date().addingTimeInterval(TimeInterval.random(in: pacing.connectionLimitWait))
        connectionLimit = until
        Log.info("sync", "\(account.email): the server allows no more connections; opening none until \(ISO8601DateFormatter.archive.string(from: until))")
        // Kept for a relaunch too, unless a pause is, which lasts longer and stops more.
        if pauseRemaining() == nil {
            extras.update {
                $0.imapPausedUntil = until
                $0.imapPauseReason = MailServiceError.Kind.tooManyConnections.rawValue
            }
        }
        return until
    }

    /// How long no new connection may be opened yet, nil when one may.
    private func connectionLimitRemaining() -> TimeInterval? {
        guard let until = connectionLimit else { return nil }
        let left = until.timeIntervalSinceNow
        guard left > 0 else {
            connectionLimit = nil
            return nil
        }
        return left
    }

    /// Returns when a new connection may be opened. Work for the reader is refused at once
    /// instead, with the time it may be tried again; a long job, an archive or an import, waits.
    private func mayOpenConnection(waits: Bool) async throws {
        while let left = connectionLimitRemaining(), let until = connectionLimit {
            guard waits else {
                throw MailServiceError(kind: .tooManyConnections, account: account,
                                       detail: "no new connection until \(ISO8601DateFormatter.archive.string(from: until))",
                                       retryAfter: until, isOneOff: true)
            }
            try await Task.sleep(nanoseconds: UInt64(min(left, pacing.budgetRecheck) * 1_000_000_000))
        }
    }

    /// A pause still running from before a relaunch is kept, and said again, as is a wait for
    /// the connection limit.
    private func resumeStoredPause() {
        guard imapPause == nil, connectionLimit == nil, let until = extras.value.imapPausedUntil, until > Date() else { return }
        let kind = extras.value.imapPauseReason.flatMap(MailServiceError.Kind.init(rawValue:)) ?? .throttled
        if kind == .tooManyConnections {
            connectionLimit = until
        } else {
            imapPause = (kind, until)
        }
        setHealth(.imapPaused(until: until))
        events.yield(.error(accountID: account.id, message: MailServiceError(kind: kind, account: account, retryAfter: until).sentence))
    }

    /// How long the pause has left, nil when there is none.
    private func pauseRemaining() -> TimeInterval? {
        guard let pause = imapPause else { return nil }
        let left = pause.until.timeIntervalSinceNow
        guard left > 0 else {
            imapPause = nil
            return nil
        }
        return left
    }

    /// Work for the reader is refused at once during a pause, rather than sent to a server that
    /// asked for quiet, and so is any once the day's download is used up. The connection limit
    /// refuses only work that needs a new connection, in `connectedOpClient`.
    private func refuseWhilePaused() throws {
        if pauseRemaining() != nil, let pause = imapPause {
            throw MailServiceError(kind: pause.kind, account: account, detail: "paused until \(ISO8601DateFormatter.archive.string(from: pause.until))",
                                   retryAfter: pause.until, isOneOff: true)
        }
        guard meter.allows(.download, for: account.id) else {
            throw MailServiceError(kind: .overBudget, account: account, detail: "download allowance used",
                                   retryAfter: meter.whenAllows(.download, for: account.id), isOneOff: true)
        }
    }

    /// Waits until `bytes` more fit in the account's `budget`, and out any pause, telling the
    /// owner why. For long jobs, an archive or an import, which carry on where they stopped
    /// rather than fail. True when it had to wait: a connection left quiet meanwhile may have
    /// been closed. The connection limit holds up only the opening of a new connection, so a
    /// job with one open is not kept waiting for it.
    @discardableResult
    public func waitForAllowance(_ budget: TrafficBudget, bytes: Int) async throws -> Bool {
        var told = false
        var waited = false
        while true {
            try Task.checkCancellation()
            if let left = pauseRemaining() {
                waited = true
                try await Task.sleep(nanoseconds: UInt64(min(left, pacing.budgetRecheck) * 1_000_000_000))
                continue
            }
            guard !meter.allows(budget, adding: bytes, for: account.id) else { return waited }
            waited = true
            let until = meter.whenAllows(budget, adding: bytes, for: account.id)
            if !told {
                told = true
                let kind: MailServiceError.Kind = budget == .upload ? .overUploadBudget : .overBudget
                Log.info("sync", "\(account.email): waiting for the allowance until \(ISO8601DateFormatter.archive.string(from: until))")
                events.yield(.progress(accountID: account.id, text: MailServiceError(kind: kind, account: account, retryAfter: until).sentence))
            }
            try await Task.sleep(nanoseconds: UInt64(max(0.01, min(until.timeIntervalSinceNow, pacing.budgetRecheck)) * 1_000_000_000))
        }
    }

    private func connectedSyncClient() async throws -> IMAPClient {
        if let c = syncClient, await c.isConnected { return c }
        lastConnectAttempt = Date()
        let c = try await connector(account, meter.tap(for: account.id))
        try await keepUnlessStopped(c)
        syncClient = c
        return c
    }

    /// A connection that finished opening after `stop` would otherwise stay open for good.
    private func keepUnlessStopped(_ client: IMAPClient) async throws {
        guard isStopped else { return }
        await client.logout()
        throw CancellationError()
    }

    /// The op connection, and whether it had been used before. A new one is opened only once
    /// however many callers ask at the same moment, and not while the server allows no more:
    /// then work for the reader is refused at once and a long job (`waits`) waits.
    private func connectedOpClient(waits: Bool = false) async throws -> (client: IMAPClient, reused: Bool) {
        if let c = opClient, await c.isConnected { return (c, true) }
        if let pending = opConnecting { return (try await pending.value, false) }
        if connectionLimitRemaining() != nil {
            try await mayOpenConnection(waits: waits)
            // Another caller may have opened one while this one waited.
            return try await connectedOpClient(waits: waits)
        }
        let account = account
        let connector = connector
        let tap = meter.tap(for: account.id)
        let opening = Task { try await connector(account, tap) }
        opConnecting = opening
        do {
            let c = try await opening.value
            opConnecting = nil
            try await keepUnlessStopped(c)
            opClient = c
            return (c, false)
        } catch {
            opConnecting = nil
            throw error
        }
    }

    private func dropOpClient(_ client: IMAPClient) {
        if opClient === client { opClient = nil }
    }

    /// Runs `work` as one unit on the op connection. A connection that fails is discarded so
    /// the next call opens a fresh one. Work that sent nothing the server could act on, because
    /// the connection was already gone when its turn came or an APPEND failed before the server
    /// asked for its message, is always tried once more on a fresh connection. So is work on
    /// one that had sat unused, which the server or the network may have closed meanwhile, when
    /// `repeatable`; work that must not happen twice, such as an APPEND that went out, is not,
    /// and nor is anything after a throttle or any other refusal that a new connection would
    /// only repeat.
    private func withOpConnection<T: Sendable>(repeatable: Bool = true, waitsForConnection: Bool = false,
                                               _ work: @Sendable (IMAPClient) async throws -> T) async throws -> T {
        try refuseWhilePaused()
        let (client, reused) = try await connectedOpClient(waits: waitsForConnection)
        do {
            return try await client.exclusively(work)
        } catch {
            guard await !client.isConnected else { throw error }
            dropOpClient(client)
            let lost = MailServiceError.classify(error, account: account)
            let unsent = error is IMAPNotSent
            guard unsent || (reused && repeatable), lost.kind == .connectionDropped, !Task.isCancelled else { throw error }
            Log.info("sync", "\(account.email): op connection lost (\(Log.redacted(lost.detail, keeping: account.email))), reconnecting")
            let fresh = try await connectedOpClient(waits: waitsForConnection).client
            do {
                return try await fresh.exclusively(work)
            } catch {
                if await !fresh.isConnected { dropOpClient(fresh) }
                throw error
            }
        }
    }

    /// Runs `work` on the op connection with `path` selected, as one unit: the SELECT, the
    /// UIDVALIDITY check and the UID commands in `work` go out with nothing in between.
    func withMailbox<T: Sendable>(_ path: String, uidValidity: UInt32?, repeatable: Bool = true,
                                  _ work: @Sendable (IMAPClient) async throws -> T) async throws -> T {
        try await withOpConnection(repeatable: repeatable) { client in
            try await client.withMailbox(path, uidValidity: uidValidity, work)
        }
    }

    static func signIn(_ account: AccountInfo, tokens: TokenStore, traffic: TrafficTap) async throws -> IMAPClient {
        let connect: @Sendable () async throws -> IMAPClient = {
            let c = IMAPClient(host: account.imapHost, port: account.imapPort, label: account.email, traffic: traffic)
            try await c.connect()
            return c
        }
        guard account.usesPassword else {
            let id = account.id
            return try await signIn(user: account.email, isGoogle: account.provider == "google", connect: connect) { force in
                try await tokens.validAccessToken(for: id, forceRefresh: force)
            }
        }
        let c = try await connect()
        do {
            try await c.login(user: account.loginName, password: try await tokens.password(for: account.id))
        } catch {
            await c.logout()
            throw error
        }
        return c
    }

    /// Signs in with an access token. One the server turns down although it has not expired,
    /// revoked early or cut short by a clock that is off, is refreshed once and tried once more
    /// before the owner is asked to sign in again.
    static func signIn(user: String, isGoogle: Bool, connect: @Sendable () async throws -> IMAPClient,
                       accessToken: @Sendable (_ forceRefresh: Bool) async throws -> String) async throws -> IMAPClient {
        func attempt(forceRefresh: Bool) async throws -> IMAPClient {
            let c = try await connect()
            do {
                try await c.authenticateXOAuth2(user: user, accessToken: try await accessToken(forceRefresh))
            } catch {
                await c.logout()
                throw error
            }
            return c
        }
        do {
            return try await attempt(forceRefresh: false)
        } catch let refusal as IMAPServerError
                    where MailServiceError.classify(refusal, email: user, isGoogle: isGoogle).kind == .needsSignIn {
            Log.info("sync", "\(user): the server turned down the access token (\(refusal.codeName ?? "no code")); refreshing it once")
            return try await attempt(forceRefresh: true)
        }
    }

    /// The failure of one thing the owner asked for, as they should see it, logged with the
    /// server's own words. Nothing retries it, so its sentence promises no retry. A throttle
    /// pauses the account as it would on the sync connection, so that what the owner does next
    /// waits instead of asking the server again. After a refused connection none is opened until
    /// the limit passes, and those open are left alone. A message or folder the server no longer
    /// has, or a folder renumbered, gets that folder brought up to date so the list stops
    /// offering it.
    private func failed(_ doing: String, _ error: Error, folder: FolderInfo?) async -> Error {
        if error is CancellationError { return error }
        var failure = MailServiceError.classify(error, account: account)
        failure.isOneOff = true
        Log.info("sync", Log.redacted("\(account.email): \(doing) failed: \(failure.kind.rawValue): \(failure.detail)", keeping: account.email))
        switch failure.kind {
        case .tooManyConnections:
            // Only the server's own word starts the wait; the refusal given during one must
            // not make it longer.
            guard !(error is MailServiceError) else { break }
            let starting = connectionLimitRemaining() == nil
            let until = limitConnections()
            failure.retryAfter = until
            // With the sync connection up the account still syncs, and its status stays as it
            // is; without it, the loop waits for the limit too, as the status says.
            guard starting, syncClient == nil else { break }
            setHealth(.imapPaused(until: until))
            var status = failure
            status.isOneOff = false
            events.yield(.error(accountID: account.id, message: status.sentence))
        case .throttled:
            // Only the server's own word starts a pause; the refusal given during one must
            // not make it longer.
            guard !(error is MailServiceError) else { break }
            let starting = pauseRemaining() == nil
            let until = pauseIMAP(for: .throttled)
            failure.retryAfter = until
            guard starting else { break }
            var status = failure
            status.isOneOff = false
            events.yield(.error(accountID: account.id, message: status.sentence))
            // The sync connection goes quiet too, rather than idle on through the pause.
            if let c = syncClient {
                syncClient = nil
                await c.logout()
            }
        case .messageGone, .mailboxRenumbered:
            if let folder { await requestSync(folderID: folder.id) }
        case .folderGone:
            // The folder list itself is out of date, which only a full pass lists again.
            await requestSync()
        default:
            break
        }
        return failure
    }

    private func syncAll(_ client: IMAPClient) async throws {
        events.yield(.started(accountID: account.id))
        syncRequested = false
        requestedFolders.removeAll()
        let listed = try await client.listFolders()
        let folders = try await store.reconcileFolders(accountID: account.id, listed: listed)
        extras.keepFolders(Set(folders.map(\.id)))
        for f in folders where f.isSelectable && f.role != .all {
            try Task.checkCancellation()
            // Paused by a throttle met on the op connection: the rest waits for the pass after.
            guard pauseRemaining() == nil else { return }
            events.yield(.progress(accountID: account.id, text: "Checking \(f.name) in \(account.email)"))
            try await syncFolder(f, client: client)
        }
    }

    private var lastFullSync = Date()

    private var wantsSync: Bool { syncRequested || !requestedFolders.isEmpty }

    private func idleLoop(_ client: IMAPClient) async throws {
        guard let inbox = await store.folder(accountID: account.id, role: .inbox) else { return }
        while !Task.isCancelled {
            if pauseRemaining() == nil, !meter.allows(.download, for: account.id) {
                let until = pauseIMAP(for: .overBudget)
                events.yield(.error(accountID: account.id, message: MailServiceError(kind: .overBudget, account: account, retryAfter: until).sentence))
            }
            if pauseRemaining() != nil {
                // Paused from the op connection, or out of allowance: this one is closed too,
                // and the loop waits.
                if syncClient === client { syncClient = nil }
                await client.logout()
                return
            }
            var changed = false
            let dueIn = pacing.fullSyncInterval - Date().timeIntervalSince(lastFullSync)
            if !wantsSync, dueIn > 0 {
                if await client.selectedMailbox != inbox.path { _ = try await client.select(inbox.path) }
                // A request made from here on ends the IDLE as soon as it starts, and one made
                // during the SELECT is seen just below, so none waits for IDLE to time out.
                await client.prepareIdle()
                if !wantsSync, pauseRemaining() == nil {
                    let quietFor = catchUps[inbox.id].map { $0.notBefore.timeIntervalSinceNow } ?? 0
                    if quietFor > 0 {
                        // A catch-up is under way: what arrives is taken with its next pass,
                        // not one wake-up at a time.
                        changed = try await client.idle(maxWait: min(quietFor, dueIn, pacing.idleRefresh), wakeOnNews: false)
                    } else {
                        changed = try await client.idle(maxWait: min(dueIn, pacing.idleRefresh))
                    }
                }
            }
            // Nothing is fetched during a pause; the pass after it catches up.
            guard pauseRemaining() == nil else { continue }
            if syncRequested || Date().timeIntervalSince(lastFullSync) >= pacing.fullSyncInterval {
                try await syncAll(client)
                lastFullSync = Date()
                if pauseRemaining() == nil { setHealth(.online) }
                events.yield(.finished(accountID: account.id))
                continue
            }
            let targets = requestedFolders
            requestedFolders.removeAll()
            let catchUpDue = catchUps[inbox.id].map { $0.notBefore <= Date() } ?? false
            // News in INBOX brings its new messages only; a folder asked for by name is brought
            // wholly up to date.
            let inboxNews = (changed || catchUpDue) && !targets.contains(inbox.id)
            guard inboxNews || !targets.isEmpty else { continue }
            if inboxNews, let fresh = await store.folder(inbox.id) {
                try await syncFolder(fresh, client: client, pass: .newOnly)
            }
            for id in targets {
                guard let fresh = await store.folder(id), fresh.isSelectable else { continue }
                try await syncFolder(fresh, client: client)
            }
            if pauseRemaining() == nil { setHealth(.online) }
            events.yield(.finished(accountID: account.id))
        }
    }

    public func syncFolder(_ input: FolderInfo, client: IMAPClient, pass: FolderPass = .full) async throws {
        let status = try await client.select(input.path)
        let fs = try await store.folderStore(input)
        // The record as it is now the store is loaded, not the copy passed in: loading a store
        // whose index was set aside resets the cursors, so that its messages are listed again.
        guard var folder = await store.folder(input.id) else { return }
        if folder.uidValidity != status.uidValidity {
            let renumbered = folder.uidValidity != 0
            if renumbered {
                try await fs.removeAll()
                // They name UIDs of the old numbering. Kept, they would keep out whichever new
                // rows now carry those UIDs; the actions behind them are cancelled when they run.
                suppressedUIDs[folder.id] = nil
                catchUps[folder.id] = nil
                folder.lastSyncedUID = 0
                folder.oldestSyncedUID = 0
            }
            // Recorded as soon as any old rows are gone and before a new one arrives, so a row
            // in the store always belongs to the UIDVALIDITY recorded for its folder.
            let numbering = status.uidValidity
            try await store.updateFolder(folder.id) { current in
                current.uidValidity = numbering
                if renumbered {
                    current.lastSyncedUID = 0
                    current.oldestSyncedUID = 0
                }
            }
        }
        folder.uidValidity = status.uidValidity
        folder.uidNext = status.uidNext
        // Mail found in a folder listed before is news; a folder listed from scratch, the first
        // time, after a renumbering or with its index set aside, brings none.
        let listedBefore = folder.lastSyncedUID > 0

        var arrived = NewMail(unfetched: [])
        if status.exists > 0 {
            arrived = try await fetchNewMessages(&folder, client: client, fs: fs)
        } else {
            catchUps[folder.id] = nil
        }
        var newMessages = arrived.messages

        // Old mail arriving now, as an import brings, is left as it is: rules and mutes act only
        // on what was sent lately.
        let recent = newMessages.filter { $0.date > Date().addingTimeInterval(-pacing.ruleWindow) }
        if folder.role == .inbox, !recent.isEmpty {
            let kept = Set(await withoutMuted(recent, folder: folder, fs: fs, client: client).map(\.uid))
            let muted = Set(recent.map(\.uid)).subtracting(kept)
            newMessages.removeAll { muted.contains($0.uid) }
        }

        if pass == .full {
            if status.exists == 0 {
                try await empty(&folder, fs: fs)
            } else {
                reportedEmpty[folder.id] = nil
                if folder.oldestSyncedUID > 0 {
                    try await checkFlagsAndDeletions(folder, status: status, client: client, fs: fs, unfetched: arrived.unfetched)
                }
            }
        }

        folder.lastSyncDate = Date()
        let passed = folder
        try await store.updateFolder(folder.id) { current in
            // A pass that met a newer numbering owns the record now.
            guard current.uidValidity == 0 || current.uidValidity == passed.uidValidity else { return }
            current.uidValidity = passed.uidValidity
            current.uidNext = passed.uidNext
            current.lastSyncedUID = max(current.lastSyncedUID, passed.lastSyncedUID)
            // Load older may have reached further back while this pass ran.
            current.oldestSyncedUID = [current.oldestSyncedUID, passed.oldestSyncedUID].filter { $0 > 0 }.min() ?? 0
            current.lastSyncDate = passed.lastSyncDate
        }
        try await store.refreshCounts(folderID: folder.id)
        await store.notifyMessagesChanged(folderID: folder.id)
        events.yield(.folderSynced(folderID: folder.id))

        if !newMessages.isEmpty { await indexer?.index(newMessages) }

        try await prefetchBodies(folder: folder, fs: fs, client: client, preferred: newMessages)

        let stillRecent = newMessages.filter { $0.date > Date().addingTimeInterval(-pacing.ruleWindow) }
        var survivors = stillRecent
        if folder.role == .inbox, listedBefore, !stillRecent.isEmpty {
            let relocated = await applyRules(to: stillRecent, folder: folder, fs: fs) { work in try await work(client) }
            survivors.removeAll { relocated.contains($0.uid) }
        }
        // Mail the owner sent, a copy to themselves or one Gmail files in INBOX too, is not news.
        let own = account.ownAddresses
        let announced = survivors.filter {
            $0.date > Date().addingTimeInterval(-pacing.notifyWindow) && !own.contains($0.from.address.lowercased())
        }
        if folder.role == .inbox, listedBefore, !announced.isEmpty {
            events.yield(.newMessages(accountID: account.id, folderID: folder.id, messages: announced))
        }
    }

    /// Takes every row off a folder the server says is empty. A few go at once; more only when
    /// a pass `emptyFolderConfirmation` later finds it empty too, since a server can report
    /// none for a moment, and nothing would list rows below the cursor again. Once they go, the
    /// oldest listed UID moves just above the cursor, so that Load older lists whatever the
    /// server shows below it again.
    private func empty(_ folder: inout FolderInfo, fs: FolderStore) async throws {
        let known = await fs.uids()
        guard !known.isEmpty else {
            reportedEmpty[folder.id] = nil
            return
        }
        if known.count > 10 {
            let since = reportedEmpty[folder.id] ?? Date()
            reportedEmpty[folder.id] = since
            guard Date().timeIntervalSince(since) >= pacing.emptyFolderConfirmation else {
                Log.info("sync", "\(account.email) \(folder.path): the server reports no messages where \(known.count) are listed; left alone for now")
                return
            }
        }
        reportedEmpty[folder.id] = nil
        try await fs.remove(uids: Array(known))
        await indexer?.remove(ids: known.map { MessageSummary.makeID(accountID: account.id, folderID: folder.id, uid: $0) })
        // A folder never listed to the end starts again from scratch.
        let raised = folder.lastSyncedUID > 0 ? folder.lastSyncedUID + 1 : 0
        let validity = folder.uidValidity
        folder.oldestSyncedUID = raised
        try await store.updateFolder(folder.id) { current in
            guard current.uidValidity == validity else { return }
            current.oldestSyncedUID = raised
        }
        extras.updateFolder(folder.id, uidValidity: validity) {
            $0.belowWindow = 0
            $0.flagSliceBelow = nil
        }
    }

    /// What a pass found above a folder's cursor.
    private struct NewMail {
        var messages: [MessageSummary] = []
        /// Messages the server holds above the cursor that are not stored yet, the rest of a
        /// catch-up, oldest first.
        var unfetched: [UInt32]
    }

    /// Stores the newest messages not yet stored, at most `catchUpWindow` a pass and one such
    /// pass per `catchUpInterval` while more are waiting, newest first. The cursor moves only
    /// over UIDs stored without a gap below them, and is saved after every batch, so a pass cut
    /// short leaves no hole behind it and the next fetches nothing twice. It stays a cursor an
    /// earlier build understands: at worst that build fetches again what is stored above it.
    private func fetchNewMessages(_ folder: inout FolderInfo, client: IMAPClient, fs: FolderStore) async throws -> NewMail {
        if let catchUp = catchUps[folder.id], catchUp.notBefore > Date() {
            return NewMail(unfetched: catchUp.unfetched)
        }
        let candidates: [UInt32]
        if folder.lastSyncedUID == 0 {
            let all = try await client.uidSearch("ALL")
            var start = all.suffix(pacing.initialWindow).first ?? 0
            // A first pass cut short saved where its window began. Taken again, the window
            // begins there at the latest: mail that arrived meanwhile pushes the newest thousand
            // up, and what lay between the two starts would be skipped for good.
            if folder.oldestSyncedUID > 0 { start = min(start, folder.oldestSyncedUID) }
            candidates = all.filter { $0 >= start }
            folder.oldestSyncedUID = candidates.first ?? 0
            let below = all.count - candidates.count
            extras.updateFolder(folder.id, uidValidity: folder.uidValidity) { $0.belowWindow = below }
        } else {
            let after = folder.lastSyncedUID
            candidates = try await client.uidSearch("UID \(after + 1):*").filter { $0 > after }
        }
        var have = await fs.uids()
        let folderID = folder.id
        let accounted = { (uid: UInt32) -> Bool in have.contains(uid) || self.isSuppressed(folderID: folderID, uid: uid) }
        let missing = candidates.filter { !accounted($0) }
        let taking = missing.suffix(pacing.catchUpWindow)
        let later = Array(missing.dropLast(taking.count))
        if !later.isEmpty {
            Log.info("sync", "\(account.email) \(folder.path): \(missing.count) new messages, taking the newest \(taking.count) this pass")
        }

        var result = NewMail(unfetched: [])
        var next = 0
        func advanceCursor() {
            while next < candidates.count, accounted(candidates[next]) {
                folder.lastSyncedUID = max(folder.lastSyncedUID, candidates[next])
                next += 1
            }
        }
        advanceCursor()
        var end = taking.endIndex
        while end > taking.startIndex {
            try Task.checkCancellation()
            let batch = Array(taking[max(taking.startIndex, end - batchSize)..<end])
            end -= batch.count
            let envelopes = try await client.fetchEnvelopes(uids: batch)
            var summaries = await AccountSyncer.thread(envelopes.map { AccountSyncer.summary(from: $0, accountID: account.id, folderID: folder.id) }, in: fs)
            summaries.removeAll { isSuppressed(folderID: folderID, uid: $0.uid) }
            for i in summaries.indices { summaries[i].hasBody = await fs.hasBody(uid: summaries[i].uid) }
            try await fs.upsert(summaries)
            have.formUnion(summaries.map(\.uid))
            result.messages.append(contentsOf: summaries)
            advanceCursor()
            try await saveCursors(folder)
            await store.notifyMessagesChanged(folderID: folder.id)
        }
        if folder.oldestSyncedUID == 0 { folder.oldestSyncedUID = candidates.first ?? folder.lastSyncedUID }
        // Only what the window left for a later pass is a backlog. A message asked for and not
        // returned was moved or deleted meanwhile, and holds up nothing that arrives after it.
        result.unfetched = later
        if result.unfetched.isEmpty {
            catchUps[folder.id] = nil
        } else {
            catchUps[folder.id] = (Date().addingTimeInterval(pacing.catchUpInterval), result.unfetched)
        }
        return result
    }

    /// Saves how far a pass has got, onto the record as it is now.
    private func saveCursors(_ pass: FolderInfo) async throws {
        try await store.updateFolder(pass.id) { current in
            guard current.uidValidity == 0 || current.uidValidity == pass.uidValidity else { return }
            current.uidValidity = pass.uidValidity
            current.lastSyncedUID = max(current.lastSyncedUID, pass.lastSyncedUID)
            current.oldestSyncedUID = [current.oldestSyncedUID, pass.oldestSyncedUID].filter { $0 > 0 }.min() ?? 0
        }
    }

    /// Brings flags up to date and removes messages gone from the server, asking for little.
    /// With CONDSTORE only the flags changed since the last pass come back, together with one
    /// slice of older messages a pass until every one has been looked at once since the first
    /// mark: a row stored before it may have changed before it too. Without CONDSTORE, the
    /// newest `flagWindow` messages are checked, and one slice of as many older ones, a
    /// different slice each pass. A check takes a row for gone only when it covered its UID and
    /// the server's count agrees; deletions further back show as the server holding fewer
    /// messages than FalconMail knows of, and only then does a search list them.
    private func checkFlagsAndDeletions(_ folder: FolderInfo, status: IMAPMailboxStatus, client: IMAPClient, fs: FolderStore,
                                        unfetched: [UInt32]) async throws {
        let known = await fs.uids().sorted()
        guard !known.isEmpty else { return }
        var state = extras.folder(folder)
        let newest = Array(known.suffix(pacing.flagWindow))
        let older = known.dropLast(pacing.flagWindow)
        var removed = Set<UInt32>()
        var refused = false
        // With actions on their way the server still holds rows taken out here, and the counts
        // cannot agree; the pass after they finish looks again.
        let settled = suppressedUIDs[folder.id]?.isEmpty ?? true
        // How many messages the server's count says it no longer has; nil before the folder has
        // been counted, or while actions are on their way, when a check takes nothing. A check
        // that would take far more rows than that is not believed: nothing brings back a row
        // below the cursor.
        let missingOnServer = settled ? state.belowWindow.map { known.count + $0 + unfetched.count - status.exists } : nil
        let slack = max(10, status.exists / 100)

        func apply(_ flags: [(uid: UInt32, flags: [String])]) async throws {
            let live = flags.filter { !isSuppressed(folderID: folder.id, uid: $0.uid) }
            _ = try await fs.setFlags(live.map { (uid: $0.uid, flags: MessageFlags(imapFlags: $0.flags)) })
        }
        func remove(_ gone: [UInt32]) async throws {
            let fresh = gone.filter { !removed.contains($0) }
            guard !fresh.isEmpty else { return }
            try await fs.remove(uids: fresh)
            removed.formUnion(fresh)
            await indexer?.remove(ids: fresh.map { MessageSummary.makeID(accountID: account.id, folderID: folder.id, uid: $0) })
        }
        func removeIfCounted(_ gone: [UInt32]) async throws {
            let fresh = gone.filter { !removed.contains($0) }
            guard !fresh.isEmpty, let missingOnServer else { return }
            guard removed.count + fresh.count <= max(0, missingOnServer) + slack else {
                // The count itself may be what is wrong; the search below sets it right.
                refused = true
                Log.info("sync", "\(account.email) \(folder.path): a reply would remove \(fresh.count) rows where the count is short by \(missingOnServer); left alone")
                return
            }
            try await remove(fresh)
        }
        func check(_ slice: [UInt32]) async throws {
            guard !slice.isEmpty else { return }
            let flags = try await client.fetchFlags(uidRange: AccountSyncer.uidSet(AccountSyncer.ranges(covering: slice, skipping: unfetched)))
            try await apply(flags)
            let answered = Set(flags.map(\.uid))
            try await removeIfCounted(slice.filter { !answered.contains($0) })
        }
        /// The next slice of older messages: downwards from just below the newest, and round
        /// again from the top once the last reached the oldest.
        func nextOlderSlice() -> [UInt32] {
            guard !older.isEmpty else {
                state.flagSliceBelow = nil
                return []
            }
            var top = state.flagSliceBelow.flatMap { below in older.firstIndex { $0 >= below } } ?? older.endIndex
            if top == older.startIndex { top = older.endIndex }
            let bottom = max(older.startIndex, top - pacing.flagWindow)
            state.flagSliceBelow = bottom == older.startIndex ? nil : older[bottom]
            return Array(older[bottom..<top])
        }

        var newestChecked = false
        let condstore = await client.hasCapability("CONDSTORE") && status.highestModSeq != nil
        if condstore, let since = state.highestModSeq {
            if status.highestModSeq != since {
                let ranges = AccountSyncer.ranges(covering: known, skipping: unfetched)
                try await apply(try await client.fetchFlags(uidRange: AccountSyncer.uidSet(ranges), changedSince: since))
            }
            if state.flagsSwept != true {
                try await check(nextOlderSlice())
                state.flagsSwept = state.flagSliceBelow == nil
            }
        } else {
            // The first mark: from here the older rows are looked at once each, from the top.
            if condstore { state.flagSliceBelow = nil }
            try await check(newest)
            try await check(nextOlderSlice())
            newestChecked = true
            if condstore { state.flagsSwept = state.flagSliceBelow == nil }
        }
        state.highestModSeq = status.highestModSeq

        if settled {
            func expected() async -> Int? {
                guard let below = state.belowWindow else { return nil }
                return await fs.count + below + unfetched.count
            }
            if let count = await expected(), status.exists < count, !newestChecked, let bound = newest.first {
                // Most deletions are of recent mail, which a short search finds.
                let present = Set(try await client.uidSearch("UID \(bound):*"))
                try await removeIfCounted(newest.filter { !present.contains($0) })
            }
            let count = await expected()
            if refused || count == nil || status.exists < count! {
                let all = try await client.uidSearch("ALL")
                if all.count + slack >= status.exists {
                    // A search that lists what the server's own count says it holds is believed.
                    let present = Set(all)
                    try await remove(known.filter { !present.contains($0) })
                    // What the server holds up to the cursor that is neither stored nor still to
                    // fetch, below the oldest listed or in a gap above it, so that the count
                    // agrees with EXISTS from here on however the gap came about.
                    let stored = await fs.uids()
                    let queued = Set(unfetched)
                    let cursor = folder.lastSyncedUID
                    state.belowWindow = all.filter { $0 <= cursor && !stored.contains($0) && !queued.contains($0) }.count
                } else {
                    Log.info("sync", "\(account.email) \(folder.path): a search listed \(all.count) of \(status.exists) messages; left alone")
                }
            }
        }
        let checked = state
        extras.updateFolder(folder.id, uidValidity: folder.uidValidity) { $0 = checked }
    }

    /// UID ranges over `targets`, in order, broken wherever one of `holes` lies between two of
    /// them: holes are messages on the server not stored yet, which a range over them would
    /// bring back by the thousand during a catch-up.
    static func ranges(covering targets: [UInt32], skipping holes: [UInt32]) -> [ClosedRange<UInt32>] {
        guard var low = targets.first else { return [] }
        var out: [ClosedRange<UInt32>] = []
        var high = low
        var h = 0
        for uid in targets.dropFirst() {
            while h < holes.count, holes[h] < high { h += 1 }
            if h < holes.count, holes[h] < uid {
                out.append(low...high)
                low = uid
            }
            high = uid
        }
        out.append(low...high)
        return out
    }

    static func uidSet(_ ranges: [ClosedRange<UInt32>]) -> String {
        ranges.map { $0.lowerBound == $0.upperBound ? "\($0.lowerBound)" : "\($0.lowerBound):\($0.upperBound)" }.joined(separator: ",")
    }

    private func prefetchBodies(folder: FolderInfo, fs: FolderStore, client: IMAPClient, preferred: [MessageSummary]) async throws {
        guard folder.role == .inbox || preferred.count <= bodyPrefetch else { return }
        if (try? await fs.pruneBodies(keepingNewest: bodyPrefetch)) ?? 0 > 0 { await store.notifyMessagesChanged(folderID: folder.id) }
        let newest = await fs.newest(bodyPrefetch)
        let candidates = newest.filter { !$0.hasBody && $0.size <= min(maxOfflineBodyBytes, maxEagerPrefetchBytes) }
        guard !candidates.isEmpty else { return }
        var texts: [String: String] = [:]
        var updated: [MessageSummary] = []
        var spent = 0
        for m in candidates {
            try Task.checkCancellation()
            guard spent + m.size <= bodyPrefetchBudget else { break }
            guard meter.allows(.background, adding: m.size, for: account.id) else {
                if !budgetNoticeGiven {
                    budgetNoticeGiven = true
                    let used = meter.used(.background, by: account.id) / 1_000_000
                    Log.info("sync", "\(account.email): \(used) MB of offline copies in the last 24 hours, pausing them")
                    events.yield(.progress(accountID: account.id, text: "\(account.email) has downloaded \(used) MB for offline reading in the last day; new mail still arrives and messages open on demand"))
                }
                break
            }
            budgetNoticeGiven = false
            let raw: Data
            do {
                raw = try await client.fetchMessage(uid: m.uid)
            } catch is IMAPMessageMissing {
                continue
            }
            meter.record(background: raw.count, for: account.id)
            spent += raw.count
            let parsed = MIMEParser.parse(raw)
            try await fs.storeBody(uid: m.uid, raw: raw, snippet: parsed.snippet, hasAttachments: !parsed.attachments.isEmpty, searchText: parsed.bestText)
            if let s = await fs.message(uid: m.uid) { updated.append(s); texts[s.id] = parsed.bestText }
        }
        await indexer?.index(updated, bodies: texts)
        await store.notifyMessagesChanged(folderID: folder.id)
    }

    /// Runs one piece of server work with the folder being ruled on selected.
    private typealias RuleRunner = (@Sendable (IMAPClient) async throws -> Void) async throws -> Void

    /// Runs the rules on `messages`, each action through `run`. A failure about the account or
    /// the connection rather than one message stops the rest, since every later action would
    /// only meet it again.
    @discardableResult
    private func applyRules(to messages: [MessageSummary], folder: FolderInfo, fs: FolderStore, run: RuleRunner) async -> Set<UInt32> {
        let defs = await rules.all().filter { $0.isEnabled }
        guard !defs.isEmpty else { return [] }
        var relocated = Set<UInt32>()
        var stopped = false
        for m in messages where !stopped {
            let bodyText = await fs.body(uid: m.uid).map { MIMEParser.parse($0).bestText } ?? ""
            let actions = RuleEngine.actions(for: defs, accountID: account.id, subject: RuleSubject(summary: m, body: bodyText))
            var flags = m.flags
            var flagsChanged = false
            var moved = false
            let uids = [m.uid]
            for a in actions {
                do {
                    switch a.kind {
                    case .markRead:
                        try await run { try await $0.store(uids: uids, add: true, flags: ["\\Seen"]) }
                        flags.insert(.seen)
                        flagsChanged = true
                    case .flag:
                        try await run { try await $0.store(uids: uids, add: true, flags: ["\\Flagged"]) }
                        flags.insert(.flagged)
                        flagsChanged = true
                    case .delete:
                        if let trash = await store.folder(accountID: account.id, role: .trash) {
                            let path = trash.path
                            try await run { try await $0.move(uids: uids, to: path) }
                            moved = true
                        }
                    case .archive:
                        let target = await archiveTarget()
                        try await run { try await AccountSyncer.archive(uids: uids, to: target, client: $0) }
                        moved = true
                    case .moveToFolder:
                        if !a.value.isEmpty {
                            let path = a.value
                            try await run { try await $0.move(uids: uids, to: path) }
                            moved = true
                        }
                    case .copyToFolder:
                        if !a.value.isEmpty {
                            let path = a.value
                            try await run { try await $0.copy(uids: uids, to: path) }
                        }
                    case .stopProcessing: break
                    }
                } catch {
                    let failure = await failed("rule", error, folder: nil)
                    events.yield(.error(accountID: account.id, message: "A rule could not run. \(failure.localizedDescription)"))
                    if let known = failure as? MailServiceError, AccountSyncer.stopsRules(known.kind) {
                        stopped = true
                        break
                    }
                }
                if moved { break }
            }
            if moved {
                relocated.insert(m.uid)
            } else if flagsChanged {
                _ = try? await fs.setFlags([(uid: m.uid, flags: flags)])
            }
        }
        guard !relocated.isEmpty else { return relocated }
        try? await fs.remove(uids: Array(relocated))
        await indexer?.remove(ids: relocated.map { MessageSummary.makeID(accountID: account.id, folderID: folder.id, uid: $0) })
        try? await store.refreshCounts(folderID: folder.id)
        await store.notifyMessagesChanged(folderID: folder.id)
        await requestSync()
        return relocated
    }

    /// A rule failure that is not about the message it was running on.
    private static func stopsRules(_ kind: MailServiceError.Kind) -> Bool {
        switch kind {
        case .messageGone, .folderGone, .expungeRefused, .refused, .recipientRefused, .local: return false
        default: return true
        }
    }

    private func withoutMuted(_ messages: [MessageSummary], folder: FolderInfo, fs: FolderStore,
                              client: IMAPClient) async -> [MessageSummary] {
        let records = await mutes.all()
        guard !records.isEmpty else { return messages }
        var kept: [MessageSummary] = []
        var muted: [MessageSummary] = []
        for m in messages {
            guard let hit = MuteStore.match(in: records, accountID: account.id, threadKey: m.threadKey, messageID: m.messageID,
                                            references: m.references, inReplyTo: m.inReplyTo) else {
                kept.append(m)
                continue
            }
            muted.append(m)
            await mutes.remember(messageID: m.messageID, accountID: hit.accountID, threadKey: hit.threadKey)
        }
        guard !muted.isEmpty else { return kept }
        let uids = muted.map { $0.uid }
        do {
            try await client.store(uids: uids, add: true, flags: ["\\Seen"])
            try await archiveOnServer(uids: uids, client: client)
            try await fs.remove(uids: uids)
        } catch {
            let failure = await failed("filing a muted conversation", error, folder: folder)
            events.yield(.error(accountID: account.id, message: "Could not file a muted conversation. \(failure.localizedDescription)"))
            return messages
        }
        await indexer?.remove(ids: muted.map { $0.id })
        await store.notifyMessagesChanged(folderID: folder.id)
        return kept
    }

    private func archiveOnServer(uids: [UInt32], client: IMAPClient) async throws {
        try await AccountSyncer.archive(uids: uids, to: await archiveTarget(), client: client)
    }

    /// Where Archive puts mail, and whether that folder has to be made first.
    private func archiveTarget() async -> (path: String, create: Bool) {
        if account.provider == "google", let all = await store.folder(accountID: account.id, role: .all) { return (all.path, false) }
        if let archive = await store.folder(accountID: account.id, role: .archive) { return (archive.path, false) }
        return ("Archive", await store.folder(accountID: account.id, path: "Archive") == nil)
    }

    private static func archive(uids: [UInt32], to target: (path: String, create: Bool), client: IMAPClient) async throws {
        if target.create {
            do {
                try await client.createFolder(target.path)
            } catch let refusal as IMAPServerError where refusal.codeName == "ALREADYEXISTS" {
                // Made by another program since the folders were last listed; use it.
            }
        }
        try await client.move(uids: uids, to: target.path)
    }

    static func thread(_ batch: [MessageSummary], in fs: FolderStore) async -> [MessageSummary] {
        let ids = Array(Set(batch.flatMap { $0.references + [$0.inReplyTo, $0.messageID] }.filter { !$0.isEmpty }))
        var known = await fs.threadKeys(for: ids)
        var out: [MessageSummary] = []
        for var s in batch.sorted(by: { $0.date < $1.date }) {
            s.threadKey = ConversationThreader.threadKey(messageID: s.messageID, inReplyTo: s.inReplyTo, references: s.references,
                                                         subject: s.subject) { known[$0] }
            if !s.messageID.isEmpty { known[s.messageID] = s.threadKey }
            out.append(s)
        }
        return out
    }

    static func summary(from e: IMAPMessageEnvelope, accountID: UUID, folderID: UUID) -> MessageSummary {
        let h = MIMEParser.parseHeaders(e.header)
        let ct = ContentType.parse(h.first("Content-Type"))
        let looksAttached = ct.mimeType == "multipart/mixed" || ct.type == "application"
        return MessageSummary(
            accountID: accountID, folderID: folderID, uid: e.uid,
            messageID: AddressParser.messageIDs(h.first("Message-ID")).first ?? "",
            inReplyTo: AddressParser.messageIDs(h.first("In-Reply-To")).first ?? "",
            references: AddressParser.messageIDs(h.first("References")),
            subject: RFC2047.decode(h.first("Subject") ?? ""),
            from: AddressParser.parse(h.first("From")).first ?? EmailAddress(address: ""),
            to: AddressParser.parse(h.first("To")),
            cc: AddressParser.parse(h.first("Cc")),
            // Without a Date header that can be read, a message is dated when the server received
            // it: dated now, old mail imported without one would pass for new.
            date: h.first("Date").flatMap(RFC5322Date.parse) ?? e.internalDate ?? Date(),
            flags: MessageFlags(imapFlags: e.flags),
            size: e.size,
            hasAttachments: looksAttached
        )
    }

    public func body(for message: MessageSummary) async throws -> Data {
        guard let folder = await store.folder(message.folderID) else { throw FalconError.storage("folder missing") }
        let fs = try await store.folderStore(folder)
        // Checked against the store only after the folder's UIDVALIDITY was read above: a row
        // that still matches then was listed under that numbering, and the server is asked
        // under it too, so neither a stale row nor a renumbering in between opens another message.
        guard await !stillCurrent([message], in: folder, fs: fs).isEmpty else {
            throw await failed("opening a message in \(folder.path)", gone(), folder: folder)
        }
        if let cached = await fs.body(uid: message.uid) { return cached }
        let raw: Data
        do {
            guard meter.allows(.download, adding: message.size, for: account.id) else {
                throw MailServiceError(kind: .overBudget, account: account, detail: "download allowance used",
                                       retryAfter: meter.whenAllows(.download, adding: message.size, for: account.id))
            }
            let uid = message.uid
            raw = try await withMailbox(folder.path, uidValidity: folder.uidValidity) { try await $0.fetchMessage(uid: uid) }
        } catch {
            throw await failed("opening a message in \(folder.path)", error, folder: folder)
        }
        let parsed = MIMEParser.parse(raw)
        try await fs.storeBody(uid: message.uid, raw: raw, snippet: parsed.snippet, hasAttachments: !parsed.attachments.isEmpty, searchText: parsed.bestText)
        if let s = await fs.message(uid: message.uid) { await indexer?.index([s], bodies: [s.id: parsed.bestText]) }
        await store.notifyMessagesChanged(folderID: folder.id)
        return raw
    }

    public func parsedMessage(for message: MessageSummary) async throws -> MIMEMessage {
        let raw = try await body(for: message)
        return MIMEParser.parse(raw)
    }

    /// The rows of `group` that still name the message they were read for, in the store of a
    /// folder whose record was read first. One read before the folder was renumbered, or since
    /// removed, carries a UID that now names another message or none, so it is left out, and
    /// the folder is brought up to date for the list to catch up.
    private func stillCurrent(_ group: [MessageSummary], in folder: FolderInfo, fs: FolderStore) async -> [MessageSummary] {
        let current = await fs.current(group)
        if current.count < group.count {
            Log.info("sync", "\(account.email) \(folder.path): \(group.count - current.count) of \(group.count) rows no longer name their message; left alone")
            await requestSync(folderID: folder.id)
        }
        return current
    }

    private func gone() -> MailServiceError {
        MailServiceError(kind: .messageGone, account: account, detail: "the row no longer names the message it was read for", isOneOff: true)
    }

    /// The records of what was done. When nothing was, because every row asked about had gone
    /// stale, that is the owner's answer rather than silence.
    private func acted(_ outcomes: [MailActionRecord?]) throws -> [MailActionRecord] {
        let records = outcomes.compactMap { $0 }
        if records.isEmpty, outcomes.contains(where: { $0 == nil }) { throw gone() }
        return records
    }

    @discardableResult
    public func setFlag(_ flag: MessageFlags, on messages: [MessageSummary], enabled: Bool,
                        silent: Bool = false) async throws -> [MailActionRecord] {
        var outcomes: [MailActionRecord?] = []
        for (folderID, all) in Dictionary(grouping: messages, by: { $0.folderID }) {
            guard let folder = await store.folder(folderID) else { continue }
            let fs = try await store.folderStore(folder)
            let group = await stillCurrent(all, in: folder, fs: fs)
            guard !group.isEmpty else {
                outcomes.append(nil)
                continue
            }
            var updates: [(uid: UInt32, flags: MessageFlags)] = []
            for m in group {
                var f = m.flags
                if enabled { f.insert(flag) } else { f.remove(flag) }
                updates.append((m.uid, f))
            }
            let pending = PendingServerOperation(accountID: account.id, folderID: folder.id, verb: .store,
                                                 uids: group.map { $0.uid }, uidValidity: folder.uidValidity,
                                                 flagNames: flag.imapFlags, enabled: enabled)
            await pendingActions.add(pending)
            suppress(pending)
            do {
                _ = try await fs.setFlags(updates)
            } catch {
                unsuppress(pending)
                await pendingActions.remove(pending.id)
                throw error
            }
            await store.notifyMessagesChanged(folderID: folderID)
            try? await store.refreshCounts(folderID: folderID)
            let kind = MailActionKind.forFlag(flag, enabled: enabled)
            let record = MailActionRecord(id: pending.id, kind: kind, accountID: account.id, folderID: folder.id,
                                          messages: group, destinationName: "", date: Date(), isAutomatic: silent)
            outcomes.append(record)
            hold(record: record, pending: pending)
        }
        return try acted(outcomes)
    }

    @discardableResult
    public func move(_ messages: [MessageSummary], to destination: FolderInfo) async throws -> [MailActionRecord] {
        try acted(await move(messages, to: destination, kind: .move))
    }

    private func move(_ messages: [MessageSummary], to destination: FolderInfo, kind: MailActionKind) async throws -> [MailActionRecord?] {
        var outcomes: [MailActionRecord?] = []
        for (folderID, group) in Dictionary(grouping: messages, by: { $0.folderID }) where folderID != destination.id {
            guard let folder = await store.folder(folderID) else { continue }
            outcomes.append(try await removeLocally(group, in: folder, kind: kind, verb: .move,
                                                    destinationPath: destination.path, destinationName: destination.name))
        }
        return outcomes
    }

    @discardableResult
    public func delete(_ messages: [MessageSummary]) async throws -> [MailActionRecord] {
        guard let trash = await store.folder(accountID: account.id, role: .trash) else {
            throw FalconError.storage("No trash folder on this account")
        }
        let alreadyTrashed = messages.filter { $0.folderID == trash.id }
        let rest = messages.filter { $0.folderID != trash.id }
        var outcomes: [MailActionRecord?] = []
        if !rest.isEmpty { outcomes += try await move(rest, to: trash, kind: .delete) }
        if !alreadyTrashed.isEmpty {
            outcomes.append(try await removeLocally(alreadyTrashed, in: trash, kind: .delete, verb: .expunge,
                                                    destinationPath: "", destinationName: trash.name))
        }
        return try acted(outcomes)
    }

    @discardableResult
    public func purge(_ messages: [MessageSummary]) async throws -> [MailActionRecord] {
        var outcomes: [MailActionRecord?] = []
        for (folderID, group) in Dictionary(grouping: messages, by: { $0.folderID }) {
            guard let folder = await store.folder(folderID) else { continue }
            outcomes.append(try await removeLocally(group, in: folder, kind: .delete, verb: .expunge,
                                                    destinationPath: "", destinationName: folder.name))
        }
        return try acted(outcomes)
    }

    @discardableResult
    public func archive(_ messages: [MessageSummary]) async throws -> [MailActionRecord] {
        let name = await archiveDestinationName()
        var outcomes: [MailActionRecord?] = []
        for (folderID, group) in Dictionary(grouping: messages, by: { $0.folderID }) {
            guard let folder = await store.folder(folderID) else { continue }
            outcomes.append(try await removeLocally(group, in: folder, kind: .archive, verb: .archive,
                                                    destinationPath: "", destinationName: name))
        }
        return try acted(outcomes)
    }

    /// Nil when none of `all` still names its message.
    private func removeLocally(_ all: [MessageSummary], in folder: FolderInfo, kind: MailActionKind,
                               verb: PendingServerVerb, destinationPath: String,
                               destinationName: String) async throws -> MailActionRecord? {
        let fs = try await store.folderStore(folder)
        let group = await stillCurrent(all, in: folder, fs: fs)
        guard !group.isEmpty else { return nil }
        let pending = PendingServerOperation(accountID: account.id, folderID: folder.id, verb: verb,
                                             uids: group.map { $0.uid }, uidValidity: folder.uidValidity,
                                             destinationPath: destinationPath)
        await pendingActions.add(pending)
        suppress(pending)
        do {
            try await fs.remove(uids: pending.uids)
        } catch {
            unsuppress(pending)
            await pendingActions.remove(pending.id)
            throw error
        }
        await indexer?.remove(ids: group.map { $0.id })
        await store.notifyMessagesChanged(folderID: folder.id)
        try? await store.refreshCounts(folderID: folder.id)
        let record = MailActionRecord(id: pending.id, kind: kind, accountID: account.id, folderID: folder.id,
                                      messages: group, destinationName: destinationName, date: Date())
        hold(record: record, pending: pending)
        return record
    }

    private func hold(record: MailActionRecord, pending: PendingServerOperation) {
        held[record.id] = HeldAction(record: record, pending: pending, task: nil)
        let nanoseconds = UInt64(max(0, undoWindow) * 1_000_000_000)
        held[record.id]?.task = Task { [weak self] in
            _ = try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await self?.commit(record.id)
        }
    }

    private func commit(_ id: UUID) async {
        guard let action = held.removeValue(forKey: id) else { return }
        do {
            try await run(action.pending)
            await release(action.pending)
            await pendingActions.remove(action.pending.id)
            if action.pending.verb == .move { await requestSync() }
        } catch {
            await release(action.pending)
            await pendingActions.remove(action.pending.id)
            let failure = await failed("\(action.record.kind.rawValue) of \(action.pending.uids.count)", error,
                                       folder: await store.folder(action.pending.folderID))
            guard !action.record.isAutomatic else { return }
            let restored = await restore(action.record, queuedAs: action.pending)
            events.yield(.actionFailed(accountID: account.id,
                                       message: "\(action.record.failurePrefix): \(failure.localizedDescription)\(restored ? " Restored." : "")"))
        }
    }

    public func undo(_ recordID: UUID) async -> Bool {
        guard let action = held.removeValue(forKey: recordID) else { return false }
        action.task?.cancel()
        await release(action.pending)
        await restore(action.record, queuedAs: action.pending)
        await pendingActions.remove(action.pending.id)
        return true
    }

    public func flushPending() async {
        for id in Array(held.keys) {
            held[id]?.task?.cancel()
            await commit(id)
        }
    }

    /// Runs an action on the server under the UIDVALIDITY it was queued with, so that a
    /// mailbox renumbered in between cancels it rather than acting on whichever messages now
    /// carry those UIDs.
    private func run(_ pending: PendingServerOperation) async throws {
        guard let folder = await store.folder(pending.folderID) else { return }
        guard pending.appliesTo(folder) else {
            throw MailServiceError(kind: .mailboxRenumbered, account: account, detail: "queued under another UIDVALIDITY", name: folder.name)
        }
        let target = await archiveTarget()
        try await withMailbox(folder.path, uidValidity: pending.uidValidity ?? folder.uidValidity) { client in
            switch pending.verb {
            case .archive:
                try await AccountSyncer.archive(uids: pending.uids, to: target, client: client)
            case .move:
                try await client.move(uids: pending.uids, to: pending.destinationPath)
            case .expunge:
                try await client.expunge(uids: pending.uids)
            case .store:
                try await client.store(uids: pending.uids, add: pending.enabled, flags: pending.flagNames)
            }
        }
    }

    /// Puts back the rows an action took out of the list. Not into a folder renumbered since
    /// the action was queued: its rows now belong to the new numbering, and one put back from
    /// before would stand at a UID that names another message.
    @discardableResult
    private func restore(_ record: MailActionRecord, queuedAs pending: PendingServerOperation) async -> Bool {
        guard let folder = await store.folder(record.folderID), pending.appliesTo(folder),
              let fs = try? await store.folderStore(folder) else { return false }
        switch record.kind {
        case .flag, .unflag, .read, .unread:
            let previous: [(uid: UInt32, flags: MessageFlags)] = record.messages.map { (uid: $0.uid, flags: $0.flags) }
            _ = try? await fs.setFlags(previous)
        case .archive, .delete, .move:
            var rows = record.messages
            for i in rows.indices { rows[i].hasBody = false }
            try? await fs.upsert(rows)
            await indexer?.index(rows)
        }
        await store.notifyMessagesChanged(folderID: folder.id)
        try? await store.refreshCounts(folderID: folder.id)
        return true
    }

    private func replayPendingOperations() async {
        let stored = await pendingActions.all()
        for pending in stored where pending.accountID == account.id && held[pending.id] == nil {
            if await mailboxWasRebuilt(pending) {
                await pendingActions.remove(pending.id)
                continue
            }
            if Date().timeIntervalSince(pending.date) > AccountSyncer.staleOperationAge {
                await pendingActions.remove(pending.id)
                await restoreRows(for: pending)
                continue
            }
            do {
                try await run(pending)
                await pendingActions.remove(pending.id)
            } catch {
                let failure = await failed("replaying \(pending.verb.rawValue) of \(pending.uids.count)", error,
                                           folder: await store.folder(pending.folderID))
                events.yield(.actionFailed(accountID: account.id,
                                           message: "Could not finish an action from the last session. \(failure.localizedDescription)"))
            }
        }
    }

    private func mailboxWasRebuilt(_ pending: PendingServerOperation) async -> Bool {
        guard let folder = await store.folder(pending.folderID) else { return true }
        return !pending.appliesTo(folder)
    }

    private func restoreRows(for pending: PendingServerOperation) async {
        guard pending.verb != .store, !pending.uids.isEmpty else { return }
        guard let folder = await store.folder(pending.folderID), let fs = try? await store.folderStore(folder) else { return }
        do {
            let uids = pending.uids
            let validity = pending.uidValidity ?? folder.uidValidity
            let envelopes = try await withMailbox(folder.path, uidValidity: validity) {
                try await $0.fetchEnvelopes(uids: uids)
            }
            guard !envelopes.isEmpty, await stillNumbered(folder.id, as: validity) else { return }
            let rows = envelopes.map { AccountSyncer.summary(from: $0, accountID: account.id, folderID: folder.id) }
            let summaries = await AccountSyncer.thread(rows, in: fs)
            try await fs.upsert(summaries)
            await indexer?.index(summaries)
            try await store.refreshCounts(folderID: folder.id)
            await store.notifyMessagesChanged(folderID: folder.id)
        } catch {
            let failure = await failed("restoring rows of a stale action", error, folder: folder)
            events.yield(.error(accountID: account.id, message: failure.localizedDescription))
        }
    }

    /// Whether the folder is still numbered as it was when rows were fetched from it. Rows
    /// fetched just before the sync found it renumbered must not join the new numbering's.
    private func stillNumbered(_ folderID: UUID, as validity: UInt32) async -> Bool {
        await store.folder(folderID)?.uidValidity == validity
    }

    private func suppress(_ pending: PendingServerOperation) {
        for uid in pending.uids { suppressedUIDs[pending.folderID, default: [:]][uid, default: 0] += 1 }
    }

    /// Lifts a finished action's hold on its rows, unless the folder was renumbered since: its
    /// holds were dropped then, and any there now are for the new numbering's rows.
    private func release(_ pending: PendingServerOperation) async {
        guard let folder = await store.folder(pending.folderID), pending.appliesTo(folder) else { return }
        unsuppress(pending)
    }

    private func unsuppress(_ pending: PendingServerOperation) {
        guard var counts = suppressedUIDs[pending.folderID] else { return }
        for uid in pending.uids {
            guard let remaining = counts[uid] else { continue }
            if remaining <= 1 { counts[uid] = nil } else { counts[uid] = remaining - 1 }
        }
        suppressedUIDs[pending.folderID] = counts.isEmpty ? nil : counts
    }

    private func isSuppressed(folderID: UUID, uid: UInt32) -> Bool {
        (suppressedUIDs[folderID]?[uid] ?? 0) > 0
    }

    private func archiveDestinationName() async -> String {
        if account.provider == "google", let all = await store.folder(accountID: account.id, role: .all) { return all.name }
        if let archive = await store.folder(accountID: account.id, role: .archive) { return archive.name }
        return "Archive"
    }

    public func append(raw: Data, to folder: FolderInfo, flags: MessageFlags, date: Date?) async throws {
        do {
            try await upload(raw, to: folder, flags: flags, date: date)
        } catch {
            throw await failed("saving a message to \(folder.path)", error, folder: folder)
        }
        syncSoon(afterSavingTo: folder.id)
    }

    /// One APPEND on the op connection. It is never repeated once the message has gone out,
    /// since one that did reach the server would be stored twice; one that failed before the
    /// server asked for the message is tried once more on a fresh connection.
    private func upload(_ raw: Data, to folder: FolderInfo, flags: MessageFlags, date: Date?,
                        waitsForConnection: Bool = false) async throws {
        guard meter.allows(.upload, adding: raw.count, for: account.id) else {
            throw MailServiceError(kind: .overUploadBudget, account: account, detail: "upload allowance used",
                                   retryAfter: meter.whenAllows(.upload, adding: raw.count, for: account.id))
        }
        _ = try await withOpConnection(repeatable: false, waitsForConnection: waitsForConnection) { client in
            try await client.append(mailbox: folder.path, message: raw, flags: flags.imapFlags, date: date)
        }
    }

    /// Uploads one imported message into `folder`. When the account's upload allowance is used
    /// up, Gmail asked for quiet, or a connection is needed while the server allows no more, it
    /// waits and then goes on, so that an import of thousands pauses rather than failing part of
    /// the way through. A message the server certainly did not store, because the connection
    /// dropped before it went or Gmail turned it away, is tried again once the pause or the
    /// connection limit that began is over, or a little later.
    public func importMessage(_ message: ImportedMessage, into folder: FolderInfo) async throws {
        var attempts = 0
        while true {
            try await waitForAllowance(.upload, bytes: message.raw.count)
            do {
                try await upload(message.raw, to: folder, flags: message.flags, date: message.date, waitsForConnection: true)
                break
            } catch {
                let failure = await failed("importing a message into \(folder.path)", error, folder: folder)
                attempts += 1
                guard attempts < 3, !(error is IMAPAppendUnconfirmed), (failure as? MailServiceError)?.isTransient ?? false else { throw failure }
                if pauseRemaining() == nil, connectionLimitRemaining() == nil {
                    try await Task.sleep(nanoseconds: UInt64(pacing.minimumReconnectInterval * 1_000_000_000))
                }
            }
        }
        syncSoon(afterSavingTo: folder.id)
    }

    /// Syncs a folder that messages were saved to, once for however many are saved within
    /// `appendSyncSpacing`: an import of thousands would otherwise sync it thousands of times.
    private func syncSoon(afterSavingTo folderID: UUID) {
        guard appendSyncs[folderID] == nil else { return }
        let last = lastAppendSync[folderID] ?? .distantPast
        let delay = max(0, last.addingTimeInterval(pacing.appendSyncSpacing).timeIntervalSinceNow)
        appendSyncs[folderID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.syncSaved(folderID)
        }
    }

    private func syncSaved(_ folderID: UUID) async {
        appendSyncs[folderID] = nil
        lastAppendSync[folderID] = Date()
        await requestSync(folderID: folderID)
    }

    public func loadOlder(folder input: FolderInfo, count: Int = 1000) async throws {
        guard let folder = await store.folder(input.id), folder.oldestSyncedUID > 1 else { return }
        let fs = try await store.folderStore(folder)
        let oldest = folder.oldestSyncedUID
        let window: [UInt32]
        let stored = await fs.uids()
        var added = 0
        do {
            window = try await withMailbox(folder.path, uidValidity: folder.uidValidity) { client in
                Array(try await client.uidSearch("UID 1:\(oldest - 1)").suffix(count))
            }
            guard !window.isEmpty else { return }
            var start = 0
            while start < window.count {
                // One unit per batch, so a message opened meanwhile does not wait for them all.
                let batch = Array(window[start..<min(start + batchSize, window.count)])
                let envelopes = try await withMailbox(folder.path, uidValidity: folder.uidValidity) { try await $0.fetchEnvelopes(uids: batch) }
                guard await stillNumbered(folder.id, as: folder.uidValidity) else {
                    throw MailServiceError(kind: .mailboxRenumbered, account: account, detail: "renumbered during Load older", name: folder.name)
                }
                var summaries = await AccountSyncer.thread(envelopes.map { AccountSyncer.summary(from: $0, accountID: account.id, folderID: folder.id) }, in: fs)
                summaries.removeAll { isSuppressed(folderID: folder.id, uid: $0.uid) }
                try await fs.upsert(summaries)
                added += summaries.filter { !stored.contains($0.uid) }.count
                await indexer?.index(summaries)
                start += batchSize
            }
        } catch {
            throw await failed("loading older messages in \(folder.path)", error, folder: folder)
        }
        // Only the cursor it moved, on the record as it is now: a sync may have moved on.
        if let first = window.first {
            let validity = folder.uidValidity
            try await store.updateFolder(folder.id) { current in
                guard current.uidValidity == validity else { return }
                current.oldestSyncedUID = current.oldestSyncedUID == 0 ? first : min(current.oldestSyncedUID, first)
            }
            // The rows it stored are no longer among those the server holds unlisted, which a
            // pass counts to tell deletions from its EXISTS.
            if await stillNumbered(folder.id, as: validity) {
                extras.updateFolder(folder.id, uidValidity: validity) { state in
                    state.belowWindow = state.belowWindow.map { max(0, $0 - added) }
                }
            }
        }
        try await store.refreshCounts(folderID: folder.id)
        await store.notifyMessagesChanged(folderID: folder.id)
    }

    public func setBodyPrefetch(_ count: Int, maxBytes: Int? = nil) {
        bodyPrefetch = count
        if let maxBytes { maxOfflineBodyBytes = maxBytes }
    }

    public func runRulesOnInbox() async throws {
        guard let inbox = await store.folder(accountID: account.id, role: .inbox) else { return }
        let fs = try await store.folderStore(inbox)
        let all = await fs.all()
        let path = inbox.path
        let validity = inbox.uidValidity
        // Each action a unit of its own, so that a message opened meanwhile waits for one
        // command rather than for the whole run.
        await applyRules(to: all, folder: inbox, fs: fs) { work in
            try await self.withMailbox(path, uidValidity: validity, work)
        }
        await requestSync()
    }

    /// A connection of its own for an archive job, which runs for a long time and would
    /// otherwise hold up every message the reader opens. While the server allows no more
    /// connections it waits, as the job does for its allowance.
    public func openArchiveSourceClient() async throws -> IMAPClient {
        do {
            try await mayOpenConnection(waits: true)
            try refuseWhilePaused()
            return try await connector(account, meter.tap(for: account.id, background: true))
        } catch {
            throw await failed("connecting for an archive", error, folder: nil)
        }
    }

    /// What an archive job of this account runs on: connections of its own, the background
    /// allowance, and this syncer to hear of what goes wrong, so that a throttle met by the job
    /// pauses the whole account and counts towards the next, longer cool-down.
    public nonisolated func archiveSource() -> ArchiveSource {
        ArchiveSource(connect: { try await self.openArchiveSourceClient() },
                      allowance: { try await self.waitForAllowance(.background, bytes: $0) },
                      failed: { await self.failed("archiving", $0, folder: nil) })
    }

    public func createMailbox(named name: String) async throws {
        do {
            let listed = try await withOpConnection(repeatable: false) { client in
                try await client.createFolder(name)
                return try await client.listFolders()
            }
            _ = try await store.reconcileFolders(accountID: account.id, listed: listed)
        } catch {
            throw await failed("creating a folder", error, folder: nil)
        }
        await requestSync()
    }
}
