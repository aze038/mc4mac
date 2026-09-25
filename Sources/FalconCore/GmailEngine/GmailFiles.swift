import Foundation

/// Where a Google account's Gmail engine keeps its files: `Accounts/<id>/Gmail/`, beside the
/// IMAP store, which it never writes. An earlier build ignores this folder, so going back to one
/// loses nothing and the next upgrade finds it as it was left.
public struct GmailFiles: Hashable, Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public init(layout: FileLayout, accountID: UUID) {
        self.init(directory: layout.accountDirectory(accountID).appendingPathComponent("Gmail", isDirectory: true))
    }

    /// The index as last compacted.
    public var indexSnapshot: URL { file("index.snap") }
    /// Everything since, appended: changes with their cursor, and listing pages.
    public var indexJournal: URL { file("index.journal") }
    public var labels: URL { file("labels.json") }
    public var dateAnchors: URL { file("anchors.json") }
    public var threadSummaries: URL { file("threads.json") }
    /// Summaries saved since `threads.json` was last written whole.
    public var threadSummariesJournal: URL { file("threads.journal") }
    /// Rows and reply headers of the newest 1,000.
    public var cacheDirectory: URL { directory.appendingPathComponent("cache", isDirectory: true) }
    public var cacheRows: URL { cacheDirectory.appendingPathComponent("rows.json") }
    /// Rows kept or let go since `rows.json` was last written whole.
    public var cacheRowsJournal: URL { cacheDirectory.appendingPathComponent("rows.journal") }
    /// The folders the owner opened most recently, whose first screens are kept.
    public var folderScreens: URL { cacheDirectory.appendingPathComponent("screens.json") }
    public var bodiesDirectory: URL { directory.appendingPathComponent("bodies", isDirectory: true) }
    /// Words of the kept messages' headers and previews, for searching them offline.
    public var terms: URL { file("terms.json") }
    /// Ids FalconMail imported itself over the last 7 days, so their echo is never new mail.
    public var importLog: URL { file("imports.json") }
    /// Imports noted since `imports.json` was last written whole.
    public var importLogJournal: URL { file("imports.journal") }
    /// Changes waiting to reach Gmail. An earlier build never reads it.
    public var pendingOps: URL { file("pendingOps.json") }
    /// Which Gmail draft each message id belongs to.
    public var drafts: URL { file("drafts.json") }
    /// The engine's own state. It never holds the history cursor, which lives in the journal only.
    public var state: URL { file("state.json") }
    /// How far moving local state to Gmail ids has got.
    public var migration: URL { file("migration.json") }

    /// One cached message's reduced body.
    public func body(_ id: GmailMessageID) -> URL {
        bodiesDirectory.appendingPathComponent("\(id.hex).lzfse")
    }

    /// Everything under the folder, in bytes: the account's whole footprint on disk.
    public func diskUsage() -> Int {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += values?.fileSize ?? 0 }
        }
        return total
    }

    private func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
}

// MARK: - Small keyed files

/// A small keyed collection kept as a JSON snapshot and a journal of JSON lines appended after it:
/// the kept rows, the conversation summaries and the import log. Saving one entry appends one
/// line rather than rewriting the file, which during the first fill of 1,000 rows would write a
/// gigabyte. Replaying the journal on the snapshot gives the same result however often it is
/// replayed, since each line says what one key becomes.
///
/// These files hold nothing Gmail cannot give again, so they are not flushed to the drive, and a
/// file that cannot be read is dropped and filled again.
final class GmailRecordFile<Value: Codable> {
    private struct Line: Codable {
        var k: String
        var v: Value?
    }

    let snapshotURL: URL
    let journalURL: URL
    private let io: GmailDiskIO
    private let what: String
    private var fd: Int32 = -1
    private var journalLength = 0
    private(set) var journalOperations = 0

    init(snapshot: URL, journal: URL, io: GmailDiskIO, what: String) {
        snapshotURL = snapshot
        journalURL = journal
        self.io = io
        self.what = what
    }

    deinit {
        if fd >= 0 { close(fd) }
    }

