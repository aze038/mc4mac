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
}
