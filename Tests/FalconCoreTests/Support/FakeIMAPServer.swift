import Foundation
import Network
@testable import FalconCore

/// An IMAP server on loopback for the engine's tests, over plain TCP, ported from olm2cloud's and
/// grown to the commands FalconMail's engine sends. Each connection is served on a thread of its
/// own with blocking reads, one command at a time as a real server does, so a client that
/// interleaves two conversations on one connection gets exactly the muddle it would get from
/// Gmail. It waits `latency` before every answer, sends no faster than `bytesPerSecond`, counts
/// commands and bytes per session, and can be told to misbehave in the ways Gmail and the
/// network do: BYE (also during IDLE, and without closing), a tagged NO with a response code, a
/// refused sign-in, a stalled command, a black hole, a close after a silence, a connection cut
/// after a given command, a renumbered mailbox, a flag fetch or search that lists nothing, an
/// APPEND whose reply is lost, and news sent before "+ idling". Given the
/// capabilities, it answers CONDSTORE's CHANGEDSINCE and ESEARCH as Gmail does. It can also
/// leave mailboxes out of a LIST reply, or give an empty one, and delete a mailbox.
final class FakeIMAPServer: @unchecked Sendable {
    struct Message {
        var uid: UInt32
        var data: Data
        var flags: [String] = []
        var internalDate = Date()
        var modSeq: UInt64 = 1
    }

    struct Mailbox {
        var name: String
        var attributes: [String]
        var uidValidity: UInt32
        var uidNext: UInt32
        var messages: [Message]
        var highestModSeq: UInt64 = 1

        func index(of uid: UInt32) -> Int? { messages.firstIndex { $0.uid == uid } }

        /// Gives the message at `i` the next mod-sequence, as any change to it does.
        mutating func touch(_ i: Int) {
            highestModSeq += 1
            messages[i].modSeq = highestModSeq
        }
    }

    /// One command and the reply it got.
    struct Exchange {
        var line: String
        var at: Date
        var replyBytes: Int
    }

    struct SessionCounts {
        var commands = 0
        var bytesIn = 0
        var bytesOut = 0
        var signedIn = false
    }

    let latency: TimeInterval
    let bytesPerSecond: Double
    private(set) var port: UInt16 = 0
    private let queue = DispatchQueue(label: "fake-imap")
    private let lock = NSLock()
    private var listener: NWListener?
    private var sessions: [Session] = []
    private var mailboxes: [Mailbox] = []
    private var capabilities: [String]
    private var recorded: [String] = []
    private var live = 0
    private var peak = 0
    private var logins = 0
    private var counts: [Int: SessionCounts] = [:]
    private var lastSessionID = 0

    private var greetingBye: String?
    private var loginRefusal: (code: String?, text: String)?
    private var byeOnNextCommand: (text: String, close: Bool)?
    private var byeWhenIdling: (text: String, close: Bool)?
    private var refusals: [(verb: String, code: String?, text: String)] = []
    private var stalls: [(verb: String, seconds: TimeInterval)] = []
    private var holeOpen = false
    private var silenceLimit: TimeInterval?
    private var queuedForIdle: [(mailbox: String, message: Message)] = []
    private var cutAfter: (verb: String, remaining: Int)?
    private var cutEvery: String?
    private var searchesToEmpty = 0
    private var flagFetchesToEmpty = 0
    private var appendRepliesToLose = 0
    private var hooks: [(verb: String, action: @Sendable () -> Void)] = []
    private var listOmissions: [Set<String>?] = []
    private var exchangeLog: [Exchange] = []

    init(capabilities: [String] = ["IMAP4rev1", "AUTH=PLAIN", "IDLE", "MOVE", "UIDPLUS", "SPECIAL-USE"],
         latency: TimeInterval = 0.002, bytesPerSecond: Double = 50_000_000) {
        self.capabilities = capabilities
        self.latency = latency
        self.bytesPerSecond = bytesPerSecond
    }

    // MARK: The mailbox model

    func addMailbox(_ name: String, attributes: [String] = [], uidValidity: UInt32 = 1_700_000_000) {
        lock.withLock {
            mailboxes.append(Mailbox(name: name, attributes: attributes, uidValidity: uidValidity, uidNext: 1, messages: []))
        }
    }

    /// Stores a message as another program would, and returns its UID.
    @discardableResult
    func add(_ data: Data, to mailbox: String, flags: [String] = [], date: Date = Date()) -> UInt32 {
        lock.withLock { insert(data, into: mailbox, flags: flags, date: date) }
    }

    /// Adds `data` with the UID given, for tests that need the same UID in two mailboxes.
    func add(_ data: Data, to mailbox: String, uid: UInt32, flags: [String] = []) {
        lock.withLock {
            guard let m = mailboxes.firstIndex(where: { $0.name == mailbox }) else { return }
            mailboxes[m].messages.append(Message(uid: uid, data: data, flags: flags))
            mailboxes[m].messages.sort { $0.uid < $1.uid }
            mailboxes[m].uidNext = max(mailboxes[m].uidNext, uid + 1)
            if let i = mailboxes[m].index(of: uid) { mailboxes[m].touch(i) }
        }
    }

    /// Stores many messages at once, as an import through another program does, each made by
    /// `make` from its position, and returns their UIDs.
    @discardableResult
    func addMany(_ count: Int, to mailbox: String, date: Date = Date(), make: (Int) -> Data) -> [UInt32] {
        lock.withLock { (0..<count).map { insert(make($0), into: mailbox, flags: [], date: date) } }
    }

