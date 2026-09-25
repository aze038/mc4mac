import XCTest
@testable import FalconCore

/// Sending a switched Google account's mail with Gmail's own send, and never twice: Gmail's
/// records only ever confirm a send, and a send they cannot confirm waits for the owner.
final class GmailSendTests: XCTestCase {
    private var root: URL!
    private let owner = "owner@example.com"

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("falcon-gmail-send-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Log.start(in: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private struct Rig {
        let mailbox: MemoryGmailTransport
        let transport: ScriptedGmailTransport
        let store: MemoryGmailStore
        let sender: GmailSender
        let outbox: Outbox
        let layout: FileLayout
    }

    private func rig(layout: FileLayout? = nil, mailbox: MemoryGmailTransport? = nil, transport: ScriptedGmailTransport? = nil,
                     placer: (any GmailUploadPlacing)? = nil, deleteDraft: (@Sendable (String) async throws -> Void)? = nil,
                     confirmAfter: [TimeInterval] = [0.05, 0.15]) -> Rig {
        let mailbox = mailbox ?? transport?.mailbox ?? MemoryGmailTransport(email: owner)
        let transport = transport ?? ScriptedGmailTransport(mailbox)
        let store = MemoryGmailStore(accountID: mailbox.accountID)
        let sender = GmailSender(accountID: mailbox.accountID, email: owner, transport: transport,
                                 placer: placer ?? GmailStorePlacer(store: store), deleteDraft: deleteDraft, cursor: { mailbox.historyID })
        let layout = layout ?? FileLayout(root: root)
        let outbox = Outbox(layout: layout, sender: sender, undoWindow: 0, confirmAfter: confirmAfter, retryDelay: { _ in 0 })
        return Rig(mailbox: mailbox, transport: transport, store: store, sender: sender, outbox: outbox, layout: layout)
    }

    static func message(to: [String] = ["ana@example.com"], cc: [String] = [], bcc: [String] = [], subject: String = "Rates for October",
                        text: String = "Please find the rates below.", attachments: [OutgoingAttachment] = [],
                        inReplyTo: String? = nil) -> OutgoingMessage {
        OutgoingMessage(from: EmailAddress(name: "Owner", address: "owner@example.com"), to: to.map { EmailAddress(address: $0) },
                        cc: cc.map { EmailAddress(address: $0) }, bcc: bcc.map { EmailAddress(address: $0) }, subject: subject,
                        textBody: text, attachments: attachments, inReplyTo: inReplyTo, references: inReplyTo.map { [$0] } ?? [])
    }

    private func item(_ outbox: Outbox) async -> OutboxItem? { await outbox.snapshot().first }

    private func sentMessages(_ mailbox: MemoryGmailTransport) -> [MemoryGmailTransport.Message] {
        mailbox.messages.filter { $0.labels.contains(.sent) }
    }

