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
    private func listed(_ count: Int, capabilities: [String]? = nil, root: URL? = nil,
                        emptyFolderConfirmation: TimeInterval = 60) async throws -> EngineHarness {
        let server = try EngineHarness.gmailServer(capabilities: capabilities)
        server.addMany(count, to: "INBOX") { FakeIMAPServer.message("m\($0)", body: "Message \($0).") }
        var pacing = SyncPacing()
        pacing.initialWindow = count
        pacing.catchUpWindow = count
        pacing.emptyFolderConfirmation = emptyFolderConfirmation
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

    func testASearchThatFindsNothingTakesNoRows() async throws {
        let h = try await listed(3_000)
        // Outside the slices this pass looks at, so only a search can find it.
        h.server.remove(uid: 1_500, from: "INBOX")
        h.server.emptyNextSearches(5)
        try await h.syncOnce()
        let rows = try await h.uids(in: "INBOX")
        XCTAssertEqual(rows.count, 3_000, "a reply that would empty the folder is not believed")
        XCTAssertTrue(h.logText().contains("a search listed 0 of 2999 messages; left alone"))
        try await h.syncOnce()
        let later = try await h.uids(in: "INBOX")
        XCTAssertFalse(later.contains(1_500), "the next pass finds the one deletion")
        XCTAssertEqual(later.count, 2_999)
    }

    private let condstore = ["IMAP4rev1", "AUTH=PLAIN", "IDLE", "MOVE", "UIDPLUS", "SPECIAL-USE", "CONDSTORE", "ESEARCH"]

    func testWithCondstoreOnlyChangedFlagsComeBack() async throws {
        let h = try await listed(3_000, capabilities: condstore)
        // The first pass looked at the newest and 1001–2000; this one ends the rotation.
        try await h.syncOnce()
        XCTAssertEqual(flagFetches(h.server).map(\.line).filter { $0.contains("UID FETCH 1:1000 (UID FLAGS)") }.count, 1)
        h.server.resetCounters()
        try await h.syncOnce()
        XCTAssertTrue(flagFetches(h.server).isEmpty, "every row has been looked at since the first mark and nothing changed, so no flag is asked for")

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

    func testOnCondstoreAFlagChangedBeforeTheFirstMarkIsFoundWithinOneRotation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("falcon-extras-\(UUID().uuidString)", isDirectory: true)
        let first = try await listed(5_000, capabilities: condstore, root: root)
        await first.syncer.stop()
        // As the earlier release leaves it: rows and cursors, no mark, and changes made since.
        try FileManager.default.removeItem(at: FileLayout(root: root).syncExtrasFile(first.account.id))
        let server = first.server
        server.setFlags(["\\Seen"], uid: 10, in: "INBOX")
        server.setFlags(["\\Seen"], uid: 1_500, in: "INBOX")
        let second = try await EngineHarness(server: server, root: root)
        for _ in 1...4 { try await second.syncOnce() }
        let oldest = try await second.message(uid: 10, in: "INBOX")
        let middle = try await second.message(uid: 1_500, in: "INBOX")
        XCTAssertTrue(oldest.isRead)
        XCTAssertTrue(middle.isRead)
        server.resetCounters()
        try await second.syncOnce()
        XCTAssertTrue(flagFetches(server).isEmpty, "after one rotation only what changed is asked for")
        let inbox = try await second.folder("INBOX")
        let stored = AtomicFile.readJSON(SyncExtras.self, from: FileLayout(root: root).syncExtrasFile(second.account.id))
        XCTAssertEqual(stored?.folders?[inbox.id.uuidString]?.flagsSwept, true, "and a relaunch does not start the rotation again")
        await second.finish()
        harness = nil
    }

    func testAFlagReplyListingNothingTakesNoRowsBeforeTheFolderIsCounted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("falcon-extras-\(UUID().uuidString)", isDirectory: true)
        let first = try await listed(3_000, root: root)
        await first.syncer.stop()
        // The first pass after an upgrade: no count of what lies below the rows yet.
        try FileManager.default.removeItem(at: FileLayout(root: root).syncExtrasFile(first.account.id))
        let server = first.server
        let second = try await EngineHarness(server: server, root: root)
        server.emptyNextFlagFetches(1)
        for _ in 1...4 { try await second.syncOnce() }
        let rows = try await second.uids(in: "INBOX")
        XCTAssertEqual(rows.count, 3_000, "rows below the cursor, which nothing would fetch again")
        await second.finish()
        harness = nil
    }

    func testAFlagReplyListingNothingTakesNoRowsWhileAnActionIsOnItsWay() async throws {
        let h = try await listed(3_000)
        await h.syncer.setUndoWindow(60)
        let records = try await h.syncer.setFlag(.flagged, on: [try await h.message(uid: 2_500, in: "INBOX")], enabled: true)
        h.server.emptyNextFlagFetches(1)
        try await h.syncOnce()
        let rows = try await h.uids(in: "INBOX")
        XCTAssertEqual(rows.count, 3_000, "with an action on its way the count cannot vouch for the reply")
        for record in records { _ = await h.syncer.undo(record.id) }
    }

    func testRowsMissingHereHoldBackNoDeletion() async throws {
        let h = try await listed(3_000)
        // Rows the server still holds that FalconMail lost, however that came about.
        let stored = try await h.store.folderStore(try await h.folder("INBOX"))
        try await stored.remove(uids: Array(1_000...1_049))
        for uid in UInt32(2_901)...3_000 { h.server.remove(uid: uid, from: "INBOX") }
        try await h.syncOnce()
        let rows = try await h.uids(in: "INBOX")
        XCTAssertEqual(rows.count, 2_850, "the hundred deleted on the server went, though the count was 50 out")
        h.server.resetCounters()
        try await h.syncOnce()
        XCTAssertFalse(h.server.commands.contains { $0.contains("SEARCH ALL") }, "the count agrees again")

        for uid in UInt32(2_871)...2_900 { h.server.remove(uid: uid, from: "INBOX") }
        try await h.syncOnce()
        let later = try await h.uids(in: "INBOX")
        XCTAssertEqual(later.count, 2_820, "and so does a later deletion smaller than the gap")
    }

    func testAReplyTheCountCannotVouchForAsksForTheSearchInTheSamePass() async throws {
        let h = try await listed(3_000)
        // A gap here of 150 rows, more than the 100 deleted on the server among the newest: the
        // count says the server holds more than is listed, so only the reply it refused to believe
        // can ask for the search that finds them.
        let stored = try await h.store.folderStore(try await h.folder("INBOX"))
        try await stored.remove(uids: Array(1_000...1_149))
        for uid in UInt32(2_901)...3_000 { h.server.remove(uid: uid, from: "INBOX") }
        h.server.resetCounters()
        try await h.syncOnce()
        XCTAssertTrue(h.logText().contains("a reply would remove 100 rows where the count is short by -50; left alone"))
        let rows = try await h.uids(in: "INBOX")
        XCTAssertEqual(rows.count, 2_750, "the hundred deleted on the server went in the same pass")
        XCTAssertTrue(rows.isDisjoint(with: Set(UInt32(2_901)...3_000)))
        XCTAssertEqual(h.server.commands.filter { $0.contains("UID SEARCH ALL") }.count, 1)

        h.server.resetCounters()
        try await h.syncOnce()
        XCTAssertFalse(h.server.commands.contains { $0.contains("SEARCH ALL") }, "the count agrees from then on")
        let later = try await h.uids(in: "INBOX")
        XCTAssertEqual(later.count, 2_750)
    }

    func testAServerReportingNoMessagesForAMomentEmptiesNothing() async throws {
        let h = try await listed(30)
        let messages = h.server.messages(in: "INBOX")
        for m in messages { h.server.remove(uid: m.uid, from: "INBOX") }
        try await h.syncOnce()
        let kept = try await h.uids(in: "INBOX")
        XCTAssertEqual(kept.count, 30, "one pass that finds the folder empty is not believed")
        for m in messages { h.server.add(m.data, to: "INBOX", uid: m.uid) }
        try await h.syncOnce()
        try await h.syncOnce()
        let rows = try await h.uids(in: "INBOX")
        XCTAssertEqual(rows.count, 30)
    }

    func testAFolderEmptiedOnTheServerIsEmptiedByALaterPass() async throws {
        let h = try await listed(30, emptyFolderConfirmation: 0.5)
        for m in h.server.messages(in: "INBOX") { h.server.remove(uid: m.uid, from: "INBOX") }
        try await h.syncOnce()
        try await h.syncOnce()
        let soon = try await h.uids(in: "INBOX")
        XCTAssertEqual(soon.count, 30, "a pass moments later is no confirmation")
        try await Task.sleep(nanoseconds: 600_000_000)
        try await h.syncOnce()
        let rows = try await h.uids(in: "INBOX")
        XCTAssertTrue(rows.isEmpty, "a later pass confirms it")
        let inbox = try await h.folder("INBOX")
        XCTAssertEqual(inbox.oldestSyncedUID, inbox.lastSyncedUID + 1, "Load older looks below the cursor for anything shown again")

        let few = try await listed(5)
        for m in few.server.messages(in: "INBOX") { few.server.remove(uid: m.uid, from: "INBOX") }
        try await few.syncOnce()
        let none = try await few.uids(in: "INBOX")
        XCTAssertTrue(none.isEmpty, "a few rows go at once")
        await h.finish()
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
