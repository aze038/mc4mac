import XCTest
@testable import FalconCore

/// A pass asks for few flags: with CONDSTORE only those changed, without it the newest and one
/// slice of older messages. Nothing it did not look at is taken for gone.
final class FlagRescanTests: XCTestCase {
    private var harness: EngineHarness?

    override func tearDown() async throws {
        await harness?.finish()
    }

    /// An account whose INBOX holds `count` messages, all listed by a first pass.
    private func listed(_ count: Int, capabilities: [String]? = nil, root: URL? = nil) async throws -> EngineHarness {
        let server = try EngineHarness.gmailServer(capabilities: capabilities)
        server.addMany(count, to: "INBOX") { FakeIMAPServer.message("m\($0)", body: "Message \($0).") }
        var pacing = SyncPacing()
        pacing.initialWindow = count
        pacing.catchUpWindow = count
        let h = try await EngineHarness(server: server, root: root, pacing: pacing)
        harness = h
        try await h.syncOnce()
        let stored = try await h.uids(in: "INBOX")
        XCTAssertEqual(stored.count, count)
        server.resetCounters()
        return h
    }

    private func flagFetches(_ server: FakeIMAPServer) -> [FakeIMAPServer.Exchange] {
        server.exchanges.filter { $0.line.contains("(UID FLAGS)") }
    }

    func testTheFlagsAPassAsksForStayBounded() async throws {
        let h = try await listed(5_000)
        for pass in 1...4 {
            h.server.resetCounters()
            try await h.syncOnce()
            let fetches = flagFetches(h.server)
            XCTAssertEqual(fetches.count, 2, "pass \(pass): the newest and one older slice")
            let bytes = fetches.reduce(0) { $0 + $1.replyBytes }
            XCTAssertLessThanOrEqual(bytes, 2_000 * 51, "pass \(pass): at most 2,000 flag lines, not all 5,000")
        }
        let rows = try await h.uids(in: "INBOX")
        XCTAssertEqual(rows.count, 5_000)
    }

    func testARescanOfAThousandDeletesNoRowBelowItsBound() async throws {
        let h = try await listed(3_000)
        // The first pass looked at 2001–3000 and 1001–2000; each after it at the newest and the
        // next older slice, and never takes a row it did not look at for gone.
        for slice in ["1:1000", "1001:2000", "1:1000"] {
            h.server.resetCounters()
            try await h.syncOnce()
            let fetches = flagFetches(h.server).map(\.line)
            XCTAssertEqual(fetches.count, 2, "\(fetches)")
            XCTAssertTrue(fetches.contains { $0.contains("UID FETCH 2001:3000 ") }, "\(fetches)")
            XCTAssertTrue(fetches.contains { $0.contains("UID FETCH \(slice) ") }, "\(fetches)")
            let rows = try await h.uids(in: "INBOX")
            XCTAssertEqual(rows.count, 3_000, "rows outside the slice were not looked at, and are kept")
            XCTAssertFalse(h.server.commands.contains { $0.contains("SEARCH ALL") }, "the counts agree, so nothing is searched")
        }
    }

    func testAnOldMessageChangedOrDeletedElsewhereIsSeenWithinOneRotation() async throws {
        let h = try await listed(3_000)
        h.server.setFlags(["\\Seen"], uid: 10, in: "INBOX")
        h.server.remove(uid: 20, from: "INBOX")
        try await h.syncOnce()
        let rows = try await h.uids(in: "INBOX")
        XCTAssertFalse(rows.contains(20), "the server holds one message fewer, so a search finds which")
        try await h.syncOnce()
        let read = try await h.message(uid: 10, in: "INBOX")
        XCTAssertTrue(read.isRead, "the older slices have all been looked at")
        let kept = try await h.uids(in: "INBOX")
        XCTAssertEqual(kept.count, 2_999)
    }