    private func itemFile(_ layout: FileLayout, _ id: UUID) -> URL {
        layout.outboxDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: - Sending

    func testAMessageGoesThroughGmailWithItsAttemptAndBccOnlyInTheUpload() async throws {
        let r = rig()
        let queued = try await r.outbox.enqueue(accountID: r.mailbox.accountID, from: owner,
                                                message: Self.message(bcc: ["hidden@example.com"]), sendAt: Date())
        await assertEventually { await self.item(r.outbox)?.status == .sent }
        let latest = await item(r.outbox)
        let sent = try XCTUnwrap(latest)
        let attempt = try XCTUnwrap(sent.attemptID)
        XCTAssertNotNil(sent.preSendHistoryID)
        let eml = await r.outbox.rawMessage(for: queued.id)
        XCTAssertEqual(sent.messageID, Self.messageID(of: try XCTUnwrap(eml)))

        let onMac = String(decoding: try XCTUnwrap(eml), as: UTF8.self)
        XCTAssertFalse(onMac.contains("Bcc:"), "the .eml stays as MIMEBuilder built it")
        XCTAssertFalse(onMac.contains(GmailSender.attemptHeader))
        let upload = String(decoding: try XCTUnwrap(r.transport.uploads(.messagesSend).first), as: UTF8.self)
        XCTAssertTrue(upload.contains("Bcc: hidden@example.com\r\n"), upload)
        XCTAssertTrue(upload.contains("\(GmailSender.attemptHeader): \(attempt.uuidString.lowercased())\r\n"), upload)
        XCTAssertEqual(upload.components(separatedBy: "Message-ID:").count, 2, "one Message-ID")
        XCTAssertTrue(upload.hasSuffix(onMac), "the message itself is byte for byte the .eml")

        let gmailCopy = try XCTUnwrap(sentMessages(r.mailbox).first)
        XCTAssertEqual(sent.gmailSentID, gmailCopy.ref.id)
        XCTAssertEqual(sentMessages(r.mailbox).count, 1)
        XCTAssertEqual(r.mailbox.units[.messagesSend], 100)
        XCTAssertNil(r.mailbox.calls[.messagesInsert], "Gmail's own send, not an insert")
    }

    func testTheSentRowIsInTheIndexBeforeTheOutboxMarksItSent() async throws {
        let mailbox = MemoryGmailTransport(email: owner)
        let store = MemoryGmailStore(accountID: mailbox.accountID)
        let watching = WatchingPlacer(GmailStorePlacer(store: store))
        let r = rig(mailbox: mailbox, placer: watching)
        watching.outbox = r.outbox
        _ = try await r.outbox.enqueue(accountID: mailbox.accountID, from: owner, message: Self.message(), sendAt: Date())
        await assertEventually { await self.item(r.outbox)?.status == .sent }
        XCTAssertEqual(watching.statusesSeen, [.sending], "placed while the Outbox still shows it going out")

        let sentID = await item(r.outbox)?.gmailSentID
        let id = try XCTUnwrap(sentID)
        let found = await store.record(for: id)
        let record = try XCTUnwrap(found)
        XCTAssertTrue(record.hasSystemLabel(.sent))
        XCTAssertFalse(record.hasSystemLabel(.unread))
        let index = await store.index()
        XCTAssertEqual(index.byOrder.last.map { index.records[Int($0)].id }, id.raw, "at the top of the order")
        let kept = await store.cachedMessages([id])[id]
        let cached = try XCTUnwrap(kept)
        XCTAssertEqual(cached.subject, "Rates for October")
        XCTAssertEqual(cached.to.map(\.address), ["ana@example.com"])
        let body = try await store.body(of: id)
        XCTAssertEqual(body?.textPlain?.trimmed, "Please find the rates below.")
        XCTAssertEqual(mailbox.units[.messagesGet], 20, "one metadata call for Gmail's Message-ID, and nothing more")
    }

    func testTheSentRowIsThereWhenSendReturns() async throws {
        let mailbox = MemoryGmailTransport(email: owner)
        mailbox.replacesMessageIDOnSend = true
        let store = MemoryGmailStore(accountID: mailbox.accountID)
        let sender = GmailSender(accountID: mailbox.accountID, email: owner, transport: mailbox, placer: GmailStorePlacer(store: store))
        let raw = MIMEBuilder.build(Self.message())
        var item = OutboxItem(accountID: mailbox.accountID, subject: "Rates", recipients: ["ana@example.com"], sender: owner,
                              sendAt: Date(), undoWindow: 0)
        item = await sender.prepare(item, message: raw)
        let sent = try await sender.send(item, message: raw)
        let id = try XCTUnwrap(sent.gmailSentID)
        let found = await store.record(for: id)
        XCTAssertNotNil(found)
        let kept = await store.cachedMessages([id])[id]
        let cached = try XCTUnwrap(kept)
        let gmails = try XCTUnwrap(mailbox.message(id)?.headers.first { $0.name == "Message-ID" }?.value)
        XCTAssertEqual("<\(cached.messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<>")))>", gmails,
                       "the kept copy carries Gmail's Message-ID, so replies to it thread")
    }

    func testAReplyGoesIntoItsConversation() async throws {
        let r = rig()
        let original = r.mailbox.add(subject: "Rates for October", messageID: "<rates@example.com>")
        _ = try await r.outbox.enqueue(accountID: r.mailbox.accountID, from: owner,
                                       message: Self.message(subject: "Re: Rates for October", inReplyTo: "<rates@example.com>"),
                                       sendAt: Date(), gmailThreadID: original.threadID)
        await assertEventually { await self.item(r.outbox)?.status == .sent }
        XCTAssertEqual(sentMessages(r.mailbox).first?.ref.threadID, original.threadID)
    }

    func testAReplyWhoseConversationIsGoneStillGoesOnce() async throws {
        let r = rig()
        r.mailbox.fail(.messagesSend, with: MemoryGmailTransport.notFound)
        _ = try await r.outbox.enqueue(accountID: r.mailbox.accountID, from: owner, message: Self.message(subject: "Re: Rates"),
                                       sendAt: Date(), gmailThreadID: GmailThreadID(raw: 0x1234))
        await assertEventually { await self.item(r.outbox)?.status == .sent }
        XCTAssertEqual(sentMessages(r.mailbox).count, 1)
        XCTAssertEqual(r.mailbox.attempts[.messagesSend], 2, "refused once for its conversation, then sent on its own")
    }

    func testAFailureBeforeTheUploadIsTriedAgainByItself() async throws {
        let r = rig()
        r.mailbox.fail(.messagesSend, with: GoogleAPIError(kind: .offline, detail: "URLError -1009"))
        _ = try await r.outbox.enqueue(accountID: r.mailbox.accountID, from: owner, message: Self.message(), sendAt: Date())
        await assertEventually { await self.item(r.outbox)?.status == .sent }
        XCTAssertEqual(sentMessages(r.mailbox).count, 1)
        XCTAssertEqual(r.mailbox.attempts[.messagesSend], 2)
        let attempts = await item(r.outbox)?.attempts
        XCTAssertEqual(attempts, 1)
    }

    func testASendWhoseConnectionDroppedAfterGmailTookItIsFoundBeforeItWouldGoAgain() async throws {
        let r = rig()
        // A transport that took a dropped connection mid-upload for being offline.
        r.transport.failAfterAccepting(.messagesSend, with: GoogleAPIError(kind: .offline, detail: "URLError -1005"))
        _ = try await r.outbox.enqueue(accountID: r.mailbox.accountID, from: owner, message: Self.message(), sendAt: Date())
        await assertEventually { await self.item(r.outbox)?.status == .sent }
        XCTAssertEqual(sentMessages(r.mailbox).count, 1, "found in the history, not sent a second time")
        XCTAssertEqual(r.mailbox.attempts[.messagesSend], 1)
        let sentID = await item(r.outbox)?.gmailSentID
        XCTAssertEqual(sentID, sentMessages(r.mailbox).first?.ref.id)
    }

    func testSendingAHeldMessageAgainLooksForItFirst() async throws {
        let r = rig(confirmAfter: [0.05, 0.1])
        // Held: Gmail's records showed nothing within both looks...
        r.transport.failAfterAccepting(.messagesSend, with: GoogleAPIError(kind: .temporary, detail: "URLError -1001"))
        r.transport.hold(.historyList)
        _ = try await r.outbox.enqueue(accountID: r.mailbox.accountID, from: owner, message: Self.message(), sendAt: Date())
        r.transport.refuse(.historyList, with: GoogleAPIError(kind: .offline, detail: "URLError -1009"))
        r.transport.release(.historyList)
        await assertEventually { await self.item(r.outbox)?.isHeld == true }
        XCTAssertEqual(sentMessages(r.mailbox).count, 1, "though Gmail had taken it")

        // ...and when the owner sends it again, the look finds it and nothing more goes.
        r.transport.refuse(.historyList, with: nil)
        let latest = await item(r.outbox)
        let held = try XCTUnwrap(latest)
        try await r.outbox.retry(held.id)
        await assertEventually { await self.item(r.outbox)?.status == .sent }
        XCTAssertEqual(sentMessages(r.mailbox).count, 1)
        XCTAssertEqual(r.mailbox.attempts[.messagesSend], 1)
    }

    // MARK: - Unclear outcomes

    func testATimeoutAfterGmailTookTheMessageIsFoundInTheHistoryAndMarkedSent() async throws {
        let r = rig()
        r.transport.failAfterAccepting(.messagesSend, with: GoogleAPIError(kind: .temporary, detail: "URLError -1001"))
        _ = try await r.outbox.enqueue(accountID: r.mailbox.accountID, from: owner, message: Self.message(), sendAt: Date())
        await assertEventually { await self.item(r.outbox)?.status == .sent }
        let latest = await item(r.outbox)
        let sent = try XCTUnwrap(latest)
        XCTAssertEqual(sentMessages(r.mailbox).count, 1, "never sent a second time")
        XCTAssertEqual(r.mailbox.attempts[.messagesSend], 1)
        XCTAssertEqual(sent.gmailSentID, sentMessages(r.mailbox).first?.ref.id)
        XCTAssertNil(sent.error)
        XCTAssertNotNil(r.mailbox.calls[.historyList])
    }

    func testASendGmailGaveItsOwnMessageIDIsFoundByTheAttemptHeader() async throws {
        let r = rig()
        r.transport.dropsOriginalMessageID = true
        r.transport.failAfterAccepting(.messagesSend, with: GoogleAPIError(kind: .temporary, httpStatus: 503, detail: "backendError"))
        let queued = try await r.outbox.enqueue(accountID: r.mailbox.accountID, from: owner, message: Self.message(), sendAt: Date())
        await assertEventually { await self.item(r.outbox)?.status == .sent }
        let gmailCopy = try XCTUnwrap(sentMessages(r.mailbox).first)
        let eml = await r.outbox.rawMessage(for: queued.id)
        let ours = Self.messageID(of: try XCTUnwrap(eml))
        XCTAssertNotEqual(gmailCopy.headers.first { $0.name == "Message-ID" }?.value, ours, "Gmail replaced it")
        XCTAssertEqual(sentMessages(r.mailbox).count, 1)
        let sentID = await item(r.outbox)?.gmailSentID
        XCTAssertEqual(sentID, gmailCopy.ref.id)
    }

    func testASendFoundByItsMessageIDWhenTheHistoryHasGone() async throws {
        let r = rig(confirmAfter: [0.4, 0.8])
        r.transport.failAfterAccepting(.messagesSend, with: GoogleAPIError(kind: .temporary, detail: "URLError -1005"))
        _ = try await r.outbox.enqueue(accountID: r.mailbox.accountID, from: owner, message: Self.message(), sendAt: Date())
        await assertEventually { self.sentMessages(r.mailbox).count == 1 }
        r.mailbox.expireHistory()
        await assertEventually { await self.item(r.outbox)?.status == .sent }
        XCTAssertEqual(sentMessages(r.mailbox).count, 1)
        XCTAssertNotNil(r.mailbox.calls[.messagesList], "Sent searched by rfc822msgid")
    }

    func testAnUnclearSendGmailHasNoRecordOfIsHeldAndNeverSentAgainByItself() async throws {
        let r = rig()
        r.mailbox.fail(.messagesSend, with: GoogleAPIError(kind: .temporary, httpStatus: 500, detail: "backendError"))
        _ = try await r.outbox.enqueue(accountID: r.mailbox.accountID, from: owner, message: Self.message(), sendAt: Date())
        let sending = await item(r.outbox)?.status
        XCTAssertTrue(sending == .queued || sending == .sending)
        await assertEventually { await self.item(r.outbox)?.isHeld == true }
        let latest = await item(r.outbox)
        let held = try XCTUnwrap(latest)
        XCTAssertEqual(held.error, Outbox.interruptedText)
        XCTAssertEqual(r.mailbox.calls[.historyList], 2, "looked twice")
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(r.mailbox.attempts[.messagesSend], 1, "never sent again by itself")
        XCTAssertTrue(sentMessages(r.mailbox).isEmpty)

        try await r.outbox.retry(held.id)
        await assertEventually { await self.item(r.outbox)?.status == .sent }
        XCTAssertEqual(sentMessages(r.mailbox).count, 1)
        let attempt = await item(r.outbox)?.attemptID
        XCTAssertNotEqual(attempt, held.attemptID, "each attempt has its own name")
    }

    func testAnUnclearSendIsHeldOnDiskWhileItIsLookedFor() async throws {
        let r = rig(confirmAfter: [5, 10])
        r.transport.failAfterAccepting(.messagesSend, with: GoogleAPIError(kind: .temporary, detail: "URLError -1001"))
        let queued = try await r.outbox.enqueue(accountID: r.mailbox.accountID, from: owner, message: Self.message(), sendAt: Date())
        await assertEventually { self.sentMessages(r.mailbox).count == 1 }
        try await Task.sleep(nanoseconds: 100_000_000)
        let status = await item(r.outbox)?.status
        XCTAssertEqual(status, .sending)
        let onDisk = try XCTUnwrap(AtomicFile.readJSON(OutboxItem.self, from: itemFile(r.layout, queued.id)))
        XCTAssertEqual(onDisk.sendBegan, true)
        XCTAssertTrue(onDisk.isHeld, "a quit now finds it held, never queued")
    }

    func testACrashMidSendIsNeverSentAgainWithoutTheOwner() async throws {
        let mailbox = MemoryGmailTransport(email: owner)
        let crashing = ScriptedGmailTransport(mailbox)
        let gate = crashing.hold(.messagesSend)
        let before = rig(layout: FileLayout(root: root.appendingPathComponent("before")), transport: crashing)
        let queued = try await before.outbox.enqueue(accountID: mailbox.accountID, from: owner, message: Self.message(), sendAt: Date())
        await assertEventually { gate.arrivals == 1 }

        // What a crash at this moment leaves on disk.
        let onDisk = try XCTUnwrap(AtomicFile.readJSON(OutboxItem.self, from: itemFile(before.layout, queued.id)))
        XCTAssertEqual(onDisk.sendBegan, true)
        XCTAssertTrue(onDisk.isHeld)
        XCTAssertNotNil(onDisk.attemptID)
        XCTAssertNotNil(onDisk.preSendHistoryID)
        let after = FileLayout(root: root.appendingPathComponent("after"))
        try FileManager.default.createDirectory(at: after.root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: before.layout.outboxDirectory, to: after.outboxDirectory)

        let relaunched = rig(layout: after, transport: ScriptedGmailTransport(mailbox))
        await assertEventually { await self.item(relaunched.outbox)?.isHeld == true }
        let heldError = await item(relaunched.outbox)?.error
        XCTAssertEqual(heldError, Outbox.interruptedText)
        XCTAssertNil(mailbox.attempts[.messagesSend], "Gmail never had it, and it is not sent by itself")
        XCTAssertNotNil(mailbox.calls[.historyList], "looked for in Gmail's records first")

        let latest = await item(relaunched.outbox)
        let held = try XCTUnwrap(latest)
        try await relaunched.outbox.retry(held.id)
        await assertEventually { await self.item(relaunched.outbox)?.status == .sent }
        XCTAssertEqual(sentMessages(mailbox).count, 1)

        // The run that "crashed" is let go without reaching Gmail.
        crashing.refuse(.messagesSend, with: GoogleAPIError(kind: .other, httpStatus: 400, detail: "gone"))
        gate.open()
    }

    func testACrashAfterGmailTookTheMessageIsFoundAtLaunchAndMarkedSent() async throws {
        let mailbox = MemoryGmailTransport(email: owner)
        let crashing = ScriptedGmailTransport(mailbox)
        let late = crashing.holdAfterAccepting(.messagesSend)
        let before = rig(layout: FileLayout(root: root.appendingPathComponent("before")), transport: crashing)
        let queued = try await before.outbox.enqueue(accountID: mailbox.accountID, from: owner, message: Self.message(), sendAt: Date())
        await assertEventually { late.arrivals == 1 }
        XCTAssertEqual(sentMessages(mailbox).count, 1)
        let after = FileLayout(root: root.appendingPathComponent("after"))
        try FileManager.default.createDirectory(at: after.root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: before.layout.outboxDirectory, to: after.outboxDirectory)

        let relaunched = rig(layout: after, transport: ScriptedGmailTransport(mailbox))
        await assertEventually { await self.item(relaunched.outbox)?.status == .sent }
        XCTAssertEqual(sentMessages(mailbox).count, 1, "found in the history, not sent again")
        XCTAssertEqual(mailbox.attempts[.messagesSend], 1)
        let sentID = await item(relaunched.outbox)?.gmailSentID
        XCTAssertEqual(sentID, sentMessages(mailbox).first?.ref.id)
        let stored = AtomicFile.readJSON(OutboxItem.self, from: itemFile(after, queued.id))
        XCTAssertEqual(stored?.status, .sent)
        XCTAssertNil(stored?.sendBegan)
        late.open()
    }

    // MARK: - Refusals

    func testASendingLimitWaitsUntilItsTimeWithItsSentence() async throws {
        let r = rig()
        r.mailbox.fail(.messagesSend, with: GoogleAPIError(kind: .sendingLimit, httpStatus: 429, retryAfter: 3_600))
        _ = try await r.outbox.enqueue(accountID: r.mailbox.accountID, from: owner, message: Self.message(), sendAt: Date())
        await assertEventually { await self.item(r.outbox)?.error != nil }
        let latest = await item(r.outbox)
        let waiting = try XCTUnwrap(latest)
        XCTAssertEqual(waiting.status, .queued)
        XCTAssertEqual(waiting.sendAt.timeIntervalSinceNow, 3_600, accuracy: 30)
        XCTAssertEqual(waiting.error, "Gmail's daily sending limit for owner@example.com was reached. The message stays in the Outbox.")
        XCTAssertTrue(sentMessages(r.mailbox).isEmpty)
    }

    func testASendingLimitWithNoTimeIsHeldForTheOwner() async throws {
        let r = rig()
        r.mailbox.fail(.messagesSend, with: GoogleAPIError(kind: .sendingLimit, httpStatus: 429))
        _ = try await r.outbox.enqueue(accountID: r.mailbox.accountID, from: owner, message: Self.message(), sendAt: Date())
        await assertEventually { await self.item(r.outbox)?.isHeld == true }
        let heldError = await item(r.outbox)?.error
        XCTAssertEqual(heldError, "Gmail's daily sending limit for owner@example.com was reached. The message stays in the Outbox.")
    }

    func testAnUploadRefusalWaitsWithItsOwnSentence() async throws {
        let r = rig()
        r.mailbox.fail(.messagesSend, with: GoogleAPIError(kind: .uploadLimit, httpStatus: 429, retryAfter: 7_200))
        _ = try await r.outbox.enqueue(accountID: r.mailbox.accountID, from: owner, message: Self.message(), sendAt: Date())
        await assertEventually { await self.item(r.outbox)?.error != nil }
        let latest = await item(r.outbox)
        let waiting = try XCTUnwrap(latest)
        XCTAssertEqual(waiting.status, .queued)
        XCTAssertEqual(waiting.sendAt.timeIntervalSinceNow, 7_200, accuracy: 30)
        let sentence = try XCTUnwrap(waiting.error)
        XCTAssertTrue(sentence.hasPrefix("Gmail has paused uploads for owner@example.com until "), sentence)
        XCTAssertTrue(sentence.hasSuffix("; an import may be using the allowance. The message stays in the Outbox."), sentence)
    }

    func testARefusedAddressFailsWithItsName() async throws {
        let r = rig()
        r.mailbox.fail(.messagesSend, with: GoogleAPIError(kind: .other, httpStatus: 400, reason: "invalidargument", detail: "Invalid To header"))
        _ = try await r.outbox.enqueue(accountID: r.mailbox.accountID, from: owner,
                                       message: Self.message(to: ["ana@example.com", "bob@example"]), sendAt: Date())
        await assertEventually { await self.item(r.outbox)?.status == .failed }
        let failed = await item(r.outbox)
        XCTAssertEqual(failed?.error, "Gmail refused the address bob@example.")
        XCTAssertFalse(failed?.isHeld ?? true)
    }

    func testAMessageTooLargeForGmailIsRefusedBeforeAnythingIsUploaded() async throws {
        let r = rig()
        let big = OutgoingAttachment(filename: "scan.pdf", mimeType: "application/pdf", data: Data(count: 26 * 1024 * 1024))
        _ = try await r.outbox.enqueue(accountID: r.mailbox.accountID, from: owner, message: Self.message(attachments: [big]), sendAt: Date())
        await assertEventually(within: 15) { await self.item(r.outbox)?.status == .failed }
        let refusedError = await item(r.outbox)?.error
        XCTAssertEqual(refusedError, GmailSender.tooLargeSentence)
        XCTAssertNil(r.mailbox.attempts[.messagesSend])
    }

    // MARK: - Diagnostics

    func testGmailSendFailuresReachDiagnosticsNamedByTheirKindAndRedacted() async throws {
        let directory = DiagnosticsFixtures.temporaryDirectory("gmail-send-diag")
        FakeDiagnosticsServer.reset()
        let center = DiagnosticsCenter(directory: directory, gate: DiagnosticsFixtures.gate(), environment: DiagnosticsFixtures.environment(),
                                       crashReportsDirectory: nil, session: FakeDiagnosticsServer.session(), clock: ManualClock(),
                                       random: { 0.5 })
        center.start()
        defer {
            center.stop()
            Log.observer = nil
            FakeDiagnosticsServer.reset()
            try? FileManager.default.removeItem(at: directory)
        }
        let limited = rig(layout: FileLayout(root: root.appendingPathComponent("limited")))
        limited.mailbox.fail(.messagesSend, with: GoogleAPIError(kind: .sendingLimit, httpStatus: 429, reason: "ratelimitexceeded",
                                                                  detail: "User-rate limit exceeded (Mail sending) for owner@example.com"))
        _ = try await limited.outbox.enqueue(accountID: limited.mailbox.accountID, from: owner, message: Self.message(subject: "Board minutes"),
                                             sendAt: Date())
        await assertEventually { await self.item(limited.outbox)?.isHeld == true }

        let unclear = rig(layout: FileLayout(root: root.appendingPathComponent("unclear")))
        unclear.mailbox.fail(.messagesSend, with: GoogleAPIError(kind: .temporary, httpStatus: 502, detail: "Bad Gateway"))
        _ = try await unclear.outbox.enqueue(accountID: unclear.mailbox.accountID, from: owner, message: Self.message(), sendAt: Date())
        await assertEventually { await self.item(unclear.outbox)?.isHeld == true }

        center.waitUntilIdle()
        let events = center.pendingRecords.map(\.event)
        let held = try XCTUnwrap(events.first { $0.signature.hasPrefix("Send.sendingLimit@") })
        XCTAssertEqual(held.kind, .error)
        XCTAssertEqual(held.signature, "Send.sendingLimit@Outbox.swift:apply")
        XCTAssertEqual(held.title, "Sending a message failed: the daily sending limit was reached")
        XCTAssertEqual(held.context["outcome"], .string("held"))
        let looking = try XCTUnwrap(events.first { $0.signature.hasPrefix("Send.temporary@") })
        XCTAssertEqual(looking.kind, .warning, "unclear, and looked for rather than failed")
        XCTAssertEqual(looking.context["outcome"], .string("confirming"))
        let notFound = try XCTUnwrap(events.first { $0.area == "Outbox" })
        XCTAssertEqual(notFound.signature, "Outbox.interrupted@Outbox.swift:confirm")
        for event in events where event.area == "Send" || event.area == "Outbox" {
            XCTAssertFalse(event.message.contains("@example.com"), event.message)
            XCTAssertFalse(event.message.contains("Board minutes"), "the subject never goes")
        }
    }

    // MARK: - Routing

    func testSwitchedGoogleAccountsSendThroughGmailAndOthersBySMTP() async throws {
        let mailbox = MemoryGmailTransport(email: owner)
        let gmail = GmailSender(accountID: mailbox.accountID, email: owner, transport: mailbox)
        let smtp = CountingSender()
        let other = UUID()
        let routing = RoutingSender(smtp: smtp) { id in id == mailbox.accountID ? .gmail(gmail) : .smtp }
        let outbox = Outbox(layout: FileLayout(root: root), sender: routing, undoWindow: 0, confirmAfter: [0.05], retryDelay: { _ in 0 })
        _ = try await outbox.enqueue(accountID: mailbox.accountID, from: owner, message: Self.message(), sendAt: Date())
        _ = try await outbox.enqueue(accountID: other, from: "kamran@freight.example", message: Self.message(), sendAt: Date())
        await assertEventually { await outbox.snapshot().allSatisfy { $0.status == .sent } }
        XCTAssertEqual(sentMessages(mailbox).count, 1)
        XCTAssertEqual(smtp.accounts, [other], "only the other account went by SMTP")
        let items = await outbox.snapshot()
        XCTAssertNotNil(items.first { $0.accountID == mailbox.accountID }?.attemptID)
        XCTAssertNil(items.first { $0.accountID == other }?.attemptID, "SMTP's items carry nothing of Gmail's")
    }

    func testASwitchedAccountWhoseEngineIsNotRunningNeverFallsBackToSMTP() async throws {
        let smtp = CountingSender()
        let google = UUID()
        let routing = RoutingSender(smtp: smtp) { id in id == google ? .gmailUnavailable : .smtp }
        let outbox = Outbox(layout: FileLayout(root: root), sender: routing, undoWindow: 0, retryDelay: { _ in 3_600 })
        _ = try await outbox.enqueue(accountID: google, from: owner, message: Self.message(), sendAt: Date())
        await assertEventually { await outbox.snapshot().first?.error != nil }
        let latest = await outbox.snapshot().first
        let waiting = try XCTUnwrap(latest)
        XCTAssertEqual(waiting.status, .queued)
        XCTAssertEqual(waiting.error, RoutingSender.notReady.sentence)
        XCTAssertTrue(smtp.accounts.isEmpty)
    }

    // MARK: - The Outbox's files

    func testSentItemsGoAWeekLaterOnlyOnceGmailsIdIsKnown() async throws {
        let layout = FileLayout(root: root)
        try FileManager.default.createDirectory(at: layout.outboxDirectory, withIntermediateDirectories: true)
        func stored(_ subject: String, daysAgo: Double, gmailID: GmailMessageID?, draft: String? = nil) throws -> UUID {
            var item = OutboxItem(accountID: UUID(), subject: subject, recipients: ["ana@example.com"], sender: owner,
                                  sendAt: Date().addingTimeInterval(-daysAgo * 86_400), undoWindow: 0)
            item.status = .sent
            item.gmailSentID = gmailID
            item.gmailDraftID = draft
            try AtomicFile.writeJSON(item, to: itemFile(layout, item.id))
            return item.id
        }
        let old = try stored("Old", daysAgo: 8, gmailID: GmailMessageID(raw: 0x19a1))
        let bySMTP = try stored("By SMTP", daysAgo: 8, gmailID: nil)
        let recent = try stored("Recent", daysAgo: 2, gmailID: GmailMessageID(raw: 0x19a2))
        let outbox = Outbox(layout: layout, sender: CountingSender(), undoWindow: 0)
        await outbox.startPump()
        await assertEventually { await outbox.snapshot().count == 2 }
        let left = Set(await outbox.snapshot().map(\.id))
        XCTAssertEqual(left, [bySMTP, recent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: itemFile(layout, old).path))
    }

    func testAnItemWithGmailsFieldsStillLoadsInThePreviousRelease() throws {
        var item = OutboxItem(accountID: UUID(), subject: "Rates", recipients: ["ana@example.com"], sender: owner, sendAt: Date(), undoWindow: 0)
        item.attemptID = UUID()
        item.messageID = "<a@b>"
        item.preSendHistoryID = HistoryID(raw: 5_123)
        item.gmailSentID = GmailMessageID(raw: 0x19a0_0000_0000_0010)
        item.gmailDraftID = "r7"
        item.gmailThreadID = GmailThreadID(raw: 0x19a0_0000_0000_0010)
        let url = root.appendingPathComponent("item.json")
        try AtomicFile.writeJSON(item, to: url)
        let previous = try XCTUnwrap(AtomicFile.readJSON(PreviousReleaseItem.self, from: url))
        XCTAssertEqual(previous.id, item.id)
        let back = try XCTUnwrap(AtomicFile.readJSON(OutboxItem.self, from: url))
        XCTAssertEqual(back.attemptID, item.attemptID)
        XCTAssertEqual(back.messageID, item.messageID)
        XCTAssertEqual(back.preSendHistoryID, item.preSendHistoryID)
        XCTAssertEqual(back.gmailSentID, item.gmailSentID)
        XCTAssertEqual(back.gmailDraftID, item.gmailDraftID)
        XCTAssertEqual(back.gmailThreadID, item.gmailThreadID)

        let fixture = """
            {"accountID":"\(UUID().uuidString)","createdAt":"2026-09-20T10:00:00Z","id":"\(UUID().uuidString)","recipients":["ana@example.com"],\
            "sendAt":"2026-09-20T10:05:00Z","sender":"owner@example.com","status":"queued","subject":"Rates","undoUntil":"2026-09-20T10:00:10Z"}
            """
        try Data(fixture.utf8).write(to: url)
        let old = try XCTUnwrap(AtomicFile.readJSON(OutboxItem.self, from: url))
        XCTAssertNil(old.attemptID)
        XCTAssertNil(old.gmailSentID)
    }

    static func messageID(of raw: Data) -> String? {
        MIMEParser.parseHeaders(raw).first("Message-ID")
    }
}

