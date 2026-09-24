import XCTest
@testable import FalconCore

/// The op connection carries everything the reader asks for. These are the races that gave the
/// owner "Protocol error", hangs, and actions landing on the wrong message.
final class OpConnectionTests: XCTestCase {
    private var harness: EngineHarness!

    override func setUp() async throws {
        let server = try EngineHarness.gmailServer(latency: 0.004)
        for n in 1...6 { server.add(FakeIMAPServer.message("inbox-\(n)"), to: "INBOX") }
        for n in 1...6 { server.add(FakeIMAPServer.message("sent-\(n)", from: "owner@example.com", to: "ana@example.com"), to: "[Gmail]/Sent Mail") }
        harness = try await EngineHarness(server: server)
        try await harness.syncOnce()
    }

    override func tearDown() async throws {
        await harness.finish()
    }

    func testConcurrentOpensReturnIntactBodiesAndNoneHangs() async throws {
        let syncer = harness.syncer
        var list: [(expected: Data, message: MessageSummary)] = []
        for uid in UInt32(1)...6 {
            list.append((FakeIMAPServer.message("inbox-\(uid)"), try await harness.message(uid: uid, in: "INBOX")))
            list.append((FakeIMAPServer.message("sent-\(uid)", from: "owner@example.com", to: "ana@example.com"),
                         try await harness.message(uid: uid, in: "[Gmail]/Sent Mail")))
        }
        let opens = list
        let bodies = try await within(20) {
            try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for (i, open) in opens.enumerated() {
                    group.addTask { (i, try await syncer.body(for: open.message)) }
                }
                var out: [Int: Data] = [:]
                for try await (i, body) in group { out[i] = body }
                return out
            }
        }
        for (i, open) in opens.enumerated() {
            XCTAssertEqual(bodies[i], open.expected, "open \(i) got another message's body or a broken one")
        }
        XCTAssertEqual(harness.server.loginCount, 2, "one sync connection for the setup and one op connection for every open")
    }

    func testArchiveCommittedDuringAnOpenInAnotherFolderLandsInTheRightMailbox() async throws {
        let server = harness.server
        // The same UID in both folders: a MOVE run in the wrong mailbox takes the wrong message.
        server.add(FakeIMAPServer.message("inbox-42"), to: "INBOX", uid: 42)
        server.add(FakeIMAPServer.message("sent-42"), to: "[Gmail]/Sent Mail", uid: 42)
        try await harness.syncOnce()
        await harness.syncer.setUndoWindow(0)
        let inboxMessage = try await harness.message(uid: 42, in: "INBOX")
        let sentMessage = try await harness.message(uid: 42, in: "[Gmail]/Sent Mail")

        server.stallNext("UID FETCH", seconds: 0.4)
        let syncer = harness.syncer
        let open = Task { try await syncer.body(for: sentMessage) }
        await assertEventually { server.commands.contains { $0.contains("UID FETCH 42") } }
        _ = try await syncer.archive([inboxMessage])
        let body = try await within(10) { try await open.value }
        XCTAssertEqual(body, FakeIMAPServer.message("sent-42"))

        await assertEventually { !server.messages(in: "INBOX").contains { $0.data == FakeIMAPServer.message("inbox-42") } }
        XCTAssertTrue(server.messages(in: "[Gmail]/Sent Mail").contains { $0.data == FakeIMAPServer.message("sent-42") },
                      "the message open in Sent must stay where it is")
        XCTAssertTrue(server.messages(in: "[Gmail]/All Mail").contains { $0.data == FakeIMAPServer.message("inbox-42") })
        XCTAssertFalse(server.messages(in: "[Gmail]/All Mail").contains { $0.data == FakeIMAPServer.message("sent-42") })
    }

    func testUIDValidityChangeBetweenQueueAndRunCancelsTheAction() async throws {
        let server = harness.server
        await harness.syncer.setUndoWindow(0.3)
        let target = try await harness.message(uid: 3, in: "INBOX")
        _ = try await harness.syncer.archive([target])
        server.renumber("INBOX")

        await assertEventually { await !self.harness.events.actionFailures.isEmpty }
        let failure = await harness.events.actionFailures.first ?? ""
        XCTAssertTrue(failure.contains("rebuilt on the server"), failure)
        XCTAssertFalse(server.commands.contains { $0.contains("UID MOVE") }, "no MOVE may run under the new numbering")
        XCTAssertEqual(server.messages(in: "INBOX").count, 6)
        XCTAssertTrue(server.messages(in: "[Gmail]/All Mail").isEmpty)
        let queued = await harness.pending.all()
        XCTAssertTrue(queued.isEmpty, "the cancelled action must not be replayed later")
    }

    func testDroppedOpConnectionIsReplacedAndTheNextOpenWorks() async throws {
        let server = harness.server
        let first = try await harness.syncer.body(for: try await harness.message(uid: 1, in: "INBOX"))
        XCTAssertEqual(first, FakeIMAPServer.message("inbox-1"))
        let loginsBefore = server.loginCount
        server.dropAllConnections()
        await assertEventually { server.openConnections == 0 }

        let second = try await within(10) { try await self.harness.syncer.body(for: try await self.harness.message(uid: 2, in: "INBOX")) }
        XCTAssertEqual(second, FakeIMAPServer.message("inbox-2"))
        XCTAssertEqual(server.loginCount, loginsBefore + 1, "exactly one new connection")
        let third = try await harness.syncer.body(for: try await harness.message(uid: 3, in: "INBOX"))
        XCTAssertEqual(third, FakeIMAPServer.message("inbox-3"))
        XCTAssertEqual(server.loginCount, loginsBefore + 1, "the new connection is kept")
    }

    func testByeOnTheOpConnectionDiscardsItAndTheNextCallReconnects() async throws {
        let server = harness.server
        _ = try await harness.syncer.body(for: try await harness.message(uid: 1, in: "INBOX"))
        let loginsBefore = server.loginCount
        server.byeOnNextCommand("Account exceeded command or bandwidth limits.", close: false)
        do {
            _ = try await within(10) { try await self.harness.syncer.body(for: try await self.harness.message(uid: 2, in: "INBOX")) }
            XCTFail("a throttle BYE must not be retried at once")
        } catch let failure as MailServiceError {
            XCTAssertEqual(failure.kind, .throttled)
            XCTAssertFalse(failure.sentence.contains("Protocol error"))
        }
        let body = try await within(10) { try await self.harness.syncer.body(for: try await self.harness.message(uid: 2, in: "INBOX")) }
        XCTAssertEqual(body, FakeIMAPServer.message("inbox-2"))
        XCTAssertEqual(server.loginCount, loginsBefore + 1)
    }

    func testMessageGoneFromTheServerSaysSoAndSyncsOnlyThatFolder() async throws {
        let server = harness.server
        let gone = try await harness.message(uid: 4, in: "INBOX")
        await harness.syncer.start()
        await assertEventually { server.idlingCount == 1 }
        server.remove(uid: 4, from: "INBOX")
        server.resetCounters()

        do {
            _ = try await harness.syncer.body(for: gone)
            XCTFail("the message is gone")
        } catch let failure as MailServiceError {
            XCTAssertEqual(failure.kind, .messageGone)
            XCTAssertEqual(failure.localizedDescription, "This message was moved or deleted on the server.")
        }
        await assertEventually("the row goes once the folder is synced") { !(try! await self.harness.uids(in: "INBOX")).contains(4) }
        let selects = server.commands.filter { $0.contains(" SELECT ") }
        XCTAssertFalse(selects.contains { $0.contains("Sent Mail") || $0.contains("Trash") }, "only INBOX is synced: \(selects)")
        XCTAssertFalse(server.commands.contains { $0.contains(" LIST ") }, "no full pass")
    }

    func testLoadOlderDoesNotWriteBackAStaleFolder() async throws {
        let server = harness.server
        for n in 7...12 { server.add(FakeIMAPServer.message("inbox-\(n)"), to: "INBOX") }
        let before = try await harness.folder("INBOX")
        var shrunk = before
        shrunk.oldestSyncedUID = 5
        try await harness.store.updateFolder(shrunk)
        try await harness.syncOnce()
        let synced = try await harness.folder("INBOX")
        XCTAssertEqual(synced.lastSyncedUID, 12)

        try await harness.syncer.loadOlder(folder: shrunk)
        let after = try await harness.folder("INBOX")
        XCTAssertEqual(after.oldestSyncedUID, 1)
        XCTAssertEqual(after.lastSyncedUID, 12, "the copy passed in was older than the sync; its cursor must not come back")
    }

    func testASavedDraftIsNeverStoredTwiceWhenTheConnectionDrops() async throws {
        let server = harness.server
        server.addMailbox("[Gmail]/Drafts", attributes: ["\\Drafts"])
        try await harness.syncOnce()
        let drafts = try await harness.folder("[Gmail]/Drafts")
        _ = try await harness.syncer.body(for: try await harness.message(uid: 1, in: "INBOX"))
        server.dropAllConnections()
        await assertEventually { server.openConnections == 0 }

        let draft = FakeIMAPServer.message("draft", from: "owner@example.com", to: "ana@example.com")
        do {
            try await harness.syncer.append(raw: draft, to: drafts, flags: [.draft, .seen], date: nil)
            XCTFail("the connection had gone")
        } catch let failure as MailServiceError {
            XCTAssertEqual(failure.kind, .connectionDropped)
        }
        XCTAssertTrue(server.messages(in: "[Gmail]/Drafts").isEmpty, "an APPEND is not repeated by itself")

        try await harness.syncer.append(raw: draft, to: drafts, flags: [.draft, .seen], date: nil)
        let stored = server.messages(in: "[Gmail]/Drafts")
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.data, draft)
        XCTAssertEqual(Set(stored.first?.flags ?? []), ["\\Draft", "\\Seen"])
    }

    func testCreatingAFolderUsesTheOpConnection() async throws {
        let server = harness.server
        _ = try await harness.syncer.body(for: try await harness.message(uid: 1, in: "INBOX"))
        let logins = server.loginCount
        try await harness.syncer.createMailbox(named: "Receipts")
        let made = await harness.store.folder(accountID: harness.account.id, path: "Receipts")
        XCTAssertNotNil(made)
        XCTAssertEqual(server.loginCount, logins, "no short-lived connection of its own")
    }
}
