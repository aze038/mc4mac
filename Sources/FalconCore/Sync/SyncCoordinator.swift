import Foundation

public actor SyncCoordinator {
    public let store: MailStore
    public let tokens: TokenStore
    public let rules: RuleStore
    public let mutes: MuteStore
    public let indexer: SpotlightIndexer
    public let pendingActions: PendingActionStore
    private var syncers: [UUID: AccountSyncer] = [:]
    private var heartbeat: Task<Void, Never>?
    private let eventContinuation: AsyncStream<SyncEvent>.Continuation
    public nonisolated let events: AsyncStream<SyncEvent>

    public init(store: MailStore, tokens: TokenStore, rules: RuleStore, mutes: MuteStore, indexer: SpotlightIndexer,
                pendingActions: PendingActionStore) {
        self.store = store
        self.tokens = tokens
        self.rules = rules
        self.mutes = mutes
        self.indexer = indexer
        self.pendingActions = pendingActions
        var cont: AsyncStream<SyncEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.eventContinuation = cont
    }

    public func startAll() async {
        for account in await store.allAccounts() where account.isEnabled {
            await start(account: account)
        }
        startHeartbeat()
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
        for id in syncers.keys { downloaded += await BandwidthMeter.shared.spentToday(id) }
        Log.info("app", "alive accounts=\(syncers.count) bodiesToday=\(downloaded / 1_000_000)MB")
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
                              indexer: indexer, pendingActions: pendingActions, events: eventContinuation)
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
        for s in syncers.values { await s.stop() }
        syncers.removeAll()
    }

    public func syncer(for accountID: UUID) -> AccountSyncer? { syncers[accountID] }

    public func syncNow() async {
        for s in syncers.values { await s.requestSync() }
    }
}

public struct SMTPSender: MessageSender {
    let store: MailStore
    let tokens: TokenStore
    let coordinator: SyncCoordinator?

    public init(store: MailStore, tokens: TokenStore, coordinator: SyncCoordinator? = nil) {
        self.store = store
        self.tokens = tokens
        self.coordinator = coordinator
    }

    public func send(accountID: UUID, from: String, recipients: [String], message: Data) async throws {
        guard let account = await store.account(accountID) else { throw FalconError.storage("account missing") }
        let smtp = SMTPClient(host: account.smtpHost, port: account.smtpPort)
        do {
            try await smtp.connect()
            if account.usesPassword {
                try await smtp.authenticatePlain(user: account.loginName, password: try await tokens.password(for: accountID))
            } else {
                let token = try await tokens.validAccessToken(for: accountID)
                try await smtp.authenticateXOAuth2(user: account.email, accessToken: token)
            }
            try await smtp.send(from: from, recipients: recipients, message: message)
        } catch {
            await smtp.quit()
            throw MailServiceError.classify(error, account: account)
        }
        await smtp.quit()
        await appendToSentFolder(message, account: account)
    }

    private func appendToSentFolder(_ message: Data, account: AccountInfo) async {
        guard account.provider != "google", let coordinator else { return }
        guard let syncer = await coordinator.syncer(for: account.id) else { return }
        let folders = await store.folders(for: account.id)
        guard let sent = folders.first(where: { $0.role == .sent && $0.isSelectable }) else { return }
        try? await syncer.append(raw: message, to: sent, flags: .seen, date: Date())
    }
}
