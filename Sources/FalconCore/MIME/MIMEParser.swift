import Foundation

public struct MIMEAttachment: Sendable, Hashable, Identifiable {
    public var id: String
    public var filename: String
    public var mimeType: String
    public var contentID: String?
    public var isInline: Bool
    public var data: Data

    public var size: Int { data.count }
}

extension MIMEAttachment {
    /// A picture shown inline under `contentID`, made outside a parsed message, as a
    /// signature's picture read from Outlook is.
    public init(picture data: Data, filename: String, mimeType: String, contentID: String?) {
        self.init(id: UUID().uuidString, filename: filename, mimeType: mimeType, contentID: contentID, isInline: true, data: data)
    }
}

public struct MIMEPart: Sendable {
    public var headers: MIMEHeaders
    public var contentType: ContentType
    public var disposition: String?
    public var dispositionParams: [String: String]
    public var transferEncoding: String?
    public var contentID: String?
    public var body: Data
    public var children: [MIMEPart]

    public var filename: String? {
        if let n = dispositionParams["filename"], !n.isEmpty { return RFC2047.decode(n) }
        if let n = contentType.params["name"], !n.isEmpty { return RFC2047.decode(n) }
        return nil
    }

    public var isAttachment: Bool {
        if (disposition ?? "").lowercased() == "attachment" { return true }
        if contentType.isMultipart || contentType.mimeType == "message/rfc822" { return false }
        if filename != nil && !contentType.isText { return true }
        if !contentType.isText && contentType.mimeType != "message/delivery-status" { return true }
        return false
    }

    public var decodedText: String {
        Charsets.decode(TransferDecoding.decode(body, encoding: transferEncoding), charset: contentType.charset)
            .replacingOccurrences(of: "\r\n", with: "\n")
    }

    public var decodedData: Data { TransferDecoding.decode(body, encoding: transferEncoding) }

    public func walk(_ visit: (MIMEPart) -> Void) {
        visit(self)
        for c in children { c.walk(visit) }
    }
}

public struct MIMEMessage: Sendable {
    public var headers: MIMEHeaders
    public var root: MIMEPart
    public var textPlain: String?
    public var textHTML: String?
    public var attachments: [MIMEAttachment]

    public var subject: String { RFC2047.decode(headers.first("Subject") ?? "") }
    public var from: EmailAddress { AddressParser.parse(headers.first("From")).first ?? EmailAddress(address: "") }
    public var to: [EmailAddress] { AddressParser.parse(headers.first("To")) }
    public var cc: [EmailAddress] { AddressParser.parse(headers.first("Cc")) }
    public var replyTo: [EmailAddress] { AddressParser.parse(headers.first("Reply-To")) }
    public var date: Date? { headers.first("Date").flatMap(RFC5322Date.parse) }
    public var messageID: String { AddressParser.messageIDs(headers.first("Message-ID")).first ?? "" }
    public var inReplyTo: String { AddressParser.messageIDs(headers.first("In-Reply-To")).first ?? "" }
    public var references: [String] { AddressParser.messageIDs(headers.first("References")) }

    public var bestText: String {
        if let t = textPlain, !t.trimmed.isEmpty { return t }
        if let h = textHTML { return HTMLText.plainText(from: h) }
        return ""
    }

    public var snippet: String {
        String(bestText.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmed.prefix(160))
    }
}

public enum MIMEParser {
    public static func parseHeaders(_ data: Data) -> MIMEHeaders {
        MIMEHeaders.parse(data)
    }

    public static func parse(_ data: Data) -> MIMEMessage {
        let root = parsePart(data, depth: 0)
        var textPlain: String?
        var textHTML: String?
        var attachments: [MIMEAttachment] = []
        collect(root, textPlain: &textPlain, textHTML: &textHTML, attachments: &attachments, inAlternative: false)
        return MIMEMessage(headers: root.headers, root: root, textPlain: textPlain, textHTML: textHTML, attachments: attachments)
    }

