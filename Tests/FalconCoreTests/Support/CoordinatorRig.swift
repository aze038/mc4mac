import Foundation
import XCTest
@testable import FalconCore

/// Counts every IMAP connection the IMAP engine asks for, and makes each to the fake IMAP server
/// on loopback, so a test sees both whether the engine asked and whether a connection was made.
final class IMAPConnectorSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []
    let port: UInt16
    /// Refuses every connection, as when the Mac is offline.
    var refuses = false

    init(port: UInt16) {
        self.port = port
    }

    var calls: [String] { lock.withLock { asked } }

    var connector: IMAPConnector {
        { [self] account, traffic in
            lock.withLock { asked.append(account.email) }
            if lock.withLock({ refuses }) { throw URLError(.notConnectedToInternet) }
            let client = IMAPClient(host: "127.0.0.1", port: port, tls: false, label: account.email, traffic: traffic)
            try await client.connect()
            try await client.login(user: account.email, password: "not-a-password")
            return client
        }
    }
}

/// Counts every message handed to SMTP.
final class SMTPDeliverSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var delivered: [UUID] = []

    var accounts: [UUID] { lock.withLock { delivered } }

    func deliver(_ account: AccountInfo) {
        lock.withLock { delivered.append(account.id) }
    }
}

/// FalconMail's coordinator over a temporary data folder, put together as the app puts it: the
/// Gmail engine of each Google account over the in-memory Gmail, the Outbox sending through
/// `RoutingSender`, and IMAP only ever to a fake server on loopback. Nothing here reads a keychain
/// item, reaches Google or a mail server, or touches Spotlight or the owner's preferences.
final class CoordinatorRig: @unchecked Sendable {
    let root: URL
    let layout: FileLayout
    let store: MailStore
    let pending: PendingActionStore
    let rules: RuleStore
    let mutes: MuteStore
    let indexer = SpotlightIndexer.inMemory()
    let meter: TrafficMeter
    let imap: FakeIMAPServer
    let connector: IMAPConnectorSpy
    let smtp = SMTPDeliverSpy()
    let switches: MemoryGmailEngineSwitchStore
    let clock: ManualGmailClock
    let events = GmailEventRecorder()
    let tokens: TokenStore
    private let lock = NSLock()
    private var fakes: [UUID: FakeGmail] = [:]
    private var settingsGiven: [UUID: GmailEngineSettings] = [:]
    /// The read-only probe the coordinator runs once per account; none unless a test gives one.
    var probe: GmailProbeRunner?
    private(set) var coordinator: SyncCoordinator!
    private(set) var outbox: Outbox!
    private var listener: Task<Void, Never>?
    let fillsCache: Bool

