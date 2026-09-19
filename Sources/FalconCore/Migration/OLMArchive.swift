import Foundation

public struct OLMArchive: MigrationSource {
    public let identifier: String
    public let title: String
    public let folders: [SourceFolder]
    private let zip: ZipReader
    private let entriesByFolder: [String: [ZipEntry]]

    public init(url: URL) throws {
        zip = try ZipReader(url: url)
        identifier = "olm:" + url.lastPathComponent + ":" + String(zip.entries.count)
        title = "OLM · " + url.lastPathComponent
        var grouped: [String: [ZipEntry]] = [:]
        for e in zip.entries where e.name.hasSuffix(".xml") && e.name.contains("com.microsoft.__Messages/") {
            let parts = e.name.components(separatedBy: "com.microsoft.__Messages/")
            guard parts.count == 2 else { continue }
            let folderPath = parts[1].split(separator: "/").dropLast().joined(separator: "/")
            guard !folderPath.isEmpty else { continue }
            grouped[folderPath, default: []].append(e)
        }
        entriesByFolder = grouped
        folders = grouped.map { path, entries in
            let name = path.split(separator: "/").last.map(String.init) ?? path
            return SourceFolder(id: path, name: name, path: path, kind: OLMArchive.kind(for: name, path: path), messageCount: entries.count)
        }.sorted { ($0.kind.order, $0.path) < ($1.kind.order, $1.path) }
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

    public func messages(in folder: SourceFolder) throws -> [SourceMessage] {
        let zip = self.zip
        return (entriesByFolder[folder.id] ?? []).map { entry in
            let parsed = try? OLMMessage(xml: try zip.data(for: entry))
            let messageID = parsed?.messageID ?? ""
            return SourceMessage(folderID: folder.id, messageID: messageID, isRead: parsed?.isRead ?? true, isFlagged: parsed?.isFlagged ?? false,
                                 date: parsed?.date) {
                let message = try OLMMessage(xml: try zip.data(for: entry))
                return try message.mime(loading: { path in
                    guard let e = zip.entry(named: path) else { return nil }
                    return try zip.data(for: e)
                })
            }
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

    var messageID: String { AddressParser.messageIDs(values["OPFMessageCopyMessageID"]).first ?? (values["OPFMessageCopyMessageID"].map { "<" + $0.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) + ">" } ?? "") }
    var subject: String { values["OPFMessageCopySubject"] ?? "" }
    var isRead: Bool { values["OPFMessageIsRead"] == "1" || values["OPFMessageIsRead"]?.lowercased() == "true" }
    var isFlagged: Bool { (Int(values["OPFMessageCopyFlagStatus"] ?? "0") ?? 0) > 0 }

    var date: Date? {
        for key in ["OPFMessageCopyReceivedTime", "OPFMessageCopySentTime", "OPFMessageCopyModDate"] {
            if let s = values[key], let d = OLMMessage.parseDate(s) { return d }
        }
        return nil
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        return f.date(from: s)
    }

    func mime(loading: (String) throws -> Data?) throws -> Data {
        let from = addresses["OPFMessageCopyFromAddresses"]?.first ?? addresses["OPFMessageCopySenderAddress"]?.first ?? EmailAddress(address: "unknown@localhost")
        var files: [OutgoingAttachment] = []
        for a in attachments {
            guard let data = try loading(a.url) else { continue }
            files.append(OutgoingAttachment(filename: a.name, mimeType: a.type.isEmpty ? "application/octet-stream" : a.type, data: data,
                                            contentID: a.contentID.isEmpty ? nil : a.contentID))
        }
        let html = values["OPFMessageCopyHTMLBody"].flatMap { $0.trimmed.isEmpty ? nil : $0 }
        let text = values["OPFMessageCopyBody"] ?? html.map(HTMLText.plainText(from:)) ?? ""
        let message = OutgoingMessage(from: from, to: addresses["OPFMessageCopyToAddresses"] ?? [], cc: addresses["OPFMessageCopyCCAddresses"] ?? [],
                                      bcc: addresses["OPFMessageCopyBCCAddresses"] ?? [], subject: subject, textBody: text, htmlBody: html,
                                      attachments: files, inReplyTo: values["OPFMessageCopyInReplyTo"],
                                      references: AddressParser.messageIDs(values["OPFMessageCopyReferences"]),
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
            if !address.isEmpty { addresses[parent, default: []].append(EmailAddress(name: name == address ? "" : name, address: address)) }
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
        if stack.count == 2 || elementName.hasPrefix("OPFMessage") { values[elementName] = text }
        stack.removeLast()
        text = ""
    }
}
