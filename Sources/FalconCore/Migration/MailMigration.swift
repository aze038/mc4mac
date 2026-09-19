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

public struct MigrationAppended: Codable, Sendable, Hashable {
    public var folder: String
    public var messageID: String
}

public struct MigrationState: Codable, Sendable {
    public var done: [String] = []
    public var appended: [MigrationAppended] = []

    public static func load(_ url: URL) -> MigrationState {
        if let s = AtomicFile.readJSON(MigrationState.self, from: url) { return s }
        if let legacy = AtomicFile.readJSON([String].self, from: url) { return MigrationState(done: legacy, appended: []) }
        return MigrationState()
    }
}

public struct MigrationReport: Sendable {
    public var appended = 0
    public var existing = 0
    public var failed = 0
    public var skippedFolders = 0
    public var createdFolders: [String] = []
    public var bytesUploaded = 0
}

public struct MigrationOptions: Sendable {
    public var bufferBytes = MigrationOptions.defaultBufferBytes
    public var uploaders = 5
    public var decoders = 3
    public var labelMigrated = true
    public var labelName = "Migrated"

    public init() {}

    public static var defaultBufferBytes: Int {
        let physical = Int(ProcessInfo.processInfo.physicalMemory)
        return min(256 * 1024 * 1024, max(64 * 1024 * 1024, physical / 64))
    }
}

struct MigrationItem: Sendable {
    var key: String
    var messageID: String
    var folderKind: SourceFolderKind
    var isRead: Bool
    var isFlagged: Bool
    var date: Date?
    var payload: Data?
    var targetPath: String
    var scope: String
}

actor PayloadQueue {
    private var items: [MigrationItem] = []
    private var bytes = 0
    private let limit: Int
    private var consumers: [CheckedContinuation<MigrationItem?, Never>] = []
    private var producers: [CheckedContinuation<Void, Never>] = []
    private var finished = false

    init(limit: Int) { self.limit = limit }

    func push(_ item: MigrationItem) async {
        while bytes >= limit && !finished {
            await withCheckedContinuation { producers.append($0) }
        }
        guard !finished else { return }
        items.append(item)
        bytes += item.payload?.count ?? 0
        if !consumers.isEmpty { consumers.removeFirst().resume(returning: items.removeFirst()) }
    }

    func pop() async -> MigrationItem? {
        if !items.isEmpty {
            let item = items.removeFirst()
            bytes -= item.payload?.count ?? 0
            if !producers.isEmpty { producers.removeFirst().resume() }
            return item
        }
        if finished { return nil }
        return await withCheckedContinuation { consumers.append($0) }
    }

    func finish() {
        finished = true
        for c in consumers { c.resume(returning: nil) }
        consumers.removeAll()
        for p in producers { p.resume() }
        producers.removeAll()
    }

    func cancel() {
        items.removeAll()
        bytes = 0
        finish()
    }
}

actor Cursor<T: Sendable> {
    private var items: [T]
    private var index = 0
    init(_ items: [T]) { self.items = items }
    func next() -> T? {
        guard index < items.count else { return nil }
        defer { index += 1 }
        return items[index]
    }
}

