import XCTest
import Foundation
@testable import FalconCore

/// The reading pane shows whatever row is chosen in the list, at once, however the rest of the
/// app is doing: the selection outlives the list being rebuilt under it, a message's text is
/// never waited for behind a connection that has gone quiet, readers of one message share one
/// fetch and stop waiting when they move on, and a web view is never handed to two readers.
final class ReaderFollowsSelectionTests: XCTestCase {
    private var harness: EngineHarness?

    override func tearDown() async throws {
        await harness?.finish()
        harness = nil
    }

    // MARK: - The selection outlives the list being rebuilt

    private let line = ReadMarking.messageLineTag

    func testASelectionStillListedIsLeftAlone() {
        let selected: Set<String> = ["b", line + "a2"]
        let kept = ReadingSelection.carried(selected, rows: ["a1", line + "a1", line + "a2", "b"],
                                            conversations: [["a1", "a2"], ["b"]])
        XCTAssertEqual(kept, selected)
    }

    func testAConversationRenamedByAReplyKeepsItsSelection() {
        // "a1" was the newest when the row was chosen; a reply "a0" now names the row.
        let kept = ReadingSelection.carried(["a1"], rows: ["a0", "b"], conversations: [["a0", "a1"], ["b"]])
        XCTAssertEqual(kept, ["a0"], "the reading pane stays on the conversation chosen")
    }

    func testAMessageLineOfAFoldedConversationFallsBackToItsRow() {
        let kept = ReadingSelection.carried([line + "a2"], rows: ["a1", "b"], conversations: [["a1", "a2"], ["b"]])
        XCTAssertEqual(kept, ["a1"])
    }

    func testAMessageLineStillShownUnderANewNewestKeepsItsLine() {
        let kept = ReadingSelection.carried([line + "a2"], rows: ["a0", line + "a0", line + "a1", line + "a2"],
                                            conversations: [["a0", "a1", "a2"]])
        XCTAssertEqual(kept, [line + "a2"])
    }

    func testAMessageNoLongerListedIsLetGo() {
        let kept = ReadingSelection.carried(["gone", "b"], rows: ["b"], conversations: [["b"]])
        XCTAssertEqual(kept, ["b"])
    }

    func testAConversationSplitIntoLoneMessagesKeepsTheMessageChosen() {
        // Conversations turned off: every message its own row, named by its own id.
        let kept = ReadingSelection.carried([line + "a2"], rows: ["a1", "a2"], conversations: [["a1"], ["a2"]])
        XCTAssertEqual(kept, ["a2"])
    }

    // MARK: - Fetches shared, waited for within a limit, and let go