    private func insert(_ data: Data, into mailbox: String, flags: [String], date: Date) -> UInt32 {
        guard let m = mailboxes.firstIndex(where: { $0.name == mailbox }) else { return 0 }
        let uid = mailboxes[m].uidNext
        mailboxes[m].uidNext += 1
        mailboxes[m].messages.append(Message(uid: uid, data: data, flags: flags, internalDate: date))
        mailboxes[m].touch(mailboxes[m].messages.count - 1)
        return uid
    }

    func messages(in mailbox: String) -> [Message] {
        lock.withLock { mailboxes.first { $0.name == mailbox }?.messages ?? [] }
    }

    func uidValidity(of mailbox: String) -> UInt32 {
        lock.withLock { mailboxes.first { $0.name == mailbox }?.uidValidity ?? 0 }
    }

    /// Flags a message as another program would.
    func setFlags(_ flags: [String], uid: UInt32, in mailbox: String) {
        lock.withLock {
            guard let m = mailboxes.firstIndex(where: { $0.name == mailbox }), let i = mailboxes[m].index(of: uid) else { return }
            mailboxes[m].messages[i].flags = flags
            mailboxes[m].touch(i)
        }
    }

    /// Deletes a message as another program would, between the client's commands.
    func remove(uid: UInt32, from mailbox: String) {
        lock.withLock {
            guard let m = mailboxes.firstIndex(where: { $0.name == mailbox }) else { return }
            mailboxes[m].messages.removeAll { $0.uid == uid }
            mailboxes[m].highestModSeq += 1
        }
    }

    /// Deletes a mailbox and everything in it, as another program would.
    func removeMailbox(_ name: String) {
        lock.withLock { mailboxes.removeAll { $0.name == name } }
    }

    /// Gives the mailbox a new UIDVALIDITY and numbers its messages afresh, as a server does
    /// when a mailbox is rebuilt: every UID the client knows now means something else.
    func renumber(_ mailbox: String) {
        lock.withLock {
            guard let m = mailboxes.firstIndex(where: { $0.name == mailbox }) else { return }
            mailboxes[m].uidValidity += 1
            var uid: UInt32 = 1
            for i in mailboxes[m].messages.indices.reversed() {
                mailboxes[m].messages[i].uid = uid
                uid += 1
            }
            mailboxes[m].messages.sort { $0.uid < $1.uid }
            mailboxes[m].uidNext = uid
        }
    }

    // MARK: Faults

    /// The next connection is greeted with this BYE and closed.
    func greetWithBye(_ text: String) {
        lock.withLock { greetingBye = text }
    }

    /// Sign-ins are turned down with this code and text until `acceptLogins`.
    func refuseLogins(code: String? = "AUTHENTICATIONFAILED", text: String = "Invalid credentials (Failure)") {
        lock.withLock { loginRefusal = (code, text) }
    }

    func acceptLogins() {
        lock.withLock { loginRefusal = nil }
    }

    /// The next command on any connection is answered with this BYE instead.
    func byeOnNextCommand(_ text: String, close: Bool = true) {
        lock.withLock { byeOnNextCommand = (text, close) }
    }

    /// The next connection to start idling gets this BYE right after "+ idling".
    func byeWhenIdling(_ text: String, close: Bool = true) {
        lock.withLock { byeWhenIdling = (text, close) }
    }

    /// The next command whose name starts with `verb` gets a tagged NO.
    func refuseNext(_ verb: String, code: String?, text: String) {
        lock.withLock { refusals.append((verb.uppercased(), code, text)) }
    }

    /// The next command whose name starts with `verb` is answered only after `seconds`.
    func stallNext(_ verb: String, seconds: TimeInterval) {
        lock.withLock { stalls.append((verb.uppercased(), seconds)) }
    }

    /// Runs `action` once, just before the next command whose name starts with `verb` is
    /// answered, as another program changing the mailbox at that moment would: mail arriving
    /// between a pass's SELECT and its search, say.
    func beforeAnswering(_ verb: String, _ action: @escaping @Sendable () -> Void) {
        lock.withLock { hooks.append((verb.uppercased(), action)) }
    }

    /// From now on nothing is answered and nothing is closed, like a link that has gone dead;
    /// until `blackHole(false)`, when commands are answered again.
    func blackHole(_ on: Bool = true) {
        lock.withLock { holeOpen = on }
    }

    /// The next `count` searches find nothing, as a server that has lost track of a mailbox for
    /// a moment might say.
    func emptyNextSearches(_ count: Int) {
        lock.withLock { searchesToEmpty = count }
    }

    /// The next `times` LIST replies leave out these mailboxes, or every one when nil, as a
    /// server that has lost track of them for a moment answers.
    func leaveOutOfNextLists(_ names: [String]?, times: Int = 1) {
        lock.withLock { listOmissions += Array(repeating: names.map(Set.init), count: times) }
    }

    /// The next `count` fetches of flags alone list no message, as a server that has lost track
    /// of a mailbox for a moment might answer.
    func emptyNextFlagFetches(_ count: Int) {
        lock.withLock { flagFetchesToEmpty = count }
    }

    /// The next APPEND stores its message and the connection then closes without a reply, as
    /// one lost at that moment does: the client cannot know the message went in.
    func loseNextAppendReply() {
        lock.withLock { appendRepliesToLose += 1 }
    }

    /// The connection that sends the `count`th command whose name starts with `verb`, from now
    /// on, is closed once it has been answered, as a connection lost part of the way through
    /// a pass is.
    func cutAfter(_ verb: String, count: Int) {
        lock.withLock { cutAfter = (verb.uppercased(), count) }
    }

    /// Every connection that sends a command whose name starts with `verb` is closed once it
    /// has been answered, until this is called again with nil: a pass cut at the same point
    /// every time, as one whose connection some middlebox drops at the same reply.
    func cutEveryAfter(_ verb: String?) {
        lock.withLock { cutEvery = verb?.uppercased() }
    }

