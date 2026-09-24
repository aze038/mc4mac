import XCTest
@testable import FalconCore

/// The op connection carries everything the reader asks for. These are the races that gave the
/// owner "Protocol error", hangs, and actions landing on the wrong message.
final class OpConnectionTests: XCTestCase {
    private var harness: EngineHarness!
    private var raced: EngineHarness?

    override func setUp() async throws {
        let server = try EngineHarness.gmailServer(latency: 0.004)
        for n in 1...6 { server.add(FakeIMAPServer.message("inbox-\(n)"), to: "INBOX") }
        for n in 1...6 { server.add(FakeIMAPServer.message("sent-\(n)", from: "owner@example.com", to: "ana@example.com"), to: "[Gmail]/Sent Mail") }
        harness = try await EngineHarness(server: server)
        try await harness.syncOnce()
    }

    override func tearDown() async throws {
        await raced?.finish()
        await harness.finish()
    }

    // MARK: The races the connection's turn prevents
    //
    // Each is run many times with the turn, as FalconMail always takes it, and must never go
    // wrong; and then with the same calls taking less of it, as the engine did before, where it
    // must go wrong, so that the test is known to catch the race at all.

    /// An account like the one `setUp` makes, whose op connections take `turns` of the turn and
    /// give up on a second's silence, since without the turn a reply can go to the wrong reader
    /// and leave the right one waiting.
    private func account(turns: IMAPClient.TurnTaking) async throws -> EngineHarness {
        let server = try EngineHarness.gmailServer(latency: 0.004)
        for n in 1...6 { server.add(FakeIMAPServer.message("inbox-\(n)"), to: "INBOX") }
        for n in 1...6 { server.add(FakeIMAPServer.message("sent-\(n)", from: "owner@example.com", to: "ana@example.com"), to: "[Gmail]/Sent Mail") }
        let h = try await EngineHarness(server: server, deadlines: IMAPDeadlines(connect: 5, response: 1, idleGrace: 1), turns: turns)
        raced = h
        try await h.syncOnce()
        return h
    }

    private enum Opened: Equatable {
        case whole, anotherMessage, broken, hung
    }

    /// Opens UIDs 1 to 6 of INBOX and of Sent, which name different messages, all at once on
    /// one op connection, none of them kept from an earlier open.
    private func openTwelveAtOnce(_ h: EngineHarness) async throws -> [Opened] {
        for path in ["INBOX", "[Gmail]/Sent Mail"] { try await h.store.folderStore(try await h.folder(path)).clearBodies() }
        var opens: [(expected: Data, message: MessageSummary)] = []
        for uid in UInt32(1)...6 {
            opens.append((FakeIMAPServer.message("inbox-\(uid)"), try await h.message(uid: uid, in: "INBOX")))
            opens.append((FakeIMAPServer.message("sent-\(uid)", from: "owner@example.com", to: "ana@example.com"),
                          try await h.message(uid: uid, in: "[Gmail]/Sent Mail")))
        }
        let everyBody = Set(opens.map(\.expected))
        let syncer = h.syncer
        let tasks = opens.map { open in Task { try await syncer.body(for: open.message) } }
        var outcomes: [Opened] = []
        for (task, open) in zip(tasks, opens) {
            do {
                let body = try await within(5) { try await task.value }
                outcomes.append(body == open.expected ? .whole : everyBody.contains(body) ? .anotherMessage : .broken)
            } catch is TimedOut {
                task.cancel()
                outcomes.append(.hung)
            } catch {
                outcomes.append(.broken)
            }
        }
        return outcomes
    }

    func testConcurrentOpensReturnIntactBodiesAndNoneHangs() async throws {
        let logins = harness.server.loginCount
        for round in 1...20 {
            let outcomes = try await openTwelveAtOnce(harness)
            XCTAssertEqual(outcomes, Array(repeating: .whole, count: 12), "round \(round)")
        }
        XCTAssertEqual(harness.server.loginCount, logins + 1, "one op connection for every open of every round")
    }

    func testWithoutTheTurnConcurrentOpensMixUpTheirReplies() async throws {
        let h = try await account(turns: .none)
        var outcomes: [Opened] = []
        for _ in 1...10 where outcomes.allSatisfy({ $0 == .whole }) {
            outcomes = try await openTwelveAtOnce(h)
        }
        XCTAssertTrue(outcomes.contains { $0 != .whole },
                      "with nothing keeping two conversations apart on one connection, opens get another's reply, a broken one or none")
    }

    func testWithoutTheUnitAnOpenGetsTheOtherFoldersMessage() async throws {
        let h = try await account(turns: .perCommand)
        var outcomes: [Opened] = []
        for _ in 1...10 where !outcomes.contains(.anotherMessage) {
            outcomes = try await openTwelveAtOnce(h)
        }
        XCTAssertTrue(outcomes.contains(.anotherMessage),
                      "with another folder selected between an open's SELECT and its FETCH, the open gets the message with its UID there: \(outcomes)")
    }

