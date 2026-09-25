import Foundation
@testable import FalconCore

/// An in-memory Gmail mailbox that answers the Gmail API over HTTP the way Google does, closely
/// enough for everything FalconMail asks of it. `FakeGmailURLProtocol` serves it inside the test
/// process, so no test ever reaches Google.
///
/// It keeps Google's rules where FalconMail depends on them:
/// - lists newest first by the time Gmail received each message, paged by offset, so a message
///   arriving or going between pages repeats or skips one as it does on Gmail;
/// - a history id that moves on every change, and history in the order the changes were made,
///   with a floor below which a start point is refused with 404;
/// - label counts, threads, `labels.create` and `labels.delete`, every change call, uploads for
///   sending, importing, inserting and drafts, `sendAs`, and HTTP batches answered in any order;
/// - SENT and DRAFT refused to modify, at most 1,000 ids a bulk call, and a new message id at
///   every draft save.
///
/// It also stands for what the tests need of Google's limits: faults of every kind on any call,
/// a per-user budget shared with a second client (olm2cloud, or another Mac), a concurrency limit
/// counted by batch parts, daily download and upload allowances, delays per endpoint, and the
/// units, bytes and peak requests and parts in flight, per endpoint and per client.
///
/// Other work items extend it in their own files; `withState` gives them the state under its lock.
final class FakeGmailMailbox: @unchecked Sendable {
    // MARK: - What tests see

    struct Attachment {
        var filename: String
        var mimeType: String
        var data: Data
        var contentID: String?
    }

    /// A message as it stands, for tests to look at.
    struct Message {
        var id: String
        var threadID: String
        var labels: Set<String>
        var date: Date
        var from: String
        var to: String
        var cc: String
        var subject: String
        var messageID: String
        var text: String
        var html: String?
        var attachments: [Attachment]
        var historyID: UInt64
        /// The bytes as uploaded, for a message sent, imported, inserted or saved as a draft.
        var raw: Data?
        /// Every header, as `metadata` answers with them.
        var headers: [(name: String, value: String)]
    }

    enum Fault {
        case status(Int, reason: String?, retryAfter: String? = nil)
        /// Google's own refusal, word for word, for the limits it tells apart only in its message.
        case google(Int, reason: String, message: String, retryAfter: String? = nil)
        case timeout
        case offline
        /// Gmail does what was asked, and then the answer never arrives.
        case acceptedThenTimeout
        /// Gmail does what was asked, and then the connection drops.
        case acceptedThenDropped

        /// The per-user rate limit, as a 429.
        static func rateLimited(retryAfter: String? = "1") -> Fault {
            .google(429, reason: "rateLimitExceeded", message: "User-rate limit exceeded", retryAfter: retryAfter)
        }

        static let concurrentRequests = Fault.google(429, reason: "rateLimitExceeded", message: "Too many concurrent requests for user")

        /// The daily sending limit, with the retry time in the message as Gmail gives it.
        static func sendingLimit(until: Date) -> Fault {
            .google(429, reason: "rateLimitExceeded",
                    message: "User-rate limit exceeded.  Retry after \(ISO8601DateFormatter.fractional.string(from: until)) (Mail sending)")
        }

        /// A bandwidth allowance: the same words as the rate limit, with a retry time hours away.
        static func bandwidth(retryAfter seconds: Int = 7_200) -> Fault {
            .google(429, reason: "rateLimitExceeded", message: "User-rate limit exceeded", retryAfter: String(seconds))
        }

        static func forbidden(_ reason: String) -> Fault { .status(403, reason: reason) }
        static let serverError = Fault.status(500, reason: "backendError")
    }

    /// How a batch's answers are ordered. Google may answer in any order.
    enum AnswerOrder {
        case asked, reversed, shuffled
    }

    /// One call as the fake saw it, for delays and in-flight counts.
    struct Call {
        var method: GmailMethod?
        /// `format` of a read.
        var format: String?
        var isBatch: Bool
        var parts: Int
        var client: String
        /// A batch's parts by the call each stands for; a single call's is itself.
        var partsByMethod: [GmailMethod: Int] = [:]
    }

    /// One answered call's units, for sharing and window checks.
    struct Booking {
        var at: Date
        var client: String
        var method: GmailMethod
        var units: Int
    }

    /// The owner's own client; a second one is named when registered.
    static let falconMail = "falconmail"

    let email: String

    // MARK: - State

    /// A set of label bits: up to 256 labels, each one bit.
    struct LabelBits: Hashable {
        var words: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)

        static func == (a: LabelBits, b: LabelBits) -> Bool {
            a.words.0 == b.words.0 && a.words.1 == b.words.1 && a.words.2 == b.words.2 && a.words.3 == b.words.3
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(words.0)
            hasher.combine(words.1)
            hasher.combine(words.2)
            hasher.combine(words.3)
        }

        subscript(_ i: Int) -> Bool {
            get {
                let bit = UInt64(1) << UInt64(i & 63)
                switch i >> 6 {
                case 0: return words.0 & bit != 0
                case 1: return words.1 & bit != 0
                case 2: return words.2 & bit != 0
                default: return words.3 & bit != 0
                }
            }
            set {
                precondition(i < 256, "the fake keeps at most 256 labels")
                let bit = UInt64(1) << UInt64(i & 63)
                switch i >> 6 {
                case 0: words.0 = newValue ? words.0 | bit : words.0 & ~bit
                case 1: words.1 = newValue ? words.1 | bit : words.1 & ~bit
                case 2: words.2 = newValue ? words.2 | bit : words.2 & ~bit
                default: words.3 = newValue ? words.3 | bit : words.3 & ~bit
                }
            }
        }

        func isSuperset(of other: LabelBits) -> Bool {
            words.0 & other.words.0 == other.words.0 && words.1 & other.words.1 == other.words.1
                && words.2 & other.words.2 == other.words.2 && words.3 & other.words.3 == other.words.3
        }

        func intersects(_ other: LabelBits) -> Bool {
            words.0 & other.words.0 != 0 || words.1 & other.words.1 != 0 || words.2 & other.words.2 != 0 || words.3 & other.words.3 != 0
        }

        func union(_ o: LabelBits) -> LabelBits {
            LabelBits(words: (words.0 | o.words.0, words.1 | o.words.1, words.2 | o.words.2, words.3 | o.words.3))
        }

        func subtracting(_ o: LabelBits) -> LabelBits {
            LabelBits(words: (words.0 & ~o.words.0, words.1 & ~o.words.1, words.2 & ~o.words.2, words.3 & ~o.words.3))
        }

        var isEmpty: Bool { words.0 | words.1 | words.2 | words.3 == 0 }

        var indices: [Int] {
            var out: [Int] = []
            forEachIndex { out.append($0) }
            return out
        }

