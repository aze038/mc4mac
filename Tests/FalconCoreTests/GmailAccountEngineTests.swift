import XCTest
@testable import FalconCore

/// The engine as the other work items and the app use it: opening messages, the parts they plug
/// in, the streams the list listens to, held changes with many records kept, labels made on
/// another device, the daily look, and a relaunch after the Mac was away.
final class GmailAccountEngineTests: XCTestCase {
    private let day: TimeInterval = 86_400

    private func listedRig(_ gmail: FakeGmail, clock: ManualGmailClock = ManualGmailClock(), count: Int = 10,
                           parts: GmailEngineParts = GmailEngineParts()) async -> (GmailEngineRig, [GmailRef]) {
        let start = clock.now()
        let refs = (0..<count).map {
            gmail.add(subject: "Old \($0)", labels: [.inbox], date: start.addingTimeInterval(-Double(count - $0) * day), hasAttachment: $0 == 0)
        }
        let rig = GmailEngineRig(transport: gmail, clock: clock, parts: parts)
        await rig.engine.runBackfill()
        _ = await rig.engine.check(reason: .schedule)
        rig.events.clear()
        return (rig, refs)
    }

    // MARK: - Opening (§6)

    func testAKeptMessageOpensFromTheMacAndAnotherFromGmail() async throws {
        let clock = ManualGmailClock()
        let gmail = FakeGmail()
        let (rig, refs) = await listedRig(gmail, clock: clock)
        clock.advance(by: 30)
        let fresh = gmail.add(subject: "Kept", text: "Kept text", labels: [.inbox, .unread], date: clock.now())
        _ = await rig.engine.check(reason: .schedule)
        // Opening reads messages and attachments; label counts asked after the check may still be
        // on their way, and are not opening's.
        func openingUnits() -> Int { (gmail.units[.messagesGet] ?? 0) + (gmail.units[.attachmentsGet] ?? 0) + (gmail.units[.threadsGet] ?? 0) }
        let units = openingUnits()
        var opened: [OpenedMessage] = []
        for try await stage in await rig.engine.open(.gmail(account: rig.account.id, id: fresh.id), purpose: .window) { opened.append(stage) }
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(opened[0].fromCache)
        XCTAssertEqual(opened[0].content.message.textPlain, "Kept text")
        XCTAssertEqual(opened[0].content.message.subject, "Kept")
        XCTAssertEqual(openingUnits(), units, "a kept message opens at no cost")

        opened = []
        for try await stage in await rig.engine.open(.gmail(account: rig.account.id, id: refs[0].id), purpose: .window) { opened.append(stage) }
        XCTAssertEqual(opened.map(\.fromCache), [false])
        XCTAssertEqual(opened.last?.content.listedAttachments.map(\.filename), ["attachment.pdf"])
        XCTAssertEqual(openingUnits() - units, 20, "one format=full")

        // An attachment id Gmail no longer takes is replaced from a fresh structure.
        var stub = try XCTUnwrap(opened.last?.content.listedAttachments.first)
        stub.attachmentID = "expired"
        let data = try await rig.engine.attachmentData(stub, of: .gmail(account: rig.account.id, id: refs[0].id))
        XCTAssertEqual(data, gmail.mailbox.message(refs[0].id.hex)?.attachments.first?.data)
        let raw = try await rig.engine.rawMessage(.gmail(account: rig.account.id, id: refs[1].id))
        XCTAssertEqual(MIMEParser.parse(raw).headers.first("Subject"), "Old 1")
        await rig.finish()
    }

    // MARK: - The parts other work items plug in

