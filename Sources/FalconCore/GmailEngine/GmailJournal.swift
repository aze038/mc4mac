import Foundation
import zlib

// The index journal: everything that happened to a Google account's index since the snapshot was
// last written, appended record by record. It is the only place the history cursor lives, so the
// cursor can never be saved ahead of the changes it covers.
//
// Two kinds of unit are written:
// - a batch: change records, then one commit record carrying the cursor (or none, when the batch
//   does not move it). On load a batch counts only when its commit record is there, so a crash in
//   the middle of one drops all of it and the next check brings it again.
// - a listing page: one self-contained record, which counts on its own.
//
// Every record carries its length and a checksum, so a record cut short by a crash is recognised
// and cut off, never half applied. Each unit is flushed with `F_BARRIERFSYNC`, which keeps the
// writes in order without waiting for the drive the way `F_FULLFSYNC` does.

// MARK: - Durable writes

/// Every write the Gmail store makes to disk goes through here, so a test can stop the world
/// before any one of them and check that what is on disk at that moment loads into a state that
/// converges.
final class GmailDiskIO: @unchecked Sendable {
    enum Write: Sendable {
        case append(URL, Data)
        case replace(URL, Data)
        case remove(URL)
        case truncate(URL, Int)
    }

    /// Called before each write, with what is about to be written. Tests only.
    var beforeWrite: ((Write) -> Void)?
    /// Whether a write fails as it would on a full disk: an append after writing half of its
    /// bytes. Tests only.
    var refuse: ((Write) -> Bool)?

    init() {}

    private func refused(_ write: Write, _ url: URL) throws {
        if refuse?(write) == true { throw GmailDiskError.posix("write", ENOSPC, url) }
    }

    /// Writes `data` to a new file beside `url`, flushes it, and renames it over `url`, so a reader
    /// finds either the old file whole or the new one whole.
    func replace(_ data: Data, at url: URL) throws {
        beforeWrite?(.replace(url, data))
        try refused(.replace(url, data), url)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw GmailDiskError.posix("open", errno, url) }
        do {
            try GmailDiskIO.writeAll(data, to: fd, url: url)
            // The rename must not reach the disk before the bytes it names.
            if fcntl(fd, F_BARRIERFSYNC) != 0 { _ = fsync(fd) }
            close(fd)
        } catch {
            close(fd)
            unlink(temporary.path)
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw GmailDiskError.posix("rename", code, url)
        }
    }

    func remove(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        beforeWrite?(.remove(url))
        unlink(url.path)
    }

    /// Appends at the end of the file open as `fd`, whose length before the write is `length`. A
    /// write that fails part-way is cut back off, so the next append never follows half a record.
    func append(_ data: Data, to fd: Int32, url: URL, length: Int, barrier: Bool) throws {
        beforeWrite?(.append(url, data))
        do {
            if refuse?(.append(url, data)) == true {
                try GmailDiskIO.writeAll(data.prefix(data.count / 2), to: fd, url: url)
                throw GmailDiskError.posix("write", ENOSPC, url)
            }
            try GmailDiskIO.writeAll(data, to: fd, url: url)
            if barrier, fcntl(fd, F_BARRIERFSYNC) != 0, fsync(fd) != 0 {
                throw GmailDiskError.posix("fsync", errno, url)
            }
        } catch {
            _ = ftruncate(fd, off_t(length))
            throw error
        }
    }

    func truncate(_ fd: Int32, url: URL, to length: Int) throws {
        beforeWrite?(.truncate(url, length))
        guard ftruncate(fd, off_t(length)) == 0 else { throw GmailDiskError.posix("ftruncate", errno, url) }
    }

    /// Opens `url` for appending, creating it when it is not there.
    static func openForAppend(_ url: URL) throws -> Int32 {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { throw GmailDiskError.posix("open", errno, url) }
        return fd
    }

    private static func writeAll(_ data: Data, to fd: Int32, url: URL) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard var base = buffer.baseAddress else { return }
            var left = buffer.count
            while left > 0 {
                let written = Darwin.write(fd, base, left)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw GmailDiskError.posix("write", errno, url)
                }
                left -= written
                base += written
            }
        }
    }
}

