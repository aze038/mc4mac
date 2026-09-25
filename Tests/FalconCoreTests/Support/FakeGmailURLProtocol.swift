import Foundation
@testable import FalconCore

/// Serves Gmail API requests from `FakeGmailMailbox`es inside the test process, so no test ever
/// reaches Google. Each registration gets its own made-up host under `.gmail.test`, and names the
/// client its requests come from, so a second client (olm2cloud, or another Mac) can share one
/// mailbox and its per-user budget. An answer arrives after the mailbox's delay for its call, and
/// the request counts as in flight until then.
final class FakeGmailURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var mailboxes: [String: (mailbox: FakeGmailMailbox, client: String)] = [:]
    private let stateLock = NSLock()
    private var stopped = false

    /// Registers a mailbox and returns the base URL a client should use for it.
    static func register(_ mailbox: FakeGmailMailbox, client: String = FakeGmailMailbox.falconMail) -> URL {
        let host = "m\(UUID().uuidString.prefix(8).lowercased()).gmail.test"
        lock.withLock { mailboxes[host] = (mailbox, client) }
        return URL(string: "https://\(host)/gmail/v1/users/me")!
    }

    /// The same ephemeral configuration the app uses, routed to the fake.
    static let session: URLSession = {
        let configuration = GoogleAPI.ephemeralConfiguration()
        configuration.protocolClasses = [FakeGmailURLProtocol.self]
        configuration.httpMaximumConnectionsPerHost = 64
        return URLSession(configuration: configuration)
    }()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".gmail.test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let entry = request.url?.host.flatMap { host in FakeGmailURLProtocol.lock.withLock { FakeGmailURLProtocol.mailboxes[host] } }
        guard let entry else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        var request = self.request
        // URLSession hands a body to a protocol as a stream; the mailbox reads it as data.
        if request.httpBody == nil, request.httpBodyStream != nil { request.httpBody = FakeGmailMailbox.body(of: request) }
        let mailbox = entry.mailbox
        let arrival = mailbox.arrive(request, client: entry.client)
        let result = mailbox.respond(to: request, arrival: arrival)
        let delay = mailbox.delay(for: arrival)
        let deliver = { [self] in
            mailbox.depart(arrival)
            guard !stateLock.withLock({ stopped }) else { return }
            switch result {
            case .success(let (response, data)):
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            case .failure(let error):
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() {
        stateLock.withLock { stopped = true }
    }
}

/// Tokens without the keychain: a stale one until a refresh is asked for.
actor FakeTokenSource: GoogleAccessTokenSource {
    private(set) var refreshes = 0
    private var current: String
    private let afterRefresh: String

    init(current: String = "token-1", afterRefresh: String = "token-2") {
        self.current = current
        self.afterRefresh = afterRefresh
    }

    func accessToken(for accountID: UUID) async throws -> String { current }

    func refreshedAccessToken(for accountID: UUID) async throws -> String {
        refreshes += 1
        current = afterRefresh
        return current
    }
}

/// A clock that moves only when someone sleeps on it, so budget waits of minutes take no time.
final class VirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private(set) var slept: TimeInterval = 0

    init(start: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
        current = start
    }

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock {
            current = current.addingTimeInterval(seconds)
            slept += seconds
        }
    }

    func limiter(unitsPerMinute: Int = GmailQuotaLimiter.defaultUnitsPerMinute) -> GmailQuotaLimiter {
        GmailQuotaLimiter(unitsPerMinute: unitsPerMinute, now: { [self] in now }, sleep: { [self] seconds in advance(seconds) })
    }
}

/// Everything under a folder by relative path, with sizes and modification dates, to show that
/// something wrote nothing there.
enum DiskSnapshot {
    static func of(_ root: URL) -> [String: String] {
        var out: [String: String] = [:]
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return out }
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let relative = url.path.replacingOccurrences(of: root.path, with: "")
            out[relative] = "\(values?.fileSize ?? -1)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.isDirectory == true)"
        }
        return out
    }

    /// This test process's own caches folder, where a shared URLCache would write.
    static var processCaches: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName, isDirectory: true)
    }
}

