import Foundation
import FalconCore

struct ComposeDraft: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var accountID: UUID
    var to: String = ""
    var cc: String = ""
    var bcc: String = ""
    var subject: String = ""
    var body: String = ""
    var attachments: [OutgoingAttachment] = []
    var inReplyTo: String?
    var references: [String] = []
    var scheduledAt: Date?
    var historyPlain: String = ""
    var historyHTML: String = ""
    var sourceMessageID: String?

    var isBlank: Bool {
        to.trimmed.isEmpty && cc.trimmed.isEmpty && bcc.trimmed.isEmpty && subject.trimmed.isEmpty && attachments.isEmpty
            && body.replacingOccurrences(of: historyPlain, with: "").trimmed.isEmpty
    }

    static func reply(to message: MessageSummary, parsed: MIMEMessage?, account: AccountInfo, all: Bool) -> ComposeDraft {
        var d = ComposeDraft(accountID: account.id)
        let replyTarget = parsed?.replyTo.first ?? message.from
        d.to = replyTarget.rfc5322
        if all {
            let others = (message.to + message.cc).filter { $0.address.caseInsensitiveCompare(account.email) != .orderedSame && $0.address != replyTarget.address }
            d.cc = others.map { $0.rfc5322 }.joined(separator: ", ")
        }
        d.subject = message.subject.lowercased().hasPrefix("re:") ? message.subject : "Re: \(message.subject)"
        d.inReplyTo = message.messageID
        d.references = message.references + [message.messageID].filter { !$0.isEmpty }
        let h = history(message, parsed: parsed)
        d.historyPlain = h.plain
        d.historyHTML = h.html
        d.body = "\n\n" + signatureBlock(account) + h.plain
        return d
    }

    static func forward(_ message: MessageSummary, parsed: MIMEMessage?, account: AccountInfo) -> ComposeDraft {
        var d = ComposeDraft(accountID: account.id)
        d.subject = message.subject.lowercased().hasPrefix("fwd:") ? message.subject : "Fwd: \(message.subject)"
        let h = history(message, parsed: parsed)
        d.historyPlain = h.plain
        d.historyHTML = h.html
        d.body = "\n\n" + signatureBlock(account) + h.plain
        d.attachments = parsed.map { ComposeDraft.outgoingAttachments(of: $0) } ?? []
        return d
    }

    static func from(parsed: MIMEMessage, accountID: UUID) -> ComposeDraft {
        var d = ComposeDraft(accountID: accountID)
        d.to = parsed.to.map { $0.rfc5322 }.joined(separator: ", ")
        d.cc = parsed.cc.map { $0.rfc5322 }.joined(separator: ", ")
        d.bcc = AddressParser.parse(parsed.headers.first("Bcc")).map { $0.rfc5322 }.joined(separator: ", ")
        d.subject = parsed.subject
        d.body = parsed.bestText
        d.attachments = ComposeDraft.outgoingAttachments(of: parsed)
        d.inReplyTo = parsed.inReplyTo.isEmpty ? nil : parsed.inReplyTo
        d.references = parsed.references
        return d
    }

    static func outgoingAttachments(of parsed: MIMEMessage) -> [OutgoingAttachment] {
        parsed.attachments.filter { !$0.isInline }.map { OutgoingAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data) }
    }

    static func blank(account: AccountInfo) -> ComposeDraft {
        var d = ComposeDraft(accountID: account.id)
        d.body = "\n\n" + signatureBlock(account)
        return d
    }

    static func signatureBlock(_ account: AccountInfo) -> String {
        account.signature.trimmed.isEmpty ? "" : "-- \n\(account.signature)\n\n"
    }

    static let separatorLine = AttachmentReminder.separatorLine

    static func history(_ message: MessageSummary, parsed: MIMEMessage?) -> (plain: String, html: String) {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        let sent = f.string(from: message.date)
        let to = message.to.map { $0.rfc5322 }.joined(separator: "; ")
        let cc = message.cc.map { $0.rfc5322 }.joined(separator: "; ")
        var plain = "\n" + separatorLine + "\n"
        plain += "From: \(message.from.rfc5322)\n"
        plain += "Sent: \(sent)\n"
        plain += "To: \(to)\n"
        if !cc.isEmpty { plain += "Cc: \(cc)\n" }
        plain += "Subject: \(message.subject)\n\n"
        plain += (parsed?.bestText ?? message.snippet).trimmed + "\n"

        var html = "<hr style=\"border:none;border-top:1px solid #b5b5b5;margin:18px 0 10px 0\">"
        html += "<div style=\"font-size:13px;color:#555;margin-bottom:10px\">"
        html += "<b>From:</b> \(HTMLText.escape(message.from.rfc5322))<br>"
        html += "<b>Sent:</b> \(HTMLText.escape(sent))<br>"
        html += "<b>To:</b> \(HTMLText.escape(to))<br>"
        if !cc.isEmpty { html += "<b>Cc:</b> \(HTMLText.escape(cc))<br>" }
        html += "<b>Subject:</b> \(HTMLText.escape(message.subject))</div>"
        if let original = parsed?.textHTML, !original.trimmed.isEmpty {
            var inner = original
            for a in parsed?.attachments ?? [] where a.contentID != nil {
                inner = inner.replacingOccurrences(of: "cid:\(a.contentID!)", with: "data:\(a.mimeType);base64,\(a.data.base64EncodedString())", options: .caseInsensitive)
            }
            inner = inner.replacingOccurrences(of: "(?is)<script[^>]*>.*?</script>", with: "", options: .regularExpression)
            inner = inner.replacingOccurrences(of: "(?is)<(/?)(html|head|body)[^>]*>", with: "", options: .regularExpression)
            html += "<div>\(inner)</div>"
        } else {
            html += "<div style=\"white-space:pre-wrap\">\(HTMLText.escape(parsed?.bestText ?? message.snippet))</div>"
        }
        return (plain, html)
    }

    func outgoing(from account: AccountInfo, requireRecipients: Bool = true) throws -> OutgoingMessage {
        let toList = AddressParser.parse(to)
        guard !requireRecipients || !toList.isEmpty || !AddressParser.parse(cc).isEmpty || !AddressParser.parse(bcc).isEmpty else {
            throw FalconError.invalidInput("Add at least one recipient.")
        }
        let style = "font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:14px"
        var html: String
        if !historyPlain.isEmpty, body.hasSuffix(historyPlain), !historyHTML.isEmpty {
            let own = String(body.dropLast(historyPlain.count))
            html = "<html><body style=\"\(style)\"><div style=\"white-space:pre-wrap\">\(HTMLText.escape(own))</div>\(historyHTML)</body></html>"
        } else {
            html = "<html><body style=\"\(style);white-space:pre-wrap\">\(HTMLText.escape(body))</body></html>"
        }
        return OutgoingMessage(from: EmailAddress(name: account.displayName, address: account.email), to: toList,
                               cc: AddressParser.parse(cc), bcc: AddressParser.parse(bcc), subject: subject, textBody: body,
                               htmlBody: html, attachments: attachments, inReplyTo: inReplyTo, references: references)
    }
}

struct ComposeDraftSidecar: Codable, Sendable {
    var id: UUID
    var accountID: UUID
    var to: String
    var cc: String
    var bcc: String
    var subject: String
    var body: String
    var inReplyTo: String?
    var references: [String]
    var scheduledAt: Date?
    var historyPlain: String
    var historyHTML: String

    init(_ draft: ComposeDraft) {
        id = draft.id
        accountID = draft.accountID
        to = draft.to
        cc = draft.cc
        bcc = draft.bcc
        subject = draft.subject
        body = draft.body
        inReplyTo = draft.inReplyTo
        references = draft.references
        scheduledAt = draft.scheduledAt
        historyPlain = draft.historyPlain
        historyHTML = draft.historyHTML
    }

    func draft(attachments: [OutgoingAttachment]) -> ComposeDraft {
        var d = ComposeDraft(id: id, accountID: accountID)
        d.to = to
        d.cc = cc
        d.bcc = bcc
        d.subject = subject
        d.body = body
        d.attachments = attachments
        d.inReplyTo = inReplyTo
        d.references = references
        d.scheduledAt = scheduledAt
        d.historyPlain = historyPlain
        d.historyHTML = historyHTML
        return d
    }
}
