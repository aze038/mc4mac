import XCTest
@testable import FalconCore

/// Checks for changes (§4.2–§4.6), against the in-memory Gmail mailbox: which mail is new, where
/// added mail goes, what the history's odd cases do, the resync after the history expired, and the
/// owner's own changes coming back.
final class GmailHistoryTests: XCTestCase {
    private let day: TimeInterval = 86_400

    /// A mailbox of `count` Inbox messages, one a day, the newest a day before the clock, listed.
    private func listedRig(_ gmail: MemoryGmailTransport, count: Int = 20, clock: ManualGmailClock = ManualGmailClock(),
                           settings: GmailEngineSettings? = nil, parts: GmailEngineParts = GmailEngineParts())
        async throws -> (GmailEngineRig, [GmailRef]) {
        let start = clock.now()
        let refs = (0..<count).map { i in
            gmail.add(subject: "Old \(i)", labels: [.inbox], date: start.addingTimeInterval(-Double(count - i) * day))
        }
        let rig = GmailEngineRig(transport: gmail, clock: clock, settings: settings, parts: parts)
        await rig.engine.runBackfill()
        let phase = await rig.engine.state.backfill?.phase
        XCTAssertEqual(phase, .complete, "every message listed")
        rig.events.clear()
        return (rig, refs)
    }

    private func mime(_ subject: String, messageID: String, date: Date, from: String = "Ana <ana@example.com>") -> Data {
        Data("""
        From: \(from)\r
        To: owner@example.com\r
        Subject: \(subject)\r
        Date: \(RFC5322Date.format(date))\r
        Message-ID: \(messageID)\r
        Content-Type: text/plain; charset=UTF-8\r
        \r
        Body of \(subject)
        """.utf8)
    }

    private func order(_ id: GmailMessageID, _ rig: GmailEngineRig) async -> UInt32? {
        await rig.store.record(for: id)?.order
    }

    // MARK: - Arrived now, or deep

    func testMailThatArrivedNowGoesOnTopAndOtherAddedMailGoesDeep() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let (rig, refs) = try await listedRig(gmail, clock: clock)
        clock.advance(by: 30)
        let fresh = gmail.add(subject: "Fresh", labels: [.inbox, .unread], date: clock.now().addingTimeInterval(-5))
        // Received ten and a half days ago, as an import from another app would be: between Old 9 and Old 10.
        let imported = gmail.add(subject: "Imported", labels: [.inbox], date: clock.now().addingTimeInterval(-10.5 * day))
        let unitsBefore = gmail.units.filter { $0.key != .labelsGet }.values.reduce(0, +)

        let report = await rig.engine.check(reason: .schedule)

