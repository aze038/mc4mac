import Foundation

/// A message known to exist but not yet in the index: waiting to be fetched and placed, or seen
/// in a label's listing before All Mail's listing reached it. The labels learnt meanwhile are
/// kept, so the message has them once it is placed.
struct GmailPendingPlacement: Hashable, Sendable {
    var ref: GmailRef
    var labels: Set<GmailLabelID>
    /// Its fetch failed for now, and the next check tries again. A message seen only in a label's
    /// listing is left to All Mail's listing instead.
    var awaiting: Bool
}

/// The whole mailbox at 32 bytes a message: every message's place in the order, its labels as
/// bits, its conversation and a few attributes, and no text or dates.
///
/// It is only ever changed by applying journal entries, which say what the state becomes; the
/// store writes each entry to the journal before applying it, so replaying the journal on the
/// snapshot rebuilds exactly this. Not thread-safe: the store's actor owns it.
final class GmailIndex {
    /// By slot. A slot never moves while the index is in memory; a deleted message stays as a
    /// tombstone until the snapshot is next read.
    private(set) var records = ContiguousArray<GmailIndexRecord>()
    private(set) var slotByID: [UInt64: Int32] = [:]
    /// Live slots, oldest first, by order and then id.
    private(set) var byOrder = ContiguousArray<Int32>()
    private(set) var slotMap = GmailSlotMap()
    /// Every label with a bit: the fixed system labels and the slotted user labels.
    private(set) var labelSlots: [GmailLabelID: Int] = GmailIndex.fixedLabelSlots
    /// Members of each overflow label, as sorted slots.
    private(set) var overflow: [GmailLabelID: ContiguousArray<Int32>] = [:]
    private(set) var pending: [UInt64: GmailPendingPlacement] = [:]
    var cursor: HistoryID?
    var resyncBegan: HistoryID?
    private(set) var chains: [GmailListingChain: GmailChainProgress] = [:]
    private(set) var liveCount = 0
    private var labelForBit = [GmailLabelID?](repeating: nil, count: GmailLabelID.slotCount)

    static let fixedLabelSlots: [GmailLabelID: Int] =
        Dictionary(uniqueKeysWithValues: GmailLabelID.fixedSlots.enumerated().map { ($0.element, $0.offset) })

    /// Attributes the index keeps for itself: the cache says which messages it holds, and only a
    /// tombstone change deletes one. Neither may arrive in a change or a page.
    static let ownAttributes: GmailRecordAttributes = [.cached, .tombstone]

    private static let userBitsMask = ~UInt64(0) << UInt64(GmailLabelID.firstUserSlot)

    init() {
        rebuildLabelSlots()
    }

    // MARK: - Reading

    func snapshot() -> GmailIndexSnapshot {
        GmailIndexSnapshot(records: records, byOrder: byOrder, slotByID: slotByID, labelSlots: labelSlots, overflow: overflow)
    }

    func slot(of id: GmailMessageID) -> Int32? { slotByID[id.raw] }

    func record(for id: GmailMessageID) -> GmailIndexRecord? {
        slotByID[id.raw].map { records[Int($0)] }
    }

    func isLive(_ id: GmailMessageID) -> Bool {
        guard let slot = slotByID[id.raw] else { return false }
        return !records[Int(slot)].attributes.contains(.tombstone)
    }

    func has(_ label: GmailLabelID, slot: Int32) -> Bool {
        if let bit = labelSlots[label] { return records[Int(slot)].has(slot: bit) }
        guard let members = overflow[label] else { return false }
        return GmailIndex.search(members, for: slot).found
    }

    func labels(atSlot slot: Int32) -> Set<GmailLabelID> {
        var bits = records[Int(slot)].labelBits
        var out = Set<GmailLabelID>()
        while bits != 0 {
            let bit = bits.trailingZeroBitCount
            if let label = labelForBit[bit] { out.insert(label) }
            bits &= bits - 1
        }
        for (label, members) in overflow where GmailIndex.search(members, for: slot).found { out.insert(label) }
        return out
    }