    init(root existing: URL? = nil, switches: MemoryGmailEngineSwitchStore = MemoryGmailEngineSwitchStore(), fillsCache: Bool = false,
         now: Date = Date(timeIntervalSince1970: 1_790_000_120)) throws {
        root = existing ?? FileManager.default.temporaryDirectory.appendingPathComponent("falcon-coordinator-\(UUID().uuidString)",
                                                                                            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Log.start(in: root)
        layout = FileLayout(root: root)
        store = MailStore(layout: layout)
        pending = PendingActionStore(layout: layout)
        rules = RuleStore(layout: layout)
        mutes = MuteStore(layout: layout)
        meter = TrafficMeter(layout: layout)
        imap = try EngineHarness.gmailServer()
        connector = IMAPConnectorSpy(port: imap.port)
        self.switches = switches
        self.fillsCache = fillsCache
        clock = ManualGmailClock(now)
        tokens = TokenStore(keychain: KeychainStore(service: "com.falconmail.tests.unused"),
                            vault: TokenVault(load: { _ in nil }, save: { _, _ in }, forget: { _ in }),
                            clientConfigProvider: { nil }, knownClientConfigs: { [] }, refresher: { token, _ in token })
    }

    /// A Google account signed in with Google, whose IMAP and SMTP settings point at the fake
    /// server, so that anything that tried them would be seen.
    func googleAccount(_ email: String = "owner-\(UUID().uuidString.prefix(8).lowercased())@example.com", id: UUID = UUID()) -> AccountInfo {
        AccountInfo(id: id, email: email, displayName: "Owner", provider: "google", imapHost: "127.0.0.1", imapPort: imap.port,
                    smtpHost: "127.0.0.1", smtpPort: 1, authMethod: "oauth")
    }

    /// The in-memory Gmail behind `account`.
    @discardableResult
    func gmail(for account: AccountInfo, mailbox: FakeGmailMailbox? = nil) -> FakeGmail {
        lock.withLock {
            if let known = fakes[account.id] { return known }
            let made = FakeGmail(email: account.email, accountID: account.id, mailbox: mailbox ?? FakeGmailMailbox(email: account.email))
            fakes[account.id] = made
            return made
        }
    }

    private func fake(_ id: UUID) -> FakeGmail? { lock.withLock { fakes[id] } }

    /// The settings the coordinator last gave the account's engine.
    func settings(of account: AccountInfo) -> GmailEngineSettings? { lock.withLock { settingsGiven[account.id] } }

    private func noteSettings(_ settings: GmailEngineSettings, for id: UUID) { lock.withLock { settingsGiven[id] = settings } }

    /// Starts the coordinator and the Outbox as the app does at launch.
    func launch(undoWindow: TimeInterval = 5) async throws {
        try await store.load()
        let layout = layout
        let mutes = mutes
        let rules = rules
        let clock = clock
        let fillsCache = fillsCache
        let actionClock = GmailActionClock(now: { clock.now() }, sleep: { seconds in
            try await Task.sleep(nanoseconds: UInt64(min(max(seconds, 0), 0.02) * 1_000_000_000))
        })
        let coordinator = SyncCoordinator(
            store: store, tokens: tokens, rules: rules, mutes: mutes, indexer: indexer, pendingActions: pending, meter: meter,
            switches: switches,
            makeEngine: { [weak self] account, setup in
                let gmail = self?.fake(account.id) ?? FakeGmail(email: account.email, accountID: account.id)
                self?.noteSettings(setup.settings, for: account.id)
                let store = GmailFileStore(accountID: account.id, files: GmailFiles(layout: layout, accountID: account.id))
                var settings = setup.settings
                settings.fillsCache = fillsCache
                return await GmailAccountAssembly(account: account, transport: gmail, store: store, listIndex: setup.listIndex,
                                                  mutes: mutes, rules: rules, settings: settings, clock: clock, actionClock: actionClock,
                                                  folderHints: setup.folderHints, undoWindow: setup.undoWindow, events: setup.events)
            },
            probe: probe, connector: connector.connector, switchRetry: 0.2, switchOffWait: 1)
        await coordinator.setUndoWindow(undoWindow)
        self.coordinator = coordinator
        let smtp = smtp
        let store = store
        let sender = SMTPSender(store: store, syncer: { await coordinator.syncer(for: $0) }) { account, _, _, _ in
            smtp.deliver(account)
        }
        outbox = Outbox(layout: layout, sender: RoutingSender(smtp: sender, route: { await coordinator.sendRoute(for: $0) }),
                        undoWindow: 0, confirmAfter: [0.05, 0.15], retryDelay: { _ in 0 })
        let events = events
        listener = Task { for await event in coordinator.events { events.record(event) } }
        await coordinator.startAll()
    }

    /// Quits as the app does: what waits is sent, then every engine stops.
    func quit() async {
        await coordinator?.flushPendingActions()
        await coordinator?.stopAll()
        listener?.cancel()
        listener = nil
    }

    func assembly(_ account: AccountInfo) async throws -> GmailAccountAssembly {
        let found = await coordinator.assembly(for: account.id)
        return try XCTUnwrap(found, "no Gmail engine for \(account.email)")
    }

    func backfilled(_ account: AccountInfo, timeout: TimeInterval = 60) async throws {
        let assembly = try await assembly(account)
        try await eventually(timeout: timeout, "the mailbox is listed") { await assembly.engine.state.backfill?.phase == .complete }
    }

    func folder(_ role: FolderRole, of account: AccountInfo) async throws -> FolderInfo {
        let folders = try await assembly(account).engine.folders()
        return try XCTUnwrap(folders.first { $0.role == role }, "no \(role) folder")
    }

    func finish() async {
        await quit()
        for account in await store.allAccounts() { TransportGuard.shared.allowMailServers(for: account.id) }
        imap.stop()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - v1.10's files for an account

    /// Writes an account's IMAP store as v1.10.3 left it: `accounts.json`, its `folders.json` and
    /// an Inbox with a few stored rows, in v1.10.3's own shapes.
    @discardableResult
    func writePreviousRelease(_ account: AccountInfo, inbox rows: [PreviousRelease.Row] = PreviousRelease.Row.samples) throws
        -> PreviousRelease.Store {
        try PreviousRelease.writeStore(for: account, rows: rows, layout: layout)
    }

    /// A digest of every file under `Accounts/<id>/` apart from `Gmail/`, by path.
    func imapStoreDigest(_ account: AccountInfo) -> [String: String] {
        PreviousRelease.digest(of: layout.accountDirectory(account.id), excluding: "Gmail")
    }
}