/// A clock that moves only when the test moves it. Unlike `VirtualClock`, a sleeper waits until
/// the clock has passed its deadline, so several sleepers at once each wait their own time.
final class SteppedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var sleepers: [(deadline: Date, continuation: CheckedContinuation<Void, Never>)] = []

    init(start: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
        current = start
    }

    var now: Date { lock.withLock { current } }

    func sleep(_ seconds: TimeInterval) async {
        let deadline = now.addingTimeInterval(max(0, seconds))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if current >= deadline { return true }
                sleepers.append((deadline, continuation))
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    var sleeperCount: Int { lock.withLock { sleepers.count } }

    /// Moves the clock on and wakes every sleeper whose deadline has passed.
    func advance(_ seconds: TimeInterval) {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            current = current.addingTimeInterval(seconds)
            let due = sleepers.filter { $0.deadline <= current }.map(\.continuation)
            sleepers.removeAll { $0.deadline <= current }
            return due
        }
        for continuation in due { continuation.resume() }
    }

    /// Lets tasks woken by the clock run before the test looks.
    static func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 2_000_000)
        for _ in 0..<20 { await Task.yield() }
    }

    /// Advances in steps, letting woken tasks run after each.
    func run(for seconds: TimeInterval, step: TimeInterval = 0.05) async {
        var left = seconds
        while left > 0 {
            let s = min(step, left)
            advance(s)
            left -= s
            await SteppedClock.settle()
        }
    }
}

enum GmailTestKit {
    static func client(_ mailbox: FakeGmailMailbox, tokens: FakeTokenSource = FakeTokenSource(), clock: VirtualClock = VirtualClock(),
                       accountID: UUID = UUID(), maxWait: TimeInterval = 8) -> GmailAPIClient {
        let base = FakeGmailURLProtocol.register(mailbox)
        let api = GoogleAPI(tokenSource: tokens, accountID: accountID, session: FakeGmailURLProtocol.session)
        return GmailAPIClient(api: api, limiter: clock.limiter(), base: base, maxWait: maxWait)
    }

    /// The Gmail engine's transport on the fake, with a budget of its own on `clock`. Its
    /// background gate is its own too, so tests never share one.
    static func transport(_ mailbox: FakeGmailMailbox, clock: VirtualClock = VirtualClock(), tokens: FakeTokenSource = FakeTokenSource(),
                          accountID: UUID = UUID(), policy: GmailBudgetPolicy = .standard, meter: TrafficMeter? = nil,
                          options: GmailTransportOptions = GmailTransportOptions(), client: String = FakeGmailMailbox.falconMail,
                          gate: GmailBackgroundGate = GmailBackgroundGate(limit: 8)) -> GmailHTTPTransport {
        let budget = GmailBudget(accountID: accountID, policy: policy, meter: meter, gate: gate,
                                 now: { clock.now }, sleep: { seconds in clock.advance(seconds) }, jitter: { 0 })
        return transport(mailbox, budget: budget, tokens: tokens, options: options, client: client)
    }

    /// The transport on a budget the test made, such as one on a `SteppedClock`.
    static func transport(_ mailbox: FakeGmailMailbox, budget: GmailBudget, tokens: FakeTokenSource = FakeTokenSource(),
                          options: GmailTransportOptions = GmailTransportOptions(),
                          client: String = FakeGmailMailbox.falconMail) -> GmailHTTPTransport {
        let base = FakeGmailURLProtocol.register(mailbox, client: client)
        let api = GoogleAPI(tokenSource: tokens, accountID: budget.accountID, session: FakeGmailURLProtocol.session)
        return GmailHTTPTransport(api: api, budget: budget, endpoints: GmailEndpoints(base: base), options: options)
    }

    /// A budget on a manual clock, whose sleeps wait for the test to move time on.
    static func budget(_ clock: SteppedClock, policy: GmailBudgetPolicy = .standard, meter: TrafficMeter? = nil,
                       gate: GmailBackgroundGate? = GmailBackgroundGate(limit: 8), accountID: UUID = UUID()) -> GmailBudget {
        GmailBudget(accountID: accountID, policy: policy, meter: meter, gate: gate, now: { clock.now },
                    sleep: { seconds in await clock.sleep(seconds) }, jitter: { 0 })
    }
}