    func testWorkNotBuiltYetSaysSoPlainlyAndPartsPlugIn() async throws {
        let gmail = FakeGmail()
        let (rig, refs) = await listedRig(gmail)
        let request = MailActionRequest(verb: .archive, targets: .items([.message(.gmail(account: rig.account.id, id: refs[0].id))]),
                                        context: ListView(scope: .folder(UUID())))
        do {
            _ = try await rig.engine.perform(request)
            XCTFail("no actions part yet")
        } catch let error as GmailEngineUnavailable {
            XCTAssertEqual(error.errorDescription, "owner@example.com isn't connected, so this wasn't done.")
        }
        let pending = await rig.engine.hasPendingChanges()
        XCTAssertFalse(pending)
        let flushed = await rig.engine.flushPending(within: 5)
        XCTAssertTrue(flushed)

        let actions = RecordingActions()
        rig.engine.install(GmailEngineParts(actions: actions))
        let receipt = try await rig.engine.perform(request)
        XCTAssertEqual(receipt.id, request.id)
        XCTAssertEqual(actions.performed, [request.id])
        await rig.finish()
    }

    func testRulesAndMutesSeeNewMailFirstAndCanKeepItQuiet() async throws {
        let clock = ManualGmailClock()
        let gmail = FakeGmail()
        let actions = RecordingActions()
        let (rig, _) = await listedRig(gmail, clock: clock, parts: GmailEngineParts(actions: actions))
        clock.advance(by: 30)
        let filed = gmail.add(subject: "Filed by a rule", labels: [.inbox, .unread], date: clock.now())
        gmail.add(subject: "Announced", labels: [.inbox, .unread], date: clock.now())
        actions.quiet = [filed.id]
        _ = await rig.engine.check(reason: .schedule)
        XCTAssertEqual(Set(actions.arrivals.map(\.summary.subject)), ["Filed by a rule", "Announced"])
        XCTAssertTrue(actions.arrivals.allSatisfy(\.runsRules))
        XCTAssertEqual(actions.arrivals.first { $0.summary.subject == "Announced" }?.textPlain, "Hello", "the text a body rule needs, at no cost")
        XCTAssertEqual(rig.events.announcedSubjects, ["Announced"])
        await rig.finish()
    }

    // MARK: - What the list listens to

    func testTheListHearsWhichMessagesChangedAndTheFoldersTheirCounts() async throws {
        let clock = ManualGmailClock()
        let gmail = FakeGmail()
        let (rig, refs) = await listedRig(gmail, clock: clock)
        let changes = await rig.engine.indexChanges()
        let folders = await rig.engine.folderUpdates()
        var changeIterator = changes.makeAsyncIterator()
        var folderIterator = folders.makeAsyncIterator()
        let initial = await folderIterator.next()
        XCTAssertEqual(initial?.first { $0.role == .inbox }?.unreadCount, 0)
        gmail.relabel(refs[2].id, adding: [.unread])
        _ = await rig.engine.check(reason: .schedule)
        let changed = await changeIterator.next()
        XCTAssertEqual(changed?.ids, [refs[2].id])
        let updated = await folderIterator.next()
        XCTAssertEqual(updated?.first { $0.role == .inbox }?.unreadCount, 1)
        await rig.finish()
    }

    // MARK: - Held changes with many records kept

    func testAnUndoneChangeWithManyKeptRecordsTakesTheLabelsFromGmail() async throws {
        let clock = ManualGmailClock()
        let gmail = FakeGmail()
        let (rig, refs) = await listedRig(gmail, clock: clock, count: 60)
        await rig.installActions(undoWindow: 60)
        let receipt = try await rig.engine.perform(try await rig.request(.archive, refs.map(\.id), in: .inbox))
        // The phone archives every one of them too, and stars one.
        for ref in refs { gmail.relabel(ref.id, removing: [.inbox]) }
        gmail.relabel(refs[7].id, adding: [.starred])
        _ = await rig.engine.check(reason: .schedule)
        let fetches = gmail.calls[.messagesGet] ?? 0
        let undone = await rig.engine.undo(receipt.id)
        XCTAssertTrue(undone)
        XCTAssertEqual((gmail.calls[.messagesGet] ?? 0) - fetches, 60, "more than 50 kept: each message's labels are asked of Gmail")
        let first = await rig.store.labels(of: refs[0].id)
        let starred = await rig.store.labels(of: refs[7].id)
        XCTAssertEqual(first, [])
        XCTAssertEqual(starred, [.starred])
        await rig.finish()
    }

