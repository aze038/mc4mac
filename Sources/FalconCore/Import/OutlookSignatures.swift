import Foundation
import SQLite3

// Legacy Outlook for Mac keeps each signature as a file of its own, found through its database:
//
//   ~/Library/Group Containers/UBF8T346G9.Office/Outlook/Outlook 15 Profiles/<profile>/Data/
//     Outlook.sqlite                 table Signatures (Record_RecordID, PathToDataFile), and
//                                    table AccountsMail (Account_Name, Account_EmailAddress, …)
//     Signatures/<n>/<UUID>.olk15Signature               one signature
//     Signature Attachments/<n>/<UUID>.olk15SigAttachment one of its pictures
//
// Both files start with a 32-byte header (0x00000DD0, then small numbers; an attachment's holds
// its UUID at 0x10) and a four-character tag written backwards: 'CRiS' for a signature,
// 'tAgS' for an attachment, the tag the database's Blocks table gives it as 'SgAt'.
//
// After a signature's tag and four bytes more comes a record, the shape Outlook stores every
// item in: a count of properties, the length of the table from the count on, the length of the
// data after it, then for each property its tag and the length of its value, and then the values
// one after another in the same order. A tag's low sixteen bits say which property it is, its
// top byte what kind of value: 0x02 and 0x03 whole numbers, 0x0B a yes or no, 0x0D a nested
// object, 0x14 a reference to another file, 0x1E text in one byte a character, 0x1F text in
// UTF-16LE, 0x4D a date. A signature holds:
//
//   0x0139 (0x1F) its name            0x013A (0x1F) its HTML, as Word writes it
//   0x0137 (0x0D) its pictures: a count, then each picture as a 16-bit length and a record of
//                 its own holding its Content-ID (0x0140), type (0x013F), file name (0x0134) and
//                 the file it is kept in (0x012C: four bytes, then the UUID the file is named by)
//
// An attachment's file holds, after its tag and four bytes, the picture as a MIME part with
// Content-Type, Content-ID and base64 body, its lines ending in a bare carriage return.
//
// Outlook keeps each account's choice of default signature with the account's own settings,
// not in either table above nor in com.microsoft.Outlook.plist, and the import reads nothing
// else, so which account used which signature is not known here; see SignatureCandidate.

/// One record of Legacy Outlook for Mac's item format (see the notes above).
struct OutlookRecord: Sendable {
    struct Property: Sendable {
        let id: UInt16
        let kind: UInt8
        let value: [UInt8]
    }

    enum Kind {
        static let object: UInt8 = 0x0D
        static let reference: UInt8 = 0x14
        static let text8: UInt8 = 0x1E
        static let text16: UInt8 = 0x1F
    }

    let properties: [Property]

    /// The most properties one record is believed to have; more means the bytes are not a record.
    private static let most = 4_096

    /// The record starting at `offset` of `bytes`, nil when the bytes there are not one. Every
    /// length is checked against what is there, so a damaged file gives nil, never a crash.
    static func parse(_ bytes: [UInt8], at offset: Int = 0) -> OutlookRecord? {
        guard let count = u32(bytes, offset), let table = u32(bytes, offset + 4), let length = u32(bytes, offset + 8),
              count <= most, table == 12 + 8 * count else { return nil }
        var position = offset + table
        guard position <= bytes.count, length <= bytes.count - position else { return nil }
        var properties: [Property] = []
        properties.reserveCapacity(count)
        for index in 0..<count {
            guard let tag = u32(bytes, offset + 12 + 8 * index), let size = u32(bytes, offset + 16 + 8 * index),
                  size <= bytes.count - position else { return nil }
            properties.append(Property(id: UInt16(tag & 0xFFFF), kind: UInt8(tag >> 24),
                                       value: Array(bytes[position..<(position + size)])))
            position += size
        }
        return OutlookRecord(properties: properties)
    }

    /// A nested list, as a signature's pictures are: a count, then each record after its 16-bit
    /// length. A list that does not add up gives what could be read of it.
    static func list(_ bytes: [UInt8]) -> [OutlookRecord] {
        guard let count = u32(bytes, 0), count <= most else { return [] }
        var records: [OutlookRecord] = []
        var position = 4
        for _ in 0..<count {
            guard position + 2 <= bytes.count else { break }
            let size = Int(bytes[position]) | Int(bytes[position + 1]) << 8
            let start = position + 2
            guard size > 0, size <= bytes.count - start, let record = parse(Array(bytes[start..<(start + size)])) else { break }
            records.append(record)
            position = start + size
        }
        return records
    }

