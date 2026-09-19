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
    private var byName: [String: Int] = [:]
    private let mapped: Data
    private let fileSize: Int

    public init(url: URL) throws {
        self.url = url
        mapped = try Data(contentsOf: url, options: [.alwaysMapped, .uncached])
        fileSize = mapped.count
        try readCentralDirectory()
    }

    public var entryCount: Int { entries.count }

    public func entry(named name: String) -> ZipEntry? {
        byName[name].map { entries[$0] }
    }

    public func data(for entry: ZipEntry) throws -> Data {
        let start = Int(entry.localHeaderOffset)
        guard start + 30 <= fileSize, mapped.readLE32(at: start) == 0x04034b50 else { throw FalconError.storage("zip: bad local header for \(entry.name)") }
        let nameLength = Int(mapped.readLE16(at: start + 26))
        let extraLength = Int(mapped.readLE16(at: start + 28))
        let dataStart = start + 30 + nameLength + extraLength
        let dataEnd = dataStart + Int(entry.compressedSize)
        guard dataEnd <= fileSize else { throw FalconError.storage("zip: entry \(entry.name) runs past the end of the file") }
        let compressed = mapped.subdata(in: dataStart..<dataEnd)
        switch entry.method {
        case 0: return compressed
        case 8: return try (compressed as NSData).decompressed(using: .zlib) as Data
        default: throw FalconError.storage("zip: unsupported compression method \(entry.method) for \(entry.name)")
        }
    }

    private func readCentralDirectory() throws {
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
        var pos = cdOffset
        var list: [ZipEntry] = []
        list.reserveCapacity(min(count, 4_000_000))
        var index: [String: Int] = [:]
        index.reserveCapacity(min(count, 4_000_000))
        while pos + 46 <= end, mapped.readLE32(at: pos) == 0x02014b50 {
            let method = mapped.readLE16(at: pos + 10)
            var compressed = UInt64(mapped.readLE32(at: pos + 20))
            var uncompressed = UInt64(mapped.readLE32(at: pos + 24))
            let nameLength = Int(mapped.readLE16(at: pos + 28))
            let extraLength = Int(mapped.readLE16(at: pos + 30))
            let commentLength = Int(mapped.readLE16(at: pos + 32))
            var offset = UInt64(mapped.readLE32(at: pos + 42))
            let name = String(decoding: mapped.subdata(in: (pos + 46)..<(pos + 46 + nameLength)), as: UTF8.self)
            var extraPos = pos + 46 + nameLength
            let extraEnd = extraPos + extraLength
            while extraPos + 4 <= extraEnd {
                let tag = mapped.readLE16(at: extraPos)
                let size = Int(mapped.readLE16(at: extraPos + 2))
                if tag == 0x0001 {
                    var p = extraPos + 4
                    if uncompressed == 0xFFFFFFFF, p + 8 <= extraEnd { uncompressed = mapped.readLE64(at: p); p += 8 }
                    if compressed == 0xFFFFFFFF, p + 8 <= extraEnd { compressed = mapped.readLE64(at: p); p += 8 }
                    if offset == 0xFFFFFFFF, p + 8 <= extraEnd { offset = mapped.readLE64(at: p); p += 8 }
                }
                extraPos += 4 + size
            }
            index[name] = list.count
            list.append(ZipEntry(name: name, method: method, compressedSize: compressed, uncompressedSize: uncompressed, localHeaderOffset: offset))
            pos += 46 + nameLength + extraLength + commentLength
        }
        entries = list
        byName = index
    }
}

extension Data {
    func readLE64(at i: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(self[startIndex + i + k]) << (8 * UInt64(k)) }
        return v
    }
}
