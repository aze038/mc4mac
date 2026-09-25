import Foundation

/// The reduced bodies of the messages kept on the Mac, one LZFSE file each at
/// `bodies/<hex>.lzfse`, and what they take on disk, which the 32 MB cap is measured against.
///
/// A body is written whole before its row, so a crash leaves at worst a body with no row, which
/// the next launch deletes. A body that cannot be read is deleted too, and the message is fetched
/// again when it is opened.
final class GmailBodyStore {
    private let files: GmailFiles
    private let io: GmailDiskIO
    private(set) var sizes: [UInt64: Int] = [:]
    private(set) var totalBytes = 0

    init(files: GmailFiles, io: GmailDiskIO) {
        self.files = files
        self.io = io
    }

    /// Finds the bodies on disk, and deletes those of messages that are no longer kept.
    func load(keeping kept: (UInt64) -> Bool) {
        sizes = [:]
        totalBytes = 0
        let listed = (try? FileManager.default.contentsOfDirectory(at: files.bodiesDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        for url in listed {
            let name = url.lastPathComponent
            guard name.hasSuffix(".lzfse"), let id = GmailMessageID(hex: String(name.dropLast(6))), kept(id.raw) else {
                io.remove(url)
                continue
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            sizes[id.raw] = size
            totalBytes += size
        }
    }

    func has(_ id: GmailMessageID) -> Bool { sizes[id.raw] != nil }

    func write(_ body: GmailReducedBody, for id: GmailMessageID) throws {
        let data = try GmailBodyStore.encode(body)
        try io.replace(data, at: files.body(id))
        totalBytes += data.count - (sizes[id.raw] ?? 0)
        sizes[id.raw] = data.count
    }

    func read(_ id: GmailMessageID) -> GmailReducedBody? {
        guard sizes[id.raw] != nil else { return nil }
        guard let data = try? Data(contentsOf: files.body(id)) else {
            forget(id)
            return nil
        }
        do {
            return try GmailBodyStore.decode(data)
        } catch {
            Log.warning("Store", "a kept Gmail message body could not be read and was deleted; it is fetched again when opened",
                        error: error, code: "gmailBodyUnreadable", logAs: "store")
            remove(id)
            return nil
        }
    }

    func remove(_ id: GmailMessageID) {
        guard sizes[id.raw] != nil else { return }
        io.remove(files.body(id))
        forget(id)
    }

    private func forget(_ id: GmailMessageID) {
        totalBytes -= sizes.removeValue(forKey: id.raw) ?? 0
    }

    /// A binary property list, so pictures are stored as their bytes rather than as base64, then
    /// compressed with LZFSE, which decodes a 100 KB body in well under a millisecond.
    static func encode(_ body: GmailReducedBody) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let plist = try encoder.encode(body)
        return try (plist as NSData).compressed(using: .lzfse) as Data
    }

    static func decode(_ data: Data) throws -> GmailReducedBody {
        let plist = try (data as NSData).decompressed(using: .lzfse) as Data
        return try PropertyListDecoder().decode(GmailReducedBody.self, from: plist)
    }
}