    func value(_ id: UInt16, kind: UInt8) -> [UInt8]? {
        properties.first { $0.id == id && $0.kind == kind }?.value
    }

    func text16(_ id: UInt16) -> String? {
        value(id, kind: Kind.text16).map(Self.text16)
    }

    func text8(_ id: UInt16) -> String? {
        value(id, kind: Kind.text8).map(Self.text8)
    }

    /// UTF-16LE, a NUL at the end left off.
    static func text16(_ bytes: [UInt8]) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var index = 0
        while index + 1 < bytes.count {
            units.append(UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
            index += 2
        }
        while units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    /// One byte a character: UTF-8 when it is, else Mac Roman, as an older Outlook wrote.
    static func text8(_ bytes: [UInt8]) -> String {
        var bytes = bytes
        while bytes.last == 0 { bytes.removeLast() }
        return String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .macOSRoman) ?? ""
    }

    static func u32(_ bytes: [UInt8], _ offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
    }

    /// Where `mark` first stands in the first `within` bytes, looked for at `expected` first.
    static func find(_ mark: [UInt8], in bytes: [UInt8], expected: Int, within: Int) -> Int? {
        if expected + mark.count <= bytes.count, Array(bytes[expected..<(expected + mark.count)]) == mark { return expected }
        let end = min(bytes.count, within) - mark.count
        guard end >= 0 else { return nil }
        for start in 0...end where bytes[start] == mark[0] && Array(bytes[start..<(start + mark.count)]) == mark {
            return start
        }
        return nil
    }
}

/// A signature as a Legacy Outlook for Mac .olk15Signature file holds it.
public struct OutlookSignatureFile: Sendable, Equatable {
    /// A picture the signature shows, by the Content-ID its HTML gives it, and the file under
    /// Signature Attachments that holds it.
    public struct PictureReference: Sendable, Equatable {
        public var contentID: String
        public var mimeType: String?
        public var filename: String?
        /// The UUID the attachment's file is named by.
        public var file: UUID?
    }

    public var name: String
    public var html: String
    public var pictures: [PictureReference]

    enum Property {
        static let pictures: UInt16 = 0x0137
        static let name: UInt16 = 0x0139
        static let html: UInt16 = 0x013A
        static let pictureFile: UInt16 = 0x012C
        static let pictureFilename: UInt16 = 0x0134
        static let pictureDetails: UInt16 = 0x0133
        static let pictureType: UInt16 = 0x013F
        static let pictureContentID: UInt16 = 0x0140
    }

    static let tag = Array("CRiS".utf8)

    /// The signature in `data`, nil when it is not a signature Outlook wrote or holds no text.
    /// A signature Outlook left nameless is called Outlook Signature.
    public static func parse(_ data: Data) -> OutlookSignatureFile? {
        let bytes = [UInt8](data)
        guard let mark = OutlookRecord.find(tag, in: bytes, expected: 0x20, within: 4_096),
              let record = OutlookRecord.parse(bytes, at: mark + 8) else { return nil }
        let name = record.text16(Property.name)?.trimmed ?? ""
        guard let html = body(of: record, name: name) else { return nil }
        let pictures = record.value(Property.pictures, kind: OutlookRecord.Kind.object).map(OutlookRecord.list)?
            .compactMap(picture) ?? []
        return OutlookSignatureFile(name: name.isEmpty ? "Outlook Signature" : name, html: html, pictures: pictures)
    }

    /// The HTML; failing that, the longest other text the record holds, as HTML when it is,
    /// else as plain lines.
    private static func body(of record: OutlookRecord, name: String) -> String? {
        if let html = record.text16(Property.html), !html.trimmed.isEmpty { return html }
        let texts = record.properties.filter { $0.kind == OutlookRecord.Kind.text16 && $0.id != Property.name }
            .map { OutlookRecord.text16($0.value) }.filter { !$0.trimmed.isEmpty }
        guard let longest = texts.max(by: { $0.count < $1.count }) else { return nil }
        if Signature.looksLikeHTML(longest) { return longest }
        return "<div style=\"white-space:pre-wrap\">\(HTMLText.escape(longest))</div>"
    }

