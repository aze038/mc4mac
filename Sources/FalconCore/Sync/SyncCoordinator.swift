import Foundation
import Network

public actor SyncCoordinator {
    public let store: MailStore
    public let tokens: TokenStore
    public let rules: RuleStore
    public let mutes: MuteStore
    public let indexer: SpotlightIndexer
    public let pendingActions: PendingActionStore
    public let meter: TrafficMeter
    private var syncers: [UUID: AccountSyncer] = [:]
    private var heartbeat: Task<Void, Never>?
    private var meterSaves: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private let eventContinuation: AsyncStream<SyncEvent>.Continuation
    public nonisolated let events: AsyncStream<SyncEvent>

    public init(store: MailStore, tokens: TokenStore, rules: RuleStore, mutes: MuteStore, indexer: SpotlightIndexer,
                pendingActions: PendingActionStore, meter: TrafficMeter = .shared) {
        self.store = store
        self.tokens = tokens
        self.rules = rules
        self.mutes = mutes
        self.indexer = indexer
        self.pendingActions = pendingActions
        self.meter = meter
        var cont: AsyncStream<SyncEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.eventContinuation = cont
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
    /// knowing it; every account opens fresh ones.
    private func watchTheNetwork() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        let seen = PathMemory()
        monitor.pathUpdateHandler = { [weak self] path in
            guard seen.changed(to: path), path.status == .satisfied else { return }
            Task { await self?.reconnectAll(reason: "the network changed") }
        }
        monitor.start(queue: DispatchQueue(label: "falconmail.network"))
        pathMonitor = monitor
    }

    /// Every running account closes its connections and opens them again, as after the Mac
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
        Log.info("app", "alive accounts=\(syncers.count) imapDown24h=\(downloaded / 1_000_000)MB imapUp24h=\(uploaded / 1_000_000)MB")
    }

    public var bodyPrefetch = 150
    public var maxOfflineBodyBytes = 5 * 1024 * 1024
    public var undoWindow: TimeInterval = 5

    public func setBodyPrefetch(_ count: Int, maxBytes: Int? = nil) async {
        bodyPrefetch = count
        if let maxBytes { maxOfflineBodyBytes = maxBytes }
        for s in syncers.values { await s.setBodyPrefetch(count, maxBytes: maxOfflineBodyBytes) }
    }

    public func setUndoWindow(_ seconds: TimeInterval) async {
        undoWindow = max(0, seconds)
        for s in syncers.values { await s.setUndoWindow(undoWindow) }
    }

    public func flushPendingActions() async {
        for s in syncers.values { await s.flushPending() }
    }

    public func start(account: AccountInfo) async {
        guard account.isEnabled else { await stop(accountID: account.id); return }
        if let existing = syncers[account.id] { await existing.stop() }
        let s = AccountSyncer(account: account, store: store, tokens: tokens, rules: rules, mutes: mutes,
                              indexer: indexer, pendingActions: pendingActions, events: eventContinuation, meter: meter)
        await s.setBodyPrefetch(bodyPrefetch, maxBytes: maxOfflineBodyBytes)
        await s.setUndoWindow(undoWindow)
        syncers[account.id] = s
        await s.start()
    }

    public func stop(accountID: UUID) async {
        await syncers[accountID]?.stop()
        syncers[accountID] = nil
    }

    public func stopAll() async {
        heartbeat?.cancel()
        heartbeat = nil
        meterSaves?.cancel()
        meterSaves = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        for s in syncers.values { await s.stop() }
        syncers.removeAll()
        meter.persist()
    }

    public func syncer(for accountID: UUID) -> AccountSyncer? { syncers[accountID] }

    public func syncNow() async {
        for s in syncers.values { await s.requestSync() }
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
        let smtp = SMTPClient(host: account.smtpHost, port: account.smtpPort)
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