public actor MigrationRunner {
    private let source: MigrationSource
    private let account: AccountInfo
    private var client: IMAPClient
    private let reconnect: @Sendable () async throws -> IMAPClient
    private let existingFolders: [FolderInfo]
    private let mapping: [String: MigrationTarget]
    public let stateURL: URL
    private var done: Set<String>
    private var appendedRecords: [MigrationAppended]
    private var knownIDs: [String: Set<String>] = [:]
    private var created = Set<String>()
    private var report = MigrationReport()
    private var processed = 0
    private var total = 0
    private let prefetchLimit = 40_000
    public var options = MigrationOptions()
    private var pendingLabel: [String: [UInt32]] = [:]

    public static func stateURL(source: MigrationSource, account: AccountInfo, layout: FileLayout) -> URL {
        let safe = source.identifier.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return layout.root.appendingPathComponent("Migrations", isDirectory: true).appendingPathComponent("\(safe)-\(account.id.uuidString).json")
    }

    public init(source: MigrationSource, account: AccountInfo, client: IMAPClient, reconnect: @escaping @Sendable () async throws -> IMAPClient,
                existingFolders: [FolderInfo], mapping: [String: MigrationTarget], layout: FileLayout) {
        self.source = source
        self.account = account
        self.client = client
        self.reconnect = reconnect
        self.existingFolders = existingFolders
        self.mapping = mapping
        stateURL = MigrationRunner.stateURL(source: source, account: account, layout: layout)
        let state = MigrationState.load(stateURL)
        done = Set(state.done)
        appendedRecords = state.appended
    }

    public func setOptions(_ o: MigrationOptions) { options = o }

    public var appendedCount: Int { appendedRecords.count }

    private var delimiter: String { existingFolders.first(where: { !$0.delimiter.isEmpty })?.delimiter ?? "/" }
    private var isGmail: Bool { account.provider == "google" }
    private var allMailPath: String? { existingFolders.first { $0.role == .all }?.path }

    public func run(dryRun: Bool, progress: @escaping @Sendable (MigrationProgress) -> Void) async throws -> MigrationReport {
        report = MigrationReport()
        processed = 0
        let plan = source.folders.compactMap { folder -> (SourceFolder, String)? in
            guard let path = mapping[folder.id]?.path else { report.skippedFolders += 1; return nil }
            return (folder, path)
        }
        total = plan.reduce(0) { $0 + $1.0.messageCount }
        for (folder, targetPath) in plan {
            try Task.checkCancellation()
            progress(.folder("\(folder.path) → \(targetPath)"))
            if !dryRun { try await ensureFolder(targetPath) }
            let messages = try source.messages(in: folder)
            let scope = isGmail ? (allMailPath ?? targetPath) : targetPath
            try await preloadKnownIDs(in: scope)
            if dryRun {
                try await dryRunFolder(folder, messages: messages, scope: scope, progress: progress)
            } else {
                try await uploadFolder(folder, messages: messages, targetPath: targetPath, scope: scope, progress: progress)
                try await flushLabels(for: targetPath)
                persist()
            }
        }
        persist()
        progress(.status(dryRun ? "Dry run complete" : "Migration complete"))
        return report
    }

    private func dryRunFolder(_ folder: SourceFolder, messages: [SourceMessage], scope: String, progress: @escaping @Sendable (MigrationProgress) -> Void) async throws {
        for light in messages {
            try Task.checkCancellation()
            processed += 1
            guard let message = try? light.prepared() else { report.failed += 1; emit(progress); continue }
            let messageID = try resolveMessageID(message)
            let alreadyDone = done.contains(folder.id + "|" + messageID)
            let present = alreadyDone ? true : try await existsOn(client, messageID, in: scope)
            if present { report.existing += 1 } else { report.appended += 1 }
            emit(progress)
        }
    }

    private func uploadFolder(_ folder: SourceFolder, messages: [SourceMessage], targetPath: String, scope: String,
                              progress: @escaping @Sendable (MigrationProgress) -> Void) async throws {
        let queue = PayloadQueue(limit: options.bufferBytes)
        let cursor = Cursor(messages)
        let preloaded = knownIDs[scope] != nil
        let decoders = max(1, options.decoders)
        let uploaders = max(1, options.uploaders)
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    await withTaskGroup(of: Void.self) { inner in
                        for _ in 0..<decoders {
                            inner.addTask { await self.decode(from: cursor, folder: folder, targetPath: targetPath, scope: scope, preloaded: preloaded, into: queue, progress: progress) }
                        }
                    }
                    await queue.finish()
                }
                for i in 0..<uploaders {
                    group.addTask { try await self.upload(from: queue, index: i, preloaded: preloaded, progress: progress) }
                }
                try await group.waitForAll()
            }
        } onCancel: {
            Task { await queue.cancel() }
        }
    }

    private func decode(from cursor: Cursor<SourceMessage>, folder: SourceFolder, targetPath: String, scope: String, preloaded: Bool,
                        into queue: PayloadQueue, progress: @escaping @Sendable (MigrationProgress) -> Void) async {
        while let light = await cursor.next(), !Task.isCancelled {
            let message: SourceMessage
            do { message = try light.prepared() } catch {
                await noteFailed(progress, "\(folder.path): \(error.localizedDescription)")
                continue
            }
            var raw: Data?
            var messageID = message.messageID
            if messageID.isEmpty {
                guard let data = try? message.load() else { await noteFailed(progress, "\(folder.path): unreadable message"); continue }
                raw = data
                messageID = MIMENormalizer.messageID(in: data)
                if messageID.isEmpty { messageID = MigrationRunner.syntheticID(for: data) }
            }
            let key = folder.id + "|" + messageID
            if await isDone(key) { await noteExisting(progress); continue }
            if preloaded, await isKnown(messageID, in: scope) {
                await markDone(key)
                if isGmail, let all = allMailPath, all != targetPath {
                    await queue.push(MigrationItem(key: key, messageID: messageID, folderKind: folder.kind, isRead: message.isRead, isFlagged: message.isFlagged,
                                                   date: message.date, payload: nil, targetPath: targetPath, scope: scope))
                } else {
                    await noteExisting(progress)
                }
                continue
            }
            let data: Data
            do { data = try raw ?? message.load() } catch {
                await noteFailed(progress, "\(folder.path) \(messageID): \(error.localizedDescription)")
                continue
            }
            let payload = MigrationRunner.ensureMessageID(data, messageID)
            await queue.push(MigrationItem(key: key, messageID: messageID, folderKind: folder.kind, isRead: message.isRead, isFlagged: message.isFlagged,
                                           date: message.date, payload: payload, targetPath: targetPath, scope: scope))
        }
    }

    private func upload(from queue: PayloadQueue, index: Int, preloaded: Bool, progress: @escaping @Sendable (MigrationProgress) -> Void) async throws {
        var connection: IMAPClient? = index == 0 ? nil : try await reconnect()
        defer { if let c = connection { Task { await c.logout() } } }
        func current() async throws -> IMAPClient {
            if let c = connection { return c }
            return await client
        }
        while let item = await queue.pop() {
            try Task.checkCancellation()
            do {
                var c = try await current()
                if item.payload == nil {
                    if let all = allMailPath { try await labelExisting(on: c, item.messageID, allMail: all, target: item.targetPath) }
                    await noteExisting(progress)
                    continue
                }
                if !preloaded, try await existsOn(c, item.messageID, in: item.scope) {
                    await markDone(item.key)
                    await noteExisting(progress)
                    continue
                }
                var flags: MessageFlags = []
                if item.isRead { flags.insert(.seen) }
                if item.isFlagged { flags.insert(.flagged) }
                if item.folderKind == .drafts { flags.insert(.draft) }
                let payload = item.payload ?? Data()
                let date = item.date ?? MIMEParser.parseHeaders(payload).first("Date").flatMap(RFC5322Date.parse)
                let uid: UInt32?
                do {
                    uid = try await c.append(mailbox: item.targetPath, message: payload, flags: flags.imapFlags, date: date)
                } catch FalconError.network {
                    await c.logout()
                    c = try await reconnect()
                    if index == 0 { client = c } else { connection = c }
                    uid = try await c.append(mailbox: item.targetPath, message: payload, flags: flags.imapFlags, date: date)
                }
                await noteAppended(item, uid: uid, bytes: payload.count, progress: progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await noteFailed(progress, "\(item.targetPath) \(item.messageID): \(error.localizedDescription)")
            }
        }
    }

    private func isDone(_ key: String) -> Bool { done.contains(key) }
    private func isKnown(_ id: String, in scope: String) -> Bool { knownIDs[scope]?.contains(id) ?? false }

    private func emit(_ progress: @escaping @Sendable (MigrationProgress) -> Void) {
        progress(.count(done: processed, total: total, appended: report.appended, existing: report.existing, failed: report.failed))
    }

    private func noteExisting(_ progress: @escaping @Sendable (MigrationProgress) -> Void) {
        processed += 1
        report.existing += 1
        emit(progress)
    }

    private func noteFailed(_ progress: @escaping @Sendable (MigrationProgress) -> Void, _ text: String) {
        processed += 1
        report.failed += 1
        Log.info("migration", "failed " + text)
        progress(.log("Failed: " + text))
        emit(progress)
    }

    private func noteAppended(_ item: MigrationItem, uid: UInt32?, bytes: Int, progress: @escaping @Sendable (MigrationProgress) -> Void) {
        processed += 1
        report.appended += 1
        report.bytesUploaded += bytes
        knownIDs[item.scope]?.insert(item.messageID)
        appendedRecords.append(MigrationAppended(folder: item.targetPath, messageID: item.messageID))
        if let uid, options.labelMigrated { pendingLabel[item.targetPath, default: []].append(uid) }
        markDone(item.key)
        emit(progress)
    }

    private func resolveMessageID(_ message: SourceMessage) throws -> String {
        if !message.messageID.isEmpty { return message.messageID }
        let data = try message.load()
        let id = MIMENormalizer.messageID(in: data)
        return id.isEmpty ? MigrationRunner.syntheticID(for: data) : id
    }

    private func flushLabels(for folder: String) async throws {
        guard options.labelMigrated, let uids = pendingLabel[folder], !uids.isEmpty else { return }
        pendingLabel[folder] = []
        if isGmail { try await ensureFolder(options.labelName) }
        if await client.selectedMailbox != folder { _ = try await client.select(folder) }
        for chunk in stride(from: 0, to: uids.count, by: 500).map({ Array(uids[$0..<min($0 + 500, uids.count)]) }) {
            if isGmail {
                try await client.copy(uids: chunk, to: options.labelName)
            } else {
                try await client.store(uids: chunk, add: true, flags: ["$" + options.labelName.replacingOccurrences(of: " ", with: "")])
            }
        }
    }

    public func undo(progress: @escaping @Sendable (MigrationProgress) -> Void) async throws -> Int {
        var removed = 0
        let trash = existingFolders.first { $0.role == .trash }?.path
        let groups = Dictionary(grouping: appendedRecords, by: \.folder)
        let count = appendedRecords.count
        for (folder, records) in groups {
            try Task.checkCancellation()
            progress(.folder("Removing from \(folder)"))
            let scope = isGmail ? (allMailPath ?? folder) : folder
            _ = try await client.select(scope)
            for record in records {
                let uids = try await client.uidSearch("HEADER Message-ID \(MigrationRunner.quote(record.messageID))")
                if !uids.isEmpty {
                    if isGmail, let trash {
                        try await client.move(uids: uids, to: trash)
                        _ = try await client.select(trash)
                        let trashed = try await client.uidSearch("HEADER Message-ID \(MigrationRunner.quote(record.messageID))")
                        if !trashed.isEmpty {
                            try await client.store(uids: trashed, add: true, flags: ["\\Deleted"])
                            try await client.expunge()
                        }
                        _ = try await client.select(scope)
                    } else {
                        try await client.store(uids: uids, add: true, flags: ["\\Deleted"])
                        try await client.expunge()
                    }
                }
                removed += 1
                appendedRecords.removeAll { $0 == record }
                done = done.filter { !$0.hasSuffix("|" + record.messageID) }
                progress(.count(done: removed, total: count, appended: 0, existing: 0, failed: 0))
            }
        }
        persist()
        progress(.status("Removed \(removed) migrated messages"))
        return removed
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

    private func preloadKnownIDs(in mailbox: String) async throws {
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

    private func existsOn(_ c: IMAPClient, _ messageID: String, in mailbox: String) async throws -> Bool {
        if let known = knownIDs[mailbox] { return known.contains(messageID) }
        guard existingFolders.contains(where: { $0.path == mailbox }) || created.contains(mailbox) else { return false }
        if await c.selectedMailbox != mailbox { _ = try await c.select(mailbox) }
        return !(try await c.uidSearch("HEADER Message-ID \(MigrationRunner.quote(messageID))")).isEmpty
    }

    private func labelExisting(on c: IMAPClient, _ messageID: String, allMail: String, target: String) async throws {
        if await c.selectedMailbox != allMail { _ = try await c.select(allMail) }
        let uids = try await c.uidSearch("HEADER Message-ID \(MigrationRunner.quote(messageID))")
        guard let uid = uids.first else { return }
        try await c.copy(uids: [uid], to: target)
    }

    private func markDone(_ key: String) {
        done.insert(key)
        if done.count % 100 == 0 { persist() }
    }

    public func persist() {
        try? AtomicFile.writeJSON(MigrationState(done: Array(done), appended: appendedRecords), to: stateURL)
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