    /// A connection that hears nothing from its client for `seconds` is closed without a word,
    /// as something between FalconMail and Gmail does to a quiet IDLE.
    func closeAfterSilence(_ seconds: TimeInterval?) {
        lock.withLock { silenceLimit = seconds }
    }

    /// When a connection next sends IDLE, `data` arrives in `mailbox` and the EXISTS for it is
    /// sent before "+ idling", as a server with news already queued does.
    func deliverBeforeIdling(_ data: Data, to mailbox: String) {
        lock.withLock { queuedForIdle.append((mailbox, Message(uid: 0, data: data))) }
    }

    /// Stores a message and tells every connection idling on that mailbox.
    @discardableResult
    func deliver(_ data: Data, to mailbox: String) -> UInt32 {
        let (uid, listeners, count) = lock.withLock { () -> (UInt32, [Session], Int) in
            let uid = insert(data, into: mailbox, flags: [], date: Date())
            let count = mailboxes.first { $0.name == mailbox }?.messages.count ?? 0
            return (uid, sessions.filter { $0.isIdling(on: mailbox) }, count)
        }
        for s in listeners { s.push("* \(count) EXISTS\r\n") }
        return uid
    }

    /// Sends `line` to every connection in IDLE, closing them afterwards when `close`.
    func sendToIdling(_ line: String, close: Bool) {
        let idling = lock.withLock { sessions.filter { $0.isIdling } }
        for s in idling {
            s.push(line + "\r\n")
            if close { s.hangUp() }
        }
    }

    /// Closes every open connection without a word.
    func dropAllConnections() {
        for s in lock.withLock({ sessions }) { s.hangUp() }
    }

    // MARK: Counters

    var commands: [String] { lock.withLock { recorded } }
    var exchanges: [Exchange] { lock.withLock { exchangeLog } }
    var peakConnections: Int { lock.withLock { peak } }
    var openConnections: Int { lock.withLock { live } }
    var loginCount: Int { lock.withLock { logins } }
    var sessionCounts: [SessionCounts] { lock.withLock { counts.keys.sorted().compactMap { counts[$0] } } }
    var bytesOut: Int { lock.withLock { counts.values.reduce(0) { $0 + $1.bytesOut } } }
    var idlingCount: Int { lock.withLock { sessions.filter { $0.isIdling }.count } }

    func resetCounters() {
        lock.withLock {
            recorded = []
            exchangeLog = []
            peak = live
        }
    }