    // MARK: - Labels made on another device

    func testALabelMadeOnAnotherDeviceIsReadAndListed() async throws {
        let clock = ManualGmailClock()
        let gmail = FakeGmail()
        let (rig, refs) = await listedRig(gmail, clock: clock)
        let label = gmail.addUserLabel(named: "Projects")
        gmail.relabel(refs[3].id, adding: [label])
        gmail.relabel(refs[4].id, adding: [label])
        _ = await rig.engine.check(reason: .schedule)
        let wanted = await rig.engine.labelsListWanted
        XCTAssertTrue(wanted, "a label the table does not hold is noticed")
        await rig.engine.maintenance(at: clock.now())
        await rig.engine.relistTask?.value
        let folders = await rig.engine.folders()
        let projects = try XCTUnwrap(folders.first { $0.name == "Projects" })
        XCTAssertEqual(projects.totalCount, 2)
        let bits = await rig.store.labels(of: refs[3].id)
        XCTAssertEqual(bits, [.inbox, label])
        await rig.finish()
    }

    func testTheDailyLookReadsTheSendAsAddressesAndChecksTheCounts() async throws {
        let clock = ManualGmailClock()
        let gmail = FakeGmail()
        gmail.sendAsAddresses = [GmailSendAs(sendAsEmail: "owner@example.com", isPrimary: true), GmailSendAs(sendAsEmail: "Sales@Example.com")]
        let (rig, _) = await listedRig(gmail, clock: clock)
        let own = await rig.engine.ownAddresses()
        XCTAssertTrue(own.contains("sales@example.com"), "read with the first load")
        gmail.sendAsAddresses = [GmailSendAs(sendAsEmail: "owner@example.com", isPrimary: true), GmailSendAs(sendAsEmail: "desk@example.com")]
        await rig.engine.maintenance(at: clock.now())
        clock.advance(by: day + 60)
        await rig.engine.noteOwnerActivity(.idle(since: clock.now()))
        let lists = gmail.calls[.messagesList] ?? 0
        await rig.engine.maintenance(at: clock.now())
        await rig.engine.relistTask?.value
        let later = await rig.engine.ownAddresses()
        XCTAssertTrue(later.contains("desk@example.com"))
        XCTAssertEqual(gmail.calls[.messagesList] ?? 0, lists, "counts that agree list nothing again")
        await rig.finish()
    }

    // MARK: - Answers placed by other items

    func testAnUploadIsPlacedOnTopOrKeepsItsPlaceAndARemovalGoes() async throws {
        let clock = ManualGmailClock(Date())
        let gmail = FakeGmail()
        let (rig, _) = await listedRig(gmail, clock: clock)
        let raw = Data("From: owner@example.com\r\nTo: ana@example.com\r\nSubject: Plan\r\nMessage-ID: <plan@x>\r\n\r\nText".utf8)
        let draft = try await gmail.createDraft(raw, threadID: nil, work: .interactive)
        let message = try XCTUnwrap(draft.message)
        await rig.engine.placeUploaded(message, labels: message.labels, raw: raw, replacing: nil, messageID: nil)
        let snapshot = await rig.store.index()
        let top = try XCTUnwrap(snapshot.byOrder.last)
        XCTAssertEqual(snapshot.records[Int(top)].gmailID, message.gmailID)
        let kept = await rig.store.cachedMessages([try XCTUnwrap(message.gmailID)])
        XCTAssertEqual(kept.values.first?.subject, "Plan", "its row is kept from the bytes uploaded, at no cost")
        // Saved again with Gmail's Message-ID: the same place.
        await rig.engine.placeUploaded(message, labels: message.labels, raw: raw, replacing: nil, messageID: "<gmail-plan@mail.gmail.com>")
        let again = await rig.store.index()
        XCTAssertEqual(again.byOrder.last, top)
        await rig.engine.forget([try XCTUnwrap(message.gmailID)])
        let gone = await rig.store.record(for: try XCTUnwrap(message.gmailID))
        XCTAssertTrue(gone?.attributes.contains(.tombstone) ?? true)
        await rig.finish()
    }

