import XCTest
@testable import FalconCore

/// A flood of new mail is taken newest first, a bounded number a pass and one pass at a time,
/// without gaps or fetching anything twice; old mail arriving now, as an import brings, runs no
/// rules and makes no noise, and neither does mail the owner sent.
final class CatchUpTests: XCTestCase {
    private var harness: EngineHarness?

    override func tearDown() async throws {
        await harness?.finish()
    }

    private func started(_ server: FakeIMAPServer, pacing: SyncPacing) async throws -> EngineHarness {
        let h = try await EngineHarness(server: server, pacing: pacing)
        harness = h
        try await h.syncOnce()
        return h
    }

    private var catchingUp: SyncPacing {
        var pacing = SyncPacing()
        pacing.catchUpInterval = 0.25
        pacing.fullSyncInterval = 3600
        pacing.minimumReconnectInterval = 0.05
        return pacing
    }

    /// The passes of a catch-up, told apart by the search that begins each.
    private func passes(_ exchanges: [FakeIMAPServer.Exchange]) -> [[FakeIMAPServer.Exchange]] {
        var out: [[FakeIMAPServer.Exchange]] = []
        for e in exchanges {
            if e.line.contains("UID SEARCH UID ") { out.append([]) }
            if !out.isEmpty { out[out.count - 1].append(e) }
        }
        return out
    }

    func testAFloodOf25kNewMessagesArrivesWholeNewestFirst() async throws {
        let server = try EngineHarness.gmailServer()
        for n in 1...10 { server.add(FakeIMAPServer.message("before-\(n)"), to: "INBOX") }
        let h = try await started(server, pacing: catchingUp)
        server.addMany(25_000, to: "INBOX") { FakeIMAPServer.message("flood-\($0)", body: "Flood \($0).") }
        server.resetCounters()
        await h.syncer.start()
        await assertEventually(within: 120) { ((try? await h.uids(in: "INBOX")) ?? []).count == 25_010 }
        // The pass that stored the last batch moves the cursor over it just after.
        await assertEventually("the cursor reached the newest message") { await self.cursor(h) == 25_010 }

        let fetched = FakeIMAPServer.headerFetchUIDs(server.exchanges)
        XCTAssertEqual(fetched.count, 25_000, "every new message fetched once")
        XCTAssertEqual(Set(fetched).count, 25_000, "and none twice")
        let headerFetches = server.exchanges.filter { $0.line.contains("HEADER.FIELDS") }
        XCTAssertEqual(FakeIMAPServer.headerFetchUIDs(Array(headerFetches.prefix(1))).max(), 25_010, "the newest first")
        let rounds = passes(server.exchanges).map { $0.filter { $0.line.contains("HEADER.FIELDS") } }.filter { !$0.isEmpty }
        XCTAssertGreaterThanOrEqual(rounds.count, 13)
        for round in rounds {
            XCTAssertLessThanOrEqual(FakeIMAPServer.headerFetchUIDs(round).count, 2_000, "at most 2,000 a pass")
        }
        for (earlier, later) in zip(rounds, rounds.dropFirst()) {
            let gap = later[0].at.timeIntervalSince(earlier.last!.at)
            XCTAssertGreaterThanOrEqual(gap, 0.2, "one pass per catch-up interval")
        }
    }

    /// Where INBOX's cursor stands. A pass stores each batch before it moves and saves the
    /// cursor over it, so a test that has seen the rows waits for the cursor too.
    private func cursor(_ h: EngineHarness) async -> UInt32 {
        (try? await h.folder("INBOX").lastSyncedUID) ?? 0
    }

