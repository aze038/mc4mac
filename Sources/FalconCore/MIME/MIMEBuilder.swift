import Foundation

public struct OutgoingAttachment: Sendable, Hashable, Identifiable, Codable {
    public var id: UUID
    public var filename: String
    public var mimeType: String
    public var data: Data
    public var contentID: String?

    public init(filename: String, mimeType: String, data: Data, contentID: String? = nil) {
        self.id = UUID()
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.contentID = contentID
    }
}

public struct OutgoingMessage: Sendable, Hashable {
    public var from: EmailAddress
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var replyTo: EmailAddress?
    public var subject: String
    public var textBody: String
    public var htmlBody: String?
    public var attachments: [OutgoingAttachment]
    public var inReplyTo: String?
    public var references: [String]
    public var messageID: String
    public var date: Date
    public var importance: String = "normal"

    public init(from: EmailAddress, to: [EmailAddress], cc: [EmailAddress] = [], bcc: [EmailAddress] = [],
                replyTo: EmailAddress? = nil, subject: String, textBody: String, htmlBody: String? = nil,
                attachments: [OutgoingAttachment] = [], inReplyTo: String? = nil, references: [String] = [],
                messageID: String? = nil, date: Date = Date(), importance: String = "normal") {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.replyTo = replyTo
        self.subject = subject
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.attachments = attachments
        self.inReplyTo = inReplyTo
        self.references = references
        self.messageID = messageID ?? OutgoingMessage.generateMessageID(domain: from.address.split(separator: "@").last.map(String.init) ?? "falconmail.local")
        self.date = date
        self.importance = importance
    }

    public var allRecipients: [String] { (to + cc + bcc).map { $0.address } }

    public static func generateMessageID(domain: String) -> String {
        "<\(UUID().uuidString.lowercased()).falconmail@\(domain)>"
    }
}

public enum MIMEBuilder {
    public static func build(_ m: OutgoingMessage) -> Data {
        var out = ""
        out += "Date: \(RFC5322Date.format(m.date))\r\n"
        out += "From: \(encodeAddress(m.from))\r\n"
        if !m.to.isEmpty { out += fold("To", m.to.map(encodeAddress).joined(separator: ",\r\n ")) }
        if !m.cc.isEmpty { out += fold("Cc", m.cc.map(encodeAddress).joined(separator: ",\r\n ")) }
        if let r = m.replyTo { out += "Reply-To: \(encodeAddress(r))\r\n" }
        out += "Subject: \(RFC2047.encode(m.subject))\r\n"
        out += "Message-ID: \(m.messageID)\r\n"
        if let irt = m.inReplyTo, !irt.isEmpty { out += "In-Reply-To: \(irt)\r\n" }
        switch m.importance {
        case "high": out += "Importance: High\r\nX-Priority: 1\r\n"
        case "low": out += "Importance: Low\r\nX-Priority: 5\r\n"
        default: break
        }
        if !m.references.isEmpty { out += fold("References", m.references.joined(separator: "\r\n ")) }
        out += "MIME-Version: 1.0\r\n"
        out += "X-Mailer: FalconMail\r\n"

        // Laid out as Outlook lays a message out: the text and HTML as multipart/alternative;
        // the pictures the HTML shows beside it, inside multipart/related; and that, when files
        // are attached as well, first inside multipart/mixed.
        let pictures = m.htmlBody == nil ? [] : m.attachments.filter { $0.contentID != nil }
        let files = m.htmlBody == nil ? m.attachments : m.attachments.filter { $0.contentID == nil }
        var bodyPart = textPart(m)
        if !pictures.isEmpty { bodyPart = relatedPart(bodyPart, pictures: pictures) }
        if files.isEmpty {
            out += bodyPart
        } else {
            let boundary = "=_FalconMail_\(UUID().uuidString)"
            out += "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n"
            out += "--\(boundary)\r\n" + bodyPart
            for a in files {
                out += "\r\n--\(boundary)\r\n" + attachmentPart(a)
            }
            out += "--\(boundary)--\r\n"
        }
        return Data(out.utf8)
    }

    /// The text and HTML with the pictures the HTML shows by `cid:`, as RFC 2387 has it: the
    /// first part is the one a reader opens, and `type` says what it is.
    static func relatedPart(_ body: String, pictures: [OutgoingAttachment]) -> String {
        let boundary = "=_FalconMailRel_\(UUID().uuidString)"
        var out = "Content-Type: multipart/related; boundary=\"\(boundary)\"; type=\"multipart/alternative\"\r\n\r\n"
        out += "--\(boundary)\r\n" + body
        for picture in pictures {
            out += "\r\n--\(boundary)\r\n" + attachmentPart(picture)
        }
        out += "--\(boundary)--\r\n"
        return out
    }

    /// A file attached, or a picture shown in the text, which has a Content-ID and is inline,
    /// with Outlook's headers for one: its name, a description, its size.
    static func attachmentPart(_ a: OutgoingAttachment) -> String {
        let name = sanitize(a.filename)
        var out = "Content-Type: \(a.mimeType); name=\"\(name)\"\r\n"
        if let cid = a.contentID {
            out += "Content-Description: \(name)\r\n"
            out += "Content-Disposition: inline; filename=\"\(name)\"; size=\(a.data.count)\r\n"
            out += "Content-ID: <\(cid)>\r\n"
        } else {
            out += "Content-Disposition: attachment; filename=\"\(name)\"\r\n"
        }
        out += "Content-Transfer-Encoding: base64\r\n"
        out += "\r\n" + a.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]) + "\r\n"
        return out
    }

    static func textPart(_ m: OutgoingMessage) -> String {
        let plain = "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n" + QuotedPrintable.encode(m.textBody) + "\r\n"
        guard let html = m.htmlBody else { return plain }
        let boundary = "=_FalconMailAlt_\(UUID().uuidString)"
        var out = "Content-Type: multipart/alternative; boundary=\"\(boundary)\"\r\n\r\n"
        out += "--\(boundary)\r\n" + plain
        out += "--\(boundary)\r\n"
        out += "Content-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n" + QuotedPrintable.encode(html) + "\r\n"
        out += "--\(boundary)--\r\n"
        return out
    }

    static func encodeAddress(_ a: EmailAddress) -> String {
        if a.name.isEmpty { return a.address }
        let name = a.name.allSatisfy(\.isASCII) ? a.name : RFC2047.encode(a.name)
        return EmailAddress(name: name, address: a.address).rfc5322
    }

    static func fold(_ name: String, _ value: String) -> String { "\(name): \(value)\r\n" }

    static func sanitize(_ filename: String) -> String {
        filename.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
    }
}

public enum QuotedPrintable {
    public static func encode(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines: [String] = []
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = ""
            var encoded = ""
            let bytes = Array(String(rawLine).utf8)
            for (i, b) in bytes.enumerated() {
                let isLast = i == bytes.count - 1
                if (b >= 33 && b <= 126 && b != 61) || ((b == 32 || b == 9) && !isLast) {
                    encoded = String(Character(UnicodeScalar(b)))
                } else {
                    encoded = String(format: "=%02X", b)
                }
                if line.count + encoded.count > 75 {
                    lines.append(line + "=")
                    line = ""
                }
                line += encoded
            }
            lines.append(line)
        }
        return lines.joined(separator: "\r\n")
    }
}
