import Foundation

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
        guard greeting.code == 220 else { throw FalconError.protocolError("SMTP greeting: \(greeting.text)") }
        let ehlo = try await command("EHLO falconmail.local")
        guard ehlo.code == 250 else { throw FalconError.protocolError("EHLO: \(ehlo.text)") }
    }

    public func authenticateXOAuth2(user: String, accessToken: String) async throws {
        let raw = "user=\(user)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}"
        let reply = try await command("AUTH XOAUTH2 \(Data(raw.utf8).base64EncodedString())")
        if reply.code == 334 {
            let detail = Data(base64Encoded: reply.text).map { $0.utf8Lossy } ?? reply.text
            _ = try await command("")
            throw FalconError.protocolError("SMTP authentication failed: \(detail)")
        }
        guard reply.code == 235 else { throw FalconError.protocolError("SMTP authentication failed: \(reply.text)") }
    }

    public func authenticatePlain(user: String, password: String) async throws {
        let raw = "\u{00}\(user)\u{00}\(password)"
        let reply = try await command("AUTH PLAIN \(Data(raw.utf8).base64EncodedString())")
        if reply.code == 235 { return }
        let login = try await command("AUTH LOGIN")
        guard login.code == 334 else { throw FalconError.protocolError("SMTP authentication failed: \(reply.text)") }
        let u = try await command(Data(user.utf8).base64EncodedString())
        guard u.code == 334 else { throw FalconError.protocolError("SMTP authentication failed: \(u.text)") }
        let p = try await command(Data(password.utf8).base64EncodedString())
        guard p.code == 235 else { throw FalconError.protocolError("SMTP authentication failed: \(p.text)") }
    }

    public func send(from: String, recipients: [String], message: Data) async throws {
        let mail = try await command("MAIL FROM:<\(from)>")
        guard mail.code == 250 else { throw FalconError.protocolError("MAIL FROM: \(mail.text)") }
        for r in recipients {
            let rcpt = try await command("RCPT TO:<\(r)>")
            guard rcpt.code == 250 || rcpt.code == 251 else { throw FalconError.protocolError("Recipient \(r) rejected: \(rcpt.text)") }
        }
        let data = try await command("DATA")
        guard data.code == 354 else { throw FalconError.protocolError("DATA: \(data.text)") }
        try await connection?.send(SMTPClient.dotStuffed(message))
        try await connection?.send(Data("\r\n.\r\n".utf8))
        let done = try await readReply()
        guard done.code == 250 else { throw FalconError.protocolError("Message rejected: \(done.text)") }
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
