import Foundation
import FalconCore

struct ComposeDraft: Identifiable, Hashable {
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
        d.body = "\n\n" + signatureBlock(account) + quote(message, parsed: parsed)
        return d
    }

    static func forward(_ message: MessageSummary, parsed: MIMEMessage?, account: AccountInfo) -> ComposeDraft {
        var d = ComposeDraft(accountID: account.id)
        d.subject = message.subject.lowercased().hasPrefix("fwd:") ? message.subject : "Fwd: \(message.subject)"
        d.body = "\n\n" + signatureBlock(account) + "---------- Forwarded message ----------\n" + quote(message, parsed: parsed, prefix: "")
        d.attachments = (parsed?.attachments ?? []).map { OutgoingAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data) }
        return d
    }

    static func blank(account: AccountInfo) -> ComposeDraft {
        var d = ComposeDraft(accountID: account.id)
        d.body = "\n\n" + signatureBlock(account)
        return d
    }

    static func signatureBlock(_ account: AccountInfo) -> String {
        account.signature.trimmed.isEmpty ? "" : "-- \n\(account.signature)\n\n"
    }

    static func quote(_ message: MessageSummary, parsed: MIMEMessage?, prefix: String = "> ") -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        let header = "On \(f.string(from: message.date)), \(message.from.rfc5322) wrote:\n"
        let text = parsed?.bestText ?? message.snippet
        let quoted = text.split(separator: "\n", omittingEmptySubsequences: false).map { prefix + $0 }.joined(separator: "\n")
        return header + quoted
    }

    func outgoing(from account: AccountInfo) throws -> OutgoingMessage {
        let toList = AddressParser.parse(to)
        guard !toList.isEmpty || !AddressParser.parse(cc).isEmpty || !AddressParser.parse(bcc).isEmpty else {
            throw FalconError.invalidInput("Add at least one recipient.")
        }
        let html = "<html><body style=\"font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:14px;white-space:pre-wrap\">" + HTMLText.escape(body) + "</body></html>"
        return OutgoingMessage(from: EmailAddress(name: account.displayName, address: account.email), to: toList,
                               cc: AddressParser.parse(cc), bcc: AddressParser.parse(bcc), subject: subject, textBody: body,
                               htmlBody: html, attachments: attachments, inReplyTo: inReplyTo, references: references)
    }
}
