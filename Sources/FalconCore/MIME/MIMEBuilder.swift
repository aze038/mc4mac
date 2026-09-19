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

    public init(from: EmailAddress, to: [EmailAddress], cc: [EmailAddress] = [], bcc: [EmailAddress] = [],
                replyTo: EmailAddress? = nil, subject: String, textBody: String, htmlBody: String? = nil,
                attachments: [OutgoingAttachment] = [], inReplyTo: String? = nil, references: [String] = [],
                messageID: String? = nil, date: Date = Date()) {
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
        if !m.references.isEmpty { out += fold("References", m.references.joined(separator: "\r\n ")) }
        out += "MIME-Version: 1.0\r\n"
        out += "X-Mailer: FalconMail\r\n"

        let bodyPart = textPart(m)
        if m.attachments.isEmpty {
            out += bodyPart
        } else {
            let boundary = "=_FalconMail_\(UUID().uuidString)"
            out += "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n"
            out += "--\(boundary)\r\n" + bodyPart
            for a in m.attachments {
                out += "\r\n--\(boundary)\r\n"
                out += "Content-Type: \(a.mimeType); name=\"\(sanitize(a.filename))\"\r\n"
                out += "Content-Transfer-Encoding: base64\r\n"
                out += "Content-Disposition: \(a.contentID == nil ? "attachment" : "inline"); filename=\"\(sanitize(a.filename))\"\r\n"
                if let cid = a.contentID { out += "Content-ID: <\(cid)>\r\n" }
                out += "\r\n" + a.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]) + "\r\n"
            }
            out += "--\(boundary)--\r\n"
        }
        return Data(out.utf8)
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
