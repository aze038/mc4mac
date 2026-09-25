import XCTest
@testable import FalconCore

/// A message goes to everyone in its To, Cc and Bcc boxes, however they were typed: each address
/// gets a RCPT TO of its own on the real path, compose boxes → OutgoingMessage → Outbox →
/// SMTPSender → SMTPClient → an SMTP server on loopback, and what is handed over names To and
/// Cc in its headers and never Bcc.
final class CcBccDeliveryTests: XCTestCase {
    private var root: URL!
    private var server: FakeSMTPServer!
    private var store: MailStore!
    private var account: AccountInfo!
    private let me = EmailAddress(name: "Owner", address: "owner@example.com")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("falcon-ccbcc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Log.start(in: root)
        server = FakeSMTPServer()
        try server.start()
        store = MailStore(layout: FileLayout(root: root))
        try await store.load()
        // A Google account, as the owner's are: XOAUTH2, and Gmail files the copy in Sent itself.
        account = AccountInfo(email: me.address, displayName: me.name)
        try await store.saveAccount(account)
    }

    override func tearDown() async throws {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: The boxes as typed

    func testEveryShapeTypedIntoToCcAndBccGetsARcptOfItsOwn() async throws {
        let bob = EmailAddress(name: "Bob Stone", address: "bob@example.com")
        let ben = EmailAddress(name: "Ben Ng", address: "ben@example.com")
        let cy = EmailAddress(name: "Cy Young", address: "cy@example.com")
        let suggestedCc = RecipientText.completing(RecipientText.completing("bo", with: bob) + "be", with: ben)
        XCTAssertEqual(suggestedCc, "Bob Stone <bob@example.com>, Ben Ng <ben@example.com>, ", "as the suggestion list leaves it")
        let cases: [(name: String, to: String, cc: String, bcc: String, expected: (to: [String], cc: [String], bcc: [String]))] = [
            ("one each", "ana@example.com", "bob@example.com", "cy@example.com",
             (["ana@example.com"], ["bob@example.com"], ["cy@example.com"])),
            ("several, commas", "ana@example.com, al@example.com", "bob@example.com,ben@example.com", "cy@example.com , cat@example.com",
             (["ana@example.com", "al@example.com"], ["bob@example.com", "ben@example.com"], ["cy@example.com", "cat@example.com"])),
            ("several, semicolons", "ana@example.com; al@example.com", "bob@example.com;ben@example.com", "cy@example.com; cat@example.com",
             (["ana@example.com", "al@example.com"], ["bob@example.com", "ben@example.com"], ["cy@example.com", "cat@example.com"])),
            ("names", "Ana Lee <ana@example.com>", "Bob Stone <bob@example.com>, Ben <ben@example.com>", "Cy Young <cy@example.com>",
             (["ana@example.com"], ["bob@example.com", "ben@example.com"], ["cy@example.com"])),
            ("quoted names with commas and semicolons", "\"Lee, Ana\" <ana@example.com>",
             "\"Stone, Bob\" <bob@example.com>; \"Ng; Ben\" <ben@example.com>", "\"Young, Cy\" <cy@example.com>, \"O'Hara, Cat\" <cat@example.com>",
             (["ana@example.com"], ["bob@example.com", "ben@example.com"], ["cy@example.com", "cat@example.com"])),
            ("trailing separators", "ana@example.com,", "bob@example.com, ben@example.com, ", "cy@example.com;  ",
             (["ana@example.com"], ["bob@example.com", "ben@example.com"], ["cy@example.com"])),
            ("accepted from the suggestion list", RecipientText.completing("an", with: EmailAddress(name: "Ana Lee", address: "ana@example.com")),
             suggestedCc, RecipientText.completing("c", with: cy),
             (["ana@example.com"], ["bob@example.com", "ben@example.com"], ["cy@example.com"])),
            ("pasted a line, a tab or a space apart", "ana@example.com al@example.com", "bob@example.com\nben@example.com\r\n",
             "cy@example.com\tcat@example.com",
             (["ana@example.com", "al@example.com"], ["bob@example.com", "ben@example.com"], ["cy@example.com", "cat@example.com"])),
            ("a name and its address pasted without brackets", "Ana Lee ana@example.com", "Ələsgər Məmmədov <ales@example.com>",
             "Çağla Öztürk <cagla@example.com>",
             (["ana@example.com"], ["ales@example.com"], ["cagla@example.com"])),
        ]
        let outbox = makeOutbox()
        for c in cases {
            let message = try composed(to: c.to, cc: c.cc, bcc: c.bcc)
            let envelope = try await send(message, via: outbox)
            assertDelivered(envelope, to: c.expected.to, cc: c.expected.cc, bcc: c.expected.bcc, c.name)
        }
        XCTAssertEqual(server.envelopes.count, cases.count, "one message each, none lost and none twice")
    }

    func testThirtyInCcAndTwentyInBccAllGetOne() async throws {
        let cc = (1...30).map { "person\($0)@example.com" }
        let bcc = (1...20).map { "hidden\($0)@example.org" }
        let envelope = try await send(try composed(to: "ana@example.com", cc: cc.joined(separator: "; "), bcc: bcc.joined(separator: ", ")),
                                      via: makeOutbox())
        assertDelivered(envelope, to: ["ana@example.com"], cc: cc, bcc: bcc, "long lists")
    }

    func testOnlyCcOrOnlyBccIsEnoughToSend() async throws {
        let outbox = makeOutbox()
        assertDelivered(try await send(try composed(to: "", cc: "bob@example.com", bcc: ""), via: outbox),
                        to: [], cc: ["bob@example.com"], bcc: [], "Cc alone")
        let bccOnly = try await send(try composed(to: "", cc: "", bcc: "cy@example.com, cat@example.com"), via: outbox)
        assertDelivered(bccOnly, to: [], cc: [], bcc: ["cy@example.com", "cat@example.com"], "Bcc alone")
    }

    func testAnAddressInTwoBoxesGetsOneRcpt() async throws {
        let envelope = try await send(try composed(to: "ana@example.com", cc: "ANA@example.com, bob@example.com", bcc: "bob@example.com; cy@example.com"),
                                      via: makeOutbox())
        XCTAssertEqual(envelope.rcptTo, ["ana@example.com", "bob@example.com", "cy@example.com"])
    }

    // MARK: Every way a message reaches the Outbox

    func testReplyAllGoesToEveryoneItNamesAndToWhomeverIsAdded() async throws {
        let received = MessageSummary(accountID: account.id, folderID: UUID(), uid: 7, messageID: "<rates@example.com>", inReplyTo: "",
                                      references: [], subject: "Rates", from: EmailAddress(name: "Ana Lee", address: "ana@example.com"),
                                      to: [me, EmailAddress(name: "Al", address: "al@example.com")],
                                      cc: [EmailAddress(name: "Stone, Bob", address: "bob@example.com"), EmailAddress(address: "ben@example.com")],
                                      date: Date(), flags: [], size: 100, hasAttachments: false)
        let recipients = ReplyAddressing.recipients(for: received, replyTo: [], own: [me.address], all: true)
        // As ComposeDraft.reply fills the boxes, then the owner adds someone in Bcc.
        let to = OutgoingRecipients.box(recipients.to)
        let cc = OutgoingRecipients.box(recipients.cc)
        XCTAssertEqual(to, "Ana Lee <ana@example.com>")
        XCTAssertEqual(cc, "Al <al@example.com>, \"Stone, Bob\" <bob@example.com>, ben@example.com")
        let envelope = try await send(try composed(to: to, cc: cc, bcc: "cy@example.com"), via: makeOutbox())
        assertDelivered(envelope, to: ["ana@example.com"], cc: ["al@example.com", "bob@example.com", "ben@example.com"],
                        bcc: ["cy@example.com"], "Reply All")
        XCTAssertFalse(envelope.rcptTo.contains(me.address), "the owner is not sent their own reply")
    }

    func testAReplyFromAMessageWindowWithCcAndBccAdded() async throws {
        let received = MessageSummary(accountID: account.id, folderID: UUID(), uid: 8, messageID: "<quote@example.com>", inReplyTo: "",
                                      references: [], subject: "Quote", from: EmailAddress(name: "Ana Lee", address: "ana@example.com"),
                                      to: [me], cc: [EmailAddress(address: "bob@example.com")], date: Date(), flags: [], size: 100,
                                      hasAttachments: false)
        let recipients = ReplyAddressing.recipients(for: received, replyTo: [], own: [me.address], all: false)
        XCTAssertTrue(recipients.cc.isEmpty, "Reply leaves Cc for the owner to fill")
        let envelope = try await send(try composed(to: OutgoingRecipients.box(recipients.to), cc: "dispatch@example.com",
                                                   bcc: "Ops <ops@example.com>"), via: makeOutbox())
        assertDelivered(envelope, to: ["ana@example.com"], cc: ["dispatch@example.com"], bcc: ["ops@example.com"], "Reply")
    }

    func testAScheduledSendGoesToCcAndBccWhenItsTimeComes() async throws {
        let outbox = makeOutbox()
        let message = try composed(to: "ana@example.com", cc: "bob@example.com", bcc: "cy@example.com")
        let item = try await outbox.enqueue(accountID: account.id, from: me.address, message: message, sendAt: Date().addingTimeInterval(1.5))
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertTrue(server.envelopes.isEmpty, "not before its time")
        await assertEventually(within: 6) { await outbox.snapshot().first { $0.id == item.id }?.status == .sent }
        let envelope = try XCTUnwrap(server.envelopes.last)
        assertDelivered(envelope, to: ["ana@example.com"], cc: ["bob@example.com"], bcc: ["cy@example.com"], "scheduled")
    }

    func testAMessageHeldAndSentAgainAfterARelaunchGoesToCcAndBcc() async throws {
        server.refuseNextMessage("550 5.4.5 Daily user sending limit exceeded.")
        let first = makeOutbox()
        let message = try composed(to: "ana@example.com", cc: "bob@example.com, ben@example.com", bcc: "cy@example.com")
        let item = try await first.enqueue(accountID: account.id, from: me.address, message: message, sendAt: Date())
        await assertEventually { await first.snapshot().first { $0.id == item.id }?.isHeld == true }
        XCTAssertTrue(server.envelopes.isEmpty)

        // FalconMail starts again, and the owner presses Send Again.
        let relaunched = makeOutbox()
        let found = await relaunched.snapshot().first { $0.id == item.id }
        let held = try XCTUnwrap(found)
        XCTAssertEqual(held.recipients, ["ana@example.com", "bob@example.com", "ben@example.com", "cy@example.com"])
        try await relaunched.retry(held.id)
        await assertEventually { await relaunched.snapshot().first { $0.id == item.id }?.status == .sent }
        XCTAssertEqual(server.envelopes.count, 1)
        assertDelivered(try XCTUnwrap(server.envelopes.last), to: ["ana@example.com"], cc: ["bob@example.com", "ben@example.com"],
                        bcc: ["cy@example.com"], "Send Again")
    }

    func testAMessageCalledBackFromTheOutboxKeepsItsBoxesAndGoesToThemAll() async throws {
        let outbox = makeOutbox(undoWindow: 60)
        let message = try composed(to: "Ana Lee <ana@example.com>", cc: "Bob Stone <bob@example.com>", bcc: "Cy Young <cy@example.com>")
        let item = try await outbox.enqueue(accountID: account.id, from: me.address, message: message)
        XCTAssertEqual(outbox.sentBcc.bcc(forMessageID: message.messageID).map(\.address), ["cy@example.com"])
        let cancelled = try await outbox.cancel(item.id)
        XCTAssertTrue(cancelled)

        // What the app opens again when the draft beside the item is missing: the boxes the item
        // itself keeps, read from disk as a relaunch reads them.
        let reread = try XCTUnwrap(AtomicFile.readJSON(OutboxItem.self,
                                                       from: FileLayout(root: root).outboxDirectory.appendingPathComponent("\(item.id.uuidString).json")))
        XCTAssertEqual(reread.to, [EmailAddress(name: "Ana Lee", address: "ana@example.com")])
        XCTAssertEqual(reread.cc, [EmailAddress(name: "Bob Stone", address: "bob@example.com")])
        XCTAssertEqual(reread.bcc, [EmailAddress(name: "Cy Young", address: "cy@example.com")])
        XCTAssertEqual(reread.messageID, message.messageID)
        let queued = await outbox.rawMessage(for: item.id)
        let raw = try XCTUnwrap(queued)
        XCTAssertNil(MIMEParser.parse(raw).headers.first("Bcc"), "the queued message never holds Bcc")
        await outbox.remove(item.id)
        XCTAssertTrue(outbox.sentBcc.bcc(forMessageID: message.messageID).isEmpty, "a message that never went has no Bcc to show")

        // Sent again from the boxes as reopened.
        let again = try composed(to: OutgoingRecipients.box(reread.to ?? []), cc: OutgoingRecipients.box(reread.cc ?? []),
                                 bcc: OutgoingRecipients.box(reread.bcc ?? []))
        let envelope = try await send(again, via: makeOutbox())
        assertDelivered(envelope, to: ["ana@example.com"], cc: ["bob@example.com"], bcc: ["cy@example.com"], "called back and sent")
    }

    func testARefusedCcRecipientFailsTheMessageRatherThanSendingItToToAlone() async throws {
        server.refuseRecipient("bob@example.com", reply: "550 5.1.1 The email account that you tried to reach does not exist.")
        let outbox = makeOutbox()
        let item = try await outbox.enqueue(accountID: account.id, from: me.address,
                                            message: try composed(to: "ana@example.com", cc: "bob@example.com", bcc: ""), sendAt: Date())
        await assertEventually { await outbox.snapshot().first { $0.id == item.id }?.status == .failed }
        XCTAssertTrue(server.envelopes.isEmpty, "nothing half-delivered")
        XCTAssertFalse(server.commands.contains("DATA"))
    }

    // MARK: Bcc stays hidden, and is remembered for its owner

    func testTheBccRecipientsAreWrittenDownForTheSentMessageAndReadAfterARelaunch() async throws {
        let outbox = makeOutbox()
        let message = try composed(to: "ana@example.com", cc: "bob@example.com", bcc: "Cy Young <cy@example.com>, cat@example.com")
        _ = try await send(message, via: outbox)
        let reread = SentBccStore(file: FileLayout(root: root).sentBccFile)
        // Gmail's copy in Sent Mail keeps the Message-ID, which the list reads with its brackets.
        let messageID = try XCTUnwrap(AddressParser.messageIDs(server.envelopes.last?.headers.first("Message-ID")).first)
        XCTAssertEqual(reread.bcc(forMessageID: messageID), [EmailAddress(name: "Cy Young", address: "cy@example.com"),
                                                             EmailAddress(address: "cat@example.com")])
        XCTAssertEqual(reread.bcc(forMessageID: messageID.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: "<>"))).count, 2)
        XCTAssertTrue(reread.bcc(forMessageID: "<someone-else@example.com>").isEmpty)
        let noBcc = try composed(to: "ana@example.com", cc: "", bcc: "")
        _ = try await send(noBcc, via: outbox)
        XCTAssertTrue(reread.bcc(forMessageID: noBcc.messageID).isEmpty)
    }

    func testTheBccLineShowsTheHeaderAndTheRecordEachOnce() {
        let shown = SentBccStore.shown(header: "Cy Young <cy@example.com>, dee@example.com",
                                       recorded: [EmailAddress(address: "CY@example.com"), EmailAddress(address: "eve@example.com")])
        XCTAssertEqual(shown.map(\.address), ["cy@example.com", "dee@example.com", "eve@example.com"])
        XCTAssertTrue(SentBccStore.shown(header: nil, recorded: []).isEmpty)
    }

    func testADraftSavedToDraftsKeepsItsBccButWhatIsSentNeverHasOne() throws {
        let message = try composed(to: "ana@example.com", cc: "bob@example.com", bcc: "Cy Young <cy@example.com>")
        let draft = MIMEParser.parse(MIMEBuilder.build(message, keepingBcc: true))
        XCTAssertEqual(AddressParser.parse(draft.headers.first("Bcc")), [EmailAddress(name: "Cy Young", address: "cy@example.com")],
                       "opened again from Drafts, as ComposeDraft.from reads it, Bcc is still there")
        XCTAssertEqual(draft.cc.map(\.address), ["bob@example.com"])
        XCTAssertNil(MIMEParser.parse(MIMEBuilder.build(message)).headers.first("Bcc"))
    }

    func testTheCopyInAnImapSentFolderNamesItsBccRecipients() {
        let message = OutgoingMessage(from: me, to: [EmailAddress(address: "ana@example.com")], cc: [EmailAddress(address: "bob@example.com")],
                                      bcc: [EmailAddress(address: "cy@example.com")], subject: "Rates", textBody: "Hello")
        let copy = SentCopy.addingBcc(to: MIMEBuilder.build(message), envelope: message.allRecipients)
        let parsed = MIMEParser.parse(copy)
        XCTAssertEqual(AddressParser.parse(parsed.headers.first("Bcc")).map(\.address), ["cy@example.com"])
        XCTAssertEqual(parsed.to.map(\.address), ["ana@example.com"])
        XCTAssertEqual(parsed.subject, "Rates")
        let noBcc = MIMEBuilder.build(OutgoingMessage(from: me, to: [EmailAddress(address: "ana@example.com")], subject: "Hi", textBody: "x"))
        XCTAssertEqual(SentCopy.addingBcc(to: noBcc, envelope: ["ana@example.com"]), noBcc)
    }

    // MARK: What cannot go

    func testAnEntryThatIsNoAddressIsCaughtInTheComposeWindow() {
        let named = OutgoingRecipients(to: "ana@example.com", cc: "Bob Stone", bcc: "")
        XCTAssertEqual(named.unreadable, OutgoingRecipients.Unreadable(field: .cc, text: "Bob Stone"))
        XCTAssertThrowsError(try named.checkSendable()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Bob Stone"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("Cc"), error.localizedDescription)
        }
        XCTAssertThrowsError(try OutgoingRecipients(to: " ", cc: ",", bcc: ";").checkSendable())
        XCTAssertNoThrow(try OutgoingRecipients(to: "", cc: "", bcc: "cy@example.com").checkSendable())
        XCTAssertEqual(OutgoingRecipients(to: "", cc: "", bcc: "bob@example").unreadable, nil, "a domain without a dot is the server's to judge")
    }

    func testAnAddressThatWouldBreakTheCommandIsNeverSent() async throws {
        let smtp = server.client()
        try await smtp.connect()
        do {
            try await smtp.send(from: me.address, recipients: ["ana@example.com", "bob@example.com>\r\nRCPT TO:<evil@example.com"],
                                message: Data("Subject: x\r\n\r\nx\r\n".utf8))
            XCTFail("sent")
        } catch {}
        await smtp.quit()
        XCTAssertFalse(server.commands.contains { $0.contains("evil") })
        XCTAssertFalse(server.commands.contains { $0.hasPrefix("MAIL") })
    }

    func testCopyingTheOwnerAddsThemOnceInTheBoxChosen() {
        var r = OutgoingRecipients(to: "ana@example.com", cc: "", bcc: "")
        r.copy(me, as: .bcc)
        XCTAssertEqual(r.bcc, [me])
        r.copy(me, as: .bcc)
        XCTAssertEqual(r.bcc, [me])
        var named = OutgoingRecipients(to: "ana@example.com", cc: "OWNER@example.com", bcc: "")
        named.copy(me, as: .cc)
        XCTAssertEqual(named.cc.count, 1)
    }

    // MARK: The Outbox shows everyone

    func testTheOutboxShowsEveryBoxAndReadsItemsAnEarlierBuildQueued() throws {
        var item = OutboxItem(accountID: UUID(), subject: "Rates", recipients: ["ana@example.com", "bob@example.com", "cy@example.com"],
                              sender: me.address, sendAt: Date(), undoWindow: 10)
        XCTAssertEqual(item.recipientSummary, "ana@example.com, bob@example.com, cy@example.com")
        item.to = [EmailAddress(name: "Ana Lee", address: "ana@example.com")]
        item.cc = [EmailAddress(address: "bob@example.com")]
        item.bcc = [EmailAddress(name: "Cy Young", address: "cy@example.com")]
        XCTAssertEqual(item.recipientSummary, "To: Ana Lee; Cc: bob@example.com; Bcc: Cy Young")

        // The previous release reads what this one writes, and ignores what it does not know.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let previous = try decoder.decode(ReleasedOutboxItem.self, from: try encoder.encode(item))
        XCTAssertEqual(previous.recipients, item.recipients)
    }

    // MARK: Helpers

    /// The compose window's reading of its boxes, as ComposeDraft.outgoing reads them.
    private func composed(to: String, cc: String, bcc: String) throws -> OutgoingMessage {
        let r = OutgoingRecipients(to: to, cc: cc, bcc: bcc)
        try r.checkSendable()
        return OutgoingMessage(from: me, to: r.to, cc: r.cc, bcc: r.bcc, subject: "Rates", textBody: "Hello, see below.\n.\nThanks")
    }

    /// An Outbox whose sender is the app's, SMTPSender, delivering over SMTPSender.deliver to the
    /// server on loopback with made-up credentials.
    private func makeOutbox(undoWindow: TimeInterval = 0) -> Outbox {
        let server = self.server!
        let sender = SMTPSender(store: store, syncer: { _ in nil }) { account, from, recipients, message in
            try await SMTPSender.deliver(message, from: from, to: recipients, account: account, over: server.client(),
                                         password: { "not-a-password" }, accessToken: { "not-a-token" })
        }
        return Outbox(layout: FileLayout(root: root), sender: sender, undoWindow: undoWindow)
    }

    private func send(_ message: OutgoingMessage, via outbox: Outbox) async throws -> FakeSMTPServer.Envelope {
        let before = server.envelopes.count
        let item = try await outbox.enqueue(accountID: account.id, from: me.address, message: message, sendAt: Date())
        await assertEventually { await outbox.snapshot().first { $0.id == item.id }?.status == .sent }
        let sent = await outbox.snapshot().first { $0.id == item.id }
        XCTAssertEqual(sent?.status, .sent, sent?.error ?? "")
        let envelopes = server.envelopes
        XCTAssertEqual(envelopes.count, before + 1)
        return try XCTUnwrap(envelopes.last)
    }

    private func assertDelivered(_ e: FakeSMTPServer.Envelope, to: [String], cc: [String], bcc: [String], _ what: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(e.mailFrom, me.address, what, file: file, line: line)
        XCTAssertEqual(e.auth, "XOAUTH2", what, file: file, line: line)
        XCTAssertEqual(e.rcptTo, to + cc + bcc, "\(what): a RCPT TO for every address, in order", file: file, line: line)
        let headers = e.headers
        XCTAssertEqual(AddressParser.parse(headers.first("To")).map(\.address), to, "\(what): To header", file: file, line: line)
        XCTAssertEqual(AddressParser.parse(headers.first("Cc")).map(\.address), cc, "\(what): Cc header", file: file, line: line)
        XCTAssertNil(headers.first("Bcc"), "\(what): no Bcc header", file: file, line: line)
        for hidden in bcc {
            XCTAssertFalse(e.text.lowercased().contains(hidden.lowercased()), "\(what): \(hidden) is nowhere in what was sent",
                           file: file, line: line)
        }
        XCTAssertTrue(e.text.contains("Hello, see below."), what, file: file, line: line)
    }
}

/// OutboxItem as v1.10.4 declares it.
private struct ReleasedOutboxItem: Codable {
    enum Status: String, Codable { case queued, sending, sent, failed, cancelled }
    var id: UUID
    var accountID: UUID
    var subject: String
    var recipients: [String]
    var sender: String
    var sendAt: Date
    var createdAt: Date
    var status: Status
    var error: String?
    var undoUntil: Date
    var attempts: Int?
    var heldBack: Bool?
    var sendBegan: Bool?
}
