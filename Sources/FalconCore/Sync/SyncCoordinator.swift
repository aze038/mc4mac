import Foundation

public actor SyncCoordinator {
    public let store: MailStore
    public let tokens: TokenStore
    public let rules: RuleStore
    public let mutes: MuteStore
    public let indexer: SpotlightIndexer
    public let pendingActions: PendingActionStore
    private var syncers: [UUID: AccountSyncer] = [:]
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
        for s in syncers.values { await s.stop() }
        syncers.removeAll()
    }

    public func syncer(for accountID: UUID) -> AccountSyncer? { syncers[accountID] }

    public func syncNow() async {
        for s in syncers.values { await s.requestSync() }
    }

    /// The accounts being kept in sync, which a check for new mail asks.
    public var runningAccountIDs: Set<UUID> { Set(syncers.keys) }

    /// Send & Receive: a sync of every account whose pass ends with `checked`.
    public func checkForNewMail() async {
        for s in syncers.values { await s.requestSync(check: true) }
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
        try await smtp.connect()
        if account.usesPassword {
            try await smtp.authenticatePlain(user: account.loginName, password: try await tokens.password(for: accountID))
        } else {
            let token = try await tokens.validAccessToken(for: accountID)
            try await smtp.authenticateXOAuth2(user: account.email, accessToken: token)
        }
        try await smtp.send(from: from, recipients: recipients, message: message)
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
