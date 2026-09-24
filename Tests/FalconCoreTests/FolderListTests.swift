import XCTest
@testable import FalconCore

/// A folder is taken off the Mac, with everything stored for it, only once the server has left
/// it out of two folder lists some time apart: one reply that leaves folders out, or lists none
/// or no INBOX, takes nothing.
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
}
