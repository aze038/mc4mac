import Foundation

public struct ZipEntry: Sendable, Hashable {
    public var name: String
    public var method: UInt16
    public var compressedSize: UInt64
    public var uncompressedSize: UInt64
    public var localHeaderOffset: UInt64
}

public final class ZipReader: @unchecked Sendable {
    public let url: URL
    public private(set) var entries: [ZipEntry] = []
    private let handle: FileHandle
    private let fileSize: UInt64
    private let lock = NSLock()

    public init(url: URL) throws {
        self.url = url
        handle = try FileHandle(forReadingFrom: url)
        fileSize = try handle.seekToEnd()
        try readCentralDirectory()
    }

    deinit { try? handle.close() }

    public func entry(named name: String) -> ZipEntry? { entries.first { $0.name == name } }

    public func data(for entry: ZipEntry) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try handle.seek(toOffset: entry.localHeaderOffset)
        let local = try handle.read(upToCount: 30) ?? Data()
        guard local.count == 30, local.readLE32(at: 0) == 0x04034b50 else { throw FalconError.storage("zip: bad local header for \(entry.name)") }
        let nameLength = Int(local.readLE16(at: 26))
        let extraLength = Int(local.readLE16(at: 28))
        try handle.seek(toOffset: entry.localHeaderOffset + 30 + UInt64(nameLength + extraLength))
        let compressed = try handle.read(upToCount: Int(entry.compressedSize)) ?? Data()
        switch entry.method {
        case 0: return compressed
        case 8: return try (compressed as NSData).decompressed(using: .zlib) as Data
        default: throw FalconError.storage("zip: unsupported compression method \(entry.method) for \(entry.name)")
        }
    }

    private func readTail(_ count: UInt64) throws -> (Data, UInt64) {
        let size = min(count, fileSize)
        let start = fileSize - size
        try handle.seek(toOffset: start)
        return (try handle.read(upToCount: Int(size)) ?? Data(), start)
    }

    private func readCentralDirectory() throws {
        let (tail, tailStart) = try readTail(70_000)
        var eocd: Int?
        var i = tail.count - 22
        while i >= 0 {
            if tail.readLE32(at: i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard let eocd else { throw FalconError.storage("Not a zip file") }
        var count = UInt64(tail.readLE16(at: eocd + 10))
        var cdSize = UInt64(tail.readLE32(at: eocd + 12))
        var cdOffset = UInt64(tail.readLE32(at: eocd + 16))
        if count == 0xFFFF || cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF, eocd >= 20, tail.readLE32(at: eocd - 20) == 0x07064b50 {
            let eocd64Offset = tail.readLE64(at: eocd - 20 + 8)
            try handle.seek(toOffset: eocd64Offset)
            let rec = try handle.read(upToCount: 56) ?? Data()
            guard rec.count == 56, rec.readLE32(at: 0) == 0x06064b50 else { throw FalconError.storage("zip64: bad record") }
            count = rec.readLE64(at: 32)
            cdSize = rec.readLE64(at: 40)
            cdOffset = rec.readLE64(at: 48)
        }
        _ = tailStart
        try handle.seek(toOffset: cdOffset)
        let cd = try handle.read(upToCount: Int(cdSize)) ?? Data()
        var pos = 0
        var list: [ZipEntry] = []
        list.reserveCapacity(Int(min(count, 1_000_000)))
        while pos + 46 <= cd.count, cd.readLE32(at: pos) == 0x02014b50 {
            let method = cd.readLE16(at: pos + 10)
            var compressed = UInt64(cd.readLE32(at: pos + 20))
            var uncompressed = UInt64(cd.readLE32(at: pos + 24))
            let nameLength = Int(cd.readLE16(at: pos + 28))
            let extraLength = Int(cd.readLE16(at: pos + 30))
            let commentLength = Int(cd.readLE16(at: pos + 32))
            var offset = UInt64(cd.readLE32(at: pos + 42))
            let name = String(decoding: cd.subdata(in: (pos + 46)..<(pos + 46 + nameLength)), as: UTF8.self)
            var extraPos = pos + 46 + nameLength
            let extraEnd = extraPos + extraLength
            while extraPos + 4 <= extraEnd {
                let tag = cd.readLE16(at: extraPos)
                let size = Int(cd.readLE16(at: extraPos + 2))
                if tag == 0x0001 {
                    var p = extraPos + 4
                    if uncompressed == 0xFFFFFFFF, p + 8 <= extraEnd { uncompressed = cd.readLE64(at: p); p += 8 }
                    if compressed == 0xFFFFFFFF, p + 8 <= extraEnd { compressed = cd.readLE64(at: p); p += 8 }
                    if offset == 0xFFFFFFFF, p + 8 <= extraEnd { offset = cd.readLE64(at: p); p += 8 }
                }
                extraPos += 4 + size
            }
            list.append(ZipEntry(name: name, method: method, compressedSize: compressed, uncompressedSize: uncompressed, localHeaderOffset: offset))
            pos += 46 + nameLength + extraLength + commentLength
        }
        entries = list
    }
}

extension Data {
    func readLE64(at i: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(self[startIndex + i + k]) << (8 * UInt64(k)) }
        return v
    }
}
