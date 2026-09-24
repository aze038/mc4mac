import Foundation
@testable import FalconCore

/// Serves Gmail API requests from `FakeGmailMailbox`es inside the test process, so no test ever
/// reaches Google. Each mailbox gets its own made-up host under `.gmail.test`.
final class FakeGmailURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var mailboxes: [String: FakeGmailMailbox] = [:]

    /// Registers a mailbox and returns the base URL a `GmailAPIClient` should use for it.
    static func register(_ mailbox: FakeGmailMailbox) -> URL {
        let host = "m\(UUID().uuidString.prefix(8).lowercased()).gmail.test"
        lock.withLock { mailboxes[host] = mailbox }
        return URL(string: "https://\(host)/gmail/v1/users/me")!
    }

    /// The same ephemeral configuration the app uses, routed to the fake.
    static let session: URLSession = {
        let configuration = GoogleAPI.ephemeralConfiguration()
        configuration.protocolClasses = [FakeGmailURLProtocol.self]
        return URLSession(configuration: configuration)
    }()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".gmail.test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let mailbox = request.url?.host.flatMap { host in FakeGmailURLProtocol.lock.withLock { FakeGmailURLProtocol.mailboxes[host] } }
        guard let mailbox else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        switch mailbox.handle(request) {
        case .success(let (response, data)):
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
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

enum GmailTestKit {
    static func client(_ mailbox: FakeGmailMailbox, tokens: FakeTokenSource = FakeTokenSource(), clock: VirtualClock = VirtualClock(),
                       accountID: UUID = UUID(), maxWait: TimeInterval = 8) -> GmailAPIClient {
        let base = FakeGmailURLProtocol.register(mailbox)
        let api = GoogleAPI(tokenSource: tokens, accountID: accountID, session: FakeGmailURLProtocol.session)
        return GmailAPIClient(api: api, limiter: clock.limiter(), base: base, maxWait: maxWait)
    }
}