    // MARK: Running

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
            throw FalconError.network("the test server did not start")
        }
        self.listener = listener
        self.port = port
    }

    func stop() {
        listener?.cancel()
        for s in lock.withLock({ sessions }) { s.hangUp() }
    }

    /// A signed-in client of this server, over plain TCP.
    func client(label: String = "owner@example.com", traffic: TrafficTap = .none) async throws -> IMAPClient {
        let c = IMAPClient(host: "127.0.0.1", port: port, tls: false, label: label, traffic: traffic)
        try await c.connect()
        try await c.login(user: label, password: "not-a-password")
        return c
    }

    private func accept(_ connection: NWConnection) {
        let session = lock.withLock { () -> Session in
            lastSessionID += 1
            let s = Session(server: self, connection: connection, id: lastSessionID)
            sessions.append(s)
            counts[s.id] = SessionCounts()
            live += 1
            peak = max(peak, live)
            return s
        }
        connection.start(queue: DispatchQueue(label: "fake-imap.connection"))
        Thread { session.run() }.start()
    }

    fileprivate func ended(_ session: Session) {
        lock.withLock {
            live -= 1
            sessions.removeAll { $0 === session }
        }
    }

    fileprivate func count(_ session: Session, bytesIn: Int = 0, bytesOut: Int = 0, command: String? = nil) {
        lock.withLock {
            counts[session.id]?.bytesIn += bytesIn
            counts[session.id]?.bytesOut += bytesOut
            if let command {
                counts[session.id]?.commands += 1
                recorded.append(command)
            }
        }
    }

    fileprivate func with<T>(_ body: (FakeIMAPServer) -> T) -> T {
        lock.withLock { body(self) }
    }

    fileprivate var greetingCapabilities: String { lock.withLock { capabilities.joined(separator: " ") } }
    fileprivate var silence: TimeInterval? { lock.withLock { silenceLimit } }
    fileprivate var isBlackHole: Bool { lock.withLock { holeOpen } }

    fileprivate func takeGreetingBye() -> String? {
        lock.withLock { defer { greetingBye = nil }; return greetingBye }
    }

    fileprivate func takeBye() -> (text: String, close: Bool)? {
        lock.withLock { defer { byeOnNextCommand = nil }; return byeOnNextCommand }
    }

    fileprivate func takeIdleBye() -> (text: String, close: Bool)? {
        lock.withLock { defer { byeWhenIdling = nil }; return byeWhenIdling }
    }

    fileprivate func takeRefusal(for command: String) -> (code: String?, text: String)? {
        lock.withLock {
            guard let i = refusals.firstIndex(where: { command.hasPrefix($0.verb) }) else { return nil }
            let r = refusals.remove(at: i)
            return (r.code, r.text)
        }
    }

    fileprivate func noteExchange(_ line: String, at: Date, replyBytes: Int) {
        lock.withLock { exchangeLog.append(Exchange(line: line, at: at, replyBytes: replyBytes)) }
    }

    /// True when the connection that sent `command` is to be cut now it has been answered.
    fileprivate func cutsAfter(_ command: String) -> Bool {
        lock.withLock {
            if let every = cutEvery, command.hasPrefix(every) { return true }
            guard let rule = cutAfter, command.hasPrefix(rule.verb) else { return false }
            if rule.remaining <= 1 {
                cutAfter = nil
                return true
            }
            cutAfter = (rule.verb, rule.remaining - 1)
            return false
        }
    }

    fileprivate func takeEmptyFlagFetch() -> Bool {
        lock.withLock {
            guard flagFetchesToEmpty > 0 else { return false }
            flagFetchesToEmpty -= 1
            return true
        }
    }

    fileprivate func takeLostAppendReply() -> Bool {
        lock.withLock {
            guard appendRepliesToLose > 0 else { return false }
            appendRepliesToLose -= 1
            return true
        }
    }

    fileprivate func takeEmptySearch() -> Bool {
        lock.withLock {
            guard searchesToEmpty > 0 else { return false }
            searchesToEmpty -= 1
            return true
        }
    }

    fileprivate var offersCondstore: Bool { lock.withLock { capabilities.contains { $0.uppercased() == "CONDSTORE" } } }
    fileprivate var offersESearch: Bool { lock.withLock { capabilities.contains { $0.uppercased() == "ESEARCH" } } }

    /// Which mailboxes the LIST being answered leaves out: none, some, or all when nil.
    fileprivate func takeListOmission() -> Set<String>?? {
        lock.withLock { listOmissions.isEmpty ? .none : .some(listOmissions.removeFirst()) }
    }

    fileprivate func takeHook(for command: String) -> (@Sendable () -> Void)? {
        lock.withLock {
            guard let i = hooks.firstIndex(where: { command.hasPrefix($0.verb) }) else { return nil }
            return hooks.remove(at: i).action
        }
    }

    fileprivate func takeStall(for command: String) -> TimeInterval? {
        lock.withLock {
            guard let i = stalls.firstIndex(where: { command.hasPrefix($0.verb) }) else { return nil }
            return stalls.remove(at: i).seconds
        }
    }

    fileprivate func signIn(_ session: Session) -> (code: String?, text: String)? {
        lock.withLock {
            if let loginRefusal { return loginRefusal }
            logins += 1
            counts[session.id]?.signedIn = true
            return nil
        }
    }

    fileprivate func takeQueuedForIdle(_ mailbox: String) -> [Message] {
        lock.withLock {
            let mine = queuedForIdle.filter { $0.mailbox == mailbox }.map(\.message)
            queuedForIdle.removeAll { $0.mailbox == mailbox }
            return mine
        }
    }

    // Mailbox access for sessions, always under the lock.
    fileprivate func mailboxIndex(_ name: String) -> Int? { mailboxes.firstIndex { $0.name == name } }
    fileprivate func mailbox(at i: Int) -> Mailbox { mailboxes[i] }
    fileprivate func setMailbox(_ box: Mailbox, at i: Int) { mailboxes[i] = box }
    fileprivate var allMailboxes: [Mailbox] { mailboxes }
    fileprivate func createMailbox(_ name: String) -> Bool {
        guard mailboxIndex(name) == nil else { return false }
        mailboxes.append(Mailbox(name: name, attributes: [], uidValidity: 1_800_000_000, uidNext: 1, messages: []))
        return true
    }
    fileprivate func appendMessage(_ data: Data, flags: [String], date: Date, to name: String) -> (UInt32, UInt32)? {
        guard let i = mailboxIndex(name) else { return nil }
        let uid = insert(data, into: name, flags: flags, date: date)
        return (mailboxes[i].uidValidity, uid)
    }
    fileprivate func insertQueued(_ data: Data, into name: String) {
        _ = insert(data, into: name, flags: [], date: Date())
    }
}

/// One client's conversation, run on a thread of its own with blocking reads and writes.
private final class Session: @unchecked Sendable {
    let id: Int
    private let server: FakeIMAPServer
    private let connection: NWConnection
    private var buffer = Data()
    private var nextFree = Date()
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var selected: String?
    private var idlingOn: String?
    private var closed = false
    private var sent = 0

    init(server: FakeIMAPServer, connection: NWConnection, id: Int) {
        self.server = server
        self.connection = connection
        self.id = id
    }

    var isIdling: Bool { stateLock.withLock { idlingOn != nil } }
    func isIdling(on mailbox: String) -> Bool { stateLock.withLock { idlingOn == mailbox } }

    func push(_ text: String) { _ = write(text) }

    func hangUp() {
        stateLock.withLock { closed = true }
        connection.cancel()
    }

    func run() {
        defer {
            hangUp()
            server.ended(self)
        }
        Thread.sleep(forTimeInterval: server.latency)
        if let bye = server.takeGreetingBye() {
            _ = write("* BYE \(bye)\r\n")
            return
        }
        guard write("* OK [CAPABILITY \(server.greetingCapabilities)] Fake IMAP ready\r\n") else { return }
        while let line = readLine() {
            if server.isBlackHole { continue }
            let words = line.split(separator: " ", maxSplits: 2).map(String.init)
            let command = Session.commandName(words)
            server.count(self, command: line)
            if let bye = server.takeBye() {
                _ = write("* BYE \(bye.text)\r\n")
                if bye.close { return }
                continue
            }
            if let seconds = server.takeStall(for: command) { Thread.sleep(forTimeInterval: seconds) }
            server.takeHook(for: command)?()
            Thread.sleep(forTimeInterval: server.latency)
            let started = Date()
            let before = sent
            let going = answer(line, words: words, command: command)
            server.noteExchange(line, at: started, replyBytes: sent - before)
            guard going, !server.cutsAfter(command) else { return }
        }
    }

