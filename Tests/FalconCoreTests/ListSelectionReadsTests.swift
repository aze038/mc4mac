import XCTest
@testable import FalconCore

/// The table's selection read into the app's (see `ListSelectionReads`): the reading pane
/// switches to rows the moment they are selected, a newer selection always wins over a read that
/// ends late or never, and a command on the selection acts on the rows shown selected, never on
/// those selected before.
@MainActor
final class ListSelectionReadsTests: XCTestCase {
    private let account = UUID()

    private func target(_ n: UInt64, _ kind: SelectedListRow.Kind = .message) -> ListReadingTarget {
        ListReadingTarget(key: .gmail(account: account, id: GmailMessageID(raw: 0x1000 + n)), kind: kind)
    }

    private func placeholder(_ t: ListReadingTarget, _ subject: String) -> ListReadingPlaceholder {
        ListReadingPlaceholder(targets: [t], subject: subject, snippet: "Preview of \(subject)")
    }

    /// Holds a read until the test lets it go, or for ever.
    @MainActor
    private final class Gate {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private(set) var entered = false
        func wait() async {
            entered = true
            await withCheckedContinuation { waiting.append($0) }
        }
        func open() {
            let all = waiting
            waiting = []
            for c in all { c.resume() }
        }
    }

    private var gates: [Gate] = []

    override func tearDown() async throws {
        // Reads the test left hanging end now, so nothing leaks past it.
        for gate in gates { gate.open() }
        gates = []
    }

    private func gate() -> Gate {
        let made = Gate()
        gates.append(made)
        return made
    }

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// The app's selection, as `EngineList` hands it over.
    private var appSelection: [ListReadingTarget] = []

    private func read(_ reads: ListSelectionReads, _ t: ListReadingTarget, subject: String, gate: Gate? = nil) {
        reads.start([t], placeholder: placeholder(t, subject)) { [weak self] generation in
            if let gate { await gate.wait() }
            guard let self, reads.isCurrent(generation) else { return }
            self.appSelection = [t]
            reads.handOver(generation)
        }
    }

    // MARK: - F2: commands act on the rows shown selected

    func testDeletePressedWhileTheNextRowIsReadDeletesThatRowNeverTheOneBefore() async {
        let reads = ListSelectionReads()
        let a = target(1), b = target(2)
        read(reads, a, subject: "A")
        await until { reads.shownTargets == [a] }
        XCTAssertEqual(appSelection, [a])

        // Down arrow: B is selected and read from Gmail, which takes a while.
        let slow = gate()
        read(reads, b, subject: "B", gate: slow)
        XCTAssertEqual(reads.placeholder?.targets, [b], "the pane shows B at once")
        XCTAssertEqual(reads.placeholder?.subject, "B")
        await until { slow.entered }

        // Delete, while B is still being read.
        var deleted: [ListReadingTarget]?
        XCTAssertTrue(reads.whenRead { deleted = self.appSelection })
        XCTAssertNil(deleted, "nothing is deleted while the app's selection is still A")

        slow.open()
        await until { deleted != nil }
        XCTAssertEqual(deleted, [b], "B, the row shown selected, is the one deleted; A stays")
        XCTAssertNil(reads.placeholder)
        XCTAssertFalse(reads.isReading)

        // Once read, a command runs at once.
        var again: [ListReadingTarget]?
        reads.whenRead { again = self.appSelection }
        XCTAssertEqual(again, [b])
    }

    func testACommandGivenForOneRowIsDroppedWhenTheSelectionMovesOnBeforeItIsRead() async {
        let reads = ListSelectionReads()
        let b = target(2), c = target(3)
        let slow = gate()
        read(reads, b, subject: "B", gate: slow)
        var acted: [ListReadingTarget]?
        reads.whenRead { acted = self.appSelection }
        read(reads, c, subject: "C")
        await until { reads.shownTargets == [c] }
        slow.open()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(acted, "a Delete meant for B never reaches C, nor B once the owner moved on")
        XCTAssertEqual(appSelection, [c])
    }

    // MARK: - The reading pane switches at once, whatever an earlier read does

    func testAReadThatNeverReturnsDoesNotStopALaterSelectionBeingShown() async {
        let reads = ListSelectionReads()
        let stuck = target(7), next = target(8), third = target(9)

        // The read of this row never returns, as when Gmail stops answering after a day.
        let never = gate()
        read(reads, stuck, subject: "Stuck", gate: never)
        XCTAssertEqual(reads.placeholder?.targets, [stuck], "the pane shows the row at once")
        await until { never.entered }

        // The owner selects another row: the pane switches to it at once, then shows its message.
        read(reads, next, subject: "Next")
        XCTAssertEqual(reads.placeholder?.targets, [next], "switched at once, not after the stuck read")
        XCTAssertEqual(reads.placeholder?.subject, "Next")
        await until { reads.shownTargets == [next] }
        XCTAssertEqual(appSelection, [next])
        XCTAssertNil(reads.placeholder)

        // And again: every later selection is shown, however many.
        read(reads, third, subject: "Third")
        await until { reads.shownTargets == [third] }
        XCTAssertEqual(appSelection, [third])
    }