    func testACatchUpAlreadyDueWhenAPassEndsGoesOnAtOnce() async throws {
        let server = try EngineHarness.gmailServer()
        for n in 1...10 { server.add(FakeIMAPServer.message("before-\(n)"), to: "INBOX") }
        // Every pass takes longer than the catch-up interval, so each ends with the next due;
        // nothing else would end the IDLE in between, neither new mail nor its refresh.
        var pacing = catchingUp
        pacing.catchUpInterval = 0.001
        pacing.idleRefresh = 3600
        let h = try await started(server, pacing: pacing)
        server.addMany(5_000, to: "INBOX") { FakeIMAPServer.message("flood-\($0)", body: "Flood \($0).") }
        server.resetCounters()
        await h.syncer.start()
        await assertEventually("the rest of the flood did not wait for new mail", within: 30) {
            ((try? await h.uids(in: "INBOX")) ?? []).count == 5_010
        }
        let fetched = FakeIMAPServer.headerFetchUIDs(server.exchanges)
        XCTAssertEqual(fetched.count, 5_000, "every new message fetched once")
        XCTAssertEqual(Set(fetched).count, 5_000, "and none twice")
    }

    func testAPassCutShortFetchesNothingStoredAgain() async throws {
        try await passCutShort(catchUpInterval: catchingUp.catchUpInterval)
    }

    func testAPassCutShortWithItsCatchUpDueAtOnceFetchesNothingStoredAgain() async throws {
        try await passCutShort(catchUpInterval: 0.001)
    }

    private func passCutShort(catchUpInterval: TimeInterval, file: StaticString = #filePath, line: UInt = #line) async throws {
        let server = try EngineHarness.gmailServer()
        for n in 1...10 { server.add(FakeIMAPServer.message("before-\(n)"), to: "INBOX") }
        var pacing = catchingUp
        pacing.catchUpInterval = catchUpInterval
        let h = try await started(server, pacing: pacing)
        server.addMany(3_000, to: "INBOX") { FakeIMAPServer.message("new-\($0)", body: "New \($0).") }
        server.resetCounters()
        // The eighth header fetch of the first pass is its last: the link drops after it.
        server.cutAfter("UID FETCH", count: 8)
        await h.syncer.start()
        await assertEventually(within: 30, file: file, line: line) { ((try? await h.uids(in: "INBOX")) ?? []).count == 3_010 }
        await assertEventually("the cursor reached the newest message", file: file, line: line) { await self.cursor(h) == 3_010 }

        let fetched = FakeIMAPServer.headerFetchUIDs(server.exchanges)
        XCTAssertEqual(Set(fetched).count, 3_000, file: file, line: line)
        XCTAssertEqual(fetched.count, 3_000, "nothing stored before the drop was fetched again", file: file, line: line)
        XCTAssertGreaterThanOrEqual(server.loginCount, 3, "the pass was cut and the loop connected again", file: file, line: line)
    }

    func testTheCursorMovesOnlyOverStoredMessagesAndIsSavedEachBatch() async throws {
        let server = try EngineHarness.gmailServer()
        for n in 1...10 { server.add(FakeIMAPServer.message("before-\(n)"), to: "INBOX") }
        var pacing = catchingUp
        pacing.catchUpInterval = 3600
        let h = try await started(server, pacing: pacing)
        server.addMany(2_500, to: "INBOX") { FakeIMAPServer.message("new-\($0)", body: "New \($0).") }
        try await h.syncOnce()
        let stored = try await h.uids(in: "INBOX")
        XCTAssertEqual(stored.count, 2_010)
        XCTAssertTrue(stored.contains(2_510) && !stored.contains(510), "the newest 2,000 were taken")
        let inbox = try await h.folder("INBOX")
        XCTAssertEqual(inbox.lastSyncedUID, 10, "the gap below them keeps the cursor where an earlier build would look again")
    }

