import Foundation

public struct OLMArchive: MigrationSource {
    public let identifier: String
    public let title: String
    public let folders: [SourceFolder]
    private let zip: ZipReader
    private let entriesByFolder: [String: [Int32]]
    private let attachmentsByTail: [UInt64: Int32]

    public init(url: URL) throws {
        var grouped: [String: [Int32]] = [:]
        var tails: [UInt64: Int32] = [:]
        let messagesMarker = Array("com.microsoft.__Messages/".utf8)
        let attachmentsMarker = Array("__Attachments".utf8)
        let xmlSuffix = Array(".xml".utf8)
        zip = try ZipReader(url: url) { index, name in
            if OLMArchive.contains(name, attachmentsMarker) {
                let tail = OLMArchive.tail(name, components: 2)
                let h = ZipReader.hash(tail)
                if tails[h] == nil { tails[h] = Int32(index) }
                return
            }
            guard OLMArchive.hasSuffix(name, xmlSuffix), let range = OLMArchive.find(name, messagesMarker) else { return }
            let rest = UnsafeRawBufferPointer(rebasing: name[range.upperBound...])
            guard let lastSlash = rest.lastIndex(of: 0x2F), lastSlash > 0 else { return }
            let folder = String(decoding: UnsafeRawBufferPointer(rebasing: rest[..<lastSlash]), as: UTF8.self)
            grouped[folder, default: []].append(Int32(index))
        }
        entriesByFolder = grouped
        attachmentsByTail = tails
        identifier = "olm:" + url.lastPathComponent + ":" + String(zip.entryCount)
        title = "OLM · " + url.lastPathComponent
        folders = grouped.map { path, entries in
            let name = path.split(separator: "/").last.map(String.init) ?? path
            return SourceFolder(id: path, name: name, path: path, kind: OLMArchive.kind(for: name, path: path), messageCount: entries.count)
        }.sorted { ($0.kind.order, $0.path) < ($1.kind.order, $1.path) }
    }

    static func contains(_ hay: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool { find(hay, needle) != nil }

    static func hasSuffix(_ hay: UnsafeRawBufferPointer, _ suffix: [UInt8]) -> Bool {
        guard hay.count >= suffix.count else { return false }
        return Array(hay.suffix(suffix.count)) == suffix
    }

    static func find(_ hay: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Range<Int>? {
        guard !needle.isEmpty, hay.count >= needle.count else { return nil }
        var i = 0
        while i + needle.count <= hay.count {
            var match = true
            for j in 0..<needle.count where hay[i + j] != needle[j] { match = false; break }
            if match { return i..<(i + needle.count) }
            i += 1
        }
        return nil
    }

    static func tail(_ name: UnsafeRawBufferPointer, components: Int) -> UnsafeRawBufferPointer {
        var seen = 0
        var i = name.count - 1
        while i >= 0 {
            if name[i] == 0x2F {
                seen += 1
                if seen == components { return UnsafeRawBufferPointer(rebasing: name[(i + 1)...]) }
            }
            i -= 1
        }
        return name
    }

    func attachmentEntry(_ path: String) -> ZipEntry? {
        if let e = zip.entry(named: path) { return e }
        let decoded = path.removingPercentEncoding ?? path
        if let e = zip.entry(named: decoded) { return e }
        let tail = decoded.split(separator: "/").suffix(2).joined(separator: "/")
        return attachmentsByTail[ZipReader.hash(tail)].flatMap { zip.entry(at: Int($0)) }
    }

    public func messages(in folder: SourceFolder) throws -> [SourceMessage] {
        let archive = self
        let folderID = folder.id
        return (entriesByFolder[folder.id] ?? []).compactMap { index in
            guard let entry = archive.zip.entry(at: Int(index)) else { return nil }
            return SourceMessage(folderID: folderID, messageID: "", isRead: true, isFlagged: false, date: nil, load: {
                try archive.render(try OLMMessage(xml: try archive.zip.data(for: entry)))
            }, prepare: {
                let parsed = try OLMMessage(xml: try archive.zip.data(for: entry))
                let mime = OLMArchive.MIMEBox()
                return SourceMessage(folderID: folderID, messageID: parsed.messageID, isRead: parsed.isRead, isFlagged: parsed.isFlagged, date: parsed.date) {
                    try mime.value(or: { try archive.render(parsed) })
                }
            })
        }
    }

    final class MIMEBox: @unchecked Sendable {
        private var data: Data?
        private let lock = NSLock()
        func value(or make: () throws -> Data) throws -> Data {
            lock.lock()
            defer { lock.unlock() }
            if let data { return data }
            let d = try make()
            data = d
            return d
        }
    }

    func render(_ parsed: OLMMessage) throws -> Data {
        try parsed.mime(loading: { path in
            guard let e = attachmentEntry(path) else { return nil }
            return try zip.data(for: e)
        })
    }

    static func kind(for name: String, path: String) -> SourceFolderKind {
        let n = name.lowercased()
        let top = path.split(separator: "/").first.map { String($0).lowercased() } ?? n
        if top != n && top != "inbox" { return .other }
        switch n {
        case "inbox", "posteingang", "boîte de réception", "входящие", "gelen kutusu": return .inbox
        case "sent items", "sent", "sent mail", "gesendete elemente", "отправленные", "gönderilmiş öğeler": return .sent
        case "drafts", "entwürfe", "черновики", "taslaklar": return .drafts
        case "deleted items", "trash", "gelöschte elemente", "удаленные", "silinmiş öğeler": return .trash
        case "junk e-mail", "junk email", "junk", "spam", "junk-e-mail", "нежелательная почта": return .junk
        case "archive", "archives", "archiv", "архив", "arşiv": return .archive
        case "outbox", "postausgang", "исходящие", "giden kutusu": return .outbox
        case "calendar", "contacts", "notes", "tasks", "journal": return .system
        default: return .other
        }
    }

}

struct OLMMessage {
    var values: [String: String] = [:]
    var addresses: [String: [EmailAddress]] = [:]
    var attachments: [(name: String, type: String, url: String, contentID: String)] = []

    init(xml: Data) throws {
        let parser = XMLParser(data: xml)
        let delegate = OLMParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else { throw FalconError.storage("OLM message XML could not be parsed") }
        values = delegate.values
        addresses = delegate.addresses
        attachments = delegate.attachments
    }

    func value(_ key: String) -> String? { values[key.lowercased()] }
    func people(_ key: String) -> [EmailAddress] { addresses[key.lowercased()] ?? [] }

    var messageID: String {
        guard let raw = value("OPFMessageCopyMessageID")?.trimmed, !raw.isEmpty else { return "" }
        return AddressParser.messageIDs(raw).first ?? "<" + raw.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) + ">"
    }
    var subject: String { value("OPFMessageCopySubject") ?? "" }
    var isRead: Bool { ["1", "true", "yes"].contains((value("OPFMessageIsRead") ?? "").lowercased()) }
    var isFlagged: Bool { (Int(value("OPFMessageCopyFlagStatus") ?? "0") ?? 0) > 0 }

    var date: Date? {
        for key in ["OPFMessageCopyReceivedTime", "OPFMessageCopySentTime", "OPFMessageCopyModDate"] {
            if let s = value(key), let d = OLMMessage.parseDate(s) { return d }
        }
        return nil
    }

    private static let plainFormats: [DateFormatter] = ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm"].map { fmt in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = fmt
        return f
    }

