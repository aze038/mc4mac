import XCTest
@testable import FalconCore

/// Deleting for good removes the messages asked for and nothing else. A plain EXPUNGE also
/// purges whatever another program marked \Deleted, which in Gmail's Trash is gone for ever.
final class ExpungeTests: XCTestCase {
    private var harness: EngineHarness?

    override func tearDown() async throws {
        await harness?.finish()
    }

    private func trashWithThree(capabilities: [String]) async throws -> EngineHarness {
        let server = try EngineHarness.gmailServer(capabilities: capabilities)
        for n in 1...3 { server.add(FakeIMAPServer.message("trash-\(n)"), to: "[Gmail]/Trash") }
        let h = try await EngineHarness(server: server)
        harness = h
        try await h.syncOnce()
        await h.syncer.setUndoWindow(0)
        return h
    }

    private static let withUIDPlus = ["IMAP4rev1", "AUTH=PLAIN", "IDLE", "MOVE", "UIDPLUS"]
    private static let withoutUIDPlus = ["IMAP4rev1", "AUTH=PLAIN", "IDLE", "MOVE"]

    func testUIDExpungeRemovesOnlyTheGivenUIDs() async throws {
        let h = try await trashWithThree(capabilities: Self.withUIDPlus)
        // Another program has marked message 2 for deletion but not purged it.
        h.server.setFlags(["\\Deleted"], uid: 2, in: "[Gmail]/Trash")
        _ = try await h.syncer.purge([try await h.message(uid: 1, in: "[Gmail]/Trash")])

        await assertEventually { h.server.messages(in: "[Gmail]/Trash").count == 2 }
        XCTAssertEqual(h.server.messages(in: "[Gmail]/Trash").map(\.uid), [2, 3])
        XCTAssertTrue(h.server.commands.contains { $0.hasSuffix("UID EXPUNGE 1") })
        XCTAssertFalse(h.server.commands.contains { $0.hasSuffix(" EXPUNGE") }, "never a plain EXPUNGE")
    }

    func testWithoutUIDPlusDeletingIsRefusedWhileAnotherMessageIsMarked() async throws {
        let h = try await trashWithThree(capabilities: Self.withoutUIDPlus)
        h.server.setFlags(["\\Deleted"], uid: 2, in: "[Gmail]/Trash")
        _ = try await h.syncer.purge([try await h.message(uid: 1, in: "[Gmail]/Trash")])

        await assertEventually { await !h.events.actionFailures.isEmpty }
        let failure = await h.events.actionFailures.first ?? ""
        XCTAssertTrue(failure.contains("another message there is marked for deletion"), failure)
        XCTAssertEqual(h.server.messages(in: "[Gmail]/Trash").map(\.uid), [1, 2, 3])
        XCTAssertFalse(h.server.messages(in: "[Gmail]/Trash")[0].flags.contains("\\Deleted"), "the refused message is not left marked")
        XCTAssertFalse(h.server.commands.contains { $0.hasSuffix(" EXPUNGE") })
        let restored = try await h.uids(in: "[Gmail]/Trash")
        XCTAssertTrue(restored.contains(1), "the row comes back when the delete is refused")
    }

    func testWithoutUIDPlusAPlainExpungeIsUsedOnlyWhenNothingElseIsMarked() async throws {
        let h = try await trashWithThree(capabilities: Self.withoutUIDPlus)
        _ = try await h.syncer.purge([try await h.message(uid: 1, in: "[Gmail]/Trash")])
        await assertEventually { h.server.messages(in: "[Gmail]/Trash").count == 2 }
        XCTAssertEqual(h.server.messages(in: "[Gmail]/Trash").map(\.uid), [2, 3])
    }

    func testMoveWithoutMOVEDeletesOnlyWhatItCopied() async throws {
        let server = try EngineHarness.gmailServer(capabilities: ["IMAP4rev1", "AUTH=PLAIN", "UIDPLUS"])
        for n in 1...3 { server.add(FakeIMAPServer.message("inbox-\(n)"), to: "INBOX") }
        server.setFlags(["\\Deleted"], uid: 3, in: "INBOX")
        let client = try await server.client()
        _ = try await client.select("INBOX")
        try await client.move(uids: [1], to: "[Gmail]/Trash")
        XCTAssertEqual(server.messages(in: "INBOX").map(\.uid), [2, 3])
        XCTAssertEqual(server.messages(in: "[Gmail]/Trash").count, 1)
        await client.logout()
        server.stop()
    }

    func testWithoutMOVEOrUIDPlusADeleteIsRefusedBeforeAnythingIsCopied() async throws {
        let server = try EngineHarness.gmailServer(capabilities: ["IMAP4rev1", "AUTH=PLAIN", "IDLE"])
        for n in 1...3 { server.add(FakeIMAPServer.message("inbox-\(n)"), to: "INBOX") }
        let h = try await EngineHarness(server: server)
        harness = h
        try await h.syncOnce()
        await h.syncer.setUndoWindow(0)
        // Another program has marked message 3 for deletion but not purged it.
        server.setFlags(["\\Deleted"], uid: 3, in: "INBOX")
        for attempt in 1...2 {
            _ = try await h.syncer.delete([try await h.message(uid: 1, in: "INBOX")])
            await assertEventually { await h.events.actionFailures.count == attempt }
            let failure = await h.events.actionFailures.last ?? ""
            XCTAssertTrue(failure.contains("another message there is marked for deletion"), failure)
            XCTAssertEqual(server.messages(in: "INBOX").map(\.uid), [1, 2, 3])
            XCTAssertTrue(server.messages(in: "[Gmail]/Trash").isEmpty, "attempt \(attempt): no copy left behind in Trash")
        }
        XCTAssertFalse(server.commands.contains { $0.contains("UID COPY") })
    }

    func testArchiveJobRemovesOnlyWhatItArchived() async throws {
        let server = try EngineHarness.gmailServer(capabilities: Self.withoutUIDPlus)
        let longAgo = Date(timeIntervalSince1970: 1_600_000_000)
        for n in 1...2 { server.add(FakeIMAPServer.message("old-\(n)"), to: "INBOX", date: longAgo) }
        // Newer than the cutoff, so not archived, and marked for deletion by another program.
        server.add(FakeIMAPServer.message("new"), to: "INBOX", flags: ["\\Deleted"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("falcon-archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Archives"), withIntermediateDirectories: true)
        Log.start(in: root)
        let client = try await server.client()
        let account = AccountInfo(email: "owner@example.com", displayName: "Owner")
        let request = ArchiveRequest(accountID: account.id, folderPaths: ["INBOX"], olderThan: Date(timeIntervalSince1970: 1_700_000_000),
                                     name: "Old mail", password: nil, removeFromServer: true, parentID: nil)
        let outcome = try await ArchiveJob.run(request: request, account: account, client: client,
                                               storage: LocalFolderStorage(root: root.appendingPathComponent("Archives")),
                                               allowance: { _ in }) { _ in }
        XCTAssertEqual(outcome.manifest.messageCount, 2)
        XCTAssertEqual(outcome.keptOnServer, ["INBOX"], "another message is marked and the server has no UIDPLUS")
        XCTAssertEqual(server.messages(in: "INBOX").count, 3, "nothing purged")
        XCTAssertFalse(server.commands.contains { $0.hasSuffix(" EXPUNGE") })
        await client.logout()
        server.stop()
    }
}