    func testAFirstPassCutShortAndTakenAgainLeavesNoGap() async throws {
        let server = try EngineHarness.gmailServer()
        server.addMany(1_500, to: "INBOX") { FakeIMAPServer.message("m\($0)", body: "Message \($0).") }
        let h = try await EngineHarness(server: server)
        harness = h
        // The third batch of the newest thousand is the last before the link drops.
        server.cutAfter("UID FETCH", count: 3)
        do {
            try await h.syncOnce()
            XCTFail("the pass was cut short")
        } catch {}
        let cut = try await h.folder("INBOX")
        XCTAssertEqual(cut.lastSyncedUID, 0)
        XCTAssertEqual(cut.oldestSyncedUID, 501)
        let partial = try await h.uids(in: "INBOX")
        XCTAssertEqual(partial.count, 300)

        // Mail arrives before the pass is taken again, pushing the newest thousand up.
        server.addMany(50, to: "INBOX") { FakeIMAPServer.message("late\($0)", body: "Late \($0).") }
        try await h.syncOnce()
        let resumed = try await h.uids(in: "INBOX")
        XCTAssertEqual(resumed, Set(UInt32(501)...1_550), "nothing between where the two windows began is skipped")
        let inbox = try await h.folder("INBOX")
        XCTAssertEqual(inbox.oldestSyncedUID, 501)
        XCTAssertEqual(inbox.lastSyncedUID, 1_550)
        try await h.syncer.loadOlder(folder: inbox, count: 2_000)
        let all = try await h.uids(in: "INBOX")
        XCTAssertEqual(all, Set(UInt32(1)...1_550))
    }

    func testAMessageGoneBeforeItsHeadersCameHoldsUpNothing() async throws {
        let server = try EngineHarness.gmailServer()
        server.add(FakeIMAPServer.message("before"), to: "INBOX")
        var pacing = SyncPacing()
        pacing.fullSyncInterval = 3600
        let h = try await started(server, pacing: pacing)
        await h.syncer.start()
        await assertEventually { server.idlingCount == 1 }
        server.resetCounters()
        server.stallNext("UID FETCH", seconds: 0.5)
        let moved = server.deliver(FakeIMAPServer.message("moved", date: Date()), to: "INBOX")
        // Another client files it elsewhere while its headers are on their way.
        await assertEventually { server.commands.contains { $0.contains("HEADER.FIELDS") } }
        server.remove(uid: moved, from: "INBOX")
        await assertEventually { server.idlingCount == 1 }
        server.deliver(FakeIMAPServer.message("next", date: Date()), to: "INBOX")
        await assertEventually("the next message is not held back as if a backlog were waiting") {
            ((try? await h.uids(in: "INBOX")) ?? []).count == 2
        }
    }

    // MARK: - A backlog held back

    private func finishedCount(_ h: EngineHarness) async -> Int {
        await h.events.all.filter { if case .finished = $0 { return true }; return false }.count
    }

    private func checkAnswers(_ h: EngineHarness) async -> [Bool] {
        await h.events.all.compactMap { if case .checked(_, let found) = $0 { return found }; return nil }
    }

    /// Asks for a whole pass and waits until it is over and the loop idles again.
    private func passRuns(_ h: EngineHarness, check: Bool = false) async {
        let before = await finishedCount(h)
        await h.syncer.requestSync(check: check)
        await assertEventually { await self.finishedCount(h) > before && h.server.idlingCount == 1 }
        await h.settled()
    }

    /// Thirty old messages stored in INBOX, the loop idling, and then `bulk` more that another
    /// program files there at once: a pass takes the newest 35 and holds the rest back for the
    /// catch-up interval, an hour here.
    private func heldBack(bulk count: Int = 105) async throws -> (h: EngineHarness, old: Set<UInt32>, taken: Set<UInt32>, held: [UInt32]) {
        var pacing = SyncPacing()
        pacing.catchUpWindow = 35
        pacing.catchUpInterval = 3600
        pacing.fullSyncInterval = 3600
        pacing.idleRefresh = 3600
        pacing.minimumReconnectInterval = 0.05
        let server = try EngineHarness.gmailServer()
        let old = server.addMany(30, to: "INBOX") { FakeIMAPServer.message("old-\($0)") }
        let h = try await EngineHarness(server: server, pacing: pacing)
        harness = h
        await h.syncer.start()
        await assertEventually { await self.finishedCount(h) == 1 && server.idlingCount == 1 }
        let bulk = server.addMany(count, to: "INBOX") { FakeIMAPServer.message("bulk-\($0)") }
        await passRuns(h)
        let stored = try await h.uids(in: "INBOX")
        XCTAssertEqual(stored, Set(old + bulk.suffix(35)), "the newest 35 are taken and the rest held back")
        return (h, Set(old), Set(bulk.suffix(35)), Array(bulk.dropLast(35)))
    }