    static func parseDate(_ raw: String) -> Date? {
        let s = raw.trimmed
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        for p in plainFormats { if let d = p.date(from: s) { return d } }
        return RFC5322Date.parse(s)
    }

    func mime(loading: (String) throws -> Data?) throws -> Data {
        let from = people("OPFMessageCopyFromAddresses").first ?? people("OPFMessageCopySenderAddress").first ?? EmailAddress(address: "unknown@localhost")
        var files: [OutgoingAttachment] = []
        for a in attachments {
            guard let data = try loading(a.url) else { continue }
            files.append(OutgoingAttachment(filename: a.name, mimeType: a.type.isEmpty ? "application/octet-stream" : a.type, data: data,
                                            contentID: a.contentID.isEmpty ? nil : a.contentID))
        }
        let html = value("OPFMessageCopyHTMLBody").flatMap { $0.trimmed.isEmpty ? nil : $0 }
        let text = value("OPFMessageCopyBody").flatMap { $0.trimmed.isEmpty ? nil : $0 } ?? html.map(HTMLText.plainText(from:)) ?? ""
        let message = OutgoingMessage(from: from, to: people("OPFMessageCopyToAddresses"), cc: people("OPFMessageCopyCCAddresses"),
                                      bcc: people("OPFMessageCopyBCCAddresses"), subject: subject, textBody: text, htmlBody: html,
                                      attachments: files, inReplyTo: value("OPFMessageCopyInReplyTo"),
                                      references: AddressParser.messageIDs(value("OPFMessageCopyReferences")),
                                      messageID: messageID.isEmpty ? nil : messageID, date: date ?? Date())
        return MIMEBuilder.build(message)
    }
}

final class OLMParserDelegate: NSObject, XMLParserDelegate {
    var values: [String: String] = [:]
    var addresses: [String: [EmailAddress]] = [:]
    var attachments: [(name: String, type: String, url: String, contentID: String)] = []
    private var stack: [String] = []
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        stack.append(elementName)
        text = ""
        if elementName == "emailAddress", let parent = stack.dropLast().last {
            let address = attributes["OPFContactEmailAddressAddress"] ?? ""
            let name = attributes["OPFContactEmailAddressName"] ?? ""
            if !address.isEmpty { addresses[parent.lowercased(), default: []].append(EmailAddress(name: name == address ? "" : name, address: address)) }
        }
        if elementName == "messageAttachment" {
            attachments.append((attributes["OPFAttachmentName"] ?? "attachment", attributes["OPFAttachmentContentType"] ?? "",
                                attributes["OPFAttachmentURL"] ?? "", attributes["OPFAttachmentContentID"] ?? ""))
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if stack.count == 2 || elementName.hasPrefix("OPFMessage") { values[elementName.lowercased()] = text }
        stack.removeLast()
        text = ""
    }
}
