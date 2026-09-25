import Foundation

public struct ArchiveRequest: Sendable {
    public var accountID: UUID
    public var folderPaths: [String]
    public var olderThan: Date?
    public var name: String
    public var password: String?
    public var removeFromServer: Bool
    public var parentID: String?

    public init(accountID: UUID, folderPaths: [String], olderThan: Date?, name: String, password: String?, removeFromServer: Bool, parentID: String?) {
        self.accountID = accountID
        self.folderPaths = folderPaths
        self.olderThan = olderThan
        self.name = name
        self.password = password
        self.removeFromServer = removeFromServer
        self.parentID = parentID
    }
}

public enum ArchiveProgress: Sendable {
    case status(String)
    case count(done: Int, total: Int, bytes: Int)
    case finished(ArchiveManifest, rootID: String)
    case failed(String)
}

/// What an archive job did. Folders in `keptOnServer` were archived but left on the server,
/// because removing their messages there was not safe.
public struct ArchiveOutcome: Sendable {
    public var manifest: ArchiveManifest
    public var rootID: String
    public var keptOnServer: [String]
}

/// Where an archive job reads an account's mail from, and how it takes archived mail off the
/// server: an IMAP account's folders (`ArchiveSource`), or a switched Google account's labels
/// through the Gmail API (`GmailArchiveSource`). Each lists, downloads and removes in its own
/// terms; the archive written is the same, and only messages that went into it are removed.
public protocol ArchiveMailSource: Sendable {
    func archive(request: ArchiveRequest, account: AccountInfo, storage: ArchiveStorage,
                 progress: @escaping @Sendable (ArchiveProgress) -> Void) async throws -> ArchiveOutcome
}

/// What an archive job needs of an IMAP account; `AccountSyncer.archiveSource` gives it.
public struct ArchiveSource: ArchiveMailSource {
    /// Opens and signs in a connection for the job alone.
    public var connect: @Sendable () async throws -> IMAPClient
    /// Holds the job while the account may not download `bytes` more in the background, or
    /// Gmail has asked for quiet; true when it did.
    public var allowance: @Sendable (_ bytes: Int) async throws -> Bool
    /// Hears of a failure on the job's connection, and returns it as the owner should see it.
    public var failed: @Sendable (Error) async -> Error

    public init(connect: @escaping @Sendable () async throws -> IMAPClient,
                allowance: @escaping @Sendable (_ bytes: Int) async throws -> Bool,
                failed: @escaping @Sendable (Error) async -> Error) {
        self.connect = connect
        self.allowance = allowance
        self.failed = failed
    }

    public func archive(request: ArchiveRequest, account: AccountInfo, storage: ArchiveStorage,
                        progress: @escaping @Sendable (ArchiveProgress) -> Void) async throws -> ArchiveOutcome {
        try await ArchiveJob.run(request: request, account: account, source: self, storage: storage, progress: progress)
    }
}

public enum ArchiveJob {
    /// Runs the job on whichever source the account's engine gives.
    public static func run(request: ArchiveRequest, account: AccountInfo, source: any ArchiveMailSource, storage: ArchiveStorage,
                           progress: @escaping @Sendable (ArchiveProgress) -> Void) async throws -> ArchiveOutcome {
        try await source.archive(request: request, account: account, storage: storage, progress: progress)
    }

    /// Every step runs as one unit under the UIDVALIDITY the folder had when it was listed, so
    /// a folder renumbered during a long job is never fetched from, or purged, by stale UIDs.
    /// Only messages that went into the archive are ever removed from the server. Before each
    /// step the job asks for its allowance, which holds it while the account's background
    /// allowance is spent or Gmail has asked for quiet, and it carries on where it stopped.
    public static func run(request: ArchiveRequest, account: AccountInfo, source: ArchiveSource, storage: ArchiveStorage,
                           progress: @escaping @Sendable (ArchiveProgress) -> Void) async throws -> ArchiveOutcome {
        let link = ArchiveLink(source: source)
        do {
            let outcome = try await archive(request: request, account: account, link: link, storage: storage, progress: progress)
            await link.close()
            return outcome
        } catch {
            await link.close()
            throw error
        }
    }

