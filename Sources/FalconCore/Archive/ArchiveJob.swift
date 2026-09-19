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

public enum ArchiveJob {
    public static func run(request: ArchiveRequest, account: AccountInfo, client: IMAPClient, storage: ArchiveStorage,
                           progress: @escaping @Sendable (ArchiveProgress) -> Void) async throws -> (ArchiveManifest, String) {
        let writer = ArchiveWriter(storage: storage, parentID: request.parentID, name: request.name, account: account,
                                   options: ArchiveOptions(password: request.password))
        progress(.status("Creating archive folder"))
        try await writer.begin()

        var plan: [(path: String, uids: [UInt32])] = []
        for path in request.folderPaths {
            progress(.status("Listing \(path)"))
            _ = try await client.select(path)
            var criteria = "ALL"
            if let cutoff = request.olderThan { criteria = "BEFORE \(imapDate(cutoff))" }
            let uids = try await client.uidSearch(criteria)
            plan.append((path, uids))
        }
        let total = plan.reduce(0) { $0 + $1.uids.count }
        var done = 0
        var bytes = 0
        for item in plan {
            _ = try await client.select(item.path)
            var start = 0
            while start < item.uids.count {
                try Task.checkCancellation()
                let batch = Array(item.uids[start..<min(start + 50, item.uids.count)])
                let flags = try await client.fetchFlags(uidRange: IMAPClient.sequenceSet(batch))
                let flagMap = Dictionary(flags.map { ($0.uid, MessageFlags(imapFlags: $0.flags)) }, uniquingKeysWith: { a, _ in a })
                for uid in batch {
                    let raw = try await client.fetchMessage(uid: uid)
                    try await writer.add(ArchiveInput(folderPath: item.path, uid: uid, raw: raw, flags: flagMap[uid] ?? []))
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

        if request.removeFromServer {
            for item in plan where !item.uids.isEmpty {
                progress(.status("Removing archived mail from \(item.path)"))
                _ = try await client.select(item.path)
                try await client.store(uids: item.uids, add: true, flags: ["\\Deleted"])
                try await client.expunge()
            }
        }
        progress(.finished(manifest, rootID: rootID))
        return (manifest, rootID)
    }

    static func imapDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "d-MMM-yyyy"
        return f.string(from: date)
    }
}