/// Watches the Outbox at the moment a sent message is placed.
final class WatchingPlacer: GmailUploadPlacing, @unchecked Sendable {
    private let inner: GmailStorePlacer
    private let lock = NSLock()
    private var _outbox: Outbox?
    private var _statuses: [OutboxItem.Status] = []

    init(_ inner: GmailStorePlacer) {
        self.inner = inner
    }

    var outbox: Outbox? {
        get { lock.withLock { _outbox } }
        set { lock.withLock { _outbox = newValue } }
    }

    var statusesSeen: [OutboxItem.Status] { lock.withLock { _statuses } }

    func placeUploaded(_ message: GmailMessage, labels: Set<GmailLabelID>, raw: Data, replacing previous: GmailMessageID?,
                       messageID: String?) async {
        if messageID == nil, let status = await outbox?.snapshot().first?.status {
            lock.withLock { _statuses.append(status) }
        }
        await inner.placeUploaded(message, labels: labels, raw: raw, replacing: previous, messageID: messageID)
    }

    func placeImported(_ message: GmailMessage, labels: Set<GmailLabelID>, date: Date, above neighbour: GmailMessageID?) async {
        await inner.placeImported(message, labels: labels, date: date, above: neighbour)
    }

    func forget(_ ids: [GmailMessageID]) async { await inner.forget(ids) }
    func importEnded() async { await inner.importEnded() }
}

/// An SMTP sender that only counts.
final class CountingSender: MessageSender, @unchecked Sendable {
    private let lock = NSLock()
    private var _accounts: [UUID] = []

    var accounts: [UUID] { lock.withLock { _accounts } }

    func send(accountID: UUID, from: String, recipients: [String], message: Data) async throws {
        lock.withLock { _accounts.append(accountID) }
    }
}

/// OutboxItem as v1.10.0 declares it.
private struct PreviousReleaseItem: Codable {
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