enum GmailDiskError: Error, LocalizedError, Equatable {
    case posix(String, Int32, URL)
    case notLoaded

    var errorDescription: String? {
        switch self {
        case .posix(let call, let code, let url):
            return "\(call) failed on \(url.lastPathComponent): \(String(cString: strerror(code)))"
        case .notLoaded:
            return "the Gmail store was used before it was loaded"
        }
    }
}

// MARK: - Binary records

/// The store's files are binary because the index is large: a listing page of 500 ids takes 8 KB
/// this way and about 25 KB as JSON, and the index snapshot is 32 bytes a message.
struct GmailBinaryWriter {
    private(set) var data = Data()

    init(capacity: Int = 256) {
        data.reserveCapacity(capacity)
    }

    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u16(_ value: UInt16) { append(value.littleEndian) }
    mutating func u32(_ value: UInt32) { append(value.littleEndian) }
    mutating func u64(_ value: UInt64) { append(value.littleEndian) }
    mutating func bool(_ value: Bool) { u8(value ? 1 : 0) }
    mutating func date(_ value: Date) { u64(value.timeIntervalSinceReferenceDate.bitPattern) }

    mutating func string(_ value: String) {
        let bytes = Array(value.utf8)
        u32(UInt32(bytes.count))
        data.append(contentsOf: bytes)
    }

    mutating func optional<T>(_ value: T?, _ write: (inout GmailBinaryWriter, T) -> Void) {
        guard let value else { return u8(0) }
        u8(1)
        write(&self, value)
    }

    /// The fixed system labels take one byte, since nearly every label a page or a change names is
    /// one of them.
    mutating func label(_ label: GmailLabelID) {
        if let slot = label.fixedSlot {
            u8(UInt8(slot))
        } else {
            u8(0xFF)
            string(label.value)
        }
    }

    /// Sorted, so that the same set is always written the same way.
    mutating func labels(_ labels: Set<GmailLabelID>) {
        u16(UInt16(labels.count))
        for label in labels.sorted() { self.label(label) }
    }

    mutating func ref(_ ref: GmailRef) {
        u64(ref.id.raw)
        u64(ref.threadID.raw)
    }

    mutating func bytes(_ other: Data) { data.append(other) }

    private mutating func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
    }
}

enum GmailBinaryError: Error, Equatable {
    case truncated
    case invalid(String)
}

struct GmailBinaryReader {
    private let bytes: [UInt8]
    private(set) var offset: Int

    init(_ data: Data) {
        bytes = Array(data)
        offset = 0
    }

    init(bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    var isAtEnd: Bool { offset >= bytes.count }
    var remaining: Int { bytes.count - offset }

    mutating func u8() throws -> UInt8 {
        guard offset < bytes.count else { throw GmailBinaryError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() throws -> UInt16 { UInt16(littleEndian: try load()) }
    mutating func u32() throws -> UInt32 { UInt32(littleEndian: try load()) }
    mutating func u64() throws -> UInt64 { UInt64(littleEndian: try load()) }

    mutating func bool() throws -> Bool {
        switch try u8() {
        case 0: return false
        case 1: return true
        default: throw GmailBinaryError.invalid("bool")
        }
    }

    mutating func date() throws -> Date { Date(timeIntervalSinceReferenceDate: Double(bitPattern: try u64())) }

    mutating func string() throws -> String {
        let count = Int(try u32())
        guard count <= remaining else { throw GmailBinaryError.truncated }
        defer { offset += count }
        guard let text = String(bytes: bytes[offset..<offset + count], encoding: .utf8) else {
            throw GmailBinaryError.invalid("string")
        }
        return text
    }

    mutating func optional<T>(_ read: (inout GmailBinaryReader) throws -> T) throws -> T? {
        switch try u8() {
        case 0: return nil
        case 1: return try read(&self)
        default: throw GmailBinaryError.invalid("optional")
        }
    }

    mutating func label() throws -> GmailLabelID {
        let code = try u8()
        if code == 0xFF { return GmailLabelID(try string()) }
        guard Int(code) < GmailLabelID.fixedSlots.count else { throw GmailBinaryError.invalid("label code \(code)") }
        return GmailLabelID.fixedSlots[Int(code)]
    }

    mutating func labels() throws -> Set<GmailLabelID> {
        let count = Int(try u16())
        var out = Set<GmailLabelID>(minimumCapacity: count)
        for _ in 0..<count { out.insert(try label()) }
        return out
    }

    mutating func ref() throws -> GmailRef {
        GmailRef(id: GmailMessageID(raw: try u64()), threadID: GmailThreadID(raw: try u64()))
    }

    mutating func skip(_ count: Int) throws {
        guard count <= remaining else { throw GmailBinaryError.truncated }
        offset += count
    }

    private mutating func load<T: FixedWidthInteger>() throws -> T {
        let size = MemoryLayout<T>.size
        guard size <= remaining else { throw GmailBinaryError.truncated }
        defer { offset += size }
        return bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
    }
}

enum GmailChecksum {
    static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.bindMemory(to: Bytef.self).baseAddress else { return 0 }
            return UInt32(zlib.crc32(0, base, uInt(buffer.count)))
        }
    }

    static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return 0 }
            return UInt32(zlib.crc32(0, base, uInt(buffer.count)))
        }
    }
}