    private static func picture(_ record: OutlookRecord) -> PictureReference? {
        let details = record.value(Property.pictureDetails, kind: OutlookRecord.Kind.object).flatMap { OutlookRecord.parse($0) }
        // The Content-ID stands bare in the picture's record and in angle brackets in its details.
        let bracketed = details?.properties.filter { $0.kind == OutlookRecord.Kind.text8 }.map { OutlookRecord.text8($0.value) }
            .first { $0.hasPrefix("<") && $0.hasSuffix(">") }.map { String($0.dropFirst().dropLast()) }
        guard let contentID = (record.text8(Property.pictureContentID)?.trimmed).flatMap({ $0.isEmpty ? nil : $0 }) ?? bracketed
        else { return nil }
        var file: UUID?
        if let reference = record.value(Property.pictureFile, kind: OutlookRecord.Kind.reference), reference.count >= 16 {
            file = uuid(Array(reference.suffix(16)))
        }
        return PictureReference(contentID: contentID, mimeType: record.text8(Property.pictureType),
                                filename: record.text16(Property.pictureFilename), file: file)
    }

    static func uuid(_ bytes: [UInt8]) -> UUID? {
        guard bytes.count == 16 else { return nil }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// A picture as a Legacy Outlook for Mac .olk15SigAttachment file holds it.
public enum OutlookSignaturePicture {
    static let tag = Array("tAgS".utf8)

    /// The picture in `data` with its type, name and Content-ID, nil when the file holds none.
    public static func parse(_ data: Data) -> MIMEAttachment? {
        let bytes = [UInt8](data)
        guard let mark = OutlookRecord.find(tag, in: bytes, expected: 0x20, within: 4_096) else { return nil }
        // The part starts with its first header, a few bytes after the tag.
        let lower = bytes.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }
        let header = Array("content-".utf8)
        let start = OutlookRecord.find(header, in: Array(lower[(mark + 4)...]), expected: 4, within: 64).map { mark + 4 + $0 } ?? mark + 8
        guard start < bytes.count else { return nil }
        let part = MIMEParser.parsePart(withLineFeeds(Array(bytes[start...])), depth: 0)
        let picture = part.decodedData
        guard !part.contentType.isMultipart, InlinePictures.sendable(picture) != nil else { return nil }
        let format = InlinePictures.format(of: picture)
        let named = part.dispositionParams["filename"] ?? part.contentType.params["name"]
        return MIMEAttachment(id: UUID().uuidString, filename: named ?? "image001.\(format?.fileExtension ?? "png")",
                              mimeType: format?.mimeType ?? part.contentType.mimeType, contentID: part.contentID,
                              isInline: true, data: picture)
    }

    /// Every bare carriage return, as Outlook ends its lines, as CRLF.
    private static func withLineFeeds(_ bytes: [UInt8]) -> Data {
        var output = Data()
        output.reserveCapacity(bytes.count + bytes.count / 60)
        for (index, byte) in bytes.enumerated() {
            output.append(byte)
            if byte == 0x0D, index + 1 >= bytes.count || bytes[index + 1] != 0x0A { output.append(0x0A) }
        }
        return output
    }
}

/// A Legacy Outlook for Mac profile on this Mac.
public struct OutlookProfile: Sendable, Equatable {
    public var name: String
    /// Its Data folder.
    public var folder: URL

    public init(name: String, folder: URL) {
        self.name = name
        self.folder = folder
    }
}

/// An account a profile has.
public struct OutlookAccount: Sendable, Equatable {
    public var name: String
    public var email: String

    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }
}

/// A signature read from a profile: its HTML and the pictures it shows by cid:.
public struct OutlookSignature: Sendable, Equatable {
    public var name: String
    public var html: String
    public var pictures: [MIMEAttachment]
    /// Content-IDs of pictures the signature shows whose file could not be found or read; each
    /// is left out.
    public var missingPictures: [String]
}

/// What one profile holds.
public struct OutlookProfileSignatures: Sendable, Equatable {
    public var profile: OutlookProfile
    public var signatures: [OutlookSignature]
    public var accounts: [OutlookAccount]
    /// Whether the list of signatures came from Outlook's database; when it could not be read,
    /// every signature file in the profile is taken instead.
    public var fromDatabase: Bool
}

/// Reads the signatures of Legacy Outlook for Mac, touching nothing of Outlook's: its database is
/// read from a copy made in a temporary folder, which is removed afterwards.
public enum OutlookSignatureImport {
    /// Where Legacy Outlook keeps its profiles, from the home folder.
    public static let profilesPath = "Library/Group Containers/UBF8T346G9.Office/Outlook/Outlook 15 Profiles"

