import XCTest
@testable import FalconCore

/// A folder is taken off the Mac, with everything stored for it, only once the server has left
/// it out of two folder lists some time apart: one reply that leaves folders out, or lists none
/// or no INBOX, takes nothing. The sync loop keeps idling on the inbox the store holds now, and
/// with none to idle on waits for the next whole pass rather than starting one after another.
final class FolderListTests: XCTestCase {
    private var harness: EngineHarness?

    override func tearDown() async throws {
        await harness?.finish()
    }

    /// Thirty messages in INBOX and twenty in HR, both listed by a first pass.
    private func listed(gone: TimeInterval = 60) async throws -> EngineHarness {
        let server = try EngineHarness.gmailServer()
        server.addMailbox("HR")
        server.addMany(30, to: "INBOX") { FakeIMAPServer.message("in-\($0)") }
        server.addMany(20, to: "HR") { FakeIMAPServer.message("hr-\($0)") }
        var pacing = SyncPacing()
        pacing.folderGoneConfirmation = gone
        let h = try await EngineHarness(server: server, pacing: pacing)
        harness = h
        try await h.syncOnce()
        return h
    }

    private func directory(_ h: EngineHarness, _ folder: FolderInfo) -> URL {
        h.layout.folderDirectory(accountID: folder.accountID, folderID: folder.id)
    }

    private func finishedCount(_ h: EngineHarness) async -> Int {
        await h.events.all.filter { if case .finished = $0 { return true }; return false }.count
    }