        /// Each set bit, lowest first, without building an array.
        func forEachIndex(_ body: (Int) -> Void) {
            for (w, word) in [words.0, words.1, words.2, words.3].enumerated() {
                var rest = word
                while rest != 0 {
                    let bit = rest.trailingZeroBitCount
                    body(w * 64 + bit)
                    rest &= rest - 1
                }
            }
        }
    }

    struct Content {
        var from: String
        var to: String
        var cc: String
        var subject: String
        var messageID: String
        var text: String
        var html: String?
        var attachments: [Attachment]
        /// Headers beyond those above, and all of them for an uploaded message.
        var headers: [(name: String, value: String)]
        var raw: Data?
    }

    struct Record {
        var id: UInt64
        var thread: UInt64
        var labels: LabelBits
        /// When Gmail received it, in milliseconds since 1970.
        var date: Int64
        var history: UInt64
        var size: Int
        var hasAttachment: Bool
        /// Its place in `contents`, or -1 for a fixture message whose text is made from its id.
        var content: Int32
        var alive: Bool
    }

    /// One history record: one change to one message.
    struct Change {
        enum Kind { case added, deleted, labels }
        var id: UInt64
        var kind: Kind
        var message: UInt64
        var thread: UInt64
        /// The message's labels after the change, or when it was deleted.
        var labels: LabelBits
        var added = LabelBits()
        var removed = LabelBits()
    }

    struct LabelInfo {
        var id: String
        var name: String
        var isSystem: Bool
        var listVisibility: String
        var alive = true
    }

    struct Counts {
        var total = 0
        var unread = 0
        var totalInSpamTrash = 0
        var unreadInSpamTrash = 0
    }

    struct State {
        var records: [Record] = []
        var slotByID: [UInt64: Int] = [:]
        /// Each thread's live slots.
        var threadMembers: [UInt64: [Int]] = [:]
        /// Slots by Message-ID without its angle brackets, for messages with text of their own.
        var slotByMessageID: [String: Int] = [:]
        /// Thread ids a test gave that are not Gmail's hex, such as "thread-9", kept as written.
        var threadNames: [UInt64: String] = [:]
        var threadByName: [String: UInt64] = [:]
        /// Slots, newest first by (date, id).
        var order: [Int] = []
        var contents: [Content] = []
        var labels: [LabelInfo] = []
        var labelIndex: [String: Int] = [:]
        var counts: [Counts] = []
        /// Messages in both Junk Email and Deleted Items, which Gmail hardly ever has.
        var inSpamAndTrash = 0
        var nextUserLabel = 1
        var log: [Change] = []
        var historyID: UInt64 = 1_000
        var historyFloor: UInt64 = 0
        var nextMessageID: UInt64 = 0x18a0_0000_0000_0000
        /// Moves on every change, so a page token knows whether it may resume where it stopped.
        var generation: UInt64 = 0
        var drafts: [String: UInt64] = [:]
        var draftOrder: [String] = []
        var nextDraft = 1
        var imported: Set<UInt64> = []
        var sendAs: [[String: Any]] = []
        var sentUploads: [Data] = []
        var attachmentGeneration = 0
        var threadStats: (generation: UInt64, threads: [Int], unreadThreads: [Int])?

        // Faults and behaviour.
        var faults: [(method: GmailMethod?, fault: Fault)] = []
        var standing: [GmailMethod: Fault] = [:]
        var batchFaults: [Fault] = []
        var acceptedTokens: Set<String>?
        var historyAddedCarriesLabels = true
        var replacesMessageIDOnSend = false
        var draftReplacesMessageID = false
        var snippetInMetadata = true
        var labelCountsIncludeSpamTrash = true
        var profileCountsSpamTrash = true
        var listReturnsChats = false
        var onlyCurrentAttachmentIDs = false
        var answerOrder = AnswerOrder.reversed
        var acceptedBatchPaths: Set<String> = ["/batch/gmail/v1"]
        var userUnitsPerMinute: Int?
        var concurrencyLimit: Int?
        var downloadAllowance: Int?
        var uploadAllowance: Int?
        var delays: [GmailMethod: TimeInterval] = [:]
        var fullDelay: TimeInterval?
        var batchDelay: TimeInterval = 0
        var delayScale: Double = 1

        // Metrics.
        var units: [GmailMethod: Int] = [:]
        var calls: [GmailMethod: Int] = [:]
        var attempts: [GmailMethod: Int] = [:]
        var bytesServed: [GmailMethod: Int] = [:]
        var bytesReceived: [GmailMethod: Int] = [:]
        var bookings: [Booking] = []
        var traffic: [(at: Date, down: Int, up: Int)] = []
        var queries: [String] = []
        var rawQueries: [String] = []
        var inFlightRequests = 0
        var inFlightParts = 0
        var inFlightByMethod: [GmailMethod: Int] = [:]
        var peakRequests = 0
        var peakParts = 0
        var peakByMethod: [GmailMethod: Int] = [:]
        var inFlightPartsByMethod: [GmailMethod: Int] = [:]
        var peakPartsByMethod: [GmailMethod: Int] = [:]
        var batchSizes: [Int] = []
    }

    private let lock = NSLock()
    private var state = State()
    private let clock: @Sendable () -> Date
    private var random = SplitMix64(seed: 0x5eed)

    static let systemLabels = ["INBOX", "SENT", "DRAFT", "SPAM", "TRASH", "UNREAD", "STARRED", "IMPORTANT",
                               "CATEGORY_PERSONAL", "CATEGORY_SOCIAL", "CATEGORY_PROMOTIONS", "CATEGORY_UPDATES",
                               "CATEGORY_FORUMS", "CHAT"]
    static let inbox = 0, sent = 1, draft = 2, spam = 3, trash = 4, unread = 5, starred = 6, important = 7
    static let personal = 8, social = 9, promotions = 10, updates = 11, forums = 12, chat = 13

    /// `now` is the clock Gmail stamps new mail and history with, and counts its per-user budget
    /// by; a test with a virtual clock passes its own.
    init(email: String = "owner@example.com", now: @escaping @Sendable () -> Date = { Date() }) {
        self.email = email
        clock = now
        for name in FakeGmailMailbox.systemLabels {
            state.labelIndex[name] = state.labels.count
            state.labels.append(LabelInfo(id: name, name: name, isSystem: true, listVisibility: "labelShow"))
            state.counts.append(Counts())
        }
        state.sendAs = [["sendAsEmail": email, "displayName": "", "isPrimary": true, "isDefault": true, "verificationStatus": "accepted"]]
    }

    /// The whole state under the lock, for other items' extensions of the fake.
    func withState<T>(_ body: (inout State) throws -> T) rethrows -> T {
        try lock.withLock { try body(&state) }
    }

    var now: Date { clock() }

    // MARK: - Setting it up and changing it as another device would

    @discardableResult
    func add(subject: String, from: String = "Ana <ana@example.com>", to: String = "owner@example.com", cc: String = "",
             text: String = "Hello", html: String? = nil, labels: Set<String> = ["INBOX"], date: Date? = nil,
             messageID: String? = nil, threadID: String? = nil, attachments: [Attachment] = [], size: Int? = nil) -> Message {
        lock.withLock {
            let id = newMessageID()
            let hex = String(id, radix: 16)
            let content = Content(from: from, to: to, cc: cc, subject: subject, messageID: messageID ?? "<\(hex)@mail.example.com>",
                                  text: text, html: html, attachments: attachments, headers: [], raw: nil)
            let thread = threadID.map(threadNumber) ?? id
            let bytes = size ?? (text.utf8.count + (html?.utf8.count ?? 0) + attachments.reduce(0) { $0 + $1.data.count })
            let slot = insert(id: id, thread: thread, labels: bits(labels), date: date ?? clock(), size: bytes,
                              hasAttachment: !attachments.isEmpty, content: content)
            return message(at: slot)
        }
    }

    /// Delivers a message now, as Gmail does for new mail: in the Inbox, unread.
    @discardableResult
    func deliver(subject: String, from: String = "Ana <ana@example.com>", labels: Set<String> = ["INBOX", "UNREAD", "CATEGORY_PERSONAL"],
                 date: Date? = nil, threadID: String? = nil, text: String = "Hello") -> Message {
        add(subject: subject, from: from, text: text, labels: labels, date: date, threadID: threadID)
    }

    /// A message imported by another app with a Date header years ahead: Gmail files it by that
    /// date, so it sits above everything else for good.
    @discardableResult
    func addImported(subject: String = "Imported from the future", date: Date = FakeGmailMailbox.year2037,
                     labels: Set<String> = ["INBOX"]) -> Message {
        let message = add(subject: subject, labels: labels, date: date)
        lock.withLock { state.imported.insert(UInt64(message.id, radix: 16)!) }
        return message
    }

    static let year2037 = Date(timeIntervalSince1970: 2_114_380_800)

    func setLabels(_ labels: Set<String>, on id: String) {
        lock.withLock {
            guard let raw = UInt64(id, radix: 16), let slot = state.slotByID[raw] else { return }
            let old = state.records[slot].labels
            let new = bits(labels)
            applyLabels(slot, adding: new.subtracting(old), removing: old.subtracting(new))
        }
    }

    /// Adds and removes labels as another device would, writing history for what really changed.
    func relabel(_ id: String, adding: Set<String> = [], removing: Set<String> = []) {
        lock.withLock {
            guard let raw = UInt64(id, radix: 16), let slot = state.slotByID[raw] else { return }
            applyLabels(slot, adding: bits(adding), removing: bits(removing))
        }
    }

    /// Deletes a message for good, as another device would.
    func delete(_ id: String) {
        lock.withLock {
            guard let raw = UInt64(id, radix: 16) else { return }
            remove(raw)
        }
    }

    @discardableResult
    func addUserLabel(named name: String, visibility: String = "labelShow") -> String {
        lock.withLock { newUserLabel(named: name, visibility: visibility) }
    }

    /// User labels by id. Setting it names labels; a label a message carries needs no entry.
    var userLabels: [String: String] {
        get { lock.withLock { Dictionary(uniqueKeysWithValues: state.labels.filter { !$0.isSystem && $0.alive }.map { ($0.id, $0.name) }) } }
        set {
            lock.withLock {
                for (id, name) in newValue {
                    let index = labelSlot(id)
                    state.labels[index].name = name
                    state.labels[index].alive = true
                }
            }
        }
    }

    /// Forgets the history so far, as Gmail does after a week or sometimes hours: any earlier start
    /// point is then refused with 404.
    func expireHistory() {
        lock.withLock { state.historyFloor = state.historyID }
    }

    /// Keeps history only from `id` on.
    func keepHistory(from id: UInt64) {
        lock.withLock { state.historyFloor = id }
    }

    /// Refuses the next `times` calls to `method` (any method when nil) with `fault`. A batch's
    /// parts each count as a call to their own method.
    func inject(_ fault: Fault, for method: GmailMethod? = nil, times: Int = 1) {
        lock.withLock { for _ in 0..<times { state.faults.append((method, fault)) } }
    }

    /// Refuses every call to `method` with `fault` until cleared with nil.
    func always(_ fault: Fault?, for method: GmailMethod) {
        lock.withLock { state.standing[method] = fault }
    }

    /// Refuses the next batch request as a whole, before any part is looked at.
    func injectBatch(_ fault: Fault, times: Int = 1) {
        lock.withLock { for _ in 0..<times { state.batchFaults.append(fault) } }
    }

    var acceptedTokens: Set<String>? {
        get { lock.withLock { state.acceptedTokens } }
        set { lock.withLock { state.acceptedTokens = newValue } }
    }

    // MARK: - Looking at it

    var units: [GmailMethod: Int] { lock.withLock { state.units } }
    var calls: [GmailMethod: Int] { lock.withLock { state.calls } }
    /// Every call that reached the fake, answered or refused.
    var attempts: [GmailMethod: Int] { lock.withLock { state.attempts } }
    var bytesServed: [GmailMethod: Int] { lock.withLock { state.bytesServed } }
    var bytesReceived: [GmailMethod: Int] { lock.withLock { state.bytesReceived } }
    var totalUnits: Int { units.values.reduce(0, +) }
    /// Decoded `q` values of every list call.
    var queries: [String] { lock.withLock { state.queries } }
    /// The percent-encoded query strings exactly as they arrived.
    var rawQueries: [String] { lock.withLock { state.rawQueries } }
    var historyID: UInt64 { lock.withLock { state.historyID } }
    var peakRequestsInFlight: Int { lock.withLock { state.peakRequests } }
    var peakPartsInFlight: Int { lock.withLock { state.peakParts } }
    var peakInFlightByMethod: [GmailMethod: Int] { lock.withLock { state.peakByMethod } }
    /// The most calls of each kind in flight at once, a batch's parts each counted as its call.
    var peakPartsInFlightByMethod: [GmailMethod: Int] { lock.withLock { state.peakPartsByMethod } }
    var requestsInFlight: Int { lock.withLock { state.inFlightRequests } }
    /// The number of parts of every batch served, in order.
    var batchSizes: [Int] { lock.withLock { state.batchSizes } }
    var bookings: [Booking] { lock.withLock { state.bookings } }
    /// Every upload `messages.send` took, as it arrived.
    var sentUploads: [Data] { lock.withLock { state.sentUploads } }
    var draftIDs: [String: String] { lock.withLock { state.drafts.mapValues { String($0, radix: 16) } } }
    var messageCount: Int { lock.withLock { state.slotByID.count } }

    func units(for client: String) -> Int {
        lock.withLock { state.bookings.filter { $0.client == client }.reduce(0) { $0 + $1.units } }
    }

    /// The most units booked in any 60 seconds, by one client or all of them together.
    func peakUnitsInAnyMinute(client: String? = nil) -> Int {
        let list = lock.withLock { state.bookings.filter { client == nil || $0.client == client } }
        var best = 0
        var total = 0
        var start = 0
        for booking in list {
            total += booking.units
            while booking.at.timeIntervalSince(list[start].at) >= 60 {
                total -= list[start].units
                start += 1
            }
            best = max(best, total)
        }
        return best
    }

    var messages: [Message] {
        lock.withLock { state.order.map { message(at: $0) } }
    }

    func message(_ id: String) -> Message? {
        lock.withLock { UInt64(id, radix: 16).flatMap { state.slotByID[$0] }.map { message(at: $0) } }
    }

    /// Whether another app imported the message, as `addImported` stands for.
    func wasImportedElsewhere(_ id: String) -> Bool {
        lock.withLock { UInt64(id, radix: 16).map { state.imported.contains($0) } ?? false }
    }

    // MARK: - Behaviour

    var historyAddedCarriesLabels: Bool {
        get { lock.withLock { state.historyAddedCarriesLabels } }
        set { lock.withLock { state.historyAddedCarriesLabels = newValue } }
    }

    /// Google does not promise that a sent message keeps FalconMail's Message-ID. When set, the
    /// fake gives it one of its own and keeps the original in X-Google-Original-Message-ID.
    var replacesMessageIDOnSend: Bool {
        get { lock.withLock { state.replacesMessageIDOnSend } }
        set { lock.withLock { state.replacesMessageIDOnSend = newValue } }
    }

    var draftReplacesMessageID: Bool {
        get { lock.withLock { state.draftReplacesMessageID } }
        set { lock.withLock { state.draftReplacesMessageID = newValue } }
    }

    var snippetInMetadata: Bool {
        get { lock.withLock { state.snippetInMetadata } }
        set { lock.withLock { state.snippetInMetadata = newValue } }
    }

    var labelCountsIncludeSpamTrash: Bool {
        get { lock.withLock { state.labelCountsIncludeSpamTrash } }
        set { lock.withLock { state.labelCountsIncludeSpamTrash = newValue } }
    }

    var profileCountsSpamTrash: Bool {
        get { lock.withLock { state.profileCountsSpamTrash } }
        set { lock.withLock { state.profileCountsSpamTrash = newValue } }
    }

    var listReturnsChats: Bool {
        get { lock.withLock { state.listReturnsChats } }
        set { lock.withLock { state.listReturnsChats = newValue } }
    }

    /// When set, only the attachment ids of the latest `full` answer work; `rotateAttachmentIDs`
    /// moves them on, as Gmail's may over time.
    var onlyCurrentAttachmentIDs: Bool {
        get { lock.withLock { state.onlyCurrentAttachmentIDs } }
        set { lock.withLock { state.onlyCurrentAttachmentIDs = newValue } }
    }

    func rotateAttachmentIDs() {
        lock.withLock { state.attachmentGeneration += 1 }
    }

    var answerOrder: AnswerOrder {
        get { lock.withLock { state.answerOrder } }
        set { lock.withLock { state.answerOrder = newValue } }
    }

    /// The batch addresses that answer; any other is 404.
    var acceptedBatchPaths: Set<String> {
        get { lock.withLock { state.acceptedBatchPaths } }
        set { lock.withLock { state.acceptedBatchPaths = newValue } }
    }

    /// Google's per-user budget, which every client of the user shares: 6,000 units a minute.
    /// Nil leaves it out.
    var userUnitsPerMinute: Int? {
        get { lock.withLock { state.userUnitsPerMinute } }
        set { lock.withLock { state.userUnitsPerMinute = newValue } }
    }

    /// The most calls in flight at once across all clients, counted by batch parts. Past it a
    /// call, or a batch's parts past it, get "Too many concurrent requests for user".
    var concurrencyLimit: Int? {
        get { lock.withLock { state.concurrencyLimit } }
        set { lock.withLock { state.concurrencyLimit = newValue } }
    }

    /// Bytes a rolling day that reads and uploads may move before Google's bandwidth 429s.
    var downloadAllowance: Int? {
        get { lock.withLock { state.downloadAllowance } }
        set { lock.withLock { state.downloadAllowance = newValue } }
    }

    var uploadAllowance: Int? {
        get { lock.withLock { state.uploadAllowance } }
        set { lock.withLock { state.uploadAllowance = newValue } }
    }

    /// Seconds each call takes before its answer arrives. A batch takes `batchDelay`, and a
    /// `format=full` read `fullDelay` when set.
    func setDelay(_ seconds: TimeInterval, for method: GmailMethod) {
        lock.withLock { state.delays[method] = seconds }
    }

    var fullDelay: TimeInterval? {
        get { lock.withLock { state.fullDelay } }
        set { lock.withLock { state.fullDelay = newValue } }
    }

    var batchDelay: TimeInterval {
        get { lock.withLock { state.batchDelay } }
        set { lock.withLock { state.batchDelay = newValue } }
    }

    /// Multiplies every delay, so a test can keep their proportions and still run quickly.
    var delayScale: Double {
        get { lock.withLock { state.delayScale } }
        set { lock.withLock { state.delayScale = newValue } }
    }

    /// The delays the design's acceptance targets are measured with: a list page 300 ms, a batch
    /// of 25 metadata reads 800 ms, a `full` read 400 ms and a history page 150 ms.
    func useAcceptanceDelays(scale: Double = 1) {
        lock.withLock {
            state.delays[.messagesList] = 0.3
            state.delays[.historyList] = 0.15
            state.delays[.messagesGet] = 0.1
            state.fullDelay = 0.4
            state.batchDelay = 0.8
            state.delayScale = scale
        }
    }

    var sendAsAddresses: [String] {
        get { lock.withLock { state.sendAs.compactMap { $0["sendAsEmail"] as? String } } }
        set {
            lock.withLock {
                state.sendAs = newValue.enumerated().map { i, address in
                    ["sendAsEmail": address, "displayName": "", "isPrimary": i == 0, "isDefault": i == 0, "verificationStatus": "accepted"]
                }
            }
        }
    }

    // MARK: - Serving

    /// A request that has arrived and not yet been answered.
    struct Arrival {
        var call: Call
        /// Parts past the concurrency limit, which are refused.
        var overLimit: Int
    }

    /// Serves a request at once, as if it took no time: arrives, is answered, and leaves.
    func handle(_ request: URLRequest, client: String = FakeGmailMailbox.falconMail) -> Result<(HTTPURLResponse, Data), URLError> {
        let arrival = arrive(request, client: client)
        defer { depart(arrival) }
        return respond(to: request, arrival: arrival)
    }

    /// Counts the request in flight, and decides whether it goes past the concurrency limit.
    func arrive(_ request: URLRequest, client: String) -> Arrival {
        let call = describe(request, client: client)
        return lock.withLock {
            let before = state.inFlightParts
            state.inFlightRequests += 1
            state.inFlightParts += call.parts
            state.peakRequests = max(state.peakRequests, state.inFlightRequests)
            state.peakParts = max(state.peakParts, state.inFlightParts)
            if let method = call.method {
                state.inFlightByMethod[method, default: 0] += 1
                state.peakByMethod[method] = max(state.peakByMethod[method] ?? 0, state.inFlightByMethod[method] ?? 0)
            }
            for (method, n) in call.partsByMethod {
                state.inFlightPartsByMethod[method, default: 0] += n
                state.peakPartsByMethod[method] = max(state.peakPartsByMethod[method] ?? 0, state.inFlightPartsByMethod[method] ?? 0)
            }
            var over = 0
            if let limit = state.concurrencyLimit { over = max(0, min(call.parts, before + call.parts - limit)) }
            return Arrival(call: call, overLimit: over)
        }
    }

    func depart(_ arrival: Arrival) {
        lock.withLock {
            state.inFlightRequests -= 1
            state.inFlightParts -= arrival.call.parts
            if let method = arrival.call.method { state.inFlightByMethod[method, default: 0] -= 1 }
            for (method, n) in arrival.call.partsByMethod { state.inFlightPartsByMethod[method, default: 0] -= n }
        }
    }

    /// How long the answer takes to arrive.
    func delay(for arrival: Arrival) -> TimeInterval {
        lock.withLock {
            let call = arrival.call
            let base: TimeInterval
            if call.isBatch {
                base = state.batchDelay
            } else if call.method == .messagesGet, call.format == "full", let full = state.fullDelay {
                base = full
            } else {
                base = call.method.flatMap { state.delays[$0] } ?? 0
            }
            return base * state.delayScale
        }
    }

    func respond(to request: URLRequest, arrival: Arrival) -> Result<(HTTPURLResponse, Data), URLError> {
        guard let url = request.url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(URLError(.badURL))
        }
        let body = FakeGmailMailbox.body(of: request)
        return lock.withLock { () -> Result<(HTTPURLResponse, Data), URLError> in
            if arrival.call.isBatch {
                return serveBatch(request, url: url, path: comps.path, body: body, arrival: arrival)
            }
            guard let method = arrival.call.method else {
                return .success(respond(url, 404, ["error": ["code": 404, "message": "Not Found", "status": "NOT_FOUND"]]))
            }
            let token = request.value(forHTTPHeaderField: "Authorization")?.removingPrefix("Bearer ") ?? ""
            let answer = serve(method, httpMethod: request.httpMethod ?? "GET", path: comps.path, query: comps.queryItems ?? [],
                               percentEncodedQuery: comps.percentEncodedQuery, body: body,
                               contentType: request.value(forHTTPHeaderField: "Content-Type"), token: token,
                               client: arrival.call.client, overLimit: arrival.overLimit > 0)
            switch answer {
            case .failure(let error): return .failure(error)
            case .success(let reply): return .success(respond(url, reply.status, reply.body, headers: reply.headers, data: reply.data))
            }
        }
    }

    /// What the request is, without serving it.
    private func describe(_ request: URLRequest, client: String) -> Call {
        let path = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.path } ?? ""
        let httpMethod = request.httpMethod ?? "GET"
        if path.hasPrefix("/batch") {
            let parts = FakeGmailMailbox.batchParts(FakeGmailMailbox.body(of: request), contentType: request.value(forHTTPHeaderField: "Content-Type"))
            var byMethod: [GmailMethod: Int] = [:]
            for part in parts {
                let fields = (part.request.components(separatedBy: "\n").first ?? "").split(separator: " ")
                guard fields.count >= 2, let comps = URLComponents(string: "https://batch.invalid" + fields[1]),
                      let route = FakeGmailMailbox.route(path: comps.path, httpMethod: String(fields[0])) else { continue }
                byMethod[route.method, default: 0] += 1
            }
            return Call(method: nil, format: nil, isBatch: true, parts: max(1, parts.count), client: client, partsByMethod: byMethod)
        }
        let format = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "format" }?.value }
        let method = FakeGmailMailbox.route(path: path, httpMethod: httpMethod)?.method
        return Call(method: method, format: format, isBatch: false, parts: 1, client: client,
                    partsByMethod: method.map { [$0: 1] } ?? [:])
    }

    struct Route {
        var method: GmailMethod
        var segments: [String]
        var isUpload: Bool
    }

    static func route(path: String, httpMethod: String) -> Route? {
        let isUpload = path.hasPrefix("/upload/")
        guard let range = path.range(of: "/gmail/v1/users/me/") ?? (path.hasSuffix("/gmail/v1/users/me") ? path.range(of: "/gmail/v1/users/me") : nil) else {
            return nil
        }
        let s = path[range.upperBound...].split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        let m = httpMethod.uppercased()
        let method: GmailMethod?
        switch (s.count, s.first ?? "") {
        case (1, "profile") where m == "GET": method = .profile
        case (1, "labels"): method = m == "POST" ? .labelsCreate : .labelsList
        case (2, "labels"): method = m == "DELETE" ? .labelsDelete : .labelsGet
        case (2, "settings") where s[1] == "sendAs": method = .sendAsList
        case (1, "messages"): method = m == "POST" ? .messagesInsert : .messagesList
        case (2, "messages") where s[1] == "send": method = .messagesSend
        case (2, "messages") where s[1] == "import": method = .messagesImport
        case (2, "messages") where s[1] == "batchModify": method = .messagesBatchModify
        case (2, "messages") where s[1] == "batchDelete": method = .messagesBatchDelete
        case (2, "messages"): method = .messagesGet
        case (3, "messages") where s[2] == "modify": method = .messagesModify
        case (3, "messages") where s[2] == "trash": method = .messagesTrash
        case (3, "messages") where s[2] == "untrash": method = .messagesUntrash
        case (4, "messages") where s[2] == "attachments": method = .attachmentsGet
        case (2, "threads"): method = .threadsGet
        case (1, "history"): method = .historyList
        case (1, "drafts"): method = m == "POST" ? .draftsCreate : .draftsList
        case (2, "drafts"): method = m == "DELETE" ? .draftsDelete : (m == "PUT" ? .draftsUpdate : nil)
        default: method = nil
        }
        return method.map { Route(method: $0, segments: s, isUpload: isUpload) }
    }

    private struct Reply {
        var status: Int
        var body: Any
        var headers: [String: String] = [:]
        /// Bytes for a body that is not JSON.
        var data: Data?
    }

    /// Serves one call under the lock: counts it, applies faults, the token, the per-user budget,
    /// the concurrency limit and the allowances, then answers it and books its units.
    private func serve(_ method: GmailMethod, httpMethod: String, path: String, query: [URLQueryItem], percentEncodedQuery: String?,
                       body: Data, contentType: String?, token: String, client: String,
                       overLimit: Bool) -> Result<Reply, URLError> {
        state.attempts[method, default: 0] += 1
        let q = Dictionary(grouping: query, by: \.name).mapValues { $0.compactMap(\.value) }
        if method == .messagesList {
            state.rawQueries.append(percentEncodedQuery ?? "")
            state.queries.append(q["q"]?.first ?? "")
        }
        var afterAnswer: URLError?
        if let fault = takeFault(for: method) {
            switch fault {
            case .acceptedThenTimeout: afterAnswer = URLError(.timedOut)
            case .acceptedThenDropped: afterAnswer = URLError(.networkConnectionLost)
            default: return refusal(fault)
            }
        }
        if let accepted = state.acceptedTokens, !accepted.contains(token) {
            return .success(Reply(status: 401, body: ["error": ["code": 401, "message": "Invalid Credentials", "status": "UNAUTHENTICATED",
                                                                "errors": [["reason": "authError", "message": "Invalid Credentials"]]]]))
        }
        if overLimit { return refusal(.concurrentRequests) }
        let moment = clock()
        if let limit = state.userUnitsPerMinute {
            let spent = state.bookings.reversed().prefix { moment.timeIntervalSince($0.at) < 60 }
            let used = spent.reduce(0) { $0 + $1.units }
            if used + method.units > limit {
                let oldest = spent.last?.at ?? moment
                let wait = max(1, Int(ceil(60 - moment.timeIntervalSince(oldest))))
                return refusal(.rateLimited(retryAfter: String(wait)))
            }
        }
        let recent = state.traffic.filter { moment.timeIntervalSince($0.at) < 86_400 }
        if method.direction == .download, let allowance = state.downloadAllowance, recent.reduce(0, { $0 + $1.down }) >= allowance {
            return refusal(.bandwidth())
        }
        if method.direction == .upload, let allowance = state.uploadAllowance, recent.reduce(0, { $0 + $1.up }) + body.count > allowance {
            return refusal(.bandwidth())
        }
        var reply = answer(method, httpMethod: httpMethod, path: path, q: q, body: body, contentType: contentType)
        if reply.status == 200 || reply.status == 204 {
            let bytes = reply.data ?? (reply.status == 204 ? Data() : FakeGmailMailbox.json(reply.body))
            reply.data = bytes
            state.units[method, default: 0] += method.units
            state.calls[method, default: 0] += 1
            state.bytesServed[method, default: 0] += bytes.count
            state.bytesReceived[method, default: 0] += body.count
            state.bookings.append(Booking(at: moment, client: client, method: method, units: method.units))
            state.traffic.append((moment, method.direction == .download ? bytes.count : 0, method.direction == .upload ? body.count : 0))
        }
        if let afterAnswer { return .failure(afterAnswer) }
        return .success(reply)
    }

    private func takeFault(for method: GmailMethod) -> Fault? {
        if let i = state.faults.firstIndex(where: { $0.method == nil || $0.method == method }) {
            return state.faults.remove(at: i).fault
        }
        return state.standing[method]
    }

    private func refusal(_ fault: Fault) -> Result<Reply, URLError> {
        switch fault {
        case .timeout, .acceptedThenTimeout: return .failure(URLError(.timedOut))
        case .offline: return .failure(URLError(.notConnectedToInternet))
        case .acceptedThenDropped: return .failure(URLError(.networkConnectionLost))
        case .status(let code, let reason, let retryAfter):
            var error: [String: Any] = ["code": code, "message": "Refused by the fake (\(reason ?? "none"))"]
            if let reason { error["errors"] = [["reason": reason, "domain": "usageLimits", "message": "Refused"]] }
            if reason == "SERVICE_DISABLED" {
                error["errors"] = nil
                error["status"] = "PERMISSION_DENIED"
                error["details"] = [["@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "SERVICE_DISABLED"]]
            }
            return .success(Reply(status: code, body: ["error": error], headers: retryAfter.map { ["Retry-After": $0] } ?? [:]))
        case .google(let code, let reason, let message, let retryAfter):
            let error: [String: Any] = ["code": code, "message": message, "status": code == 429 ? "RESOURCE_EXHAUSTED" : "PERMISSION_DENIED",
                                        "errors": [["reason": reason, "domain": "usageLimits", "message": message]]]
            return .success(Reply(status: code, body: ["error": error], headers: retryAfter.map { ["Retry-After": $0] } ?? [:]))
        }
    }

    private func respond(_ url: URL, _ status: Int, _ body: Any, headers: [String: String] = [:], data: Data? = nil) -> (HTTPURLResponse, Data) {
        var all = headers
        if all["Content-Type"] == nil { all["Content-Type"] = "application/json; charset=UTF-8" }
        let bytes = data ?? (status == 204 ? Data() : FakeGmailMailbox.json(body))
        return (HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: all)!, bytes)
    }

    static func json(_ body: Any) -> Data {
        if let data = body as? Data { return data }
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    // MARK: - Batches

    static func batchParts(_ body: Data, contentType: String?) -> [(contentID: String?, request: String)] {
        guard let boundary = contentType.flatMap(MultipartText.boundary) else { return [] }
        return MultipartText.parts(of: body, boundary: boundary).map { part in
            let (head, nested) = MultipartText.splitHead(part)
            let id = MultipartText.headers(head)["content-id"]
            return (id, nested.utf8Lossy)
        }
    }

    private func serveBatch(_ request: URLRequest, url: URL, path: String, body: Data, arrival: Arrival) -> Result<(HTTPURLResponse, Data), URLError> {
        guard state.acceptedBatchPaths.contains(path) else {
            return .success(respond(url, 404, ["error": ["code": 404, "message": "Not Found", "status": "NOT_FOUND"]]))
        }
        if !state.batchFaults.isEmpty {
            switch refusal(state.batchFaults.removeFirst()) {
            case .failure(let error): return .failure(error)
            case .success(let reply): return .success(respond(url, reply.status, reply.body, headers: reply.headers))
            }
        }
        let parts = FakeGmailMailbox.batchParts(body, contentType: request.value(forHTTPHeaderField: "Content-Type"))
        guard parts.count <= 100 else {
            return .success(respond(url, 400, ["error": ["code": 400, "message": "Too many requests in a batch", "status": "INVALID_ARGUMENT"]]))
        }
        state.batchSizes.append(parts.count)
        let token = request.value(forHTTPHeaderField: "Authorization")?.removingPrefix("Bearer ") ?? ""
        let allowed = parts.count - arrival.overLimit
        var answers: [String] = []
        for (index, part) in parts.enumerated() {
            let line = part.request.components(separatedBy: "\n").first?.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) ?? ""
            let fields = line.split(separator: " ")
            var status = 400
            var answerBody = Data()
            var headers: [String: String] = [:]
            if fields.count >= 2, let comps = URLComponents(string: "https://batch.invalid" + fields[1]),
               let route = FakeGmailMailbox.route(path: comps.path, httpMethod: String(fields[0])) {
                let served = serve(route.method, httpMethod: String(fields[0]), path: comps.path, query: comps.queryItems ?? [],
                                   percentEncodedQuery: comps.percentEncodedQuery, body: Data(), contentType: nil, token: token,
                                   client: arrival.call.client, overLimit: index >= allowed)
                switch served {
                case .success(let reply):
                    status = reply.status
                    answerBody = reply.data ?? FakeGmailMailbox.json(reply.body)
                    headers = reply.headers
                case .failure:
                    status = 503
                    answerBody = FakeGmailMailbox.json(["error": ["code": 503, "message": "Backend Error", "errors": [["reason": "backendError"]]]])
                }
            } else {
                answerBody = FakeGmailMailbox.json(["error": ["code": 400, "message": "Bad Request"]])
            }
            var text = "Content-Type: application/http\r\n"
            if let id = part.contentID {
                let bare = id.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
                text += "Content-ID: <response-\(bare)>\r\n"
            }
            text += "\r\nHTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json; charset=UTF-8\r\n"
            for (name, value) in headers where name != "Content-Type" { text += "\(name): \(value)\r\n" }
            text += "\r\n" + answerBody.utf8Lossy + "\r\n"
            answers.append(text)
        }
        switch state.answerOrder {
        case .asked: break
        case .reversed: answers.reverse()
        case .shuffled: answers.shuffle(using: &random)
        }
        let boundary = "batch_fake_\(state.batchSizes.count)"
        let payload = answers.map { "--\(boundary)\r\n" + $0 }.joined() + "--\(boundary)--\r\n"
        return .success(respond(url, 200, [:], headers: ["Content-Type": "multipart/mixed; boundary=\(boundary)"], data: Data(payload.utf8)))
    }

    // MARK: - Endpoints

    private static func notFound(_ what: String = "Requested entity was not found.") -> Reply {
        Reply(status: 404, body: ["error": ["code": 404, "message": what, "status": "NOT_FOUND", "errors": [["reason": "notFound", "message": what]]]])
    }

    private static func invalid(_ what: String) -> Reply {
        Reply(status: 400, body: ["error": ["code": 400, "message": what, "status": "INVALID_ARGUMENT",
                                            "errors": [["reason": "invalidArgument", "message": what]]]])
    }

    private func answer(_ method: GmailMethod, httpMethod: String, path: String, q: [String: [String]], body: Data,
                        contentType: String?) -> Reply {
        guard let route = FakeGmailMailbox.route(path: path, httpMethod: httpMethod) else { return FakeGmailMailbox.notFound("Not Found") }
        let s = route.segments
        switch method {
        case .profile:
            let inEither = state.counts[FakeGmailMailbox.trash].total + state.counts[FakeGmailMailbox.spam].total - state.inSpamAndTrash
            let total = state.profileCountsSpamTrash ? state.order.count : state.order.count - inEither
            return Reply(status: 200, body: ["emailAddress": email, "messagesTotal": total, "threadsTotal": state.threadMembers.count,
                                             "historyId": String(state.historyID)])
        case .labelsList:
            return Reply(status: 200, body: ["labels": state.labels.filter(\.alive).map { labelJSON($0, counts: false) }])
        case .labelsGet:
            guard let index = state.labelIndex[s[1]], state.labels[index].alive else { return FakeGmailMailbox.notFound() }
            return Reply(status: 200, body: labelJSON(state.labels[index], counts: true))
        case .labelsCreate:
            let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            guard let name = request?["name"] as? String, !name.isEmpty else { return FakeGmailMailbox.invalid("Invalid label name") }
            if state.labels.contains(where: { $0.alive && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return Reply(status: 409, body: ["error": ["code": 409, "message": "Label name exists or conflicts", "status": "ALREADY_EXISTS",
                                                           "errors": [["reason": "duplicate"]]]])
            }
            let id = newUserLabel(named: name, visibility: request?["labelListVisibility"] as? String ?? "labelShow")
            return Reply(status: 200, body: labelJSON(state.labels[state.labelIndex[id]!], counts: false))
        case .labelsDelete:
            guard let index = state.labelIndex[s[1]], state.labels[index].alive else { return FakeGmailMailbox.notFound() }
            guard !state.labels[index].isSystem else { return FakeGmailMailbox.invalid("Invalid delete request") }
            var bit = LabelBits()
            bit[index] = true
            for slot in state.order where state.records[slot].labels[index] { applyLabels(slot, adding: LabelBits(), removing: bit) }
            state.labels[index].alive = false
            return Reply(status: 204, body: [:])
        case .sendAsList:
            return Reply(status: 200, body: ["sendAs": state.sendAs])
        case .messagesList:
            return list(q)
        case .messagesGet:
            guard let slot = UInt64(s[1], radix: 16).flatMap({ state.slotByID[$0] }) else { return FakeGmailMailbox.notFound() }
            return Reply(status: 200, body: messageJSON(slot, format: q["format"]?.first ?? "full", headers: q["metadataHeaders"] ?? []))
        case .threadsGet:
            guard let thread = state.threadByName[s[1]] ?? UInt64(s[1], radix: 16) else { return FakeGmailMailbox.notFound() }
            let members = (state.threadMembers[thread] ?? []).sorted { a, b in
                let x = state.records[a], y = state.records[b]
                return x.date != y.date ? x.date < y.date : x.id < y.id
            }
            guard !members.isEmpty else { return FakeGmailMailbox.notFound() }
            let format = q["format"]?.first ?? "full"
            let newest = members.map { state.records[$0].history }.max() ?? 0
            return Reply(status: 200, body: ["id": s[1], "historyId": String(newest),
                                             "messages": members.map { messageJSON($0, format: format, headers: q["metadataHeaders"] ?? []) }])
        case .attachmentsGet:
            return attachment(s[1], s[3])
        case .historyList:
            return history(q)
        case .messagesModify:
            guard let slot = UInt64(s[1], radix: 16).flatMap({ state.slotByID[$0] }) else { return FakeGmailMailbox.notFound() }
            let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            switch checkedChange(request["addLabelIds"] as? [String] ?? [], request["removeLabelIds"] as? [String] ?? []) {
            case .failure(let reply): return reply
            case .success(let change):
                applyLabels(slot, adding: change.add, removing: change.remove)
                return Reply(status: 200, body: messageJSON(slot, format: "minimal", headers: []))
            }
        case .messagesBatchModify:
            let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            let ids = request["ids"] as? [String] ?? []
            guard ids.count <= 1_000 else { return FakeGmailMailbox.invalid("Too many ids") }
            switch checkedChange(request["addLabelIds"] as? [String] ?? [], request["removeLabelIds"] as? [String] ?? []) {
            case .failure(let reply): return reply
            case .success(let change):
                for id in ids {
                    guard let slot = UInt64(id, radix: 16).flatMap({ state.slotByID[$0] }) else { continue }
                    applyLabels(slot, adding: change.add, removing: change.remove)
                }
                return Reply(status: 204, body: [:])
            }
        case .messagesBatchDelete:
            let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            let ids = request["ids"] as? [String] ?? []
            guard ids.count <= 1_000 else { return FakeGmailMailbox.invalid("Too many ids") }
            for id in ids { if let raw = UInt64(id, radix: 16) { remove(raw) } }
            return Reply(status: 204, body: [:])
        case .messagesTrash, .messagesUntrash:
            guard let slot = UInt64(s[1], radix: 16).flatMap({ state.slotByID[$0] }) else { return FakeGmailMailbox.notFound() }
            var bit = LabelBits()
            bit[FakeGmailMailbox.trash] = true
            if method == .messagesTrash {
                applyLabels(slot, adding: bit, removing: LabelBits())
            } else {
                applyLabels(slot, adding: LabelBits(), removing: bit)
            }
            return Reply(status: 200, body: messageJSON(slot, format: "minimal", headers: []))
        case .messagesSend, .messagesImport, .messagesInsert, .draftsCreate, .draftsUpdate:
            return upload(method, segments: s, q: q, body: body, contentType: contentType, isUpload: route.isUpload)
        case .draftsDelete:
            guard let old = state.drafts.removeValue(forKey: s[1]) else { return FakeGmailMailbox.notFound() }
            state.draftOrder.removeAll { $0 == s[1] }
            remove(old)
            return Reply(status: 204, body: [:])
        case .draftsList:
            let maxResults = max(1, min(500, Int(q["maxResults"]?.first ?? "") ?? 100))
            let offset = Int(q["pageToken"]?.first ?? "") ?? 0
            let page = state.draftOrder.dropFirst(offset).prefix(maxResults)
            var reply: [String: Any] = ["resultSizeEstimate": state.draftOrder.count]
            if !page.isEmpty {
                reply["drafts"] = page.compactMap { id -> [String: Any]? in
                    guard let message = state.drafts[id], let slot = state.slotByID[message] else { return nil }
                    return ["id": id, "message": ["id": String(message, radix: 16), "threadId": threadString(state.records[slot].thread)]]
                }
            }
            if offset + page.count < state.draftOrder.count { reply["nextPageToken"] = String(offset + page.count) }
            return Reply(status: 200, body: reply)
        }
    }

    private func labelJSON(_ label: LabelInfo, counts: Bool) -> [String: Any] {
        var out: [String: Any] = ["id": label.id, "name": label.name, "type": label.isSystem ? "system" : "user"]
        if !label.isSystem {
            out["labelListVisibility"] = label.listVisibility
            out["messageListVisibility"] = "show"
        }
        if counts, let index = state.labelIndex[label.id] {
            let c = state.counts[index]
            let include = state.labelCountsIncludeSpamTrash || index == FakeGmailMailbox.spam || index == FakeGmailMailbox.trash
            out["messagesTotal"] = include ? c.total : c.total - c.totalInSpamTrash
            out["messagesUnread"] = include ? c.unread : c.unread - c.unreadInSpamTrash
            let threads = threadStats()
            out["threadsTotal"] = index < threads.threads.count ? threads.threads[index] : 0
            out["threadsUnread"] = index < threads.unreadThreads.count ? threads.unreadThreads[index] : 0
        }
        return out
    }

    /// Thread counts per label, worked out in one pass over the threads and kept until the
    /// mailbox next changes: a thread counts for a label when any of its messages has it.
    private func threadStats() -> (threads: [Int], unreadThreads: [Int]) {
        if let cached = state.threadStats, cached.generation == state.generation { return (cached.threads, cached.unreadThreads) }
        var threads = [Int](repeating: 0, count: state.labels.count)
        var unread = [Int](repeating: 0, count: state.labels.count)
        for members in state.threadMembers.values {
            var any = LabelBits()
            var anyUnread = LabelBits()
            for slot in members {
                let labels = state.records[slot].labels
                any = any.union(labels)
                if labels[FakeGmailMailbox.unread] { anyUnread = anyUnread.union(labels) }
            }
            any.forEachIndex { threads[$0] += 1 }
            anyUnread.forEachIndex { unread[$0] += 1 }
        }
        state.threadStats = (state.generation, threads, unread)
        return (threads, unread)
    }

    private enum Checked {
        case success((add: LabelBits, remove: LabelBits))
        case failure(Reply)
    }

    private func checkedChange(_ add: [String], _ remove: [String]) -> Checked {
        for id in add + remove {
            if id == "SENT" || id == "DRAFT" { return .failure(FakeGmailMailbox.invalid("Invalid label: \(id)")) }
            guard let index = state.labelIndex[id], state.labels[index].alive else {
                return .failure(id.hasPrefix("Label_") ? FakeGmailMailbox.notFound("Label not found") : FakeGmailMailbox.invalid("Invalid label: \(id)"))
            }
        }
        var a = LabelBits()
        var r = LabelBits()
        for id in add { a[state.labelIndex[id]!] = true }
        for id in remove { r[state.labelIndex[id]!] = true }
        return .success((a, r))
    }

    // MARK: Lists and search

    private struct Filter {
        var required = LabelBits()
        var excluded = LabelBits()
        var beforeMs: Int64?
        var afterMs: Int64?
        var tests: [(Record) -> Bool] = []
        var impossible = false
    }

    private func filter(_ q: [String: [String]]) -> Filter {
        var f = Filter()
        let terms = FakeGmailMailbox.terms(q["q"]?.first ?? "")
        let includeSpamTrash = q["includeSpamTrash"]?.first == "true"
        var asked = LabelBits()
        for id in q["labelIds"] ?? [] {
            guard let index = state.labelIndex[id] else { f.impossible = true; continue }
            f.required[index] = true
            asked[index] = true
        }
        var anywhere = includeSpamTrash
        for term in terms {
            let lower = term.lowercased()
            func value(_ prefix: String) -> String? {
                lower.hasPrefix(prefix) ? String(term.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) : nil
            }
            if let v = value("in:") {
                switch v.lowercased() {
                case "inbox": f.required[FakeGmailMailbox.inbox] = true
                case "sent": f.required[FakeGmailMailbox.sent] = true
                case "drafts": f.required[FakeGmailMailbox.draft] = true
                case "spam": f.required[FakeGmailMailbox.spam] = true; asked[FakeGmailMailbox.spam] = true
                case "trash": f.required[FakeGmailMailbox.trash] = true; asked[FakeGmailMailbox.trash] = true
                case "anywhere": anywhere = true
                default: break
                }
            } else if let v = value("is:") {
                switch v.lowercased() {
                case "starred": f.required[FakeGmailMailbox.starred] = true
                case "unread": f.required[FakeGmailMailbox.unread] = true
                case "important": f.required[FakeGmailMailbox.important] = true
                default: f.impossible = true
                }
            } else if let v = value("label:") {
                let wanted = v.lowercased()
                let found = state.labels.firstIndex { label in
                    let name = label.name.lowercased()
                    return label.alive && (name == wanted || label.id.lowercased() == wanted
                                           || name.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "-") == wanted)
                }
                if let found { f.required[found] = true } else { f.impossible = true }
            } else if let v = value("before:"), let seconds = Double(v) {
                f.beforeMs = min(f.beforeMs ?? .max, Int64(seconds * 1000))
            } else if let v = value("after:"), let seconds = Double(v) {
                f.afterMs = max(f.afterMs ?? .min, Int64(seconds * 1000))
            } else if let v = value("larger:") {
                let n = FakeGmailMailbox.bytes(v)
                f.tests.append { $0.size > n }
            } else if let v = value("smaller:") {
                let n = FakeGmailMailbox.bytes(v)
                f.tests.append { $0.size < n }
            } else if lower == "has:attachment" {
                f.tests.append { $0.hasAttachment }
            } else {
                let term = term
                f.tests.append { [unowned self] record in self.matches(record, term) }
            }
        }
        if !anywhere {
            if !asked[FakeGmailMailbox.spam] { f.excluded[FakeGmailMailbox.spam] = true }
            if !asked[FakeGmailMailbox.trash] { f.excluded[FakeGmailMailbox.trash] = true }
        }
        if !state.listReturnsChats, !asked[FakeGmailMailbox.chat] { f.excluded[FakeGmailMailbox.chat] = true }
        return f
    }

    private func accepts(_ f: Filter, _ r: Record) -> Bool {
        guard r.labels.isSuperset(of: f.required), !r.labels.intersects(f.excluded) else { return false }
        if let before = f.beforeMs, r.date >= before { return false }
        if let after = f.afterMs, r.date < after { return false }
        return f.tests.allSatisfy { $0(r) }
    }

    /// Where in `order` a date bound starts, found by halving: `order` is newest first.
    private func firstPosition(olderThan ms: Int64) -> Int {
        var low = 0
        var high = state.order.count
        while low < high {
            let mid = (low + high) / 2
            if state.records[state.order[mid]].date >= ms { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func list(_ q: [String: [String]]) -> Reply {
        let f = filter(q)
        let maxResults = max(1, min(500, Int(q["maxResults"]?.first ?? "") ?? 100))
        var offset = 0
        var position = f.beforeMs.map(firstPosition(olderThan:)) ?? 0
        if let token = q["pageToken"]?.first {
            // "offset.position.generation": the position is used only while nothing has changed;
            // otherwise the offset is counted again from the top, as Gmail's own tokens behave.
            let pieces = token.split(separator: ".").compactMap { Int($0) }
            if pieces.count == 3 {
                offset = pieces[0]
                if UInt64(pieces[2]) == state.generation {
                    position = pieces[1]
                } else {
                    var skipped = 0
                    while position < state.order.count, skipped < offset {
                        if accepts(f, state.records[state.order[position]]) { skipped += 1 }
                        position += 1
                    }
                }
            }
        }
        var page: [Int] = []
        if !f.impossible {
            while position < state.order.count, page.count < maxResults {
                let r = state.records[state.order[position]]
                if let after = f.afterMs, r.date < after { position = state.order.count; break }
                if accepts(f, r) { page.append(state.order[position]) }
                position += 1
            }
        }
        var more = false
        if !f.impossible {
            var probe = position
            while probe < state.order.count {
                let r = state.records[state.order[probe]]
                if let after = f.afterMs, r.date < after { break }
                if accepts(f, r) { more = true; break }
                probe += 1
            }
        }
        var body: [String: Any] = ["resultSizeEstimate": estimate(f, pageEnd: offset + page.count, more: more)]
        if !page.isEmpty {
            body["messages"] = page.map { ["id": String(state.records[$0].id, radix: 16), "threadId": threadString(state.records[$0].thread)] }
        }
        if more { body["nextPageToken"] = "\(offset + page.count).\(position).\(state.generation)" }
        return Reply(status: 200, body: body)
    }

    /// Gmail's estimate: exact here for one label or none, from the counters, and otherwise what
    /// has been seen so far.
    private func estimate(_ f: Filter, pageEnd: Int, more: Bool) -> Int {
        guard f.tests.isEmpty, f.beforeMs == nil, f.afterMs == nil, !f.impossible else { return pageEnd + (more ? 1 : 0) }
        let required = f.required.indices
        let excludesSpamTrash = f.excluded[FakeGmailMailbox.spam] && f.excluded[FakeGmailMailbox.trash]
        if required.isEmpty {
            let spamTrash = state.counts[FakeGmailMailbox.spam].total + state.counts[FakeGmailMailbox.trash].total - state.inSpamAndTrash
            return excludesSpamTrash ? max(0, state.order.count - spamTrash) : state.order.count
        }
        return required.map { i in excludesSpamTrash ? state.counts[i].total - state.counts[i].totalInSpamTrash : state.counts[i].total }.min() ?? 0
    }

    private func matches(_ r: Record, _ term: String) -> Bool {
        let c = content(r)
        let lower = term.lowercased()
        func value(_ prefix: String) -> String? {
            lower.hasPrefix(prefix) ? String(lower.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) : nil
        }
        if let v = value("from:") { return c.from.lowercased().contains(v) }
        if let v = value("to:") { return c.to.lowercased().contains(v) }
        if let v = value("subject:") { return c.subject.lowercased().contains(v) }
        if let v = value("rfc822msgid:") {
            let wanted = v.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            let own = c.messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<>")).lowercased()
            return own == wanted || own.contains(wanted)
        }
        let needle = lower.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return [c.subject, c.from, c.to, c.text, c.html ?? ""].contains { $0.lowercased().contains(needle) }
    }

    static func terms(_ q: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quoted = false
        for ch in q {
            if ch == "\"" { quoted.toggle(); current.append(ch); continue }
            if ch == " " && !quoted {
                if !current.isEmpty { out.append(current); current = "" }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func bytes(_ text: String) -> Int {
        let t = text.lowercased()
        if t.hasSuffix("m"), let n = Int(t.dropLast()) { return n * 1_000_000 }
        if t.hasSuffix("k"), let n = Int(t.dropLast()) { return n * 1_000 }
        return Int(t) ?? 0
    }

    // MARK: History

    private func history(_ q: [String: [String]]) -> Reply {
        guard let start = q["startHistoryId"]?.first.flatMap({ UInt64($0) }) else {
            return FakeGmailMailbox.invalid("startHistoryId is required")
        }
        guard start >= state.historyFloor else { return FakeGmailMailbox.notFound() }
        let types = Set(q["historyTypes"] ?? [])
        let wanted = types.isEmpty ? Set(GmailHistoryType.allCases.map(\.rawValue)) : types
        let labelFilter = q["labelId"]?.first.flatMap { state.labelIndex[$0] }
        if q["labelId"]?.first != nil, labelFilter == nil { return FakeGmailMailbox.notFound() }
        let maxResults = max(1, min(500, Int(q["maxResults"]?.first ?? "") ?? 100))
        var low = 0
        var high = state.log.count
        while low < high {
            let mid = (low + high) / 2
            if state.log[mid].id <= start { low = mid + 1 } else { high = mid }
        }
        var records: [[String: Any]] = []
        var skip = Int(q["pageToken"]?.first ?? "") ?? 0
        var taken = 0
        var more = false
        for change in state.log[low...] {
            guard let record = historyJSON(change, wanted: wanted, label: labelFilter) else { continue }
            if skip > 0 { skip -= 1; continue }
            if records.count == maxResults { more = true; break }
            records.append(record)
            taken += 1
        }
        var body: [String: Any] = ["historyId": String(state.historyID)]
        if !records.isEmpty { body["history"] = records }
        if more { body["nextPageToken"] = String((Int(q["pageToken"]?.first ?? "") ?? 0) + taken) }
        return Reply(status: 200, body: body)
    }

    private func historyJSON(_ change: Change, wanted: Set<String>, label: Int?) -> [String: Any]? {
        if let label {
            let touches = change.labels[label] || change.added[label] || change.removed[label]
            guard touches else { return nil }
        }
        let ids: [String: Any] = ["id": String(change.message, radix: 16), "threadId": threadString(change.thread)]
        var message = ids
        message["labelIds"] = labelIDs(change.labels)
        var record: [String: Any] = ["id": String(change.id), "messages": [ids]]
        switch change.kind {
        case .added:
            guard wanted.contains("messageAdded") else { return nil }
            record["messagesAdded"] = [["message": state.historyAddedCarriesLabels ? message : ids]]
        case .deleted:
            guard wanted.contains("messageDeleted") else { return nil }
            record["messagesDeleted"] = [["message": message]]
        case .labels:
            var any = false
            if !change.added.isEmpty, wanted.contains("labelAdded") {
                record["labelsAdded"] = [["message": message, "labelIds": labelIDs(change.added)]]
                any = true
            }
            if !change.removed.isEmpty, wanted.contains("labelRemoved") {
                record["labelsRemoved"] = [["message": message, "labelIds": labelIDs(change.removed)]]
                any = true
            }
            guard any else { return nil }
        }
        return record
    }

    // MARK: Messages

    private func messageJSON(_ slot: Int, format: String, headers wanted: [String]) -> [String: Any] {
        let r = state.records[slot]
        let c = content(r)
        var body: [String: Any] = [
            "id": String(r.id, radix: 16), "threadId": threadString(r.thread), "labelIds": labelIDs(r.labels),
            "historyId": String(r.history), "internalDate": String(r.date), "sizeEstimate": r.size
        ]
        let snippet = FakeGmailMailbox.escape(String(c.text.prefix(100)))
        let all = allHeaders(c, date: r.date)
        switch format {
        case "minimal":
            break
        case "metadata":
            let names = Set(wanted.map { $0.lowercased() })
            let kept = names.isEmpty ? all : all.filter { names.contains($0.name.lowercased()) }
            if state.snippetInMetadata { body["snippet"] = snippet }
            body["payload"] = ["mimeType": String(FakeGmailMailbox.contentType(c).prefix { $0 != ";" }),
                               "headers": kept.map { ["name": $0.name, "value": $0.value] }]
        case "raw":
            body["snippet"] = snippet
            body["raw"] = rawBytes(c, date: r.date).base64URL
        default:
            body["snippet"] = snippet
            body["payload"] = fullPayload(r, c, headers: all)
        }
        return body
    }

    private func allHeaders(_ c: Content, date: Int64) -> [(name: String, value: String)] {
        if c.raw != nil { return c.headers }
        var headers: [(name: String, value: String)] = [("From", c.from), ("To", c.to), ("Subject", c.subject)]
        headers.append(("Date", RFC5322Date.format(Date(timeIntervalSince1970: TimeInterval(date) / 1000))))
        headers.append(("Message-Id", c.messageID))
        headers.append(("Content-Type", FakeGmailMailbox.contentType(c)))
        if !c.cc.isEmpty { headers.append(("Cc", c.cc)) }
        return headers + c.headers
    }

    private func fullPayload(_ r: Record, _ m: Content, headers all: [(name: String, value: String)]) -> [String: Any] {
        let headers = all.map { ["name": $0.name, "value": $0.value] }
        func textPart(_ partID: String, _ type: String, _ text: String) -> [String: Any] {
            let data = Data(text.utf8)
            return ["partId": partID, "mimeType": type, "filename": "",
                    "headers": [["name": "Content-Type", "value": "\(type); charset=UTF-8"]],
                    "body": ["size": data.count, "data": data.base64URL]]
        }
        var textParts: [[String: Any]] = [textPart("0.0", "text/plain", m.text)]
        if let html = m.html { textParts.append(textPart("0.1", "text/html", html)) }
        let body: [String: Any] = textParts.count == 1 ? textParts[0]
            : ["partId": "0", "mimeType": "multipart/alternative", "filename": "", "headers": [["name": "Content-Type", "value": "multipart/alternative; boundary=b2"]],
               "body": ["size": 0], "parts": textParts]
        guard !m.attachments.isEmpty else {
            var single = body
            single["partId"] = ""
            single["headers"] = headers.filter { $0["name"] != "Content-Type" } + ((single["headers"] as? [[String: String]]) ?? [])
            return single
        }
        let attachmentParts: [[String: Any]] = m.attachments.enumerated().map { index, a in
            var partHeaders = [["name": "Content-Type", "value": "\(a.mimeType); name=\"\(a.filename)\""],
                               ["name": "Content-Disposition", "value": "\(a.contentID == nil ? "attachment" : "inline"); filename=\"\(a.filename)\""]]
            if let cid = a.contentID { partHeaders.append(["name": "Content-ID", "value": "<\(cid)>"]) }
            return ["partId": String(index + 1), "mimeType": a.mimeType, "filename": a.filename, "headers": partHeaders,
                    "body": ["attachmentId": attachmentID(r.id, index), "size": a.data.count]]
        }
        return ["partId": "", "mimeType": "multipart/mixed", "filename": "", "headers": headers, "body": ["size": 0],
                "parts": [body] + attachmentParts]
    }

    private func attachmentID(_ id: UInt64, _ index: Int) -> String {
        let base = "att-\(String(id, radix: 16))-\(index)"
        return state.attachmentGeneration == 0 ? base : base + "-g\(state.attachmentGeneration)"
    }

    private func attachment(_ messageID: String, _ attachmentID: String) -> Reply {
        guard let raw = UInt64(messageID, radix: 16), let slot = state.slotByID[raw] else { return FakeGmailMailbox.notFound("Not Found") }
        let c = content(state.records[slot])
        let pieces = attachmentID.split(separator: "-")
        guard pieces.count >= 3, pieces[0] == "att", pieces[1] == Substring(messageID), let index = Int(pieces[2]),
              c.attachments.indices.contains(index) else {
            return FakeGmailMailbox.notFound("Not Found")
        }
        if state.onlyCurrentAttachmentIDs, attachmentID != self.attachmentID(raw, index) { return FakeGmailMailbox.notFound("Invalid attachment token") }
        let data = c.attachments[index].data
        return Reply(status: 200, body: ["size": data.count, "data": data.base64URL])
    }

    private func rawBytes(_ c: Content, date: Int64) -> Data {
        if let raw = c.raw { return raw }
        var head = allHeaders(c, date: date).filter { $0.name.lowercased() != "content-type" && $0.name.lowercased() != "date" }
        head.append(("Date", RFC5322Date.format(Date(timeIntervalSince1970: TimeInterval(date) / 1000))))
        head.append(("MIME-Version", "1.0"))
        var text = head.map { "\($0.name): \($0.value)" }.joined(separator: "\r\n")
        if c.attachments.isEmpty && c.html == nil {
            text += "\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n" + c.text
            return Data(text.utf8)
        }
        let boundary = "fake_raw_boundary"
        text += "\r\nContent-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n"
        text += "--\(boundary)\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n\(c.text)\r\n"
        if let html = c.html { text += "--\(boundary)\r\nContent-Type: text/html; charset=UTF-8\r\n\r\n\(html)\r\n" }
        for a in c.attachments {
            text += "--\(boundary)\r\nContent-Type: \(a.mimeType); name=\"\(a.filename)\"\r\nContent-Transfer-Encoding: base64\r\n"
            text += "Content-Disposition: \(a.contentID == nil ? "attachment" : "inline"); filename=\"\(a.filename)\"\r\n"
            if let cid = a.contentID { text += "Content-ID: <\(cid)>\r\n" }
            text += "\r\n" + a.data.base64EncodedString(options: .lineLength76Characters) + "\r\n"
        }
        text += "--\(boundary)--\r\n"
        return Data(text.utf8)
    }

    static func contentType(_ m: Content) -> String {
        if let raw = m.headers.first(where: { $0.name.lowercased() == "content-type" }) { return raw.value }
        if !m.attachments.isEmpty { return "multipart/mixed; boundary=b1" }
        return m.html == nil ? "text/plain; charset=UTF-8" : "multipart/alternative; boundary=b2"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    // MARK: Uploads

    private func upload(_ method: GmailMethod, segments s: [String], q: [String: [String]], body: Data, contentType: String?,
                        isUpload: Bool) -> Reply {
        var metadata: [String: Any] = [:]
        var raw = Data()
        if isUpload {
            guard let type = contentType, let parsed = GmailUpload.parse(body, contentType: type) else {
                return FakeGmailMailbox.invalid("Media type 'application/octet-stream' is not supported")
            }
            metadata = (try? JSONSerialization.jsonObject(with: parsed.metadata)) as? [String: Any] ?? [:]
            raw = parsed.message
        } else {
            metadata = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            let encoded = (metadata["raw"] as? String) ?? ((metadata["message"] as? [String: Any])?["raw"] as? String)
            raw = encoded.flatMap { Data(base64URL: $0) } ?? Data()
        }
        guard !raw.isEmpty else { return FakeGmailMailbox.invalid("Missing message") }
        let maxBytes = GmailUpload.maxBytes(for: method)
        guard raw.count <= maxBytes else {
            return Reply(status: 413, body: ["error": ["code": 413, "message": "Request Entity Too Large", "errors": [["reason": "payloadTooLarge"]]]])
        }
        let threadHex = (metadata["threadId"] as? String) ?? ((metadata["message"] as? [String: Any])?["threadId"] as? String)
        let labelIDs = metadata["labelIds"] as? [String] ?? []
        switch method {
        case .messagesSend:
            state.sentUploads.append(raw)
            let slot = file(raw, labels: sentLabels(raw), threadHex: threadHex, date: clock(), replaceMessageID: state.replacesMessageIDOnSend)
            return Reply(status: 200, body: messageJSON(slot, format: "minimal", headers: []))
        case .messagesImport, .messagesInsert:
            for id in labelIDs where state.labelIndex[id].map({ !state.labels[$0].alive }) ?? true {
                return id.hasPrefix("Label_") ? FakeGmailMailbox.notFound("Label not found") : FakeGmailMailbox.invalid("Invalid label: \(id)")
            }
            let fromHeader = (q["internalDateSource"]?.first ?? (method == .messagesImport ? "dateHeader" : "receivedTime")) == "dateHeader"
            let date = fromHeader ? (MIMEParser.parse(raw).date ?? clock()) : clock()
            let slot = file(raw, labels: bitsForIDs(labelIDs), threadHex: threadHex, date: date, replaceMessageID: false)
            return Reply(status: 200, body: messageJSON(slot, format: "minimal", headers: []))
        case .draftsCreate:
            let id = "r\(state.nextDraft)"
            state.nextDraft += 1
            let slot = file(raw, labels: bitsForIDs(["DRAFT"]), threadHex: threadHex, date: clock(), replaceMessageID: state.draftReplacesMessageID)
            state.drafts[id] = state.records[slot].id
            state.draftOrder.insert(id, at: 0)
            return Reply(status: 200, body: ["id": id, "message": messageJSON(slot, format: "minimal", headers: [])])
        case .draftsUpdate:
            let id = s.count > 1 ? s[1] : ""
            guard let old = state.drafts[id] else { return FakeGmailMailbox.notFound() }
            // Gmail files every save as a new message and deletes the one before it.
            remove(old)
            let slot = file(raw, labels: bitsForIDs(["DRAFT"]), threadHex: threadHex, date: clock(), replaceMessageID: state.draftReplacesMessageID)
            state.drafts[id] = state.records[slot].id
            return Reply(status: 200, body: ["id": id, "message": messageJSON(slot, format: "minimal", headers: [])])
        default:
            return FakeGmailMailbox.notFound()
        }
    }

    /// SENT, and the Inbox as well when the message was sent to the account itself.
    private func sentLabels(_ raw: Data) -> LabelBits {
        let parsed = MIMEParser.parse(raw)
        let recipients = (parsed.to + parsed.cc + AddressParser.parse(parsed.headers.first("Bcc"))).map { $0.address.lowercased() }
        var labels = bitsForIDs(["SENT"])
        if recipients.contains(email.lowercased()) {
            labels[FakeGmailMailbox.inbox] = true
            labels[FakeGmailMailbox.unread] = true
        }
        return labels
    }

    /// Files an uploaded message: its thread is the one named, or the one its References point
    /// into, or its own.
    private func file(_ raw: Data, labels: LabelBits, threadHex: String?, date: Date, replaceMessageID: Bool) -> Int {
        let parsed = MIMEParser.parse(raw)
        var headers = parsed.headers.fields.map { (name: $0.name, value: $0.value) }
        var messageID = parsed.headers.first("Message-ID") ?? ""
        if replaceMessageID {
            let replacement = "<gmail-\(UUID().uuidString.lowercased())@mail.gmail.com>"
            if let i = headers.firstIndex(where: { $0.name.lowercased() == "message-id" }) {
                headers[i].value = replacement
            } else {
                headers.append(("Message-ID", replacement))
            }
            headers.append(("X-Google-Original-Message-ID", messageID))
            messageID = replacement
        }
        let id = newMessageID()
        var thread = id
        if let hex = threadHex, let named = state.threadByName[hex] ?? UInt64(hex, radix: 16), state.threadMembers[named]?.isEmpty == false {
            thread = named
        } else if let slot = (parsed.references.reversed() + [parsed.inReplyTo]).lazy.compactMap({ self.slot(messageID: $0) }).first {
            thread = state.records[slot].thread
        }
        let content = Content(from: parsed.headers.first("From") ?? "", to: parsed.headers.first("To") ?? "",
                              cc: parsed.headers.first("Cc") ?? "", subject: parsed.subject, messageID: messageID,
                              text: parsed.textPlain ?? "", html: parsed.textHTML,
                              attachments: parsed.attachments.map { Attachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data,
                                                                               contentID: $0.isInline ? $0.contentID : nil) },
                              headers: headers, raw: raw)
        return insert(id: id, thread: thread, labels: labels, date: date, size: raw.count, hasAttachment: !parsed.attachments.isEmpty,
                      content: content)
    }

    // MARK: - Inside the lock

    private func threadString(_ thread: UInt64) -> String {
        state.threadNames[thread] ?? String(thread, radix: 16)
    }

    /// A thread id as a test wrote it: Gmail's hex, or any other text, which stands for a thread
    /// of its own.
    private func threadNumber(_ text: String) -> UInt64 {
        if let known = state.threadByName[text] { return known }
        if GmailThreadID(hex: text) != nil, let value = UInt64(text, radix: 16) { return value }
        let number = 0x7f00_0000_0000_0000 + UInt64(state.threadNames.count)
        state.threadNames[number] = text
        state.threadByName[text] = number
        return number
    }

    static func bare(_ messageID: String) -> String {
        messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")).lowercased()
    }

    /// The live message with this Message-ID. A fixture message's is made from its id.
    private func slot(messageID: String) -> Int? {
        let key = FakeGmailMailbox.bare(messageID)
        guard !key.isEmpty else { return nil }
        if let slot = state.slotByMessageID[key], state.records[slot].alive { return slot }
        if key.hasSuffix("@fixture.example"), let id = UInt64(key.dropLast("@fixture.example".count), radix: 16) {
            return state.slotByID[id]
        }
        return nil
    }

    private func newMessageID() -> UInt64 {
        state.nextMessageID += 0x10
        return state.nextMessageID
    }

    private func bump() -> UInt64 {
        state.historyID += 1
        state.generation += 1
        return state.historyID
    }

    /// The bit of a label id, registering an unknown one as a user label named after it.
    private func labelSlot(_ id: String) -> Int {
        if let index = state.labelIndex[id] { return index }
        let index = state.labels.count
        state.labelIndex[id] = index
        state.labels.append(LabelInfo(id: id, name: id, isSystem: false, listVisibility: "labelShow"))
        state.counts.append(Counts())
        return index
    }

    private func newUserLabel(named name: String, visibility: String) -> String {
        var id = "Label_\(state.nextUserLabel)"
        while state.labelIndex[id] != nil {
            state.nextUserLabel += 1
            id = "Label_\(state.nextUserLabel)"
        }
        state.nextUserLabel += 1
        let index = labelSlot(id)
        state.labels[index].name = name
        state.labels[index].listVisibility = visibility
        return id
    }

    private func bits(_ labels: Set<String>) -> LabelBits {
        var out = LabelBits()
        for id in labels { out[labelSlot(id)] = true }
        return out
    }

    private func bitsForIDs(_ ids: [String]) -> LabelBits { bits(Set(ids)) }

    private func labelIDs(_ bits: LabelBits) -> [String] {
        bits.indices.map { state.labels[$0].id }.sorted()
    }

    private func count(_ r: Record, sign: Int) {
        let isUnread = r.labels[FakeGmailMailbox.unread]
        let inSpamTrash = r.labels[FakeGmailMailbox.spam] || r.labels[FakeGmailMailbox.trash]
        if r.labels[FakeGmailMailbox.spam] && r.labels[FakeGmailMailbox.trash] { state.inSpamAndTrash += sign }
        r.labels.forEachIndex { index in
            state.counts[index].total += sign
            if isUnread { state.counts[index].unread += sign }
            if inSpamTrash {
                state.counts[index].totalInSpamTrash += sign
                if isUnread { state.counts[index].unreadInSpamTrash += sign }
            }
        }
    }

    /// Places a message in the order and writes its arrival into the history.
    @discardableResult
    private func insert(id: UInt64, thread: UInt64, labels: LabelBits, date: Date, size: Int, hasAttachment: Bool,
                        content: Content?, recordHistory: Bool = true) -> Int {
        var contentIndex: Int32 = -1
        if let content {
            contentIndex = Int32(state.contents.count)
            state.contents.append(content)
        }
        let history = recordHistory ? bump() : state.historyID
        let record = Record(id: id, thread: thread, labels: labels, date: Int64((date.timeIntervalSince1970 * 1000).rounded()),
                            history: history, size: size, hasAttachment: hasAttachment, content: contentIndex, alive: true)
        let slot = state.records.count
        state.records.append(record)
        state.slotByID[id] = slot
        state.order.insert(slot, at: orderPosition(of: record))
        state.threadMembers[thread, default: []].append(slot)
        if let content { state.slotByMessageID[FakeGmailMailbox.bare(content.messageID)] = slot }
        count(record, sign: 1)
        if recordHistory {
            state.log.append(Change(id: history, kind: .added, message: id, thread: thread, labels: labels))
        } else {
            state.generation += 1
        }
        return slot
    }

    /// Where a record goes in `order`: after every one newer than it.
    private func orderPosition(of record: Record) -> Int {
        var low = 0
        var high = state.order.count
        while low < high {
            let mid = (low + high) / 2
            let other = state.records[state.order[mid]]
            if other.date > record.date || (other.date == record.date && other.id > record.id) { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func remove(_ id: UInt64) {
        guard let slot = state.slotByID.removeValue(forKey: id) else { return }
        let record = state.records[slot]
        let position = orderPosition(of: record)
        if position < state.order.count, state.order[position] == slot {
            state.order.remove(at: position)
        } else {
            state.order.removeAll { $0 == slot }
        }
        count(record, sign: -1)
        state.threadMembers[record.thread]?.removeAll { $0 == slot }
        if state.threadMembers[record.thread]?.isEmpty == true { state.threadMembers[record.thread] = nil }
        if record.content >= 0 {
            let key = FakeGmailMailbox.bare(state.contents[Int(record.content)].messageID)
            if state.slotByMessageID[key] == slot { state.slotByMessageID[key] = nil }
        }
        state.records[slot].alive = false
        let history = bump()
        state.log.append(Change(id: history, kind: .deleted, message: id, thread: record.thread, labels: record.labels))
        state.imported.remove(id)
    }

    /// Adds and removes labels, writing one history record for what really changed, as Gmail does.
    private func applyLabels(_ slot: Int, adding: LabelBits, removing: LabelBits) {
        var record = state.records[slot]
        guard record.alive else { return }
        let added = adding.subtracting(record.labels)
        let removed = removing.subtracting(adding).intersection(record.labels)
        guard !added.isEmpty || !removed.isEmpty else { return }
        count(record, sign: -1)
        record.labels = record.labels.union(added).subtracting(removed)
        record.history = bump()
        state.records[slot] = record
        count(record, sign: 1)
        state.log.append(Change(id: record.history, kind: .labels, message: record.id, thread: record.thread, labels: record.labels,
                                added: added, removed: removed))
    }

    private func content(_ r: Record) -> Content {
        if r.content >= 0 { return state.contents[Int(r.content)] }
        let hex = String(r.id, radix: 16)
        let n = Int(r.id >> 4) % 53
        let attachments = r.hasAttachment
            ? [Attachment(filename: "document-\(hex).pdf", mimeType: "application/pdf", data: Data("attachment of \(hex)".utf8), contentID: nil)]
            : []
        return Content(from: "Sender \(n) <sender\(n)@example.com>", to: email, cc: "", subject: "Fixture message \(hex)",
                       messageID: "<\(hex)@fixture.example>", text: "Text of fixture message \(hex).", html: nil, attachments: attachments,
                       headers: [], raw: nil)
    }

    private func message(at slot: Int) -> Message {
        let r = state.records[slot]
        let c = content(r)
        return Message(id: String(r.id, radix: 16), threadID: threadString(r.thread), labels: Set(labelIDs(r.labels)),
                       date: Date(timeIntervalSince1970: TimeInterval(r.date) / 1000), from: c.from, to: c.to, cc: c.cc,
                       subject: c.subject, messageID: c.messageID, text: c.text, html: c.html, attachments: c.attachments,
                       historyID: r.history, raw: c.raw, headers: allHeaders(c, date: r.date))
    }
}

extension FakeGmailMailbox.LabelBits {
    func intersection(_ o: FakeGmailMailbox.LabelBits) -> FakeGmailMailbox.LabelBits {
        FakeGmailMailbox.LabelBits(words: (words.0 & o.words.0, words.1 & o.words.1, words.2 & o.words.2, words.3 & o.words.3))
    }
}

/// A small seeded generator, so fixtures come out the same on every run.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Fixtures

extension FakeGmailMailbox {
    /// The shape of a fixture mailbox. The counts are exact.
    struct FixtureSpec {
        var total: Int
        var inbox: Int
        var sent: Int
        var unread: Int
        var important: Int
        var starred: Int
        var drafts: Int
        var spam: Int
        var trash: Int
        var chats: Int
        /// User labels, and their memberships in all.
        var userLabels: Int
        var userMemberships: Int
        /// Inbox mail in Social, Promotions, Updates and Forums; the rest of the Inbox is Primary.
        var otherCategories: Int
        /// The share of messages in conversations of two or more.
        var conversationShare: Double = 0.4
        var years: Double = 10
        /// Label names like Outlook folder paths, as olm2cloud makes them.
        var folderPaths = false

        /// The owner's typical account: 55,000 messages.
        static let typical55k = FixtureSpec(total: 55_000, inbox: 20_000, sent: 6_000, unread: 3_000, important: 10_000, starred: 400,
                                            drafts: 20, spam: 300, trash: 700, chats: 0, userLabels: 20, userMemberships: 10_000,
                                            otherCategories: 12_000)
        static let large200k = FixtureSpec(total: 200_000, inbox: 80_000, sent: 20_000, unread: 30_000, important: 40_000,
                                           starred: 2_000, drafts: 50, spam: 1_500, trash: 1_500, chats: 0, userLabels: 40,
                                           userMemberships: 60_000, otherCategories: 50_000)
        /// 200,000 messages migrated from Outlook with 150 labels, one for each folder path.
        static let migrated200k = FixtureSpec(total: 200_000, inbox: 20_000, sent: 30_000, unread: 10_000, important: 60_000,
                                              starred: 1_000, drafts: 20, spam: 500, trash: 1_500, chats: 0, userLabels: 150,
                                              userMemberships: 140_000, otherCategories: 10_000, folderPaths: true)

        /// The same proportions at another size, for tests that need the shape but not the bulk.
        func scaled(to total: Int) -> FixtureSpec {
            let f = Double(total) / Double(self.total)
            func s(_ n: Int) -> Int { Int((Double(n) * f).rounded()) }
            var out = self
            out.total = total
            out.inbox = s(inbox); out.sent = s(sent); out.unread = s(unread); out.important = s(important); out.starred = s(starred)
            out.drafts = s(drafts); out.spam = s(spam); out.trash = s(trash); out.chats = s(chats)
            out.userMemberships = s(userMemberships); out.otherCategories = s(otherCategories)
            return out
        }
    }

    static func fixture(_ spec: FixtureSpec, email: String = "owner@example.com", newest: Date = Date(timeIntervalSince1970: 1_790_000_000),
                        now: @escaping @Sendable () -> Date = { Date() }, seed: UInt64 = 42) -> FakeGmailMailbox {
        let mailbox = FakeGmailMailbox(email: email, now: now)
        mailbox.lock.withLock { mailbox.fill(spec, newest: newest, seed: seed) }
        return mailbox
    }

    static func typical55k(now: @escaping @Sendable () -> Date = { Date() }) -> FakeGmailMailbox { fixture(.typical55k, now: now) }
    static func large200k(now: @escaping @Sendable () -> Date = { Date() }) -> FakeGmailMailbox { fixture(.large200k, now: now) }
    static func migrated200k(now: @escaping @Sendable () -> Date = { Date() }) -> FakeGmailMailbox { fixture(.migrated200k, now: now) }

    /// Fills an empty mailbox, under the lock. The messages are there before any history starts,
    /// as an account's mail is before FalconMail first looks.
    private func fill(_ spec: FixtureSpec, newest: Date, seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let n = spec.total
        let step = spec.years * 365 * 86_400 / Double(max(1, n))
        let newestMs = Int64(newest.timeIntervalSince1970 * 1000)
        let base = state.nextMessageID
        // Index 0 is the newest. Ids and dates both fall with the index, as Gmail's do over time.
        var labels = [LabelBits](repeating: LabelBits(), count: n)
        var threads = [UInt64](repeating: 0, count: n)
        var ids = [UInt64](repeating: 0, count: n)
        for i in 0..<n { ids[i] = base + UInt64(n - i) * 0x10 }
        for i in stride(from: n - 1, through: 0, by: -1) {
            if i + 1 < n, Double(rng.next() % 10_000) / 10_000 < spec.conversationShare {
                let back = 1 + Int(rng.next() % 20)
                threads[i] = threads[min(n - 1, i + back)]
            } else {
                threads[i] = ids[i]
            }
        }
        var pool = Array(0..<n)
        // Picks `k` random places from the front part of `pool` given by `from`, without copying.
        func pick(_ k: Int, from count: Int) -> ArraySlice<Int> {
            let k = min(k, count)
            for j in 0..<k {
                let r = j + Int(rng.next() % UInt64(count - j))
                pool.swapAt(j, r)
            }
            return pool[0..<k]
        }
        func set(_ indices: ArraySlice<Int>, _ label: Int) { for i in indices { labels[i][label] = true } }
        // Spam, trash, chats, drafts and sent take their own messages; the rest arrived.
        pool.shuffle(using: &rng)
        var cursor = 0
        func take(_ k: Int, _ label: Int) -> [Int] {
            let slice = Array(pool[cursor..<min(n, cursor + k)])
            cursor += slice.count
            for i in slice { labels[i][label] = true }
            return slice
        }
        _ = take(spec.spam, FakeGmailMailbox.spam)
        _ = take(spec.trash, FakeGmailMailbox.trash)
        _ = take(spec.chats, FakeGmailMailbox.chat)
        _ = take(spec.drafts, FakeGmailMailbox.draft)
        let sent = take(spec.sent, FakeGmailMailbox.sent)
        let received = Array(pool[cursor...])
        let inbox = Array(received.prefix(spec.inbox))
        for i in inbox { labels[i][FakeGmailMailbox.inbox] = true }
        for i in inbox.prefix(spec.unread) { labels[i][FakeGmailMailbox.unread] = true }
        if spec.unread > inbox.count { for i in received.dropFirst(inbox.count).prefix(spec.unread - inbox.count) { labels[i][FakeGmailMailbox.unread] = true } }
        let others = [FakeGmailMailbox.social, FakeGmailMailbox.promotions, FakeGmailMailbox.updates, FakeGmailMailbox.forums]
        for (j, i) in inbox.enumerated() {
            labels[i][j < spec.otherCategories ? others[j % others.count] : FakeGmailMailbox.personal] = true
        }
        for i in received.dropFirst(inbox.count) { labels[i][FakeGmailMailbox.personal] = true }
        // Important, Starred and user labels come from mail that is neither junk nor deleted.
        pool = received + sent
        let kept = pool.count
        set(pick(spec.important, from: kept), FakeGmailMailbox.important)
        set(pick(spec.starred, from: kept), FakeGmailMailbox.starred)
        if spec.userLabels > 0 {
            let weights = (1...spec.userLabels).map { 1 / Double($0) }
            let sum = weights.reduce(0, +)
            var remaining = spec.userMemberships
            for l in 0..<spec.userLabels {
                let size = l == spec.userLabels - 1 ? remaining : min(remaining, Int((Double(spec.userMemberships) * weights[l] / sum).rounded()))
                remaining -= size
                let name = spec.folderPaths ? "Folders/Group \(l / 10 + 1)/Folder \(l + 1)" : "Label \(l + 1)"
                let id = newUserLabel(named: name, visibility: "labelShow")
                set(pick(size, from: kept), state.labelIndex[id]!)
            }
        }
        state.records.reserveCapacity(state.records.count + n)
        state.order.reserveCapacity(state.order.count + n)
        for i in 0..<n {
            let jitter = Double(rng.next() % 1_000) / 1_000 * step * 0.5
            let date = newestMs - Int64((Double(i) * step + jitter) * 1000)
            let size = 2_000 + Int(rng.next() % 200_000)
            let record = Record(id: ids[i], thread: threads[i], labels: labels[i], date: date, history: state.historyID, size: size,
                                hasAttachment: rng.next() % 5 == 0, content: -1, alive: true)
            state.slotByID[record.id] = state.records.count
            state.threadMembers[record.thread, default: []].append(state.records.count)
            state.order.append(state.records.count)
            state.records.append(record)
            count(record, sign: 1)
        }
        state.nextMessageID = base + UInt64(n + 1) * 0x10
        state.historyID += 1
        state.historyFloor = state.historyID
        state.generation += 1
    }
}
