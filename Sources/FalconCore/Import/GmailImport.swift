import Foundation

/// Imports .eml and .mbox files into a switched Google account with `messages.import`, never
/// an IMAP APPEND (§9.1).
///
/// `import` rather than `insert`: Gmail puts the message through its normal scanning, which an
/// old mbox deserves; `neverMarkSpam` keeps imported mail out of Junk Email; and dating it by its
/// own Date header sorts it among old mail, not at the top of the Inbox. olm2cloud imports into
/// the same mailboxes the same way.
///
/// Each message goes into the index at once from Gmail's answer, among the mail of its own day,
/// and into the import log, so its echo in the history is never new mail, never starts flood
/// mode and never runs rules or notifications. Imports are background work, at most 60 a minute,
/// and stop at 300 MB of upload in a rolling day, keeping the rest of FalconMail's allowance for
/// sends and drafts; so an import takes whichever is longer, its units or its bytes.
public actor GmailImporter {
    public nonisolated let accountID: UUID
    public nonisolated let email: String
    private let transport: any GmailTransport
    private let store: any GmailStore
    private let placer: (any GmailUploadPlacing)?
    private let allowance: any GmailImportAllowance
    private let jobFile: URL?
    private let perMinute: Int
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var recent: [Date] = []
    /// The newest message received before each day, found once per day an import touches.
    private var neighbours: [Date: GmailMessageID?] = [:]
    private var lastRelisting: Date?

    public static let messagesPerMinute = 60
    /// Gmail takes at most 150 MB in one imported message [S10].
    public static let largestMessage = 150 * 1024 * 1024
    /// A long import has All Mail listed again this often, as well as when it ends.
    static let relistingInterval: TimeInterval = 24 * 3600

    public init(accountID: UUID, email: String, transport: any GmailTransport, store: any GmailStore,
                placer: (any GmailUploadPlacing)? = nil, allowance: any GmailImportAllowance, jobFile: URL? = nil,
                perMinute: Int = GmailImporter.messagesPerMinute, now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
                    try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                }) {
        self.accountID = accountID
        self.email = email
        self.transport = transport
        self.store = store
        self.placer = placer
        self.allowance = allowance
        self.jobFile = jobFile
        self.perMinute = max(1, perMinute)
        self.now = now
        self.sleep = sleep
    }

    // MARK: - Before it starts

    /// What an import will take, for the sheet to say before it starts.
    public static func estimate(_ messages: [ImportedMessage], perMinute: Int = messagesPerMinute,
                                bytesPerDay: Int = RollingImportAllowance.dailyLimit) -> GmailImportEstimate {
        estimate(count: messages.count, bytes: messages.reduce(0) { $0 + $1.raw.count }, perMinute: perMinute, bytesPerDay: bytesPerDay)
    }

    public static func estimate(count: Int, bytes: Int, perMinute: Int = messagesPerMinute,
                                bytesPerDay: Int = RollingImportAllowance.dailyLimit) -> GmailImportEstimate {
        GmailImportEstimate(messages: count, bytes: bytes, units: count * GmailMethod.messagesImport.units,
                            byUnits: TimeInterval(count) / TimeInterval(max(1, perMinute)) * 60,
                            byBytes: TimeInterval(bytes) / TimeInterval(max(1, bytesPerDay)) * 86_400)
    }

    // MARK: - Importing

    /// Imports `messages` into the folder of `label`: Archive (All Mail) when nil. Not saved
    /// as a job, so a quit ends it; files imported through `run(files:)` resume instead.
    public func run(_ messages: [ImportedMessage], into label: GmailLabelID?,
                    progress: @escaping @Sendable (GmailImportProgress) -> Void = { _ in }) async throws -> GmailImportOutcome {
        var outcome = GmailImportOutcome()
        outcome.startedAt = now()
        for (i, message) in messages.enumerated() {
            try Task.checkCancellation()
            try await importOne(message, into: label, index: i, outcome: &outcome) { _ in }
            progress(.imported(done: i + 1, total: messages.count))
        }
        await ended(outcome)
        return outcome
    }

    /// Imports the messages of .eml and .mbox files, as File ▸ Import does. The job is saved
    /// after every message, so after a quit or a crash `resume` carries on where it stopped,
    /// and a message whose upload was on its way then is looked for before it is sent again.
    public func run(files urls: [URL], into label: GmailLabelID?,
                    progress: @escaping @Sendable (GmailImportProgress) -> Void = { _ in }) async throws -> GmailImportOutcome {
        let job = GmailImportJob(id: UUID(), files: urls.map(\.path), label: label, done: 0, startedAt: now())
        try saveJob(job)
        return try await carryOn(job, progress: progress)
    }

    /// Carries on with the import a quit or a crash left, if there was one.
    public func resume(progress: @escaping @Sendable (GmailImportProgress) -> Void = { _ in }) async throws -> GmailImportOutcome? {
        guard let job = unfinishedJob() else { return nil }
        return try await carryOn(job, progress: progress)
    }

    /// The import left unfinished, for the sheet to offer.
    public nonisolated func unfinishedJob() -> GmailImportJob? {
        jobFile.flatMap { AtomicFile.readJSON(GmailImportJob.self, from: $0) }
    }

    private func carryOn(_ start: GmailImportJob, progress: @escaping @Sendable (GmailImportProgress) -> Void) async throws -> GmailImportOutcome {
        var job = start
        var outcome = GmailImportOutcome()
        outcome.startedAt = now()
        var messages: [ImportedMessage] = []
        for path in job.files {
            let url = URL(fileURLWithPath: path)
            do {
                messages += url.pathExtension.lowercased() == "mbox"
                    ? MboxReader.messages(in: try Data(contentsOf: url)) : [try EMLImport.message(at: url)]
            } catch {
                Log.error("Import", "Reading a .\(url.pathExtension.lowercased()) file to import into Gmail failed: \(error.localizedDescription)",
                          error: error, names: [url.lastPathComponent, url.deletingPathExtension().lastPathComponent])
                outcome.failures.append(GmailImportFailure(index: nil, sentence: "\(url.lastPathComponent) could not be read."))
            }
        }
        if let inFlight = job.inFlight, inFlight.index < messages.count {
            // The upload was on its way when FalconMail stopped: Gmail may have it already.
            if try await alreadyImported(messageID: inFlight.messageID, message: messages[inFlight.index], label: job.label,
                                         outcome: &outcome) {
                job.done = inFlight.index + 1
            }
            job.inFlight = nil
            try saveJob(job)
        }
        while job.done < messages.count {
            try Task.checkCancellation()
            let index = job.done
            let before = job
            try await importOne(messages[index], into: job.label, index: index, outcome: &outcome) { messageID in
                // On disk before the upload, so a crash during it is looked for, not imported twice.
                var marked = before
                marked.inFlight = GmailImportJob.InFlight(index: index, messageID: messageID)
                try self.saveJob(marked)
            }
            job.done += 1
            job.inFlight = nil
            try saveJob(job)
            progress(.imported(done: job.done, total: messages.count))
        }
        clearJob()
        await ended(outcome)
        return outcome
    }

    /// One message: paced, uploaded, logged as FalconMail's own, and placed. A message Gmail
    /// refuses is noted and passed over, so one bad message never stops the rest; waiting for
    /// Gmail or for the day's allowance is not a failure.
    private func importOne(_ message: ImportedMessage, into label: GmailLabelID?, index: Int, outcome: inout GmailImportOutcome,
                           beforeUpload: (String?) throws -> Void) async throws {
        guard message.raw.count <= GmailImporter.largestMessage else {
            outcome.failures.append(GmailImportFailure(index: index, sentence: "A message of more than 150 MB can't be imported into Gmail."))
            return
        }
        let labels = GmailImporter.labels(for: message, into: label)
        let headers = MIMEParser.parseHeaders(message.raw)
        let messageID = AddressParser.messageIDs(headers.first("Message-ID")).first
        let date = message.date ?? headers.first("Date").flatMap(RFC5322Date.parse) ?? now()
        var tries = 0
        while true {
            try await pace(bytes: message.raw.count)
            try beforeUpload(messageID)
            do {
                let answer = try await transport.importMessage(message.raw, labels: labels, options: GmailImportOptions(),
                                                               work: .background(.transfer))
                await allowance.record(message.raw.count)
                recent.append(now())
                try await placed(answer, labels: labels, date: date, outcome: &outcome)
                return
            } catch let refusal as GoogleAPIError {
                let mayHaveGone = refusal.kind == .temporary
                    || (refusal.kind == .other && (refusal.httpStatus == 0 || refusal.httpStatus >= 500))
                if refusal.kind == .offline || mayHaveGone {
                    // Tried again after a pause; an upload that may have gone is looked for
                    // first, so it is not imported twice.
                    tries += 1
                    if mayHaveGone, try await alreadyImported(messageID: messageID, message: message, label: label, outcome: &outcome) {
                        return
                    }
                    guard tries < 5 else { throw refusal }
                    try await sleep(min(64, pow(2, Double(tries))))
                    continue
                }
                switch refusal.kind {
                case .rateLimited, .uploadLimit, .downloadLimit, .quotaExhausted, .apiDisabled:
                    // Gmail refused it for now, so nothing was imported: it goes again later.
                    let until = refusal.kind == .quotaExhausted
                        ? GoogleAPIError.quotaReset(after: now()) : now().addingTimeInterval(refusal.retryAfter ?? 60)
                    try await wait(until: until, reason: .gmail(refusal.kind))
                case .needsSignIn, .clientRejected, .insufficientPermissions, .domainPolicy, .gmailNotEnabled:
                    throw refusal
                default:
                    Log.warning("Import", "\(email): Gmail refused an imported message: \(refusal.kind.rawValue)", error: refusal)
                    outcome.failures.append(GmailImportFailure(index: index, sentence: refusal.kind == .tooLarge
                        ? "Gmail refused a message as too large to import." : "Gmail refused a message. Details are in the log."))
                    return
                }
            }
        }
    }

    /// Whether a message whose upload may have gone is in Gmail already, looked for by its
    /// Message-ID. Found, it is logged and placed as if its answer had come.
    private func alreadyImported(messageID: String?, message: ImportedMessage, label: GmailLabelID?,
                                 outcome: inout GmailImportOutcome) async throws -> Bool {
        guard let wanted = GmailSender.bare(messageID) else { return false }
        let query = GmailListQuery(labels: label.map { [$0] } ?? [], query: "rfc822msgid:\(wanted)", includeSpamTrash: true, maxResults: 10)
        let page = try await transport.list(query, work: .background(.transfer))
        guard let ref = page.refs.first else { return false }
        let labels = GmailImporter.labels(for: message, into: label)
        let found = GmailMessage(id: ref.id.hex, threadId: ref.threadID.hex, labelIds: labels.map(\.value).sorted())
        let date = message.date ?? MIMEParser.parseHeaders(message.raw).first("Date").flatMap(RFC5322Date.parse) ?? now()
        try await placed(found, labels: labels, date: date, outcome: &outcome)
        return true
    }

    private func placed(_ answer: GmailMessage, labels: Set<GmailLabelID>, date: Date, outcome: inout GmailImportOutcome) async throws {
        guard let id = GmailMessageID.fromGmail(answer.id, in: "messages.import") else { return }
        // Logged before anything else can see the message, so its echo is never new mail.
        try await store.noteImported([id], at: now())
        outcome.imported += 1
        outcome.ids.append(id)
        let neighbour = try await neighbour(before: date)
        await placer?.placeImported(answer, labels: answer.labels.isEmpty ? labels : answer.labels, date: date, above: neighbour)
        if let last = lastRelisting ?? outcome.startedAt, now().timeIntervalSince(last) >= GmailImporter.relistingInterval {
            lastRelisting = now()
            await placer?.importEnded()
        }
    }

    /// The newest message received before the day of `date`, which the index already holds:
    /// one `before:` search a day, exact to the day.
    private func neighbour(before date: Date) async throws -> GmailMessageID? {
        let day = Calendar.current.startOfDay(for: date)
        if let known = neighbours[day] { return known }
        let query = GmailListQuery(query: "before:\(Int(day.timeIntervalSince1970))", includeSpamTrash: true, maxResults: 1)
        let found = try await transport.list(query, work: .background(.transfer)).refs.first?.id
        neighbours[day] = found
        return found
    }

    private func ended(_ outcome: GmailImportOutcome) async {
        neighbours = [:]
        lastRelisting = nil
        if outcome.imported > 0 { await placer?.importEnded() }
    }

    // MARK: - Pace

    /// At most `perMinute` a minute, and only while the rolling day's upload allowance has room.
    private func pace(bytes: Int) async throws {
        let when = await allowance.whenAllows(bytes)
        if when > now() { try await wait(until: when, reason: .uploadAllowance) }
        recent.removeAll { now().timeIntervalSince($0) >= 60 }
        if recent.count >= perMinute, let oldest = recent.first {
            try await sleep(max(0, 60 - now().timeIntervalSince(oldest)))
            recent.removeAll { now().timeIntervalSince($0) >= 60 }
        }
    }

    private var waitReporter: (@Sendable (GmailImportProgress) -> Void)?

    private func wait(until date: Date, reason: GmailImportProgress.WaitReason) async throws {
        waitReporter?(.waiting(until: date, reason: reason))
        let seconds = date.timeIntervalSince(now())
        if seconds > 0 { try await sleep(seconds) }
    }

    /// Tells `progress` about waits as well as messages imported.
    public func reportWaits(to progress: @escaping @Sendable (GmailImportProgress) -> Void) {
        waitReporter = progress
    }

    // MARK: - Labels

    /// The folder's label, plus INBOX for the Inbox (the label itself). Mail comes in read
    /// unless an mbox's Status header says it was not (open question 7), and flagged mail is
    /// starred, as Outlook's flag is Gmail's star.
    static func labels(for message: ImportedMessage, into label: GmailLabelID?) -> Set<GmailLabelID> {
        var labels: Set<GmailLabelID> = label.map { [$0] } ?? []
        let headers = MIMEParser.parseHeaders(message.raw)
        let hasStatus = headers.first("Status") != nil || headers.first("X-Status") != nil
        if hasStatus && !message.flags.contains(.seen) { labels.insert(.unread) }
        if message.flags.contains(.flagged) { labels.insert(.starred) }
        return labels
    }

    // MARK: - The job on disk

    private func saveJob(_ job: GmailImportJob) throws {
        guard let jobFile else { return }
        try AtomicFile.writeJSON(job, to: jobFile)
    }

    private func clearJob() {
        guard let jobFile else { return }
        try? FileManager.default.removeItem(at: jobFile)
    }
}