    static func splitHeaderBody(_ data: Data) -> (Data, Data) {
        if let r = data.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
            return (data.subdata(in: data.startIndex..<r.lowerBound), data.subdata(in: r.upperBound..<data.endIndex))
        }
        if let r = data.range(of: Data([0x0A, 0x0A])) {
            return (data.subdata(in: data.startIndex..<r.lowerBound), data.subdata(in: r.upperBound..<data.endIndex))
        }
        return (data, Data())
    }

    static func parsePart(_ data: Data, depth: Int) -> MIMEPart {
        let (headerData, body) = splitHeaderBody(data)
        let headers = MIMEHeaders.parse(headerData)
        let ct = ContentType.parse(headers.first("Content-Type"))
        let (disp, dispParams) = headers.first("Content-Disposition").map(HeaderParams.parse) ?? ("", [:])
        let cid = AddressParser.messageIDs(headers.first("Content-ID")).first.map { String($0.dropFirst().dropLast()) }
        var part = MIMEPart(headers: headers, contentType: ct, disposition: disp.isEmpty ? nil : disp.lowercased(),
                            dispositionParams: dispParams, transferEncoding: headers.first("Content-Transfer-Encoding"),
                            contentID: cid, body: body, children: [])
        if ct.isMultipart, let boundary = ct.boundary, depth < 20 {
            part.children = splitMultipart(body, boundary: boundary).map { parsePart($0, depth: depth + 1) }
            part.body = Data()
        } else if ct.mimeType == "message/rfc822", depth < 20 {
            part.children = [parsePart(part.decodedData, depth: depth + 1)]
        }
        return part
    }

    static func splitMultipart(_ body: Data, boundary: String) -> [Data] {
        let delimiter = Data(("--" + boundary).utf8)
        let bytes = body
        var positions: [Int] = []
        var searchStart = bytes.startIndex
        while let r = bytes.range(of: delimiter, in: searchStart..<bytes.endIndex) {
            let atLineStart = r.lowerBound == bytes.startIndex || bytes[r.lowerBound - 1] == 0x0A
            if atLineStart { positions.append(r.lowerBound) }
            searchStart = r.upperBound
        }
        var parts: [Data] = []
        for (i, pos) in positions.enumerated() {
            var after = pos + delimiter.count
            if after + 1 < bytes.endIndex, bytes[after] == 0x2D, bytes[after + 1] == 0x2D { break }
            while after < bytes.endIndex, bytes[after] != 0x0A { after += 1 }
            if after < bytes.endIndex { after += 1 }
            var end = i + 1 < positions.count ? positions[i + 1] : bytes.endIndex
            if end > after, bytes[end - 1] == 0x0A { end -= 1 }
            if end > after, bytes[end - 1] == 0x0D { end -= 1 }
            if end >= after { parts.append(bytes.subdata(in: after..<end)) }
        }
        return parts
    }

    static func collect(_ part: MIMEPart, textPlain: inout String?, textHTML: inout String?,
                        attachments: inout [MIMEAttachment], inAlternative: Bool) {
        let ct = part.contentType
        if ct.isMultipart {
            let alt = ct.subtype == "alternative"
            for c in part.children {
                collect(c, textPlain: &textPlain, textHTML: &textHTML, attachments: &attachments, inAlternative: alt || inAlternative)
            }
            return
        }
        if ct.mimeType == "message/rfc822" {
            let name = part.filename ?? "message.eml"
            attachments.append(MIMEAttachment(id: UUID().uuidString, filename: name, mimeType: ct.mimeType,
                                              contentID: part.contentID, isInline: false, data: part.decodedData))
            return
        }
        if part.isAttachment {
            let name = part.filename ?? defaultName(for: ct)
            attachments.append(MIMEAttachment(id: UUID().uuidString, filename: name, mimeType: ct.mimeType, contentID: part.contentID,
                                              isInline: (part.disposition ?? "") == "inline" || part.contentID != nil, data: part.decodedData))
            return
        }
        if ct.mimeType == "text/plain" {
            let text = part.decodedText
            if textPlain == nil { textPlain = text } else if !inAlternative { textPlain! += "\n\n" + text }
        } else if ct.mimeType == "text/html" {
            let html = part.decodedText
            if textHTML == nil { textHTML = html } else if !inAlternative { textHTML! += "<hr>" + html }
        } else if ct.isText, textPlain == nil {
            textPlain = part.decodedText
        }
    }

    static func defaultName(for ct: ContentType) -> String {
        let ext: String
        switch ct.mimeType {
        case "image/jpeg": ext = "jpg"
        case "image/png": ext = "png"
        case "image/gif": ext = "gif"
        case "application/pdf": ext = "pdf"
        default: ext = ct.subtype.split(separator: ".").last.map(String.init) ?? "bin"
        }
        return "attachment.\(ext)"
    }
}

public enum HTMLText {
    private static let entities: [String: String] = [
        "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&#160;": " "
    ]

    public static func plainText(from html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: "(?is)<(script|style|head)[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)<br\\s*/?>|</p>|</div>|</tr>|</li>|</h[1-6]>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacingOccurrences(of: "&#(\\d+);", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
        return s.trimmed
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
