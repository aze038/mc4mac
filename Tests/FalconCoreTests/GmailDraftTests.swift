import XCTest
@testable import FalconCore

/// Drafts of a switched Google account on Gmail: closing saves, Discard deletes after its undo
/// window, and no save ever loses the text or makes a second draft.
final class GmailDraftTests: XCTestCase {
    private var root: URL!
    private let owner = "owner@example.com"

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("falcon-gmail-drafts-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Log.start(in: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private struct Rig {
        let mailbox: FakeGmail
        let transport: ScriptedGmailTransport
        let store: any GmailStore
        let drafts: GmailDrafts
        let file: URL
    }

    private func rig(file: URL? = nil, transport: ScriptedGmailTransport? = nil, clock: TestClock? = nil,
                     retryInterval: TimeInterval = 0.1) -> Rig {
        let transport = transport ?? ScriptedGmailTransport(FakeGmail(email: owner))
        let mailbox = transport.mailbox
        let store = GmailTestPlacer.store(accountID: mailbox.accountID, root: root)
        let file = file ?? root.appendingPathComponent("drafts.json")
        let now: @Sendable () -> Date = clock?.reading ?? { @Sendable in Date() }
        let drafts = GmailDrafts(accountID: mailbox.accountID, email: owner, transport: transport, placer: GmailTestPlacer.engine(transport: transport, store: store),
                                 file: file, cursor: { mailbox.historyID }, now: now, retryInterval: retryInterval)
        return Rig(mailbox: mailbox, transport: transport, store: store, drafts: drafts, file: file)
    }

    private func raw(_ text: String, subject: String = "Rates for October", to: [String] = ["ana@example.com"]) -> Data {
        MIMEBuilder.build(OutgoingMessage(from: EmailAddress(name: "Owner", address: owner), to: to.map { EmailAddress(address: $0) },
                                          subject: subject, textBody: text))
    }

    private func ref(_ localID: UUID = UUID(), accountID: UUID, draftID: String? = nil, thread: GmailThreadID? = nil) -> DraftRef {
        DraftRef(localID: localID, accountID: accountID, gmailDraftID: draftID, threadID: thread,
                 stableMessageID: "<\(localID.uuidString.lowercased()).falconmail@example.com>")
    }

    private func draftMessages(_ mailbox: FakeGmail) -> [FakeGmail.Message] {
        mailbox.messages.filter { $0.labels.contains(.draft) }
    }