extension GmailFiles {
    /// An import into Gmail left unfinished, which carries on where it stopped.
    public var importJob: URL { directory.appendingPathComponent("importJob.json") }
    /// What imports uploaded over the last day, for their share of the upload allowance.
    public var importBytes: URL { directory.appendingPathComponent("importBytes.json") }
}

/// What an import takes, which the sheet says before it starts: whichever is longer of the
/// time its units take at 60 a minute and the time its bytes take at 300 MB a day, about 3½
/// days per GB.
public struct GmailImportEstimate: Sendable, Equatable {
    public var messages: Int
    public var bytes: Int
    public var units: Int
    public var byUnits: TimeInterval
    public var byBytes: TimeInterval

    public var duration: TimeInterval { max(byUnits, byBytes) }
    public var isBoundByBytes: Bool { byBytes > byUnits }
}

public enum GmailImportProgress: Sendable, Equatable {
    public enum WaitReason: Sendable, Equatable {
        /// The rolling day's 300 MB for imports is used up.
        case uploadAllowance
        /// Gmail asked FalconMail to wait.
        case gmail(GoogleAPIError.Kind)
    }

    case imported(done: Int, total: Int)
    case waiting(until: Date, reason: WaitReason)
}

public struct GmailImportOutcome: Sendable {
    public var imported = 0
    public var ids: [GmailMessageID] = []
    public var failures: [GmailImportFailure] = []
    var startedAt: Date?