    func testABacklogThatLeavesTheInboxDuringItsHoldTakesNoRowsForAFlagReplyThatListsNothing() async throws {
        let (h, old, taken, held) = try await heldBack()
        // Another program takes the 70 held back out of INBOX while they wait.
        for uid in held { h.server.remove(uid: uid, from: "INBOX") }
        // A pass during the hold, when the server loses track of INBOX for one flag fetch.
        h.server.emptyNextFlagFetches(1)
        await passRuns(h)
        let stored = try await h.uids(in: "INBOX")
        XCTAssertEqual(old.subtracting(stored), [], "no row below the cursor, which nothing would fetch again, is taken off")
        XCTAssertEqual(stored, old.union(taken), "nor any other, for a flag reply that listed nothing")
        XCTAssertEqual(h.server.messages(in: "INBOX").count, 65, "and nothing on the server was touched")

        // Nothing is held back any more, so mail that arrives now is fetched at once.
        let next = h.server.deliver(FakeIMAPServer.message("next", date: Date()), to: "INBOX")
        await assertEventually("the hold ended with its backlog") { ((try? await h.uids(in: "INBOX")) ?? []).contains(next) }
    }

    func testABacklogPartlyGoneDuringItsHoldCountsOnlyWhatIsLeft() async throws {
        let (h, old, taken, held) = try await heldBack()
        // Sixty of the seventy leave INBOX; ten still wait.
        for uid in held.prefix(60) { h.server.remove(uid: uid, from: "INBOX") }
        h.server.resetCounters()
        h.server.emptyNextFlagFetches(1)
        await passRuns(h)
        let stored = try await h.uids(in: "INBOX")
        XCTAssertEqual(stored, old.union(taken), "no row is taken off for a flag reply that listed nothing")
        let searches = h.server.commands.filter { $0.contains("UID SEARCH UID ") }
        XCTAssertEqual(searches.count, 1, "the backlog is listed again with one search: \(searches)")
        XCTAssertTrue(FakeIMAPServer.headerFetchUIDs(h.server.exchanges).isEmpty, "and nothing of it is fetched during the hold")

        // Asked, the pass says mail is on its way: the ten still wait.
        await passRuns(h, check: true)
        let answers = await checkAnswers(h)
        XCTAssertEqual(answers, [true])
        let after = try await h.uids(in: "INBOX")
        XCTAssertEqual(after, old.union(taken))
    }

    func testACheckDuringAHoldWhoseBacklogLeftTheInboxTakesNoRowsForAFlagReplyThatListsNothing() async throws {
        let (h, old, taken, held) = try await heldBack()
        for uid in held { h.server.remove(uid: uid, from: "INBOX") }
        // Send & Receive for a message the owner is waiting for, and the server loses track of
        // INBOX for one flag fetch.
        let urgent = h.server.add(FakeIMAPServer.message("urgent", date: Date()), to: "INBOX")
        h.server.emptyNextFlagFetches(1)
        await passRuns(h, check: true)
        let stored = try await h.uids(in: "INBOX")
        XCTAssertEqual(old.subtracting(stored), [], "no row below the cursor is taken off")
        XCTAssertEqual(stored, old.union(taken).union([urgent]), "the one asked for joins every row already there")
        let answers = await checkAnswers(h)
        XCTAssertEqual(answers, [true])
        XCTAssertEqual(h.server.messages(in: "INBOX").count, 66, "and nothing on the server was touched")
    }

    func testACheckDuringAHoldWhileMailArrivesAfterItsCountTakesNoRowsForAFlagReplyThatListsNothing() async throws {
        let (h, old, taken, _) = try await heldBack()
        // Two hundred more arrive just after the pass has counted INBOX, before its search.
        let server = h.server
        server.beforeAnswering("UID SEARCH") {
            server.addMany(200, to: "INBOX") { FakeIMAPServer.message("late-\($0)", date: Date()) }
        }
        server.emptyNextFlagFetches(1)
        await passRuns(h, check: true)
        let stored = try await h.uids(in: "INBOX")
        XCTAssertEqual(old.subtracting(stored), [], "no row below the cursor is taken off")
        XCTAssertTrue(taken.isSubset(of: stored), "nor any the catch-up took")
        XCTAssertEqual(stored.count, 30 + 35 + 35, "and the newest 35 that arrived join them")
        XCTAssertEqual(server.messages(in: "INBOX").count, 335, "nothing on the server was touched")
    }