    func testARecentDeletionNeedsNoSearch() async throws {
        let h = try await listed(3_000)
        h.server.remove(uid: 2_990, from: "INBOX")
        try await h.syncOnce()
        let rows = try await h.uids(in: "INBOX")
        XCTAssertFalse(rows.contains(2_990))
        XCTAssertFalse(h.server.commands.contains { $0.contains("SEARCH ALL") }, "the newest were looked at, so the counts agree")
    }

    func testWithCondstoreOnlyChangedFlagsComeBack() async throws {
        let h = try await listed(3_000, capabilities: ["IMAP4rev1", "AUTH=PLAIN", "IDLE", "MOVE", "UIDPLUS", "SPECIAL-USE", "CONDSTORE", "ESEARCH"])
        try await h.syncOnce()
        XCTAssertTrue(flagFetches(h.server).isEmpty, "nothing changed, so no flag is asked for")

        h.server.resetCounters()
        h.server.setFlags(["\\Flagged"], uid: 5, in: "INBOX")
        try await h.syncOnce()
        let fetches = flagFetches(h.server)
        XCTAssertEqual(fetches.count, 1)
        XCTAssertTrue(fetches.first?.line.contains("CHANGEDSINCE") ?? false)
        XCTAssertLessThan(fetches.first?.replyBytes ?? .max, 200, "one line, for the one message changed")
        let flagged = try await h.message(uid: 5, in: "INBOX")
        XCTAssertTrue(flagged.isFlagged)

        h.server.resetCounters()
        h.server.remove(uid: 7, from: "INBOX")
        try await h.syncOnce()
        let rows = try await h.uids(in: "INBOX")
        XCTAssertFalse(rows.contains(7))
        let searches = h.server.exchanges.filter { $0.line.contains("UID SEARCH") }
        XCTAssertTrue(searches.allSatisfy { $0.line.contains("RETURN (ALL)") }, "searches use ESEARCH where offered")
        XCTAssertLessThan(searches.reduce(0) { $0 + $1.replyBytes }, 400, "a compact set, not three thousand numbers")
    }

    func testIdleWakesFetchOnlyNewMessages() async throws {
        let server = try EngineHarness.gmailServer()
        for n in 1...5 { server.add(FakeIMAPServer.message("m\(n)"), to: "INBOX") }
        var pacing = SyncPacing()
        pacing.fullSyncInterval = 3600
        let h = try await EngineHarness(server: server, pacing: pacing)
        harness = h
        await h.syncer.start()
        await assertEventually { server.idlingCount == 1 }
        server.resetCounters()
        server.deliver(FakeIMAPServer.message("new"), to: "INBOX")
        await assertEventually { ((try? await h.uids(in: "INBOX")) ?? []).count == 6 }
        await assertEventually { server.idlingCount == 1 }
        XCTAssertTrue(server.commands.contains { $0.contains("HEADER.FIELDS") })
        XCTAssertFalse(server.commands.contains { $0.contains("(UID FLAGS)") }, "no flag rescan for a wake-up")
        XCTAssertFalse(server.commands.contains { $0.contains(" LIST ") })
        XCTAssertFalse(server.commands.contains { $0.contains("Sent Mail") || $0.contains("Trash") })
    }

    // MARK: syncExtras.json

    func testTheSliceAndModSeqOutliveARelaunchAndFoldersJsonIsUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("falcon-extras-\(UUID().uuidString)", isDirectory: true)
        let first = try await listed(3_000, root: root)
        let inbox = try await first.folder("INBOX")
        await first.syncer.stop()
        let layout = FileLayout(root: root)
        let extrasFile = layout.syncExtrasFile(first.account.id)
        let stored = try XCTUnwrap(AtomicFile.readJSON(SyncExtras.self, from: extrasFile))
        XCTAssertEqual(stored.folders?[inbox.id.uuidString]?.flagSliceBelow, 1001)
        XCTAssertEqual(stored.folders?[inbox.id.uuidString]?.belowWindow, 0)

