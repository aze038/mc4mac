import Foundation

/// Where uploads go: the Apps Script web app's `/exec` URL and its ingest key, both read from
/// the app's Info.plist.
public struct DiagnosticsEndpoint: Sendable, Equatable {
    public var url: URL
    public var key: String

    public init(url: URL, key: String) {
        self.url = url
        self.key = key
    }
}

public enum DiagnosticsUploadError: Error, Equatable {
    /// No network. Not the server's fault, so it does not lengthen the backoff.
    case offline
    case network(String)
    case http(Int)
    case refused(String)
    case badResponse
}

/// Sends batches exactly as docs/DIAGNOSTICS.md describes: a UTF-8 JSON body posted as
/// `text/plain`, Apps Script's redirect followed, and success only when the final answer is
/// `{"ok":true}`.
public struct DiagnosticsUploader: Sendable {
    public static let maxEvents = 200
    public static let maxBodyBytes = 256 * 1024

    public let endpoint: DiagnosticsEndpoint
    public let session: URLSession

    public init(endpoint: DiagnosticsEndpoint, session: URLSession) {
        self.endpoint = endpoint
        self.session = session
    }

    /// Keeps nothing: no cache, no cookies, no credentials, and gives up rather than waiting
    /// for a network, since the next attempt is already scheduled.
    public static func makeSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.waitsForConnectivity = false
        config.allowsConstrainedNetworkAccess = false
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        if let protocolClasses { config.protocolClasses = protocolClasses }
        return URLSession(configuration: config)
    }

    public struct Receipt: Equatable, Sendable {
        public var accepted: Int
        public var duplicates: Int
    }

    public func send(_ upload: DiagnosticsUpload) async throws -> Receipt {
        let body = try DiagnosticsJSON.encoder.encode(upload)
        var request = URLRequest(url: endpoint.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("text/plain;charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where [.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff].contains(error.code) {
            throw DiagnosticsUploadError.offline
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DiagnosticsUploadError.network((error as? URLError).map { "\($0.code.rawValue)" } ?? "\(type(of: error))")
        }
        guard let http = response as? HTTPURLResponse else { throw DiagnosticsUploadError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw DiagnosticsUploadError.http(http.statusCode) }
        guard let reply = JSONValue.parse(data), let ok = reply["ok"]?.boolValue else {
            throw DiagnosticsUploadError.badResponse
        }
        guard ok else { throw DiagnosticsUploadError.refused(reply["error"]?.stringValue ?? "no reason given") }
        return Receipt(accepted: Int(reply["accepted"]?.intValue ?? 0), duplicates: Int(reply["duplicates"]?.intValue ?? 0))
    }

    /// Records split into bodies of at most 200 events and 256 KB, one body per build and
    /// macOS version so each carries the ones its events happened under, oldest first.
    public static func batches(_ records: [DiagnosticsRecord],
                               envelope: (DiagnosticsApp, String, [DiagnosticsEvent]) -> DiagnosticsUpload) -> [DiagnosticsUpload] {
        var groups: [(app: DiagnosticsApp, os: String, events: [DiagnosticsEvent])] = []
        for record in records {
            if let i = groups.firstIndex(where: { $0.app == record.app && $0.os == record.os }) {
                groups[i].events.append(record.event)
            } else {
                groups.append((record.app, record.os, [record.event]))
            }
        }
        var out: [DiagnosticsUpload] = []
        for group in groups {
            let overhead = ((try? DiagnosticsJSON.encoder.encode(envelope(group.app, group.os, []))) ?? Data()).count
            var current: [DiagnosticsEvent] = []
            var size = overhead
            for event in group.events {
                let eventSize = ((try? DiagnosticsJSON.encoder.encode(event)) ?? Data()).count + 1
                if !current.isEmpty, current.count >= maxEvents || size + eventSize > maxBodyBytes {
                    out.append(envelope(group.app, group.os, current))
                    current = []
                    size = overhead
                }
                current.append(event)
                size += eventSize
            }
            if !current.isEmpty { out.append(envelope(group.app, group.os, current)) }
        }
        return out
    }
}

// MARK: - When to upload

/// Time as the diagnostics centre sees it, so tests can move it on by hand.
public protocol DiagnosticsClock: Sendable {
    func now() -> Date
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemDiagnosticsClock: DiagnosticsClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

/// A minute after launch, then hourly; within a minute of a crash or hang being found; and
/// after a failure, exponentially later with jitter, never more than six hours.
public struct DiagnosticsSchedule: Sendable, Equatable {
    public static let firstDelay: TimeInterval = 60
    public static let interval: TimeInterval = 60 * 60
    public static let urgentDelay: TimeInterval = 60
    public static let offlineRetry: TimeInterval = 10 * 60
    public static let baseBackoff: TimeInterval = 2 * 60
    public static let maxBackoff: TimeInterval = 6 * 60 * 60

    public private(set) var nextAttempt: Date
    public private(set) var failures = 0

    public init(launchedAt: Date) {
        nextAttempt = launchedAt.addingTimeInterval(DiagnosticsSchedule.firstDelay)
    }

    public mutating func succeeded(at now: Date) {
        failures = 0
        nextAttempt = now.addingTimeInterval(DiagnosticsSchedule.interval)
    }

    /// `jitter` is a random number in 0..<1.
    public mutating func failed(at now: Date, jitter: Double) {
        failures += 1
        nextAttempt = now.addingTimeInterval(DiagnosticsSchedule.backoff(failures: failures, jitter: jitter))
    }

    /// Being offline says nothing about the server, so the backoff stays where it was.
    public mutating func offline(at now: Date) {
        nextAttempt = now.addingTimeInterval(DiagnosticsSchedule.offlineRetry)
    }

    public mutating func urgent(at now: Date) {
        nextAttempt = min(nextAttempt, now.addingTimeInterval(DiagnosticsSchedule.urgentDelay))
    }

    public static func backoff(failures: Int, jitter: Double) -> TimeInterval {
        let exponent = Double(min(max(failures, 1) - 1, 16))
        let base = min(maxBackoff, baseBackoff * pow(2, exponent))
        return min(maxBackoff, base * (0.75 + 0.5 * min(max(jitter, 0), 1)))
    }
}
