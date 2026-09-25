import Foundation

/// The archive job's source for a switched Google account: its folders are Gmail labels, read
/// through the Gmail API (§9.2).
///
/// Each chosen folder is listed with one `before:` search in epoch seconds, which Gmail reads
/// exactly, and each message comes as `format=raw` into the same archive an IMAP account's job
/// writes. It is background work: at most 60 messages a minute, holding at the account's
/// background download allowance, and carrying on where it stopped after any wait.
///
/// "Remove from Gmail after archiving" does what v1.10.0's expunge does on Gmail: the message
/// leaves the archived folder only. Archiving a label removes that label, and archiving the
/// Inbox removes INBOX; the message stays in Archive (All Mail) and its other folders. Only
/// archiving Archive itself moves messages to Deleted Items, where Gmail deletes them after 30
/// days. Nothing is deleted for good, and nothing is removed before the archive is written.
public struct GmailArchiveSource: ArchiveMailSource {
    public let transport: any GmailTransport
    /// The label each folder the owner can choose stands for, by the path the request names
    /// it by. Archive (All Mail) has no label, so it maps to nil.
    public let folders: [String: GmailLabelID?]
    /// Holds the job while the account may not download `bytes` more in the background; true
    /// when it waited.
    public let allowance: @Sendable (_ bytes: Int) async throws -> Bool
    public let perMinute: Int
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    /// Ten `format=raw` parts a batch, as for any background download of whole messages.
    static let batchSize = 10
    /// `batchModify` takes at most 1,000 ids.
    static let removalPage = 1_000

    public init(transport: any GmailTransport, folders: [String: GmailLabelID?],
                allowance: @escaping @Sendable (_ bytes: Int) async throws -> Bool, perMinute: Int = 60,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void) {
        self.transport = transport
        self.folders = folders
        self.allowance = allowance
        self.perMinute = max(1, perMinute)
        self.now = now
        self.sleep = sleep
    }

    public func archive(request: ArchiveRequest, account: AccountInfo, storage: ArchiveStorage,
                        progress: @escaping @Sendable (ArchiveProgress) -> Void) async throws -> ArchiveOutcome {
        let writer = ArchiveWriter(storage: storage, parentID: request.parentID, name: request.name, account: account,
                                   options: ArchiveOptions(password: request.password))
        progress(.status("Creating archive folder"))
        try await writer.begin()

        var plan: [(path: String, label: GmailLabelID?, ids: [GmailMessageID])] = []
        for path in request.folderPaths {
            guard let label = folders[path] else {
                throw MailServiceError(kind: .folderGone, account: account, detail: "no Gmail label for an archived folder", name: path)
            }
            progress(.status("Listing \(path)"))
            plan.append((path, label, try await list(label, olderThan: request.olderThan)))
        }
        let total = plan.reduce(0) { $0 + $1.ids.count }
        var done = 0
        var bytes = 0
        var archived: [String: [GmailMessageID]] = [:]
        var pace = Pace(perMinute: perMinute, now: now, sleep: sleep)
        var lastBatchBytes = 0
        for item in plan {
            var uid: UInt32 = 0
            var start = 0
            while start < item.ids.count {
                try Task.checkCancellation()
                let batch = Array(item.ids[start..<min(start + GmailArchiveSource.batchSize, item.ids.count)])
                _ = try await allowance(lastBatchBytes)
                try await pace.admit(batch.count)
                let messages = try await download(batch)
                lastBatchBytes = 0
                for id in batch {
                    // Deleted since the folder was listed: nothing to archive, and nothing to remove.
                    guard let message = messages[id], let raw = message.rawData else { continue }
                    uid += 1
                    try await writer.add(ArchiveInput(folderPath: item.path, uid: uid, raw: raw, flags: GmailArchiveSource.flags(message)))
                    archived[item.path, default: []].append(id)
                    done += 1
                    bytes += raw.count
                    lastBatchBytes += raw.count
                    if done % 10 == 0 || done == total { progress(.count(done: done, total: total, bytes: bytes)) }
                }
                start += GmailArchiveSource.batchSize
            }
        }
        progress(.status("Writing index and manifest"))
        let manifest = try await writer.finish()
        let rootID = await writer.rootFolderID

        var kept: [String] = []
        if request.removeFromServer {
            for item in plan {
                guard let ids = archived[item.path], !ids.isEmpty else { continue }
                guard let removal = GmailArchiveSource.removal(for: item.label) else {
                    // Gmail would refuse it, or taking the label off would bring the mail back
                    // rather than remove it: left as it is.
                    kept.append(item.path)
                    Log.info("archive", "\(account.email): kept an archived folder on Gmail, as removing its label would not remove its mail")
                    continue
                }
                progress(.status("Removing archived mail from \(item.path)"))
                do {
                    var start = 0
                    while start < ids.count {
                        let page = Array(ids[start..<min(start + GmailArchiveSource.removalPage, ids.count)])
                        try await transport.batchModify(page, adding: removal.adding, removing: removal.removing, work: .background(.transfer))
                        start += GmailArchiveSource.removalPage
                    }
                } catch {
                    kept.append(item.path)
                    Log.warning("Archive", "\(account.email): kept archived mail on Gmail, which refused to remove it", error: error,
                                account: account, names: [item.path], logAs: "archive")
                }
            }
        }
        progress(.finished(manifest, rootID: rootID))
        return ArchiveOutcome(manifest: manifest, rootID: rootID, keptOnServer: kept)
    }

