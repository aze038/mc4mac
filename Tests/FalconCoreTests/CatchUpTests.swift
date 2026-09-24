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
        let inbox = try await h.folder("INBOX")
        XCTAssertEqual(inbox.lastSyncedUID, 25_010)
    }

    func testAPassCutShortFetchesNothingStoredAgain() async throws {
        let server = try EngineHarness.gmailServer()
        for n in 1...10 { server.add(FakeIMAPServer.message("before-\(n)"), to: "INBOX") }
        let h = try await started(server, pacing: catchingUp)
        server.addMany(3_000, to: "INBOX") { FakeIMAPServer.message("new-\($0)", body: "New \($0).") }
        server.resetCounters()
        // The eighth header fetch of the first pass is its last: the link drops after it.
        server.cutAfter("UID FETCH", count: 8)
        await h.syncer.start()
        await assertEventually(within: 30) { ((try? await h.uids(in: "INBOX")) ?? []).count == 3_010 }

        let fetched = FakeIMAPServer.headerFetchUIDs(server.exchanges)
        XCTAssertEqual(Set(fetched).count, 3_000)
        XCTAssertEqual(fetched.count, 3_000, "nothing stored before the drop was fetched again")
        XCTAssertGreaterThanOrEqual(server.loginCount, 3, "the pass was cut and the loop connected again")
        let inbox = try await h.folder("INBOX")
        XCTAssertEqual(inbox.lastSyncedUID, 3_010)
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