    // MARK: - A reply to a kept conversation

    func testAReplyToAKeptConversationExtendsItsSummaryAtNoCost() async throws {
        let clock = ManualGmailClock()
        let gmail = FakeGmail()
        let (rig, _) = await listedRig(gmail, clock: clock)
        clock.advance(by: 30)
        let first = gmail.add(subject: "Rates", labels: [.inbox, .unread], date: clock.now())
        _ = await rig.engine.check(reason: .schedule)
        clock.advance(by: 30)
        gmail.add(subject: "Re: Rates", from: "Bo <bo@example.com>", labels: [.inbox, .unread], date: clock.now(), thread: first.threadID)
        let threadCalls = gmail.calls[.threadsGet] ?? 0
        _ = await rig.engine.check(reason: .schedule)
        XCTAssertEqual(gmail.calls[.threadsGet] ?? 0, threadCalls)
        let summary = await rig.store.threadSummaries([first.threadID])[first.threadID]
        XCTAssertEqual(summary?.messageCount, 2)
        XCTAssertEqual(summary?.senders.map(\.address), ["ana@example.com", "bo@example.com"])
        await rig.finish()
    }

    // MARK: - After the Mac was away

    func testAfterARelaunchMailFromTheLastDayIsAnnouncedAndOlderMailIsNot() async throws {
        let clock = ManualGmailClock()
        let gmail = FakeGmail()
        let (rig, _) = await listedRig(gmail, clock: clock)
        await rig.engine.stop()
        // Two days away: mail came in all the while.
        let away = clock.now()
        let early = gmail.add(subject: "Early in the absence", labels: [.inbox, .unread], date: away.addingTimeInterval(3_600))
        let late = gmail.add(subject: "Late in the absence", labels: [.inbox, .unread], date: away.addingTimeInterval(40 * 3_600))
        clock.advance(by: 2 * day)
        let relaunched = rig.relaunched()
        let report = await relaunched.engine.check(reason: .wake)
        XCTAssertEqual(Set(report.placedAtTop), [early.id, late.id], "both came in since the last check")
        XCTAssertEqual(relaunched.events.announcedSubjects, ["Late in the absence"], "only the last day's is announced")
        await relaunched.finish()
    }
}

/// Stands in for G5's actions, rules and mutes.
final class RecordingActions: GmailEngineActions, @unchecked Sendable {
    private let lock = NSLock()
    private var _performed: [UUID] = []
    private var _arrivals: [GmailArrival] = []
    private var _quiet: Set<GmailMessageID> = []

    var performed: [UUID] { lock.withLock { _performed } }
    var arrivals: [GmailArrival] { lock.withLock { _arrivals } }
    var quiet: Set<GmailMessageID> {
        get { lock.withLock { _quiet } }
        set { lock.withLock { _quiet = newValue } }
    }

    func perform(_ request: MailActionRequest, engine: GmailAccountEngine) async throws -> ActionReceipt {
        lock.withLock { _performed.append(request.id) }
        return ActionReceipt(id: request.id, accountID: engine.accountID, verb: request.verb, messageCount: 1, isUndoable: true)
    }
    func undo(_ receiptID: UUID, engine: GmailAccountEngine) async -> Bool { false }
    func hasPendingChanges(engine: GmailAccountEngine) async -> Bool { false }
    func flushPending(within seconds: TimeInterval, engine: GmailAccountEngine) async -> Bool { true }
    func runRulesOnInbox(engine: GmailAccountEngine) async throws {}
    func createFolder(named name: String, parent: UUID?, engine: GmailAccountEngine) async throws -> FolderInfo {
        throw GmailEngineUnavailable(email: engine.account.email, what: "New Folder")
    }
    func arrived(_ arrivals: [GmailArrival], engine: GmailAccountEngine) async -> Set<GmailMessageID> {
        lock.withLock {
            _arrivals += arrivals
            return _quiet
        }
    }
}
