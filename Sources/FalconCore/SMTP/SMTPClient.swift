import Foundation

/// An SMTP reply that refused something, kept whole so the Outbox can tell a full mailbox of
/// sending allowance from a mistyped address without reading any sentence meant for a person.
public struct SMTPServerError: Error, LocalizedError, Sendable, Equatable {
    public enum Stage: String, Sendable { case greeting, hello, authentication, sender, recipient, data, message }

    public var stage: Stage
    public var code: Int
    public var text: String
    /// The address refused, for a refusal at RCPT.
    public var recipient: String?

    public init(stage: Stage, code: Int, text: String, recipient: String? = nil) {
        self.stage = stage
        self.code = code
        self.text = text
        self.recipient = recipient
    }

    /// The enhanced status code at the start of the text, such as `5.4.5`.
    public var enhancedCode: String? {
        guard let first = text.split(separator: " ").first else { return nil }
        let parts = first.split(separator: ".")
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        return String(first)
    }

    public var errorDescription: String? { "The mail server refused the message." }
}

public actor SMTPClient {
    public let host: String
    public let port: UInt16
    private var connection: StreamConnection?

    public init(host: String, port: UInt16 = 465) {
        self.host = host
        self.port = port
    }

    public func connect() async throws {
        let c = StreamConnection(host: host, port: port, tls: true)
        try await c.connect()
        connection = c
        let greeting = try await readReply()
        guard greeting.code == 220 else { throw SMTPServerError(stage: .greeting, code: greeting.code, text: greeting.text) }
        let ehlo = try await command("EHLO falconmail.local")
        guard ehlo.code == 250 else { throw SMTPServerError(stage: .hello, code: ehlo.code, text: ehlo.text) }
    }

    public func authenticateXOAuth2(user: String, accessToken: String) async throws {
        let raw = "user=\(user)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}"
        let reply = try await command("AUTH XOAUTH2 \(Data(raw.utf8).base64EncodedString())")
        if reply.code == 334 {
            let detail = Data(base64Encoded: reply.text).map { $0.utf8Lossy } ?? reply.text
            let refusal = try await command("")
            throw SMTPServerError(stage: .authentication, code: refusal.code, text: "\(refusal.text) \(detail)")
        }
        guard reply.code == 235 else { throw SMTPServerError(stage: .authentication, code: reply.code, text: reply.text) }
    }

    public func authenticatePlain(user: String, password: String) async throws {
        let raw = "\u{00}\(user)\u{00}\(password)"
        let reply = try await command("AUTH PLAIN \(Data(raw.utf8).base64EncodedString())")
        if reply.code == 235 { return }
        let login = try await command("AUTH LOGIN")
        guard login.code == 334 else { throw SMTPServerError(stage: .authentication, code: reply.code, text: reply.text) }
        let u = try await command(Data(user.utf8).base64EncodedString())
        guard u.code == 334 else { throw SMTPServerError(stage: .authentication, code: u.code, text: u.text) }
        let p = try await command(Data(password.utf8).base64EncodedString())
        guard p.code == 235 else { throw SMTPServerError(stage: .authentication, code: p.code, text: p.text) }
    }

    public func send(from: String, recipients: [String], message: Data) async throws {
        let mail = try await command("MAIL FROM:<\(from)>")
        guard mail.code == 250 else { throw SMTPServerError(stage: .sender, code: mail.code, text: mail.text) }
        for r in recipients {
            let rcpt = try await command("RCPT TO:<\(r)>")
            guard rcpt.code == 250 || rcpt.code == 251 else { throw SMTPServerError(stage: .recipient, code: rcpt.code, text: rcpt.text, recipient: r) }
        }
        let data = try await command("DATA")
        guard data.code == 354 else { throw SMTPServerError(stage: .data, code: data.code, text: data.text) }
        try await connection?.send(SMTPClient.dotStuffed(message))
        try await connection?.send(Data("\r\n.\r\n".utf8))
        let done = try await readReply()
        guard done.code == 250 else { throw SMTPServerError(stage: .message, code: done.code, text: done.text) }
    }

    public func quit() async {
        _ = try? await command("QUIT")
        await connection?.close()
        connection = nil
    }

    private func command(_ line: String) async throws -> (code: Int, text: String) {
        guard let connection else { throw FalconError.network("not connected") }
        try await connection.send(line: line)
        return try await readReply()
    }

    private func readReply() async throws -> (code: Int, text: String) {
        guard let connection else { throw FalconError.network("not connected") }
        var lines: [String] = []
        while true {
            let line = try await connection.readLine().utf8Lossy
            guard line.count >= 3 else { continue }
            lines.append(String(line.dropFirst(4)))
            if line.count == 3 || line[line.index(line.startIndex, offsetBy: 3)] == " " {
                let code = Int(line.prefix(3)) ?? 0
                return (code, lines.joined(separator: "\n"))
            }
        }
    }

    static func dotStuffed(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count + 64)
        var atLineStart = true
        for b in data {
            if atLineStart && b == 0x2E { out.append(0x2E) }
            out.append(b)
            atLineStart = b == 0x0A
        }
        return out
    }
}