    private static func archive(request: ArchiveRequest, account: AccountInfo, link: ArchiveLink, storage: ArchiveStorage,
                                progress: @escaping @Sendable (ArchiveProgress) -> Void) async throws -> ArchiveOutcome {
        let writer = ArchiveWriter(storage: storage, parentID: request.parentID, name: request.name, account: account,
                                   options: ArchiveOptions(password: request.password))
        progress(.status("Creating archive folder"))
        try await writer.begin()

        let criteria = request.olderThan.map { "BEFORE \(imapDate($0))" } ?? "ALL"
        var plan: [(path: String, uidValidity: UInt32, uids: [UInt32])] = []
        for path in request.folderPaths {
            progress(.status("Listing \(path)"))
            let listed = try await link.step { c in
                let status = try await c.select(path)
                return (status.uidValidity, try await c.uidSearch(criteria))
            }
            plan.append((path, listed.0, listed.1))
        }
        let total = plan.reduce(0) { $0 + $1.uids.count }
        var done = 0
        var bytes = 0
        var archived: [String: [UInt32]] = [:]
        for item in plan {
            let path = item.path
            let validity = item.uidValidity
            var start = 0
            while start < item.uids.count {
                try Task.checkCancellation()
                let batch = Array(item.uids[start..<min(start + 50, item.uids.count)])
                let listed = try await link.step { c in
                    try await c.withMailbox(path, uidValidity: validity) { try await $0.fetchFlagsAndSizes(uids: batch) }
                }
                let flagMap = Dictionary(listed.map { ($0.uid, MessageFlags(imapFlags: $0.flags)) }, uniquingKeysWith: { a, _ in a })
                let sizes = Dictionary(listed.map { ($0.uid, $0.size) }, uniquingKeysWith: { a, _ in a })
                for uid in batch {
                    let raw: Data
                    do {
                        raw = try await link.step(bytes: sizes[uid] ?? 0) { c in
                            try await c.withMailbox(path, uidValidity: validity) { try await $0.fetchMessage(uid: uid) }
                        }
                    } catch is IMAPMessageMissing {
                        // Deleted since the folder was listed: nothing to archive, and nothing to remove.
                        continue
                    }
                    try await writer.add(ArchiveInput(folderPath: path, uid: uid, raw: raw, flags: flagMap[uid] ?? []))
                    archived[path, default: []].append(uid)
                    done += 1
                    bytes += raw.count
                    if done % 10 == 0 || done == total { progress(.count(done: done, total: total, bytes: bytes)) }
                }
                start += 50
            }
        }
        progress(.status("Writing index and manifest"))
        let manifest = try await writer.finish()
        let rootID = await writer.rootFolderID

        var kept: [String] = []
        if request.removeFromServer {
            for item in plan {
                guard let uids = archived[item.path], !uids.isEmpty else { continue }
                progress(.status("Removing archived mail from \(item.path)"))
                let path = item.path
                let validity = item.uidValidity
                do {
                    try await link.step { c in try await c.withMailbox(path, uidValidity: validity) { try await $0.expunge(uids: uids) } }
                } catch let refusal as IMAPExpungeRefused {
                    kept.append(item.path)
                    Log.failure("Archive", MailServiceError.classify(refusal, account: account),
                                "\(account.email): kept \(item.path) on the server, \(refusal.others.count) other messages there are marked deleted and it has no UIDPLUS",
                                level: .warning, account: account, names: [item.path], logAs: "archive")
                } catch let renumbered as IMAPMailboxRenumbered {
                    kept.append(item.path)
                    Log.failure("Archive", MailServiceError.classify(renumbered, account: account),
                                "\(account.email): kept \(item.path) on the server, it was renumbered during the archive",
                                account: account, names: [item.path], logAs: "archive")
                }
            }
        }
        progress(.finished(manifest, rootID: rootID))
        return ArchiveOutcome(manifest: manifest, rootID: rootID, keptOnServer: kept)
    }

    static func imapDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "d-MMM-yyyy"
        return f.string(from: date)
    }
}

/// The job's connection: opened when first needed, and again after any wait for the allowance,
/// since one left quiet that long may have been closed, and after the last one was lost.
/// A step that met a dropped connection or a throttle is repeated on a new one once its pause
/// is over: each step selects its folder and names its messages by UID, so repeating one does
/// nothing twice.
private actor ArchiveLink {
    private let source: ArchiveSource
    private var client: IMAPClient?
    /// Tries of one step before the job gives up: enough for a stale connection and a throttle
    /// or two, and never a loop that cannot end.
    private static let attempts = 3

    init(source: ArchiveSource) {
        self.source = source
    }

    func step<T: Sendable>(bytes: Int = 0, _ work: @Sendable (IMAPClient) async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            attempt += 1
            if try await source.allowance(bytes) { await close() }
            do {
                let c: IMAPClient
                if let open = client {
                    c = open
                } else {
                    c = try await source.connect()
                    client = c
                }
                return try await c.exclusively(work)
            } catch {
                // What the job itself answers, and a connection that is still good.
                if error is IMAPMessageMissing || error is IMAPExpungeRefused || error is IMAPMailboxRenumbered || error is CancellationError {
                    throw error
                }
                await close()
                // A failure to connect was reported when it happened.
                let failure = error is MailServiceError ? error : await source.failed(error)
                guard attempt < ArchiveLink.attempts, (failure as? MailServiceError)?.isTransient ?? false,
                      !Task.isCancelled else { throw failure }
            }
        }
    }

    func close() async {
        guard let c = client else { return }
        client = nil
        await c.logout()
    }
}