    public init() {}
}

public struct GmailImportFailure: Sendable, Equatable {
    /// Which message it was, in the order the files hold them; nil for a whole file.
    public var index: Int?
    public var sentence: String
}

/// An import saved after every message, so it carries on after a quit or a crash.
public struct GmailImportJob: Codable, Sendable, Equatable {
    public struct InFlight: Codable, Sendable, Equatable {
        public var index: Int
        public var messageID: String?
    }

    public var id: UUID
    public var files: [String]
    public var label: GmailLabelID?
    /// Messages done, in the order the files hold them.
    public var done: Int
    /// The message whose upload was on its way, which Gmail may already have.
    public var inFlight: InFlight?
    public var startedAt: Date
}

/// The import's share of the account's daily upload allowance (§11.2). FalconMail keeps
/// 400 MB a day of Gmail's inferred 500 for itself; imports take at most 300 of it, so sends
/// and drafts always have room. G1's traffic meter can stand in for the rolling ledger below.
public protocol GmailImportAllowance: Sendable {
    /// When `bytes` more may be imported: now, or when the rolling day has room.
    func whenAllows(_ bytes: Int) async -> Date
    func record(_ bytes: Int) async
}

/// A rolling 24-hour ledger of import uploads, kept in a small file so a relaunch does not
/// forget the day's uploads.
public actor RollingImportAllowance: GmailImportAllowance {
    public static let dailyLimit = 300 * 1024 * 1024

    private struct Entry: Codable {
        var at: Date
        var bytes: Int
    }

    private let limit: Int
    private let file: URL?
    private let now: @Sendable () -> Date
    private var ledger: [Entry]

    public init(limit: Int = RollingImportAllowance.dailyLimit, file: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.limit = limit
        self.file = file
        self.now = now
        ledger = file.flatMap { AtomicFile.readJSON([Entry].self, from: $0) } ?? []
    }

    public func whenAllows(_ bytes: Int) -> Date {
        let current = now()
        ledger.removeAll { current.timeIntervalSince($0.at) >= 86_400 }
        var used = ledger.reduce(0) { $0 + $1.bytes }
        guard used + bytes > limit else { return current }
        // Each upload leaves the day 24 hours after it was made.
        for entry in ledger.sorted(by: { $0.at < $1.at }) {
            used -= entry.bytes
            if used + bytes <= limit || used <= 0 { return entry.at.addingTimeInterval(86_400) }
        }
        return current
    }

    public func record(_ bytes: Int) {
        ledger.append(Entry(at: now(), bytes: bytes))
        if let file { try? AtomicFile.writeJSON(ledger, to: file) }
    }

    public func used() -> Int {
        let current = now()
        return ledger.filter { current.timeIntervalSince($0.at) < 86_400 }.reduce(0) { $0 + $1.bytes }
    }
}