    func testAnOlderReadThatFinishesLateNeverReplacesANewerSelection() async {
        let reads = ListSelectionReads()
        let old = target(1), new = target(2)
        let late = gate()
        read(reads, old, subject: "Old", gate: late)
        await until { late.entered }
        read(reads, new, subject: "New")
        await until { reads.shownTargets == [new] }
        late.open()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(appSelection, [new], "the newer selection wins")
        XCTAssertEqual(reads.shownTargets, [new])
        XCTAssertNil(reads.placeholder)

        // A generation overtaken hands nothing over, even called directly.
        let first = reads.start([old], placeholder: placeholder(old, "Old")) { _ in }
        reads.start([new], placeholder: placeholder(new, "New")) { _ in }
        XCTAssertFalse(reads.handOver(first))
        XCTAssertNil(reads.placeholder, "the pane already shows New, and keeps it")
        XCTAssertEqual(reads.shownTargets, [new])
    }

    func testAfterTheDeadlineThePaneShowsThePreviewWithTryAgainAndTheMessageStillFillsIn() async {
        let reads = ListSelectionReads(deadline: 0.05)
        let slow = target(4)
        let held = gate()
        read(reads, slow, subject: "Slow", gate: held)
        await until { reads.placeholder?.timedOut == true }
        XCTAssertEqual(reads.placeholder?.timedOut, true, "the pane offers Try Again")
        XCTAssertEqual(reads.placeholder?.snippet, "Preview of Slow", "with the row's preview")
        var ran = false
        XCTAssertFalse(reads.whenRead { ran = true }, "a command given now is not kept waiting for ever")

        // The message arrives late: it still shows, since nothing newer was selected.
        held.open()
        await until { reads.shownTargets == [slow] }
        XCTAssertEqual(appSelection, [slow])
        XCTAssertNil(reads.placeholder)
        XCTAssertFalse(ran)

        // Try Again reads the same rows afresh, the pane saying it is reading again.
        let retry = gate()
        let twice = target(5)
        read(reads, twice, subject: "Twice", gate: retry)
        await until { reads.placeholder?.timedOut == true }
        read(reads, twice, subject: "Twice")
        XCTAssertEqual(reads.placeholder?.timedOut, false)
        await until { reads.shownTargets == [twice] }
    }

    func testReadingAgainTheRowsTheAppAlreadyHoldsKeepsThePaneAsItIs() async {
        let reads = ListSelectionReads()
        let a = target(1)
        read(reads, a, subject: "A")
        await until { reads.shownTargets == [a] }
        // The row changed elsewhere, as when it was flagged on the phone: it is read again, and
        // the pane keeps showing the message meanwhile.
        let slow = gate()
        read(reads, a, subject: "A", gate: slow)
        XCTAssertNil(reads.placeholder)
        XCTAssertTrue(reads.isReading)
        slow.open()
        await until { !reads.isReading }
    }

    func testStoppingDropsWhatWaitsAndShowsNothing() async {
        let reads = ListSelectionReads()
        let held = gate()
        read(reads, target(1), subject: "A", gate: held)
        var ran = false
        reads.whenRead { ran = true }
        reads.stop()
        XCTAssertFalse(reads.isReading)
        XCTAssertNil(reads.placeholder)
        held.open()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(ran)
        XCTAssertTrue(appSelection.isEmpty)
    }

    func testThePlaceholderIsWhatTheRowSays() {
        let content = RowContentStore()
        let t = target(1)
        let from = EmailAddress(name: "Ann", address: "ann@example.com")
        content.insert(MessageRowContent(key: t.key, from: from, to: [], subject: "Invoice", preview: "Please find",
                                         date: Date(timeIntervalSince1970: 1_700_000_000)), for: t.key)
        let one = ListReadingPlaceholder.of([t], content: content)
        XCTAssertEqual(one.subject, "Invoice")
        XCTAssertEqual(one.from, from)
        XCTAssertEqual(one.snippet, "Please find")
        XCTAssertFalse(one.timedOut)
        let unknown = ListReadingPlaceholder.of([target(2)], content: content)
        XCTAssertEqual(unknown.subject, "")
        XCTAssertEqual(ListReadingPlaceholder.of([t, target(2)], content: content).targets.count, 2)
    }
}
