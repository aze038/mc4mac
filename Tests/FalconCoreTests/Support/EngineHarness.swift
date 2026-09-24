import Foundation
import XCTest
@testable import FalconCore

/// An account on a fake server, with its own temporary data folder and log, and an
/// `AccountSyncer` that connects to the fake over plain TCP. Nothing here reads a keychain item
/// or touches the owner's data: the store, the meter, the pending actions and the log all live
/// in the temporary folder, and nothing is indexed in Spotlight.
final class EngineHarness: @unchecked Sendable {
    let server: FakeIMAPServer
    let root: URL
    let layout: FileLayout
    let store: MailStore
    let pending: PendingActionStore
    let meter: BandwidthMeter
    let account: AccountInfo
    let syncer: AccountSyncer
    let events = EventLog()
    private let listener: Task<Void, Never>

    /// A Gmail-like server: INBOX, Sent, Trash and All Mail with their special-use attributes.
    static func gmailServer(capabilities: [String]? = nil, latency: TimeInterval = 0.002) throws -> FakeIMAPServer {
        let server = capabilities.map { FakeIMAPServer(capabilities: $0, latency: latency) } ?? FakeIMAPServer(latency: latency)
        server.addMailbox("INBOX")
        server.addMailbox("[Gmail]/Sent Mail", attributes: ["\\Sent"], uidValidity: 1_700_000_100)
        server.addMailbox("[Gmail]/Trash", attributes: ["\\Trash"], uidValidity: 1_700_000_200)
        server.addMailbox("[Gmail]/All Mail", attributes: ["\\All"], uidValidity: 1_700_000_300)
        try server.start()
        return server
    }

    init(server: FakeIMAPServer, email: String = "owner@example.com", root existing: URL? = nil) async throws {
        self.server = server
        root = existing ?? FileManager.default.temporaryDirectory.appendingPathComponent("falcon-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Log.start(in: root)
        layout = FileLayout(root: root)
        store = MailStore(layout: layout)
        try await store.load()
        if let known = await store.allAccounts().first {
            account = known
        } else {
            account = AccountInfo(email: email, displayName: "Owner", provider: "google", imapHost: "127.0.0.1", imapPort: server.port,
                                  authMethod: "password", username: email)
            try await store.saveAccount(account)
        }
        pending = PendingActionStore(layout: layout)
        meter = BandwidthMeter(layout: layout)
        let (stream, continuation) = AsyncStream<SyncEvent>.makeStream()
        let port = server.port
        syncer = AccountSyncer(account: account, store: store,
                               tokens: TokenStore(keychain: KeychainStore(service: "com.falconmail.tests.unused"), clientConfigProvider: { nil }),
                               rules: RuleStore(layout: layout), mutes: MuteStore(layout: layout), indexer: nil,
                               pendingActions: pending, events: continuation, meter: meter,
                               connector: { account in
                                   let c = IMAPClient(host: "127.0.0.1", port: port, tls: false, label: account.email)
                                   try await c.connect()
                                   try await c.login(user: account.email, password: "not-a-password")
                                   return c
                               })
        let events = events
        listener = Task { for await e in stream { await events.append(e) } }
        await syncer.setBodyPrefetch(0)
    }

    /// Lists the folders and syncs each once on a connection of its own, as a pass of the sync
    /// loop would, without starting the loop.
    func syncOnce() async throws {
        let c = try await server.client(label: account.email)
        let folders = try await store.reconcileFolders(accountID: account.id, listed: try await c.listFolders())
        for f in folders where f.isSelectable && f.role != .all { try await syncer.syncFolder(f, client: c) }
        await c.logout()
    }

    func folder(_ path: String) async throws -> FolderInfo {
        let found = await store.folder(accountID: account.id, path: path)
        return try XCTUnwrap(found, "no folder \(path)")
    }

    func message(uid: UInt32, in path: String) async throws -> MessageSummary {
        let found = await (try store.folderStore(try await folder(path))).message(uid: uid)
        return try XCTUnwrap(found, "no message \(uid) in \(path)")
    }

    func uids(in path: String) async throws -> Set<UInt32> {
        await (try store.folderStore(try await folder(path))).uids()
    }

    func logText() -> String {
        Log.flush()
        return (try? String(contentsOf: root.appendingPathComponent("falconmail.log"), encoding: .utf8)) ?? ""
    }

    func finish() async {
        await syncer.stop()
        listener.cancel()
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

actor EventLog {
    private(set) var all: [SyncEvent] = []

    func append(_ e: SyncEvent) { all.append(e) }

    var errors: [String] {
        all.compactMap { if case .error(_, let message) = $0 { return message }; return nil }
    }

    var actionFailures: [String] {
        all.compactMap { if case .actionFailed(_, let message) = $0 { return message }; return nil }
    }

    var healths: [AccountHealth] {
        all.compactMap { if case .health(_, let h) = $0 { return h }; return nil }
    }
}

struct TimedOut: Error {}

/// Runs `body`, failing with `TimedOut` after `seconds` even if it never returns. A task group
/// would wait for a hung child before returning, and so hang the test with it.
func within<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    let once = Once()
    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        let work = Task {
            do {
                let value = try await body()
                if once.claim() { cont.resume(returning: value) }
            } catch {
                if once.claim() { cont.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if once.claim() {
                work.cancel()
                cont.resume(throwing: TimedOut())
            }
        }
    }
}

/// Waits until `condition` holds, checking every 20 ms. False if it never did within `seconds`.
func eventually(_ seconds: TimeInterval = 5, _ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

func assertEventually(_ message: String = "", within seconds: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                      _ condition: @escaping @Sendable () async -> Bool) async {
    let held = await eventually(seconds, condition)
    XCTAssertTrue(held, message, file: file, line: line)
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            guard !done else { return false }
            done = true
            return true
        }
    }
}