    func testTwoReadersOfOneMessageShareOneFetch() async {
        let fetches = SharedFetches<String, Int>()
        let calls = Counter()
        let gate = Gate()
        async let first = fetches.value(for: "m", within: 5) { calls.add(); await gate.wait(); return 7 }
        await assertEventually { calls.count == 1 }
        async let second = fetches.value(for: "m", within: 5) { calls.add(); return 8 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        gate.open()
        let answers = await [first.value, second.value]
        XCTAssertEqual(answers, [7, 7], "the window and the pane read the same fetch")
        XCTAssertEqual(calls.count, 1, "no second fetch queued behind the first on the connection")
        XCTAssertEqual(fetches.inFlight, 0)
    }

    func testAReaderStopsWaitingAtItsDeadlineWhateverTheFetchIsDoing() async {
        let fetches = SharedFetches<String, Int>()
        let started = Date()
        let outcome = await fetches.value(for: "m", within: 0.2) { await Gate().wait(); return 1 }
        guard case .timedOut = outcome else { return XCTFail("\(outcome)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testAReaderThatMovesOnStopsWaitingAtOnceAndItsFetchIsCalledOff() async {
        let fetches = SharedFetches<String, Int>()
        let cancelled = Flag()
        let reader = Task {
            await fetches.value(for: "m", within: 60) {
                await withTaskCancellationHandler { await Gate().wait() } onCancel: { cancelled.set() }
                return 1
            }
        }
        await assertEventually { fetches.inFlight == 1 }
        let asked = Date()
        reader.cancel()
        let outcome = await reader.value
        guard case .cancelled = outcome else { return XCTFail("\(outcome)") }
        XCTAssertLessThan(Date().timeIntervalSince(asked), 1)
        await assertEventually("a fetch nobody waits for is not left queued") { cancelled.isSet }
        XCTAssertEqual(fetches.inFlight, 0)
    }

    func testAReaderMovingOnLeavesTheOtherReaderItsFetch() async {
        let fetches = SharedFetches<String, Int>()
        let gate = Gate()
        let pane = Task { await fetches.value(for: "m", within: 60) { await gate.wait(); return 3 } }
        await assertEventually { fetches.inFlight == 1 }
        let window = Task { await fetches.value(for: "m", within: 60) { 4 } }
        try? await Task.sleep(nanoseconds: 50_000_000)
        pane.cancel()
        gate.open()
        let answer = await window.value.value
        XCTAssertEqual(answer, 3)
    }

    func testAFetchThatRanOutOfTimeIsJoinedByTheNextReader() async {
        let fetches = SharedFetches<String, Int>()
        let calls = Counter()
        let gate = Gate()
        let first = await fetches.value(for: "m", within: 0.1) { calls.add(); await gate.wait(); return 5 }
        guard case .timedOut = first else { return XCTFail("\(first)") }
        async let again = fetches.value(for: "m", within: 5) { calls.add(); return 6 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        gate.open()
        let answer = await again.value
        XCTAssertEqual(answer, 5, "Try Again waits for the fetch already on its way")
        XCTAssertEqual(calls.count, 1)
    }

    func testAFetchStuckPastItsTimeIsNotWaitedBehind() async {
        let clock = TestClock()
        let fetches = SharedFetches<String, Int>(replacedAfter: 30, now: clock.reading)
        let first = await fetches.value(for: "m", within: 0.1) { await Gate().wait(); return 1 }
        guard case .timedOut = first else { return XCTFail("\(first)") }
        clock.advance(31)
        let second = await fetches.value(for: "m", within: 5) { 2 }
        XCTAssertEqual(second.value, 2, "a fresh fetch, not the one stuck")
    }

    func testDifferentMessagesNeverWaitForEachOther() async {
        let fetches = SharedFetches<String, Int>()
        let stuck = Task { await fetches.value(for: "old", within: 60) { await Gate().wait(); return 0 } }
        await assertEventually { fetches.inFlight == 1 }
        let started = Date()
        let answer = await fetches.value(for: "new", within: 5) { 9 }
        XCTAssertEqual(answer.value, 9)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        stuck.cancel()
    }

    // MARK: - A connection gone quiet does not hold the reader

    private func started() async throws -> EngineHarness {
        let server = try EngineHarness.gmailServer()
        server.add(FakeIMAPServer.message("first"), to: "INBOX")
        server.add(FakeIMAPServer.message("second"), to: "INBOX")
        // A second to sign in, so that a fresh connection to a server that has stopped
        // answering fails quickly too; replies keep the standard minute.
        let h = try await EngineHarness(server: server, deadlines: IMAPDeadlines(connect: 1))
        harness = h
        try await h.syncOnce()
        return h
    }

    func testAFetchForAReaderGivesUpASilentConnectionWithinItsPatienceAndTheNextOneWorks() async throws {
        let h = try await started()
        let first = try await h.message(uid: 1, in: "INBOX")
        let second = try await h.message(uid: 2, in: "INBOX")
        _ = try await h.syncer.body(for: first)
        h.server.blackHole()
        let asked = Date()
        do {
            _ = try await within(10) { try await h.syncer.parsedMessage(for: second, replyWithin: 0.5) }
            XCTFail("nothing answers")
        } catch let failure as MailServiceError {
            XCTAssertEqual(failure.kind, .connectionDropped)
        }
        XCTAssertLessThan(Date().timeIntervalSince(asked), 5, "well within the standard minute of silence")
        h.server.blackHole(false)
        let parsed = try await within(10) { try await h.syncer.parsedMessage(for: second, replyWithin: 5) }
        XCTAssertTrue(parsed.bestText.contains("This is message second."), "the next message opens on a fresh connection")
    }

    func testAQuietOpConnectionIsDroppedSoTheNextFetchDoesNotWaitBehindIt() async throws {
        let h = try await started()
        let first = try await h.message(uid: 1, in: "INBOX")
        let second = try await h.message(uid: 2, in: "INBOX")
        _ = try await h.syncer.body(for: first)
        // A fetch held on a connection that has died without a word, waiting its full minute.
        h.server.blackHole()
        let stuck = Task { try await h.syncer.body(for: second) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let fresh = await h.syncer.dropOpConnection(ifQuietFor: 0.2)
        XCTAssertTrue(fresh)
        do {
            _ = try await within(3) { try await stuck.value }
            XCTFail("the connection it waited on was closed")
        } catch is TimedOut {
            XCTFail("whatever held the quiet connection fails at once rather than holding its turn")
        } catch {}
        h.server.blackHole(false)
        let parsed = try await within(10) { try await h.syncer.parsedMessage(for: second, replyWithin: 5) }
        XCTAssertTrue(parsed.bestText.contains("This is message second."))
    }

    func testABusyConnectionIsNotDropped() async throws {
        let h = try await started()
        _ = try await h.syncer.body(for: try await h.message(uid: 1, in: "INBOX"))
        let dropped = await h.syncer.dropOpConnection(ifQuietFor: 30)
        XCTAssertFalse(dropped, "a connection that answered a moment ago is kept")
    }

    // MARK: - Web views reused, never shared

    @MainActor
    func testAnObjectOutIsNeverHandedOutAgain() {
        let pool = ReusePool<Box>(capacity: 4)
        let a = pool.take { Box() }
        let b = pool.take { Box() }
        XCTAssertFalse(a === b)
        XCTAssertTrue(pool.giveBack(a))
        XCTAssertFalse(pool.giveBack(a), "given back twice, it is kept once")
        let c = pool.take { Box() }
        let d = pool.take { Box() }
        XCTAssertTrue(c === a)
        XCTAssertFalse(d === a, "the one kept went to one reader only")
        XCTAssertFalse(d === b)
    }

    @MainActor
    func testAnObjectStillInUseIsNotKept() {
        let pool = ReusePool<Box>(capacity: 4) { !$0.inWindow }
        let a = pool.take { Box() }
        a.inWindow = true
        XCTAssertFalse(pool.giveBack(a), "a web view still in a window is not kept for another reader")
        XCTAssertEqual(pool.freeCount, 0)
        let b = pool.take { Box() }
        XCTAssertFalse(a === b)
    }

    @MainActor
    func testAKeptObjectThatCameIntoUseIsSkipped() {
        let pool = ReusePool<Box>(capacity: 4) { !$0.inWindow }
        let a = pool.take { Box() }
        XCTAssertTrue(pool.giveBack(a))
        a.inWindow = true
        let b = pool.take { Box() }
        XCTAssertFalse(a === b)
    }

    @MainActor
    func testAnUnusableObjectIsNeverKept() {
        let pool = ReusePool<Box>(capacity: 4)
        let a = pool.take { Box() }
        pool.markUnusable(a)
        XCTAssertFalse(pool.giveBack(a), "a web view whose process died is thrown away")
        let b = pool.take { Box() }
        XCTAssertFalse(a === b)
        XCTAssertTrue(pool.giveBack(b))
        pool.dropFree()
        XCTAssertEqual(pool.freeCount, 0)
        XCTAssertFalse(pool.take { Box() } === b, "none kept from a process that died")
    }

    @MainActor
    func testThePoolKeepsNoMoreThanItsCapacity() {
        let pool = ReusePool<Box>(capacity: 2)
        let boxes = (0..<3).map { _ in pool.take { Box() } }
        XCTAssertEqual(boxes.map { pool.giveBack($0) }, [true, true, false])
        XCTAssertFalse(pool.giveBack(Box()), "one it never handed out is not taken in")
        XCTAssertEqual(pool.outCount, 0)
    }
}

private final class Box {
    var inWindow = false
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// Holds whoever waits on it until it is opened; never opened, it holds them for good, as a
/// connection that stopped answering does.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resume: Bool = lock.withLock {
                if isOpen { return true }
                waiting.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }

    func open() {
        let all: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { waiting = [] }
            return waiting
        }
        all.forEach { $0.resume() }
    }
}
