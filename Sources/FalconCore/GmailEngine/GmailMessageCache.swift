import Foundation

/// A folder the owner opened, and how many rows its list showed.
struct GmailFolderScreen: Codable, Hashable, Sendable {
    /// Nil for Archive, which has no label.
    var label: GmailLabelID?
    var rows: Int
    var shownAt: Date
}

/// The newest messages of the account, up to the store's limit (25,000), kept on the Mac with
/// their rows, reply headers and reduced bodies, so lists fill and messages open at once and
/// offline. Bodies are capped in bytes; past the cap the oldest go and their rows stay.
///
/// Which messages belong, in this order until the limit is reached:
/// 1. those pinned: drafts, messages with a change waiting, and those open in a window or tab;
/// 2. one screen of the Inbox and of each of the 12 other folders used most recently;
/// 3. the newest of the account.
///
/// Never Junk Email, Deleted Items, chats or mail not shown yet. Flags and labels are never kept
/// here; they are always read from the index, so a cache that lags the journal can be incomplete
/// but never wrong.
final class GmailMessageCache {
    let limit: Int
    /// The count may reach this before anything goes, so eviction runs once every 50 new
    /// messages rather than at each one.
    let ceiling: Int
    /// On-disk bytes of the bodies. Past it the oldest bodies go and their rows stay.
    let bodyBytesCap: Int
    /// The folders used most recently that keep their first screen, the Inbox apart.
    static let recentFolders = 12
    static let screenRows = 20...30
    private static let rememberedScreens = 50

    private let files: GmailFiles
    private let io: GmailDiskIO
    private let rows: GmailRecordFile<GmailCachedMessage>
    let bodies: GmailBodyStore
    private(set) var messages: [UInt64: GmailCachedMessage] = [:]
    var pinned: Set<GmailMessageID> = []
    private(set) var screens: [GmailFolderScreen] = []
    /// Each kept message's header and preview words, folded for matching, made when first searched.
    private var searchText: [UInt64: String] = [:]

    init(files: GmailFiles, io: GmailDiskIO, limit: Int, ceiling: Int, bodyBytesCap: Int) {
        self.files = files
        self.io = io
        self.limit = limit
        self.ceiling = max(limit, ceiling)
        self.bodyBytesCap = bodyBytesCap
        rows = GmailRecordFile(snapshot: files.cacheRows, journal: files.cacheRowsJournal, io: io, what: "kept Gmail rows")
        bodies = GmailBodyStore(files: files, io: io)
    }

    // MARK: - Loading

    /// Reads the kept rows and drops those whose message the index no longer holds, which a crash
    /// between the index's journal and the cache's can leave. Returns what was dropped.
    @discardableResult
    func load(index: GmailIndex) -> [GmailMessageID] {
        var dropped: [GmailMessageID] = []
        for (key, message) in rows.load() {
            guard let id = GmailMessageID(hex: key), id == message.id, index.isLive(id) else {
                dropped.append(message.id)
                continue
            }
            messages[id.raw] = message
        }
        if !dropped.isEmpty {
            try? rows.remove(dropped.map(\.hex))
        }
        bodies.load { messages[$0] != nil }
        if let data = try? Data(contentsOf: files.folderScreens),
           let stored = try? JSONDecoder().decode([GmailFolderScreen].self, from: data) {
            screens = stored
        }
        return dropped
    }

    // MARK: - Keeping and letting go

