import Foundation

/// An attachment of a message opened through the API, known by name and size until someone
/// asks for its bytes.
public struct GmailAttachmentStub: Sendable, Hashable, Identifiable {
    public var id: String
    public var attachmentID: String?
    public var filename: String
    public var mimeType: String
    public var size: Int
    public var contentID: String?
    public var isInline: Bool
    /// Bytes Gmail sent with the structure itself, which happens for very small parts.
    public var inlineData: Data?

    /// An inline picture the text refers to and small enough to fetch with the text.
    public var isSmallInlineImage: Bool {
        contentID != nil && mimeType.hasPrefix("image/") && size <= 100_000
    }
}

/// A message opened from Gmail into memory only: its text first, its attachments on demand.
public struct GmailOpenedMessage: Sendable {
    public var gmailID: String
    /// Text and HTML, plus any inline pictures fetched so far. Attachments are not in it.
    public var message: MIMEMessage
    public var attachments: [GmailAttachmentStub]

    /// The pictures the HTML refers to by `cid:` that are small enough to fetch straight away.
    public var pendingInlineImages: [GmailAttachmentStub] {
        let html = message.textHTML?.lowercased() ?? ""
        let fetched = Set(message.attachments.compactMap(\.contentID))
        return attachments.filter { stub in
            guard stub.isSmallInlineImage, let cid = stub.contentID, !fetched.contains(cid) else { return false }
            return html.contains("cid:" + cid.lowercased())
        }
    }

    public mutating func add(_ data: Data, for stub: GmailAttachmentStub) {
        message.attachments.append(MIMEAttachment(id: stub.id, filename: stub.filename, mimeType: stub.mimeType,
                                                  contentID: stub.contentID, isInline: stub.isInline, data: data))
    }
}

public enum GmailMessageContent {
    /// The first stage of an open: the text parts from a `format=full` answer. Gmail sends a very
    /// long text part as an attachment id instead of inline; its bytes come in `fetchedText`,
    /// keyed by that id. Nothing else is fetched, so the text shows however large the
    /// attachments are.
    public static func textStage(_ message: GmailMessage, fetchedText: [String: Data] = [:]) -> GmailOpenedMessage {
        var headers = MIMEHeaders()
        for h in message.payload?.headers ?? [] { headers.add(h.name, h.value) }
        var collected = Collected()
        if let payload = message.payload { collect(payload, into: &collected, inAlternative: false, fetchedText: fetchedText) }
        var inline: [MIMEAttachment] = []
        for stub in collected.stubs {
            guard let data = stub.inlineData, stub.contentID != nil else { continue }
            inline.append(MIMEAttachment(id: stub.id, filename: stub.filename, mimeType: stub.mimeType,
                                         contentID: stub.contentID, isInline: stub.isInline, data: data))
        }
        let rootType = ContentType.parse(message.payload?.header("Content-Type") ?? message.payload?.mimeType)
        let root = MIMEPart(headers: headers, contentType: rootType, disposition: nil, dispositionParams: [:],
                            transferEncoding: nil, contentID: nil, body: Data(), children: [])
        let mime = MIMEMessage(headers: headers, root: root, textPlain: collected.textPlain, textHTML: collected.textHTML, attachments: inline)
        return GmailOpenedMessage(gmailID: message.id, message: mime, attachments: collected.stubs)
    }

    /// Attachment ids of text parts Gmail did not send inline, which the text stage needs.
    public static func deferredTextParts(_ message: GmailMessage) -> [String] {
        var collected = Collected()
        if let payload = message.payload { collect(payload, into: &collected, inAlternative: false, fetchedText: [:]) }
        return collected.deferredText
    }

    private struct Collected {
        var textPlain: String?
        var textHTML: String?
        var stubs: [GmailAttachmentStub] = []
        var deferredText: [String] = []
    }

    private static func collect(_ part: GmailPart, into out: inout Collected, inAlternative: Bool, fetchedText: [String: Data]) {
        let type = ContentType.parse(part.header("Content-Type") ?? part.mimeType)
        if type.isMultipart {
            let alternative = type.subtype == "alternative"
            for child in part.parts ?? [] {
                collect(child, into: &out, inAlternative: alternative || inAlternative, fetchedText: fetchedText)
            }
            return
        }
        let (disposition, params) = part.header("Content-Disposition").map(HeaderParams.parse) ?? ("", [:])
        let dispositionValue = disposition.lowercased()
        let filename = [part.filename, params["filename"], type.params["name"]].compactMap { $0 }.first { !$0.isEmpty }.map(RFC2047.decode)
        let contentID = AddressParser.messageIDs(part.header("Content-ID")).first.map { String($0.dropFirst().dropLast()) }
        // The same test MIMEParser applies to a downloaded message, so a message looks alike
        // whichever way it was opened.
        let isAttachment = dispositionValue == "attachment" || type.mimeType == "message/rfc822"
            || (filename != nil && !type.isText) || (!type.isText && type.mimeType != "message/delivery-status")
        let inlineData = part.body?.data.flatMap { Data(base64URL: $0) }
        if isAttachment {
            let name = filename ?? (type.mimeType == "message/rfc822" ? "message.eml" : MIMEParser.defaultName(for: type))
            out.stubs.append(GmailAttachmentStub(id: part.partId ?? UUID().uuidString, attachmentID: part.body?.attachmentId,
                                                 filename: name, mimeType: type.mimeType, size: part.body?.size ?? inlineData?.count ?? 0,
                                                 contentID: contentID, isInline: dispositionValue == "inline" || contentID != nil,
                                                 inlineData: inlineData))
            return
        }
        var bytes = inlineData
        if bytes == nil, let attachmentID = part.body?.attachmentId {
            bytes = fetchedText[attachmentID]
            if bytes == nil { out.deferredText.append(attachmentID) }
        }
        let text = bytes.map { Charsets.decode($0, charset: type.charset).replacingOccurrences(of: "\r\n", with: "\n") } ?? ""
        if type.mimeType == "text/plain" {
            if out.textPlain == nil { out.textPlain = text } else if !inAlternative { out.textPlain! += "\n\n" + text }
        } else if type.mimeType == "text/html" {
            if out.textHTML == nil { out.textHTML = text } else if !inAlternative { out.textHTML! += "<hr>" + text }
        } else if out.textPlain == nil {
            out.textPlain = text
        }
    }
}

extension GmailAPIClient {
    /// Opens a message into memory: one `format=full` call for its text, and the text parts
    /// Gmail held back for their length.
    public func openText(id: String) async throws -> GmailOpenedMessage {
        let message = try await full(id: id)
        var fetched: [String: Data] = [:]
        for attachmentID in GmailMessageContent.deferredTextParts(message) {
            fetched[attachmentID] = try await attachment(messageID: id, attachmentID: attachmentID)
        }
        return GmailMessageContent.textStage(message, fetchedText: fetched)
    }

    /// The small pictures the text shows inline, fetched after the text is on screen.
    public func withInlineImages(_ opened: GmailOpenedMessage) async throws -> GmailOpenedMessage {
        var result = opened
        for stub in opened.pendingInlineImages {
            result.add(try await attachmentData(messageID: opened.gmailID, stub: stub), for: stub)
        }
        return result
    }

    /// One attachment's bytes, fetched when someone opens, saves or forwards it.
    public func attachmentData(messageID: String, stub: GmailAttachmentStub) async throws -> Data {
        if let data = stub.inlineData { return data }
        guard let attachmentID = stub.attachmentID else { throw GoogleAPIError(kind: .notFound, detail: "no attachment id") }
        return try await attachment(messageID: messageID, attachmentID: attachmentID)
    }
}