    /// Why nothing could be read.
    public enum Problem: Error, Equatable, Sendable {
        /// There is no Legacy Outlook profile on this Mac.
        case noOutlook
        /// macOS did not let FalconMail read Outlook's data.
        case notAllowed
        /// The profiles are there but none of them could be read.
        case unreadable
    }

    /// Every profile, by name, "Main Profile" first as Outlook's own is.
    public static func profiles(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> [OutlookProfile] {
        let root = home.appendingPathComponent(profilesPath, isDirectory: true)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw refusesLooking(at: root) ? Problem.notAllowed : Problem.noOutlook
        }
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        } catch {
            throw isRefusal(error) ? Problem.notAllowed : Problem.unreadable
        }
        var refused = false
        let profiles = entries.compactMap { entry -> OutlookProfile? in
            let data = entry.appendingPathComponent("Data", isDirectory: true)
            var folder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: data.path, isDirectory: &folder), folder.boolValue else {
                if refusesLooking(at: data) { refused = true }
                return nil
            }
            return OutlookProfile(name: entry.lastPathComponent, folder: data)
        }
        guard !profiles.isEmpty else { throw refused ? Problem.notAllowed : Problem.noOutlook }
        return profiles.sorted {
            if ($0.name == "Main Profile") != ($1.name == "Main Profile") { return $0.name == "Main Profile" }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Every profile's signatures. A profile that cannot be read is left out; when none can be,
    /// the reason is thrown.
    public static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> [OutlookProfileSignatures] {
        var read: [OutlookProfileSignatures] = []
        var refused = false
        for profile in try profiles(home: home) {
            do {
                read.append(try self.read(profile))
            } catch Problem.notAllowed {
                refused = true
            } catch {
                continue
            }
        }
        if read.isEmpty { throw refused ? Problem.notAllowed : Problem.unreadable }
        return read
    }

    /// One profile's signatures and accounts, in the order Outlook made the signatures.
    public static func read(_ profile: OutlookProfile) throws -> OutlookProfileSignatures {
        let database = try? readDatabase(of: profile)
        var files: [URL]
        if let listed = database?.signatures {
            files = listed
        } else {
            do {
                files = try signatureFiles(in: profile)
            } catch {
                throw isRefusal(error) ? Problem.notAllowed : Problem.unreadable
            }
        }
        var pictureFiles: [String: URL]?
        var signatures: [OutlookSignature] = []
        for file in files {
            let data: Data
            do {
                data = try Data(contentsOf: file)
            } catch {
                if isRefusal(error) { throw Problem.notAllowed }
                continue
            }
            guard let parsed = OutlookSignatureFile.parse(data) else { continue }
            var pictures: [MIMEAttachment] = []
            for reference in parsed.pictures where !pictures.contains(where: { $0.contentID == reference.contentID }) {
                if pictureFiles == nil { pictureFiles = attachmentFiles(in: profile) }
                guard let url = reference.file.flatMap({ pictureFiles?[$0.uuidString.uppercased()] }),
                      var picture = (try? Data(contentsOf: url)).flatMap(OutlookSignaturePicture.parse) else { continue }
                picture.contentID = reference.contentID
                if let name = reference.filename, !name.isEmpty { picture.filename = name }
                pictures.append(picture)
            }
            // Each picture the HTML shows that no file answers, whether the signature lists it
            // or not, is missing.
            let missing = cids(in: parsed.html).filter { id in
                !pictures.contains { $0.contentID?.lowercased() == id.lowercased() }
            }
            signatures.append(OutlookSignature(name: parsed.name, html: parsed.html, pictures: pictures, missingPictures: missing))
        }
        return OutlookProfileSignatures(profile: profile, signatures: signatures, accounts: database?.accounts ?? [],
                                        fromDatabase: database != nil)
    }

    private static let cidReference = try! NSRegularExpression(pattern: "(?i)src\\s*=\\s*[\"']?cid:([^\"'\\s>]+)")

    static func cids(in html: String) -> [String] {
        let text = html as NSString
        var seen = Set<String>()
        return cidReference.matches(in: html, range: NSRange(location: 0, length: text.length))
            .map { text.substring(with: $0.range(at: 1)) }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    /// Every .olk15Signature file in the profile, oldest first.
    static func signatureFiles(in profile: OutlookProfile) throws -> [URL] {
        let folder = profile.folder.appendingPathComponent("Signatures", isDirectory: true)
        var found: [(URL, Date)] = []
        for sub in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            let files = (try? FileManager.default.contentsOfDirectory(at: sub, includingPropertiesForKeys: [.creationDateKey])) ?? []
            for file in files where file.pathExtension == "olk15Signature" {
                found.append((file, (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast))
            }
        }
        return found.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// Every .olk15SigAttachment file in the profile, by the UUID it is named by, in capitals.
    static func attachmentFiles(in profile: OutlookProfile) -> [String: URL] {
        let folder = profile.folder.appendingPathComponent("Signature Attachments", isDirectory: true)
        var found: [String: URL] = [:]
        for sub in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            for file in (try? FileManager.default.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "olk15SigAttachment" {
                found[file.deletingPathExtension().lastPathComponent.uppercased()] = file
            }
        }
        return found
    }

    // MARK: - The database

    struct Database {
        var signatures: [URL]
        var accounts: [OutlookAccount]
    }

    /// The signature files Outlook lists and its accounts, read from a copy of Outlook.sqlite and
    /// its write-ahead log made in a temporary folder, which is removed afterwards. Outlook's own
    /// files are only ever read.
    static func readDatabase(of profile: OutlookProfile) throws -> Database {
        let source = profile.folder.appendingPathComponent("Outlook.sqlite")
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("FalconMail-Outlook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: copy) }
        let database = copy.appendingPathComponent("Outlook.sqlite")
        try FileManager.default.copyItem(at: source, to: database)
        for suffix in ["-wal", "-shm"] {
            let companion = profile.folder.appendingPathComponent("Outlook.sqlite" + suffix)
            guard FileManager.default.fileExists(atPath: companion.path) else { continue }
            try? FileManager.default.copyItem(at: companion, to: copy.appendingPathComponent("Outlook.sqlite" + suffix))
        }
        let reader = try SQLiteReader(database)
        let paths = try reader.strings("SELECT PathToDataFile FROM Signatures ORDER BY Record_RecordID")
        let signatures = paths.compactMap { $0.first ?? nil }.map { path in
            profile.folder.appendingPathComponent(path.removingPercentEncoding ?? path)
        }
        let rows = (try? reader.strings("SELECT Account_Name, Account_EmailAddress FROM AccountsMail ORDER BY Record_RecordID")) ?? []
        let accounts = rows.compactMap { row -> OutlookAccount? in
            guard row.count == 2, let email = row[1]?.trimmed, email.contains("@") else { return nil }
            return OutlookAccount(name: row[0]?.trimmed ?? "", email: email)
        }
        return Database(signatures: signatures, accounts: accounts)
    }

    /// Whether macOS will not say whether `url` is there, as it will not inside another app's
    /// data until the owner allows it, rather than its not being there: the profiles then only
    /// seem to be missing.
    static func refusesLooking(at url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) != 0 else { return false }
        return errno == EPERM || errno == EACCES
    }

    /// Whether `error` is macOS refusing access, as it does to another app's data until the
    /// owner allows it.
    static func isRefusal(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(EPERM) || error.code == Int(EACCES) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error { return isRefusal(underlying) }
        return false
    }
}

/// Reads rows from an SQLite file, as text.
struct SQLiteReader {
    private final class Handle {
        let pointer: OpaquePointer
        init(_ pointer: OpaquePointer) { self.pointer = pointer }
        deinit { sqlite3_close_v2(pointer) }
    }

    struct Failure: Error {
        let message: String
    }

    private let handle: Handle

    /// Opens a copy made for reading. Opened for writing, so SQLite can take in its write-ahead
    /// log as it would for Outlook; only the copy is ever touched.
    init(_ file: URL) throws {
        var pointer: OpaquePointer?
        let status = sqlite3_open_v2(file.path, &pointer, SQLITE_OPEN_READWRITE, nil)
        guard status == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close_v2(pointer) }
            throw Failure(message: "open \(status)")
        }
        handle = Handle(pointer)
    }

    func strings(_ query: String) throws -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle.pointer, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure(message: String(cString: sqlite3_errmsg(handle.pointer)))
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[String?]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw Failure(message: String(cString: sqlite3_errmsg(handle.pointer))) }
            let columns = sqlite3_column_count(statement)
            rows.append((0..<columns).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) }
            })
        }
        return rows
    }
}