        XCTAssertEqual(report.placedAtTop, [fresh.id])
        XCTAssertEqual(report.placedDeep, [imported.id])
        XCTAssertEqual(rig.events.announcedSubjects, ["Fresh"], "only mail that arrived now is announced")
        let top = await order(fresh.id, rig)
        let deep = await order(imported.id, rig)
        let below = await order(refs[9].id, rig)
        let above = await order(refs[10].id, rig)
        let newestOld = await order(refs[19].id, rig)
        XCTAssertGreaterThan(try XCTUnwrap(top), try XCTUnwrap(newestOld))
        XCTAssertGreaterThan(try XCTUnwrap(deep), try XCTUnwrap(below))
        XCTAssertLessThan(try XCTUnwrap(deep), try XCTUnwrap(above))
        // One history call, both fetched whole in one batch, one `before:` search for the deep one.
        let spent = gmail.units.filter { $0.key != .labelsGet }.values.reduce(0, +) - unitsBefore
        XCTAssertEqual(spent, 2 + 2 * 20 + 5)
        let labels = await rig.store.labels(of: fresh.id)
        XCTAssertEqual(labels, [.inbox, .unread])
        let cached = await rig.store.cachedIDs()
        XCTAssertTrue(cached.contains(fresh.id), "mail that arrived now joins the newest 1,000 with the text its fetch gave")
        await rig.finish()
    }

    func testAMessageDated2037ChangesNothingAndNewMailIsStillAnnounced() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let (rig, _) = try await listedRig(gmail, clock: clock)
        clock.advance(by: 30)
        let future = gmail.add(subject: "Dated 2037", labels: [.inbox, .unread], date: Date(timeIntervalSince1970: 2_114_380_800))
        let first = await rig.engine.check(reason: .schedule)
        XCTAssertTrue(first.arrivals.isEmpty, "a message dated years ahead is old mail")
        XCTAssertTrue(rig.events.announced.isEmpty)
        XCTAssertEqual(first.placedDeep, [future.id])
        let placed = await rig.store.record(for: future.id)
        XCTAssertNotNil(placed)

        clock.advance(by: 30)
        let fresh = gmail.add(subject: "Fresh after 2037", labels: [.inbox, .unread], date: clock.now())
        let second = await rig.engine.check(reason: .schedule)
        XCTAssertEqual(second.placedAtTop, [fresh.id])
        XCTAssertEqual(rig.events.announcedSubjects, ["Fresh after 2037"], "new mail is announced whatever sits at the top")
        let freshOrder = await order(fresh.id, rig)
        let futureOrder = await order(future.id, rig)
        XCTAssertGreaterThan(try XCTUnwrap(freshOrder), try XCTUnwrap(futureOrder))
        await rig.finish()
    }

    func testMailGmailTookLongerToScanStillCountsAsNew() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let (rig, _) = try await listedRig(gmail, clock: clock)
        _ = await rig.engine.check(reason: .schedule)
        clock.advance(by: 30)
        // Received eight minutes before the last check began, but only in the history now.
        let slow = gmail.add(subject: "Large scan", labels: [.inbox, .unread], date: clock.now().addingTimeInterval(-30 - 8 * 60))
        let tooOld = gmail.add(subject: "Older", labels: [.inbox, .unread], date: clock.now().addingTimeInterval(-30 - 15 * 60))
        let report = await rig.engine.check(reason: .schedule)
        XCTAssertEqual(report.placedAtTop, [slow.id])
        XCTAssertEqual(report.placedDeep, [tooOld.id])
        await rig.finish()
    }

    func testAWrongClockOnTheMacDoesNotMatter() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let (rig, _) = try await listedRig(gmail, clock: clock)
        _ = await rig.engine.check(reason: .schedule)
        // The Mac's clock is two hours behind Gmail's.
        rig.transport.setClockOffset(2 * 3600)
        clock.advance(by: 30)
        let fresh = gmail.add(subject: "By Gmail's clock", labels: [.inbox, .unread], date: clock.now().addingTimeInterval(2 * 3600))
        let report = await rig.engine.check(reason: .schedule)
        XCTAssertEqual(report.placedAtTop, [fresh.id])
        XCTAssertEqual(rig.events.announcedSubjects, ["By Gmail's clock"])
        await rig.finish()
    }

    // MARK: - The history's odd cases

    func testAMessageAddedAndDeletedInOneCheckIsNeverFetched() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let (rig, _) = try await listedRig(gmail, clock: clock)
        let fetchesBefore = gmail.calls[.messagesGet] ?? 0
        let autosave = gmail.add(subject: "Autosave", labels: [.draft], date: clock.now())
        gmail.delete(autosave.id)
        let report = await rig.engine.check(reason: .schedule)
        XCTAssertEqual(report.records, 2)
        XCTAssertEqual(gmail.calls[.messagesGet] ?? 0, fetchesBefore)
        XCTAssertTrue(report.placedAtTop.isEmpty && report.placedDeep.isEmpty && report.waiting.isEmpty)
        let record = await rig.store.record(for: autosave.id)
        XCTAssertNil(record)
        let cursor = await rig.engine.historyCursor()
        XCTAssertEqual(cursor, gmail.historyID)
        await rig.finish()
    }

    func testAMessageDeletedBeforeItsFetchIsATombstoneAndNeverPlaced() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let (rig, _) = try await listedRig(gmail, clock: clock)
        clock.advance(by: 30)
        let brief = gmail.add(subject: "Here and gone", labels: [.inbox, .unread], date: clock.now())
        rig.transport.before(.messagesGet) { gmail.delete(brief.id) }
        let report = await rig.engine.check(reason: .schedule)
        XCTAssertEqual(report.tombstoned, [brief.id])
        XCTAssertTrue(report.placedAtTop.isEmpty)
        XCTAssertTrue(rig.events.announced.isEmpty)
        let tombstone = await rig.store.batches.last?.changes.contains(.tombstone(brief.id)) ?? false
        XCTAssertTrue(tombstone, "journaled as a tombstone")
        let next = await rig.engine.check(reason: .schedule)
        XCTAssertNil(next.failure)
        let record = await rig.store.record(for: brief.id)
        XCTAssertNil(record)
        await rig.finish()
    }

    func testAStreamOfWebDraftAutosavesPlacesOnlyTheLatest() async throws {
        let clock = ManualGmailClock(Date())
        let gmail = MemoryGmailTransport()
        let (rig, _) = try await listedRig(gmail, clock: clock)
        var draft = try await gmail.createDraft(mime("Plan", messageID: "<plan@example.com>", date: clock.now()), threadID: nil, work: .interactive)
        let fetchesBefore = gmail.calls[.messagesGet] ?? 0
        var placed: [GmailMessageID] = []
        for round in 0..<4 {
            for save in 0..<3 {
                draft = try await gmail.updateDraft(draft.id, raw: mime("Plan \(round).\(save)", messageID: "<plan@example.com>", date: clock.now()),
                                                    threadID: nil, work: .interactive)
            }
            clock.advance(by: 30)
            let report = await rig.engine.check(reason: .schedule)
            placed += report.placedAtTop + report.placedDeep
            XCTAssertEqual(report.placedAtTop.count + report.placedDeep.count, 1, "each check places only the save that survived it")
        }
        XCTAssertEqual(gmail.calls[.messagesGet] ?? 0, fetchesBefore + 4, "one fetch a check, never one a save")
        let latest = try XCTUnwrap(draft.message?.gmailID)
        XCTAssertEqual(placed.last, latest)
        let snapshot = await rig.store.index()
        let drafts = snapshot.byOrder.filter { snapshot.records[Int($0)].hasSystemLabel(.draft) }.map { snapshot.records[Int($0)].gmailID }
        XCTAssertEqual(drafts, [latest], "earlier saves are gone from the index")
        XCTAssertTrue(rig.events.announced.isEmpty)
        await rig.finish()
    }

    func testALabelChangeOnAMessageTheIndexMissedPlacesIt() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let (rig, refs) = try await listedRig(gmail, clock: clock)
        let missed = gmail.add(subject: "Missed by a listing", labels: [.inbox], date: clock.now().addingTimeInterval(-5.5 * day),
                               recordHistory: false)
        gmail.relabel(missed.id, adding: [.starred])
        let report = await rig.engine.check(reason: .schedule)
        XCTAssertEqual(report.placedDeep, [missed.id])
        let labels = await rig.store.labels(of: missed.id)
        XCTAssertEqual(labels, [.inbox, .starred])
        let placedOrder = await order(missed.id, rig)
        let olderOrder = await order(refs[14].id, rig)
        let newerOrder = await order(refs[15].id, rig)
        XCTAssertGreaterThan(try XCTUnwrap(placedOrder), try XCTUnwrap(olderOrder))
        XCTAssertLessThan(try XCTUnwrap(placedOrder), try XCTUnwrap(newerOrder))
        await rig.finish()
    }

    func testLabelChangesApplyInOrderAndTheLastWins() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let (rig, refs) = try await listedRig(gmail, clock: clock)
        gmail.relabel(refs[3].id, adding: [.unread])
        gmail.relabel(refs[3].id, removing: [.unread])
        gmail.relabel(refs[4].id, removing: [.inbox])
        gmail.relabel(refs[4].id, adding: [.inbox, .starred])
        let report = await rig.engine.check(reason: .schedule)
        XCTAssertEqual(Set(report.relabelled), [refs[3].id, refs[4].id])
        let three = await rig.store.labels(of: refs[3].id)
        let four = await rig.store.labels(of: refs[4].id)
        XCTAssertEqual(three, [.inbox])
        XCTAssertEqual(four, [.inbox, .starred])
        await rig.finish()
    }

    func testAFetchThatFailsForNowWaitsWithoutHoldingTheCursor() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let (rig, _) = try await listedRig(gmail, clock: clock)
        clock.advance(by: 30)
        let slow = gmail.add(subject: "Timed out", labels: [.inbox, .unread], date: clock.now())
        rig.transport.fail(.messagesGet, with: GoogleAPIError(kind: .temporary, detail: "timeout"))
        let first = await rig.engine.check(reason: .schedule)
        XCTAssertEqual(first.waiting, [slow.id])
        let cursor = await rig.engine.historyCursor()
        XCTAssertEqual(cursor, gmail.historyID, "one bad message never stops the cursor")
        let journaled = await rig.store.batches.last?.changes.contains(.awaitingPlacement(slow)) ?? false
        XCTAssertTrue(journaled)
        clock.advance(by: 30)
        let second = await rig.engine.check(reason: .schedule)
        XCTAssertEqual(second.placedAtTop, [slow.id])
        XCTAssertEqual(rig.events.announcedSubjects, ["Timed out"])
        await rig.finish()
    }

    func testManyAddedMessagesAreMatchedAgainstOneSearchFirst() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let (rig, _) = try await listedRig(gmail, clock: clock)
        clock.advance(by: 30)
        let fresh = (0..<3).map { gmail.add(subject: "Fresh \($0)", labels: [.inbox, .unread], date: clock.now().addingTimeInterval(Double(-$0))) }
        let old = (0..<12).map { gmail.add(subject: "Old import \($0)", labels: [.inbox], date: clock.now().addingTimeInterval(-Double(100 + $0) * day)) }
        let before = gmail.units
        let report = await rig.engine.check(reason: .schedule)
        XCTAssertEqual(Set(report.placedAtTop), Set(fresh.map(\.id)))
        XCTAssertEqual(Set(report.placedDeep), Set(old.map(\.id)))
        XCTAssertEqual(Set(rig.events.announcedSubjects), ["Fresh 0", "Fresh 1", "Fresh 2"])
        // One search for what arrived, the three fetched whole, the twelve fetched minimal and
        // each placed beside its neighbour with one search.
        let spentGets = (gmail.units[.messagesGet] ?? 0) - (before[.messagesGet] ?? 0)
        XCTAssertEqual(spentGets, 3 * 20 + 12 * 20)
        let spentLists = (gmail.units[.messagesList] ?? 0) - (before[.messagesList] ?? 0)
        XCTAssertEqual(spentLists, 5 + 12 * 5)
        await rig.finish()
    }

    func testDeepMailPackedIntoOneGapMovesItsNeighboursAndKeepsTheOrder() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let (rig, refs) = try await listedRig(gmail, count: 6, clock: clock)
        // Twenty messages received between the two oldest, whose orders are one step apart.
        let low = clock.now().addingTimeInterval(-6 * day)
        let packed = (0..<20).map { gmail.add(subject: "Between \($0)", labels: [.inbox], date: low.addingTimeInterval(Double($0 + 1) * 3_000)) }
        let report = await rig.engine.check(reason: .schedule)
        XCTAssertEqual(Set(report.placedDeep), Set(packed.map(\.id)))
        let snapshot = await rig.store.index()
        let inOrder = snapshot.byOrder.map { snapshot.records[Int($0)].gmailID }
        let byDate = ([refs[0]] + packed + Array(refs.dropFirst())).map(\.id)
        XCTAssertEqual(inOrder, byDate, "the order follows the dates after the neighbours moved up")
        await rig.finish()
    }

    // MARK: - The owner's own changes coming back (§4.6)

    func testAnEchoOfTheOwnersChangeChangesNoCount() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let (rig, refs) = try await listedRig(gmail, clock: clock)
        for ref in refs.suffix(5) { gmail.relabel(ref.id, adding: [.unread]) }
        _ = await rig.engine.check(reason: .schedule)
        func inboxUnread() async -> Int { await rig.engine.folders().first { $0.role == .inbox }?.unreadCount ?? -1 }
        let unreadBefore = await inboxUnread()
        XCTAssertEqual(unreadBefore, 5)

        let change = UUID()
        let target = refs[19].id
        await rig.engine.hold(GmailHeldChange(id: change, labels: [target: [.unread]]))
        try await rig.engine.showNow([.relabel(target, adding: [], removing: [.unread])])
        let shown = await inboxUnread()
        XCTAssertEqual(shown, 4, "the change shows at once")
        _ = try await gmail.modify(target, adding: [], removing: [.unread], work: .interactive)
        _ = await rig.engine.check(reason: .schedule)
        let afterEcho = await inboxUnread()
        XCTAssertEqual(afterEcho, 4, "its echo changes nothing")
        await rig.engine.endHold(change, sent: true)
        _ = await rig.engine.check(reason: .schedule)
        let settled = await inboxUnread()
        XCTAssertEqual(settled, 4)

        // A sent message goes in from Gmail's answer; its echo fetches nothing.
        let answer = try await gmail.send(mime("Re: plan", messageID: "<reply@example.com>", date: clock.now(), from: "owner@example.com"),
                                          threadID: nil, work: .interactive)
        try await rig.engine.placeAtTop(answer)
        let fetches = gmail.calls[.messagesGet] ?? 0
        let report = await rig.engine.check(reason: .schedule)
        XCTAssertEqual(gmail.calls[.messagesGet] ?? 0, fetches)
        XCTAssertTrue(report.placedAtTop.isEmpty && report.placedDeep.isEmpty)
        let sent = await rig.engine.folders().first { $0.role == .sent }?.totalCount
        XCTAssertEqual(sent, 1)
        await rig.finish()
    }

    func testAPhoneDeleteDuringAHeldDeleteSurvivesUndo() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let (rig, refs) = try await listedRig(gmail, clock: clock)
        let target = refs[10].id
        let change = UUID()
        await rig.engine.hold(GmailHeldChange(id: change, labels: [target: [.trash]]))
        try await rig.engine.showNow([.relabel(target, adding: [.trash], removing: [])])
        // Meanwhile the phone deletes it too, and stars it.
        gmail.relabel(target, adding: [.trash, .starred])
        _ = await rig.engine.check(reason: .schedule)
        let kept = await rig.engine.keptRecords(for: change)
        XCTAssertEqual(kept, [GmailKeptRecord(id: target, adding: [.trash], removing: [])])
        let starred = await rig.store.labels(of: target)
        XCTAssertEqual(starred, [.inbox, .trash, .starred], "what the change does not touch is applied at once")
        // The owner presses Undo: his own delete is taken back, and the phone's is not lost.
        try await rig.engine.showNow([.relabel(target, adding: [], removing: [.trash])])
        await rig.engine.endHold(change, sent: false)
        let labels = await rig.store.labels(of: target)
        XCTAssertEqual(labels, [.inbox, .trash, .starred])
        await rig.finish()
    }

    func testAListingLeavesAHeldChangeAlone() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let (rig, refs) = try await listedRig(gmail, clock: clock)
        let target = refs[12].id
        let change = UUID()
        await rig.engine.hold(GmailHeldChange(id: change, labels: [target: [.inbox]]))
        try await rig.engine.showNow([.relabel(target, adding: [], removing: [.inbox])])
        let result = try await rig.engine.relist(labels: [.label(.inbox)], allMail: false, replaceBits: true, confirmRemovals: false,
                                                 work: .background(.index))
        try await rig.store.commit(GmailJournalBatch(changes: result.changes))
        let labels = await rig.store.labels(of: target)
        XCTAssertEqual(labels, [], "the archived row does not come back while the change is on its way")
        await rig.finish()
    }

    // MARK: - Another app importing (§4.3 step 5)

    /// §14.3: a flood of 25,000 from another app, at olm2cloud's recommended 150 a minute, costs at
    /// most 40,000 units at 200,000 messages, announces none of it, and still announces real new
    /// mail that comes in meanwhile.
    func testAFloodOfImportsFromAnotherAppAt200kStaysCheapAndQuiet() async throws {
        var settings = GmailEngineSettings()
        settings.fillsCache = false
        let gmail = GmailFixtureMailbox.fixture(.large)
        let clock = ManualGmailClock(gmail.now)
        let rig = GmailEngineRig(transport: gmail, clock: clock, settings: settings)
        await rig.engine.runBackfill()
        let phase = await rig.engine.state.backfill?.phase
        XCTAssertEqual(phase, .complete)
        _ = await rig.engine.check(reason: .schedule)
        rig.events.clear()
        let target = gmail.addUserLabel(named: "Outlook/Imported")
        let before = gmail.totalUnits
        let old = gmail.now.addingTimeInterval(-3 * 365 * day)
        var imported: [GmailRef] = []
        var real: [GmailRef] = []
        var sawFloodMode = false
        var step = 0
        func tick() async {
            clock.advance(by: 30)
            _ = await rig.engine.check(reason: .schedule)
            await rig.engine.maintenance(at: clock.now())
            await rig.engine.relistTask?.value
            if gmail.isFloodMode { sawFloodMode = true }
        }
        while imported.count < 25_000 {
            let count = min(75, 25_000 - imported.count)
            let from = old.addingTimeInterval(Double(imported.count) * 600)
            imported += gmail.importFromOtherApp(count: count, datedFrom: from, to: from.addingTimeInterval(Double(count) * 600), labels: [target])
            if step % 100 == 50 { real.append(gmail.add(date: clock.now().addingTimeInterval(-2), labels: [.inbox, .unread])) }
            step += 1
            await tick()
        }
        // Half an hour with no more ends it, with one last listing.
        for _ in 0..<62 { await tick() }

        let spent = gmail.totalUnits - before
        print("flood: \(spent) units over \(step) checks")
        XCTAssertLessThanOrEqual(spent, 40_000)
        XCTAssertTrue(sawFloodMode, "FalconMail used less of the shared budget while it lasted")
        XCTAssertFalse(gmail.isFloodMode)
        let flooding = await rig.engine.flood.isActive
        XCTAssertFalse(flooding)
        XCTAssertEqual(rig.events.announced.flatMap { $0 }.compactMap(\.gmailID), real.map(\.id), "only the real new mail is announced")
        let snapshot = await rig.store.index()
        XCTAssertEqual(snapshot.byOrder.count, gmail.count)
        let unsettled = snapshot.byOrder.filter { snapshot.records[Int($0)].attributes.contains(.provisional) }.count
        XCTAssertEqual(unsettled, 0, "every imported message has its place once the flood is over")
        for ref in [imported[0], imported[12_345], imported[24_999]] {
            let slot = try XCTUnwrap(snapshot.slotByID[ref.id.raw])
            XCTAssertTrue(snapshot.record(atSlot: slot, has: target), "the imported folder's label is on its messages")
        }
        let order = snapshot.byOrder.reversed().map { snapshot.records[Int($0)].id }
        XCTAssertEqual(order, gmail.newestFirst.map(\.id.raw), "and every message is where Gmail has it")
        await rig.finish()
    }

    // MARK: - FalconMail's own imports (§9.1)

    func testFalconMailsOwnImportNeverFloodsOrAnnounces() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let (rig, _) = try await listedRig(gmail, clock: clock)
        let old = clock.now().addingTimeInterval(-400 * day)
        // One import whose echo a check sees before its answer is recorded.
        let racedID = "<raced@import.example>"
        await rig.engine.willImport(messageID: racedID)
        let raced = try await gmail.importMessage(mime("Raced", messageID: racedID, date: old), labels: [.inbox], options: GmailImportOptions(),
                                                  work: .background(.transfer))
        let during = await rig.engine.check(reason: .schedule)
        XCTAssertEqual(during.waiting, [try XCTUnwrap(raced.gmailID)], "left for the next check while the import is on its way")
        try await rig.engine.didImport(raced, messageID: racedID, date: old)
        for i in 0..<120 {
            let id = "<import\(i)@import.example>"
            await rig.engine.willImport(messageID: id)
            let answer = try await gmail.importMessage(mime("Import \(i)", messageID: id, date: old.addingTimeInterval(Double(i) * 60)),
                                                       labels: [.inbox], options: GmailImportOptions(), work: .background(.transfer))
            try await rig.engine.didImport(answer, messageID: id, date: old)
        }
        clock.advance(by: 120)
        let fetches = gmail.calls[.messagesGet] ?? 0
        let report = await rig.engine.check(reason: .schedule)
        XCTAssertFalse(report.floodBegan)
        let flooding = await rig.engine.flood.isActive
        XCTAssertFalse(flooding)
        XCTAssertFalse(gmail.isFloodMode)
        XCTAssertEqual(gmail.calls[.messagesGet] ?? 0, fetches, "their echoes fetch nothing")
        XCTAssertTrue(rig.events.announced.isEmpty)
        let snapshot = await rig.store.index()
        XCTAssertEqual(snapshot.byOrder.count, 20 + 121)
        await rig.finish()
    }

    // MARK: - When the history is too old (§4.4)

    func testAResyncConfirmsEachRemovalBeforeMakingIt() async throws {
        var settings = GmailEngineSettings()
        settings.fillsCache = false
        settings.pageSize = 10
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let (rig, refs) = try await listedRig(gmail, count: 60, clock: clock, settings: settings)
        let oldCursor = await rig.engine.historyCursor()
        let doomed = refs[40]
        gmail.delete(doomed.id)
        gmail.expireHistory()
        // While All Mail is listed again, a message above the page being read goes, so the next
        // page starts one later and one message is skipped.
        let deletedDuring = refs[55]
        let skipped = refs[49]
        var fired = false
        rig.transport.onList { query in
            if !fired, query.labels.isEmpty, query.query == nil, query.pageToken == "10", query.maxResults == 10 {
                fired = true
                gmail.delete(deletedDuring.id)
            }
        }
        let report = await rig.engine.check(reason: .schedule)
        XCTAssertTrue(report.lookedAtTop)
        let task = await rig.engine.relistTask
        await task?.value
        let batches = await rig.store.batches
        let began = batches.first { $0.changes.contains { if case .resyncBegan = $0 { return true } else { return false } } }
        XCTAssertEqual(began?.cursor, oldCursor, "the cursor does not move when the resync begins")
        let ended = try XCTUnwrap(batches.first { $0.changes.contains { if case .resyncEnded = $0 { return true } else { return false } } })
        XCTAssertTrue(ended.changes.contains(.tombstone(doomed.id)), "a confirmed removal is journaled with the end of the resync")
        XCTAssertFalse(ended.changes.contains(.tombstone(skipped.id)), "a message the listing skipped is confirmed present and kept")
        let earlier = batches.prefix { $0 != ended }.contains { $0.changes.contains(.tombstone(doomed.id)) }
        XCTAssertFalse(earlier, "nothing is removed before it is confirmed")
        let skippedRecord = await rig.store.record(for: skipped.id)
        XCTAssertFalse(try XCTUnwrap(skippedRecord).attributes.contains(.tombstone))
        // Then the history from the resync's start takes over, and removes what went meanwhile.
        _ = await rig.engine.check(reason: .schedule)
        let gone = await rig.store.record(for: deletedDuring.id)
        XCTAssertTrue(gone?.attributes.contains(.tombstone) ?? true)
        let cursor = await rig.engine.historyCursor()
        XCTAssertEqual(cursor, gmail.historyID)
        let live = await rig.store.index().byOrder.count
        XCTAssertEqual(live, 58)
        await rig.finish()
    }

    func testNewMailDuringAResyncIsStillAnnounced() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let (rig, refs) = try await listedRig(gmail, clock: clock)
        gmail.relabel(refs[0].id, adding: [.starred])
        gmail.expireHistory()
        // The listing cannot start for now.
        rig.transport.fail(.profile, with: GoogleAPIError(kind: .temporary, detail: "5xx"), times: 2)
        let first = await rig.engine.check(reason: .schedule)
        XCTAssertTrue(first.lookedAtTop)
        await rig.engine.relistTask?.value
        clock.advance(by: 30)
        let fresh = gmail.add(subject: "During the resync", labels: [.inbox, .unread], date: clock.now())
        let second = await rig.engine.check(reason: .schedule)
        XCTAssertTrue(second.lookedAtTop)
        XCTAssertEqual(second.placedAtTop, [fresh.id])
        XCTAssertEqual(rig.events.announcedSubjects, ["During the resync"])
        await rig.engine.relistTask?.value
        let third = await rig.engine.check(reason: .schedule)
        XCTAssertTrue(third.lookedAtTop)
        await rig.engine.relistTask?.value
        let resyncing = await rig.engine.resyncBegan
        XCTAssertNil(resyncing, "the resync ran once the listing could start")
        // The check the end of the resync asks for.
        _ = await rig.engine.check(reason: .schedule)
        clock.advance(by: 30)
        let after = gmail.add(subject: "After the resync", labels: [.inbox, .unread], date: clock.now())
        let fourth = await rig.engine.check(reason: .schedule)
        XCTAssertFalse(fourth.lookedAtTop)
        XCTAssertEqual(fourth.placedAtTop, [after.id])
        XCTAssertEqual(rig.events.announcedSubjects, ["During the resync", "After the resync"], "each announced once")
        await rig.finish()
    }

    func testAFullRelistingRunsAtMostEverySixHoursUnlessTheOwnerAsks() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let (rig, refs) = try await listedRig(gmail, clock: clock)
        gmail.relabel(refs[0].id, adding: [.starred])
        gmail.expireHistory()
        _ = await rig.engine.check(reason: .schedule)
        await rig.engine.relistTask?.value
        let resynced = await rig.store.batches.filter { $0.changes.contains { if case .resyncEnded = $0 { return true } else { return false } } }.count
        XCTAssertEqual(resynced, 1)
        _ = await rig.engine.check(reason: .schedule)
        clock.advance(by: 3600)
        gmail.relabel(refs[1].id, adding: [.starred])
        gmail.expireHistory()
        let waiting = await rig.engine.check(reason: .schedule)
        XCTAssertTrue(waiting.lookedAtTop)
        let started = await rig.engine.relistTask
        XCTAssertNil(started, "less than six hours after the last one, the top of All Mail is looked at instead")
        let asked = await rig.engine.check(reason: .sendAndReceive)
        XCTAssertTrue(asked.lookedAtTop)
        await rig.engine.relistTask?.value
        let again = await rig.store.batches.filter { $0.changes.contains { if case .resyncEnded = $0 { return true } else { return false } } }.count
        XCTAssertEqual(again, 2, "Send & Receive asks for one at once")
        await rig.finish()
    }

    func testALaunchThatFindsAResyncBegunStartsItAgain() async throws {
        var settings = GmailEngineSettings()
        settings.fillsCache = false
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let (rig, refs) = try await listedRig(gmail, clock: clock, settings: settings)
        gmail.relabel(refs[0].id, adding: [.starred])
        gmail.expireHistory()
        rig.transport.fail(.messagesList, with: GoogleAPIError(kind: .temporary, detail: "cut off"), times: 1)
        rig.transport.onList { query in if query.maxResults == 500 { rig.transport.fail(.messagesList, with: GoogleAPIError(kind: .temporary), times: 1) } }
        _ = await rig.engine.check(reason: .schedule)
        _ = await rig.engine.check(reason: .schedule)
        await rig.engine.relistTask?.value
        let began = await rig.engine.resyncBegan
        XCTAssertNotNil(began, "cut off part of the way")
        await rig.engine.stop()
        rig.transport.onList(nil)

        let relaunched = rig.relaunched(settings: settings)
        let load = try await relaunched.store.load()
        XCTAssertEqual(load.resyncBegan, began)
        clock.advance(by: 7 * 3600)
        _ = await relaunched.engine.check(reason: .schedule)
        await relaunched.engine.relistTask?.value
        let over = await relaunched.engine.resyncBegan
        XCTAssertNil(over)
        let cursor = await relaunched.engine.historyCursor()
        XCTAssertEqual(cursor, began)
        await relaunched.finish()
    }

    // MARK: - One check at a time

    func testAPokeDuringACheckSchedulesExactlyOneMore() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let (rig, _) = try await listedRig(gmail, clock: clock)
        rig.transport.clearLog()
        let entered = Flag()
        rig.transport.before(.historyList) {
            entered.set()
            Thread.sleep(forTimeInterval: 0.2)
        }
        let first = Task { await rig.engine.check(reason: .schedule) }
        try await eventually { entered.isSet }
        let others = (0..<3).map { _ in Task { await rig.engine.check(reason: .schedule) } }
        _ = await first.value
        for task in others { _ = await task.value }
        XCTAssertEqual(rig.transport.log.filter { $0 == .historyList }.count, 2)
        await rig.finish()
    }

    func testAQuietCheckSavesNothing() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let (rig, _) = try await listedRig(gmail, clock: clock)
        _ = await rig.engine.check(reason: .schedule)
        let batches = await rig.store.batches.count
        for _ in 0..<5 {
            clock.advance(by: 30)
            _ = await rig.engine.check(reason: .schedule)
        }
        let after = await rig.store.batches.count
        XCTAssertEqual(after, batches, "no change and no new history id writes nothing")
        XCTAssertTrue(rig.events.names.isEmpty, "a routine check with nothing to say says nothing: \(rig.events.names)")
        await rig.finish()
    }

    // MARK: - The rules, on their own

    func testTheReducerKeepsTheOrderGmailWroteIn() {
        let a = GmailRef(id: GmailMessageID(raw: 0xa0), threadID: GmailThreadID(raw: 0xa0))
        let b = GmailRef(id: GmailMessageID(raw: 0xb0), threadID: GmailThreadID(raw: 0xb0))
        let c = GmailRef(id: GmailMessageID(raw: 0xc0), threadID: GmailThreadID(raw: 0xc0))
        let d = GmailRef(id: GmailMessageID(raw: 0xd0), threadID: GmailThreadID(raw: 0xd0))
        func change(_ ref: GmailRef, _ labels: [GmailLabelID]) -> GmailLabelChange {
            GmailLabelChange(message: GmailHistoryMessage(ref: ref), labels: labels)
        }
        let records = [
            GmailHistoryRecord(id: HistoryID(raw: 1), messagesAdded: [GmailHistoryMessage(ref: a, labels: [.draft])]),
            GmailHistoryRecord(id: HistoryID(raw: 2), labelsAdded: [change(b, [.unread])]),
            GmailHistoryRecord(id: HistoryID(raw: 3), messagesDeleted: [GmailHistoryMessage(ref: a)]),
            GmailHistoryRecord(id: HistoryID(raw: 4), labelsRemoved: [change(b, [.unread])]),
            GmailHistoryRecord(id: HistoryID(raw: 5), labelsAdded: [change(c, [.starred])]),
            GmailHistoryRecord(id: HistoryID(raw: 6), messagesDeleted: [GmailHistoryMessage(ref: d)]),
        ]
        let known: Set<GmailMessageID> = [b.id, d.id]
        let reduced = GmailHistoryReducer.reduce(records) { known.contains($0) }
        XCTAssertEqual(reduced.vanished, [a])
        XCTAssertEqual(reduced.deleted, [d])
        XCTAssertEqual(reduced.relabels.count, 1)
        XCTAssertEqual(reduced.relabels.first?.id, b.id)
        XCTAssertEqual(reduced.relabels.first?.removing, [.unread])
        XCTAssertEqual(reduced.relabels.first?.adding, [])
        XCTAssertEqual(reduced.unknown, [c], "a label change on a message the index lacks places it")
        XCTAssertEqual(reduced.labelHints[c.id.raw], [.starred])
        XCTAssertEqual(reduced.labelEvents[.unread], 2)
        XCTAssertEqual(reduced.messageEvents, 3)
    }

    func testTheArrivalRule() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let lastCheck = now.addingTimeInterval(-30)
        let window = GmailArrivalRule.windowStart(lastCheckStart: lastCheck, floodBegan: nil)
        XCTAssertEqual(window, lastCheck.addingTimeInterval(-600))
        XCTAssertTrue(GmailArrivalRule.arrivedNow(internalDate: now, windowStart: window, gmailNow: now, importedByFalconMail: false))
        XCTAssertTrue(GmailArrivalRule.arrivedNow(internalDate: window, windowStart: window, gmailNow: now, importedByFalconMail: false))
        XCTAssertFalse(GmailArrivalRule.arrivedNow(internalDate: window.addingTimeInterval(-1), windowStart: window, gmailNow: now,
                                                   importedByFalconMail: false))
        XCTAssertFalse(GmailArrivalRule.arrivedNow(internalDate: now, windowStart: window, gmailNow: now, importedByFalconMail: true))
        XCTAssertTrue(GmailArrivalRule.arrivedNow(internalDate: now.addingTimeInterval(86_000), windowStart: window, gmailNow: now,
                                                  importedByFalconMail: false))
        XCTAssertFalse(GmailArrivalRule.arrivedNow(internalDate: now.addingTimeInterval(86_401), windowStart: window, gmailNow: now,
                                                   importedByFalconMail: false), "more than a day ahead is old mail")
        let flood = now.addingTimeInterval(-60)
        XCTAssertEqual(GmailArrivalRule.windowStart(lastCheckStart: lastCheck, floodBegan: flood), flood,
                       "during a flood, mail dated before it began is the import")
        let own: Set<String> = ["owner@example.com"]
        XCTAssertTrue(GmailArrivalRule.announces(labels: [.inbox], internalDate: now, from: "ana@example.com", gmailNow: now,
                                                 ownAddresses: own, muted: false))
        XCTAssertFalse(GmailArrivalRule.announces(labels: [.inbox, .spam], internalDate: now, from: "ana@example.com", gmailNow: now,
                                                  ownAddresses: own, muted: false))
        XCTAssertFalse(GmailArrivalRule.announces(labels: [.sent], internalDate: now, from: "ana@example.com", gmailNow: now,
                                                  ownAddresses: own, muted: false))
        XCTAssertFalse(GmailArrivalRule.announces(labels: [.inbox], internalDate: now, from: "Owner@Example.com", gmailNow: now,
                                                  ownAddresses: own, muted: false))
        XCTAssertFalse(GmailArrivalRule.announces(labels: [.inbox], internalDate: now, from: "ana@example.com", gmailNow: now,
                                                  ownAddresses: own, muted: true))
        XCTAssertFalse(GmailArrivalRule.announces(labels: [.inbox], internalDate: now.addingTimeInterval(-86_401), from: "ana@example.com",
                                                  gmailNow: now, ownAddresses: own, muted: false))
        XCTAssertTrue(GmailArrivalRule.runsRules(labels: [.inbox], internalDate: now.addingTimeInterval(-40 * 3600), from: "ana@example.com",
                                                 gmailNow: now, ownAddresses: own), "rules act on two days")
    }

    func testFloodModeBeginsRelistsAndEnds() {
        var flood = GmailFloodDetector()
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertNil(flood.noteDeep(50, at: t0), "50 in one check is not yet a flood")
        XCTAssertNil(flood.noteDeep(40, at: t0.addingTimeInterval(30)))
        XCTAssertNil(flood.noteDeep(40, at: t0.addingTimeInterval(60)))
        XCTAssertNil(flood.noteDeep(40, at: t0.addingTimeInterval(90)))
        XCTAssertEqual(flood.noteDeep(40, at: t0.addingTimeInterval(120)), .began, "more than 200 within ten minutes")
        XCTAssertNil(flood.tick(at: t0.addingTimeInterval(600)))
        XCTAssertEqual(flood.tick(at: t0.addingTimeInterval(120 + 1800)), .ended, "half an hour with no deep mail ends it")
        var busy = GmailFloodDetector()
        XCTAssertEqual(busy.noteDeep(51, at: t0), .began)
        for minute in stride(from: 1, through: 29, by: 1) { _ = busy.noteDeep(75, at: t0.addingTimeInterval(Double(minute) * 60)) }
        XCTAssertEqual(busy.tick(at: t0.addingTimeInterval(1800)), .relist, "every half hour while it lasts")
        XCTAssertNil(busy.tick(at: t0.addingTimeInterval(1860)))
    }

    func testTheOrderArithmetic() throws {
        XCTAssertEqual(GmailOrderSpace.top(count: 2, above: 160), [176, 192])
        XCTAssertEqual(GmailOrderSpace.between(16, 32, count: 1), [24])
        XCTAssertEqual(GmailOrderSpace.between(16, 32, count: 15)?.count, 15)
        XCTAssertNil(GmailOrderSpace.between(16, 32, count: 16))
        XCTAssertNil(GmailOrderSpace.between(16, 17, count: 1))
        // A gap used up: the fewest neighbours above move, with a full step between every one.
        let plan = try XCTUnwrap(GmailOrderSpace.renumber(above: 16, inserting: 3, neighbours: [17, 18, 400, 416], reachesTop: false, ceiling: 416))
        XCTAssertEqual(plan.inserted.count, 3)
        XCTAssertEqual(plan.moved.count, 2)
        let all = [16] + plan.inserted + plan.moved + [400]
        XCTAssertEqual(all, all.sorted())
        XCTAssertTrue(zip(all, all.dropFirst()).allSatisfy { $1 - $0 >= 16 })
        let atTop = try XCTUnwrap(GmailOrderSpace.renumber(above: 16, inserting: 2, neighbours: [17], reachesTop: true, ceiling: 17))
        XCTAssertEqual(atTop.moved.count, 1)
        XCTAssertGreaterThan(atTop.moved[0], atTop.inserted[1])
        XCTAssertNil(GmailOrderSpace.renumber(above: 16, inserting: 2, neighbours: [17, 18], reachesTop: false, ceiling: 18))
        let band = GmailOrderSpace.band(for: 200_000, above: 0)
        XCTAssertEqual(band.top, 16 * (200_000 + 20_000 + 1_000))
        let wrapped = GmailOrderSpace.band(for: 200_000, above: UInt32.max - 1_000)
        XCTAssertEqual(wrapped.top, wrapped.size, "a band that would reach the top starts again from the bottom")
    }
}

/// A flag set from any thread.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