// MARK: - What the journal holds

/// Which user labels have a bit in every record and which are kept in lists instead. It is written
/// into the journal whenever it changes, in the same flush as moving the members, so the bits and
/// what they mean can never be saved apart.
struct GmailSlotMap: Hashable, Sendable {
    /// User labels with a bit, from `GmailLabelID.firstUserSlot` up.
    var userSlots: [GmailLabelID: Int] = [:]
    /// Shown user labels with no bit, whose members are listed.
    var overflow: Set<GmailLabelID> = []

    var tracked: Set<GmailLabelID> { Set(userSlots.keys).union(overflow) }

    func write(to writer: inout GmailBinaryWriter) {
        writer.u16(UInt16(userSlots.count))
        for (label, slot) in userSlots.sorted(by: { $0.value < $1.value }) {
            writer.label(label)
            writer.u8(UInt8(slot))
        }
        writer.labels(overflow)
    }

    static func read(from reader: inout GmailBinaryReader) throws -> GmailSlotMap {
        var map = GmailSlotMap()
        let count = Int(try reader.u16())
        for _ in 0..<count {
            let label = try reader.label()
            let slot = Int(try reader.u8())
            guard (GmailLabelID.firstUserSlot..<GmailLabelID.slotCount).contains(slot), label.fixedSlot == nil else {
                throw GmailBinaryError.invalid("user slot \(slot)")
            }
            map.userSlots[label] = slot
        }
        map.overflow = try reader.labels()
        return map
    }
}

enum GmailJournalEntry: Hashable, Sendable {
    case change(GmailChange)
    case slots(GmailSlotMap)
}

/// A unit of the journal as it is applied on load, in the order it was written.
enum GmailJournalUnit: Hashable, Sendable {
    case batch([GmailJournalEntry], cursor: HistoryID?)
    case page(GmailListingPage)
}

enum GmailJournalCodec {
    static let magic: [UInt8] = Array("FMGJ".utf8)
    static let version: UInt16 = 1
    static let headerLength = 16

    enum Kind: UInt8 {
        case change = 1
        case commit = 2
        case page = 3
        case slots = 4
    }

    static func header(generation: UInt64) -> Data {
        var writer = GmailBinaryWriter(capacity: headerLength)
        writer.bytes(Data(magic))
        writer.u16(version)
        writer.u16(0)
        writer.u64(generation)
        return writer.data
    }

    /// The generation a journal's header names, or nil when there is no valid header.
    static func generation(ofHeader bytes: [UInt8]) -> UInt64? {
        guard bytes.count >= headerLength, Array(bytes[0..<4]) == magic else { return nil }
        var reader = GmailBinaryReader(bytes: bytes, offset: 4)
        guard (try? reader.u16()) == version, (try? reader.u16()) != nil else { return nil }
        return try? reader.u64()
    }

    /// One framed record: its payload's length, its kind, the payload, and a checksum of the kind
    /// and payload together.
    static func frame(_ kind: Kind, _ payload: Data) -> Data {
        var body = Data(capacity: payload.count + 1)
        body.append(kind.rawValue)
        body.append(payload)
        var writer = GmailBinaryWriter(capacity: body.count + 8)
        writer.u32(UInt32(payload.count))
        writer.bytes(body)
        writer.u32(GmailChecksum.crc32(body))
        return writer.data
    }

