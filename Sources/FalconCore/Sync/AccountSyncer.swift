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

/// Opens and signs in an IMAP connection for an account. Tests connect to a fake server here.
public typealias IMAPConnector = @Sendable (AccountInfo) async throws -> IMAPClient

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
    private var syncClient: IMAPClient?
    /// Everything the reader asks for (opening a message, actions, drafts, rules, older mail)
    /// shares this connection, one unit of work at a time.
    private var opClient: IMAPClient?
    private var opConnecting: Task<IMAPClient, Error>?
    private var loopTask: Task<Void, Never>?
    private var syncRequested = false
    /// Folders to bring up to date on their own, without a whole pass over the account.
    private var requestedFolders: [UUID] = []
    private var backoff: TimeInterval = 5
    private var health: AccountHealth?
    /// Set when the server asked FalconMail to slow down or refused another connection, on
    /// whichever connection it said so: until then nothing more is asked of it.
    private var imapPause: (kind: MailServiceError.Kind, until: Date)?
    private var downSince: Date?
    private var isStopped = false
    /// How long a dropped connection is retried quietly before the owner is told.
    public var quietReconnectPeriod: TimeInterval = 120
    public var initialWindow = 1000
    public var catchUpWindow = 2000
    public var bodyPrefetch = 150
    public var maxOfflineBodyBytes = 5 * 1024 * 1024
    public var bodyPrefetchBudget = 64 * 1024 * 1024
    /// Google allows 2,500 MB of IMAP download per account per day and suspends the account past it.
    /// Eager prefetching stops well below that; opening a message by hand may go a little further.
    public var dailyPrefetchBudget = 900 * 1024 * 1024
    public var dailyHardCeiling = 1_800 * 1024 * 1024
    public var maxEagerPrefetchBytes = 1024 * 1024
    private let meter: BandwidthMeter
    private var budgetNoticeGiven = false
    private var pendingCatchUp = false

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
                meter: BandwidthMeter? = nil, connector: IMAPConnector? = nil) {
        self.account = account
        self.store = store
        self.tokens = tokens
        self.rules = rules
        self.mutes = mutes
        self.indexer = indexer
        self.pendingActions = pendingActions
        self.events = events
        self.meter = meter ?? .shared
        self.connector = connector ?? { account in try await AccountSyncer.signIn(account, tokens: tokens) }
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
        for action in held.values { action.task?.cancel() }
        held.removeAll()
        suppressedUIDs.removeAll()
        try? await syncClient?.finishIdle()
        await syncClient?.logout()
        await opClient?.logout()
        syncClient = nil
        opClient = nil
    }

    public func requestSync() async {
        syncRequested = true
        try? await syncClient?.finishIdle()
    }

    /// Brings one folder up to date soon, on its own, for example after a message in it turned
    /// out to be gone.
    public func requestSync(folderID: UUID) async {
        if !requestedFolders.contains(folderID) { requestedFolders.append(folderID) }
        try? await syncClient?.finishIdle()
    }

    private func setHealth(_ new: AccountHealth) {
        guard health != new else { return }
        health = new
        Log.info("health", "\(account.email): \(new.logName)")
        events.yield(.health(accountID: account.id, new))
    }

    private func loop() async {
        while !Task.isCancelled {
            if let problem = await store.folderListProblem(account.id) {
                // Syncing would write a new folder list and orphan every folder stored under the old one.
                let failure = MailServiceError(kind: .folderListUnreadable, account: account, detail: problem.detail, name: problem.fileName)
                Log.info("sync", "\(account.email): not syncing, \(problem.detail)")
                setHealth(.blocked(reason: failure.sentence))
                events.yield(.error(accountID: account.id, message: failure.sentence))
                return
            }
            do {
                if let rest = pauseRemaining() {
                    try await Task.sleep(nanoseconds: UInt64(rest * 1_000_000_000))
                    continue
                }
                if syncClient == nil, health == nil { setHealth(.connecting) }
                let client = try await connectedSyncClient()
                setHealth(.online)
                downSince = nil
                backoff = 5
                await replayPendingOperations()
                try await syncAll(client)
                lastFullSync = Date()
                await meter.persist()
                events.yield(.finished(accountID: account.id))
                if pendingCatchUp {
                    pendingCatchUp = false
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    continue
                }
                try await idleLoop(client)
            } catch is CancellationError {
                break
            } catch {
                if Task.isCancelled { break }
                let failure = MailServiceError.classify(error, account: account)
                Log.info("sync", "\(account.email): \(failure.kind.rawValue): \(Log.redacted(failure.detail, keeping: account.email))")
                await syncClient?.logout()
                syncClient = nil
                guard pause(after: failure) else { return }
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            }
        }
    }

    /// Sets how long to wait after a failed pass and what the owner is told. False when the
    /// loop should stop until the owner acts, as when the account must be signed in again.
    private func pause(after failure: MailServiceError) -> Bool {
        let now = Date()
        var shown = failure
        switch failure.kind {
        case .throttled, .tooManyConnections:
            shown.retryAfter = pauseIMAP(for: failure.kind)
        case .needsSignIn:
            setHealth(.needsSignIn)
            events.yield(.error(accountID: account.id, message: failure.sentence))
            return false
        case .webSignInRequired:
            // Nothing FalconMail sends will help until the owner has been to the browser, so
            // it asks again only now and then rather than hammering the server.
            backoff = 1800
            setHealth(.blocked(reason: failure.sentence))
        case .connectionDropped:
            backoff = min(max(backoff * 2, 5), 300)
            let since = downSince ?? now
            downSince = since
            guard now.timeIntervalSince(since) >= quietReconnectPeriod else {
                setHealth(.connecting)
                return true
            }
            setHealth(.offline(since: since))
        default:
            backoff = min(max(backoff * 2, 5), 300)
            setHealth(.offline(since: downSince ?? now))
        }
        events.yield(.error(accountID: account.id, message: shown.sentence))
        return true
    }

    /// Stops asking the server for anything until the returned time. Gmail's throttle and its
    /// connection limit are the account's, not one connection's, and every command meanwhile
    /// only prolongs them.
    private func pauseIMAP(for kind: MailServiceError.Kind) -> Date {
        backoff = kind == .throttled ? min(max(backoff * 2, 1800), 7200) : TimeInterval.random(in: 300...600)
        let until = Date().addingTimeInterval(backoff)
        imapPause = (kind, until)
        setHealth(.imapPaused(until: until))
        return until
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
    /// asked for quiet.
    private func refuseWhilePaused() throws {
        guard pauseRemaining() != nil, let pause = imapPause else { return }
        throw MailServiceError(kind: pause.kind, account: account, detail: "paused until \(ISO8601DateFormatter.archive.string(from: pause.until))",
                               retryAfter: pause.until, isOneOff: true)
    }

    private func connectedSyncClient() async throws -> IMAPClient {
        if let c = syncClient, await c.isConnected { return c }
        let c = try await connector(account)
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
    /// however many callers ask at the same moment.
    private func connectedOpClient() async throws -> (client: IMAPClient, reused: Bool) {
        if let c = opClient, await c.isConnected { return (c, true) }
        if let pending = opConnecting { return (try await pending.value, false) }
        let account = account
        let connector = connector
        let opening = Task { try await connector(account) }
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
    /// the next call opens a fresh one. Work that found it already gone when its turn came sent
    /// nothing, and is always tried once more on a fresh connection. So is work on one that had
    /// sat unused, which the server or the network may have closed meanwhile, when
    /// `repeatable`; work that must not happen twice, such as an APPEND, is not, and nor is
    /// anything after a throttle or any other refusal that a new connection would only repeat.
    private func withOpConnection<T: Sendable>(repeatable: Bool = true,
                                               _ work: @Sendable (IMAPClient) async throws -> T) async throws -> T {
        try refuseWhilePaused()
        let (client, reused) = try await connectedOpClient()
        do {
            return try await client.exclusively(work)
        } catch {
            guard await !client.isConnected else { throw error }
            dropOpClient(client)
            let lost = MailServiceError.classify(error, account: account)
            let unsent = error is IMAPNotSent
            guard unsent || (reused && repeatable), lost.kind == .connectionDropped, !Task.isCancelled else { throw error }
            Log.info("sync", "\(account.email): op connection lost (\(Log.redacted(lost.detail, keeping: account.email))), reconnecting")
            let fresh = try await connectedOpClient().client
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

    static func signIn(_ account: AccountInfo, tokens: TokenStore) async throws -> IMAPClient {
        let connect: @Sendable () async throws -> IMAPClient = {
            let c = IMAPClient(host: account.imapHost, port: account.imapPort, label: account.email)
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
    /// server's own words. Nothing retries it, so its sentence promises no retry. A throttle or
    /// a refused connection pauses the account as it would on the sync connection, so that
    /// what the owner does next waits instead of asking the server again. A message or folder
    /// the server no longer has, or a folder renumbered, gets that folder brought up to date so
    /// the list stops offering it.
    private func failed(_ doing: String, _ error: Error, folder: FolderInfo?) async -> Error {
        if error is CancellationError { return error }
        var failure = MailServiceError.classify(error, account: account)
        failure.isOneOff = true
        Log.info("sync", Log.redacted("\(account.email): \(doing) failed: \(failure.kind.rawValue): \(failure.detail)", keeping: account.email))
        switch failure.kind {
        case .throttled, .tooManyConnections:
            // Only the server's own word starts a pause; the refusal given during one must
            // not make it longer.
            guard !(error is MailServiceError) else { break }
            let until = pauseIMAP(for: failure.kind)
            failure.retryAfter = until
            var status = failure
            status.isOneOff = false
            events.yield(.error(accountID: account.id, message: status.sentence))
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
        for f in folders where f.isSelectable && f.role != .all {
            try Task.checkCancellation()
            // Paused by a throttle met on the op connection: the rest waits for the pass after.
            guard pauseRemaining() == nil else { return }
            events.yield(.progress(accountID: account.id, text: "Checking \(f.name) in \(account.email)"))
            try await syncFolder(f, client: client)
        }
    }

    public var fullSyncInterval: TimeInterval = 5 * 60
    private var lastFullSync = Date()

    private var wantsSync: Bool { syncRequested || !requestedFolders.isEmpty }

    private func idleLoop(_ client: IMAPClient) async throws {
        guard let inbox = await store.folder(accountID: account.id, role: .inbox) else { return }
        while !Task.isCancelled {
            var changed = false
            if pauseRemaining() != nil || !wantsSync {
                _ = try await client.select(inbox.path)
                // A request made from here on ends the IDLE as soon as it starts, and one made
                // during the SELECT is seen just below, so none waits for IDLE to time out.
                await client.prepareIdle()
                let paused = pauseRemaining()
                if paused != nil || !wantsSync {
                    let wait = paused ?? max(30, fullSyncInterval - Date().timeIntervalSince(lastFullSync))
                    changed = try await client.idle(maxWait: min(wait, 20 * 60))
                }
            }
            // Nothing is fetched during a pause; the pass after it catches up.
            guard pauseRemaining() == nil else { continue }
            let due = Date().timeIntervalSince(lastFullSync) >= fullSyncInterval
            if syncRequested || due {
                try await syncAll(client)
                lastFullSync = Date()
                if pauseRemaining() == nil { setHealth(.online) }
                events.yield(.finished(accountID: account.id))
                continue
            }
            var targets = requestedFolders
            requestedFolders.removeAll()
            if changed, !targets.contains(inbox.id) { targets.insert(inbox.id, at: 0) }
            guard !targets.isEmpty else { continue }
            for id in targets {
                guard let fresh = await store.folder(id), fresh.isSelectable else { continue }
                try await syncFolder(fresh, client: client)
            }
            if pauseRemaining() == nil { setHealth(.online) }
            events.yield(.finished(accountID: account.id))
        }
    }

    public func syncFolder(_ input: FolderInfo, client: IMAPClient) async throws {
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

        var newMessages: [MessageSummary] = []
        if status.exists > 0 {
            var uids: [UInt32]
            if folder.lastSyncedUID == 0 {
                let all = try await client.uidSearch("ALL")
                uids = Array(all.suffix(initialWindow))
                folder.oldestSyncedUID = uids.first ?? 0
            } else {
                let fresh = try await client.uidSearch("UID \(folder.lastSyncedUID + 1):*").filter { $0 > folder.lastSyncedUID }.sorted()
                if fresh.count > catchUpWindow {
                    uids = Array(fresh.prefix(catchUpWindow))
                    pendingCatchUp = true
                    Log.info("sync", "\(account.email) \(folder.path): \(fresh.count) new messages, taking \(uids.count) this pass")
                } else {
                    uids = fresh
                }
            }
            var start = 0
            while start < uids.count {
                try Task.checkCancellation()
                let batch = Array(uids[start..<min(start + batchSize, uids.count)])
                let envelopes = try await client.fetchEnvelopes(uids: batch)
                var summaries = await AccountSyncer.thread(envelopes.map { AccountSyncer.summary(from: $0, accountID: account.id, folderID: folder.id) }, in: fs)
                summaries.removeAll { isSuppressed(folderID: folder.id, uid: $0.uid) }
                for i in summaries.indices { summaries[i].hasBody = await fs.hasBody(uid: summaries[i].uid) }
                try await fs.upsert(summaries)
                newMessages.append(contentsOf: summaries)
                folder.lastSyncedUID = max(folder.lastSyncedUID, batch.max() ?? 0)
                start += batchSize
                await store.notifyMessagesChanged(folderID: folder.id)
            }
            if folder.oldestSyncedUID == 0 { folder.oldestSyncedUID = uids.first ?? folder.lastSyncedUID }
        }

        if folder.role == .inbox, !newMessages.isEmpty {
            newMessages = await withoutMuted(newMessages, folder: folder, fs: fs, client: client)
        }

        if folder.oldestSyncedUID > 0 {
            let flags = try await client.fetchFlags(uidRange: "\(folder.oldestSyncedUID):*")
            let known = await fs.uids()
            let serverUIDs = Set(flags.map { $0.uid })
            let live = flags.filter { !isSuppressed(folderID: folder.id, uid: $0.uid) }
            let updates = live.map { (uid: $0.uid, flags: MessageFlags(imapFlags: $0.flags)) }
            _ = try await fs.setFlags(updates)
            let gone = known.filter { $0 >= folder.oldestSyncedUID && !serverUIDs.contains($0) }
            if !gone.isEmpty {
                try await fs.remove(uids: Array(gone))
                await indexer?.remove(ids: gone.map { MessageSummary.makeID(accountID: account.id, folderID: folder.id, uid: $0) })
            }
        } else if status.exists == 0 {
            let known = await fs.uids()
            if !known.isEmpty { try await fs.remove(uids: Array(known)) }
        }

        folder.lastSyncDate = Date()
        let pass = folder
        try await store.updateFolder(folder.id) { current in
            // A pass that met a newer numbering owns the record now.
            guard current.uidValidity == 0 || current.uidValidity == pass.uidValidity else { return }
            current.uidValidity = pass.uidValidity
            current.uidNext = pass.uidNext
            current.lastSyncedUID = max(current.lastSyncedUID, pass.lastSyncedUID)
            // Load older may have reached further back while this pass ran.
            current.oldestSyncedUID = [current.oldestSyncedUID, pass.oldestSyncedUID].filter { $0 > 0 }.min() ?? 0
            current.lastSyncDate = pass.lastSyncDate
        }
        try await store.refreshCounts(folderID: folder.id)
        await store.notifyMessagesChanged(folderID: folder.id)
        events.yield(.folderSynced(folderID: folder.id))

        if !newMessages.isEmpty { await indexer?.index(newMessages) }

        try await prefetchBodies(folder: folder, fs: fs, client: client, preferred: newMessages)

        var survivors = newMessages
        if folder.role == .inbox, listedBefore, !newMessages.isEmpty {
            let relocated = await applyRules(to: newMessages, folder: folder, fs: fs) { work in try await work(client) }
            survivors.removeAll { relocated.contains($0.uid) }
        }
        if folder.role == .inbox, listedBefore, !survivors.isEmpty {
            events.yield(.newMessages(accountID: account.id, folderID: folder.id, messages: survivors))
        }
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
            guard await meter.allows(m.size, for: account.id, budget: dailyPrefetchBudget) else {
                if !budgetNoticeGiven {
                    budgetNoticeGiven = true
                    let used = await meter.spentToday(account.id) / 1_000_000
                    Log.info("sync", "\(account.email): \(used) MB downloaded today, pausing offline copies until tomorrow")
                    events.yield(.progress(accountID: account.id, text: "\(account.email) has downloaded \(used) MB today; new mail still arrives and messages open on demand"))
                }
                break
            }
            let raw: Data
            do {
                raw = try await client.fetchMessage(uid: m.uid)
            } catch is IMAPMessageMissing {
                continue
            }
            await meter.record(raw.count, for: account.id)
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
            date: h.first("Date").flatMap(RFC5322Date.parse) ?? Date(),
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
            guard await meter.allows(message.size, for: account.id, budget: dailyHardCeiling) else {
                throw MailServiceError(kind: .overBudget, account: account, detail: "daily ceiling reached", retryAfter: BandwidthMeter.nextDay)
            }
            let uid = message.uid
            raw = try await withMailbox(folder.path, uidValidity: folder.uidValidity) { try await $0.fetchMessage(uid: uid) }
        } catch {
            throw await failed("opening a message in \(folder.path)", error, folder: folder)
        }
        await meter.record(raw.count, for: account.id)
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
            // Never repeated on a fresh connection: an APPEND that did reach the server would be stored twice.
            _ = try await withOpConnection(repeatable: false) { client in
                try await client.append(mailbox: folder.path, message: raw, flags: flags.imapFlags, date: date)
            }
        } catch {
            throw await failed("saving a message to \(folder.path)", error, folder: folder)
        }
        await requestSync(folderID: folder.id)
    }

    public func loadOlder(folder input: FolderInfo, count: Int = 1000) async throws {
        guard let folder = await store.folder(input.id), folder.oldestSyncedUID > 1 else { return }
        let fs = try await store.folderStore(folder)
        let oldest = folder.oldestSyncedUID
        let window: [UInt32]
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
    /// otherwise hold up every message the reader opens.
    public func openArchiveSourceClient() async throws -> IMAPClient {
        do {
            try refuseWhilePaused()
            return try await connector(account)
        } catch {
            throw await failed("connecting for an archive", error, folder: nil)
        }
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
