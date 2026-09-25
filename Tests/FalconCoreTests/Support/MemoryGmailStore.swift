import Foundation
@testable import FalconCore

/// A Gmail store in memory behind `GmailStore`, so work built on the store can be tested before
/// the files exist. It keeps the rules the engine relies on: changes that say what the state
/// becomes, fixed slots for system labels, overflow lists past the 48 user slots, labels kept for
/// messages listed before they are placed, the cache's 1,050-back-to-1,000 and body cap, and the
/// first-screen rule. It keeps every batch and page it was given, for tests to look at; it does
/// not model a crash, which the store's own journal tests cover.
actor MemoryGmailStore: GmailStore {
    nonisolated let accountID: UUID
    nonisolated let files: GmailFiles

    private var records = ContiguousArray<GmailIndexRecord>()
    private var slotByID: [UInt64: Int32] = [:]
    private var table: [GmailLabelEntry] = []
    private var slotOf: [GmailLabelID: Int]
    private var overflowMembers: [GmailLabelID: Set<Int32>] = [:]
    private var cursor: HistoryID?
    private var resyncBegan: HistoryID?
    private var awaiting: [UInt64: (ref: GmailRef, labels: Set<GmailLabelID>)] = [:]
    private var chains: [GmailListingChain: GmailChainProgress] = [:]
    private var anchors: [GmailDateAnchor] = []
    private var cached: [UInt64: GmailCachedMessage] = [:]
    private var bodies: [UInt64: GmailReducedBody] = [:]
    private var pinned: Set<GmailMessageID> = []
    private var folderUse: [(label: GmailLabelID?, rows: Int, at: Date)] = []
    private var summaries: [GmailThreadID: GmailThreadSummary] = [:]
    private var imports: [UInt64: Date] = [:]

    private(set) var batches: [GmailJournalBatch] = []
    private(set) var pages: [GmailListingPage] = []
    private(set) var compactions = 0

    let cacheLimit: Int
    let cacheCeiling: Int
    let bodyBytesCap: Int

    init(accountID: UUID = UUID(), files: GmailFiles? = nil, cacheLimit: Int = 1_000, cacheCeiling: Int = 1_050,
         bodyBytesCap: Int = 32 * 1024 * 1024) {
        self.accountID = accountID
        self.files = files ?? GmailFiles(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryGmailStore-\(accountID.uuidString)", isDirectory: true))
        self.cacheLimit = cacheLimit
        self.cacheCeiling = cacheCeiling
        self.bodyBytesCap = bodyBytesCap
        slotOf = Dictionary(uniqueKeysWithValues: GmailLabelID.fixedSlots.enumerated().map { ($0.element, $0.offset) })
    }

    // MARK: - Loading

    func load() async throws -> GmailStoreLoad {
        GmailStoreLoad(cursor: cursor, resyncBegan: resyncBegan,
                       awaitingPlacement: awaiting.values.map(\.ref).sorted { $0.id < $1.id }, chains: chains,
                       messageCount: records.filter { !$0.attributes.contains(.tombstone) }.count)
    }

    // MARK: - The index

    func index() async -> GmailIndexSnapshot { snapshot() }

    func record(for id: GmailMessageID) async -> GmailIndexRecord? {
        slotByID[id.raw].map { records[Int($0)] }
    }

    func labels(of id: GmailMessageID) async -> Set<GmailLabelID>? {
        guard let slot = slotByID[id.raw] else { return nil }
        return labels(atSlot: slot)
    }

    /// Messages known but not yet placed, with the labels listed for them so far.
    func awaitingLabels() -> [GmailMessageID: Set<GmailLabelID>] {
        Dictionary(uniqueKeysWithValues: awaiting.map { (GmailMessageID(raw: $0.key), $0.value.labels) })
    }

    // MARK: - The journal

    func commit(_ batch: GmailJournalBatch) async throws {
        for change in batch.changes { apply(change) }
        if let next = batch.cursor { cursor = next }
        batches.append(batch)
    }

    func appendListingPage(_ page: GmailListingPage) async throws {
        for (i, ref) in page.refs.enumerated() {
            if let slot = slotByID[ref.id.raw], !records[Int(slot)].attributes.contains(.tombstone) {
                var record = records[Int(slot)]
                if let first = page.firstOrder { record.order = first - UInt32(i) * page.orderStep }
                record.labelBits |= bits(page.labels)
                record.attributes = merged(record.attributes, page.attributes)
                records[Int(slot)] = record
                setOverflow(slot, adding: page.labels, removing: [])
            } else if let first = page.firstOrder {
                let learnt = awaiting.removeValue(forKey: ref.id.raw)?.labels ?? []
                place(ref, order: first - UInt32(i) * page.orderStep, labels: learnt.union(page.labels), attributes: page.attributes)
            } else if !page.labels.isEmpty {
                awaiting[ref.id.raw] = (ref, (awaiting[ref.id.raw]?.labels ?? []).union(page.labels))
            }
        }
        let before = chains[page.chain]
        let listed = (before?.run == page.run ? before?.listed ?? 0 : 0) + page.refs.count
        chains[page.chain] = GmailChainProgress(run: page.run, nextPageToken: page.nextPageToken,
                                                isComplete: page.nextPageToken == nil, listed: listed)
        pages.append(page)
    }

    func compact() async throws {
        compactions += 1
    }

    // MARK: - Labels

    func labelTable() async -> [GmailLabelEntry] { table }

    @discardableResult
    func saveLabelTable(_ entries: [GmailLabelEntry]) async throws -> [GmailLabelEntry] {
        // Who carries each user label now, so moving a label between a bit and an overflow list
        // keeps its members.
        var members: [GmailLabelID: Set<Int32>] = [:]
        for label in Set(slotOf.keys).union(overflowMembers.keys) where label.fixedSlot == nil {
            members[label] = Set(records.indices.map(Int32.init).filter { has(label, slot: $0) })
        }
        var result = entries
        var taken: [Int: GmailLabelID] = [:]
        for i in result.indices {
            if let fixed = result[i].id.fixedSlot {
                result[i].slot = fixed
            } else if result[i].isShown, result[i].kind == .user, let kept = slotOf[result[i].id] {
                result[i].slot = kept
                taken[kept] = result[i].id
            } else {
                result[i].slot = nil
            }
        }
        let waiting = result.indices
            .filter { result[$0].kind == .user && result[$0].isShown && result[$0].slot == nil }
            .sorted { (result[$0].counts?.messagesTotal ?? 0, result[$1].name) > (result[$1].counts?.messagesTotal ?? 0, result[$0].name) }
        var free = (GmailLabelID.firstUserSlot..<GmailLabelID.slotCount).filter { taken[$0] == nil }
        for i in waiting where !free.isEmpty {
            result[i].slot = free.removeFirst()
        }
        var newSlotOf = Dictionary(uniqueKeysWithValues: GmailLabelID.fixedSlots.enumerated().map { ($0.element, $0.offset) })
        var newOverflow: [GmailLabelID: Set<Int32>] = [:]
        for entry in result where entry.id.fixedSlot == nil && entry.isShown && entry.kind == .user {
            if let slot = entry.slot { newSlotOf[entry.id] = slot } else { newOverflow[entry.id] = [] }
        }
        // Every user bit is written again from the members worked out above.
        let userMask = ~UInt64(0) << UInt64(GmailLabelID.firstUserSlot)
        for i in records.indices { records[i].labelBits &= ~userMask }
        for (label, slots) in members {
            if let bit = newSlotOf[label] {
                for slot in slots { records[Int(slot)].labelBits |= 1 << UInt64(bit) }
            } else if newOverflow[label] != nil {
                newOverflow[label] = slots
            }
        }
        slotOf = newSlotOf
        overflowMembers = newOverflow
        table = result
        return result
    }

    // MARK: - Date anchors

    func dateAnchors() async -> [GmailDateAnchor] { anchors }
    func saveDateAnchors(_ anchors: [GmailDateAnchor]) async throws { self.anchors = anchors }

    // MARK: - The newest 1,000

    func cachedMessages(_ ids: [GmailMessageID]) async -> [GmailMessageID: GmailCachedMessage] {
        var out: [GmailMessageID: GmailCachedMessage] = [:]
        for id in ids { out[id] = cached[id.raw] }
        return out
    }

    func cachedIDs() async -> Set<GmailMessageID> { Set(cached.keys.map(GmailMessageID.init(raw:))) }

    @discardableResult
    func cache(_ message: GmailCachedMessage, body: GmailReducedBody?) async throws -> [GmailMessageID] {
        cached[message.id.raw] = message
        if let body { bodies[message.id.raw] = body }
        setCachedBit(message.id, true)
        var evicted: [GmailMessageID] = []
        if cached.count >= cacheCeiling {
            let evictable = cached.keys.filter { !pinned.contains(GmailMessageID(raw: $0)) }.sorted { orderOf($0) < orderOf($1) }
            evicted = evictable.prefix(cached.count - cacheLimit).map(GmailMessageID.init(raw:))
            for id in evicted { drop(id) }
        }
        var bytes = bodies.values.reduce(0) { $0 + $1.byteCount }
        if bytes > bodyBytesCap {
            // The oldest bodies go first; their rows stay, so the list still paints from disk.
            for raw in bodies.keys.filter({ !pinned.contains(GmailMessageID(raw: $0)) }).sorted(by: { orderOf($0) < orderOf($1) }) {
                guard bytes > bodyBytesCap else { break }
                bytes -= bodies.removeValue(forKey: raw)?.byteCount ?? 0
            }
        }
        return evicted
    }

    func body(of id: GmailMessageID) async throws -> GmailReducedBody? { bodies[id.raw] }

    func uncache(_ ids: [GmailMessageID]) async throws {
        for id in ids { drop(id) }
    }

    func setPinned(_ ids: Set<GmailMessageID>) async { pinned = ids }

    func noteFolderShown(_ label: GmailLabelID?, rows: Int, at date: Date) async {
        folderUse.removeAll { $0.label == label }
        folderUse.append((label, rows, date))
    }

    func messagesToCache(limit: Int) async -> [GmailMessageID] {
        let snap = snapshot()
        let newestFirst = snap.byOrder.reversed().filter { eligible(snap.records[Int($0)]) }
        var wanted: [UInt64] = []
        var seen: Set<UInt64> = []
        func want(_ raw: UInt64) {
            guard wanted.count < cacheLimit, seen.insert(raw).inserted else { return }
            wanted.append(raw)
        }
        for id in pinned.sorted() {
            if let slot = snap.slotByID[id.raw], eligible(snap.records[Int(slot)]) { want(id.raw) }
        }
        // The Inbox and the 12 folders used most recently keep one screen each, 20 to 30 rows.
        let inbox = folderUse.first { $0.label == .inbox }
        let others = folderUse.filter { $0.label != .inbox }.sorted { $0.at > $1.at }.prefix(12)
        var screens: [(label: GmailLabelID?, rows: Int)] = [(.inbox, inbox?.rows ?? 20)]
        screens += others.map { (label: $0.label, rows: $0.rows) }
        for screen in screens {
            let rows = min(30, max(20, screen.rows))
            let members = newestFirst.filter { slot in screen.label.map { snap.record(atSlot: slot, has: $0) } ?? true }
            for slot in members.prefix(rows) { want(snap.records[Int(slot)].id) }
        }
        for slot in newestFirst { want(snap.records[Int(slot)].id) }
        return Array(wanted.filter { cached[$0] == nil }.prefix(limit).map(GmailMessageID.init(raw:)))
    }

    func searchCached(_ query: String, limit: Int) async -> [GmailMessageID] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return [] }
        let hits = cached.values.filter { m in
            let text = ([m.subject, m.preview, m.from.name, m.from.address] + m.to.map(\.address) + m.cc.map(\.address))
                .joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        return Array(hits.sorted { ($0.date, $0.id) > ($1.date, $1.id) }.prefix(limit).map(\.id))
    }

    // MARK: - Conversation summaries

    func threadSummaries(_ ids: [GmailThreadID]) async -> [GmailThreadID: GmailThreadSummary] {
        var out: [GmailThreadID: GmailThreadSummary] = [:]
        for id in ids { out[id] = summaries[id] }
        return out
    }

    func saveThreadSummaries(_ summaries: [GmailThreadSummary]) async throws {
        for summary in summaries { self.summaries[summary.threadID] = summary }
    }

    func removeThreadSummaries(_ ids: [GmailThreadID]) async throws {
        for id in ids { summaries[id] = nil }
    }

    // MARK: - The import log

    func noteImported(_ ids: [GmailMessageID], at date: Date) async throws {
        imports = imports.filter { date.timeIntervalSince($0.value) < 7 * 24 * 3600 }
        for id in ids { imports[id.raw] = date }
    }

    func wasImported(_ id: GmailMessageID) async -> Bool { imports[id.raw] != nil }

    // MARK: - Inside the actor

    private func apply(_ change: GmailChange) {
        switch change {
        case .place(let ref, let order, let labels, let attributes):
            awaiting[ref.id.raw] = nil
            place(ref, order: order, labels: labels, attributes: attributes)
        case .relabel(let id, let adding, let removing):
            if let slot = slotByID[id.raw] {
                records[Int(slot)].labelBits = (records[Int(slot)].labelBits | bits(adding)) & ~bits(removing)
                setOverflow(slot, adding: adding, removing: removing)
            } else if let waiting = awaiting[id.raw] {
                awaiting[id.raw] = (waiting.ref, waiting.labels.union(adding).subtracting(removing))
            }
        case .attributes(let id, let setting, let clearing):
            guard let slot = slotByID[id.raw] else { return }
            records[Int(slot)].attributes = records[Int(slot)].attributes.subtracting(clearing).union(setting)
        case .tombstone(let id):
            awaiting[id.raw] = nil
            drop(id)
            guard let slot = slotByID[id.raw] else { return }
            records[Int(slot)].attributes.insert(.tombstone)
            for label in overflowMembers.keys { overflowMembers[label]?.remove(slot) }
        case .awaitingPlacement(let ref):
            if let slot = slotByID[ref.id.raw], !records[Int(slot)].attributes.contains(.tombstone) { return }
            awaiting[ref.id.raw] = (ref, awaiting[ref.id.raw]?.labels ?? [])
        case .resyncBegan(let history):
            resyncBegan = history
        case .resyncEnded:
            resyncBegan = nil
        }
    }

    private func place(_ ref: GmailRef, order: UInt32, labels: Set<GmailLabelID>, attributes: GmailRecordAttributes) {
        let slot: Int32
        if let existing = slotByID[ref.id.raw] {
            slot = existing
        } else {
            slot = Int32(records.count)
            records.append(GmailIndexRecord(id: ref.id, threadID: ref.threadID, order: order))
            slotByID[ref.id.raw] = slot
        }
        let keptCached = records[Int(slot)].attributes.intersection(.cached)
        var record = GmailIndexRecord(id: ref.id, threadID: ref.threadID, labelBits: bits(labels), order: order,
                                      attributes: attributes.subtracting(.cached).union(keptCached))
        if cached[ref.id.raw] != nil { record.attributes.insert(.cached) }
        records[Int(slot)] = record
        setOverflow(slot, adding: labels, removing: Set(overflowMembers.keys).subtracting(labels))
    }

    private func merged(_ old: GmailRecordAttributes, _ new: GmailRecordAttributes) -> GmailRecordAttributes {
        new.contains(.sizeKnown) ? old.subtracting(.allSizeBands).union(new) : old.union(new)
    }

    private func bits(_ labels: Set<GmailLabelID>) -> UInt64 {
        labels.reduce(0) { bits, label in slotOf[label].map { bits | 1 << UInt64($0) } ?? bits }
    }

    private func setOverflow(_ slot: Int32, adding: Set<GmailLabelID>, removing: Set<GmailLabelID>) {
        for label in overflowMembers.keys {
            if adding.contains(label) { overflowMembers[label]?.insert(slot) } else if removing.contains(label) { overflowMembers[label]?.remove(slot) }
        }
    }

    private func has(_ label: GmailLabelID, slot: Int32) -> Bool {
        if let bit = slotOf[label] { return records[Int(slot)].has(slot: bit) }
        return overflowMembers[label]?.contains(slot) ?? false
    }

    private func labels(atSlot slot: Int32) -> Set<GmailLabelID> {
        Set(slotOf.keys.filter { has($0, slot: slot) }).union(overflowMembers.keys.filter { has($0, slot: slot) })
    }

    private func eligible(_ record: GmailIndexRecord) -> Bool {
        !record.attributes.contains(.tombstone) && !record.attributes.contains(.provisional)
            && !record.hasSystemLabel(.spam) && !record.hasSystemLabel(.trash) && !record.hasSystemLabel(.chat)
    }

    private func orderOf(_ raw: UInt64) -> UInt32 {
        slotByID[raw].map { records[Int($0)].order } ?? 0
    }

    private func setCachedBit(_ id: GmailMessageID, _ on: Bool) {
        guard let slot = slotByID[id.raw] else { return }
        if on { records[Int(slot)].attributes.insert(.cached) } else { records[Int(slot)].attributes.remove(.cached) }
    }

    private func drop(_ id: GmailMessageID) {
        cached[id.raw] = nil
        bodies[id.raw] = nil
        setCachedBit(id, false)
    }

    private func snapshot() -> GmailIndexSnapshot {
        let alive = records.indices.filter { !records[$0].attributes.contains(.tombstone) }
        let byOrder = ContiguousArray(alive.sorted { (records[$0].order, records[$0].id) < (records[$1].order, records[$1].id) }.map(Int32.init))
        return GmailIndexSnapshot(records: records, byOrder: byOrder, slotByID: slotByID, labelSlots: slotOf,
                                  overflow: overflowMembers.mapValues { ContiguousArray($0.sorted()) })
    }
}