    static func encode(batch entries: [GmailJournalEntry], cursor: HistoryID?) -> Data {
        var out = Data()
        for entry in entries {
            var writer = GmailBinaryWriter()
            switch entry {
            case .change(let change):
                write(change, to: &writer)
                out.append(frame(.change, writer.data))
            case .slots(let map):
                map.write(to: &writer)
                out.append(frame(.slots, writer.data))
            }
        }
        var commit = GmailBinaryWriter(capacity: 9)
        commit.optional(cursor) { $0.u64($1.raw) }
        out.append(frame(.commit, commit.data))
        return out
    }

    static func encode(page: GmailListingPage) -> Data {
        var writer = GmailBinaryWriter(capacity: 64 + page.refs.count * 16)
        write(page, to: &writer)
        return frame(.page, writer.data)
    }

    /// Reads every whole unit after the header. A record cut short, one whose checksum does not
    /// match, or one that cannot be decoded ends the reading: everything from there on is what a
    /// crash left, and `validLength` says where to cut. Change records with no commit record
    /// after them are dropped the same way.
    static func read(_ bytes: [UInt8]) -> (units: [GmailJournalUnit], validLength: Int, damaged: Bool) {
        var units: [GmailJournalUnit] = []
        var open: [GmailJournalEntry] = []
        var offset = headerLength
        var validLength = headerLength
        var damaged = false
        while offset < bytes.count {
            guard bytes.count - offset >= 9 else { damaged = true; break }
            var reader = GmailBinaryReader(bytes: bytes, offset: offset)
            guard let length = try? Int(reader.u32()), length <= bytes.count - offset - 9 else { damaged = true; break }
            let bodyStart = offset + 4
            let bodyEnd = bodyStart + 1 + length
            var sumReader = GmailBinaryReader(bytes: bytes, offset: bodyEnd)
            guard let sum = try? sumReader.u32(), sum == GmailChecksum.crc32(bytes[bodyStart..<bodyEnd]),
                  let kind = Kind(rawValue: bytes[bodyStart]) else { damaged = true; break }
            var payload = GmailBinaryReader(bytes: Array(bytes[(bodyStart + 1)..<bodyEnd]))
            do {
                switch kind {
                case .change:
                    open.append(.change(try readChange(&payload)))
                case .slots:
                    open.append(.slots(try GmailSlotMap.read(from: &payload)))
                case .commit:
                    let cursor = try payload.optional { HistoryID(raw: try $0.u64()) }
                    units.append(.batch(open, cursor: cursor))
                    open = []
                    validLength = bodyEnd + 4
                case .page:
                    // A page is only ever written between batches, so change records still open
                    // here belong to a batch a crash cut short, and are dropped.
                    open = []
                    units.append(.page(try readPage(&payload)))
                    validLength = bodyEnd + 4
                }
            } catch {
                damaged = true
                break
            }
            offset = bodyEnd + 4
        }
        return (units, validLength, damaged || !open.isEmpty)
    }

    // MARK: Changes

    private static func write(_ change: GmailChange, to writer: inout GmailBinaryWriter) {
        switch change {
        case .place(let ref, let order, let labels, let attributes):
            writer.u8(1)
            writer.ref(ref)
            writer.u32(order)
            writer.labels(labels)
            writer.u16(attributes.rawValue)
        case .relabel(let id, let adding, let removing):
            writer.u8(2)
            writer.u64(id.raw)
            writer.labels(adding)
            writer.labels(removing)
        case .attributes(let id, let setting, let clearing):
            writer.u8(3)
            writer.u64(id.raw)
            writer.u16(setting.rawValue)
            writer.u16(clearing.rawValue)
        case .tombstone(let id):
            writer.u8(4)
            writer.u64(id.raw)
        case .awaitingPlacement(let ref):
            writer.u8(5)
            writer.ref(ref)
        case .resyncBegan(let history):
            writer.u8(6)
            writer.u64(history.raw)
        case .resyncEnded(let history):
            writer.u8(7)
            writer.u64(history.raw)
        }
    }