    /// Keeps a message, then lets go of what no longer belongs once the count reaches the ceiling,
    /// and of the oldest bodies once they pass the cap. Returns the messages that left.
    func put(_ message: GmailCachedMessage, body: GmailReducedBody?, index: GmailIndex) throws -> [GmailMessageID] {
        if let body { try bodies.write(body, for: message.id) }
        try rows.set(message.id.hex, message)
        messages[message.id.raw] = message
        searchText[message.id.raw] = nil
        index.setCached(message.id, true)

        var evicted: [GmailMessageID] = []
        // Everything the rule no longer wants goes, not only the oldest 50: kept longer, it would
        // go anyway once the fill brings in what the rule wants instead. Going by the rule rather
        // than by age also keeps an old folder's first screen from being let go and fetched again.
        if messages.count >= ceiling {
            let keep = Set(wanted(index: index, includingCached: true).map(\.raw)).union(pinned.map(\.raw))
            evicted = messages.keys.filter { !keep.contains($0) }
                .sorted { GmailMessageCache.older($0, $1, index) }
                .map(GmailMessageID.init(raw:))
            try remove(evicted, index: index)
        }
        if bodies.totalBytes > bodyBytesCap { trimBodies(index: index) }
        return evicted
    }

    func remove(_ ids: [GmailMessageID], index: GmailIndex) throws {
        let present = ids.filter { messages[$0.raw] != nil || bodies.has($0) }
        guard !present.isEmpty else { return }
        for id in present {
            messages[id.raw] = nil
            searchText[id.raw] = nil
            bodies.remove(id)
            index.setCached(id, false)
        }
        try rows.remove(present.map(\.hex))
    }

    func body(of id: GmailMessageID) -> GmailReducedBody? {
        messages[id.raw] == nil ? nil : bodies.read(id)
    }

    /// Drops the bodies of the oldest kept messages until the rest fit under the cap. Pinned
    /// messages keep theirs; so does every row.
    private func trimBodies(index: GmailIndex) {
        let oldestFirst = bodies.sizes.keys
            .filter { !pinned.contains(GmailMessageID(raw: $0)) }
            .sorted { GmailMessageCache.older($0, $1, index) }
        for raw in oldestFirst where bodies.totalBytes > bodyBytesCap {
            bodies.remove(GmailMessageID(raw: raw))
        }
    }

    /// Oldest first by the index's order; a message the index does not hold goes before any it
    /// does.
    private static func older(_ a: UInt64, _ b: UInt64, _ index: GmailIndex) -> Bool {
        let ra = index.record(for: GmailMessageID(raw: a))
        let rb = index.record(for: GmailMessageID(raw: b))
        let oa = ra.map { $0.attributes.contains(.tombstone) ? -1 : Int64($0.order) } ?? -1
        let ob = rb.map { $0.attributes.contains(.tombstone) ? -1 : Int64($0.order) } ?? -1
        return oa != ob ? oa < ob : a < b
    }

    func compact() throws {
        try rows.write(Dictionary(uniqueKeysWithValues: messages.values.map { ($0.id.hex, $0) }))
    }

    var needsCompaction: Bool { rows.shouldCompact(count: messages.count) }

    // MARK: - The first-screen rule

    /// Remembers that the owner opened a folder, and how many rows its list showed.
    func noteShown(_ label: GmailLabelID?, rows count: Int, at date: Date) {
        screens.removeAll { $0.label == label }
        screens.insert(GmailFolderScreen(label: label, rows: count, shownAt: date), at: 0)
        screens.sort { $0.shownAt > $1.shownAt }
        if screens.count > GmailMessageCache.rememberedScreens { screens.removeLast(screens.count - GmailMessageCache.rememberedScreens) }
        do {
            try io.replace(try JSONEncoder().encode(screens), at: files.folderScreens)
        } catch {
            Log.warning("Store", "could not save which Gmail folders were opened", error: error, code: "gmailScreensUnsaved", logAs: "store")
        }
    }

    /// The folders whose first screen is kept: the Inbox, then the 12 others used most recently.
    /// Junk Email and Deleted Items are never kept, so they never take a place.
    var keptScreens: [(label: GmailLabelID?, rows: Int)] {
        func clamp(_ rows: Int) -> Int { min(GmailMessageCache.screenRows.upperBound, max(GmailMessageCache.screenRows.lowerBound, rows)) }
        let inbox = screens.first { $0.label == .inbox }
        var out: [(label: GmailLabelID?, rows: Int)] = [(.inbox, clamp(inbox?.rows ?? GmailMessageCache.screenRows.lowerBound))]
        for screen in screens where screen.label != .inbox && screen.label != .spam && screen.label != .trash && screen.label != .chat {
            guard out.count <= GmailMessageCache.recentFolders else { break }
            out.append((screen.label, clamp(screen.rows)))
        }
        return out
    }