    /// The live messages of one conversation, oldest first.
    func liveMembers(ofThread thread: GmailThreadID) -> [Int32] {
        var out: [Int32] = []
        records.withUnsafeBufferPointer { buffer in
            for i in buffer.indices where buffer[i].threadID == thread.raw && !buffer[i].attributes.contains(.tombstone) {
                out.append(Int32(i))
            }
        }
        return out.sorted { precedes($0, $1) }
    }

    /// Whether every listing of All Mail seen so far has reached its end, so a message still known
    /// only from a label's listing was skipped by it rather than not reached yet.
    var allMailListed: Bool {
        var any = false
        for (chain, progress) in chains {
            guard case .allMail = chain else { continue }
            guard progress.isComplete else { return false }
            any = true
        }
        return any
    }

    /// What the index costs in memory, for the budget of about 13 MB at 200,000 messages. A
    /// dictionary's storage is its buckets, of which it keeps a quarter free.
    var approximateMemory: Int {
        let buckets = max(1, Int((Double(slotByID.capacity) / 0.75).rounded(.up))).nextPowerOfTwo
        let dictionary = buckets * (MemoryLayout<UInt64>.stride + MemoryLayout<Int32>.stride) + buckets / 8
        let lists = overflow.values.reduce(0) { $0 + $1.capacity * MemoryLayout<Int32>.stride }
        let waiting = pending.count * (MemoryLayout<GmailPendingPlacement>.stride + 16)
        return records.capacity * MemoryLayout<GmailIndexRecord>.stride + byOrder.capacity * MemoryLayout<Int32>.stride
            + dictionary + lists + waiting
    }

    // MARK: - Changing

    func apply(_ entry: GmailJournalEntry) {
        switch entry {
        case .change(let change): apply(change)
        case .slots(let map): apply(map)
        }
    }

    func apply(_ change: GmailChange) {
        switch change {
        case .place(let ref, let order, let labels, let attributes):
            pending[ref.id.raw] = nil
            place(ref, order: order, labels: labels, attributes: attributes)
        case .relabel(let id, let adding, let removing):
            if let slot = slotByID[id.raw] {
                records[Int(slot)].labelBits = (records[Int(slot)].labelBits | bits(adding)) & ~bits(removing)
                // Overflow lists hold live messages only; a deleted one that comes back is given
                // its labels afresh.
                guard !records[Int(slot)].attributes.contains(.tombstone) else { return }
                for label in adding where overflow[label] != nil { insertMember(slot, into: label) }
                for label in removing where overflow[label] != nil { removeMember(slot, from: label) }
            } else if var waiting = pending[id.raw] {
                waiting.labels.formUnion(adding)
                waiting.labels.subtract(removing)
                pending[id.raw] = waiting
            }
        case .attributes(let id, let setting, let clearing):
            guard let slot = slotByID[id.raw] else { return }
            let own = GmailIndex.ownAttributes
            var attributes = records[Int(slot)].attributes
            attributes = attributes.subtracting(clearing.subtracting(own)).union(setting.subtracting(own))
            records[Int(slot)].attributes = attributes
        case .tombstone(let id):
            pending[id.raw] = nil
            guard let slot = slotByID[id.raw], !records[Int(slot)].attributes.contains(.tombstone) else { return }
            removeFromOrder(slot, order: records[Int(slot)].order, id: id.raw)
            records[Int(slot)].attributes.insert(.tombstone)
            records[Int(slot)].attributes.remove(.cached)
            liveCount -= 1
            for label in Array(overflow.keys) { removeMember(slot, from: label) }
        case .awaitingPlacement(let ref):
            if isLive(ref.id) { return }
            pending[ref.id.raw] = GmailPendingPlacement(ref: ref, labels: pending[ref.id.raw]?.labels ?? [], awaiting: true)
        case .resyncBegan(let history):
            resyncBegan = history
        case .resyncEnded:
            resyncBegan = nil
        }
    }

