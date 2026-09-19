import Foundation

public actor SyncCoordinator {
    public let store: MailStore
    public let tokens: TokenStore
    public let rules: RuleStore
    public let indexer: SpotlightIndexer
    private var syncers: [UUID: AccountSyncer] = [:]
    private let eventContinuation: AsyncStream<SyncEvent>.Continuation
    public nonisolated let events: AsyncStream<SyncEvent>

    public init(store: MailStore, tokens: TokenStore, rules: RuleStore, indexer: SpotlightIndexer) {
        self.store = store
        self.tokens = tokens
        self.rules = rules
        self.indexer = indexer
        var cont: AsyncStream<SyncEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.eventContinuation = cont
    }

    public func startAll() async {
        for account in await store.allAccounts() where account.isEnabled {
            await start(account: account)
        }
    }

    public func start(account: AccountInfo) async {
        if let existing = syncers[account.id] { await existing.stop() }
        let s = AccountSyncer(account: account, store: store, tokens: tokens, rules: rules, indexer: indexer, events: eventContinuation)
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
}

public struct SMTPSender: MessageSender {
    let store: MailStore
    let tokens: TokenStore

    public init(store: MailStore, tokens: TokenStore) {
        self.store = store
        self.tokens = tokens
    }

    public func send(accountID: UUID, from: String, recipients: [String], message: Data) async throws {
        guard let account = await store.account(accountID) else { throw FalconError.storage("account missing") }
        let token = try await tokens.validAccessToken(for: accountID)
        let smtp = SMTPClient(host: account.smtpHost, port: account.smtpPort)
        try await smtp.connect()
        try await smtp.authenticateXOAuth2(user: account.email, accessToken: token)
        try await smtp.send(from: from, recipients: recipients, message: message)
        await smtp.quit()
    }
}