    /// The messages that belong in the cache, the most wanted first, up to the limit: those
    /// pinned, then the kept first screens, then the newest.
    ///
    /// A screen is what the folder's list shows first in either view: the newest message of each
    /// of its first conversations, then its newest messages, at most one screen of rows in all.
    /// Conversations come first because they are the list's default.
    func wanted(index: GmailIndex, includingCached: Bool) -> [GmailMessageID] {
        var chosen: [UInt64] = []
        var seen = Set<UInt64>()
        func take(_ raw: UInt64) {
            guard chosen.count < limit, seen.insert(raw).inserted else { return }
            chosen.append(raw)
        }
        let records = index.records
        func eligible(_ slot: Int32) -> Bool {
            GmailMessageCache.eligible(records[Int(slot)])
        }

        for id in pinned.sorted() {
            if let slot = index.slot(of: id), eligible(slot) { take(id.raw) }
        }

        let kept = keptScreens
        var heads = [[UInt64]](repeating: [], count: kept.count)
        var firsts = [[UInt64]](repeating: [], count: kept.count)
        var threads = [Set<UInt64>](repeating: [], count: kept.count)
        var open = Set(kept.indices)
        var newest: [UInt64] = []
        var needNewest = true
        for slot in index.byOrder.reversed() {
            guard eligible(slot) else { continue }
            let record = records[Int(slot)]
            if needNewest {
                newest.append(record.id)
                needNewest = newest.count < limit
            }
            for i in open {
                if let label = kept[i].label, !index.has(label, slot: slot) { continue }
                let rows = kept[i].rows
                if firsts[i].count < rows { firsts[i].append(record.id) }
                if heads[i].count < rows, threads[i].insert(record.threadID).inserted { heads[i].append(record.id) }
                if firsts[i].count >= rows, heads[i].count >= rows { open.remove(i) }
            }
            if open.isEmpty, !needNewest { break }
        }
        for i in kept.indices {
            var screen = heads[i]
            let inScreen = Set(screen)
            screen += firsts[i].filter { !inScreen.contains($0) }
            for raw in screen.prefix(kept[i].rows) { take(raw) }
        }
        for raw in newest { take(raw) }
        let out = includingCached ? chosen : chosen.filter { messages[$0] == nil }
        return out.map(GmailMessageID.init(raw:))
    }

    static func eligible(_ record: GmailIndexRecord) -> Bool {
        !record.attributes.contains(.tombstone) && !record.attributes.contains(.provisional)
            && !record.hasSystemLabel(.spam) && !record.hasSystemLabel(.trash) && !record.hasSystemLabel(.chat)
    }

    // MARK: - Searching offline

    /// Kept messages whose sender, recipients, subject or preview hold every word of `query`,
    /// ignoring case and accents, newest first.
    func search(_ query: String, limit count: Int) -> [GmailMessageID] {
        let words = GmailMessageCache.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, count > 0 else { return [] }
        var hits: [GmailCachedMessage] = []
        for (raw, message) in messages {
            let text: String
            if let known = searchText[raw] {
                text = known
            } else {
                text = GmailMessageCache.fold(GmailMessageCache.searchable(message))
                searchText[raw] = text
            }
            if words.allSatisfy({ text.contains($0) }) { hits.append(message) }
        }
        return hits.sorted { ($0.date, $0.id) > ($1.date, $1.id) }.prefix(count).map(\.id)
    }

    private static func searchable(_ m: GmailCachedMessage) -> String {
        var parts = [m.subject, m.preview, m.from.name, m.from.address]
        for address in m.to + m.cc { parts.append(address.name); parts.append(address.address) }
        return parts.joined(separator: " ")
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