    /// One page of a listing: places what All Mail lists, sets the bits a label's listing gives,
    /// and learns attributes from a search. It never removes anything.
    func apply(_ page: GmailListingPage) {
        let mask = bits(page.labels)
        let listedLabels = page.labels.filter { overflow[$0] != nil }
        let attributes = page.attributes.subtracting(GmailIndex.ownAttributes)
        var moved: [(slot: Int32, order: UInt32, id: UInt64)] = []
        var entering: [Int32] = []
        var enteringSet = Set<Int32>()
        var members: [Int32] = []

        for (i, ref) in page.refs.enumerated() {
            let order = page.firstOrder.map { GmailIndex.order($0, minus: i, step: page.orderStep) }
            if let slot = slotByID[ref.id.raw], !records[Int(slot)].attributes.contains(.tombstone) {
                var record = records[Int(slot)]
                if let order, order != record.order {
                    if !enteringSet.contains(slot) {
                        moved.append((slot, record.order, record.id))
                        entering.append(slot)
                        enteringSet.insert(slot)
                    }
                    record.order = order
                }
                record.labelBits |= mask
                record.attributes = GmailIndex.merged(record.attributes, attributes)
                records[Int(slot)] = record
                if !listedLabels.isEmpty { members.append(slot) }
            } else if let order {
                let learnt = pending.removeValue(forKey: ref.id.raw)?.labels ?? []
                let labels = learnt.union(page.labels)
                let slot = store(GmailIndexRecord(id: ref.id, threadID: ref.threadID, labelBits: bits(labels), order: order,
                                                  attributes: attributes))
                if enteringSet.insert(slot).inserted { entering.append(slot) }
                liveCount += 1
                setMembership(slot, labels)
            } else if !page.labels.isEmpty {
                var waiting = pending[ref.id.raw] ?? GmailPendingPlacement(ref: ref, labels: [], awaiting: false)
                waiting.labels.formUnion(page.labels)
                pending[ref.id.raw] = waiting
            }
        }

        if moved.count > 16 {
            let leaving = Set(moved.map(\.slot))
            byOrder.removeAll { leaving.contains($0) }
        } else {
            for m in moved { removeFromOrder(m.slot, order: m.order, id: m.id) }
        }
        insertIntoOrder(entering)
        if !members.isEmpty {
            let sorted = members.sorted()
            for label in listedLabels { mergeMembers(sorted, into: label) }
        }

        let before = chains[page.chain]
        let listed = (before?.run == page.run ? before?.listed ?? 0 : 0) + page.refs.count
        chains[page.chain] = GmailChainProgress(run: page.run, nextPageToken: page.nextPageToken,
                                                isComplete: page.nextPageToken == nil, listed: listed)
        if case .allMail = page.chain, page.nextPageToken == nil { trim() }
    }

    /// Gives user labels their bits and lists as `map` says, moving each label's members so that
    /// no message gains or loses a label. A label `map` no longer tracks leaves every record.
    func apply(_ map: GmailSlotMap) {
        guard map != slotMap else { return }
        var members: [GmailLabelID: [Int32]] = [:]
        records.withUnsafeBufferPointer { buffer in
            for i in buffer.indices {
                var bits = buffer[i].labelBits & GmailIndex.userBitsMask
                guard bits != 0, !buffer[i].attributes.contains(.tombstone) else { continue }
                while bits != 0 {
                    let bit = bits.trailingZeroBitCount
                    if let label = labelForBit[bit] { members[label, default: []].append(Int32(i)) }
                    bits &= bits - 1
                }
            }
        }
        for (label, list) in overflow { members[label] = Array(list) }
        let keep = ~GmailIndex.userBitsMask
        for i in records.indices { records[i].labelBits &= keep }
        for (label, bit) in map.userSlots {
            for slot in members[label] ?? [] { records[Int(slot)].labelBits |= 1 << UInt64(bit) }
        }
        var lists: [GmailLabelID: ContiguousArray<Int32>] = [:]
        for label in map.overflow { lists[label] = ContiguousArray((members[label] ?? []).sorted()) }
        overflow = lists
        slotMap = map
        rebuildLabelSlots()
    }

    /// Marks which messages the cache holds. The cache is the truth for this bit; the index only
    /// mirrors it so that a view can tell without asking.
    func setCached(_ id: GmailMessageID, _ cached: Bool) {
        guard let slot = slotByID[id.raw] else { return }
        if cached, !records[Int(slot)].attributes.contains(.tombstone) {
            records[Int(slot)].attributes.insert(.cached)
        } else {
            records[Int(slot)].attributes.remove(.cached)
        }
    }