    private func header(_ name: String, of message: FakeGmail.Message) -> String? {
        message.headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func state(_ file: URL) -> GmailDraftsState? {
        AtomicFile.readJSON(GmailDraftsState.self, from: file)
    }

    // MARK: - Saving

    func testTheFirstSaveCreatesAndLaterSavesUpdateTheSameDraft() async throws {
        let r = rig()
        let draft = ref(accountID: r.mailbox.accountID)
        let first = try await r.drafts.save(raw("First words"), as: draft)
        let draftID = try XCTUnwrap(first.gmailDraftID)
        XCTAssertEqual(state(r.file)?.links[draft.localID.uuidString]?.ref.gmailDraftID, draftID,
                       "written down before save returns, so a leftover updates it")
        let second = try await r.drafts.save(raw("First words, and more"), as: draft)
        XCTAssertEqual(second.gmailDraftID, draftID)

        XCTAssertEqual(r.mailbox.draftIDs.count, 1)
        let gmailCopy = try XCTUnwrap(draftMessages(r.mailbox).first)
        XCTAssertEqual(draftMessages(r.mailbox).count, 1)
        XCTAssertEqual(gmailCopy.text.trimmed, "First words, and more")
        XCTAssertEqual(header("Message-ID", of: gmailCopy), draft.stableMessageID, "one Message-ID for every save")
        XCTAssertEqual(header(GmailDrafts.draftHeader, of: gmailCopy), draft.localID.uuidString.lowercased())
        XCTAssertEqual(r.mailbox.units[.draftsCreate], 10)
        XCTAssertEqual(r.mailbox.units[.draftsUpdate], 15)

        // Each save's answer goes into the index at once; the message the save replaced leaves it.
        let firstMessage = try XCTUnwrap(first.gmailMessageID)
        let secondMessage = try XCTUnwrap(second.gmailMessageID)
        XCTAssertNotEqual(firstMessage, secondMessage)
        let index = await store(r).index()
        XCTAssertTrue(index.record(for: firstMessage)?.attributes.contains(.tombstone) ?? true, "the earlier message is gone")
        XCTAssertFalse(index.byOrder.contains { index.records[Int($0)].id == firstMessage.raw })
        XCTAssertTrue(index.record(for: secondMessage)?.hasSystemLabel(.draft) ?? false)
        let cached = await r.store.cachedMessages([secondMessage])[secondMessage]
        XCTAssertEqual(cached?.subject, "Rates for October")
    }

    private func store(_ r: Rig) -> any GmailStore { r.store }

    func testBccIsKeptInGmailsCopyOfTheDraft() async throws {
        let r = rig()
        try await r.drafts.save(raw("Hello"), as: ref(accountID: r.mailbox.accountID), bcc: [EmailAddress(address: "hidden@example.com")])
        let upload = String(decoding: try XCTUnwrap(r.transport.uploads(.draftsCreate).first), as: UTF8.self)
        XCTAssertTrue(upload.contains("Bcc: hidden@example.com\r\n"), upload)
    }

    func testOverlappingSavesFinishInOrderAndTheLatestContentWins() async throws {
        let r = rig()
        let draft = ref(accountID: r.mailbox.accountID)
        let gate = r.transport.hold(.draftsCreate)
        let drafts = r.drafts
        let a = Task { try await drafts.save(self.raw("A"), as: draft) }
        await assertEventually { gate.arrivals == 1 }
        let b = Task { try await drafts.save(self.raw("B"), as: draft) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let c = Task { try await drafts.save(self.raw("C"), as: draft) }
        try await Task.sleep(nanoseconds: 50_000_000)
        gate.open()
        let results = try await [a.value, b.value, c.value]
        XCTAssertEqual(Set(results.compactMap(\.gmailDraftID)).count, 1, "one draft")
        XCTAssertEqual(r.mailbox.calls[.draftsCreate], 1)
        XCTAssertEqual(r.mailbox.calls[.draftsUpdate], 1, "B was superseded by C before it went")
        XCTAssertEqual(draftMessages(r.mailbox).map { $0.text.trimmed }, ["C"])
    }

    func testACreateThatTimedOutIsNotCreatedTwice() async throws {
        let r = rig(retryInterval: 3_600)
        let draft = ref(accountID: r.mailbox.accountID)
        r.transport.failAfterAccepting(.draftsCreate, with: GoogleAPIError(kind: .temporary, detail: "URLError -1001"))
        do {
            try await r.drafts.save(raw("Kept"), as: draft)
            XCTFail("an unanswered create is not a saved draft")
        } catch let deferred as GmailDraftDeferred {
            XCTAssertEqual(deferred.sentence, "Saved to Drafts. It goes to Gmail when you're back online.")
        }
        XCTAssertEqual(draftMessages(r.mailbox).count, 1, "Gmail made it, though no answer came")
        XCTAssertEqual(state(r.file)?.links[draft.localID.uuidString]?.creating, true)

        let saved = try await r.drafts.save(raw("Kept, and more"), as: draft)
        XCTAssertEqual(r.mailbox.calls[.draftsCreate], 1, "found in the history, not created again")
        XCTAssertEqual(r.mailbox.calls[.draftsUpdate], 1)
        XCTAssertEqual(draftMessages(r.mailbox).map { $0.text.trimmed }, ["Kept, and more"])
        XCTAssertEqual(saved.gmailDraftID, r.mailbox.draftIDs.keys.first)
        XCTAssertNil(state(r.file)?.links[draft.localID.uuidString]?.creating)
    }

    func testAQuitBeforeCreateAnsweredSavesTheDraftExactlyOnceAtTheNextLaunch() async throws {
        let mailbox = FakeGmail(email: owner)
        let crashing = ScriptedGmailTransport(mailbox)
        let late = crashing.holdAfterAccepting(.draftsCreate)
        let before = rig(file: root.appendingPathComponent("before.json"), transport: crashing)
        let draft = ref(accountID: mailbox.accountID)
        let drafts = before.drafts
        let closing = Task { try? await drafts.save(self.raw("Closing words"), as: draft) }
        await assertEventually { late.arrivals == 1 }
        XCTAssertEqual(draftMessages(mailbox).count, 1)

        // What the quit leaves: the link says a create was on its way.
        let after = root.appendingPathComponent("after.json")
        try FileManager.default.copyItem(at: before.file, to: after)
        XCTAssertEqual(state(after)?.links[draft.localID.uuidString]?.creating, true)
        let relaunched = rig(file: after, transport: ScriptedGmailTransport(mailbox))
        let saved = try await relaunched.drafts.save(raw("Closing words"), as: draft, reason: .leftover)
        XCTAssertEqual(draftMessages(mailbox).count, 1, "exactly once")
        XCTAssertEqual(mailbox.calls[.draftsCreate], 1)
        XCTAssertEqual(saved.gmailDraftID, mailbox.draftIDs.keys.first)
        late.open()
        _ = await closing.value
    }

    func testAnUpdateGmailNoLongerKnowsCreatesANewDraftSoTheTextIsKept() async throws {
        let r = rig()
        let draft = ref(accountID: r.mailbox.accountID)
        let first = try await r.drafts.save(raw("Before"), as: draft)
        // Sent or deleted on the phone meanwhile.
        try await r.mailbox.deleteDraft(try XCTUnwrap(first.gmailDraftID), work: .interactive)
        let second = try await r.drafts.save(raw("After"), as: draft)
        XCTAssertNotEqual(second.gmailDraftID, first.gmailDraftID)
        XCTAssertEqual(draftMessages(r.mailbox).map { $0.text.trimmed }, ["After"])
        XCTAssertEqual(r.mailbox.calls[.draftsCreate], 2)
    }

    func testADraftSavedAgainAfterARelaunchUpdatesTheSameDraft() async throws {
        let r = rig()
        let draft = ref(accountID: r.mailbox.accountID)
        let saved = try await r.drafts.save(raw("Closed"), as: draft, reason: .close)
        let relaunched = rig(file: r.file, transport: r.transport)
        let again = try await relaunched.drafts.save(raw("Closed"), as: ref(draft.localID, accountID: r.mailbox.accountID), reason: .leftover)
        XCTAssertEqual(again.gmailDraftID, saved.gmailDraftID)
        XCTAssertEqual(r.mailbox.calls[.draftsCreate], 1)
        XCTAssertEqual(draftMessages(r.mailbox).count, 1)
    }

    // MARK: - Offline

    func testClosingOfflineShowsAProvisionalDraftThatGoesToGmailWhenBackOnline() async throws {
        let r = rig(retryInterval: 3_600)
        let events = await r.drafts.events()
        let seen = DraftEventLog()
        let listening = Task { for await event in events { seen.append(event) } }
        let draft = ref(accountID: r.mailbox.accountID)
        r.mailbox.failAlways(.draftsCreate, with: GoogleAPIError(kind: .offline, detail: "URLError -1009"))
        do {
            try await r.drafts.save(raw("Written on the train", subject: "Board minutes"), as: draft)
            XCTFail("offline, Gmail has not got it")
        } catch let deferred as GmailDraftDeferred {
            XCTAssertEqual(deferred.sentence, "Saved to Drafts. It goes to Gmail when you're back online.")
        }
        let provisional = await r.drafts.provisionalDrafts()
        XCTAssertEqual(provisional.map(\.subject), ["Board minutes"])
        XCTAssertEqual(provisional.first?.localID, draft.localID)
        XCTAssertEqual(state(r.file)?.provisional.count, 1, "still shown after a relaunch")
        XCTAssertNil(state(r.file)?.links[draft.localID.uuidString]?.creating, "no create reached Gmail")

        r.mailbox.failAlways(.draftsCreate, with: nil)
        await r.drafts.retryWaiting()
        await assertEventually { seen.savedIDs == [draft.localID] }
        let left = await r.drafts.provisionalDrafts()
        XCTAssertTrue(left.isEmpty)
        XCTAssertEqual(draftMessages(r.mailbox).map { $0.text.trimmed }, ["Written on the train"])
        listening.cancel()
    }

    // MARK: - Discard, with Undo

    func testDiscardDeletesGmailsCopyOnlyAfterTheUndoWindow() async throws {
        let r = rig()
        let draft = ref(accountID: r.mailbox.accountID)
        try await r.drafts.save(raw("To be thrown away"), as: draft)
        await r.drafts.discard(draft, undoWindow: 0.4)
        XCTAssertEqual(r.mailbox.draftIDs.count, 1, "still there while Undo is possible")
        XCTAssertNotNil(state(r.file)?.discarded[draft.localID.uuidString], "the marker is on disk at once")
        do {
            try await r.drafts.save(raw("To be thrown away"), as: draft)
            XCTFail("a discarded draft is never saved back")
        } catch is GmailDraftDiscarded {}
        await assertEventually { r.mailbox.draftIDs.isEmpty }
        XCTAssertEqual(r.mailbox.units[.draftsDelete], 10)
        await assertEventually { self.state(r.file)?.discarded.isEmpty == true }
        XCTAssertTrue(draftMessages(r.mailbox).isEmpty)
    }

    func testUndoWithinTheWindowKeepsTheDraftAndItsLink() async throws {
        let r = rig()
        let draft = ref(accountID: r.mailbox.accountID)
        let saved = try await r.drafts.save(raw("Second thoughts"), as: draft)
        await r.drafts.discard(ref(draft.localID, accountID: r.mailbox.accountID), undoWindow: 0.4)
        let back = await r.drafts.undoDiscard(draft.localID)
        XCTAssertEqual(back?.gmailDraftID, saved.gmailDraftID, "the window comes back with its link to Gmail's copy")
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertNil(r.mailbox.calls[.draftsDelete])
        XCTAssertEqual(r.mailbox.draftIDs.count, 1)
        let again = try await r.drafts.save(raw("Second thoughts, kept"), as: draft)
        XCTAssertEqual(again.gmailDraftID, saved.gmailDraftID)
        XCTAssertEqual(r.mailbox.calls[.draftsCreate], 1)
    }

    func testDiscardThenQuitDeletesAtQuit() async throws {
        let r = rig()
        let draft = ref(accountID: r.mailbox.accountID)
        try await r.drafts.save(raw("Gone at quit"), as: draft)
        await r.drafts.discard(draft, undoWindow: 60)
        let done = await r.drafts.flush(within: 5)
        XCTAssertTrue(done)
        XCTAssertTrue(r.mailbox.draftIDs.isEmpty)
        XCTAssertEqual(state(r.file)?.discarded.isEmpty, true)
        XCTAssertNil(state(r.file)?.links[draft.localID.uuidString])
    }

    func testADiscardLeftByAQuitIsFinishedAtTheNextLaunch() async throws {
        let mailbox = FakeGmail(email: owner)
        let offline = ScriptedGmailTransport(mailbox)
        let before = rig(transport: offline, retryInterval: 3_600)
        let draft = ref(accountID: mailbox.accountID)
        try await before.drafts.save(raw("Discarded offline"), as: draft)
        offline.refuse(.draftsDelete, with: GoogleAPIError(kind: .offline, detail: "URLError -1009"))
        await before.drafts.discard(draft, undoWindow: 0)
        await assertEventually { offline.mailbox.attempts[.draftsDelete] == nil && self.state(before.file)?.discarded.isEmpty == false }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(mailbox.draftIDs.count, 1, "offline, nothing deleted yet")

        let relaunched = rig(file: before.file, transport: ScriptedGmailTransport(mailbox))
        await relaunched.drafts.start()
        await assertEventually { mailbox.draftIDs.isEmpty }
        await assertEventually { self.state(before.file)?.discarded.isEmpty == true }
    }

    func testAQuietCloseDeletesThisSessionsAutosaveOnly() async throws {
        let r = rig()
        let fresh = ref(accountID: r.mailbox.accountID)
        let autosaved = try await r.drafts.autosave(raw("Half a thought"), as: fresh)
        XCTAssertNotNil(autosaved?.gmailDraftID)
        await r.drafts.closeWithoutSaving(fresh)
        XCTAssertTrue(r.mailbox.draftIDs.isEmpty, "no stray copy stays in Drafts")

        // A draft opened from Drafts is the owner's, and a quiet close leaves it.
        let existing = try await r.drafts.save(raw("Saved yesterday"), as: ref(accountID: r.mailbox.accountID))
        let reopened = ref(accountID: r.mailbox.accountID, draftID: existing.gmailDraftID)
        _ = try await r.drafts.autosave(raw("Saved yesterday"), as: reopened)
        await r.drafts.closeWithoutSaving(reopened)
        XCTAssertEqual(r.mailbox.draftIDs.count, 1)
        XCTAssertEqual(r.mailbox.calls[.draftsDelete], 1)
    }

    func testAQuietCloseAfterSaveDraftKeepsTheDraft() async throws {
        let r = rig()
        let draft = ref(accountID: r.mailbox.accountID)
        _ = try await r.drafts.autosave(raw("Half a thought"), as: draft)
        try await r.drafts.save(raw("Half a thought"), as: draft, reason: .saveButton)
        await r.drafts.closeWithoutSaving(draft)
        XCTAssertEqual(r.mailbox.draftIDs.count, 1, "saved on purpose, so kept")
        XCTAssertNil(r.mailbox.calls[.draftsDelete])
    }

    func testUndoAfterTheWindowIsTooLate() async throws {
        let r = rig()
        let draft = ref(accountID: r.mailbox.accountID)
        try await r.drafts.save(raw("Gone"), as: draft)
        await r.drafts.discard(draft, undoWindow: 0.1)
        await assertEventually { r.mailbox.draftIDs.isEmpty }
        let back = await r.drafts.undoDiscard(draft.localID)
        XCTAssertNil(back)
    }

    func testQuitWaitsForASaveOnItsWayForAtMostItsLimit() async throws {
        let r = rig()
        let draft = ref(accountID: r.mailbox.accountID)
        let gate = r.transport.hold(.draftsCreate)
        let drafts = r.drafts
        let closing = Task { try await drafts.save(self.raw("Closing at quit"), as: draft) }
        await assertEventually { gate.arrivals == 1 }
        let cutShort = await r.drafts.flush(within: 0.2)
        XCTAssertFalse(cutShort, "Gmail had not answered within the limit")
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            gate.open()
        }
        let done = await r.drafts.flush(within: 5)
        XCTAssertTrue(done)
        _ = try await closing.value
        XCTAssertEqual(r.mailbox.draftIDs.count, 1)
    }

    func testAutomaticSavesComeAtMostOnceAMinute() async throws {
        let clock = TestClock()
        let r = rig(clock: clock)
        let draft = ref(accountID: r.mailbox.accountID)
        let first = try await r.drafts.autosave(raw("One"), as: draft)
        XCTAssertNotNil(first)
        clock.advance(30)
        let skipped = try await r.drafts.autosave(raw("One and two"), as: draft)
        XCTAssertNil(skipped)
        clock.advance(31)
        let second = try await r.drafts.autosave(raw("One, two and three"), as: draft)
        XCTAssertEqual(second?.gmailDraftID, first?.gmailDraftID)
        XCTAssertEqual(r.mailbox.calls[.draftsCreate], 1)
        XCTAssertEqual(r.mailbox.calls[.draftsUpdate], 1)
    }

    // MARK: - Opening drafts

    func testADraftOpenedFromDraftsIsUpdatedNeverCopied() async throws {
        let r = rig()
        // Written in Gmail on the web.
        let web = try await r.mailbox.createDraft(raw("From the web"), threadID: nil, work: .interactive)
        let message = try XCTUnwrap(web.message?.gmailID)
        let draftID = try await r.drafts.draftID(forMessage: message)
        XCTAssertEqual(draftID, web.id)
        XCTAssertEqual(r.mailbox.units[.draftsList], 5)
        let opened = ref(accountID: r.mailbox.accountID, draftID: draftID)
        try await r.drafts.save(raw("From the web, finished here"), as: opened, reason: .saveButton)
        let open = await r.drafts.openDraft(web.id)
        XCTAssertEqual(open, opened.localID, "a second double-click brings this window forward")
        XCTAssertEqual(r.mailbox.draftIDs.count, 1)
        XCTAssertEqual(r.mailbox.calls[.draftsCreate], 1, "only the web's own")
        XCTAssertEqual(draftMessages(r.mailbox).map { $0.text.trimmed }, ["From the web, finished here"])
        _ = try await r.drafts.draftID(forMessage: message)
        XCTAssertEqual(r.mailbox.units[.draftsList], 5, "known, so not listed again")
    }

    func testADraftSavedBeforeTheSwitchIsFoundByItsMessageID() async throws {
        let r = rig()
        let old = OutgoingMessage(from: EmailAddress(address: owner), to: [EmailAddress(address: "ana@example.com")], subject: "Old draft",
                                  textBody: "Saved over IMAP", messageID: "<imap-draft-1@example.com>")
        let web = try await r.mailbox.createDraft(MIMEBuilder.build(old), threadID: nil, work: .interactive)
        let found = try await r.drafts.draft(forMessageID: "<imap-draft-1@example.com>")
        XCTAssertEqual(found?.draftID, web.id)
        XCTAssertEqual(found?.message.hex, web.message?.id)
    }

    // MARK: - Sending a draft

    func testSendingADraftDeletesItOnceTheSendIsConfirmed() async throws {
        let r = rig()
        let draft = ref(accountID: r.mailbox.accountID)
        try await r.drafts.save(raw("Ready to go"), as: draft)
        let handed = await r.drafts.handOver(draft.localID)
        let drafts = r.drafts
        let sender = GmailSender(accountID: r.mailbox.accountID, email: owner, transport: r.transport,
                                 deleteDraft: { try await drafts.sent($0) }, cursor: { r.mailbox.historyID }, wentOut: {})
        let outbox = Outbox(layout: FileLayout(root: root), sender: sender, undoWindow: 0, confirmAfter: [0.05], retryDelay: { _ in 0 })
        _ = try await outbox.enqueue(accountID: r.mailbox.accountID, from: owner, message: message("Ready to go"), sendAt: Date(),
                                     gmailDraftID: handed?.gmailDraftID)
        await assertEventually { await outbox.snapshot().first?.status == .sent }
        await assertEventually { await outbox.snapshot().first?.gmailDraftID == nil }
        XCTAssertTrue(r.mailbox.draftIDs.isEmpty)
        XCTAssertEqual(r.mailbox.messages.filter { $0.labels.contains(.sent) }.count, 1)
        let link = await r.drafts.link(draft.localID)
        XCTAssertNil(link)
    }

    func testAfterARelaunchTheSentDraftIsStillDeleted() async throws {
        let r = rig()
        let draft = ref(accountID: r.mailbox.accountID)
        let saved = try await r.drafts.save(raw("Sent before the delete"), as: draft)
        r.transport.refuse(.draftsDelete, with: GoogleAPIError(kind: .offline, detail: "URLError -1009"))
        let layout = FileLayout(root: root)
        let first = Outbox(layout: layout, sender: GmailSender(accountID: r.mailbox.accountID, email: owner, transport: r.transport,
                                                                        cursor: { nil }, wentOut: {}),
                           undoWindow: 0, confirmAfter: [0.05], retryDelay: { _ in 0 })
        let item = try await first.enqueue(accountID: r.mailbox.accountID, from: owner, message: message("Sent before the delete"),
                                           sendAt: Date(), gmailDraftID: saved.gmailDraftID)
        await assertEventually { await first.snapshot().first?.status == .sent }
        let stillThere = await first.snapshot().first?.gmailDraftID
        XCTAssertEqual(stillThere, saved.gmailDraftID, "kept until Gmail has deleted it")
        XCTAssertEqual(r.mailbox.draftIDs.count, 1)

        r.transport.refuse(.draftsDelete, with: nil)
        let relaunched = Outbox(layout: layout, sender: GmailSender(accountID: r.mailbox.accountID, email: owner, transport: r.transport,
                                                                        cursor: { nil }, wentOut: {}),
                                undoWindow: 0)
        await assertEventually { await relaunched.snapshot().first?.gmailDraftID == nil }
        XCTAssertTrue(r.mailbox.draftIDs.isEmpty)
        let stored = AtomicFile.readJSON(OutboxItem.self, from: layout.outboxDirectory.appendingPathComponent("\(item.id.uuidString).json"))
        XCTAssertNil(stored?.gmailDraftID)
        XCTAssertEqual(stored?.status, .sent)
    }

    private func message(_ text: String) -> OutgoingMessage {
        OutgoingMessage(from: EmailAddress(name: "Owner", address: owner), to: [EmailAddress(address: "ana@example.com")],
                        subject: "Rates for October", textBody: text)
    }
}

private final class DraftEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [GmailDraftEvent] = []

    func append(_ event: GmailDraftEvent) { lock.withLock { events.append(event) } }

    var savedIDs: [UUID] {
        lock.withLock {
            events.compactMap { if case .saved(let ref) = $0 { return ref.localID } else { return nil } }
        }
    }
}
