import Foundation
import Network

public actor StreamConnection {
    public let host: String
    public let port: UInt16
    private let connection: NWConnection
    private var buffer = Data()
    private var isClosed = false

    public init(host: String, port: UInt16, tls: Bool = true) {
        self.host = host
        self.port = port
        let params: NWParameters
        if tls {
            let tlsOptions = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)
            params = NWParameters(tls: tlsOptions)
        } else {
            params = .tcp
        }
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
    }

    public func connect() async throws {
        let box = ResumeOnce()
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
            connection.start(queue: DispatchQueue(label: "falconmail.net.\(host)"))
        }
    }

    public func send(_ data: Data) async throws {
        guard !isClosed else { throw FalconError.network("connection closed") }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: FalconError.network(error.localizedDescription)) } else { cont.resume() }
            })
        }
    }

    public func send(line: String) async throws {
        try await send(Data((line + "\r\n").utf8))
    }

    private func fill() async throws {
        let result: (Data?, Bool, NWError?) = await withCheckedContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
                cont.resume(returning: (data, isComplete, error))
            }
        }
        if let error = result.2 { isClosed = true; throw FalconError.network(error.localizedDescription) }
        if let data = result.0, !data.isEmpty { buffer.append(data) }
        if result.1 {
            isClosed = true
            if result.0?.isEmpty ?? true { throw FalconError.network("connection closed by peer") }
        }
    }

    public func readLine() async throws -> Data {
        while true {
            if let range = buffer.range(of: Data([0x0D, 0x0A])) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return line
            }
            if isClosed { throw FalconError.network("connection closed") }
            try await fill()
        }
    }

    public func read(exactly count: Int) async throws -> Data {
        while buffer.count < count {
            if isClosed { throw FalconError.network("connection closed") }
            try await fill()
        }
        let out = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return out
    }

    public func close() {
        isClosed = true
        connection.cancel()
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
