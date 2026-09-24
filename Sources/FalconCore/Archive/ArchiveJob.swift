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

public enum ArchiveJob {
    /// Every step runs as one unit under the UIDVALIDITY the folder had when it was listed, so
    /// a folder renumbered during a long job is never fetched from, or purged, by stale UIDs.
    /// Only messages that went into the archive are ever removed from the server.
    public static func run(request: ArchiveRequest, account: AccountInfo, client: IMAPClient, storage: ArchiveStorage,
                           progress: @escaping @Sendable (ArchiveProgress) -> Void) async throws -> ArchiveOutcome {
        let writer = ArchiveWriter(storage: storage, parentID: request.parentID, name: request.name, account: account,
                                   options: ArchiveOptions(password: request.password))
        progress(.status("Creating archive folder"))
        try await writer.begin()

        let criteria = request.olderThan.map { "BEFORE \(imapDate($0))" } ?? "ALL"
        var plan: [(path: String, uidValidity: UInt32, uids: [UInt32])] = []
        for path in request.folderPaths {
            progress(.status("Listing \(path)"))
            let listed = try await client.exclusively { c in
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
            var start = 0
            while start < item.uids.count {
                try Task.checkCancellation()
                let batch = Array(item.uids[start..<min(start + 50, item.uids.count)])
                let flags = try await client.withMailbox(item.path, uidValidity: item.uidValidity) {
                    try await $0.fetchFlags(uidRange: IMAPClient.sequenceSet(batch))
                }
                let flagMap = Dictionary(flags.map { ($0.uid, MessageFlags(imapFlags: $0.flags)) }, uniquingKeysWith: { a, _ in a })
                for uid in batch {
                    let raw: Data
                    do {
                        raw = try await client.withMailbox(item.path, uidValidity: item.uidValidity) { try await $0.fetchMessage(uid: uid) }
                    } catch is IMAPMessageMissing {
                        // Deleted since the folder was listed: nothing to archive, and nothing to remove.
                        continue
                    }
                    try await writer.add(ArchiveInput(folderPath: item.path, uid: uid, raw: raw, flags: flagMap[uid] ?? []))
                    archived[item.path, default: []].append(uid)
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
                do {
                    try await client.withMailbox(item.path, uidValidity: item.uidValidity) { try await $0.expunge(uids: uids) }
                } catch let refusal as IMAPExpungeRefused {
                    kept.append(item.path)
                    Log.info("archive", "\(account.email): kept \(item.path) on the server, \(refusal.others.count) other messages there are marked deleted and it has no UIDPLUS")
                } catch is IMAPMailboxRenumbered {
                    kept.append(item.path)
                    Log.info("archive", "\(account.email): kept \(item.path) on the server, it was renumbered during the archive")
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
