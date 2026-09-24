import Foundation

public struct IMAPMessageEnvelope: Sendable {
    public var uid: UInt32
    public var flags: [String]
    public var size: Int
    public var header: Data
}

/// The connections whose turn the current task holds, so that the commands inside one unit of
/// work run without asking for the turn again.
enum IMAPTurn {
    @TaskLocal static var held: Set<UUID> = []
}

/// One IMAP connection. Every command holds the connection's turn from the moment it is sent
/// until its tagged reply has been read, and `withMailbox` holds it across a SELECT and the
/// commands that depend on it. An actor alone is not enough: it lets another caller in at every
/// `await`, and two conversations interleaved on one socket read each other's replies, or run
/// a MOVE in whichever mailbox the other one had just selected.
public actor IMAPClient {
    public let host: String
    public let port: UInt16
    public let tls: Bool
    /// Names the connection in the log: the account's own address, never anyone else's.
    public let label: String
    private var connection: StreamConnection?
    private var tagCounter = 0
    private var idleTag: String?
    private var idleContinued = false
    private var idleStopRequested = false
    private var idleDoneSent = false
    private let turn = AsyncMutex()
    private nonisolated let turnID = UUID()
    public private(set) var capabilities: [String] = []
    public private(set) var selectedMailbox: String?
    private var selectedStatus: IMAPMailboxStatus?

    public init(host: String, port: UInt16 = 993, tls: Bool = true, label: String? = nil) {
        self.host = host
        self.port = port
        self.tls = tls
        self.label = label ?? host
    }

    /// False once the connection has failed or been closed; a failed connection is never used again.
    public var isConnected: Bool { connection != nil }

    public func connect() async throws {
        try await locked {
            let c = StreamConnection(host: host, port: port, tls: tls)
            try await c.connect()
            connection = c
            let greeting = try await readResponse()
            if case .untaggedStatus(_, let code, _) = greeting, let code, code.uppercased().hasPrefix("CAPABILITY ") {
                capabilities = code.split(separator: " ").dropFirst().map(String.init)
            }
            if capabilities.isEmpty { try await refreshCapabilities() }
        }
    }

    public func hasCapability(_ name: String) -> Bool {
        capabilities.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func authenticateXOAuth2(user: String, accessToken: String) async throws {
        let raw = "user=\(user)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}"
        let b64 = Data(raw.utf8).base64EncodedString()
        try await locked {
            let tag = try await sendCommand("AUTHENTICATE XOAUTH2 \(b64)")
            while true {
                switch try await readResponse() {
                case .continuation(let payload):
                    // Gmail explains a refusal in a challenge and gives the tagged NO, with its
                    // response code, only after an empty reply.
                    let explanation = Data(base64Encoded: payload).map { $0.utf8Lossy } ?? payload
                    try await sendLine("")
                    _ = try await collect(tag: tag, command: "AUTHENTICATE", mailbox: nil, includeTagged: true)
                    throw IMAPServerError(status: .no, code: nil, text: explanation, command: "AUTHENTICATE")
                case .tagged(let t, let status, let code, let text) where t == tag:
                    guard status == .ok else { throw IMAPServerError(status: status, code: code, text: text, command: "AUTHENTICATE") }
                    try await refreshCapabilities()
                    return
                case .capability(let caps):
                    capabilities = caps
                default:
                    continue
                }
            }
        }
    }

    public func login(user: String, password: String) async throws {
        try await locked {
            if hasCapability("AUTH=PLAIN") {
                let raw = "\u{00}\(user)\u{00}\(password)"
                let tag = try await sendCommand("AUTHENTICATE PLAIN \(Data(raw.utf8).base64EncodedString())")
                loop: while true {
                    switch try await readResponse() {
                    case .continuation:
                        try await sendLine("")
                    case .tagged(let t, let status, let code, let text) where t == tag:
                        guard status == .ok else { throw IMAPServerError(status: status, code: code, text: text, command: "AUTHENTICATE") }
                        break loop
                    default:
                        continue
                    }
                }
            } else {
                _ = try await run("LOGIN \(quote(user)) \(quote(password))")
            }
            try await refreshCapabilities()
        }
    }

    private func refreshCapabilities() async throws {
        for r in try await run("CAPABILITY") { if case .capability(let list) = r { capabilities = list } }
    }

    /// Runs `work` as one unit on this connection: nothing else is sent until it returns. When
    /// the connection failed while `work` waited behind another caller, `IMAPNotSent` says
    /// that none of it went out.
    public func exclusively<T: Sendable>(_ work: @Sendable (IMAPClient) async throws -> T) async throws -> T {
        try await locked {
            guard connection != nil else { throw IMAPNotSent() }
            return try await work(self)
        }
    }

    /// Runs `work` with `mailbox` selected, as one unit from the SELECT to its last reply. When
    /// `uidValidity` is known and the server now reports another, nothing is run, since every
    /// UID `work` was given would name a different message.
    public func withMailbox<T: Sendable>(_ mailbox: String, uidValidity: UInt32?,
                                         _ work: @Sendable (IMAPClient) async throws -> T) async throws -> T {
        try await locked {
            let status: IMAPMailboxStatus
            if selectedMailbox == mailbox, let current = selectedStatus {
                status = current
            } else {
                status = try await select(mailbox)
            }
            if let expected = uidValidity, expected != 0, status.uidValidity != 0, status.uidValidity != expected {
                throw IMAPMailboxRenumbered(mailbox: mailbox, expected: expected, found: status.uidValidity)
            }
            return try await work(self)
        }
    }

    public func listFolders() async throws -> [IMAPFolderInfo] {
        let responses = try await run("LIST \"\" \"*\"")
        return responses.compactMap { if case .list(let f) = $0 { return f } else { return nil } }
    }

    public func select(_ mailbox: String) async throws -> IMAPMailboxStatus {
        try await locked {
            // A SELECT that fails leaves no mailbox selected, so forget the old one first.
            selectedMailbox = nil
            selectedStatus = nil
            var status = IMAPMailboxStatus()
            let responses = try await run("SELECT \(quote(mailbox))", mailbox: mailbox, collectTagged: true)
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
            selectedStatus = status
            return status
        }
    }

    public func status(_ mailbox: String) async throws -> [String: Int] {
        let responses = try await run("STATUS \(quote(mailbox)) (MESSAGES UNSEEN UIDNEXT UIDVALIDITY)", mailbox: mailbox)
        for r in responses { if case .status(_, let items) = r { return items } }
        return [:]
    }

    public func uidSearch(_ criteria: String) async throws -> [UInt32] {
        let responses = try await run("UID SEARCH \(criteria)", mailbox: selectedMailbox)
        var out: [UInt32] = []
        for r in responses { if case .search(let uids) = r { out.append(contentsOf: uids) } }
        return out.sorted()
    }

    public static let headerFields = "From To Cc Bcc Date Subject Message-ID In-Reply-To References Content-Type Reply-To"

    public func fetchEnvelopes(uids: [UInt32]) async throws -> [IMAPMessageEnvelope] {
        guard !uids.isEmpty else { return [] }
        let set = IMAPClient.sequenceSet(uids)
        let responses = try await run("UID FETCH \(set) (UID FLAGS RFC822.SIZE BODY.PEEK[HEADER.FIELDS (\(IMAPClient.headerFields))])",
                                      mailbox: selectedMailbox)
        var out: [IMAPMessageEnvelope] = []
        for r in responses {
            if case .fetch(let item) = r, let uid = item.uid {
                out.append(IMAPMessageEnvelope(uid: uid, flags: item.flags ?? [], size: item.size ?? 0, header: item.headerSection ?? Data()))
            }
        }
        return out
    }

    public func fetchMessageIDs(uidRange: String) async throws -> [String] {
        let responses = try await run("UID FETCH \(uidRange) (UID BODY.PEEK[HEADER.FIELDS (Message-ID)])", mailbox: selectedMailbox)
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
        let responses = try await run("UID FETCH \(uidRange) (UID FLAGS)", mailbox: selectedMailbox)
        var out: [(UInt32, [String])] = []
        for r in responses {
            if case .fetch(let item) = r, let uid = item.uid { out.append((uid, item.flags ?? [])) }
        }
        return out.map { (uid: $0.0, flags: $0.1) }
    }

    public func fetchMessage(uid: UInt32, peek: Bool = true) async throws -> Data {
        let section = peek ? "BODY.PEEK[]" : "BODY[]"
        let responses = try await run("UID FETCH \(uid) (UID \(section))", mailbox: selectedMailbox)
        for r in responses {
            if case .fetch(let item) = r, item.uid == uid, let body = item.body { return body }
        }
        throw IMAPMessageMissing(mailbox: selectedMailbox, uid: uid)
    }

    public func store(uids: [UInt32], add: Bool, flags: [String]) async throws {
        guard !uids.isEmpty, !flags.isEmpty else { return }
        let op = add ? "+FLAGS.SILENT" : "-FLAGS.SILENT"
        _ = try await run("UID STORE \(IMAPClient.sequenceSet(uids)) \(op) (\(flags.joined(separator: " ")))", mailbox: selectedMailbox)
    }

    public func move(uids: [UInt32], to mailbox: String) async throws {
        guard !uids.isEmpty else { return }
        let set = IMAPClient.sequenceSet(uids)
        try await locked {
            if hasCapability("MOVE") {
                _ = try await run("UID MOVE \(set) \(quote(mailbox))", mailbox: mailbox)
                return
            }
            // Without UIDPLUS the originals could not be removed while another message is
            // marked, so that is found out before copying: a copy made first would stay behind
            // in the destination, and another with every retry.
            if !hasCapability("UIDPLUS") { try await refuseIfOthersMarked(uids) }
            _ = try await run("UID COPY \(set) \(quote(mailbox))", mailbox: mailbox)
            try await expunge(uids: uids)
        }
    }

    public func copy(uids: [UInt32], to mailbox: String) async throws {
        guard !uids.isEmpty else { return }
        _ = try await run("UID COPY \(IMAPClient.sequenceSet(uids)) \(quote(mailbox))", mailbox: mailbox)
    }

    /// Deletes these messages from the selected mailbox for good, and nothing else. A plain
    /// EXPUNGE also purges every other message marked \Deleted, by another program or long ago,
    /// which in Gmail's Trash is gone for ever. Without UIDPLUS it is used only when no other
    /// message is marked; otherwise nothing is marked and `IMAPExpungeRefused` is thrown.
    public func expunge(uids: [UInt32]) async throws {
        guard !uids.isEmpty else { return }
        try await locked {
            let set = IMAPClient.sequenceSet(uids)
            if hasCapability("UIDPLUS") {
                try await store(uids: uids, add: true, flags: ["\\Deleted"])
                _ = try await run("UID EXPUNGE \(set)", mailbox: selectedMailbox)
                return
            }
            try await refuseIfOthersMarked(uids)
            try await store(uids: uids, add: true, flags: ["\\Deleted"])
            _ = try await run("EXPUNGE", mailbox: selectedMailbox)
        }
    }

    /// Throws `IMAPExpungeRefused` when a plain EXPUNGE would take messages besides these.
    private func refuseIfOthersMarked(_ uids: [UInt32]) async throws {
        let others = Set(try await uidSearch("DELETED")).subtracting(uids)
        guard others.isEmpty else { throw IMAPExpungeRefused(mailbox: selectedMailbox, others: others.sorted()) }
    }

    @discardableResult
    public func append(mailbox: String, message: Data, flags: [String], date: Date?) async throws -> UInt32? {
        var cmd = "APPEND \(quote(mailbox))"
        if !flags.isEmpty { cmd += " (\(flags.joined(separator: " ")))" }
        if let date { cmd += " \(quote(IMAPClient.internalDate(date)))" }
        return try await locked {
            let tag = try await sendCommand("\(cmd) {\(message.count)}")
            waiting: while true {
                switch try await readResponse() {
                case .continuation:
                    break waiting
                case .tagged(let t, let status, let code, let text) where t == tag:
                    throw IMAPServerError(status: status, code: code, text: text, command: "APPEND", mailbox: mailbox)
                default:
                    continue
                }
            }
            try await sendData(message)
            try await sendLine("")
            let reply = try await collect(tag: tag, command: "APPEND", mailbox: mailbox, includeTagged: true).last
            if case .tagged(_, _, let code?, _) = reply {
                let parts = code.split(separator: " ")
                if parts.count == 3, parts[0].uppercased() == "APPENDUID" { return UInt32(parts[2]) }
            }
            return nil
        }
    }

    public func createFolder(_ path: String) async throws {
        _ = try await run("CREATE \(quote(path))", mailbox: path)
    }

    public func noop() async throws {
        _ = try await run("NOOP")
    }

    /// Forgets any earlier call to `finishIdle`. One made from now on ends the next `idle` as
    /// soon as the server agrees to it, even if it comes before that IDLE is sent, so a caller
    /// that calls this, then checks whether it still wants to idle, then idles, misses no
    /// wake-up in between.
    public func prepareIdle() {
        idleStopRequested = false
    }

    /// Waits in IDLE until the selected mailbox changes, `finishIdle` is called or `maxWait`
    /// passes. True when the server reported a change, including one it sent before agreeing
    /// to idle.
    public func idle(maxWait: TimeInterval) async throws -> Bool {
        guard hasCapability("IDLE") else {
            try await Task.sleep(nanoseconds: UInt64(min(maxWait, 60) * 1_000_000_000))
            let responses = try await run("NOOP")
            return responses.contains { if case .exists = $0 { return true }; if case .expunge = $0 { return true }; return false }
        }
        return try await locked {
            let tag = nextTag()
            idleTag = tag
            idleContinued = false
            idleDoneSent = false
            defer {
                idleTag = nil
                idleStopRequested = false
            }
            try await sendLine("\(tag) IDLE")
            var changed = false
            waiting: while true {
                switch try await readResponse() {
                case .continuation:
                    break waiting
                case .exists, .expunge, .fetch, .recent:
                    // A server with news queued sends it ahead of "+ idling".
                    changed = true
                case .tagged(let t, let status, let code, let text) where t == tag:
                    guard status == .ok else { throw IMAPServerError(status: status, code: code, text: text, command: "IDLE") }
                    return changed
                default:
                    continue
                }
            }
            idleContinued = true
            if changed || idleStopRequested { try await sendDone() }
            let timer = Task.detached { [weak self] in
                try await Task.sleep(nanoseconds: UInt64(maxWait * 1_000_000_000))
                try await self?.finishIdle()
            }
            defer { timer.cancel() }
            while true {
                switch try await readResponse() {
                case .exists, .expunge, .fetch:
                    changed = true
                    try await finishIdle()
                case .tagged(let t, let status, let code, let text) where t == tag:
                    guard status == .ok else { throw IMAPServerError(status: status, code: code, text: text, command: "IDLE") }
                    return changed
                default:
                    continue
                }
            }
        }
    }

    /// Ends an IDLE in progress. DONE may only follow the server's "+", so a call that comes
    /// before it, or before the IDLE itself (see `prepareIdle`), is remembered and DONE is sent
    /// as soon as the "+" arrives.
    public func finishIdle() async throws {
        guard idleTag != nil, idleContinued else {
            idleStopRequested = true
            return
        }
        try await sendDone()
    }

    private func sendDone() async throws {
        guard !idleDoneSent else { return }
        idleDoneSent = true
        try await sendLine("DONE")
    }

    /// Says goodbye when the connection is free, and otherwise just closes it: a command stuck
    /// on a dead link must not keep FalconMail from quitting.
    public func logout() async {
        guard let c = connection else { return }
        if turn.tryAcquire() {
            _ = try? await sendCommand("LOGOUT")
            turn.release()
        }
        await c.close()
        if connection === c { forget() }
    }

    private func locked<T>(_ body: () async throws -> T) async throws -> T {
        if IMAPTurn.held.contains(turnID) { return try await body() }
        try await turn.acquire()
        defer { turn.release() }
        return try await IMAPTurn.$held.withValue(IMAPTurn.held.union([turnID])) { try await body() }
    }

    private func run(_ command: String, mailbox: String? = nil, collectTagged: Bool = false) async throws -> [IMAPResponse] {
        try await locked {
            let tag = try await sendCommand(command)
            return try await collect(tag: tag, command: IMAPClient.commandName(command), mailbox: mailbox, includeTagged: collectTagged)
        }
    }

    private func nextTag() -> String {
        tagCounter += 1
        return String(format: "F%04d", tagCounter)
    }

    private func sendCommand(_ command: String) async throws -> String {
        let tag = nextTag()
        try await sendLine("\(tag) \(command)")
        return tag
    }

    private func sendLine(_ line: String) async throws {
        try await sendData(Data((line + "\r\n").utf8))
    }

    private func sendData(_ data: Data) async throws {
        guard let connection else { throw FalconError.network("not connected") }
        do {
            try await connection.send(data)
        } catch {
            await abandon(connection)
            throw error
        }
    }

    private func collect(tag: String, command: String, mailbox: String?, includeTagged: Bool) async throws -> [IMAPResponse] {
        var out: [IMAPResponse] = []
        while true {
            let r = try await readResponse()
            if case .tagged(let t, let status, let code, let text) = r {
                guard t == tag else {
                    // Another command's reply: this connection is out of step and cannot be trusted.
                    if let connection { await abandon(connection) }
                    throw FalconError.protocolError("reply to \(t) while waiting for \(tag)")
                }
                guard status == .ok else {
                    throw IMAPServerError(status: status, code: code, text: text, command: command, mailbox: mailbox)
                }
                if includeTagged { out.append(r) }
                return out
            }
            out.append(r)
        }
    }

    /// The next response. A connection that fails or sends something unreadable is closed for
    /// good, as is one the server says BYE on, whether or not the server closes it too.
    private func readResponse() async throws -> IMAPResponse {
        guard let connection else { throw FalconError.network("not connected") }
        let response: IMAPResponse
        do {
            var parts: [IMAPRawPart] = []
            while true {
                let text = try await connection.readLine().utf8Lossy
                if let literalSize = IMAPClient.trailingLiteralSize(text) {
                    parts.append(.text(text))
                    parts.append(.literal(try await connection.read(exactly: literalSize)))
                    continue
                }
                parts.append(.text(text))
                break
            }
            response = try IMAPResponseParser.parse(parts)
        } catch {
            await abandon(connection)
            throw error
        }
        if case .untaggedStatus(.bye, let code, let text) = response {
            Log.info("imap", "\(label): BYE \(code.map { "[\($0)] " } ?? "")\(Log.redacted(text, keeping: label))")
            await abandon(connection)
            throw IMAPBye(code: code, text: text)
        }
        return response
    }

    private func abandon(_ c: StreamConnection) async {
        await c.close()
        if connection === c { forget() }
    }

    private func forget() {
        connection = nil
        selectedMailbox = nil
        selectedStatus = nil
    }

    /// The command's name without its arguments, which can hold a password or a token.
    static func commandName(_ command: String) -> String {
        let words = command.split(separator: " ", maxSplits: 2).map { $0.uppercased() }
        guard let first = words.first else { return "" }
        if first == "UID", words.count > 1 { return "UID " + words[1] }
        return first
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
