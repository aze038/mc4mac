import Foundation
import Network
@testable import FalconCore

/// An SMTP server on loopback for the tests, over plain TCP, that accepts any sign-in and writes
/// down every message handed to it as its envelope, MAIL FROM and each RCPT TO, and its DATA with
/// the dot-stuffing taken out, as Gmail's submission server receives them. It can be told to
/// refuse one recipient, or the end of the next message, as a server does.
final class FakeSMTPServer: @unchecked Sendable {
    struct Envelope {
        var mailFrom: String
        var rcptTo: [String]
        var data: Data
        /// The sign-in used: "XOAUTH2" or "PLAIN".
        var auth: String?

        var text: String { String(decoding: data, as: UTF8.self) }
        var headers: MIMEHeaders { MIMEHeaders.parse(data) }
    }

    private(set) var port: UInt16 = 0
    private let queue = DispatchQueue(label: "fake-smtp")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var delivered: [Envelope] = []
    private var lines: [String] = []
    private var refusedRecipients: [String: String] = [:]
    private var messageRefusals: [String] = []

    var envelopes: [Envelope] { lock.withLock { delivered } }
    /// Every command received, in order, DATA's content left out.
    var commands: [String] { lock.withLock { lines } }

    /// RCPT TO for `address` is answered with `reply`, such as "550 5.1.1 No such user".
    func refuseRecipient(_ address: String, reply: String) {
        lock.withLock { refusedRecipients[address.lowercased()] = reply }
    }

    /// The end of the next message is answered with `reply` instead of 250, and nothing is delivered.
    func refuseNextMessage(_ reply: String) {
        lock.withLock { messageRefusals.append(reply) }
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else {
            listener.cancel()
            throw FalconError.network("the test SMTP server did not start")
        }
        self.listener = listener
        self.port = port
    }

    func stop() {
        listener?.cancel()
        for c in lock.withLock({ connections }) { c.cancel() }
    }

    /// A client for this server, over plain TCP.
    func client() -> SMTPClient {
        SMTPClient(host: "127.0.0.1", port: port, tls: false)
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        let session = Session(server: self, connection: connection)
        connection.start(queue: queue)
        session.begin()
    }

    fileprivate func note(_ line: String) { lock.withLock { lines.append(line) } }

    fileprivate func refusal(for address: String) -> String? { lock.withLock { refusedRecipients[address.lowercased()] } }

    fileprivate func takeMessageRefusal() -> String? {
        lock.withLock { messageRefusals.isEmpty ? nil : messageRefusals.removeFirst() }
    }

    fileprivate func deliver(_ envelope: Envelope) { lock.withLock { delivered.append(envelope) } }

    /// One connection, answered a line at a time as its bytes arrive.
    private final class Session: @unchecked Sendable {
        private let server: FakeSMTPServer
        private let connection: NWConnection
        private var buffer = Data()
        private var inData = false
        private var mailFrom: String?
        private var rcptTo: [String] = []
        private var auth: String?

        init(server: FakeSMTPServer, connection: NWConnection) {
            self.server = server
            self.connection = connection
        }

        func begin() {
            reply("220 fake.smtp.test ESMTP ready")
            receive()
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, error in
                if let data { buffer.append(data); drain() }
                if done || error != nil {
                    connection.cancel()
                    return
                }
                receive()
            }
        }

        private func drain() {
            while true {
                if inData {
                    let end = Data("\r\n.\r\n".utf8)
                    let range: Range<Data.Index>?
                    if buffer.starts(with: Data(".\r\n".utf8)) {
                        range = buffer.startIndex..<buffer.startIndex + 3
                    } else {
                        range = buffer.range(of: end)
                    }
                    guard let range else { return }
                    var message = buffer[buffer.startIndex..<range.lowerBound]
                    if range.upperBound - range.lowerBound == 5 { message.append(contentsOf: Array("\r\n".utf8)) }
                    buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                    inData = false
                    finishMessage(Data(message))
                    continue
                }
                guard let newline = buffer.range(of: Data("\r\n".utf8)) else { return }
                let line = String(decoding: buffer[buffer.startIndex..<newline.lowerBound], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<newline.upperBound)
                handle(line)
            }
        }

        private func handle(_ line: String) {
            server.note(line)
            let upper = line.uppercased()
            if upper.hasPrefix("EHLO") || upper.hasPrefix("HELO") {
                reply("250-fake.smtp.test\r\n250-AUTH PLAIN LOGIN XOAUTH2\r\n250-8BITMIME\r\n250 SIZE 35882577")
            } else if upper.hasPrefix("AUTH XOAUTH2") {
                auth = "XOAUTH2"
                reply("235 2.7.0 Accepted")
            } else if upper.hasPrefix("AUTH PLAIN") {
                auth = "PLAIN"
                reply("235 2.7.0 Accepted")
            } else if upper.hasPrefix("MAIL FROM:") {
                mailFrom = FakeSMTPServer.path(in: line)
                rcptTo = []
                reply("250 2.1.0 OK")
            } else if upper.hasPrefix("RCPT TO:") {
                let address = FakeSMTPServer.path(in: line)
                if let refusal = server.refusal(for: address) {
                    reply(refusal)
                } else if mailFrom == nil {
                    reply("503 5.5.1 MAIL first")
                } else {
                    rcptTo.append(address)
                    reply("250 2.1.5 OK")
                }
            } else if upper == "DATA" {
                if rcptTo.isEmpty {
                    reply("554 5.5.1 No valid recipients")
                } else {
                    inData = true
                    reply("354 Go ahead")
                }
            } else if upper == "RSET" {
                mailFrom = nil
                rcptTo = []
                reply("250 2.0.0 OK")
            } else if upper == "QUIT" {
                reply("221 2.0.0 closing connection")
                connection.cancel()
            } else if upper == "NOOP" {
                reply("250 2.0.0 OK")
            } else {
                reply("502 5.5.1 Unrecognized command")
            }
        }

        private func finishMessage(_ stuffed: Data) {
            if let refusal = server.takeMessageRefusal() {
                reply(refusal)
            } else {
                server.deliver(Envelope(mailFrom: mailFrom ?? "", rcptTo: rcptTo, data: FakeSMTPServer.unstuffed(stuffed), auth: auth))
                reply("250 2.0.0 OK queued")
            }
            mailFrom = nil
            rcptTo = []
        }

        private func reply(_ text: String) {
            connection.send(content: Data((text + "\r\n").utf8), completion: .contentProcessed { _ in })
        }
    }

    /// The address between the angle brackets of MAIL FROM:<…> or RCPT TO:<…>.
    static func path(in line: String) -> String {
        guard let lt = line.firstIndex(of: "<"), let gt = line[lt...].firstIndex(of: ">") else {
            return String(line.drop { $0 != ":" }.dropFirst()).trimmed
        }
        return String(line[line.index(after: lt)..<gt])
    }

    /// DATA as sent, each line's leading dot doubled, back as the message was.
    static func unstuffed(_ data: Data) -> Data {
        var out = Data()
        var atLineStart = true
        var skipped = false
        for b in data {
            if atLineStart && b == 0x2E && !skipped {
                skipped = true
                continue
            }
            out.append(b)
            atLineStart = b == 0x0A
            skipped = false
        }
        return out
    }
}
