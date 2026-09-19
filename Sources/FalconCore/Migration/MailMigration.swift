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
    case count(done: Int, total: Int, appended: Int, existing: Int, failed: Int, bytes: Int)
    case log(String)
}

public struct MigrationAppended: Codable, Sendable, Hashable {
    public var folder: String
    public var messageID: String
}

public struct MigrationState: Sendable {
    public var done: Set<String> = []
    public var appended: [MigrationAppended] = []

    public static func key(_ folderID: String, _ messageID: String) -> String {
        let digest = SHA256.hash(data: Data((folderID + "|" + messageID).utf8))
        return Data(digest.prefix(12)).base64URL
    }

    public static func load(_ url: URL) -> MigrationState {
        var state = MigrationState()
        guard let data = AtomicFile.read(url) else { return state }
        let decoder = JSONDecoder()
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let entry = try? decoder.decode(JournalLine.self, from: line) else { continue }
            if let d = entry.d { state.done.insert(d) }
            if let a = entry.a { state.appended.append(a) }
            if let r = entry.r { state.appended.removeAll { $0.messageID == r }; state.done = state.done.filter { !$0.hasSuffix("|" + r) } }
            if let u = entry.u { state.done.remove(u) }
        }
        return state
    }

    struct JournalLine: Codable {
        var d: String?
        var a: MigrationAppended?
        var r: String?
        var u: String?
    }

    static func append(_ lines: [JournalLine], to url: URL) {
        guard !lines.isEmpty else { return }
        let encoder = JSONEncoder()
        var data = Data()
        for l in lines {
            if let e = try? encoder.encode(l) { data.append(e); data.append(0x0A) }
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    public static func rewrite(_ state: MigrationState, to url: URL) {
        try? FileManager.default.removeItem(at: url)
        append(state.done.map { JournalLine(d: $0) } + state.appended.map { JournalLine(a: $0) }, to: url)
    }
}

public struct VerificationFolder: Sendable, Identifiable {
    public var id: String { source }
    public var source: String
    public var target: String
    public var inArchive = 0
    public var present = 0
    public var missing = 0
    public var unreadable = 0
}

public struct VerificationReport: Sendable {
    public var folders: [VerificationFolder] = []
    public var inArchive: Int { folders.reduce(0) { $0 + $1.inArchive } }
    public var present: Int { folders.reduce(0) { $0 + $1.present } }
    public var missing: Int { folders.reduce(0) { $0 + $1.missing } }
    public var unreadable: Int { folders.reduce(0) { $0 + $1.unreadable } }
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
    public var importsPerMinute = 240
    public var decoders = 3
    public var labelMigrated = true
    public var labelName = "Migrated"
    public var memoryCeiling = 900 * 1024 * 1024

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

    var bufferedBytes: Int { bytes }

    func push(_ item: MigrationItem) async {
        while bytes >= limit && !finished {
            await withCheckedContinuation { producers.append($0) }
        }
        guard !finished else { return }
        if items.isEmpty, !consumers.isEmpty {
            consumers.removeFirst().resume(returning: item)
            return
        }
        items.append(item)
        bytes += item.payload?.count ?? 0
    }

    func requeue(_ item: MigrationItem) {
        if items.isEmpty, !consumers.isEmpty {
            consumers.removeFirst().resume(returning: item)
            return
        }
        items.insert(item, at: 0)
        bytes += item.payload?.count ?? 0
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

enum MemoryFootprint {
    static func current() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    static func waitBelow(_ ceiling: Int, whileQueueHolds queue: PayloadQueue) async {
        var waited = 0
        while MemoryFootprint.current() > ceiling, waited < 50, !Task.isCancelled, await queue.bufferedBytes > 0 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
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
    private var journal: [MigrationState.JournalLine] = []
    private var knownIDs: [String: Set<String>] = [:]
    private var created = Set<String>()
    private var report = MigrationReport()
    private var processed = 0
    private var total = 0
    private let prefetchLimit = 250_000
    public var options = MigrationOptions()
    private var pendingLabel: [String: [UInt32]] = [:]
    private var gmail: GmailImporter?
    private var migratedLabelID: String?
    private var labelIDsByPath: [String: [String]] = [:]

    public static func stateURL(source: MigrationSource, account: AccountInfo, layout: FileLayout) -> URL {
        let safe = source.identifier.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return layout.root.appendingPathComponent("Migrations", isDirectory: true).appendingPathComponent("\(safe)-\(account.id.uuidString).jsonl")
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
        done = state.done
        appendedRecords = state.appended
    }

    public func setOptions(_ o: MigrationOptions) { options = o }

    public func setGmailImporter(_ importer: GmailImporter?) { gmail = importer }

    public var usesGmailAPI: Bool { gmail != nil }

    private func gmailLabelIDs(for targetPath: String) async throws -> [String] {
        if let cached = labelIDsByPath[targetPath] { return cached }
        guard let gmail else { return [] }
        var ids: [String] = []
        if let folder = existingFolders.first(where: { $0.path == targetPath }) {
            switch folder.role {
            case .inbox: ids = ["INBOX"]
            case .sent: ids = ["SENT"]
            case .drafts: ids = ["DRAFT"]
            case .trash: ids = ["TRASH"]
            case .junk: ids = ["SPAM"]
            case .all: ids = []
            default:
                if let id = try await gmail.labelID(named: targetPath, create: true) { ids = [id] }
            }
        } else if let id = try await gmail.labelID(named: targetPath, create: true) {
            ids = [id]
        }
        if options.labelMigrated {
            if migratedLabelID == nil { migratedLabelID = try await gmail.labelID(named: options.labelName, create: true) }
            if let migratedLabelID { ids.append(migratedLabelID) }
        }
        labelIDsByPath[targetPath] = ids
        return ids
    }

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

    public func verify(progress: @escaping @Sendable (MigrationProgress) -> Void) async throws -> VerificationReport {
        var result = VerificationReport()
        let plan = source.folders.compactMap { folder -> (SourceFolder, String)? in
            guard let path = mapping[folder.id]?.path else { return nil }
            return (folder, path)
        }
        total = plan.reduce(0) { $0 + $1.0.messageCount }
        processed = 0
        var presentTotal = 0
        var missingTotal = 0
        for (folder, targetPath) in plan {
            try Task.checkCancellation()
            progress(.folder("Checking \(folder.path) against \(targetPath)"))
            var entry = VerificationFolder(source: folder.path, target: targetPath)
            let messages = try source.messages(in: folder)
            let scope = isGmail ? (allMailPath ?? targetPath) : targetPath
            knownIDs[scope] = nil
            try await preloadKnownIDs(in: scope)
            let ids = await collectMessageIDs(messages)
            entry.inArchive = ids.ids.count + ids.unreadable
            entry.unreadable = ids.unreadable
            for messageID in ids.ids {
                try Task.checkCancellation()
                processed += 1
                let present = try await existsOn(client, messageID, in: scope)
                if present {
                    entry.present += 1
                    presentTotal += 1
                } else {
                    entry.missing += 1
                    missingTotal += 1
                    let key = MigrationState.key(folder.id, messageID)
                    if done.remove(key) != nil { journal.append(MigrationState.JournalLine(u: key)) }
                }
                if processed % 50 == 0 {
                    progress(.count(done: processed, total: total, appended: 0, existing: presentTotal, failed: missingTotal, bytes: 0))
                }
            }
            processed += ids.unreadable
            progress(.count(done: processed, total: total, appended: 0, existing: presentTotal, failed: missingTotal, bytes: 0))
            progress(.log("\(folder.path): \(entry.inArchive) in archive · \(entry.present) on server · \(entry.missing) missing" + (entry.unreadable > 0 ? " · \(entry.unreadable) unreadable" : "")))
            result.folders.append(entry)
            persist()
        }
        persist()
        progress(.status(missingTotal == 0 ? "Verified: every message in the archive is on the server" : "Verified: \(missingTotal) missing. Press Start Migration… to upload them."))
        return result
    }

    private func collectMessageIDs(_ messages: [SourceMessage]) async -> (ids: [String], unreadable: Int) {
        let cursor = Cursor(messages)
        let decoders = max(1, options.decoders)
        return await withTaskGroup(of: ([String], Int).self) { group in
            for _ in 0..<decoders {
                group.addTask {
                    var ids: [String] = []
                    var unreadable = 0
                    while let light = await cursor.next(), !Task.isCancelled {
                        guard let message = try? light.prepared() else { unreadable += 1; continue }
                        if !message.messageID.isEmpty { ids.append(message.messageID); continue }
                        guard let data = try? message.load() else { unreadable += 1; continue }
                        let id = MIMENormalizer.messageID(in: data)
                        ids.append(id.isEmpty ? MigrationRunner.syntheticID(for: data) : id)
                    }
                    return (ids, unreadable)
                }
            }
            var all: [String] = []
            var unreadable = 0
            for await (ids, bad) in group { all.append(contentsOf: ids); unreadable += bad }
            return (all, unreadable)
        }
    }

    private func dryRunFolder(_ folder: SourceFolder, messages: [SourceMessage], scope: String, progress: @escaping @Sendable (MigrationProgress) -> Void) async throws {
        for light in messages {
            try Task.checkCancellation()
            processed += 1
            guard let message = try? light.prepared() else { report.failed += 1; emit(progress); continue }
            let messageID = try resolveMessageID(message)
            let alreadyDone = done.contains(MigrationState.key(folder.id, messageID))
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
        let ceiling = options.memoryCeiling
        while let light = await cursor.next(), !Task.isCancelled {
            await MemoryFootprint.waitBelow(ceiling, whileQueueHolds: queue)
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
            let key = MigrationState.key(folder.id, messageID)
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
        var connection: IMAPClient?
        if index > 0, gmail == nil {
            do { connection = try await reconnect() } catch {
                progress(.log("Connection \(index + 1) not opened (\(error.localizedDescription)); continuing with fewer connections"))
                return
            }
        }
        defer { if let c = connection { Task { await c.logout() } } }
        func current() async throws -> IMAPClient {
            if let c = connection { return c }
            return await client
        }
        while let item = await queue.pop() {
            var attempt = 0
            while true {
                try Task.checkCancellation()
                do {
                    let c = try await current()
                    try await process(item, on: c, preloaded: preloaded, progress: progress)
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard MigrationRunner.isTransient(error), attempt < 6 else {
                        await noteFailed(progress, "\(item.targetPath) \(item.messageID): \(error.localizedDescription)")
                        break
                    }
                    attempt += 1
                    let delay = min(60, 5 * (1 << attempt))
                    if GmailImporter.isRateLimited(error) {
                        await gmail?.noteRateLimited()
                        let pace = await gmail?.pacePerMinute ?? 0
                        progress(.log("Gmail asked to slow down — pace now \(pace)/min, retrying in \(delay)s"))
                        try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                        continue
                    }
                    if let c = connection { await c.logout() } else { await client.logout() }
                    progress(.log("Connection \(index + 1): \(error.localizedDescription) — retrying in \(delay)s"))
                    try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                    do {
                        let fresh = try await reconnect()
                        if index == 0 { client = fresh } else { connection = fresh }
                    } catch {
                        if index > 0 {
                            await queue.requeue(item)
                            progress(.log("Connection \(index + 1) closed: \(error.localizedDescription); continuing with fewer connections"))
                            connection = nil
                            return
                        }
                    }
                }
            }
        }
    }

    private func process(_ item: MigrationItem, on c: IMAPClient, preloaded: Bool, progress: @escaping @Sendable (MigrationProgress) -> Void) async throws {
        if item.payload == nil {
            if let all = allMailPath { try await labelExisting(on: c, item.messageID, allMail: all, target: item.targetPath) }
            noteExisting(progress)
            return
        }
        if !preloaded, try await existsOn(c, item.messageID, in: item.scope) {
            markDone(item.key)
            noteExisting(progress)
            return
        }
        var flags: MessageFlags = []
        if item.isRead { flags.insert(.seen) }
        if item.isFlagged { flags.insert(.flagged) }
        if item.folderKind == .drafts { flags.insert(.draft) }
        let payload = item.payload ?? Data()
        if let gmail {
            var labels = try await gmailLabelIDs(for: item.targetPath)
            if !item.isRead { labels.append("UNREAD") }
            if item.isFlagged { labels.append("STARRED") }
            _ = try await gmail.importMessage(payload, labelIDs: labels)
            noteAppended(item, uid: nil, bytes: payload.count, progress: progress)
            return
        }
        let date = item.date ?? MIMEParser.parseHeaders(payload).first("Date").flatMap(RFC5322Date.parse)
        let uid = try await c.append(mailbox: item.targetPath, message: payload, flags: flags.imapFlags, date: date)
        noteAppended(item, uid: uid, bytes: payload.count, progress: progress)
    }

    static func isTransient(_ error: Error) -> Bool {
        if GmailImporter.isRateLimited(error) { return true }
        switch error {
        case FalconError.network: return true
        case FalconError.protocolError(let text):
            let t = text.lowercased()
            return t.contains("too many simultaneous") || t.contains("try again") || t.contains("temporar") || t.contains("throttl") || t.contains("bye") || t.contains("timeout")
        default:
            return "\(error)".lowercased().contains("too many simultaneous")
        }
    }

    private func isDone(_ key: String) -> Bool { done.contains(key) }
    private func isKnown(_ id: String, in scope: String) -> Bool { knownIDs[scope]?.contains(id) ?? false }

    private func emit(_ progress: @escaping @Sendable (MigrationProgress) -> Void) {
        progress(.count(done: processed, total: total, appended: report.appended, existing: report.existing, failed: report.failed, bytes: report.bytesUploaded))
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
        let record = MigrationAppended(folder: item.targetPath, messageID: item.messageID)
        appendedRecords.append(record)
        journal.append(MigrationState.JournalLine(a: record))
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
                done.remove(MigrationState.key(folder, record.messageID))
                progress(.count(done: removed, total: count, appended: 0, existing: 0, failed: 0, bytes: 0))
            }
        }
        MigrationState.rewrite(MigrationState(done: done, appended: appendedRecords), to: stateURL)
        journal.removeAll()
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
        guard !done.contains(key) else { return }
        done.insert(key)
        journal.append(MigrationState.JournalLine(d: key))
        if journal.count >= 200 { persist() }
    }

    public func persist() {
        MigrationState.append(journal, to: stateURL)
        journal.removeAll()
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