    private static func readChange(_ reader: inout GmailBinaryReader) throws -> GmailChange {
        switch try reader.u8() {
        case 1:
            let ref = try reader.ref()
            let order = try reader.u32()
            let labels = try reader.labels()
            return .place(ref, order: order, labels: labels, attributes: GmailRecordAttributes(rawValue: try reader.u16()))
        case 2:
            let id = GmailMessageID(raw: try reader.u64())
            let adding = try reader.labels()
            return .relabel(id, adding: adding, removing: try reader.labels())
        case 3:
            let id = GmailMessageID(raw: try reader.u64())
            let setting = GmailRecordAttributes(rawValue: try reader.u16())
            return .attributes(id, setting: setting, clearing: GmailRecordAttributes(rawValue: try reader.u16()))
        case 4:
            return .tombstone(GmailMessageID(raw: try reader.u64()))
        case 5:
            return .awaitingPlacement(try reader.ref())
        case 6:
            return .resyncBegan(HistoryID(raw: try reader.u64()))
        case 7:
            return .resyncEnded(HistoryID(raw: try reader.u64()))
        case let tag:
            throw GmailBinaryError.invalid("change \(tag)")
        }
    }

    // MARK: Pages

    static func write(_ chain: GmailListingChain, to writer: inout GmailBinaryWriter) {
        switch chain {
        case .allMail(let after, let before):
            writer.u8(1)
            writer.optional(after) { $0.date($1) }
            writer.optional(before) { $0.date($1) }
        case .label(let label):
            writer.u8(2)
            writer.label(label)
        case .labels(let labels):
            writer.u8(3)
            writer.u16(UInt16(labels.count))
            for label in labels { writer.label(label) }
        case .search(let query):
            writer.u8(4)
            writer.string(query)
        }
    }

    static func readChain(_ reader: inout GmailBinaryReader) throws -> GmailListingChain {
        switch try reader.u8() {
        case 1:
            let after = try reader.optional { try $0.date() }
            return .allMail(after: after, before: try reader.optional { try $0.date() })
        case 2:
            return .label(try reader.label())
        case 3:
            let count = Int(try reader.u16())
            var labels: [GmailLabelID] = []
            for _ in 0..<count { labels.append(try reader.label()) }
            return .labels(labels)
        case 4:
            return .search(try reader.string())
        case let tag:
            throw GmailBinaryError.invalid("chain \(tag)")
        }
    }

    private static func write(_ page: GmailListingPage, to writer: inout GmailBinaryWriter) {
        write(page.chain, to: &writer)
        writer.u32(page.run)
        writer.optional(page.pageToken) { $0.string($1) }
        writer.optional(page.nextPageToken) { $0.string($1) }
        writer.u32(UInt32(page.refs.count))
        for ref in page.refs { writer.ref(ref) }
        writer.optional(page.firstOrder) { $0.u32($1) }
        writer.u32(page.orderStep)
        writer.labels(page.labels)
        writer.u16(page.attributes.rawValue)
    }

    private static func readPage(_ reader: inout GmailBinaryReader) throws -> GmailListingPage {
        let chain = try readChain(&reader)
        let run = try reader.u32()
        let token = try reader.optional { try $0.string() }
        let next = try reader.optional { try $0.string() }
        let count = Int(try reader.u32())
        guard count * 16 <= reader.remaining else { throw GmailBinaryError.truncated }
        var refs: [GmailRef] = []
        refs.reserveCapacity(count)
        for _ in 0..<count { refs.append(try reader.ref()) }
        let first = try reader.optional { try $0.u32() }
        let step = try reader.u32()
        let labels = try reader.labels()
        let attributes = GmailRecordAttributes(rawValue: try reader.u16())
        return GmailListingPage(chain: chain, run: run, pageToken: token, nextPageToken: next, refs: refs, firstOrder: first,
                                orderStep: step, labels: labels, attributes: attributes)
    }
}

// MARK: - The journal file

