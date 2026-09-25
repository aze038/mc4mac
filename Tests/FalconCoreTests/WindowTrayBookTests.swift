import XCTest
@testable import FalconCore

final class WindowTrayBookTests: XCTestCase {
    private let draft = UUID()

    func testOpeningAMessageWithNoWindowOpensOne() {
        XCTAssertEqual(WindowTrayBook().opening(.message("m1")), .open)
    }

    func testOpeningTheSameMessageAgainBringsItsWindowForward() {
        var book = WindowTrayBook()
        book.showing(.message("m1"), title: "Quarterly figures")
        XCTAssertEqual(book.opening(.message("m1")), .bringForward)
        XCTAssertEqual(book.opening(.message("m2")), .open)
    }

    func testOpeningAMessageWhoseWindowIsInTheTrayTakesItOut() {
        var book = WindowTrayBook()
        book.showing(.message("m1"), title: "Quarterly figures")
        book.minimise(.message("m1"), title: "Quarterly figures")
        XCTAssertEqual(book.opening(.message("m1")), .restoreFromTray)
        XCTAssertTrue(book.restore(.message("m1")))
        XCTAssertEqual(book.opening(.message("m1")), .bringForward)
        XCTAssertTrue(book.tray.isEmpty)
    }

    func testMessageAndComposeWindowsShareTheTrayInTheOrderTheyWereMinimised() {
        var book = WindowTrayBook()
        book.showing(.compose(draft), title: "New Message")
        book.showing(.message("m1"), title: "Quarterly figures")
        book.minimise(.message("m1"), title: "Quarterly figures")
        book.minimise(.compose(draft), title: "Re: Site visit")
        XCTAssertEqual(book.tray.map(\.key), [.message("m1"), .compose(draft)])
        XCTAssertEqual(book.tray.map(\.title), ["Quarterly figures", "Re: Site visit"])
    }

    func testMinimisingAgainMovesAWindowToTheEndOfTheTray() {
        var book = WindowTrayBook()
        book.minimise(.message("m1"), title: "One")
        book.minimise(.message("m2"), title: "Two")
        book.restore(.message("m1"))
        book.minimise(.message("m1"), title: "")
        XCTAssertEqual(book.tray.map(\.key), [.message("m2"), .message("m1")])
        XCTAssertEqual(book.tray.last?.title, "One", "an empty title keeps the one it had")
    }

    func testRestoringSomethingNotInTheTrayDoesNothing() {
        var book = WindowTrayBook()
        XCTAssertFalse(book.restore(.message("m1")))
        book.showing(.message("m1"), title: "One")
        XCTAssertFalse(book.restore(.message("m1")))
    }

    func testAWindowComingForwardLeavesTheTray() {
        var book = WindowTrayBook()
        book.minimise(.compose(draft), title: "Re: Site visit")
        book.showing(.compose(draft), title: "")
        XCTAssertTrue(book.tray.isEmpty)
        XCTAssertEqual(book.entry(.compose(draft))?.title, "Re: Site visit")
    }

    func testClosingAWindowFromTheScreenOrTheTrayForgetsIt() {
        var book = WindowTrayBook()
        book.showing(.message("m1"), title: "One")
        book.minimise(.message("m2"), title: "Two")
        book.closed(.message("m1"))
        book.closed(.message("m2"))
        XCTAssertTrue(book.entries.isEmpty)
        XCTAssertEqual(book.opening(.message("m2")), .open)
    }

    // MARK: Sessions

    func testASessionListsEveryMessageWindowAndWhichWereInTheTray() {
        var book = WindowTrayBook()
        book.showing(.message("m1"), title: "One")
        book.showing(.compose(draft), title: "New Message")
        book.showing(.message("m2"), title: "Two")
        book.minimise(.message("m2"), title: "Two")
        book.minimise(.compose(draft), title: "New Message")
        let session = book.messageWindows
        XCTAssertEqual(session.all, ["m1", "m2"], "messages being written go to Drafts, not to the session")
        XCTAssertEqual(session.inTray, ["m2"])
    }

    func testALaunchOpensTheWindowsThatWereShowingAndTraysTheRest() {
        let restored = WindowTrayBook.restoring(messageWindows: ["m1", "m2", "m3"], inTray: ["m2"])
        XCTAssertEqual(restored.open, ["m1", "m3"])
        XCTAssertEqual(restored.tray, ["m2"])
    }

    func testASessionFromABuildThatDidNotRememberTheTrayOpensEveryWindow() {
        let restored = WindowTrayBook.restoring(messageWindows: ["m1", "m2"], inTray: nil)
        XCTAssertEqual(restored.open, ["m1", "m2"])
        XCTAssertTrue(restored.tray.isEmpty)
    }

    func testALaunchOpensEachMessageOnceAndOnlyThoseItLists() {
        let restored = WindowTrayBook.restoring(messageWindows: ["m1", "m1", "m2"], inTray: ["m2", "m9"])
        XCTAssertEqual(restored.open, ["m1"])
        XCTAssertEqual(restored.tray, ["m2"])
    }
}
