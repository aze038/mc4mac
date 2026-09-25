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
    /// The body with its pictures, as flat RTFD, kept only while it holds any, beside the RTF an
    /// earlier build reads (see ComposedBody.stored).
    var bodyRTFD: Data?
    var attachments: [OutgoingAttachment] = []
    var inReplyTo: String?
    var references: [String] = []
    var scheduledAt: Date?
    var historyPlain: String = ""
    var historyHTML: String = ""
    var sourceMessageID: String?
    /// The row in Drafts this draft was opened from, as it was then. Saving or sending the
    /// draft removes that row, but only while its UID still names that message: the folder may
    /// have been renumbered since, and the UID given to another draft. Absent from drafts kept
    /// by an earlier build, whose stored copy is then left where it is.
    var sourceMessage: MessageSummary?
    var importance: String = "normal"
    /// A new message's body as its signature left it, so that changing the From account before
    /// the body is touched swaps the signature for the new account's.
    var autoSignature: AutoSignature?
    /// The Gmail conversation a reply or forward of a Google account on the Gmail API goes in, so
    /// Gmail keeps it with the message it answers. Absent from drafts kept by earlier builds,
    /// which read past it.
    var gmailThreadID: GmailThreadID?

    struct AutoSignature: Codable, Hashable, Sendable {
        var lead: String
        var body: String
        var bodyRTF: Data?
        var bodyRTFD: Data?
    }

    /// The body in every form it is kept in, which the composer's text view reads and writes
    /// as one.
    var richBody: RichText.Body {
        get { RichText.Body(plain: body, rtf: bodyRTF, rtfd: bodyRTFD) }
        set {
            body = newValue.plain
            bodyRTF = newValue.rtf
            bodyRTFD = newValue.rtfd
        }
    }

    /// A digest of what the message held when it was opened, fresh or from the Drafts folder,
    /// which closing compares against so that a message nobody changed closes without leaving a
    /// copy in Drafts. Nil for a message that exists nowhere else, such as a send called back
    /// from the Outbox, which closing always keeps.
    var openedDigest: String?

    /// Everything closing without saving would lose: who it is from and to, what it says and
    /// how, what is attached, when it goes and how important it is.
    var contentDigest: String {
        let fields = [accountID.uuidString, to, cc, bcc, subject, body, importance,
                      scheduledAt.map { String($0.timeIntervalSince1970) } ?? ""]
        let attached = attachments.flatMap { [Data($0.filename.utf8), Data($0.mimeType.utf8), $0.data] }
        // A body without pictures is fingerprinted as before, so a draft kept by an earlier
        // build still counts as untouched.
        let pictures = bodyRTFD.map { [$0] } ?? []
        return UnsentMessage.fingerprint(fields.map { Data($0.utf8) } + [bodyRTF ?? Data()] + pictures + attached)
    }

    /// Remembers what it holds now, as it opens from `origin`, or forgets it where nothing else
    /// holds the message.
    mutating func markOpened(as origin: UnsentMessage.Origin) {
        openedDigest = origin.remembersOpening ? contentDigest : nil
    }

    /// Whether it still holds what it opened with, where something else holds that too, so that
    /// closing it now keeps nothing.
    var isUntouched: Bool { openedDigest != nil && openedDigest == contentDigest }

    /// Takes what it holds now as what it opened with, where its opening is remembered at all:
    /// as when the pictures from the web fetched for a message nobody has touched fill their
    /// boxes, so that it still closes without leaving a copy in Drafts.
    mutating func keepUntouched() {
        if openedDigest != nil { openedDigest = contentDigest }
    }

    /// What closing it does: nothing is kept when nothing would be lost, else it goes to Drafts.
    var closing: UnsentMessage.Closing {
        UnsentMessage.closing(openedDigest: openedDigest, digest: contentDigest, blank: isBlank)
    }

    var isBlank: Bool {
        to.trimmed.isEmpty && cc.trimmed.isEmpty && bcc.trimmed.isEmpty && subject.trimmed.isEmpty && attachments.isEmpty
            && body.replacingOccurrences(of: historyPlain, with: "").trimmed.isEmpty
    }

    /// A reply, its original quoted as Legacy Outlook quotes it, as rich text with its pictures
    /// (see ComposedBody.quote), or as its text when it has no HTML that can be read.
    @MainActor
    static func reply(to message: MessageSummary, parsed: MIMEMessage?, account: AccountInfo, all: Bool,
                      signature: Signature?) -> ComposeDraft {
        var d = ComposeDraft(accountID: account.id)
        let recipients = ReplyAddressing.recipients(for: message, replyTo: parsed?.replyTo ?? [], own: account.ownAddresses, all: all)
        d.to = OutgoingRecipients.box(recipients.to)
        if all { d.cc = OutgoingRecipients.box(recipients.cc) }
        d.subject = message.subject.lowercased().hasPrefix("re:") ? message.subject : "Re: \(message.subject)"
        d.inReplyTo = message.messageID
        d.references = message.references + [message.messageID].filter { !$0.isEmpty }
        d.gmailThreadID = message.gmailThreadID
        d.openQuoting(message, parsed: parsed, signature: signature)
        return d
    }

    @MainActor
    static func forward(_ message: MessageSummary, parsed: MIMEMessage?, account: AccountInfo, signature: Signature?) -> ComposeDraft {
        var d = ComposeDraft(accountID: account.id)
        d.subject = message.subject.lowercased().hasPrefix("fwd:") ? message.subject : "Fwd: \(message.subject)"
        d.gmailThreadID = message.gmailThreadID
        d.openQuoting(message, parsed: parsed, signature: signature)
        d.attachments = parsed.map { ComposeDraft.outgoingAttachments(of: $0) } ?? []
        return d
    }

    /// Starts a reply's or forward's body: a blank line, the signature, then the original. The
    /// original is quoted as rich text, its formatting, links and pictures as it was written,
    /// every picture it would fetch from the web an empty box until it is fetched; only an
    /// original without HTML, or HTML that cannot be read, is quoted as its text. `historyPlain`
    /// is the quote's text, which the body ends with while the original is untouched, and is
    /// then sent as `historyHTML`, the original's own HTML.
    @MainActor
    private mutating func openQuoting(_ message: MessageSummary, parsed: MIMEMessage?, signature: Signature?) {
        let h = ComposeDraft.history(message, parsed: parsed)
        historyHTML = h.html
        if let html = parsed?.textHTML,
           let quote = ComposedBody.quote(heading: h.heading, html: html, parts: parsed?.attachments ?? [],
                                          indent: Preferences.bool(Pref.indentOriginal, default: false),
                                          attributes: RichText.bodyAttributes) {
            let opened = ComposedBody.opening(lead: "\n\n", signature: signature, quote: quote, attributes: RichText.bodyAttributes)
            body = opened.plain
            let stored = ComposedBody.stored(opened.rich)
            bodyRTF = stored.rtf
            bodyRTFD = stored.rtfd
            historyPlain = quote.string
        } else {
            historyPlain = h.plain
            open(lead: "\n\n", signature: signature, tail: h.plain)
        }
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

    /// A draft from a message kept on the server, or in the Outbox by an earlier build: its
    /// formatting and pictures come back from its HTML, each picture from the part the HTML
    /// shows it from, at the size it was sent at; each it shows from the web, such as the logo
    /// in a quoted Gmail signature, is an empty box that is sent from its address again, as a
    /// reply's quote holds it. A message without HTML, or HTML that cannot be read, opens as its
    /// text.
    @MainActor
    static func from(parsed: MIMEMessage, accountID: UUID) -> ComposeDraft {
        var d = ComposeDraft(accountID: accountID)
        d.to = OutgoingRecipients.box(parsed.to)
        d.cc = OutgoingRecipients.box(parsed.cc)
        // A draft saved to Drafts keeps its Bcc recipients in a Bcc header (see uploadDraft).
        d.bcc = OutgoingRecipients.box(AddressParser.parse(parsed.headers.first("Bcc")))
        d.subject = parsed.subject
        d.body = parsed.bestText
        if let html = parsed.textHTML, !html.trimmed.isEmpty,
           let rich = InlinePictures.text(fromHTML: html, parts: parsed.attachments, attributes: RichText.bodyAttributes,
                                          remote: [:], fitting: false) {
            d.richBody = RichText.body(of: rich)
        }
        d.attachments = ComposeDraft.outgoingAttachments(of: parsed)
        d.inReplyTo = parsed.inReplyTo.isEmpty ? nil : parsed.inReplyTo
        d.references = parsed.references
        return d
    }

    /// What a forward, or a draft opened again, carries as attachments: every part but the
    /// pictures its HTML shows, which stay in its text.
    static func outgoingAttachments(of parsed: MIMEMessage) -> [OutgoingAttachment] {
        parsed.attachments.filter { !InlinePictures.isShownInText($0, html: parsed.textHTML) }
            .map { OutgoingAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data) }
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
        let stored = opened.rich.map(ComposedBody.stored)
        bodyRTF = stored?.rtf
        bodyRTFD = stored?.rtfd
    }

    /// A new message's start, remembered until the body is touched.
    mutating func openNew(lead: String, signature: Signature?) {
        open(lead: lead, signature: signature)
        autoSignature = AutoSignature(lead: lead, body: body, bodyRTF: bodyRTF, bodyRTFD: bodyRTFD)
    }

    /// A new message nobody has typed in yet takes the new account's signature for new
    /// messages in place of the old one's, as Outlook's does.
    mutating func changeAccount(to account: AccountInfo, signature: Signature?) {
        accountID = account.id
        guard let auto = autoSignature, auto.body == body, auto.bodyRTF == bodyRTF, auto.bodyRTFD == bodyRTFD else { return }
        openNew(lead: auto.lead, signature: signature)
    }

    /// The original as a reply or forward quotes it, as Legacy Outlook for Mac does (see
    /// ReplyHistory): `heading`, the From, Date, To, Cc and Subject lines in English; `plain`,
    /// the heading and the original's text; and `html`, what is sent for them while the
    /// original is untouched, the original's own HTML with its rules kept to itself. Its
    /// pictures are held in its HTML until the message goes, and are then sent as inline parts
    /// of their own (see ComposedHTML).
    static func history(_ message: MessageSummary, parsed: MIMEMessage?) -> ReplyHistory {
        let mode = AttributionMode(rawValue: Preferences.string(Pref.attributionMode, default: AttributionMode.standard.rawValue)) ?? .standard
        let attribution: ReplyHeader.Attribution
        switch mode {
        case .none: attribution = .none
        case .custom: attribution = .custom(Preferences.string(Pref.attributionFormat, default: "On [DATE], \"[NAME]\" <[ADDRESS]> wrote:"))
        case .standard: attribution = .outlook
        }
        let original = ReplyHeader.Original(from: message.from, date: message.date, to: message.to, cc: message.cc,
                                            subject: message.subject)
        let html = parsed?.textHTML.map { InlinePictures.resolvingCIDs(in: $0, with: parsed?.attachments ?? []) }
        // The original's words, never the codes and addresses its sender's plain text writes for
        // its pictures (see QuotedText); the few words the list shows when it could not be
        // downloaded.
        return ReplyHistory(original: original, html: html, text: QuotedText.of(parsed, snippet: message.snippet),
                            attribution: attribution, indent: Preferences.bool(Pref.indentOriginal, default: false),
                            font: ComposeFont.chosen())
    }

    /// The message as it goes: to everyone in To, Cc and Bcc, each box read as CcBccDeliveryTests
    /// sends it (see OutgoingRecipients). Sending needs someone to send to and nothing in a box
    /// that is no address; `asDraft`, the copy saved to Drafts, needs neither, and does not add
    /// the owner as "automatically Cc or Bcc myself" does, which happens only as it is sent.
    func outgoing(from account: AccountInfo, asDraft: Bool = false) throws -> OutgoingMessage {
        var recipients = OutgoingRecipients(to: to, cc: cc, bcc: bcc)
        if !asDraft {
            try recipients.checkSendable()
            if Preferences.bool(Pref.autoCopySelf, default: false) {
                let mode = OutgoingRecipients.CopyMode(rawValue: Preferences.string(Pref.autoCopyMode, default: "bcc")) ?? .bcc
                recipients.copy(EmailAddress(name: account.displayName, address: account.email), as: mode)
            }
        }
        let date = Date()
        let content = ComposedHTML.content(rtf: bodyRTF, rtfd: bodyRTFD, plain: body, historyPlain: historyPlain,
                                           historyHTML: historyHTML, date: date, font: ComposeFont.chosen())
        return OutgoingMessage(from: EmailAddress(name: account.displayName, address: account.email), to: recipients.to,
                               cc: recipients.cc, bcc: recipients.bcc, subject: subject, textBody: content.plain,
                               htmlBody: content.html, attachments: attachments + content.pictures.map(\.attachment),
                               inReplyTo: inReplyTo, references: references, date: date, importance: importance)
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
    /// The body's formatting and pictures, which a send called back from the Outbox opens
    /// with again. Absent from what an earlier build wrote, whose message then opens as text.
    var bodyRTF: Data?
    var bodyRTFD: Data?
    /// The Gmail conversation, so Undo Send reopens a reply still in it.
    var gmailThreadID: GmailThreadID?

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
        bodyRTF = draft.bodyRTF
        bodyRTFD = draft.bodyRTFD
        gmailThreadID = draft.gmailThreadID
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
        d.bodyRTF = bodyRTF
        d.bodyRTFD = bodyRTFD
        d.gmailThreadID = gmailThreadID
        return d
    }
}