/// `index.journal`: a header naming its generation, then records. The snapshot names the
/// generation of the journal that follows it, so a journal the snapshot already holds, left
/// behind when a crash came between writing the snapshot and starting the new journal, is known
/// and never applied twice.
final class GmailJournal {
    let url: URL
    private let io: GmailDiskIO
    private(set) var generation: UInt64
    private(set) var length: Int
    /// Records written since the snapshot, which decides when to compact.
    private(set) var operations: Int
    private var fd: Int32 = -1
    /// Set while starting the journal of a new generation. Until that has worked, the file on disk
    /// may still be the old generation's, which the next launch would rightly ignore, so nothing
    /// may be appended to it.
    private var restarting: UInt64?

    private init(url: URL, io: GmailDiskIO, generation: UInt64, length: Int, operations: Int) {
        self.url = url
        self.io = io
        self.generation = generation
        self.length = length
        self.operations = operations
    }

    deinit {
        if fd >= 0 { close(fd) }
    }

    /// Opens the journal that follows a snapshot of `generation`, and returns what it holds. A
    /// journal of another generation, or none, is replaced by an empty one; a damaged tail is cut
    /// off so that the next append follows the last whole unit.
    static func open(_ url: URL, generation: UInt64, io: GmailDiskIO) throws -> (GmailJournal, [GmailJournalUnit]) {
        let bytes = (try? Data(contentsOf: url)).map { [UInt8]($0) }
        guard let bytes, let found = GmailJournalCodec.generation(ofHeader: bytes) else {
            if bytes != nil {
                Log.warning("Store", "the Gmail index journal had no valid header; starting a new one", code: "gmailJournalHeader",
                            logAs: "store")
            }
            return (try fresh(url, generation: generation, io: io), [])
        }
        guard found == generation else {
            // An older journal is already in the snapshot; a newer one follows a snapshot that is
            // gone. Neither can be applied.
            Log.info("store", "Gmail index journal of generation \(found) set aside; the snapshot expects \(generation)")
            return (try fresh(url, generation: generation, io: io), [])
        }
        let read = GmailJournalCodec.read(bytes)
        let journal = GmailJournal(url: url, io: io, generation: generation, length: bytes.count,
                                   operations: read.units.reduce(0) { total, unit in
                                       if case .batch(let entries, _) = unit { return total + max(1, entries.count) }
                                       return total + 1
                                   })
        journal.fd = try GmailDiskIO.openForAppend(url)
        if read.validLength < bytes.count {
            Log.warning("Store", "cut \(bytes.count - read.validLength) bytes a crash left at the end of the Gmail index journal",
                        code: "gmailJournalCut", logAs: "store")
            try io.truncate(journal.fd, url: url, to: read.validLength)
            journal.length = read.validLength
        }
        return (journal, read.units)
    }

    /// Starts an empty journal of `generation`, replacing whatever was there in one rename.
    static func fresh(_ url: URL, generation: UInt64, io: GmailDiskIO) throws -> GmailJournal {
        try io.replace(GmailJournalCodec.header(generation: generation), at: url)
        let journal = GmailJournal(url: url, io: io, generation: generation, length: GmailJournalCodec.headerLength, operations: 0)
        journal.fd = try GmailDiskIO.openForAppend(url)
        return journal
    }

    func append(batch entries: [GmailJournalEntry], cursor: HistoryID?) throws {
        try write(GmailJournalCodec.encode(batch: entries, cursor: cursor), operations: max(1, entries.count))
    }

    func append(page: GmailListingPage) throws {
        try write(GmailJournalCodec.encode(page: page), operations: 1)
    }

    /// After a compaction: the snapshot now holds everything, so the journal starts again empty
    /// under the next generation.
    func restart(generation next: UInt64) throws {
        restarting = next
        try io.replace(GmailJournalCodec.header(generation: next), at: url)
        if fd >= 0 { close(fd) }
        fd = -1
        fd = try GmailDiskIO.openForAppend(url)
        generation = next
        length = GmailJournalCodec.headerLength
        operations = 0
        restarting = nil
    }

    private func write(_ data: Data, operations added: Int) throws {
        if let next = restarting { try restart(generation: next) }
        guard fd >= 0 else { throw GmailDiskError.notLoaded }
        try io.append(data, to: fd, url: url, length: length, barrier: true)
        length += data.count
        operations += added
    }
}