    func load() -> [String: Value] {
        var values: [String: Value] = [:]
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: snapshotURL) {
            if let decoded = try? decoder.decode([String: Value].self, from: data) {
                values = decoded
            } else {
                Log.warning("Store", "\(what) could not be read and will be filled again", code: "gmailFileUnreadable", logAs: "store")
                io.remove(snapshotURL)
            }
        }
        let bytes = [UInt8]((try? Data(contentsOf: journalURL)) ?? Data())
        var start = 0
        var valid = 0
        var skipped = 0
        journalOperations = 0
        while let end = bytes[start...].firstIndex(of: 0x0A) {
            if let line = try? decoder.decode(Line.self, from: Data(bytes[start..<end])) {
                if let value = line.v { values[line.k] = value } else { values[line.k] = nil }
                journalOperations += 1
            } else {
                skipped += 1
            }
            start = end + 1
            valid = start
        }
        if skipped > 0 {
            Log.info("store", "\(what): skipped \(skipped) unreadable lines")
        }
        do {
            fd = try GmailDiskIO.openForAppend(journalURL)
            // What follows the last newline is a line a crash cut short; the next line must not be
            // glued to it.
            if valid < bytes.count { try io.truncate(fd, url: journalURL, to: valid) }
            journalLength = valid
        } catch {
            Log.warning("Store", "could not open the journal of \(what)", error: error, code: "gmailFileUnwritable", logAs: "store")
        }
        return values
    }

    func set(_ key: String, _ value: Value) throws {
        try append([Line(k: key, v: value)])
    }

    func set(_ entries: [(String, Value)]) throws {
        guard !entries.isEmpty else { return }
        try append(entries.map { Line(k: $0.0, v: $0.1) })
    }

    func remove(_ keys: [String]) throws {
        guard !keys.isEmpty else { return }
        try append(keys.map { Line(k: $0, v: nil) })
    }

    /// Writes every entry into the snapshot and starts the journal again.
    func write(_ all: [String: Value]) throws {
        try io.replace(try JSONEncoder().encode(all), at: snapshotURL)
        if fd >= 0 { close(fd) }
        fd = -1
        io.remove(journalURL)
        fd = try GmailDiskIO.openForAppend(journalURL)
        journalLength = 0
        journalOperations = 0
    }

    func shouldCompact(count: Int) -> Bool { journalOperations > max(64, count) }

    private func append(_ lines: [Line]) throws {
        if fd < 0 {
            fd = try GmailDiskIO.openForAppend(journalURL)
            // A failed append is cut back to this length, so it has to be the file's own.
            journalLength = Int(lseek(fd, 0, SEEK_END))
        }
        let encoder = JSONEncoder()
        var data = Data()
        for line in lines {
            data.append(try encoder.encode(line))
            data.append(0x0A)
        }
        try io.append(data, to: fd, url: journalURL, length: journalLength, barrier: false)
        journalLength += data.count
        journalOperations += lines.count
    }
}

// MARK: - The store