    // MARK: - Listing and downloading

    /// Every message of the folder received before `olderThan`, newest first, 500 ids a page.
    private func list(_ label: GmailLabelID?, olderThan: Date?) async throws -> [GmailMessageID] {
        var ids: [GmailMessageID] = []
        var token: String?
        let spamOrTrash = label == .spam || label == .trash
        repeat {
            let query = GmailListQuery(labels: label.map { [$0] } ?? [], query: olderThan.map { "before:\(Int($0.timeIntervalSince1970))" },
                                       includeSpamTrash: spamOrTrash, maxResults: 500, pageToken: token)
            let page = try await step { try await transport.list(query, work: .background(.transfer)) }
            ids += page.refs.map(\.id)
            token = page.nextPageToken
        } while token != nil
        var seen = Set<GmailMessageID>()
        return ids.filter { seen.insert($0).inserted }
    }

    private func download(_ ids: [GmailMessageID]) async throws -> [GmailMessageID: GmailMessage] {
        let parts = ids.map { GmailBatchPart.message($0, .raw) }
        let answers = try await step { try await transport.batch(parts, work: .background(.transfer)) }
        var out: [GmailMessageID: GmailMessage] = [:]
        for (id, part) in zip(ids, parts) {
            switch answers[part] {
            case .success(let answer)?:
                out[id] = answer.message
            case .failure(let refusal)? where refusal.kind == .notFound:
                continue
            case .failure(let refusal)?:
                throw refusal
            case nil:
                throw GoogleAPIError(kind: .other, detail: "a batch part went unanswered")
            }
        }
        return out
    }

    /// One call, carried on after what only means waiting: a pause Gmail asks for is waited
    /// out however long it is, as the IMAP job waits at its allowance, and a dropped connection
    /// is tried twice more. Every call here only reads, so repeating one does nothing twice.
    private func step<T>(_ call: () async throws -> T) async throws -> T {
        var failures = 0
        while true {
            do {
                return try await call()
            } catch let refusal as GoogleAPIError {
                switch refusal.kind {
                case .rateLimited, .downloadLimit:
                    try await sleep(max(1, refusal.retryAfter ?? 60))
                case .quotaExhausted:
                    try await sleep(max(1, GoogleAPIError.quotaReset(after: now()).timeIntervalSince(now())))
                case .offline, .temporary:
                    failures += 1
                    guard failures < 3 else { throw refusal }
                    try await sleep(pow(2, Double(failures)))
                default:
                    throw refusal
                }
            }
        }
    }

    // MARK: - Flags and removal

    static func flags(_ message: GmailMessage) -> MessageFlags {
        let labels = message.labels
        var flags = MessageFlags()
        if !labels.contains(.unread) { flags.insert(.seen) }
        if labels.contains(.starred) { flags.insert(.flagged) }
        if labels.contains(.draft) { flags.insert(.draft) }
        return flags
    }

    /// What taking archived mail out of a folder asks of Gmail, or nil where it must stay: Sent
    /// and Drafts, whose labels Gmail refuses to change, and Deleted Items and Junk Email,
    /// where taking the label off would bring the mail back instead of removing it.
    static func removal(for label: GmailLabelID?) -> (adding: Set<GmailLabelID>, removing: Set<GmailLabelID>)? {
        guard let label else { return ([.trash], []) }
        if GmailLabelID.fixedByGmail.contains(label) || label == .trash || label == .spam { return nil }
        return ([], [label])
    }
}

/// At most `perMinute` messages in any minute.
private struct Pace {
    let perMinute: Int
    let now: @Sendable () -> Date
    let sleep: @Sendable (TimeInterval) async throws -> Void
    private var admitted: [Date] = []

    init(perMinute: Int, now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (TimeInterval) async throws -> Void) {
        self.perMinute = perMinute
        self.now = now
        self.sleep = sleep
    }

    mutating func admit(_ count: Int) async throws {
        admitted.removeAll { now().timeIntervalSince($0) >= 60 }
        while admitted.count + count > perMinute, let oldest = admitted.first {
            try await sleep(max(0.01, 60 - now().timeIntervalSince(oldest)))
            admitted.removeAll { now().timeIntervalSince($0) >= 60 }
        }
        admitted += Array(repeating: now(), count: count)
    }
}
