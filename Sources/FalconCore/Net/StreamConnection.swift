import Foundation
import Network

/// Nothing came from the server within the time allowed, so the connection was given up rather
/// than waited on for ever, as a dead path or a server that stopped answering would have it.
public struct StreamStalled: Error, LocalizedError, Sendable, Equatable {
    public var seconds: TimeInterval

    public var errorDescription: String? { "The mail server stopped answering." }
}

public actor StreamConnection {
    public let host: String
    public let port: UInt16
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let tap: TrafficTap
    private var buffer = Data()
    private var isClosed = false
    /// When anything last came from the server, or a send last finished, and since when a send
    /// has been under way; see `quietFor`.
    private var lastActive = Date()
    private var sendingSince: Date?
    /// Ends the wait for data under way, when there is one, as `close` must: a connection closed
    /// from outside, because nobody wants to wait on it any more, fails whatever waits on it at
    /// once rather than whenever the network says so.
    private var abortReceive: (@Sendable () -> Void)?

    public init(host: String, port: UInt16, tls: Bool = true, tap: TrafficTap = .none) {
        self.host = host
        self.port = port
        self.tap = tap
        // Keepalive finds a path that died without a word, which otherwise leaves a connection
        // waiting in IDLE for a reply that can never come.
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60
        tcp.keepaliveInterval = 15
        let params: NWParameters
        if tls {
            let tlsOptions = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)
            params = NWParameters(tls: tlsOptions, tcp: tcp)
        } else {
            params = NWParameters(tls: nil, tcp: tcp)
        }
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
        queue = DispatchQueue(label: "falconmail.net.\(host)")
    }

    /// Opens the connection, giving up after `deadline` seconds, when one is given, rather than
    /// waiting as long as the network does for a path that may never come.
    public func connect(deadline: TimeInterval? = nil) async throws {
        let box = ResumeOnce()
        let connection = connection
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        box.run { cont.resume() }
                    case .failed(let err):
                        box.run { cont.resume(throwing: FalconError.network(err.localizedDescription)) }
                    case .cancelled:
                        box.run { cont.resume(throwing: FalconError.network("connection cancelled")) }
                    case .waiting(let err):
                        Log.info("net", "waiting: \(err.localizedDescription)")
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                if let deadline {
                    queue.asyncAfter(deadline: .now() + deadline) {
                        box.run {
                            connection.cancel()
                            cont.resume(throwing: StreamStalled(seconds: deadline))
                        }
                    }
                }
            }
        } catch {
            isClosed = true
            throw error
        }
    }

    public func send(_ data: Data) async throws {
        guard !isClosed else { throw FalconError.network("connection closed") }
        if sendingSince == nil { sendingSince = Date() }
        defer {
            sendingSince = nil
            lastActive = Date()
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: FalconError.network(error.localizedDescription)) } else { cont.resume() }
            })
        }
        tap.sent(data.count)
    }

    /// How long the connection has been quiet: nothing received and no send finished. A send
    /// under way counts as activity for up to `sendAllowance` seconds, so that a large message
    /// going up a slow line is not taken for a dead one; one taking longer, as a send into a
    /// path that died does, counts from when it began.
    public func quietFor(sendAllowance: TimeInterval = 120) -> TimeInterval {
        let now = Date()
        if let since = sendingSince {
            let sending = now.timeIntervalSince(since)
            return sending < sendAllowance ? 0 : sending
        }
        return now.timeIntervalSince(lastActive)
    }

    public func send(line: String) async throws {
        try await send(Data((line + "\r\n").utf8))
    }

    private struct Received: Sendable {
        var data: Data?
        var isComplete: Bool
        var error: NWError?
    }

    /// Waits for more data, at most `deadline` seconds of silence when one is given: a long reply
    /// that keeps arriving is never cut short, a path that has gone quiet is.
    private func fill(deadline: TimeInterval?) async throws {
        let box = ResumeOnce()
        let connection = connection
        let abort = ReceiveAbort()
        abortReceive = { abort.fire() }
        let result: Received
        do {
            result = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Received, Error>) in
                let timer = deadline.map { seconds in
                    Deadline(after: seconds, on: queue) {
                        box.run {
                            connection.cancel()
                            cont.resume(throwing: StreamStalled(seconds: seconds))
                        }
                    }
                }
                abort.arm {
                    timer?.cancel()
                    box.run { cont.resume(throwing: FalconError.network("connection closed")) }
                }
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
                    timer?.cancel()
                    box.run { cont.resume(returning: Received(data: data, isComplete: isComplete, error: error)) }
                }
            }
        } catch {
            abortReceive = nil
            isClosed = true
            throw error
        }
        abortReceive = nil
        if let error = result.error { isClosed = true; throw FalconError.network(error.localizedDescription) }
        if let data = result.data, !data.isEmpty {
            lastActive = Date()
            buffer.append(data)
            tap.received(data.count)
        }
        if result.isComplete {
            isClosed = true
            if result.data?.isEmpty ?? true { throw FalconError.network("connection closed by peer") }
        }
    }

    public func readLine(deadline: TimeInterval? = nil) async throws -> Data {
        while true {
            if let range = buffer.range(of: Data([0x0D, 0x0A])) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return line
            }
            if isClosed { throw FalconError.network("connection closed") }
            try await fill(deadline: deadline)
        }
    }

    public func read(exactly count: Int, deadline: TimeInterval? = nil) async throws -> Data {
        while buffer.count < count {
            if isClosed { throw FalconError.network("connection closed") }
            try await fill(deadline: deadline)
        }
        let out = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return out
    }

    public func close() {
        isClosed = true
        connection.cancel()
        let abort = abortReceive
        abortReceive = nil
        abort?()
    }
}

/// A timer that can be called off from any thread, as a reply arriving does.
private final class Deadline: @unchecked Sendable {
    private let work: DispatchWorkItem

    init(after seconds: TimeInterval, on queue: DispatchQueue, _ fire: @escaping @Sendable () -> Void) {
        work = DispatchWorkItem(block: fire)
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func cancel() {
        work.cancel()
    }
}

/// Ends a wait for data from outside, once the wait has begun, or at once if it begins after.
private final class ReceiveAbort: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?
    private var fired = false

    func arm(_ body: @escaping () -> Void) {
        lock.lock()
        if fired {
            lock.unlock()
            body()
            return
        }
        action = body
        lock.unlock()
    }

    func fire() {
        lock.lock()
        fired = true
        let body = action
        action = nil
        lock.unlock()
        body?()
    }
}

final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
