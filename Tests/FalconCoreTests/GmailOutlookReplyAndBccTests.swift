import XCTest
import AppKit
@testable import FalconCore

/// A Google account on the Gmail API sends what an account on SMTP sends: the reply under Legacy
/// Outlook for Mac's heading, its original's style elements split under Gmail's limit, the
/// recipients read and checked as the compose window reads them, and Bcc only in what is
/// uploaded, written down in sentBcc.json so the reader shows it. Drafts saved to Gmail keep their
/// Bcc, as drafts saved to an IMAP Drafts folder do. Fakes only: an in-memory Gmail and an SMTP
/// server on loopback.
final class GmailOutlookReplyAndBccTests: XCTestCase {
    private var root: URL!
    private let owner = "owner@example.com"
    private let me = EmailAddress(name: "Owner", address: "owner@example.com")
    private let sam = EmailAddress(name: "Sam Sender", address: "sam@example.com")
    private let alex = EmailAddress(name: "Alex Example", address: "alex@example.com")
    private let jo = EmailAddress(name: "Jo Park", address: "jo@example.com")

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("falcon-gmail-outlook-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Log.start(in: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - The reply as SMTP sends it

    func testAReplySentThroughGmailCarriesTheOutlookHeadingAndStylesExactlyAsSMTPSendsThem() async throws {
        // An Outlook original whose style sheet is longer than Gmail reads in one element.
        var rules = "p.MsoNormal, li.MsoNormal, div.MsoNormal {margin:0cm; font-size:11.0pt; font-family:\"Aptos\",sans-serif;}\n"
        for list in 0..<30 {
            rules += "@list l\(list) {mso-list-id:\(1_000_000 + list); mso-list-type:hybrid;}\n"
            for level in 1...9 {
                rules += "@list l\(list):level\(level) {mso-level-number-format:bullet; margin-left:\(18 * level).0pt; text-indent:-18.0pt;}\n"
            }
        }
        let html = "<html><head><style><!--\n\(rules)--></style></head><body lang=EN-GB><div class=WordSection1>"
            + OutlookChainFixtures.paragraph("The figures are in.") + "</div></body></html>"
        XCTAssertGreaterThan(rules.utf8.count, 16_000)
        let original = OutlookChainFixtures.message(html: html, from: sam, to: [alex], cc: [jo], subject: "Figures")
        let content = reply(to: original)
        let message = OutgoingMessage(from: me, to: [sam], cc: [jo], subject: "Re: Figures", textBody: content.plain,
                                      htmlBody: content.html, attachments: content.pictures.map(\.attachment),
                                      inReplyTo: "<figures@example.com>", references: ["<figures@example.com>"])

        // By SMTP, through the Outbox, as an IMAP account sends it.
        let smtpServer = FakeSMTPServer()
        try smtpServer.start()
        defer { smtpServer.stop() }
        let smtpRoot = root.appendingPathComponent("smtp", isDirectory: true)
        let store = MailStore(layout: FileLayout(root: smtpRoot))
        try await store.load()
        let account = AccountInfo(email: owner, displayName: "Owner")
        try await store.saveAccount(account)
        let smtpSender = SMTPSender(store: store, syncer: { _ in nil }) { account, from, recipients, raw in
            try await SMTPSender.deliver(raw, from: from, to: recipients, account: account, over: smtpServer.client(),
                                         password: { "not-a-password" }, accessToken: { "not-a-token" })
        }
        let smtpOutbox = Outbox(layout: FileLayout(root: smtpRoot), sender: smtpSender, undoWindow: 0)
        let smtpItem = try await smtpOutbox.enqueue(accountID: account.id, from: owner, message: message, sendAt: Date())
        await assertEventually { await smtpOutbox.snapshot().first { $0.id == smtpItem.id }?.status == .sent }
        let envelope = try XCTUnwrap(smtpServer.envelopes.last)

        // By Gmail's own send, through the same Outbox code, as a Google account on the Gmail API sends it.
        let r = gmailRig()
        let queued = try await r.outbox.enqueue(accountID: r.mailbox.accountID, from: owner, message: message, sendAt: Date())
        await assertEventually { await r.outbox.snapshot().first { $0.id == queued.id }?.status == .sent }
        let uploadData = try XCTUnwrap(r.transport.uploads(.messagesSend).first)
        let eml = await r.outbox.rawMessage(for: queued.id)
        XCTAssertTrue(String(decoding: uploadData, as: UTF8.self).hasSuffix(String(decoding: try XCTUnwrap(eml), as: UTF8.self)),
                      "the upload is the Outbox's .eml, built by MIMEBuilder as for SMTP, with only headers put before it")

        let bySMTP = MIMEParser.parse(envelope.data)
        let byGmail = MIMEParser.parse(uploadData)
        let smtpHTML = try XCTUnwrap(bySMTP.textHTML)
        let gmailHTML = try XCTUnwrap(byGmail.textHTML)
        XCTAssertEqual(gmailHTML, smtpHTML, "the same HTML part, byte for byte")
        XCTAssertEqual(byGmail.textPlain, bySMTP.textPlain, "the same plain part")

        // Outlook for Mac's heading: its line across the message and the bold lines, in English.
        XCTAssertTrue(gmailHTML.contains("border-top:solid #B5C4DF 1.0pt"), "the heading's line across the message")
        XCTAssertTrue(gmailHTML.contains("<b>From: </b>Sam Sender &lt;sam@example.com&gt;<br><b>Date: </b>"), "heading")
        XCTAssertTrue(gmailHTML.contains("<b>Cc: </b>Jo Park &lt;jo@example.com&gt;<br><b>Subject: </b>Figures</p>"), "heading")
        // The original's rules, split between whole rules into elements Gmail reads whole.
        let head = try XCTUnwrap(gmailHTML.range(of: "</head>").map { String(gmailHTML[..<$0.lowerBound]) })
        let sheets = head.components(separatedBy: "<style>").dropFirst().map { $0.components(separatedBy: "</style>")[0] }
        XCTAssertGreaterThanOrEqual(sheets.count, 2, head.prefix(300).description)
        for sheet in sheets { XCTAssertLessThan(sheet.utf8.count, 16_000) }
        XCTAssertEqual(sheets.joined(), ScopedCSS.scope(rules, to: ".fm-q"), "every rule, in order")

        // The copy in Sent reads in the reader's page with Office's fonts at Outlook's widths.
        let sentID = try XCTUnwrap(r.mailbox.messages.first { $0.labels.contains(.sent) }?.ref.id)
        let full = try await r.transport.message(sentID, format: .full, work: .interactive)
        let opened = GmailMessageContent.textStage(full)
        let page = ReadingHTML.page(body: try XCTUnwrap(opened.message.textHTML), parts: opened.message.attachments,
                                    allowRemote: false, dark: false, ownColours: false, installedFamilies: [])
        XCTAssertTrue(page.contains("@font-face{font-family:\"Aptos\";src:local(\"Helvetica\")"), "Office's font stood in for")
    }

    // MARK: - Bcc

    func testABccOnlySendThroughGmailPutsBccOnlyInTheUploadAndWritesItDown() async throws {
        let r = gmailRig()
        // Gmail gives the message a Message-ID of its own, which its copy in Sent then carries.
        r.mailbox.replacesMessageIDOnSend = true
        let boxes = OutgoingRecipients(to: "", cc: "", bcc: "Cy Young <cy@example.com>\ncat@example.com, CY@example.com")
        try boxes.checkSendable()
        XCTAssertEqual(boxes.bcc.count, 3, "as typed")
        let message = OutgoingMessage(from: me, to: boxes.to, cc: boxes.cc, bcc: boxes.bcc, subject: "Rates", textBody: "Hello, see below.")
        XCTAssertEqual(message.allRecipients, ["cy@example.com", "cat@example.com"], "each address once")

        let queued = try await r.outbox.enqueue(accountID: r.mailbox.accountID, from: owner, message: message, sendAt: Date())
        await assertEventually { await r.outbox.snapshot().first { $0.id == queued.id }?.status == .sent }
        let sent = await r.outbox.snapshot().first { $0.id == queued.id }
        XCTAssertEqual(sent?.status, .sent, sent?.error ?? "")

        let stored = await r.outbox.rawMessage(for: queued.id)
        let eml = String(decoding: try XCTUnwrap(stored), as: UTF8.self)
        XCTAssertFalse(eml.lowercased().contains("bcc:"), "the .eml on the Mac names no Bcc")
        XCTAssertFalse(eml.lowercased().contains("cy@example.com"))
        XCTAssertEqual(r.transport.uploads(.messagesSend).count, 1)
        let upload = try XCTUnwrap(r.transport.uploads(.messagesSend).first)
        let headers = MIMEParser.parseHeaders(upload)
        XCTAssertEqual(AddressParser.parse(headers.first("Bcc")), [EmailAddress(name: "Cy Young", address: "cy@example.com"),
                                                                   EmailAddress(address: "cat@example.com")],
                       "Bcc in the upload only, each once, with its name")
        XCTAssertNil(headers.first("To"))
        XCTAssertNil(headers.first("Cc"))
        let text = String(decoding: upload, as: UTF8.self)
        XCTAssertEqual(text.components(separatedBy: "cy@example.com").count - 1, 1, "named once, in the Bcc header")

        // Written down under FalconMail's Message-ID and Gmail's, read back from sentBcc.json.
        let reread = SentBccStore(file: r.layout.sentBccFile)
        let expected = [EmailAddress(name: "Cy Young", address: "cy@example.com"), EmailAddress(address: "cat@example.com")]
        XCTAssertEqual(reread.bcc(forMessageID: message.messageID), expected)
        let gmailCopy = try XCTUnwrap(r.mailbox.messages.first { $0.labels.contains(.sent) })
        let gmails = try XCTUnwrap(gmailCopy.headers.first { $0.name == "Message-ID" }?.value)
        XCTAssertNotEqual(SentBccStore.key(gmails), SentBccStore.key(message.messageID))
        XCTAssertEqual(reread.bcc(forMessageID: gmails), expected)

        // The reader finds them for the engine's row, keyed <account>:gm:<hex>, however little
        // its row knows yet.
        let key = RowKey.gmail(account: r.mailbox.accountID, id: gmailCopy.ref.id)
        var row = MessageSummary(accountID: r.mailbox.accountID, folderID: UUID(), uid: 0, messageID: gmails, inReplyTo: "", references: [],
                                 subject: "Rates", from: me, to: [], cc: [], date: Date(), flags: [.seen], size: 0, snippet: "",
                                 hasAttachments: false)
        row.id = key.stringValue
        row.gmailID = gmailCopy.ref.id
        XCTAssertTrue(row.id.contains(":gm:"), row.id)
        let shown = ReaderRecipients(row, parsed: nil, recorded: { reread.bcc(forMessageID: $0) })
        XCTAssertEqual(shown.bcc, expected)
        XCTAssertTrue(shown.to.isEmpty && shown.cc.isEmpty)
        // A stand-in row with no Message-ID yet: its body's gives it.
        row.messageID = ""
        let body = MIMEParser.parse(Data("Message-ID: \(gmails)\r\nFrom: \(owner)\r\nSubject: Rates\r\n\r\nHello\r\n".utf8))
        XCTAssertEqual(ReaderRecipients(row, parsed: body, recorded: { reread.bcc(forMessageID: $0) }).bcc, expected)
    }

    func testTheReaderShowsToAndCcFromTheBodyWhenAnEngineRowStandsInWithoutThem() {
        let accountID = UUID()
        var row = MessageSummary(accountID: accountID, folderID: UUID(), uid: 0, messageID: "", inReplyTo: "", references: [],
                                 subject: "Figures", from: sam, to: [], cc: [], date: Date(), flags: [.seen], size: 0, snippet: "",
                                 hasAttachments: false)
        row.id = RowKey.gmail(account: accountID, id: GmailMessageID(raw: 0x1a2b)).stringValue
        let body = MIMEParser.parse(Data("From: \(sam.rfc5322)\r\nTo: \(alex.rfc5322)\r\nCc: \(jo.rfc5322)\r\nBcc: dee@example.com\r\nSubject: Figures\r\n\r\nHi\r\n".utf8))
        let shown = ReaderRecipients(row, parsed: body, recorded: { _ in [] })
        XCTAssertEqual(shown.to, [alex])
        XCTAssertEqual(shown.cc, [jo], "Cc shown whenever the message has one")
        XCTAssertEqual(shown.bcc.map(\.address), ["dee@example.com"])
        // A row that knows its own addresses keeps them.
        row.to = [sam]
        row.bcc = [EmailAddress(address: "eve@example.com")]
        let known = ReaderRecipients(row, parsed: body, recorded: { _ in [] })
        XCTAssertEqual(known.to, [sam])
        XCTAssertEqual(known.bcc.map(\.address), ["dee@example.com", "eve@example.com"])
    }

    // MARK: - Recipients checked before Gmail is asked anything

    func testAnEntryThatIsNoAddressFailsOnTheGmailPathBeforeAnyCall() async throws {
        let r = gmailRig()
        let before = r.mailbox.calls.values.reduce(0, +)
        let typed = OutgoingRecipients(to: "ana@example.com, Stone", cc: "", bcc: "")
        let expected = try XCTUnwrap(typed.unreadable).sentence
        XCTAssertThrowsError(try typed.checkSendable(), "the compose window refuses it too")
        let message = OutgoingMessage(from: me, to: typed.to, subject: "Rates", textBody: "Hello")
        _ = try await r.outbox.enqueue(accountID: r.mailbox.accountID, from: owner, message: message, sendAt: Date())
        await assertEventually { await r.outbox.snapshot().first?.status == .failed }
        let failed = await r.outbox.snapshot().first
        XCTAssertEqual(failed?.error, expected)
        XCTAssertFalse(failed?.isHeld ?? true, "refused for good, never held as maybe sent")
        XCTAssertNil(failed?.attemptID, "no attempt was begun")
        XCTAssertEqual(r.mailbox.calls.values.reduce(0, +), before, "Gmail was asked nothing")
        XCTAssertTrue(r.transport.uploads(.messagesSend).isEmpty)

        // Nobody to send to at all is refused the same way.
        let nobody = OutgoingMessage(from: me, to: [], subject: "Empty", textBody: "Hello")
        let item = try await r.outbox.enqueue(accountID: r.mailbox.accountID, from: owner, message: nobody, sendAt: Date())
        await assertEventually { await r.outbox.snapshot().first { $0.id == item.id }?.status == .failed }
        let empty = await r.outbox.snapshot().first { $0.id == item.id }
        XCTAssertEqual(empty?.error, "Add at least one recipient.")
        XCTAssertEqual(r.mailbox.calls.values.reduce(0, +), before)
    }

    // MARK: - Drafts

    func testADraftSavedThroughGmailKeepsItsBccToBeSentLater() async throws {
        let transport = ScriptedGmailTransport(FakeGmail(email: owner))
        let mailbox = transport.mailbox
        let store = GmailTestPlacer.store(accountID: mailbox.accountID, root: root)
        let drafts = GmailDrafts(accountID: mailbox.accountID, email: owner, transport: transport,
                                 placer: GmailTestPlacer.engine(transport: transport, store: store),
                                 file: root.appendingPathComponent("drafts.json"), cursor: { mailbox.historyID },
                                 now: { Date() }, retryInterval: 0.1)
        // As the app saves one: the boxes read as when sent, built with Bcc kept, as for IMAP Drafts.
        let boxes = OutgoingRecipients(to: "ana@example.com", cc: "", bcc: "Cy Young <cy@example.com>; cat@example.com")
        let message = OutgoingMessage(from: me, to: boxes.to, cc: boxes.cc, bcc: boxes.bcc, subject: "Rates", textBody: "Draft words")
        let raw = MIMEBuilder.build(message, keepingBcc: true)
        let localID = UUID()
        let ref = DraftRef(localID: localID, accountID: mailbox.accountID, gmailDraftID: nil, threadID: nil,
                           stableMessageID: "<\(localID.uuidString.lowercased()).falconmail@example.com>")
        let saved = try await drafts.save(raw, as: ref, bcc: message.bcc)
        XCTAssertNotNil(saved.gmailDraftID)

        let upload = try XCTUnwrap(transport.uploads(.draftsCreate).first)
        let text = String(decoding: upload, as: UTF8.self)
        XCTAssertEqual(text.components(separatedBy: "\r\nBcc:").count - 1, 1, "one Bcc header")
        let bcc = [EmailAddress(name: "Cy Young", address: "cy@example.com"), EmailAddress(address: "cat@example.com")]
        XCTAssertEqual(AddressParser.parse(MIMEParser.parseHeaders(upload).first("Bcc")), bcc)

        // Gmail's copy of the draft opens again with its Bcc, so it goes to them when sent.
        let copy = try XCTUnwrap(mailbox.messages.first { $0.labels.contains(.draft) })
        XCTAssertEqual(AddressParser.parse(copy.headers.first { $0.name.caseInsensitiveCompare("Bcc") == .orderedSame }?.value), bcc)

        // Saved again, as by an automatic save that passes no Bcc of its own, the draft still keeps it.
        _ = try await drafts.save(raw, as: saved)
        let again = try XCTUnwrap(transport.uploads(.draftsUpdate).last)
        XCTAssertEqual(AddressParser.parse(MIMEParser.parseHeaders(again).first("Bcc")), bcc)
    }

    // MARK: - Helpers

    private struct Rig {
        let mailbox: FakeGmail
        let transport: ScriptedGmailTransport
        let outbox: Outbox
        let layout: FileLayout
    }

    /// An Outbox sending through GmailSender, with the Outbox's own sentBcc.json, as the engine's
    /// assembly gives it.
    private func gmailRig() -> Rig {
        let mailbox = FakeGmail(email: owner)
        let transport = ScriptedGmailTransport(mailbox)
        let store = GmailTestPlacer.store(accountID: mailbox.accountID, root: root)
        let layout = FileLayout(root: root.appendingPathComponent("gmail", isDirectory: true))
        let sender = GmailSender(accountID: mailbox.accountID, email: owner, transport: transport,
                                 placer: GmailTestPlacer.engine(transport: transport, store: store), deleteDraft: nil,
                                 cursor: { mailbox.historyID }, wentOut: {}, keepsOwnMessageID: false,
                                 sentBcc: SentBccStore.shared(file: layout.sentBccFile))
        let outbox = Outbox(layout: layout, sender: sender, undoWindow: 0, confirmAfter: [0.05, 0.15], retryDelay: { _ in 0 })
        return Rig(mailbox: mailbox, transport: transport, outbox: outbox, layout: layout)
    }

    /// A reply as the compose window writes it (see OutlookReplyTests).
    private func reply(to parsed: MIMEMessage, saying words: String = "Thanks, noted.", font: ComposeFont = .outlook) -> ComposedHTML.Content {
        let heading = ReplyHeader.Original(from: parsed.from, date: parsed.date ?? Date(), to: parsed.to, cc: parsed.cc,
                                           subject: parsed.subject)
        let history = ReplyHistory(original: heading, html: parsed.textHTML.map { InlinePictures.resolvingCIDs(in: $0, with: parsed.attachments) },
                                   text: parsed.bestText, attribution: .outlook, indent: false, font: font)
        let attributes: [NSAttributedString.Key: Any] = [.font: font.displayFont, .foregroundColor: NSColor.labelColor]
        let body = NSMutableAttributedString(string: words + "\n\n", attributes: attributes)
        body.append(NSAttributedString(string: history.plain, attributes: attributes))
        let stored = ComposedBody.stored(body)
        return ComposedHTML.content(rtf: stored.rtf, rtfd: stored.rtfd, plain: body.string, historyPlain: history.plain,
                                    historyHTML: history.html, font: font)
    }
}
