import Foundation
import XCTest
@testable import FalconCore

/// Stands in for the Apps Script web app. Every request of a session built with it is
/// answered here, so no test ever reaches a network.
final class FakeDiagnosticsServer: URLProtocol {
    struct Reply {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()

        static func json(_ text: String, status: Int = 200) -> Reply {
            Reply(status: status, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
        }

        static func redirect(to location: String) -> Reply {
            Reply(status: 302, headers: ["Location": location])
        }
    }

    struct Seen {
        var request: URLRequest
        var body: Data
    }

    private static let lock = NSLock()
    private static var handler: ((URLRequest, Data) -> Reply?)?
    private static var seen: [Seen] = []

    static func respond(_ handler: @escaping (URLRequest, Data) -> Reply?) {
        lock.withLock {
            self.handler = handler
            seen = []
        }
    }

    static var requests: [Seen] { lock.withLock { seen } }

    static func reset() {
        lock.withLock {
            handler = nil
            seen = []
        }
    }

    static func session() -> URLSession {
        DiagnosticsUploader.makeSession(protocolClasses: [FakeDiagnosticsServer.self])
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let body = request.httpBody ?? FakeDiagnosticsServer.read(request.httpBodyStream)
        let reply: Reply? = FakeDiagnosticsServer.lock.withLock {
            FakeDiagnosticsServer.seen.append(Seen(request: request, body: body))
            return FakeDiagnosticsServer.handler?(request, body)
        }
        guard let reply, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        if (300..<400).contains(reply.status), let location = reply.headers["Location"], let next = URL(string: location) {
            // What URLSession does with a 302 after a POST, and what Apps Script relies on.
            var follow = URLRequest(url: next)
            follow.httpMethod = "GET"
            client?.urlProtocol(self, wasRedirectedTo: follow, redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            guard n > 0 else { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

/// Time that moves only when a test says so. The upload loop's sleeps wait here until then.
final class ManualClock: DiagnosticsClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var sleepers: [UUID: (deadline: Date, continuation: CheckedContinuation<Void, Error>)] = [:]
    private var requested: [TimeInterval] = []

    init(_ start: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
        current = start
    }

    var sleepsRequested: [TimeInterval] { lock.withLock { requested } }

    func now() -> Date { lock.withLock { current } }

    func sleep(seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    requested.append(seconds)
                    sleepers[id] = (current.addingTimeInterval(seconds), continuation)
                }
            }
        } onCancel: {
            let sleeper = lock.withLock { sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by seconds: TimeInterval) {
        let due: [CheckedContinuation<Void, Error>] = lock.withLock {
            current = current.addingTimeInterval(seconds)
            let ready = sleepers.filter { $0.value.deadline <= current }
            for id in ready.keys { sleepers[id] = nil }
            return ready.map(\.value.continuation)
        }
        for continuation in due { continuation.resume() }
    }
}

/// What a closure run on another thread gave back.
final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

enum DiagnosticsFixtures {
    static let endpoint = URL(string: "https://script.example.invalid/macros/s/test/exec")!
    static let app = DiagnosticsApp(version: "1.10.0", build: "123", channel: "release")

    static func environment(home: String = "/Users/tester") -> DiagnosticsEnvironment {
        DiagnosticsEnvironment(app: app, os: "macOS 26.6 (25G5023)", hardware: "MacBookPro18,3", locale: "en_GB", homePath: home)
    }

    static func gate(endpoint: URL? = DiagnosticsFixtures.endpoint, key: String = "ingest-key", release: Bool = true,
                     bundle: String? = "com.falconmail.app", enabled: Bool = true) -> DiagnosticsGate {
        DiagnosticsGate(endpoint: endpoint, key: key, isReleaseBuild: release, bundleIdentifier: bundle, userEnabled: enabled)
    }

    /// Runs `body` on a thread with the 512 KB stack a Dispatch queue's thread has, as the
    /// diagnostics queue's does, rather than the test runner's 8 MB main thread: code that goes a
    /// call deeper for each level of its input runs out of stack here.
    static func onQueueSizedStack<T>(_ body: @escaping () -> T) -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.value = body()
            done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        done.wait()
        return box.value!
    }

    static func temporaryDirectory(_ name: String = "diag") -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("falcon-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func event(_ signature: String = "IMAP.network@AccountSyncer.swift:loop", kind: DiagnosticsKind = .error,
                      at date: Date = Date(timeIntervalSince1970: 1_790_000_000), message: String = "connection closed",
                      context: JSONValue = .object([:]), account: String? = nil) -> DiagnosticsEvent {
        DiagnosticsEvent(kind: kind, signature: signature, title: "Checking for new mail failed: the connection dropped",
                         area: "IMAP", firstAt: date, message: message, context: context,
                         account: account.map { DiagnosticsAccount(provider: "google", kind: "workspace", host: "imap.gmail.com", ref: $0) })
    }

    static func record(_ event: DiagnosticsEvent, app: DiagnosticsApp = DiagnosticsFixtures.app) -> DiagnosticsRecord {
        DiagnosticsRecord(event: event, app: app, os: "macOS 26.6 (25G5023)")
    }

    static let okReply = FakeDiagnosticsServer.Reply.json(#"{"ok":true,"accepted":1,"duplicates":0}"#)

    static func uploadedEvents(_ body: Data) -> [[String: Any]] {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        return json?["events"] as? [[String: Any]] ?? []
    }
}

extension XCTestCase {
    /// Polls until `condition` holds, for work that happens on another thread.
    func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting", file: file, line: line)
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}