    static func commandName(_ words: [String]) -> String {
        guard words.count >= 2 else { return words.first?.uppercased() ?? "" }
        let verb = words[1].uppercased()
        if verb == "UID", words.count > 2, let sub = words[2].split(separator: " ").first { return "UID " + sub.uppercased() }
        return verb
    }

    /// False when the conversation is over.
    private func answer(_ line: String, words: [String], command: String) -> Bool {
        guard words.count >= 2 else { return write("* BAD no tag\r\n") }
        let tag = words[0]
        let rest = words.count > 2 ? words[2] : ""
        if let refusal = server.takeRefusal(for: command) {
            return write("\(tag) NO \(refusal.code.map { "[\($0)] " } ?? "")\(refusal.text)\r\n")
        }
        switch command {
        case "CAPABILITY":
            return write("* CAPABILITY \(server.greetingCapabilities)\r\n\(tag) OK CAPABILITY completed\r\n")
        case "LOGIN", "AUTHENTICATE":
            if let refusal = server.signIn(self) {
                return write("\(tag) NO \(refusal.code.map { "[\($0)] " } ?? "")\(refusal.text)\r\n")
            }
            return write("\(tag) OK signed in\r\n")
        case "NOOP":
            return write("\(tag) OK NOOP completed\r\n")
        case "LOGOUT":
            _ = write("* BYE LOGOUT Requested\r\n\(tag) OK completed\r\n")
            return false
        case "LIST":
            var boxes = server.with { $0.allMailboxes }
            if let omitted = server.takeListOmission() {
                boxes = omitted.map { names in boxes.filter { !names.contains($0.name) } } ?? []
            }
            let lines = boxes.map { box -> String in
                "* LIST (\((["\\HasNoChildren"] + box.attributes).joined(separator: " "))) \"/\" \(Session.quoted(box.name))\r\n"
            }
            return write(lines.joined() + "\(tag) OK LIST completed\r\n")
        case "SELECT", "EXAMINE":
            return select(tag: tag, name: Session.firstArgument(rest))
        case "STATUS":
            return status(tag: tag, rest: rest)
        case "CREATE":
            let made = server.with { $0.createMailbox(Session.unquoted(rest)) }
            return write(made ? "\(tag) OK CREATE completed\r\n" : "\(tag) NO [ALREADYEXISTS] Duplicate folder name\r\n")
        case "UID SEARCH":
            return search(tag: tag, criteria: String(rest.dropFirst("SEARCH ".count)))
        case "UID FETCH":
            return fetch(tag: tag, String(rest.dropFirst("FETCH ".count)))
        case "UID STORE":
            return store(tag: tag, String(rest.dropFirst("STORE ".count)))
        case "UID MOVE", "UID COPY":
            return transfer(tag: tag, String(rest.dropFirst(5)), removing: command == "UID MOVE")
        case "UID EXPUNGE":
            guard server.greetingCapabilities.uppercased().contains("UIDPLUS") else { return write("\(tag) BAD UID EXPUNGE needs UIDPLUS\r\n") }
            return expunge(tag: tag, only: Session.uidSet(String(rest.dropFirst("EXPUNGE ".count))))
        case "EXPUNGE":
            return expunge(tag: tag, only: nil)
        case "APPEND":
            return append(tag: tag, rest: rest)
        case "IDLE":
            return idle(tag: tag)
        default:
            return write("\(tag) BAD not served here\r\n")
        }
    }

    private func currentBox() -> (Int, FakeIMAPServer.Mailbox)? {
        guard let selected = stateLock.withLock({ self.selected }) else { return nil }
        return server.with { s in s.mailboxIndex(selected).map { ($0, s.mailbox(at: $0)) } }
    }

    private func select(tag: String, name: String) -> Bool {
        stateLock.withLock { selected = nil }
        guard let box = server.with({ s in s.mailboxIndex(name).map { s.mailbox(at: $0) } }) else {
            return write("\(tag) NO [NONEXISTENT] Unknown Mailbox: \(name)\r\n")
        }
        stateLock.withLock { selected = name }
        let modSeq = server.offersCondstore ? "* OK [HIGHESTMODSEQ \(box.highestModSeq)] Highest\r\n" : ""
        return write("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n* \(box.messages.count) EXISTS\r\n* 0 RECENT\r\n"
                     + "* OK [UIDVALIDITY \(box.uidValidity)] UIDs valid\r\n* OK [UIDNEXT \(box.uidNext)] Predicted next UID\r\n"
                     + modSeq + "\(tag) OK [READ-WRITE] \(name) selected\r\n")
    }

    private func status(tag: String, rest: String) -> Bool {
        let name = Session.unquoted(String(rest.prefix { $0 != "(" }).trimmingCharacters(in: .whitespaces))
        guard let box = server.with({ s in s.mailboxIndex(name).map { s.mailbox(at: $0) } }) else {
            return write("\(tag) NO [NONEXISTENT] Unknown Mailbox\r\n")
        }
        let unseen = box.messages.filter { !$0.flags.contains("\\Seen") }.count
        return write("* STATUS \(Session.quoted(name)) (MESSAGES \(box.messages.count) UNSEEN \(unseen) UIDNEXT \(box.uidNext) UIDVALIDITY \(box.uidValidity))\r\n"
                     + "\(tag) OK STATUS completed\r\n")
    }