    func testACheckThatTakesTheWholeBacklogEndsTheHold() async throws {
        let (h, old, taken, held) = try await heldBack(bulk: 45)
        XCTAssertEqual(held.count, 10)
        // The 35 taken leave INBOX and a pass drops them: the newest stored is now below the ten
        // held back.
        for uid in taken { h.server.remove(uid: uid, from: "INBOX") }
        await passRuns(h)
        var stored = try await h.uids(in: "INBOX")
        XCTAssertEqual(stored, old)

        // Send & Receive takes the ten with the message asked for, all in one window.
        let urgent = h.server.add(FakeIMAPServer.message("urgent", date: Date()), to: "INBOX")
        await passRuns(h, check: true)
        stored = try await h.uids(in: "INBOX")
        XCTAssertEqual(stored, old.union(held).union([urgent]))
        let answers = await checkAnswers(h)
        XCTAssertEqual(answers, [true])

        // Nothing is held back any more, so mail that arrives now is fetched at once.
        let next = h.server.deliver(FakeIMAPServer.message("next", date: Date()), to: "INBOX")
        await assertEventually("a hold with nothing left to fetch was ended") {
            ((try? await h.uids(in: "INBOX")) ?? []).contains(next)
        }
    }

    func testASearchDuringAHoldThatListsNothingTakesNoRowsAndLosesNoBacklog() async throws {
        let (h, old, taken, held) = try await heldBack()
        // A pass and then a check during the hold, each meeting a server that lists nothing for
        // one search and one flag fetch, while the backlog is still there.
        h.server.emptyNextSearches(1)
        h.server.emptyNextFlagFetches(1)
        await passRuns(h)
        var stored = try await h.uids(in: "INBOX")
        XCTAssertEqual(stored, old.union(taken), "no row is taken off")

        h.server.emptyNextSearches(1)
        h.server.emptyNextFlagFetches(1)
        await passRuns(h, check: true)
        stored = try await h.uids(in: "INBOX")
        XCTAssertEqual(stored, old.union(taken), "no row is taken off, and the backlog still waits for its turn")
        let answers = await checkAnswers(h)
        XCTAssertEqual(answers, [true], "mail is still on its way")
        let cursor = try await h.folder("INBOX").lastSyncedUID
        XCTAssertLessThan(cursor, held[0], "the cursor stays below the backlog, so the pass after the hold lists it again")
    }

    // MARK: - Mail a cut pass stored

    func testMailStoredByAPassCutBeforeItsAnnouncementIsAnnouncedByTheNextOnce() async throws {
        let server = try EngineHarness.gmailServer()
        server.add(FakeIMAPServer.message("before"), to: "INBOX")
        var pacing = SyncPacing()
        pacing.fullSyncInterval = 3600
        pacing.idleRefresh = 3600
        pacing.minimumReconnectInterval = 0.05
        let h = try await started(server, pacing: pacing)
        try await h.rules.save([RuleDefinition(name: "Flag Ana's", conditions: [RuleCondition(field: .subject, op: .contains, value: "theirs")],
                                               actions: [RuleAction(kind: .flag)])])
        await h.syncer.start()
        await assertEventually { await self.finishedCount(h) == 1 && server.idlingCount == 1 }
        // Stored without a word to the idling connection: news, an old message, and one the
        // owner sent.
        let theirs = server.add(FakeIMAPServer.message("theirs", date: Date()), to: "INBOX")
        server.add(FakeIMAPServer.message("old", date: Date().addingTimeInterval(-3 * 24 * 3600)), to: "INBOX")
        server.add(FakeIMAPServer.message("mine", from: "Owner <owner@example.com>", date: Date()), to: "INBOX")
        server.resetCounters()
        // A whole pass stores them and loses its connection at its next command, before it
        // announces them.
        server.cutAfter("UID FETCH", count: 1)
        let logins = server.loginCount
        await h.syncer.requestSync()
        await assertEventually { await self.finishedCount(h) >= 2 && server.loginCount > logins && server.idlingCount == 1 }
        await h.settled()
        let stored = try await h.uids(in: "INBOX")
        XCTAssertEqual(stored.count, 4)
        var told = await h.events.announced.map(\.messageID)
        XCTAssertEqual(told, ["<theirs@example.com>"], "the pass after announces what is news, and neither old mail nor the owner's own")
        let flagged = try await h.message(uid: theirs, in: "INBOX")
        XCTAssertTrue(flagged.isFlagged, "the rule the cut pass never got to has run")

        await passRuns(h)
        told = await h.events.announced.map(\.messageID)
        XCTAssertEqual(told, ["<theirs@example.com>"], "once")
        let stores = server.commands.filter { $0.contains("UID STORE") }
        XCTAssertEqual(stores.count, 1, "the rule ran once: \(stores)")
    }

