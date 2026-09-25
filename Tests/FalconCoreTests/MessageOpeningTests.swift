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
}