    private struct ArchiveDuringOpen {
        var archivedTheRightMessage: Bool
        var movedTheOpenMessage: Bool
        var opened: Data?
    }

    /// Archives INBOX's message with a UID that Sent has too, and while its SELECT of INBOX is on
    /// its way opens Sent's message with that UID: a MOVE run with Sent selected takes the
    /// message being opened instead.
    private func archiveDuringAnOpen(_ h: EngineHarness, uid: UInt32) async throws -> ArchiveDuringOpen {
        let server = h.server
        let inboxData = FakeIMAPServer.message("inbox-\(uid)")
        let sentData = FakeIMAPServer.message("sent-\(uid)")
        server.add(inboxData, to: "INBOX", uid: uid)
        server.add(sentData, to: "[Gmail]/Sent Mail", uid: uid)
        try await h.syncOnce()
        await h.syncer.setUndoWindow(0)
        let inboxMessage = try await h.message(uid: uid, in: "INBOX")
        let sentMessage = try await h.message(uid: uid, in: "[Gmail]/Sent Mail")
        server.resetCounters()

        server.stallNext("SELECT", seconds: 0.3)
        let syncer = h.syncer
        _ = try await syncer.archive([inboxMessage])
        await assertEventually { server.commands.contains { $0.contains("SELECT \"INBOX\"") } }
        let open = Task { try await syncer.body(for: sentMessage) }
        let opened = try? await within(10) { try await open.value }
        await assertEventually { await h.pending.all().isEmpty }
        let archived = server.messages(in: "[Gmail]/All Mail").map(\.data)
        return ArchiveDuringOpen(archivedTheRightMessage: archived.contains(inboxData) && !server.messages(in: "INBOX").contains { $0.data == inboxData },
                                 movedTheOpenMessage: archived.contains(sentData) || !server.messages(in: "[Gmail]/Sent Mail").contains { $0.data == sentData },
                                 opened: opened)
    }

    func testArchiveCommittedDuringAnOpenInAnotherFolderLandsInTheRightMailbox() async throws {
        for round in UInt32(1)...10 {
            let uid = 100 + round
            let outcome = try await archiveDuringAnOpen(harness, uid: uid)
            XCTAssertTrue(outcome.archivedTheRightMessage, "round \(round): the archived message is in All Mail")
            XCTAssertFalse(outcome.movedTheOpenMessage, "round \(round): the message open in Sent stays where it is")
            XCTAssertEqual(outcome.opened, FakeIMAPServer.message("sent-\(uid)"), "round \(round)")
        }
    }

