import Foundation

public struct IMAPMessageEnvelope: Sendable {
    public var uid: UInt32
    public var flags: [String]
    public var size: Int
    public var header: Data
}

public actor IMAPClient {
    public let host: String
    public let port: UInt16
    private var connection: StreamConnection?
    private var tagCounter = 0
    private var idleTag: String?
    private var idleDoneSent = false
    public private(set) var capabilities: [String] = []
    public private(set) var selectedMailbox: String?

    public init(host: String, port: UInt16 = 993) {
        self.host = host
        self.port = port
    }

    public var isConnected: Bool { connection != nil }

    public func connect() async throws {
        let c = StreamConnection(host: host, port: port, tls: true)
        try await c.connect()
        connection = c
        let greeting = try await readResponse()
        if case .untaggedStatus(let status, let code, _) = greeting {
            if status == .bye { throw FalconError.protocolError("server refused connection") }
            if let code, code.uppercased().hasPrefix("CAPABILITY ") {
                capabilities = code.split(separator: " ").dropFirst().map(String.init)
            }
        }
        if capabilities.isEmpty {
            let responses = try await run("CAPABILITY")
            for r in responses { if case .capability(let caps) = r { capabilities = caps } }
        }
    }

    public func authenticateXOAuth2(user: String, accessToken: String) async throws {
        let raw = "user=\(user)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}"
        let b64 = Data(raw.utf8).base64EncodedString()
        let tag = try await sendCommand("AUTHENTICATE XOAUTH2 \(b64)")
        while true {
            let r = try await readResponse()
            switch r {
            case .continuation(let payload):
                let decoded = Data(base64Encoded: payload).map { $0.utf8Lossy } ?? payload
                try await connection?.send(line: "")
                _ = try await waitTagged(tag)
                throw FalconError.notAuthenticatedWith(decoded)
            case .tagged(let t, let status, _, let text) where t == tag:
                guard status == .ok else { throw FalconError.notAuthenticatedWith(text) }
                let caps = try await run("CAPABILITY")
                for c in caps { if case .capability(let list) = c { capabilities = list } }
                return
            case .capability(let caps):
                capabilities = caps
            default:
                continue
            }
        }
    }

    public func login(user: String, password: String) async throws {
        if capabilities.contains(where: { $0.uppercased() == "AUTH=PLAIN" }) {
            let raw = "\u{00}\(user)\u{00}\(password)"
            let tag = try await sendCommand("AUTHENTICATE PLAIN \(Data(raw.utf8).base64EncodedString())")
            while true {
                let r = try await readResponse()
                if case .continuation = r { try await connection?.send(line: ""); continue }
                if case .tagged(let t, let status, _, let text) = r, t == tag {
                    guard status == .ok else { throw FalconError.notAuthenticatedWith(text) }
                    break
                }
            }
        } else {
            _ = try await run("LOGIN \(quote(user)) \(quote(password))")
        }
        let caps = try await run("CAPABILITY")
        for c in caps { if case .capability(let list) = c { capabilities = list } }
    }

    public func listFolders() async throws -> [IMAPFolderInfo] {
        let responses = try await run("LIST \"\" \"*\"")
        return responses.compactMap { if case .list(let f) = $0 { return f } else { return nil } }
    }

    public func select(_ mailbox: String) async throws -> IMAPMailboxStatus {
        var status = IMAPMailboxStatus()
        let responses = try await run("SELECT \(quote(mailbox))", collectTagged: true)
        for r in responses {
            switch r {
            case .exists(let n): status.exists = n
            case .recent(let n): status.recent = n
            case .flags(let f): status.flags = f
            case .untaggedStatus(_, let code?, _):
                let parts = code.split(separator: " ").map(String.init)
                guard let key = parts.first?.uppercased() else { continue }
                if key == "UIDVALIDITY", parts.count > 1 { status.uidValidity = UInt32(parts[1]) ?? 0 }
                if key == "UIDNEXT", parts.count > 1 { status.uidNext = UInt32(parts[1]) ?? 0 }
                if key == "UNSEEN", parts.count > 1 { status.unseen = Int(parts[1]) ?? 0 }
            case .tagged(_, _, let code?, _):
                status.readOnly = code.uppercased().hasPrefix("READ-ONLY")
            default: break
            }
        }
        selectedMailbox = mailbox
        return status
    }

    public func status(_ mailbox: String) async throws -> [String: Int] {
        let responses = try await run("STATUS \(quote(mailbox)) (MESSAGES UNSEEN UIDNEXT UIDVALIDITY)")
        for r in responses { if case .status(_, let items) = r { return items } }
        return [:]
    }

    public func uidSearch(_ criteria: String) async throws -> [UInt32] {
        let responses = try await run("UID SEARCH \(criteria)")
        var out: [UInt32] = []
        for r in responses { if case .search(let uids) = r { out.append(contentsOf: uids) } }
        return out.sorted()
    }

    public static let headerFields = "From To Cc Bcc Date Subject Message-ID In-Reply-To References Content-Type Reply-To"

    public func fetchEnvelopes(uids: [UInt32]) async throws -> [IMAPMessageEnvelope] {
        guard !uids.isEmpty else { return [] }
        let set = IMAPClient.sequenceSet(uids)
        let responses = try await run("UID FETCH \(set) (UID FLAGS RFC822.SIZE BODY.PEEK[HEADER.FIELDS (\(IMAPClient.headerFields))])")
        var out: [IMAPMessageEnvelope] = []
        for r in responses {
            if case .fetch(let item) = r, let uid = item.uid {
                out.append(IMAPMessageEnvelope(uid: uid, flags: item.flags ?? [], size: item.size ?? 0, header: item.headerSection ?? Data()))
            }
        }
        return out
    }

    public func fetchMessageIDs(uidRange: String) async throws -> [String] {
        let responses = try await run("UID FETCH \(uidRange) (UID BODY.PEEK[HEADER.FIELDS (Message-ID)])")
        var out: [String] = []
        for r in responses {
            if case .fetch(let item) = r, let header = item.headerSection {
                let id = AddressParser.messageIDs(MIMEHeaders.parse(header).first("Message-ID")).first ?? ""
                if !id.isEmpty { out.append(id) }
            }
        }
        return out
    }

    public func fetchFlags(uidRange: String) async throws -> [(uid: UInt32, flags: [String])] {
        let responses = try await run("UID FETCH \(uidRange) (UID FLAGS)")
        var out: [(UInt32, [String])] = []
        for r in responses {
            if case .fetch(let item) = r, let uid = item.uid { out.append((uid, item.flags ?? [])) }
        }
        return out.map { (uid: $0.0, flags: $0.1) }
    }

    public func fetchMessage(uid: UInt32, peek: Bool = true) async throws -> Data {
        let section = peek ? "BODY.PEEK[]" : "BODY[]"
        let responses = try await run("UID FETCH \(uid) (UID \(section))")
        for r in responses {
            if case .fetch(let item) = r, item.uid == uid, let body = item.body { return body }
        }
        throw FalconError.protocolError("message \(uid) not returned")
    }

    public func store(uids: [UInt32], add: Bool, flags: [String]) async throws {
        guard !uids.isEmpty, !flags.isEmpty else { return }
        let op = add ? "+FLAGS.SILENT" : "-FLAGS.SILENT"
        _ = try await run("UID STORE \(IMAPClient.sequenceSet(uids)) \(op) (\(flags.joined(separator: " ")))")
    }

    public func move(uids: [UInt32], to mailbox: String) async throws {
        guard !uids.isEmpty else { return }
        let set = IMAPClient.sequenceSet(uids)
        if capabilities.contains(where: { $0.uppercased() == "MOVE" }) {
            _ = try await run("UID MOVE \(set) \(quote(mailbox))")
        } else {
            _ = try await run("UID COPY \(set) \(quote(mailbox))")
            try await store(uids: uids, add: true, flags: ["\\Deleted"])
            _ = try await run("UID EXPUNGE \(set)")
        }
    }

    public func copy(uids: [UInt32], to mailbox: String) async throws {
        guard !uids.isEmpty else { return }
        _ = try await run("UID COPY \(IMAPClient.sequenceSet(uids)) \(quote(mailbox))")
    }

    public func expunge() async throws {
        _ = try await run("EXPUNGE")
    }

    public func append(mailbox: String, message: Data, flags: [String], date: Date?) async throws {
        var cmd = "APPEND \(quote(mailbox))"
        if !flags.isEmpty { cmd += " (\(flags.joined(separator: " ")))" }
        if let date { cmd += " \(quote(IMAPClient.internalDate(date)))" }
        let tag = try await sendCommand("\(cmd) {\(message.count)}")
        while true {
            let r = try await readResponse()
            if case .continuation = r { break }
            if case .tagged(let t, _, _, let text) = r, t == tag { throw FalconError.protocolError("APPEND rejected: \(text)") }
        }
        try await connection?.send(message)
        try await connection?.send(line: "")
        _ = try await waitTagged(tag)
    }

    public func createFolder(_ path: String) async throws {
        _ = try await run("CREATE \(quote(path))")
    }

    public func noop() async throws {
        _ = try await run("NOOP")
    }

    public func idle(maxWait: TimeInterval) async throws -> Bool {
        guard capabilities.contains(where: { $0.uppercased() == "IDLE" }) else {
            try await Task.sleep(nanoseconds: UInt64(min(maxWait, 60) * 1_000_000_000))
            let responses = try await run("NOOP")
            return responses.contains { if case .exists = $0 { return true }; if case .expunge = $0 { return true }; return false }
        }
        let tag = try await sendCommand("IDLE")
        idleTag = tag
        idleDoneSent = false
        let first = try await readResponse()
        guard case .continuation = first else {
            idleTag = nil
            if case .tagged(_, _, _, let text) = first { throw FalconError.protocolError("IDLE rejected: \(text)") }
            throw FalconError.protocolError("IDLE: unexpected response")
        }
        let timer = Task { [weak self] in
            try await Task.sleep(nanoseconds: UInt64(maxWait * 1_000_000_000))
            try await self?.finishIdle()
        }
        defer { timer.cancel() }
        var changed = false
        while true {
            let r = try await readResponse()
            switch r {
            case .exists, .expunge, .fetch:
                changed = true
                try await finishIdle()
            case .tagged(let t, _, _, _) where t == tag:
                idleTag = nil
                return changed
            default:
                continue
            }
        }
    }

    public func finishIdle() async throws {
        guard idleTag != nil, !idleDoneSent else { return }
        idleDoneSent = true
        try await connection?.send(line: "DONE")
    }

    public func logout() async {
        if let c = connection {
            _ = try? await sendCommand("LOGOUT")
            await c.close()
        }
        connection = nil
        selectedMailbox = nil
    }

    private func run(_ command: String, collectTagged: Bool = false) async throws -> [IMAPResponse] {
        let tag = try await sendCommand(command)
        return try await collect(tag: tag, includeTagged: collectTagged)
    }

    private func sendCommand(_ command: String) async throws -> String {
        guard let connection else { throw FalconError.network("not connected") }
        tagCounter += 1
        let tag = String(format: "F%04d", tagCounter)
        try await connection.send(line: "\(tag) \(command)")
        return tag
    }

    private func waitTagged(_ tag: String) async throws -> IMAPResponse {
        let all = try await collect(tag: tag, includeTagged: true)
        return all.last!
    }

    private func collect(tag: String, includeTagged: Bool) async throws -> [IMAPResponse] {
        var out: [IMAPResponse] = []
        while true {
            let r = try await readResponse()
            if case .tagged(let t, let status, _, let text) = r, t == tag {
                switch status {
                case .ok:
                    if includeTagged { out.append(r) }
                    return out
                case .no: throw FalconError.protocolError(text)
                case .bad: throw FalconError.protocolError("bad command: \(text)")
                default: throw FalconError.protocolError(text)
                }
            }
            if case .untaggedStatus(.bye, _, let text) = r {
                throw FalconError.network("server closed session: \(text)")
            }
            out.append(r)
        }
    }

    private func readResponse() async throws -> IMAPResponse {
        guard let connection else { throw FalconError.network("not connected") }
        var parts: [IMAPRawPart] = []
        while true {
            let line = try await connection.readLine()
            let text = line.utf8Lossy
            if let literalSize = IMAPClient.trailingLiteralSize(text) {
                parts.append(.text(text))
                let data = try await connection.read(exactly: literalSize)
                parts.append(.literal(data))
                continue
            }
            parts.append(.text(text))
            break
        }
        return try IMAPResponseParser.parse(parts)
    }

    static func trailingLiteralSize(_ line: String) -> Int? {
        guard line.hasSuffix("}"), let open = line.lastIndex(of: "{") else { return nil }
        var digits = line[line.index(after: open)..<line.index(before: line.endIndex)]
        if digits.hasSuffix("+") { digits = digits.dropLast() }
        return Int(digits)
    }

    private func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public static func sequenceSet(_ uids: [UInt32]) -> String {
        let sorted = Array(Set(uids)).sorted()
        var ranges: [String] = []
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count && sorted[j + 1] == sorted[j] + 1 { j += 1 }
            ranges.append(i == j ? "\(sorted[i])" : "\(sorted[i]):\(sorted[j])")
            i = j + 1
        }
        return ranges.joined(separator: ",")
    }

    static func internalDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "d-MMM-yyyy HH:mm:ss +0000"
        return f.string(from: date)
    }
}

extension FalconError {
    static func notAuthenticatedWith(_ detail: String) -> FalconError {
        .protocolError("authentication failed: \(detail)")
    }
}
