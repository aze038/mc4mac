import XCTest
@testable import FalconCore

final class MessageOpeningTests: XCTestCase {
    func testADoubleClickedMessageOpensInAWindowOfItsOwnUnlessTheOwnerChoseTabs() {
        XCTAssertTrue(MessageOpening.opensInWindow(stored: nil))
        XCTAssertEqual(MessageOpening.destination(inDraftsFolder: false, opensInWindow: MessageOpening.opensInWindow(stored: nil),
                                                  forceWindow: false), .window)
    }

    func testTheOwnersChoiceOfTabsOpensItInATab() {
        XCTAssertFalse(MessageOpening.opensInWindow(stored: false))
        XCTAssertEqual(MessageOpening.destination(inDraftsFolder: false, opensInWindow: false, forceWindow: false), .tab)
        XCTAssertTrue(MessageOpening.opensInWindow(stored: true))
    }

    func testOpenInSeparateWindowOpensAWindowWhateverWasChosen() {
        XCTAssertEqual(MessageOpening.destination(inDraftsFolder: false, opensInWindow: false, forceWindow: true), .window)
        XCTAssertEqual(MessageOpening.destination(inDraftsFolder: false, opensInWindow: true, forceWindow: true), .window)
    }

    func testADraftInDraftsOpensToBeWrittenHoweverItIsOpened() {
        for opensInWindow in [false, true] {
            for forceWindow in [false, true] {
                XCTAssertEqual(MessageOpening.destination(inDraftsFolder: true, opensInWindow: opensInWindow, forceWindow: forceWindow),
                               .editDraft)
            }
        }
    }

    func testTheSettingKeepsTheKeyEarlierBuildsRead() {
        XCTAssertEqual(MessageOpening.preferenceKey, "openInWindowOnDoubleClick")
    }

    // MARK: The Message menu

    func testTheMessageMenuActsOnTheMessageInAMessageWindowNotTheSelection() {
        XCTAssertEqual(MenuTarget.of(front: .message("m7"), writingInMailbox: false), .messageWindow("m7"))
        XCTAssertEqual(MenuTarget.of(front: .message("m7"), writingInMailbox: true), .messageWindow("m7"))
    }

    func testTheMessageMenuActsOnNothingWhileAMessageIsBeingWritten() {
        XCTAssertEqual(MenuTarget.of(front: .compose(UUID()), writingInMailbox: false), .nothing)
        XCTAssertEqual(MenuTarget.of(front: nil, writingInMailbox: true), .nothing)
    }

    func testTheMessageMenuActsOnTheSelectionInTheMailboxWindow() {
        XCTAssertEqual(MenuTarget.of(front: nil, writingInMailbox: false), .selection)
    }

    // MARK: Opening a message found only on Gmail

    /// The waits an opener asked for.
    private final class Waits: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: [TimeInterval] = []
        var all: [TimeInterval] { lock.withLock { seconds } }
        func add(_ wait: TimeInterval) { lock.withLock { seconds.append(wait) } }
    }

    private func opener(_ mailbox: FakeGmailMailbox, waits: Waits = Waits()) -> GmailOpener {
        GmailOpener(client: GmailTestKit.client(mailbox), settle: 0.3) { seconds in
            waits.add(seconds)
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    func testAMessageWindowsOpenIsSentAtOnce() async throws {
        let mailbox = FakeGmailMailbox()
        let message = mailbox.add(subject: "Contract")
        let waits = Waits()
        let opener = opener(mailbox, waits: waits)
        let started = Date()
        let opened = try await opener.openText(id: message.id, trigger: .asked)
        XCTAssertEqual(opened.message.subject, "Contract")
        XCTAssertEqual(waits.all, [], "a window, Return, Command-O, Reply and Forward never wait")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.3)
        XCTAssertEqual(mailbox.attempts[.messagesGet], 1)
    }

    func testThreeArrowKeyMovesWithinTheSettleTimeSendOneOpen() async throws {
        let mailbox = FakeGmailMailbox()
        let rows = (0..<3).map { mailbox.add(subject: "Row \($0)") }
        let opener = opener(mailbox)
        // The reading pane's selection moves down three rows, one every 20 ms, and nothing cancels
        // the opens it began: the opener itself gives up the rows passed over.
        var opens: [Task<GmailOpenedMessage, Error>] = []
        for row in rows {
            opens.append(Task { try await opener.openText(id: row.id, trigger: .selectionMoved) })
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        for passed in opens.dropLast() {
            do {
                _ = try await passed.value
                XCTFail("a row passed over is never opened")
            } catch is CancellationError {}
        }
        let stayed = try await opens[2].value
        XCTAssertEqual(stayed.message.subject, "Row 2")
        XCTAssertEqual(mailbox.attempts[.messagesGet], 1, "three moves, one open")
    }

    func testReplyWhileThePaneWaitsOpensAtOnceAndThePaneUsesThatOpen() async throws {
        let mailbox = FakeGmailMailbox()
        let message = mailbox.add(subject: "Figures")
        let opener = opener(mailbox)
        let pane = Task { try await opener.openText(id: message.id, trigger: .selectionMoved) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let reply = try await opener.openText(id: message.id, trigger: .asked)
        XCTAssertEqual(mailbox.attempts[.messagesGet], 1, "Reply did not wait for the pane")
        let shown = try await pane.value
        XCTAssertEqual(reply.message.subject, "Figures")
        XCTAssertEqual(shown.message.subject, "Figures")
        XCTAssertEqual(mailbox.attempts[.messagesGet], 1, "the pane shows what Reply fetched")
    }
}