    func testWithoutTheUnitAnArchiveDuringAnOpenMovesTheWrongMessage() async throws {
        let h = try await account(turns: .perCommand)
        var outcomes: [ArchiveDuringOpen] = []
        for round in UInt32(1)...5 where !outcomes.contains(where: \.movedTheOpenMessage) {
            outcomes.append(try await archiveDuringAnOpen(h, uid: 100 + round))
        }
        let wrong = try XCTUnwrap(outcomes.last)
        XCTAssertTrue(wrong.movedTheOpenMessage, "with Sent selected between the archive's SELECT and its MOVE, the MOVE takes Sent's message")
        XCTAssertFalse(wrong.archivedTheRightMessage, "and leaves the one archived in INBOX")
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

    func testByeOnAUsedOpConnectionIsTriedOnceMoreOnANewOne() async throws {
        let server = harness.server
        _ = try await harness.syncer.body(for: try await harness.message(uid: 1, in: "INBOX"))
        let loginsBefore = server.loginCount
        server.byeOnNextCommand("Session expired", close: false)
        let body = try await within(10) { try await self.harness.syncer.body(for: try await self.harness.message(uid: 2, in: "INBOX")) }
        XCTAssertEqual(body, FakeIMAPServer.message("inbox-2"))
        XCTAssertEqual(server.loginCount, loginsBefore + 1, "the connection that said BYE was replaced once")
    }

    func testThrottleByeOnTheOpConnectionPausesWhatFollows() async throws {
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
        server.resetCounters()
        do {
            _ = try await within(10) { try await self.harness.syncer.body(for: try await self.harness.message(uid: 3, in: "INBOX")) }
            XCTFail("Gmail asked for quiet")
        } catch let failure as MailServiceError {
            XCTAssertEqual(failure.kind, .throttled)
        }
        XCTAssertTrue(server.commands.isEmpty, "nothing is asked of the server during the pause: \(server.commands)")
        XCTAssertEqual(server.loginCount, loginsBefore)
    }

    func testAStaleRowAfterARenumberingOpensAndActsOnNothing() async throws {
        let server = harness.server
        await harness.syncer.setUndoWindow(0)
        let stale = try await harness.message(uid: 1, in: "INBOX")
        // Renumbered on the server and synced: UID 1 now names inbox-6, while a message tab or
        // a selection still holds the row read for inbox-1.
        server.renumber("INBOX")
        try await harness.syncOnce()
        let now = try await harness.message(uid: 1, in: "INBOX")
        XCTAssertEqual(now.messageID, "<inbox-6@example.com>")

        do {
            _ = try await harness.syncer.body(for: stale)
            XCTFail("the row names a message that is no longer at that UID")
        } catch let failure as MailServiceError {
            XCTAssertEqual(failure.kind, .messageGone)
        }
        for act in [{ try await self.harness.syncer.archive([stale]) },
                    { try await self.harness.syncer.setFlag(.flagged, on: [stale], enabled: true) },
                    { try await self.harness.syncer.delete([stale]) }] as [@Sendable () async throws -> [MailActionRecord]] {
            do {
                _ = try await act()
                XCTFail("nothing may be done to whichever message now has the UID")
            } catch let failure as MailServiceError {
                XCTAssertEqual(failure.kind, .messageGone)
            }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(server.messages(in: "INBOX").count, 6)
        XCTAssertTrue(server.messages(in: "[Gmail]/All Mail").isEmpty)
        XCTAssertTrue(server.messages(in: "[Gmail]/Trash").isEmpty)
        XCTAssertFalse(server.messages(in: "INBOX").contains { $0.flags.contains("\\Flagged") })
        let untouched = try await harness.message(uid: 1, in: "INBOX")
        XCTAssertFalse(untouched.isFlagged, "the row now at UID 1 keeps its own flags")
        let queued = await harness.pending.all()
        XCTAssertTrue(queued.isEmpty)
    }

    func testOnlyTheRowsStillCurrentAreActedOn() async throws {
        let server = harness.server
        await harness.syncer.setUndoWindow(0)
        let kept = try await harness.message(uid: 2, in: "INBOX")
        let gone = try await harness.message(uid: 3, in: "INBOX")
        server.remove(uid: 3, from: "INBOX")
        try await harness.syncOnce()
        let records = try await harness.syncer.archive([kept, gone])
        XCTAssertEqual(records.flatMap(\.messages).map(\.uid), [2])
        await assertEventually { server.messages(in: "[Gmail]/All Mail").count == 1 }
        XCTAssertEqual(server.messages(in: "[Gmail]/All Mail").first?.data, FakeIMAPServer.message("inbox-2"))
    }

    func testAStaleTrashRowIsNeverPurged() async throws {
        let server = harness.server
        for n in 1...3 { server.add(FakeIMAPServer.message("trash-\(n)"), to: "[Gmail]/Trash") }
        try await harness.syncOnce()
        await harness.syncer.setUndoWindow(0)
        let stale = try await harness.message(uid: 1, in: "[Gmail]/Trash")
        server.renumber("[Gmail]/Trash")
        try await harness.syncOnce()
        do {
            _ = try await harness.syncer.purge([stale])
            XCTFail("UID 1 now names trash-3")
        } catch let failure as MailServiceError {
            XCTAssertEqual(failure.kind, .messageGone)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(server.messages(in: "[Gmail]/Trash").count, 3, "nothing deleted for good")
        XCTAssertFalse(server.commands.contains { $0.contains("EXPUNGE") })
    }

    func testAnActionThatFailsAfterARenumberingPutsBackNoStaleRow() async throws {
        let server = harness.server
        await harness.syncer.setUndoWindow(0.5)
        let target = try await harness.message(uid: 1, in: "INBOX")
        _ = try await harness.syncer.archive([target])
        server.renumber("INBOX")
        try await harness.syncOnce()
        await assertEventually { await !self.harness.events.actionFailures.isEmpty }
        let row = try await harness.message(uid: 1, in: "INBOX")
        XCTAssertEqual(row.messageID, "<inbox-6@example.com>", "the row the renumbering put at UID 1 is not replaced by the one from before")
        XCTAssertTrue(server.messages(in: "[Gmail]/All Mail").isEmpty)
    }

    func testRulesRunOneActionAtATimeSoAnOpenGetsIn() async throws {
        let server = harness.server
        for n in 7...150 { server.add(FakeIMAPServer.message("inbox-\(n)"), to: "INBOX") }
        try await harness.syncOnce()
        try await harness.rules.save([RuleDefinition(name: "Flag", conditions: [RuleCondition(field: .subject, op: .contains, value: "Message")],
                                                     actions: [RuleAction(kind: .flag)])])
        let sent = try await harness.message(uid: 1, in: "[Gmail]/Sent Mail")
        let syncer = harness.syncer
        server.resetCounters()
        let run = Task { try await syncer.runRulesOnInbox() }
        await assertEventually { server.commands.filter { $0.contains("UID STORE") }.count >= 3 }
        let started = Date()
        let body = try await within(10) { try await syncer.body(for: sent) }
        let waited = Date().timeIntervalSince(started)
        let storesBefore = server.commands.filter { $0.contains("UID STORE") }.count
        XCTAssertEqual(body, FakeIMAPServer.message("sent-1", from: "owner@example.com", to: "ana@example.com"))
        XCTAssertLessThan(storesBefore, 150, "the open went in while the rules still ran")
        XCTAssertLessThan(waited, 0.5)
        try await within(20) { try await run.value }
        await assertEventually { server.messages(in: "INBOX").filter { $0.flags.contains("\\Flagged") }.count == 150 }
    }

    func testWorkQueuedBehindAConnectionThatDiedIsTriedOnANewOne() async throws {
        let server = harness.server
        await harness.syncer.setUndoWindow(0)
        let opens = try await (1...3).asyncMap { try await self.harness.message(uid: UInt32($0), in: "INBOX") }
        let archived = try await harness.message(uid: 4, in: "INBOX")
        server.resetCounters()
        // Everything asks while the op connection is still signing in, so all share it, new;
        // then its first command is in flight when the link drops.
        server.stallNext("AUTHENTICATE", seconds: 0.4)
        server.stallNext("SELECT", seconds: 0.8)
        let syncer = harness.syncer
        let results = opens.map { m in Task { try await syncer.body(for: m) } }
        _ = try await syncer.archive([archived])
        await assertEventually { server.commands.contains { $0.contains(" SELECT ") } }
        server.dropAllConnections()

        var failed = 0
        for (i, task) in results.enumerated() {
            do {
                let body = try await within(10) { try await task.value }
                XCTAssertEqual(body, FakeIMAPServer.message("inbox-\(i + 1)"))
            } catch {
                failed += 1
            }
        }
        await assertEventually {
            if server.messages(in: "[Gmail]/All Mail").count == 1 { return true }
            let failures = await self.harness.events.actionFailures
            return !failures.isEmpty
        }
        failed += await harness.events.actionFailures.count
        XCTAssertEqual(failed, 1, "only the command in flight when the link dropped fails; what waited behind it sent nothing and is tried again")
    }

    func testLoadOlderDuringAPassKeepsItsCursor() async throws {
        let server = harness.server
        for n in 7...12 { server.add(FakeIMAPServer.message("inbox-\(n)"), to: "INBOX") }
        try await harness.syncOnce()
        try await harness.store.updateFolder(try await harness.folder("INBOX").id) { $0.oldestSyncedUID = 5 }
        server.resetCounters()
        server.stallNext("UID SEARCH", seconds: 0.8)
        let pass = Task { try await self.harness.syncOnce() }
        await assertEventually { server.commands.contains { $0.contains("UID SEARCH") } }
        try await harness.syncer.loadOlder(folder: try await harness.folder("INBOX"))
        let loaded = try await harness.folder("INBOX")
        XCTAssertEqual(loaded.oldestSyncedUID, 1)
        try await within(10) { try await pass.value }
        let after = try await harness.folder("INBOX")
        XCTAssertEqual(after.oldestSyncedUID, 1, "the pass that ran meanwhile does not put back the cursor it started with")
        XCTAssertEqual(after.lastSyncedUID, 12)
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

        // Gone before the server asked for the message: nothing reached it, so the draft is
        // saved on a new connection.
        let draft = FakeIMAPServer.message("draft", from: "owner@example.com", to: "ana@example.com")
        try await harness.syncer.append(raw: draft, to: drafts, flags: [.draft, .seen], date: nil)
        let stored = server.messages(in: "[Gmail]/Drafts")
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.data, draft)
        XCTAssertEqual(Set(stored.first?.flags ?? []), ["\\Draft", "\\Seen"])

        // Gone once the message was on its way: the server may have stored it, so it is not
        // sent again.
        server.loseNextAppendReply()
        do {
            try await harness.syncer.append(raw: FakeIMAPServer.message("draft-2", from: "owner@example.com"), to: drafts,
                                            flags: [.draft, .seen], date: nil)
            XCTFail("its answer never came")
        } catch let failure as MailServiceError {
            XCTAssertEqual(failure.kind, .connectionDropped)
        }
        XCTAssertEqual(server.messages(in: "[Gmail]/Drafts").count, 2, "an APPEND that went out is not repeated by itself")
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

extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        for element in self { out.append(try await transform(element)) }
        return out
    }
}
