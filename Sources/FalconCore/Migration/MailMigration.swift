import Foundation
import CryptoKit

public enum MigrationTarget: Hashable, Sendable {
    case skip
    case existing(String)
    case create(String)

    public var path: String? {
        switch self {
        case .skip: return nil
        case .existing(let p), .create(let p): return p
        }
    }
}

public enum MigrationProgress: Sendable {
    case status(String)
    case folder(String)
    case count(done: Int, total: Int, appended: Int, existing: Int, failed: Int)
    case log(String)
}

public struct MigrationReport: Sendable {
    public var appended = 0
    public var existing = 0
    public var failed = 0
    public var skippedFolders = 0
    public var createdFolders: [String] = []
}

public actor MigrationRunner {
    private let source: MigrationSource
    private let account: AccountInfo
    private let client: IMAPClient
    private let existingFolders: [FolderInfo]
    private let mapping: [String: MigrationTarget]
    private let stateURL: URL
    private var done: Set<String>
    private var knownIDs: [String: Set<String>] = [:]
    private var created = Set<String>()
    private var report = MigrationReport()
    private let prefetchLimit = 40_000

    public init(source: MigrationSource, account: AccountInfo, client: IMAPClient, existingFolders: [FolderInfo],
                mapping: [String: MigrationTarget], layout: FileLayout) {
        self.source = source
        self.account = account
        self.client = client
        self.existingFolders = existingFolders
        self.mapping = mapping
        let safe = source.identifier.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        stateURL = layout.root.appendingPathComponent("Migrations", isDirectory: true).appendingPathComponent("\(safe)-\(account.id.uuidString).json")
        done = Set(AtomicFile.readJSON([String].self, from: stateURL) ?? [])
    }

    private var delimiter: String { existingFolders.first(where: { !$0.delimiter.isEmpty })?.delimiter ?? "/" }
    private var isGmail: Bool { account.provider == "google" }
    private var allMailPath: String? { existingFolders.first { $0.role == .all }?.path }

    public func run(dryRun: Bool, progress: @escaping @Sendable (MigrationProgress) -> Void) async throws -> MigrationReport {
        report = MigrationReport()
        let plan = source.folders.compactMap { folder -> (SourceFolder, String)? in
            guard let path = mapping[folder.id]?.path else { report.skippedFolders += 1; return nil }
            return (folder, path)
        }
        let total = plan.reduce(0) { $0 + $1.0.messageCount }
        var processed = 0
        var seenThisRun = Set<String>()
        for (folder, targetPath) in plan {
            try Task.checkCancellation()
            progress(.folder("\(folder.path) → \(targetPath)"))
            if !dryRun { try await ensureFolder(targetPath) }
            let messages = try source.messages(in: folder)
            let dedupeScope = isGmail ? (allMailPath ?? targetPath) : targetPath
            try await preloadKnownIDs(in: dedupeScope, dryRun: dryRun)
            for message in messages {
                try Task.checkCancellation()
                processed += 1
                defer { progress(.count(done: processed, total: total, appended: report.appended, existing: report.existing, failed: report.failed)) }
                var messageID = message.messageID
                var raw: Data?
                if messageID.isEmpty {
                    guard let data = try? message.load() else { report.failed += 1; continue }
                    raw = data
                    messageID = MIMENormalizer.messageID(in: data)
                    if messageID.isEmpty { messageID = MigrationRunner.syntheticID(for: data) }
                }
                let key = folder.id + "|" + messageID
                if done.contains(key) { report.existing += 1; continue }
                if try await exists(messageID, in: dedupeScope, dryRun: dryRun) {
                    if isGmail, !seenThisRun.contains(messageID), !dryRun, let all = allMailPath, all != targetPath {
                        try await labelExisting(messageID, allMail: all, target: targetPath)
                    }
                    report.existing += 1
                    seenThisRun.insert(messageID)
                    markDone(key)
                    continue
                }
                if dryRun { report.appended += 1; continue }
                do {
                    let data = try raw ?? message.load()
                    let payload = MigrationRunner.ensureMessageID(data, messageID)
                    var flags: MessageFlags = []
                    if message.isRead { flags.insert(.seen) }
                    if message.isFlagged { flags.insert(.flagged) }
                    if folder.kind == .drafts { flags.insert(.draft) }
                    let date = message.date ?? MIMEParser.parseHeaders(payload).first("Date").flatMap(RFC5322Date.parse)
                    try await client.append(mailbox: targetPath, message: payload, flags: flags.imapFlags, date: date)
                    knownIDs[dedupeScope, default: []].insert(messageID)
                    seenThisRun.insert(messageID)
                    report.appended += 1
                    markDone(key)
                } catch {
                    report.failed += 1
                    progress(.log("Failed: \(folder.path) \(messageID): \(error.localizedDescription)"))
                }
            }
        }
        progress(.status(dryRun ? "Dry run complete" : "Migration complete"))
        return report
    }

    private func ensureFolder(_ path: String) async throws {
        guard !existingFolders.contains(where: { $0.path == path }), !created.contains(path) else { return }
        let parts = path.components(separatedBy: delimiter)
        for i in 1...parts.count {
            let partial = parts[0..<i].joined(separator: delimiter)
            guard !existingFolders.contains(where: { $0.path == partial }), !created.contains(partial) else { continue }
            do { try await client.createFolder(partial) } catch { if i == parts.count { throw error } }
            created.insert(partial)
            report.createdFolders.append(partial)
        }
    }

    private func preloadKnownIDs(in mailbox: String, dryRun: Bool) async throws {
        guard knownIDs[mailbox] == nil else { return }
        guard existingFolders.contains(where: { $0.path == mailbox }) || created.contains(mailbox) else {
            knownIDs[mailbox] = []
            return
        }
        let status = try await client.status(mailbox)
        let count = status["MESSAGES"] ?? 0
        guard count > 0 else { knownIDs[mailbox] = []; return }
        guard count <= prefetchLimit else { return }
        _ = try await client.select(mailbox)
        knownIDs[mailbox] = Set(try await client.fetchMessageIDs(uidRange: "1:*"))
    }

    private func exists(_ messageID: String, in mailbox: String, dryRun: Bool) async throws -> Bool {
        if let known = knownIDs[mailbox] { return known.contains(messageID) }
        guard existingFolders.contains(where: { $0.path == mailbox }) || created.contains(mailbox) else { return false }
        if await client.selectedMailbox != mailbox { _ = try await client.select(mailbox) }
        return !(try await client.uidSearch("HEADER Message-ID \(MigrationRunner.quote(messageID))")).isEmpty
    }

    private func labelExisting(_ messageID: String, allMail: String, target: String) async throws {
        _ = try await client.select(allMail)
        let uids = try await client.uidSearch("HEADER Message-ID \(MigrationRunner.quote(messageID))")
        guard let uid = uids.first else { return }
        try await client.copy(uids: [uid], to: target)
    }

    private func markDone(_ key: String) {
        done.insert(key)
        if done.count % 50 == 0 { persist() }
    }

    public func persist() {
        try? AtomicFile.writeJSON(Array(done), to: stateURL)
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func syntheticID(for data: Data) -> String {
        let digest = SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
        return "<\(digest)@migration.falconmail>"
    }

    static func ensureMessageID(_ data: Data, _ messageID: String) -> Data {
        guard MIMENormalizer.messageID(in: data).isEmpty else { return data }
        return Data("Message-ID: \(messageID)\r\n".utf8) + data
    }
}