    func testAFolderLeftOutOfOneListKeepsItsMail() async throws {
        let h = try await listed()
        let hr = try await h.folder("HR")
        h.server.leaveOutOfNextLists(["HR"])
        h.server.resetCounters()
        try await h.syncOnce()
        let kept = try await h.folder("HR")
        XCTAssertEqual(kept.id, hr.id)
        var rows = try await h.uids(in: "HR")
        XCTAssertEqual(rows.count, 20)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory(h, hr).path))
        XCTAssertFalse(h.server.commands.contains { $0.contains("SELECT") && $0.contains("HR") }, "a folder left out is not selected")

        // Listed again, it is the same folder, and nothing of it is fetched again.
        h.server.resetCounters()
        try await h.syncOnce()
        let again = try await h.folder("HR")
        XCTAssertEqual(again.id, hr.id)
        rows = try await h.uids(in: "HR")
        XCTAssertEqual(rows.count, 20)
        XCTAssertTrue(FakeIMAPServer.headerFetchUIDs(h.server.exchanges).isEmpty)
    }

    func testAListWithoutTheInboxOrWithNothingTakesNothing() async throws {
        // Even with no time at all between two lists, neither kind is believed.
        let h = try await listed(gone: 0)
        let before = Set(await h.store.folders(for: h.account.id).map(\.id))
        for omitted in [nil, ["INBOX"], ["INBOX", "HR"]] as [[String]?] {
            h.server.leaveOutOfNextLists(omitted, times: 3)
            for _ in 1...3 { try await h.syncOnce() }
            let after = Set(await h.store.folders(for: h.account.id).map(\.id))
            XCTAssertEqual(after, before, "\(omitted ?? ["everything"]) left out")
            let inbox = try await h.uids(in: "INBOX")
            let hr = try await h.uids(in: "HR")
            XCTAssertEqual(inbox.count, 30)
            XCTAssertEqual(hr.count, 20)
        }
    }

    func testAFolderDeletedOnTheServerGoesOnceALaterListLeavesItOutToo() async throws {
        let h = try await listed(gone: 0.3)
        let hr = try await h.folder("HR")
        h.server.removeMailbox("HR")
        try await h.syncOnce()
        var stored = await h.store.folder(hr.id)
        XCTAssertNotNil(stored, "one list is not enough")
        try await h.syncOnce()
        stored = await h.store.folder(hr.id)
        XCTAssertNotNil(stored, "nor two in quick succession")
        try await Task.sleep(nanoseconds: 400_000_000)
        try await h.syncOnce()
        stored = await h.store.folder(hr.id)
        XCTAssertNil(stored, "gone from two lists some time apart")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory(h, hr).path), "with everything stored for it")
        let inbox = try await h.uids(in: "INBOX")
        XCTAssertEqual(inbox.count, 30)
    }

    /// The sync loop, with whole passes an hour apart, over INBOX and HR, idling on INBOX.
    private func running(gone: TimeInterval) async throws -> EngineHarness {
        var pacing = SyncPacing()
        pacing.fullSyncInterval = 3600
        pacing.idleRefresh = 3600
        pacing.folderGoneConfirmation = gone
        pacing.minimumReconnectInterval = 0.05
        let server = try EngineHarness.gmailServer()
        server.addMailbox("HR")
        server.addMany(3, to: "INBOX") { FakeIMAPServer.message("in-\($0)") }
        server.addMany(2, to: "HR") { FakeIMAPServer.message("hr-\($0)") }
        let h = try await EngineHarness(server: server, pacing: pacing)
        harness = h
        await h.syncer.start()
        await assertEventually { await self.finishedCount(h) == 1 && server.idlingCount == 1 }
        return h
    }

    /// A folder deleted on the server goes from the Mac about the confirmation time after the
    /// first list that left it out: a second list looks for it then, instead of at the next
    /// whole pass, which here is an hour away.
    func testAFolderDeletedOnTheServerGoesSoonAfterTheFirstListWithoutIt() async throws {
        let h = try await running(gone: 0.5)
        let hr = try await h.folder("HR")
        h.server.removeMailbox("HR")
        let listsBefore = h.server.commands.filter { $0.contains(" LIST ") }.count
        let asked = Date()
        await h.syncer.requestSync()
        await assertEventually { await h.store.foldersLeftOut(accountID: h.account.id) == [hr.id] }
        var stored = await h.store.folder(hr.id)
        XCTAssertNotNil(stored, "one list is not enough")
        await assertEventually("taken off by a second list", within: 5) { await h.store.folder(hr.id) == nil }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(asked), 0.5, "not before the confirmation time")
        stored = await h.store.folder(hr.id)
        XCTAssertNil(stored)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory(h, hr).path))
        let lists = h.server.commands.filter { $0.contains(" LIST ") }.count - listsBefore
        XCTAssertEqual(lists, 2, "the pass asked for, then the one that confirms it")
        // Nothing more is asked of the server until the next pass is due.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(h.server.commands.filter { $0.contains(" LIST ") }.count - listsBefore, 2)
        let inbox = try await h.uids(in: "INBOX")
        XCTAssertEqual(inbox.count, 3)
    }

    private func lists(_ h: EngineHarness) -> Int { h.server.commands.filter { $0.contains(" LIST ") }.count }

    /// Send & Receive inside the confirmation time after the first list that left a folder out
    /// neither takes the folder off early nor puts off the look for it: the folder still goes
    /// about the confirmation time after that first list, not at the next whole pass an hour away.
    func testSendAndReceiveInsideTheConfirmationTimeKeepsTheLookForAFolderLeftOut() async throws {
        let h = try await running(gone: 1.0)
        let hr = try await h.folder("HR")
        h.server.removeMailbox("HR")
        let asked = Date()
        let first = await finishedCount(h)
        await h.syncer.requestSync()
        await assertEventually { await h.store.foldersLeftOut(accountID: h.account.id) == [hr.id] }
        await assertEventually { await self.finishedCount(h) > first && h.server.idlingCount == 1 }
        let listsBefore = lists(h)
        try await Task.sleep(nanoseconds: 300_000_000)
        let second = await finishedCount(h)
        await h.syncer.requestSync(check: true)
        await assertEventually { await self.finishedCount(h) > second && h.server.idlingCount == 1 }
        XCTAssertEqual(lists(h), listsBefore + 1)
        var stored = await h.store.folder(hr.id)
        XCTAssertNotNil(stored, "the pass in between comes before the confirmation time")
        await assertEventually("taken off by the look that was waiting", within: 5) { await h.store.folder(hr.id) == nil }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(asked), 1.0, "not before the confirmation time")
        stored = await h.store.folder(hr.id)
        XCTAssertNil(stored)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory(h, hr).path))
        XCTAssertEqual(lists(h) - listsBefore, 2, "Send & Receive, then the look")
        // Nothing more is asked of the server until the next pass is due.
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(lists(h) - listsBefore, 2)
    }

    /// A folder that a list leaves out and the next lists again, before the confirmation time is
    /// up, needs no look: nothing more is listed until the next whole pass.
    func testAFolderListedAgainBeforeTheLookNeedsNone() async throws {
        let h = try await running(gone: 0.5)
        let hr = try await h.folder("HR")
        h.server.leaveOutOfNextLists(["HR"])
        let first = await finishedCount(h)
        await h.syncer.requestSync()
        await assertEventually { await h.store.foldersLeftOut(accountID: h.account.id) == [hr.id] }
        await assertEventually { await self.finishedCount(h) > first && h.server.idlingCount == 1 }
        let second = await finishedCount(h)
        await h.syncer.requestSync(check: true)
        await assertEventually { await self.finishedCount(h) > second && h.server.idlingCount == 1 }
        let leftOut = await h.store.foldersLeftOut(accountID: h.account.id)
        XCTAssertTrue(leftOut.isEmpty, "listed again")
        let listsAfter = lists(h)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(lists(h), listsAfter, "no look is left waiting")
        let kept = try await h.folder("HR")
        XCTAssertEqual(kept.id, hr.id)
        let rows = try await h.uids(in: "HR")
        XCTAssertEqual(rows.count, 2)
    }

    /// A folder deleted on the server and then asked for on its own, as after saving into it or
    /// finding one of its messages gone: the SELECT the server refuses neither drops the
    /// connection nor takes the account offline. The folders are listed again at once, and the
    /// folder goes once a list the confirmation time later leaves it out too.
    func testAFolderAskedForAfterItWasDeletedOnTheServerKeepsTheConnection() async throws {
        let h = try await running(gone: 0.5)
        let hr = try await h.folder("HR")
        let healthsBefore = await h.events.healths.count
        h.server.removeMailbox("HR")
        await h.syncer.requestSync(folderID: hr.id)
        await assertEventually("taken off by a second list", within: 5) { await h.store.folder(hr.id) == nil }
        await assertEventually { h.server.idlingCount == 1 }
        XCTAssertEqual(h.server.loginCount, 1, "the connection stayed up")
        let healths = await h.events.healths.dropFirst(healthsBefore)
        XCTAssertFalse(healths.contains { if case .offline = $0 { return true }; return false }, "\(Array(healths))")
        let errors = await h.events.errors
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertTrue(h.server.commands.contains { $0.contains("SELECT") && $0.contains("HR") }, "it was asked for")
        let inbox = try await h.uids(in: "INBOX")
        XCTAssertEqual(inbox.count, 3)
    }

    /// A pass whose list leaves INBOX out while its catch-up is held back: the inbox and its
    /// hold stay, the loop neither spins nor stops idling, and the rest of the backlog and
    /// what IDLE tells of next still arrive.
    func testAListWithoutTheInboxDuringAHoldNeitherSpinsNorLosesTheInbox() async throws {
        var pacing = SyncPacing()
        pacing.catchUpWindow = 35
        pacing.catchUpInterval = 1
        pacing.fullSyncInterval = 3600
        pacing.idleRefresh = 3600
        pacing.minimumReconnectInterval = 0.05
        let server = try EngineHarness.gmailServer()
        server.addMany(30, to: "INBOX") { FakeIMAPServer.message("old-\($0)") }
        let h = try await EngineHarness(server: server, pacing: pacing)
        harness = h
        await h.syncer.start()
        await assertEventually { await self.finishedCount(h) == 1 && server.idlingCount == 1 }
        let inbox = try await h.folder("INBOX")
        server.addMany(105, to: "INBOX") { FakeIMAPServer.message("bulk-\($0)") }
        let first = await finishedCount(h)
        await h.syncer.requestSync()
        await assertEventually { await self.finishedCount(h) > first && server.idlingCount == 1 }
        var rows = try await h.uids(in: "INBOX")
        XCTAssertEqual(rows.count, 65, "the newest 35 taken, the rest held back")

        server.leaveOutOfNextLists(["INBOX"])
        let second = await finishedCount(h)
        await h.syncer.requestSync()
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let passes = await finishedCount(h) - second
        XCTAssertLessThan(passes, 10, "the loop does not spin")
        let kept = try await h.folder("INBOX")
        XCTAssertEqual(kept.id, inbox.id, "the inbox is the same")
        await assertEventually("the backlog arrived") { ((try? await h.uids(in: "INBOX")) ?? []).count == 135 }
        await assertEventually { server.idlingCount == 1 }
        let next = server.deliver(FakeIMAPServer.message("next", date: Date()), to: "INBOX")
        await assertEventually("what IDLE tells of is fetched at once") { ((try? await h.uids(in: "INBOX")) ?? []).contains(next) }
        rows = try await h.uids(in: "INBOX")
        XCTAssertEqual(rows.count, 136)
    }

    /// A server that never lists INBOX: with no inbox to idle on, the loop waits for the next
    /// whole pass, or one the owner asks for, instead of starting one after another.
    func testWithNoInboxToIdleOnTheLoopWaitsForTheNextPass() async throws {
        var pacing = SyncPacing()
        pacing.fullSyncInterval = 3600
        pacing.minimumReconnectInterval = 0.05
        let server = try EngineHarness.gmailServer()
        server.add(FakeIMAPServer.message("sent"), to: "[Gmail]/Sent Mail")
        server.leaveOutOfNextLists(["INBOX"], times: 1_000)
        let h = try await EngineHarness(server: server, pacing: pacing)
        harness = h
        await h.syncer.start()
        await assertEventually { await self.finishedCount(h) >= 1 }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let lists = server.commands.filter { $0.contains(" LIST ") }.count
        XCTAssertLessThanOrEqual(lists, 2, "no pass after pass: \(lists) lists")
        let sent = try await h.uids(in: "[Gmail]/Sent Mail")
        XCTAssertEqual(sent.count, 1, "the folders listed are synced")

        await h.syncer.requestSync(check: true)
        await assertEventually("a pass asked for runs at once") {
            await h.events.all.contains { if case .checked = $0 { return true }; return false }
        }
    }
}