        // The previous release reads folders.json with exactly the fields it always had.
        let previousFields: Set<String> = ["id", "accountID", "path", "name", "delimiter", "role", "attributes", "isSelectable", "uidValidity",
                                           "uidNext", "lastSyncedUID", "oldestSyncedUID", "totalCount", "unreadCount", "lastSyncDate"]
        let folders = try JSONSerialization.jsonObject(with: Data(contentsOf: layout.foldersFile(first.account.id))) as? [[String: Any]]
        for folder in folders ?? [] { XCTAssertTrue(Set(folder.keys).isSubset(of: previousFields), "\(folder.keys)") }

        let server = first.server
        server.resetCounters()
        let second = try await EngineHarness(server: server, root: root)
        try await second.syncOnce()
        XCTAssertTrue(flagFetches(server).map(\.line).contains { $0.contains("UID FETCH 1:1000 ") }, "the rotation goes on where it was")
        await second.finish()
        harness = nil
    }

    func testAFolderFromTheEarlierReleaseIsCountedOnceThenKept() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("falcon-extras-\(UUID().uuidString)", isDirectory: true)
        let first = try await listed(1_500, root: root)
        let layout = FileLayout(root: root)
        await first.syncer.stop()
        // As the earlier release leaves it: cursors in folders.json and no syncExtras.json.
        try FileManager.default.removeItem(at: layout.syncExtrasFile(first.account.id))
        let server = first.server
        server.resetCounters()
        let second = try await EngineHarness(server: server, root: root)
        try await second.syncOnce()
        XCTAssertEqual(server.commands.filter { $0.contains("UID SEARCH ALL") }.count, 1, "counted once, to tell deletions from then on")
        let rows = try await second.uids(in: "INBOX")
        XCTAssertEqual(rows.count, 1_500)
        server.resetCounters()
        try await second.syncOnce()
        XCTAssertFalse(server.commands.contains { $0.contains("UID SEARCH ALL") })
        await second.finish()
        harness = nil
    }

    func testAnUndecodableSyncStateIsSetAsideAndSyncGoesOn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("falcon-extras-\(UUID().uuidString)", isDirectory: true)
        let first = try await listed(50, root: root)
        await first.syncer.stop()
        let file = FileLayout(root: root).syncExtrasFile(first.account.id)
        let garbage = Data("{\"imapPauseLevel\": nope".utf8)
        try garbage.write(to: file)
        _ = StoredFileNotices.take()
        let server = first.server
        let second = try await EngineHarness(server: server, root: root)
        try await second.syncOnce()
        let aside = AtomicFile.setAsideCopies(of: file)
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: aside[0]), garbage)
        XCTAssertNotNil(AtomicFile.readJSON(SyncExtras.self, from: file), "a new one is written beside it")
        let rows = try await second.uids(in: "INBOX")
        XCTAssertEqual(rows.count, 50)
        XCTAssertTrue(StoredFileNotices.take().contains("the sync state for owner@example.com"))
        await second.finish()
        harness = nil
    }

    func testALaterBuildsFieldsAreIgnored() throws {
        let json = """
            {"imapPauseLevel":2,"lastThrottleAt":"2026-09-24T10:00:00Z","futureField":{"x":1},
             "folders":{"\(UUID().uuidString)":{"uidValidity":7,"highestModSeq":9223372036854775807,"somethingNew":true}}}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SyncExtras.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.imapPauseLevel, 2)
        XCTAssertEqual(decoded.folders?.values.first?.highestModSeq, 9_223_372_036_854_775_807)
    }

    func testRangesLeaveOutMessagesStillToFetch() {
        XCTAssertEqual(AccountSyncer.ranges(covering: [1, 2, 3, 7, 8, 20, 21], skipping: []), [1...21])
        XCTAssertEqual(AccountSyncer.ranges(covering: [1, 2, 3, 7, 8, 20, 21], skipping: [10, 11, 12]), [1...8, 20...21])
        XCTAssertEqual(AccountSyncer.ranges(covering: [5], skipping: [1, 9]), [5...5])
        XCTAssertEqual(AccountSyncer.ranges(covering: [], skipping: [1]), [])
        XCTAssertEqual(AccountSyncer.uidSet([1...8, 20...20]), "1:8,20")
    }
}