    private func search(tag: String, criteria text: String) -> Bool {
        guard let (_, box) = currentBox() else { return write("\(tag) BAD no mailbox selected\r\n") }
        var criteria = text
        var extended = false
        if criteria.uppercased().hasPrefix("RETURN ("), let close = criteria.firstIndex(of: ")") {
            guard server.offersESearch else { return write("\(tag) BAD RETURN needs ESEARCH\r\n") }
            extended = true
            criteria = String(criteria[criteria.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        var hits = server.takeEmptySearch() ? [] : box.messages
        var words = criteria.split(separator: " ").map(String.init)[...]
        while let word = words.popFirst() {
            switch word.uppercased() {
            case "ALL": continue
            case "DELETED": hits = hits.filter { $0.flags.contains("\\Deleted") }
            case "UNDELETED": hits = hits.filter { !$0.flags.contains("\\Deleted") }
            case "SEEN": hits = hits.filter { $0.flags.contains("\\Seen") }
            case "UNSEEN": hits = hits.filter { !$0.flags.contains("\\Seen") }
            case "UID":
                guard let set = words.popFirst() else { return write("\(tag) BAD UID needs a set\r\n") }
                let ranges = Session.uidSet(set, last: box.messages.last?.uid ?? 0)
                hits = hits.filter { m in ranges.contains { $0.contains(m.uid) } }
            case "SINCE", "BEFORE":
                guard let text = words.popFirst(), let day = Session.searchDate(text) else { return write("\(tag) BAD date\r\n") }
                hits = hits.filter { word.uppercased() == "SINCE" ? $0.internalDate >= day : $0.internalDate < day }
            default:
                return write("\(tag) BAD search key not served here\r\n")
            }
        }
        if extended {
            let all = hits.isEmpty ? "" : " ALL \(IMAPClient.sequenceSet(hits.map(\.uid)))"
            return write("* ESEARCH (TAG \"\(tag)\") UID\(all)\r\n\(tag) OK SEARCH completed\r\n")
        }
        return write("* SEARCH\(hits.map { " \($0.uid)" }.joined())\r\n\(tag) OK SEARCH completed\r\n")
    }

    private func fetch(tag: String, _ arguments: String) -> Bool {
        guard let (_, box) = currentBox() else { return write("\(tag) BAD no mailbox selected\r\n") }
        guard let space = arguments.firstIndex(of: " ") else { return write("\(tag) BAD\r\n") }
        let wanted = Session.uidSet(String(arguments[..<space]), last: box.messages.last?.uid ?? 0)
        let items = arguments[space...].uppercased()
        if items.hasPrefix(" (UID FLAGS)"), server.takeEmptyFlagFetch() { return write("\(tag) OK FETCH completed\r\n") }
        var changedSince: UInt64?
        if let modifier = items.range(of: "(CHANGEDSINCE ") {
            guard server.offersCondstore else { return write("\(tag) BAD CHANGEDSINCE needs CONDSTORE\r\n") }
            changedSince = UInt64(items[modifier.upperBound...].prefix { $0.isNumber })
        }
        var out = Data()
        var seen: [UInt32] = []
        for index in Session.indices(of: wanted, in: box.messages) {
            let message = box.messages[index]
            if let changedSince, message.modSeq <= changedSince { continue }
            var parts = ["UID \(message.uid)"]
            var literal: Data?
            var flags = message.flags
            if items.contains("BODY[]") && !items.contains("BODY.PEEK[]") && !flags.contains("\\Seen") {
                flags.append("\\Seen")
                seen.append(message.uid)
            }
            if items.contains("FLAGS") { parts.append("FLAGS (\(flags.joined(separator: " ")))") }
            if items.contains("RFC822.SIZE") { parts.append("RFC822.SIZE \(message.data.count)") }
            if items.contains("INTERNALDATE") { parts.append("INTERNALDATE \"\(Session.internalDate(message.internalDate))\"") }
            if changedSince != nil || items.contains("MODSEQ") { parts.append("MODSEQ (\(message.modSeq))") }
            if let fields = Session.headerFieldList(items) {
                let head = Session.headerFields(fields, in: message.data)
                parts.append("BODY[HEADER.FIELDS (\(fields.joined(separator: " ")))] {\(head.count)}")
                literal = head
            } else if items.contains("BODY.PEEK[]") || items.contains("BODY[]") {
                parts.append("BODY[] {\(message.data.count)}")
                literal = message.data
            }
            out += Data("* \(index + 1) FETCH (\(parts.joined(separator: " "))".utf8)
            if let literal { out += Data("\r\n".utf8) + literal }
            out += Data(")\r\n".utf8)
        }
        if !seen.isEmpty {
            mutateSelected { box in
                for uid in seen {
                    guard let i = box.index(of: uid) else { continue }
                    box.messages[i].flags.append("\\Seen")
                    box.touch(i)
                }
            }
        }
        out += Data("\(tag) OK FETCH completed\r\n".utf8)
        return write(out)
    }

    private func store(tag: String, _ arguments: String) -> Bool {
        let words = arguments.split(separator: " ", maxSplits: 2).map(String.init)
        guard words.count == 3, let (_, box) = currentBox() else { return write("\(tag) BAD\r\n") }
        let ranges = Session.uidSet(words[0], last: box.messages.last?.uid ?? 0)
        let op = words[1].uppercased()
        let flags = words[2].trimmingCharacters(in: CharacterSet(charactersIn: "()")).split(separator: " ").map(String.init)
        var echoed = ""
        mutateSelected { box in
            for i in box.messages.indices where ranges.contains(where: { $0.contains(box.messages[i].uid) }) {
                var current = box.messages[i].flags
                if op.hasPrefix("+") {
                    for f in flags where !current.contains(f) { current.append(f) }
                } else if op.hasPrefix("-") {
                    current.removeAll { flags.contains($0) }
                } else {
                    current = flags
                }
                if current != box.messages[i].flags { box.touch(i) }
                box.messages[i].flags = current
                if !op.hasSuffix(".SILENT") {
                    echoed += "* \(i + 1) FETCH (UID \(box.messages[i].uid) FLAGS (\(current.joined(separator: " "))))\r\n"
                }
            }
        }
        return write(echoed + "\(tag) OK STORE completed\r\n")
    }

    private func transfer(tag: String, _ arguments: String, removing: Bool) -> Bool {
        guard let space = arguments.firstIndex(of: " "), let (_, box) = currentBox() else { return write("\(tag) BAD\r\n") }
        let ranges = Session.uidSet(String(arguments[..<space]), last: box.messages.last?.uid ?? 0)
        let destination = Session.unquoted(String(arguments[arguments.index(after: space)...]))
        let result = server.with { s -> String? in
            guard let d = s.mailboxIndex(destination), let src = s.mailboxIndex(box.name) else { return nil }
            var source = s.mailbox(at: src)
            var target = s.mailbox(at: d)
            var expunged: [Int] = []
            var from: [UInt32] = []
            var to: [UInt32] = []
            for (i, m) in source.messages.enumerated() where ranges.contains(where: { $0.contains(m.uid) }) {
                target.messages.append(FakeIMAPServer.Message(uid: target.uidNext, data: m.data, flags: m.flags, internalDate: m.internalDate))
                target.touch(target.messages.count - 1)
                from.append(m.uid)
                to.append(target.uidNext)
                target.uidNext += 1
                expunged.append(i + 1)
            }
            if removing, !from.isEmpty {
                source.messages.removeAll { m in from.contains(m.uid) }
                source.highestModSeq += 1
            }
            s.setMailbox(target, at: d)
            s.setMailbox(source, at: src)
            var out = from.isEmpty ? "" : "* OK [COPYUID \(target.uidValidity) \(IMAPClient.sequenceSet(from)) \(IMAPClient.sequenceSet(to))] Done\r\n"
            if removing { for n in expunged.reversed() { out += "* \(n) EXPUNGE\r\n" } }
            return out
        }
        guard let result else { return write("\(tag) NO [TRYCREATE] No folder \(destination) (Failure)\r\n") }
        return write(result + "\(tag) OK \(removing ? "MOVE" : "COPY") completed\r\n")
    }

    private func expunge(tag: String, only: [ClosedRange<UInt32>]?) -> Bool {
        var out = ""
        mutateSelected { box in
            for i in box.messages.indices.reversed() {
                let m = box.messages[i]
                guard m.flags.contains("\\Deleted") else { continue }
                if let only, !only.contains(where: { $0.contains(m.uid) }) { continue }
                box.messages.remove(at: i)
                box.highestModSeq += 1
                out += "* \(i + 1) EXPUNGE\r\n"
            }
        }
        return write(out + "\(tag) OK EXPUNGE completed\r\n")
    }

    private func append(tag: String, rest: String) -> Bool {
        guard rest.hasSuffix("}"), let open = rest.lastIndex(of: "{"),
              let size = Int(rest[rest.index(after: open)..<rest.index(before: rest.endIndex)].filter(\.isNumber)) else {
            return write("\(tag) BAD APPEND needs a literal\r\n")
        }
        let name = Session.firstArgument(rest)
        var flags: [String] = []
        if let l = rest.firstIndex(of: "("), let r = rest.firstIndex(of: ")"), l < r {
            flags = rest[rest.index(after: l)..<r].split(separator: " ").map(String.init)
        }
        var date = Date()
        let afterName = rest.hasPrefix("\"") ? rest.dropFirst().drop { $0 != "\"" }.dropFirst() : rest.drop { $0 != " " }
        if let open = afterName.firstIndex(of: "\""), let close = afterName[afterName.index(after: open)...].firstIndex(of: "\""),
           let parsed = Session.parseInternalDate(String(afterName[afterName.index(after: open)..<close])) {
            date = parsed
        }
        guard write("+ Ready for literal data\r\n"), let data = read(exactly: size), readLine() != nil else { return false }
        guard let (validity, uid) = server.with({ $0.appendMessage(data, flags: flags, date: date, to: name) }) else {
            return write("\(tag) NO [TRYCREATE] No folder \(name) (Failure)\r\n")
        }
        if server.takeLostAppendReply() { return false }
        return write("\(tag) OK [APPENDUID \(validity) \(uid)] APPEND completed\r\n")
    }

    private func idle(tag: String) -> Bool {
        guard let selected = stateLock.withLock({ self.selected }) else { return write("\(tag) BAD no mailbox selected\r\n") }
        let queued = server.takeQueuedForIdle(selected)
        if !queued.isEmpty {
            for m in queued { server.with { $0.insertQueued(m.data, into: selected) } }
            let count = server.with { s in s.mailboxIndex(selected).map { s.mailbox(at: $0).messages.count } ?? 0 }
            guard write("* \(count) EXISTS\r\n") else { return false }
        }
        stateLock.withLock { idlingOn = selected }
        defer { stateLock.withLock { idlingOn = nil } }
        guard write("+ idling\r\n") else { return false }
        if let bye = server.takeIdleBye() {
            guard write("* BYE \(bye.text)\r\n") else { return false }
            if bye.close { return false }
        }
        while let line = readLine() {
            if server.isBlackHole { continue }
            server.count(self, command: line)
            if line.uppercased() == "DONE" {
                stateLock.withLock { idlingOn = nil }
                return write("\(tag) OK IDLE terminated\r\n")
            }
            return write("\(tag) BAD expected DONE\r\n")
        }
        return false
    }

    private func mutateSelected(_ change: (inout FakeIMAPServer.Mailbox) -> Void) {
        guard let selected = stateLock.withLock({ self.selected }) else { return }
        server.with { s in
            guard let i = s.mailboxIndex(selected) else { return }
            var box = s.mailbox(at: i)
            change(&box)
            s.setMailbox(box, at: i)
        }
    }

    private func readLine() -> String? {
        while true {
            if let end = buffer.range(of: Data([0x0D, 0x0A])) {
                let line = buffer[buffer.startIndex..<end.lowerBound]
                buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                return String(decoding: line, as: UTF8.self)
            }
            guard fill() else { return nil }
        }
    }

    private func read(exactly count: Int) -> Data? {
        while buffer.count < count { guard fill() else { return nil } }
        let out = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return out
    }

    private func fill() -> Bool {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var received: Data?
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
            received = data
            done.signal()
        }
        if let silence = server.silence {
            guard done.wait(timeout: .now() + silence) == .success else {
                hangUp()
                return false
            }
        } else {
            done.wait()
        }
        guard let received, !received.isEmpty else { return false }
        server.count(self, bytesIn: received.count)
        buffer += received
        return true
    }

    /// Sends in slices, each no sooner than the link would have finished the one before.
    private func write(_ text: String) -> Bool { write(Data(text.utf8)) }

    private func write(_ data: Data) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        if stateLock.withLock({ closed }) { return false }
        var offset = data.startIndex
        while offset < data.endIndex {
            let slice = data[offset..<min(offset + 16_384, data.endIndex)]
            let now = Date()
            if nextFree > now { Thread.sleep(until: nextFree) }
            nextFree = max(nextFree, now).addingTimeInterval(Double(slice.count) / server.bytesPerSecond)
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var delivered = false
            connection.send(content: Data(slice), completion: .contentProcessed { error in
                delivered = error == nil
                done.signal()
            })
            done.wait()
            guard delivered else { return false }
            sent += slice.count
            server.count(self, bytesOut: slice.count)
            offset = slice.endIndex
        }
        return true
    }

    /// The positions of the messages whose UIDs lie in `ranges`, in order, found by halving
    /// rather than by a walk through every message, which a mailbox of 25,000 would make slow.
    static func indices(of ranges: [ClosedRange<UInt32>], in messages: [FakeIMAPServer.Message]) -> [Int] {
        var out: [Int] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            var low = 0
            var high = messages.count
            while low < high {
                let mid = (low + high) / 2
                if messages[mid].uid < range.lowerBound { low = mid + 1 } else { high = mid }
            }
            while low < messages.count, messages[low].uid <= range.upperBound {
                if out.last.map({ $0 < low }) ?? true { out.append(low) }
                low += 1
            }
        }
        return out
    }

