import Foundation

public struct ZipEntry: Sendable, Hashable {
    public var index: Int
    public var method: UInt16
    public var compressedSize: UInt64
    public var localHeaderOffset: UInt64
}

struct ZipRecord {
    var offset: UInt64
    var compressedSize: UInt64
    var method: UInt16
}

public final class ZipReader: @unchecked Sendable {
    public let url: URL
    private var records: [ZipRecord] = []
    private var byNameHash: [UInt64: Int32] = [:]
    private let mapped: Data
    private let fileSize: Int

    public init(url: URL, onEntry: ((Int, UnsafeRawBufferPointer) -> Void)? = nil) throws {
        self.url = url
        mapped = try Data(contentsOf: url, options: [.alwaysMapped, .uncached])
        fileSize = mapped.count
        try readCentralDirectory(onEntry: onEntry)
    }

    public var entryCount: Int { records.count }

    public func entry(at index: Int) -> ZipEntry? {
        guard records.indices.contains(index) else { return nil }
        let r = records[index]
        return ZipEntry(index: index, method: r.method, compressedSize: r.compressedSize, localHeaderOffset: r.offset)
    }

    public func entry(named name: String) -> ZipEntry? {
        var bytes = Array(name.utf8)
        let h = bytes.withUnsafeMutableBytes { ZipReader.hash(UnsafeRawBufferPointer($0)) }
        return byNameHash[h].flatMap { entry(at: Int($0)) }
    }

    public static func hash(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in bytes { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    public static func hash(_ string: String) -> UInt64 {
        var bytes = Array(string.utf8)
        return bytes.withUnsafeMutableBytes { hash(UnsafeRawBufferPointer($0)) }
    }

    public func data(for entry: ZipEntry) throws -> Data {
        let start = Int(entry.localHeaderOffset)
        guard start + 30 <= fileSize, mapped.readLE32(at: start) == 0x04034b50 else { throw FalconError.storage("zip: bad local header at \(start)") }
        let nameLength = Int(mapped.readLE16(at: start + 26))
        let extraLength = Int(mapped.readLE16(at: start + 28))
        let dataStart = start + 30 + nameLength + extraLength
        let dataEnd = dataStart + Int(entry.compressedSize)
        guard dataEnd <= fileSize else { throw FalconError.storage("zip: entry at \(start) runs past the end of the file") }
        let compressed = mapped.subdata(in: dataStart..<dataEnd)
        switch entry.method {
        case 0: return compressed
        case 8: return try (compressed as NSData).decompressed(using: .zlib) as Data
        default: throw FalconError.storage("zip: unsupported compression method \(entry.method)")
        }
    }

    private func readCentralDirectory(onEntry: ((Int, UnsafeRawBufferPointer) -> Void)?) throws {
        let tailStart = max(0, fileSize - 70_000)
        var eocd: Int?
        var i = fileSize - 22
        while i >= tailStart {
            if mapped.readLE32(at: i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard let eocd else { throw FalconError.storage("Not a zip file") }
        var count = Int(mapped.readLE16(at: eocd + 10))
        var cdSize = Int(mapped.readLE32(at: eocd + 12))
        var cdOffset = Int(mapped.readLE32(at: eocd + 16))
        if count == 0xFFFF || cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF, eocd >= 20, mapped.readLE32(at: eocd - 20) == 0x07064b50 {
            let rec = Int(mapped.readLE64(at: eocd - 20 + 8))
            guard rec + 56 <= fileSize, mapped.readLE32(at: rec) == 0x06064b50 else { throw FalconError.storage("zip64: bad record") }
            count = Int(mapped.readLE64(at: rec + 32))
            cdSize = Int(mapped.readLE64(at: rec + 40))
            cdOffset = Int(mapped.readLE64(at: rec + 48))
        }
        let end = min(fileSize, cdOffset + cdSize)
        records.reserveCapacity(min(count, 8_000_000))
        byNameHash.reserveCapacity(min(count, 8_000_000))
        mapped.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var pos = cdOffset
            while pos + 46 <= end, mapped.readLE32(at: pos) == 0x02014b50 {
                let method = mapped.readLE16(at: pos + 10)
                var compressed = UInt64(mapped.readLE32(at: pos + 20))
                let nameLength = Int(mapped.readLE16(at: pos + 28))
                let extraLength = Int(mapped.readLE16(at: pos + 30))
                let commentLength = Int(mapped.readLE16(at: pos + 32))
                var offset = UInt64(mapped.readLE32(at: pos + 42))
                var uncompressedIs64 = mapped.readLE32(at: pos + 24) == 0xFFFFFFFF
                var extraPos = pos + 46 + nameLength
                let extraEnd = extraPos + extraLength
                while extraPos + 4 <= extraEnd {
                    let tag = mapped.readLE16(at: extraPos)
                    let size = Int(mapped.readLE16(at: extraPos + 2))
                    if tag == 0x0001 {
                        var p = extraPos + 4
                        if uncompressedIs64, p + 8 <= extraEnd { p += 8; uncompressedIs64 = false }
                        if compressed == 0xFFFFFFFF, p + 8 <= extraEnd { compressed = mapped.readLE64(at: p); p += 8 }
                        if offset == 0xFFFFFFFF, p + 8 <= extraEnd { offset = mapped.readLE64(at: p); p += 8 }
                    }
                    extraPos += 4 + size
                }
                let nameBytes = UnsafeRawBufferPointer(rebasing: raw[(pos + 46)..<(pos + 46 + nameLength)])
                let index = records.count
                byNameHash[ZipReader.hash(nameBytes)] = Int32(index)
                records.append(ZipRecord(offset: offset, compressedSize: compressed, method: method))
                onEntry?(index, nameBytes)
                pos += 46 + nameLength + extraLength + commentLength
            }
        }
    }
}

extension Data {
    func readLE64(at i: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(self[startIndex + i + k]) << (8 * UInt64(k)) }
        return v
    }
}