    func testMailInAMutedConversationStoredByAPassCutBeforeItsMutesRanIsFiledByTheNextUnannounced() async throws {
        let server = try EngineHarness.gmailServer()
        server.add(FakeIMAPServer.message("before"), to: "INBOX")
        var pacing = SyncPacing()
        pacing.fullSyncInterval = 3600
        pacing.idleRefresh = 3600
        pacing.minimumReconnectInterval = 0.05
        let h = try await started(server, pacing: pacing)
        // The owner muted the conversation that a message about to arrive belongs to.
        await MuteStore(layout: h.layout).mute(MutedThread(accountID: h.account.id, threadKey: "<muted-root@example.com>",
                                                           messageIDs: ["<muted-root@example.com>", "<muted@example.com>"],
                                                           normalizedSubject: "lunch", subject: "Lunch"))
        await h.syncer.start()
        await assertEventually { await self.finishedCount(h) == 1 && server.idlingCount == 1 }
        // A hundred and fifty old messages, then the muted conversation's latest and one that is
        // news, all stored without a word to the idling connection.
        server.addMany(150, to: "INBOX") { FakeIMAPServer.message("old-\($0)") }
        let muted = server.add(FakeIMAPServer.message("muted", date: Date()), to: "INBOX")
        server.add(FakeIMAPServer.message("news", date: Date()), to: "INBOX")
        // The pass stores the newest hundred and loses its connection fetching the rest, before
        // its mutes, rules or announcement.
        server.cutAfter("UID FETCH", count: 1)
        let logins = server.loginCount
        await h.syncer.requestSync()
        await assertEventually { await self.finishedCount(h) >= 2 && server.loginCount > logins && server.idlingCount == 1 }
        await h.settled()

        let told = await h.events.announced.map(\.messageID)
        XCTAssertEqual(told, ["<news@example.com>"], "the muted conversation's message is not announced")
        let stored = try await h.uids(in: "INBOX")
        XCTAssertEqual(stored.count, 152, "everything but the muted message is here")
        XCTAssertFalse(stored.contains(muted))
        XCTAssertFalse(server.messages(in: "INBOX").contains { $0.uid == muted }, "it was filed away, as the cut pass would have")
    }

    /// A message from an old mailbox, with no Date header or one in `date`'s words.
    private func undated(_ tag: String, date: String? = nil) -> Data {
        Data(("From: ana@example.com\r\nTo: owner@example.com\r\nSubject: Message \(tag)\r\n" + (date.map { "Date: \($0)\r\n" } ?? "")
              + "Message-ID: <\(tag)@example.com>\r\n\r\nFrom an old mailbox.\r\n").utf8)
    }