    static func uidSet(_ text: String, last: UInt32 = .max) -> [ClosedRange<UInt32>] {
        text.split(separator: ",").compactMap { piece in
            let ends = piece.split(separator: ":").map { $0 == "*" ? last : UInt32($0) ?? 0 }
            guard let low = ends.min(), let high = ends.max() else { return nil }
            return low...high
        }
    }

    static func headerFieldList(_ items: String) -> [String]? {
        guard let start = items.range(of: "HEADER.FIELDS (") else { return nil }
        let tail = items[start.upperBound...]
        guard let end = tail.firstIndex(of: ")") else { return nil }
        return tail[..<end].split(separator: " ").map(String.init)
    }

    /// The named header fields of a message as HEADER.FIELDS returns them: each whole field in
    /// CRLF lines, then the blank line.
    static func headerFields(_ names: [String], in message: Data) -> Data {
        let wanted = Set(names.map { $0.lowercased() })
        let head = String(decoding: MIMEParser.splitHeaderBody(message).0, as: UTF8.self)
        var out = ""
        var taking = false
        for line in head.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if line.first == " " || line.first == "\t" {
                if taking { out += line + "\r\n" }
                continue
            }
            let name = line.split(separator: ":", maxSplits: 1).first.map { $0.lowercased() } ?? ""
            taking = wanted.contains(name)
            if taking { out += line + "\r\n" }
        }
        return Data((out + "\r\n").utf8)
    }

    static func internalDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "dd-MMM-yyyy HH:mm:ss +0000"
        return f.string(from: date)
    }

    static func parseInternalDate(_ text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return f.date(from: text)
    }

    /// The first argument of a command, quoted or not, without what follows it.
    static func firstArgument(_ rest: String) -> String {
        guard rest.hasPrefix("\"") else { return String(rest.prefix { $0 != " " }) }
        var out = ""
        var escaped = false
        for ch in rest.dropFirst() {
            if escaped { out.append(ch); escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { break } else { out.append(ch) }
        }
        return out
    }

    static func searchDate(_ text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "d-MMM-yyyy"
        return f.date(from: text)
    }

    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func unquoted(_ s: String) -> String {
        guard s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 else { return s }
        var out = ""
        var escaped = false
        for ch in s.dropFirst().dropLast() {
            if escaped { out.append(ch); escaped = false } else if ch == "\\" { escaped = true } else { out.append(ch) }
        }
        return out
    }
}

extension FakeIMAPServer {
    /// A small RFC 5322 message whose body names it, so a test can tell which one it got.
    static func message(_ tag: String, from: String = "ana@example.com", to: String = "owner@example.com",
                        subject: String? = nil, date: Date = Date(timeIntervalSince1970: 1_790_000_000),
                        body: String? = nil) -> Data {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        let text = body ?? "This is message \(tag).\r\n" + String(repeating: "Padding for \(tag). ", count: 40)
        return Data("""
            From: \(from)\r
            To: \(to)\r
            Subject: \(subject ?? "Message \(tag)")\r
            Date: \(f.string(from: date))\r
            Message-ID: <\(tag)@example.com>\r
            Content-Type: text/plain; charset=utf-8\r
            \r
            \(text)\r

            """.utf8)
    }
}
