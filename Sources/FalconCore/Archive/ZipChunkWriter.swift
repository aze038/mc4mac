import Foundation
import CryptoKit

struct ZipEntryRecord {
    var name: String
    var crc: UInt32
    var size: Int
    var headerOffset: Int
    var time: UInt16
    var date: UInt16
}

final class ZipChunkWriter {
    let session: ArchiveUploadSession
    let name: String
    private(set) var offset = 0
    private(set) var entries: [ZipEntryRecord] = []
    private var hasher = SHA256()

    init(session: ArchiveUploadSession, name: String) {
        self.session = session
        self.name = name
    }

    var entryCount: Int { entries.count }
    var byteCount: Int { offset }

    func projectedSize(adding data: Data, name: String) -> Int {
        offset + 30 + name.utf8.count + data.count + 46 + name.utf8.count + 22
    }

    func add(name: String, data: Data, modified: Date) async throws -> (offset: Int, length: Int) {
        let nameBytes = Data(name.utf8)
        let crc = CRC32.checksum(data)
        let (dosTime, dosDate) = ZipChunkWriter.dosDateTime(modified)
        var header = Data()
        header.appendLE32(0x04034b50)
        header.appendLE16(20)
        header.appendLE16(0x0800)
        header.appendLE16(0)
        header.appendLE16(dosTime)
        header.appendLE16(dosDate)
        header.appendLE32(crc)
        header.appendLE32(UInt32(data.count))
        header.appendLE32(UInt32(data.count))
        header.appendLE16(UInt16(nameBytes.count))
        header.appendLE16(0)
        header.append(nameBytes)
        let headerOffset = offset
        try await emit(header)
        let dataOffset = offset
        try await emit(data)
        entries.append(ZipEntryRecord(name: name, crc: crc, size: data.count, headerOffset: headerOffset, time: dosTime, date: dosDate))
        return (dataOffset, data.count)
    }

    func close() async throws -> (fileID: String, byteSize: Int, sha256: String) {
        let cdStart = offset
        var cd = Data()
        for e in entries {
            let nameBytes = Data(e.name.utf8)
            cd.appendLE32(0x02014b50)
            cd.appendLE16(20)
            cd.appendLE16(20)
            cd.appendLE16(0x0800)
            cd.appendLE16(0)
            cd.appendLE16(e.time)
            cd.appendLE16(e.date)
            cd.appendLE32(e.crc)
            cd.appendLE32(UInt32(e.size))
            cd.appendLE32(UInt32(e.size))
            cd.appendLE16(UInt16(nameBytes.count))
            cd.appendLE16(0)
            cd.appendLE16(0)
            cd.appendLE16(0)
            cd.appendLE16(0)
            cd.appendLE32(0)
            cd.appendLE32(UInt32(e.headerOffset))
            cd.append(nameBytes)
        }
        try await emit(cd)
        var eocd = Data()
        eocd.appendLE32(0x06054b50)
        eocd.appendLE16(0)
        eocd.appendLE16(0)
        eocd.appendLE16(UInt16(entries.count))
        eocd.appendLE16(UInt16(entries.count))
        eocd.appendLE32(UInt32(offset - cdStart))
        eocd.appendLE32(UInt32(cdStart))
        eocd.appendLE16(0)
        try await emit(eocd)
        let fileID = try await session.finish()
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (fileID, offset, digest)
    }

    private func emit(_ data: Data) async throws {
        try await session.write(data)
        hasher.update(data: data)
        offset += data.count
    }

    static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year: Int = max(1980, min(2107, c.year ?? 1980))
        let hour: Int = c.hour ?? 0
        let minute: Int = c.minute ?? 0
        let second: Int = c.second ?? 0
        let month: Int = c.month ?? 1
        let day: Int = c.day ?? 1
        var time: Int = hour << 11
        time |= minute << 5
        time |= second / 2
        var d: Int = (year - 1980) << 9
        d |= month << 5
        d |= day
        return (UInt16(time), UInt16(d))
    }
}

extension Data {
    mutating func appendLE16(_ v: UInt16) {
        append(UInt8(v & 0xFF))
        append(UInt8(v >> 8))
    }

    mutating func appendLE32(_ v: UInt32) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 24) & 0xFF))
    }

    func readLE16(at i: Int) -> UInt16 {
        UInt16(self[startIndex + i]) | (UInt16(self[startIndex + i + 1]) << 8)
    }

    func readLE32(at i: Int) -> UInt32 {
        UInt32(self[startIndex + i]) | (UInt32(self[startIndex + i + 1]) << 8) | (UInt32(self[startIndex + i + 2]) << 16) | (UInt32(self[startIndex + i + 3]) << 24)
    }
}