    func setCachedBits(_ cached: Set<UInt64>) {
        for i in records.indices {
            let holds = cached.contains(records[i].id) && !records[i].attributes.contains(.tombstone)
            if holds { records[i].attributes.insert(.cached) } else { records[i].attributes.remove(.cached) }
        }
    }

    /// Frees the room arrays keep for growing, once a listing has placed everything: 200,000
    /// records would otherwise sit in room for 262,144.
    func trim() {
        if records.capacity > records.count + records.count / 8 {
            records = records.withUnsafeBufferPointer { ContiguousArray($0) }
        }
        if byOrder.capacity > byOrder.count + byOrder.count / 8 {
            byOrder = byOrder.withUnsafeBufferPointer { ContiguousArray($0) }
        }
    }

    // MARK: - Inside

    private func place(_ ref: GmailRef, order: UInt32, labels: Set<GmailLabelID>, attributes: GmailRecordAttributes) {
        let own = attributes.subtracting(GmailIndex.ownAttributes)
        if let slot = slotByID[ref.id.raw] {
            let old = records[Int(slot)]
            let wasLive = !old.attributes.contains(.tombstone)
            if wasLive { removeFromOrder(slot, order: old.order, id: old.id) } else { liveCount += 1 }
            records[Int(slot)] = GmailIndexRecord(id: ref.id, threadID: ref.threadID, labelBits: bits(labels), order: order,
                                                  attributes: own.union(wasLive ? old.attributes.intersection(.cached) : []))
            insertIntoOrder(slot)
        } else {
            let slot = store(GmailIndexRecord(id: ref.id, threadID: ref.threadID, labelBits: bits(labels), order: order,
                                              attributes: own))
            liveCount += 1
            insertIntoOrder(slot)
        }
        setMembership(slotByID[ref.id.raw]!, labels)
    }

    /// Makes `slot` a member of exactly the overflow labels among `labels`.
    private func setMembership(_ slot: Int32, _ labels: Set<GmailLabelID>) {
        for label in Array(overflow.keys) {
            if labels.contains(label) { insertMember(slot, into: label) } else { removeMember(slot, from: label) }
        }
    }

    /// Adds a record in a new slot, or over its tombstone, and returns the slot. The caller puts
    /// it into the order.
    private func store(_ record: GmailIndexRecord) -> Int32 {
        if let slot = slotByID[record.id] {
            records[Int(slot)] = record
            return slot
        }
        let slot = Int32(records.count)
        records.append(record)
        slotByID[record.id] = slot
        return slot
    }

    func bits(_ labels: Set<GmailLabelID>) -> UInt64 {
        var out: UInt64 = 0
        for label in labels {
            if let bit = labelSlots[label] { out |= 1 << UInt64(bit) }
        }
        return out
    }

    private func rebuildLabelSlots() {
        var slots = GmailIndex.fixedLabelSlots
        for (label, bit) in slotMap.userSlots { slots[label] = bit }
        labelSlots = slots
        labelForBit = [GmailLabelID?](repeating: nil, count: GmailLabelID.slotCount)
        for (label, bit) in slots where bit < GmailLabelID.slotCount { labelForBit[bit] = label }
    }

    private static func merged(_ old: GmailRecordAttributes, _ new: GmailRecordAttributes) -> GmailRecordAttributes {
        new.contains(.sizeKnown) ? old.subtracting(.allSizeBands).union(new) : old.union(new)
    }

    /// The order of the `index`th message of a page. An order below zero cannot be stored, so it
    /// stops at zero, where the message still sorts below everything above it.
    private static func order(_ first: UInt32, minus index: Int, step: UInt32) -> UInt32 {
        let offset = UInt64(index) * UInt64(step)
        return UInt64(first) >= offset ? first - UInt32(offset) : 0
    }

    @inline(__always)
    private func precedes(_ a: Int32, _ b: Int32) -> Bool {
        let ra = records[Int(a)]
        let rb = records[Int(b)]
        return ra.order != rb.order ? ra.order < rb.order : ra.id < rb.id
    }

