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
    var bodyRTF: Data?
    var attachments: [OutgoingAttachment] = []
    var inReplyTo: String?
    var references: [String] = []
    var scheduledAt: Date?
    var historyPlain: String = ""
    var historyHTML: String = ""
    var sourceMessageID: String?
    var importance: String = "normal"
    /// A new message's body as its signature left it, so that changing the From account before
    /// the body is touched swaps the signature for the new account's.
    var autoSignature: AutoSignature?

    struct AutoSignature: Codable, Hashable, Sendable {
        var lead: String
        var body: String
        var bodyRTF: Data?
    }

    /// A digest of what the message held when it was opened, fresh or from the Drafts folder,
    /// which closing compares against so it asks only when something would be lost. Nil for a
    /// message that exists nowhere else, such as a send called back from the Outbox, which
    /// always asks.
    var openedDigest: String?

    /// Everything closing without saving would lose: who it is from and to, what it says and
    /// how, what is attached, when it goes and how important it is.
    var contentDigest: String {
        let fields = [accountID.uuidString, to, cc, bcc, subject, body, importance,
                      scheduledAt.map { String($0.timeIntervalSince1970) } ?? ""]
        let attached = attachments.flatMap { [Data($0.filename.utf8), Data($0.mimeType.utf8), $0.data] }
        return UnsentMessage.fingerprint(fields.map { Data($0.utf8) } + [bodyRTF ?? Data()] + attached)
    }

    var isUntouched: Bool { openedDigest == contentDigest }

    mutating func markOpened() { openedDigest = contentDigest }

    var isBlank: Bool {
        to.trimmed.isEmpty && cc.trimmed.isEmpty && bcc.trimmed.isEmpty && subject.trimmed.isEmpty && attachments.isEmpty
            && body.replacingOccurrences(of: historyPlain, with: "").trimmed.isEmpty
    }

    static func reply(to message: MessageSummary, parsed: MIMEMessage?, account: AccountInfo, all: Bool,
                      signature: Signature?) -> ComposeDraft {
        var d = ComposeDraft(accountID: account.id)
        let recipients = ReplyAddressing.recipients(for: message, replyTo: parsed?.replyTo ?? [], own: account.ownAddresses, all: all)
        d.to = recipients.to.map { $0.rfc5322 }.joined(separator: ", ")
        if all { d.cc = recipients.cc.map { $0.rfc5322 }.joined(separator: ", ") }
        d.subject = message.subject.lowercased().hasPrefix("re:") ? message.subject : "Re: \(message.subject)"
        d.inReplyTo = message.messageID
        d.references = message.references + [message.messageID].filter { !$0.isEmpty }
        let h = history(message, parsed: parsed)
        d.historyPlain = h.plain
        d.historyHTML = h.html
        d.open(lead: "\n\n", signature: signature, tail: h.plain)
        return d
    }

    static func forward(_ message: MessageSummary, parsed: MIMEMessage?, account: AccountInfo, signature: Signature?) -> ComposeDraft {
        var d = ComposeDraft(accountID: account.id)
        d.subject = message.subject.lowercased().hasPrefix("fwd:") ? message.subject : "Fwd: \(message.subject)"
        let h = history(message, parsed: parsed)
        d.historyPlain = h.plain
        d.historyHTML = h.html
        d.open(lead: "\n\n", signature: signature, tail: h.plain)
        d.attachments = parsed.map { ComposeDraft.outgoingAttachments(of: $0) } ?? []
        return d
    }

    static func forwardAsAttachment(_ message: MessageSummary, raw: Data, account: AccountInfo, signature: Signature?) -> ComposeDraft {
        var d = ComposeDraft(accountID: account.id)
        d.subject = message.subject.lowercased().hasPrefix("fwd:") ? message.subject : "Fwd: \(message.subject)"
        d.open(lead: "\n\n", signature: signature)
        var name = message.subject.trimmed.isEmpty ? "Forwarded message" : message.subject.trimmed
        name = name.replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression)
        if name.count > 60 { name = String(name.prefix(60)) }
        d.attachments = [OutgoingAttachment(filename: name + ".eml", mimeType: "message/rfc822", data: raw)]
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

    static func blank(account: AccountInfo, signature: Signature?) -> ComposeDraft {
        var d = ComposeDraft(accountID: account.id)
        d.openNew(lead: "\n\n", signature: signature)
        return d
    }

    /// Starts the body with `lead`, the signature, then `tail`, a reply's quoted original. A
    /// signature with formatting of its own makes the body rich text from the start, the rest
    /// of it in the composer's own font.
    mutating func open(lead: String, signature: Signature?, tail: String = "") {
        let opened = ComposedBody.opening(lead: lead, signature: signature, tail: tail, attributes: RichText.bodyAttributes)
        body = opened.plain
        bodyRTF = opened.rich.flatMap { RichText.rtf(from: $0) }
    }

    /// A new message's start, remembered until the body is touched.
    mutating func openNew(lead: String, signature: Signature?) {
        open(lead: lead, signature: signature)
        autoSignature = AutoSignature(lead: lead, body: body, bodyRTF: bodyRTF)
    }

    /// A new message nobody has typed in yet takes the new account's signature for new
    /// messages in place of the old one's, as Outlook's does.
    mutating func changeAccount(to account: AccountInfo, signature: Signature?) {
        accountID = account.id
        guard let auto = autoSignature, auto.body == body, auto.bodyRTF == bodyRTF else { return }
        openNew(lead: auto.lead, signature: signature)
    }

    static let separatorLine = AttachmentReminder.separatorLine

    static func history(_ message: MessageSummary, parsed: MIMEMessage?) -> (plain: String, html: String) {
        let mode = AttributionMode(rawValue: Preferences.string(Pref.attributionMode, default: AttributionMode.standard.rawValue)) ?? .standard
        let indent = Preferences.bool(Pref.indentOriginal, default: false)
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        let sent = f.string(from: message.date)
        let to = message.to.map { $0.rfc5322 }.joined(separator: "; ")
        let cc = message.cc.map { $0.rfc5322 }.joined(separator: "; ")

        var plain = "\n" + separatorLine + "\n"
        var html = "<hr style=\"border:none;border-top:1px solid #b5b5b5;margin:18px 0 10px 0\">"
        switch mode {
        case .none:
            break
        case .custom:
            let line = customAttribution(message: message, sent: sent)
            plain += line + "\n\n"
            html += "<div style=\"font-size:13px;color:#555;margin-bottom:10px\">\(HTMLText.escape(line))</div>"
        case .standard:
            plain += "From: \(message.from.rfc5322)\n"
            plain += "Sent: \(sent)\n"
            plain += "To: \(to)\n"
            if !cc.isEmpty { plain += "Cc: \(cc)\n" }
            plain += "Subject: \(message.subject)\n\n"
            html += "<div style=\"font-size:13px;color:#555;margin-bottom:10px\">"
            html += "<b>From:</b> \(HTMLText.escape(message.from.rfc5322))<br>"
            html += "<b>Sent:</b> \(HTMLText.escape(sent))<br>"
            html += "<b>To:</b> \(HTMLText.escape(to))<br>"
            if !cc.isEmpty { html += "<b>Cc:</b> \(HTMLText.escape(cc))<br>" }
            html += "<b>Subject:</b> \(HTMLText.escape(message.subject))</div>"
        }

        let originalText = (parsed?.bestText ?? message.snippet).trimmed
        plain += (indent ? originalText.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n") : originalText) + "\n"

        let quoteStyle = indent ? "border-left:3px solid #b5b5b5;padding-left:10px;margin-left:2px" : ""
        if let original = parsed?.textHTML, !original.trimmed.isEmpty {
            var inner = original
            for a in parsed?.attachments ?? [] where a.contentID != nil {
                inner = inner.replacingOccurrences(of: "cid:\(a.contentID!)", with: "data:\(a.mimeType);base64,\(a.data.base64EncodedString())", options: .caseInsensitive)
            }
            inner = inner.replacingOccurrences(of: "(?is)<script[^>]*>.*?</script>", with: "", options: .regularExpression)
            inner = inner.replacingOccurrences(of: "(?is)<(/?)(html|head|body)[^>]*>", with: "", options: .regularExpression)
            html += "<div style=\"\(quoteStyle)\">\(inner)</div>"
        } else {
            html += "<div style=\"white-space:pre-wrap;\(quoteStyle)\">\(HTMLText.escape(originalText))</div>"
        }
        return (plain, html)
    }

    static func customAttribution(message: MessageSummary, sent: String) -> String {
        Preferences.string(Pref.attributionFormat, default: "On [DATE], \"[NAME]\" <[ADDRESS]> wrote:")
            .replacingOccurrences(of: "[DATE]", with: sent)
            .replacingOccurrences(of: "[NAME]", with: message.from.name.isEmpty ? message.from.address : message.from.name)
            .replacingOccurrences(of: "[ADDRESS]", with: message.from.address)
    }

    func outgoing(from account: AccountInfo, requireRecipients: Bool = true) throws -> OutgoingMessage {
        let toList = AddressParser.parse(to)
        var ccList = AddressParser.parse(cc)
        var bccList = AddressParser.parse(bcc)
        if Preferences.bool(Pref.autoCopySelf, default: false) {
            let me = EmailAddress(name: account.displayName, address: account.email)
            let alreadyThere = (toList + ccList + bccList).contains { $0.address.caseInsensitiveCompare(account.email) == .orderedSame }
            if !alreadyThere {
                if Preferences.string(Pref.autoCopyMode, default: "bcc") == "cc" { ccList.append(me) } else { bccList.append(me) }
            }
        }
        guard !requireRecipients || !toList.isEmpty || !AddressParser.parse(cc).isEmpty || !AddressParser.parse(bcc).isEmpty else {
            throw FalconError.invalidInput("Add at least one recipient.")
        }
        let html = ComposedHTML.document(rtf: bodyRTF, plain: body, historyPlain: historyPlain, historyHTML: historyHTML)
        return OutgoingMessage(from: EmailAddress(name: account.displayName, address: account.email), to: toList,
                               cc: ccList, bcc: bccList, subject: subject, textBody: body,
                               htmlBody: html, attachments: attachments, inReplyTo: inReplyTo, references: references, importance: importance)
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