/// A Google account's store on disk, in `Accounts/<id>/Gmail/`. See `GmailStore` for what it
/// promises; this is where it is kept.
///
/// The index is a snapshot and a journal: each check appends its changes and then its cursor,
/// flushed together, and each listing page is appended on its own. So a crash at any point loads
/// into a state that the next check or listing page brings up to date, and the cursor is never
/// saved ahead of the changes it covers. Everything else is derived, or small, and is repaired
/// from the index at launch.
public actor GmailFileStore: GmailStore {
    public struct Limits: Sendable {
        public var cacheLimit = 1_000
        public var cacheCeiling = 1_050
        public var bodyBytesCap = 32 * 1_024 * 1_024
        /// Journal records after which the snapshot is written again.
        public var compactOperations = 5_000
        /// Journal bytes after which the snapshot is written again, or the snapshot's own size if
        /// larger, so that a launch never reads much more journal than index.
        public var compactBytes = 8 * 1_024 * 1_024
        /// How long an import is remembered.
        public var importMemory: TimeInterval = 7 * 86_400

        public init() {}
    }

    public nonisolated let accountID: UUID
    public nonisolated let files: GmailFiles
    public nonisolated let limits: Limits
    let io: GmailDiskIO

    private var index = GmailIndex()
    private var journal: GmailJournal?
    private var snapshotBytes = 0
    private var labelEntries: [GmailLabelEntry] = []
    private let cache: GmailMessageCache
    private let summaries: GmailThreadSummaryStore
    private var anchors: [GmailDateAnchor] = []
    private let importFile: GmailRecordFile<Date>
    private var imports: [UInt64: Date] = [:]
    /// Conversations with a newly kept message and no summary yet. Whether every message of one
    /// is kept takes a pass over the whole index, so it is done for all of them at once, before
    /// anyone reads a summary, rather than once for each message kept.
    private var summariesWanted = Set<UInt64>()
    private var loaded = false

    public init(accountID: UUID, files: GmailFiles, limits: Limits = Limits()) {
        self.init(accountID: accountID, files: files, limits: limits, io: GmailDiskIO())
    }

    init(accountID: UUID, files: GmailFiles, limits: Limits = Limits(), io: GmailDiskIO) {
        self.accountID = accountID
        self.files = files
        self.limits = limits
        self.io = io
        cache = GmailMessageCache(files: files, io: io, limit: limits.cacheLimit, ceiling: limits.cacheCeiling,
                                  bodyBytesCap: limits.bodyBytesCap)
        summaries = GmailThreadSummaryStore(files: files, io: io)
        importFile = GmailRecordFile(snapshot: files.importLog, journal: files.importLogJournal, io: io,
                                     what: "the Gmail import log")
    }

    // MARK: - Loading

    public func load() async throws -> GmailStoreLoad {
        try ensureLoaded()
        return currentLoad()
    }

    private func currentLoad() -> GmailStoreLoad {
        // A message seen only in a label's listing is left to All Mail's listing, which places
        // it when it gets there; once that listing is complete, it was skipped, and has to be
        // placed on its own.
        let skippedByAllMail = index.allMailListed
        let waiting = index.pending.values.filter { $0.awaiting || skippedByAllMail }.map(\.ref).sorted { $0.id < $1.id }
        return GmailStoreLoad(cursor: index.cursor, resyncBegan: index.resyncBegan, awaitingPlacement: waiting,
                              chains: index.chains, messageCount: index.liveCount)
    }

    private func ensureLoaded() throws {
        guard !loaded else { return }
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        removeStrayTemporaries()
        try loadIndex()
        labelEntries = GmailLabelTable.load(from: files.labels, map: index.slotMap)
        let dropped = cache.load(index: index)
        if !dropped.isEmpty { Log.info("store", "let go of \(dropped.count) kept Gmail rows whose messages are gone") }
        index.setCachedBits(Set(cache.messages.keys))
        let cachedThreads = Set(cache.messages.values.map(\.threadID.raw))
        summaries.load { cachedThreads.contains($0.raw) }
        anchors = GmailDateAnchorFile.load(from: files.dateAnchors)
        var gone: [String] = []
        let now = Date()
        for (key, date) in importFile.load() {
            if let id = GmailMessageID(hex: key), now.timeIntervalSince(date) < limits.importMemory {
                imports[id.raw] = date
            } else {
                gone.append(key)
            }
        }
        try? importFile.remove(gone)
        loaded = true
        if let journal, journal.operations >= limits.compactOperations { try compactNow() }
    }

    /// A file being written whole goes to a temporary name first; one left by a crash is never
    /// read, so it goes.
    private func removeStrayTemporaries() {
        for folder in [files.directory, files.cacheDirectory] {
            let listed = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for url in listed where url.lastPathComponent.hasPrefix(".") && url.lastPathComponent.hasSuffix(".tmp") {
                io.remove(url)
            }
        }
    }

    private func loadIndex() throws {
        var generation: UInt64 = 1
        do {
            let data = try Data(contentsOf: files.indexSnapshot)
            do {
                let decoded = try GmailIndex.decodeSnapshot(data)
                index = decoded.index
                generation = decoded.nextGeneration
                snapshotBytes = data.count
            } catch {
                // Starting again from Gmail costs a listing; trusting part of an index could lose
                // mail. The journal belongs to the snapshot, so it goes too.
                let aside = AtomicFile.setAside(files.indexSnapshot)
                Log.error("Store", "the Gmail index could not be read; it is listed again from Gmail", error: error,
                          code: "gmailIndexUnreadable", logAs: "store")
                if aside == nil { throw error }
                _ = AtomicFile.setAside(files.indexJournal)
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A new account, or one whose first snapshot was never written.
        }
        // A journal of another generation than the snapshot names, such as one that followed a
        // snapshot now missing, is replaced by an empty one rather than applied to nothing.
        let (opened, units) = try GmailJournal.open(files.indexJournal, generation: generation, io: io)
        journal = opened
        for unit in units {
            switch unit {
            case .batch(let entries, let cursor):
                for entry in entries { index.apply(entry) }
                if let cursor { index.cursor = cursor }
            case .page(let page):
                index.apply(page)
            }
        }
    }

    // MARK: - The index

    public func index() async -> GmailIndexSnapshot {
        try? ensureLoaded()
        return index.snapshot()
    }

    public func record(for id: GmailMessageID) async -> GmailIndexRecord? {
        try? ensureLoaded()
        return index.record(for: id)
    }

    public func labels(of id: GmailMessageID) async -> Set<GmailLabelID>? {
        try? ensureLoaded()
        guard let slot = index.slot(of: id) else { return nil }
        return index.labels(atSlot: slot)
    }

    // MARK: - The journal

    public func commit(_ batch: GmailJournalBatch) async throws {
        try commitNow(batch)
    }

    public func placeIfAbsent(_ changes: [GmailChange]) async throws -> [GmailMessageID] {
        try ensureLoaded()
        var chosen: [GmailChange] = []
        var ids: [GmailMessageID] = []
        for change in changes {
            guard case .place(let ref, let order, let labels, let attributes) = change, index.slot(of: ref.id) == nil else { continue }
            // Labels another listing named while it waited for its place are kept.
            let learnt = index.pending[ref.id.raw]?.labels ?? []
            chosen.append(.place(ref, order: order, labels: labels.union(learnt), attributes: attributes))
            ids.append(ref.id)
        }
        guard !chosen.isEmpty else { return [] }
        try commitNow(GmailJournalBatch(changes: chosen))
        return ids
    }

    /// With no suspension between reading the index and writing, so no listing page can come
    /// between them.
    private func commitNow(_ batch: GmailJournalBatch) throws {
        try ensureLoaded()
        guard let journal else { throw GmailDiskError.notLoaded }
        try journal.append(batch: batch.changes.map(GmailJournalEntry.change), cursor: batch.cursor)
        var gone: [GmailMessageID] = []
        for change in batch.changes {
            index.apply(change)
            switch change {
            case .tombstone(let id):
                gone.append(id)
            case .place(let ref, _, _, _) where cache.messages[ref.id.raw] != nil:
                index.setCached(ref.id, true)
            default:
                break
            }
        }
        if let cursor = batch.cursor { index.cursor = cursor }
        if !gone.isEmpty { letGo(gone, deleted: true) }
        compactIfDue()
    }

    public func appendListingPage(_ page: GmailListingPage) async throws {
        try ensureLoaded()
        guard let journal else { throw GmailDiskError.notLoaded }
        try journal.append(page: page)
        index.apply(page)
        compactIfDue()
    }

    public func compact() async throws {
        try ensureLoaded()
        try compactNow()
    }

    private func compactNow() throws {
        guard let journal else { throw GmailDiskError.notLoaded }
        makeWantedSummaries()
        let next = journal.generation + 1
        let data = index.encodedSnapshot(nextGeneration: next)
        try io.replace(data, at: files.indexSnapshot)
        try journal.restart(generation: next)
        snapshotBytes = data.count
        index.trim()
        try cache.compact()
        try summaries.compact()
        try importFile.write(Dictionary(uniqueKeysWithValues: imports.map { (GmailMessageID(raw: $0.key).hex, $0.value) }))
    }

    /// Compacts once the journal is long. The change that made it long is already saved, so a
    /// compaction that fails is logged and tried again later rather than reported as a failed
    /// change.
    private func compactIfDue() {
        guard let journal else { return }
        guard journal.operations >= limits.compactOperations || journal.length >= max(limits.compactBytes, snapshotBytes) else { return }
        do {
            try compactNow()
        } catch {
            Log.warning("Store", "could not compact the Gmail index; it is tried again later", error: error,
                        code: "gmailCompactionFailed", logAs: "store")
        }
    }

    // MARK: - Labels

    public func labelTable() async -> [GmailLabelEntry] {
        try? ensureLoaded()
        return labelEntries
    }

    @discardableResult
    public func saveLabelTable(_ entries: [GmailLabelEntry]) async throws -> [GmailLabelEntry] {
        try ensureLoaded()
        guard let journal else { throw GmailDiskError.notLoaded }
        let (assigned, map) = GmailLabelTable.assign(entries, current: index.slotMap)
        if map != index.slotMap {
            try journal.append(batch: [.slots(map)], cursor: nil)
            index.apply(map)
        }
        try GmailLabelTable.save(assigned, to: files.labels, io: io)
        labelEntries = assigned
        compactIfDue()
        return assigned
    }

    // MARK: - Date anchors

    public func dateAnchors() async -> [GmailDateAnchor] {
        try? ensureLoaded()
        return GmailDateAnchoring.resolve(anchors, in: index.snapshot())
    }

    public func saveDateAnchors(_ anchors: [GmailDateAnchor]) async throws {
        try ensureLoaded()
        try GmailDateAnchorFile.save(anchors, to: files.dateAnchors, io: io)
        self.anchors = anchors
    }

    // MARK: - The newest 1,000

    public func cachedMessages(_ ids: [GmailMessageID]) async -> [GmailMessageID: GmailCachedMessage] {
        try? ensureLoaded()
        var out: [GmailMessageID: GmailCachedMessage] = [:]
        for id in ids { out[id] = cache.messages[id.raw] }
        return out
    }

    public func cachedIDs() async -> Set<GmailMessageID> {
        try? ensureLoaded()
        return Set(cache.messages.keys.map(GmailMessageID.init(raw:)))
    }

    @discardableResult
    public func cache(_ message: GmailCachedMessage, body: GmailReducedBody?) async throws -> [GmailMessageID] {
        try ensureLoaded()
        let evicted = try cache.put(message, body: body, index: index)
        if cache.messages[message.id.raw] != nil { keepSummaryCurrent(with: message) }
        dropSummaries(of: evicted.compactMap { index.record(for: $0)?.gmailThreadID })
        if cache.needsCompaction { try cache.compact() }
        return evicted
    }

    public func body(of id: GmailMessageID) async throws -> GmailReducedBody? {
        try ensureLoaded()
        return cache.body(of: id)
    }

    public func uncache(_ ids: [GmailMessageID]) async throws {
        try ensureLoaded()
        let threads = ids.compactMap { cache.messages[$0.raw]?.threadID }
        try cache.remove(ids, index: index)
        dropSummaries(of: threads)
    }

    public func setPinned(_ ids: Set<GmailMessageID>) async {
        try? ensureLoaded()
        cache.pinned = ids
    }

    public func noteFolderShown(_ label: GmailLabelID?, rows: Int, at date: Date) async {
        try? ensureLoaded()
        cache.noteShown(label, rows: rows, at: date)
    }

    public func messagesToCache(limit: Int) async -> [GmailMessageID] {
        try? ensureLoaded()
        makeWantedSummaries()
        return Array(cache.wanted(index: index, includingCached: false).prefix(max(0, limit)))
    }

    public func searchCached(_ query: String, limit: Int) async -> [GmailMessageID] {
        try? ensureLoaded()
        return cache.search(query, limit: limit)
    }

    // MARK: - Conversation summaries

    public func threadSummaries(_ ids: [GmailThreadID]) async -> [GmailThreadID: GmailThreadSummary] {
        try? ensureLoaded()
        if ids.contains(where: { summariesWanted.contains($0.raw) }) { makeWantedSummaries() }
        return summaries.summaries(ids)
    }

    public func saveThreadSummaries(_ list: [GmailThreadSummary]) async throws {
        try ensureLoaded()
        try summaries.save(list)
        if summaries.needsCompaction { try summaries.compact() }
    }

    public func removeThreadSummaries(_ ids: [GmailThreadID]) async throws {
        try ensureLoaded()
        try summaries.remove(ids)
    }

    /// A kept message joins its conversation's summary, or, when the conversation has none yet,
    /// waits for one to be made from the kept rows.
    private func keepSummaryCurrent(with message: GmailCachedMessage) {
        guard let summary = summaries.summary(message.threadID) else {
            summariesWanted.insert(message.threadID.raw)
            return
        }
        let updated = summary.adding(message)
        guard updated != summary else { return }
        do {
            try summaries.save([updated])
        } catch {
            Log.warning("Store", "could not save a Gmail conversation summary", error: error, code: "gmailSummaryUnsaved", logAs: "store")
        }
    }

    /// Makes the summary of each waiting conversation whose every message is now kept, in one
    /// pass over the index. The others are left to the engine, which asks Gmail for them.
    private func makeWantedSummaries() {
        guard !summariesWanted.isEmpty else { return }
        let wanted = summariesWanted.filter { summaries.summary(GmailThreadID(raw: $0)) == nil }
        summariesWanted = []
        guard !wanted.isEmpty else { return }
        var members: [UInt64: [GmailCachedMessage]] = [:]
        var incomplete = Set<UInt64>()
        index.records.withUnsafeBufferPointer { records in
            for record in records where wanted.contains(record.threadID) && !record.attributes.contains(.tombstone) {
                if let kept = cache.messages[record.id] {
                    members[record.threadID, default: []].append(kept)
                } else {
                    incomplete.insert(record.threadID)
                }
            }
        }
        let made = members.filter { !incomplete.contains($0.key) }.values.compactMap(GmailThreadSummary.made(from:))
        do {
            try summaries.save(made)
        } catch {
            Log.warning("Store", "could not save Gmail conversation summaries", error: error, code: "gmailSummaryUnsaved", logAs: "store")
        }
    }

    /// Summaries go with the last kept message of their conversation.
    private func dropSummaries(of threads: [GmailThreadID]) {
        guard !threads.isEmpty else { return }
        let stillKept = Set(cache.messages.values.map(\.threadID.raw))
        let orphaned = Set(threads.map(\.raw)).subtracting(stillKept).map(GmailThreadID.init(raw:))
        do {
            try summaries.remove(orphaned)
        } catch {
            Log.warning("Store", "could not remove Gmail conversation summaries", error: error, code: "gmailSummaryUnsaved", logAs: "store")
        }
    }

    /// Messages gone from Gmail leave the cache and their conversations' summaries. The index has
    /// already saved the deletion, so a failure here is repaired at the next launch rather than
    /// reported as a failed commit.
    private func letGo(_ ids: [GmailMessageID], deleted: Bool) {
        let threads = Dictionary(ids.compactMap { id in index.record(for: id).map { (id, $0.gmailThreadID) } }, uniquingKeysWith: { a, _ in a })
        do {
            try cache.remove(ids, index: index)
            if deleted {
                var changed: [GmailThreadSummary] = []
                var emptied: [GmailThreadID] = []
                for (id, thread) in threads {
                    guard let summary = changed.first(where: { $0.threadID == thread }) ?? summaries.summary(thread) else { continue }
                    changed.removeAll { $0.threadID == thread }
                    if let left = summary.removing(id) { changed.append(left) } else { emptied.append(thread) }
                }
                try summaries.save(changed)
                try summaries.remove(emptied)
            }
        } catch {
            Log.warning("Store", "could not let go of deleted Gmail messages kept on the Mac", error: error,
                        code: "gmailCacheUnsaved", logAs: "store")
        }
        dropSummaries(of: Array(threads.values))
    }

    // MARK: - The import log

    public func noteImported(_ ids: [GmailMessageID], at date: Date) async throws {
        try ensureLoaded()
        let expired = imports.filter { date.timeIntervalSince($0.value) >= limits.importMemory }.map(\.key)
        for raw in expired { imports[raw] = nil }
        try importFile.remove(expired.map { GmailMessageID(raw: $0).hex })
        for id in ids { imports[id.raw] = date }
        try importFile.set(ids.map { ($0.hex, date) })
        if importFile.shouldCompact(count: imports.count) {
            try importFile.write(Dictionary(uniqueKeysWithValues: imports.map { (GmailMessageID(raw: $0.key).hex, $0.value) }))
        }
    }

    public func wasImported(_ id: GmailMessageID) async -> Bool {
        try? ensureLoaded()
        return imports[id.raw] != nil
    }

    // MARK: - For tests

    /// What the index costs in memory now.
    func indexMemory() -> Int {
        try? ensureLoaded()
        return index.approximateMemory
    }

    /// Messages known but not yet placed, with the labels learnt for them so far.
    func pendingLabels() -> [GmailMessageID: Set<GmailLabelID>] {
        try? ensureLoaded()
        return Dictionary(uniqueKeysWithValues: index.pending.values.map { ($0.ref.id, $0.labels) })
    }
}