    /// Where a record of this order and id goes among `byOrder`.
    private func lowerBound(order: UInt32, id: UInt64) -> Int {
        var low = 0
        var high = byOrder.count
        while low < high {
            let mid = (low + high) / 2
            let r = records[Int(byOrder[mid])]
            if r.order < order || (r.order == order && r.id < id) { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func insertIntoOrder(_ slot: Int32) {
        let r = records[Int(slot)]
        byOrder.insert(slot, at: lowerBound(order: r.order, id: r.id))
    }

    /// Takes a slot out of the order, found by the order it had when it went in.
    private func removeFromOrder(_ slot: Int32, order: UInt32, id: UInt64) {
        let at = lowerBound(order: order, id: id)
        if at < byOrder.count, byOrder[at] == slot {
            byOrder.remove(at: at)
        } else if let found = byOrder.firstIndex(of: slot) {
            byOrder.remove(at: found)
        }
    }

    /// Puts many slots into the order at once. A listing of All Mail goes newest first, so each
    /// page lands wholly below everything before it, and new mail wholly above: both are one move
    /// of memory, not one per message.
    private func insertIntoOrder(_ slots: [Int32]) {
        guard !slots.isEmpty else { return }
        let sorted = slots.sorted { precedes($0, $1) }
        if byOrder.isEmpty || precedes(sorted[sorted.count - 1], byOrder[0]) {
            byOrder.insert(contentsOf: sorted, at: 0)
        } else if precedes(byOrder[byOrder.count - 1], sorted[0]) {
            byOrder.append(contentsOf: sorted)
        } else if sorted.count <= 16 {
            for slot in sorted { insertIntoOrder(slot) }
        } else {
            var merged = ContiguousArray<Int32>()
            merged.reserveCapacity(byOrder.count + sorted.count)
            var i = 0
            var j = 0
            while i < byOrder.count, j < sorted.count {
                if precedes(sorted[j], byOrder[i]) {
                    merged.append(sorted[j]); j += 1
                } else {
                    merged.append(byOrder[i]); i += 1
                }
            }
            merged.append(contentsOf: byOrder[i...])
            merged.append(contentsOf: sorted[j...])
            byOrder = merged
        }
    }

    static func search(_ members: ContiguousArray<Int32>, for slot: Int32) -> (found: Bool, at: Int) {
        var low = 0
        var high = members.count
        while low < high {
            let mid = (low + high) / 2
            if members[mid] < slot { low = mid + 1 } else { high = mid }
        }
        return (low < members.count && members[low] == slot, low)
    }

    private func insertMember(_ slot: Int32, into label: GmailLabelID) {
        guard let members = overflow[label] else { return }
        let hit = GmailIndex.search(members, for: slot)
        guard !hit.found else { return }
        overflow[label]!.insert(slot, at: hit.at)
    }

    private func removeMember(_ slot: Int32, from label: GmailLabelID) {
        guard let members = overflow[label] else { return }
        let hit = GmailIndex.search(members, for: slot)
        guard hit.found else { return }
        overflow[label]!.remove(at: hit.at)
    }

    /// Adds sorted, distinct slots to a label's sorted list in one pass.
    private func mergeMembers(_ slots: [Int32], into label: GmailLabelID) {
        guard let members = overflow[label] else { return }
        if slots.count <= 8 {
            for slot in slots { insertMember(slot, into: label) }
            return
        }
        var merged = ContiguousArray<Int32>()
        merged.reserveCapacity(members.count + slots.count)
        var i = 0
        var j = 0
        while i < members.count || j < slots.count {
            let next: Int32
            if j >= slots.count || (i < members.count && members[i] <= slots[j]) {
                next = members[i]; i += 1
            } else {
                next = slots[j]; j += 1
            }
            if merged.last != next { merged.append(next) }
        }
        overflow[label] = merged
    }
}

// MARK: - The snapshot file

/// `index.snap`: the whole index as last compacted, and the generation of the journal that
/// follows it. Records are written oldest first with tombstones left out, so reading it back gives
/// the order without sorting.
extension GmailIndex {
    static let snapshotMagic: [UInt8] = Array("FMGI".utf8)
    static let snapshotVersion: UInt16 = 1
    private static let recordSize = 32

    func encodedSnapshot(nextGeneration: UInt64) -> Data {
        var meta = GmailBinaryWriter(capacity: 1_024)
        meta.optional(cursor) { $0.u64($1.raw) }
        meta.optional(resyncBegan) { $0.u64($1.raw) }
        slotMap.write(to: &meta)
        meta.u32(UInt32(chains.count))
        for (chain, progress) in chains.sorted(by: { "\($0.key)" < "\($1.key)" }) {
            GmailJournalCodec.write(chain, to: &meta)
            meta.u32(progress.run)
            meta.optional(progress.nextPageToken) { $0.string($1) }
            meta.bool(progress.isComplete)
            meta.u64(UInt64(max(0, progress.listed)))
        }
        meta.u32(UInt32(pending.count))
        for waiting in pending.values.sorted(by: { $0.ref.id < $1.ref.id }) {
            meta.ref(waiting.ref)
            meta.labels(waiting.labels)
            meta.bool(waiting.awaiting)
        }

        var fileSlot = [Int32](repeating: -1, count: records.count)
        for (i, slot) in byOrder.enumerated() { fileSlot[Int(slot)] = Int32(i) }

        var writer = GmailBinaryWriter(capacity: 64 + meta.data.count + byOrder.count * GmailIndex.recordSize)
        writer.bytes(Data(GmailIndex.snapshotMagic))
        writer.u16(GmailIndex.snapshotVersion)
        writer.u16(0)
        writer.u64(nextGeneration)
        writer.u32(UInt32(meta.data.count))
        writer.bytes(meta.data)
        writer.u32(UInt32(byOrder.count))
        var block = Data(count: byOrder.count * GmailIndex.recordSize)
        block.withUnsafeMutableBytes { out in
            records.withUnsafeBufferPointer { source in
                for (i, slot) in byOrder.enumerated() {
                    let r = source[Int(slot)]
                    let at = i * GmailIndex.recordSize
                    out.storeBytes(of: r.id.littleEndian, toByteOffset: at, as: UInt64.self)
                    out.storeBytes(of: r.threadID.littleEndian, toByteOffset: at + 8, as: UInt64.self)
                    out.storeBytes(of: r.labelBits.littleEndian, toByteOffset: at + 16, as: UInt64.self)
                    out.storeBytes(of: r.order.littleEndian, toByteOffset: at + 24, as: UInt32.self)
                    out.storeBytes(of: r.attributes.rawValue.littleEndian, toByteOffset: at + 28, as: UInt16.self)
                    out.storeBytes(of: r.spare.littleEndian, toByteOffset: at + 30, as: UInt16.self)
                }
            }
        }
        writer.bytes(block)
        let lists = slotMap.overflow.sorted()
        writer.u32(UInt32(lists.count))
        for label in lists {
            let members = (overflow[label] ?? []).map { fileSlot[Int($0)] }.filter { $0 >= 0 }.sorted()
            writer.label(label)
            writer.u32(UInt32(members.count))
            for member in members { writer.u32(UInt32(member)) }
        }
        let sum = GmailChecksum.crc32(writer.data)
        writer.u32(sum)
        return writer.data
    }

    /// Reads a snapshot back, with the generation of the journal that must follow it. Anything
    /// that does not add up throws, and the store then starts again from Gmail rather than trust
    /// part of an index.
    static func decodeSnapshot(_ data: Data) throws -> (index: GmailIndex, nextGeneration: UInt64) {
        let bytes = [UInt8](data)
        guard bytes.count >= 24, Array(bytes[0..<4]) == snapshotMagic else { throw GmailBinaryError.invalid("snapshot header") }
        var sumReader = GmailBinaryReader(bytes: bytes, offset: bytes.count - 4)
        guard try sumReader.u32() == GmailChecksum.crc32(bytes[0..<(bytes.count - 4)]) else {
            throw GmailBinaryError.invalid("snapshot checksum")
        }
        var reader = GmailBinaryReader(bytes: bytes, offset: 4)
        guard try reader.u16() == snapshotVersion else { throw GmailBinaryError.invalid("snapshot version") }
        _ = try reader.u16()
        let generation = try reader.u64()
        let metaLength = Int(try reader.u32())
        guard metaLength <= reader.remaining else { throw GmailBinaryError.truncated }

        let index = GmailIndex()
        index.cursor = try reader.optional { HistoryID(raw: try $0.u64()) }
        index.resyncBegan = try reader.optional { HistoryID(raw: try $0.u64()) }
        let map = try GmailSlotMap.read(from: &reader)
        let chainCount = Int(try reader.u32())
        for _ in 0..<chainCount {
            let chain = try GmailJournalCodec.readChain(&reader)
            let run = try reader.u32()
            let next = try reader.optional { try $0.string() }
            let complete = try reader.bool()
            let listed = Int(clamping: try reader.u64())
            index.chains[chain] = GmailChainProgress(run: run, nextPageToken: next, isComplete: complete, listed: listed)
        }
        let pendingCount = Int(try reader.u32())
        for _ in 0..<pendingCount {
            let ref = try reader.ref()
            let labels = try reader.labels()
            index.pending[ref.id.raw] = GmailPendingPlacement(ref: ref, labels: labels, awaiting: try reader.bool())
        }

        let count = Int(try reader.u32())
        guard count * recordSize <= reader.remaining else { throw GmailBinaryError.truncated }
        let start = reader.offset
        var records = ContiguousArray<GmailIndexRecord>()
        records.reserveCapacity(count)
        var slotByID = [UInt64: Int32](minimumCapacity: count)
        try bytes.withUnsafeBytes { raw in
            for i in 0..<count {
                let at = start + i * recordSize
                let id = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt64.self))
                var record = GmailIndexRecord(id: GmailMessageID(raw: id),
                                              threadID: GmailThreadID(raw: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: at + 8, as: UInt64.self))),
                                              labelBits: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: at + 16, as: UInt64.self)),
                                              order: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: at + 24, as: UInt32.self)),
                                              attributes: GmailRecordAttributes(rawValue: UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: at + 28, as: UInt16.self))))
                record.spare = UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: at + 30, as: UInt16.self))
                // A tombstone is never written, so one here means the file is not what it seems.
                guard !record.attributes.contains(.tombstone) else { throw GmailBinaryError.invalid("tombstone in snapshot") }
                guard slotByID.updateValue(Int32(i), forKey: id) == nil else { throw GmailBinaryError.invalid("id twice in snapshot") }
                records.append(record)
            }
        }
        try reader.skip(count * recordSize)
        var lists: [GmailLabelID: ContiguousArray<Int32>] = [:]
        let listCount = Int(try reader.u32())
        for _ in 0..<listCount {
            let label = try reader.label()
            let members = Int(try reader.u32())
            guard members * 4 <= reader.remaining else { throw GmailBinaryError.truncated }
            var list = ContiguousArray<Int32>()
            list.reserveCapacity(members)
            for _ in 0..<members {
                let slot = try reader.u32()
                guard Int(slot) < count else { throw GmailBinaryError.invalid("overflow slot") }
                list.append(Int32(slot))
            }
            lists[label] = list
        }
        guard Set(lists.keys) == map.overflow else { throw GmailBinaryError.invalid("overflow lists") }

        index.records = records
        index.slotByID = slotByID
        index.byOrder = ContiguousArray((0..<Int32(count)))
        index.liveCount = count
        index.slotMap = map
        index.overflow = lists.mapValues { list in list.isSorted ? list : ContiguousArray(list.sorted()) }
        index.rebuildLabelSlots()
        if !index.byOrderIsSorted {
            index.byOrder = ContiguousArray(index.byOrder.sorted { index.precedes($0, $1) })
        }
        return (index, generation)
    }

    private var byOrderIsSorted: Bool {
        guard byOrder.count > 1 else { return true }
        for i in 1..<byOrder.count where precedes(byOrder[i], byOrder[i - 1]) { return false }
        return true
    }
}

private extension ContiguousArray where Element == Int32 {
    var isSorted: Bool {
        guard count > 1 else { return true }
        for i in 1..<count where self[i] < self[i - 1] { return false }
        return true
    }
}

private extension Int {
    var nextPowerOfTwo: Int {
        guard self > 1 else { return 1 }
        return 1 << (Int.bitWidth - (self - 1).leadingZeroBitCount)
    }
}