    func testOldMailWithoutADateThatCanBeReadIsNotTakenForNew() async throws {
        let server = try EngineHarness.gmailServer()
        server.add(FakeIMAPServer.message("before"), to: "INBOX")
        let h = try await started(server, pacing: catchingUp)
        try await h.rules.save([RuleDefinition(name: "Flag everything", conditions: [RuleCondition(field: .subject, op: .contains, value: "Message")],
                                               actions: [RuleAction(kind: .flag)])])
        let longAgo = Date(timeIntervalSince1970: 1_080_000_000)
        for n in 1...20 { server.add(undated("undated-\(n)"), to: "INBOX", date: longAgo) }
        for n in 1...5 { server.add(undated("asctime-\(n)", date: "Tue Mar 18 10:03:20 2003"), to: "INBOX", date: longAgo) }
        server.add(FakeIMAPServer.message("today", date: Date()), to: "INBOX")
        try await h.syncOnce()
        let rows = try await h.uids(in: "INBOX")
        XCTAssertEqual(rows.count, 27)
        // Every announcement of the pass was given before it returned.
        await h.settled()
        let told = await h.events.announced.map(\.messageID)
        XCTAssertEqual(told, ["<today@example.com>"], "no notification or sound for old mail without a date")
        XCTAssertEqual(server.commands.filter { $0.contains("UID STORE") }.count, 1, "the rule ran on today's message alone")
        let dated = try await h.message(uid: 2, in: "INBOX")
        XCTAssertEqual(dated.date.timeIntervalSince1970, longAgo.timeIntervalSince1970, accuracy: 1, "dated when the server received it")
    }

    func testAnImportOf24kOldMessagesRunsNoRulesAndMakesNoNoise() async throws {
        let server = try EngineHarness.gmailServer()
        for n in 1...5 { server.add(FakeIMAPServer.message("before-\(n)"), to: "INBOX") }
        let h = try await started(server, pacing: catchingUp)
        try await h.rules.save([RuleDefinition(name: "Flag everything", conditions: [RuleCondition(field: .subject, op: .contains, value: "Message")],
                                               actions: [RuleAction(kind: .flag)])])
        let longAgo = Date(timeIntervalSince1970: 1_600_000_000)
        server.addMany(24_000, to: "INBOX", date: longAgo) { FakeIMAPServer.message("old-\($0)", date: longAgo, body: "Old \($0).") }
        server.resetCounters()
        await h.syncer.start()
        await assertEventually(within: 120) { ((try? await h.uids(in: "INBOX")) ?? []).count == 24_005 }
        // The pass that stored the last of them is over once the loop idles again, and every
        // announcement and rule of it has been given.
        await assertEventually { server.idlingCount == 1 }
        await h.settled()

        XCTAssertFalse(server.commands.contains { $0.contains("UID STORE") || $0.contains("UID MOVE") }, "no rule ran")
        let announced = await h.events.announced
        XCTAssertTrue(announced.isEmpty, "no notification for old mail")

        // Mail sent now still gets both.
        server.deliver(FakeIMAPServer.message("today", date: Date()), to: "INBOX")
        await assertEventually { await !h.events.announced.isEmpty }
        let told = await h.events.announced.map(\.messageID)
        XCTAssertEqual(told, ["<today@example.com>"])
        await assertEventually { server.commands.filter { $0.contains("UID STORE") }.count == 1 }
    }

    func testMailFromTheAccountItselfIsNotAnnounced() async throws {
        let server = try EngineHarness.gmailServer()
        server.add(FakeIMAPServer.message("before"), to: "INBOX")
        var pacing = SyncPacing()
        pacing.fullSyncInterval = 3600
        let h = try await started(server, pacing: pacing)
        await h.syncer.start()
        await assertEventually { server.idlingCount == 1 }
        server.addMany(1, to: "INBOX") { _ in FakeIMAPServer.message("mine", from: "Owner <owner@example.com>", date: Date()) }
        server.addMany(1, to: "INBOX") { _ in FakeIMAPServer.message("mine-too", from: "OWNER@Example.com", date: Date()) }
        server.deliver(FakeIMAPServer.message("theirs", from: "ana@example.com", date: Date()), to: "INBOX")
        await assertEventually { ((try? await h.uids(in: "INBOX")) ?? []).count == 4 }
        await assertEventually { await !h.events.announced.isEmpty }
        try await Task.sleep(nanoseconds: 200_000_000)
        let told = await h.events.announced.map(\.messageID)
        XCTAssertEqual(told, ["<theirs@example.com>"], "a message from the account's own address brings no notification or sound")
    }
}
