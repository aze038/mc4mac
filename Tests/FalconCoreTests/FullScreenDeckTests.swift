import XCTest
@testable import FalconCore

/// The message and compose windows laid out inside the mailbox window while it fills the screen,
/// as Legacy Outlook lays out its own, and the tabs they go to when minimised.
final class FullScreenLayoutTests: XCTestCase {
    /// A 1728 × 1117 point screen, the mailbox window under the 37 point band at its top and its
    /// 35.5 point status bar at its foot, as Outlook was captured.
    private let area = CGRect(x: 0, y: 35.5, width: 1728, height: 1080 - 35.5)
    private let message = CGSize(width: 917, height: 1006)
    private let compose = CGSize(width: 966, height: 1006)

    func testOneWindowKeepsItsOwnSizeAndStandsInTheMiddle() {
        XCTAssertEqual(FullScreenLayout.frames(for: [message], in: area), [CGRect(x: 406, y: 55, width: 917, height: 1006)])
    }

    func testTwoWindowsShareTheWidthSideBySideEachKeepingItsHeight() {
        let frames = FullScreenLayout.frames(for: [message, compose], in: area)
        XCTAssertEqual(frames, [CGRect(x: 36, y: 55, width: 810, height: 1006), CGRect(x: 882, y: 55, width: 810, height: 1006)])
        XCTAssertEqual(frames[1].minX - frames[0].maxX, FullScreenLayout.margin, "the gap between them is their margin")
        XCTAssertEqual(area.maxX - frames[1].maxX, FullScreenLayout.margin)
    }

    func testAShorterWindowStandsInTheMiddleOfTheHeightBesideATallerOne() {
        let frames = FullScreenLayout.frames(for: [message, CGSize(width: 700, height: 600)], in: area)
        XCTAssertEqual(frames[1].height, 600)
        XCTAssertEqual(frames[1].midY, frames[0].midY, accuracy: 1)
    }

    func testAWindowTallerOrWiderThanTheSpaceIsCutToIt() {
        let small = CGRect(x: 0, y: 30, width: 1280, height: 800)
        XCTAssertEqual(FullScreenLayout.frames(for: [CGSize(width: 2000, height: 1006)], in: small),
                       [CGRect(x: 36, y: 48, width: 1208, height: 764)])
    }

    func testOnANarrowerScreenTwoWindowsCloseUpBeforeTheyGrowTooNarrow() {
        let frames = FullScreenLayout.frames(for: [message, compose], in: CGRect(x: 0, y: 30, width: 1280, height: 770))
        XCTAssertEqual(frames.map(\.width), [600, 600])
        XCTAssertEqual(frames[0].minX, 27)
        XCTAssertEqual(frames[1].minX, 653)
    }

    func testFramesFollowAnAreaOnAnotherScreen() {
        let right = area.offsetBy(dx: 1728, dy: 0)
        XCTAssertEqual(FullScreenLayout.frames(for: [message], in: right), [CGRect(x: 2134, y: 55, width: 917, height: 1006)])
        XCTAssertEqual(FullScreenLayout.frames(for: [message, compose], in: right).map(\.minX), [1764, 2610])
    }

    func testNoWindowsHaveNoFrames() {
        XCTAssertEqual(FullScreenLayout.frames(for: [], in: area), [])
    }

    func testTwoFitSideBySideOnlyWhenBothCanBeTheirNarrowest() {
        XCTAssertEqual(FullScreenLayout.capacity(forWidth: 1728), 2)
        XCTAssertEqual(FullScreenLayout.capacity(forWidth: 1512), 2)
        XCTAssertEqual(FullScreenLayout.capacity(forWidth: 1236), 2)
        XCTAssertEqual(FullScreenLayout.capacity(forWidth: 1235), 1)
        XCTAssertEqual(FullScreenLayout.capacity(forWidth: 1024), 1)
    }

    // MARK: Tabs

    func testOneTabIsAsWideAsATabMayBeAndMoreShareTheBand() {
        let band = 1728 - 2 * FullScreenLayout.tabSideRoom
        XCTAssertEqual(FullScreenLayout.tabWidth(count: 1, band: band), 812)
        XCTAssertEqual(FullScreenLayout.tabWidth(count: 2, band: band), 593, "Outlook's two tabs are 593.6 points wide")
        XCTAssertEqual(FullScreenLayout.tabWidth(count: 5, band: band), 234)
        XCTAssertEqual(FullScreenLayout.tabWidth(count: 0, band: band), 0)
        XCTAssertEqual(FullScreenLayout.tabWidth(count: 3, band: 0), 0)
    }
}

final class FullScreenDeckTests: XCTestCase {
    private let a = PopupKey.message("a")
    private let b = PopupKey.message("b")
    private let draft = PopupKey.compose(UUID())

    func testWindowsStandInTheOrderTheyCameOnScreenLeftToRight() {
        var deck = FullScreenDeck()
        XCTAssertEqual(deck.show(a, capacity: 2), [])
        XCTAssertEqual(deck.show(draft, capacity: 2), [])
        XCTAssertEqual(deck.showing, [a, draft])
    }

    func testAThirdWindowSendsTheOneInFrontLeastRecentlyToItsTab() {
        var deck = FullScreenDeck()
        deck.show(a, capacity: 2)
        deck.show(b, capacity: 2)
        deck.cameForward(a)
        XCTAssertEqual(deck.show(draft, capacity: 2), [b])
        XCTAssertEqual(deck.showing, [a, draft], "the new one comes in on the right")
    }

    func testWithoutAnyWindowComingForwardTheOldestGoes() {
        var deck = FullScreenDeck()
        deck.show(a, capacity: 2)
        deck.show(b, capacity: 2)
        XCTAssertEqual(deck.show(draft, capacity: 2), [a])
        XCTAssertEqual(deck.showing, [b, draft])
    }

    func testWhereOnlyOneFitsTheNewOneTakesItsPlace() {
        var deck = FullScreenDeck()
        deck.show(a, capacity: 1)
        XCTAssertEqual(deck.show(b, capacity: 1), [a])
        XCTAssertEqual(deck.showing, [b])
    }

    func testShowingAWindowAlreadyShowingOnlyBringsItForward() {
        var deck = FullScreenDeck()
        deck.show(a, capacity: 2)
        deck.show(b, capacity: 2)
        XCTAssertEqual(deck.show(a, capacity: 2), [])
        XCTAssertEqual(deck.showing, [a, b])
        XCTAssertEqual(deck.show(draft, capacity: 2), [b], "a came forward, so b is the one in front least recently")
    }

    func testAWindowMinimisedOrClosedLeavesTheOtherAlone() {
        var deck = FullScreenDeck()
        deck.show(a, capacity: 2)
        deck.show(b, capacity: 2)
        deck.hide(a)
        XCTAssertEqual(deck.showing, [b])
        deck.hide(a)
        XCTAssertEqual(deck.showing, [b], "hiding one not showing changes nothing")
    }

    func testANarrowerScreenSendsAllButTheOneInFrontToTabs() {
        var deck = FullScreenDeck()
        deck.show(a, capacity: 2)
        deck.show(b, capacity: 2)
        deck.cameForward(a)
        XCTAssertEqual(deck.fit(capacity: 1), [b])
        XCTAssertEqual(deck.showing, [a])
        XCTAssertEqual(deck.fit(capacity: 0), [], "the one in front always stays")
    }

    // MARK: Command-`

    func testCommandBacktickGoesFromTheMailboxWindowThroughThoseShowingLeftToRightAndRound() {
        var deck = FullScreenDeck()
        deck.show(a, capacity: 2)
        deck.show(draft, capacity: 2)
        XCTAssertEqual(deck.next(after: .mailbox, backwards: false), .window(a))
        XCTAssertEqual(deck.next(after: .window(a), backwards: false), .window(draft))
        XCTAssertEqual(deck.next(after: .window(draft), backwards: false), .mailbox)
    }

    func testWithShiftItGoesTheOtherWay() {
        var deck = FullScreenDeck()
        deck.show(a, capacity: 2)
        deck.show(draft, capacity: 2)
        XCTAssertEqual(deck.next(after: .mailbox, backwards: true), .window(draft))
        XCTAssertEqual(deck.next(after: .window(draft), backwards: true), .window(a))
        XCTAssertEqual(deck.next(after: .window(a), backwards: true), .mailbox)
    }

    func testWithNothingShowingCommandBacktickIsLeftToMacOS() {
        XCTAssertNil(FullScreenDeck().next(after: .mailbox, backwards: false))
        var deck = FullScreenDeck()
        deck.show(a, capacity: 2)
        deck.hide(a)
        XCTAssertNil(deck.next(after: .mailbox, backwards: true))
    }

    func testFromAWindowNotShowingItGoesOnFromTheMailboxWindow() {
        var deck = FullScreenDeck()
        deck.show(a, capacity: 2)
        XCTAssertEqual(deck.next(after: .window(b), backwards: false), .window(a))
    }

    // MARK: Keys answered while the mailbox window fills the screen

    private func key(_ code: UInt16, _ characters: String?, command: Bool = false, shift: Bool = false, option: Bool = false,
                     control: Bool = false, function: Bool = false) -> FullScreenKey? {
        FullScreenKey(keyCode: code, characters: characters, command: command, shift: shift, option: option, control: control,
                      function: function)
    }

    func testCommandBacktickGoesRoundAndWithShiftTheOtherWay() {
        XCTAssertEqual(key(50, "`", command: true), .cycle(backwards: false))
        XCTAssertEqual(key(50, "~", command: true, shift: true), .cycle(backwards: true))
        XCTAssertNil(key(50, "`"), "backtick alone is typed")
        XCTAssertNil(key(50, "`", command: true, option: true))
    }

    func testCommandMSendsTheWindowInFrontToItsTab() {
        XCTAssertEqual(key(46, "m", command: true), .minimise)
        XCTAssertNil(key(46, "m", command: true, shift: true), "Command-Shift-M is Move to Folder")
        XCTAssertNil(key(46, "m", command: true, option: true), "Command-Option-M is left to the Window menu")
        XCTAssertNil(key(46, "m"))
    }

    func testControlCommandFAndGlobeFLeaveFullScreen() {
        XCTAssertEqual(key(3, "f", command: true, control: true), .leaveFullScreen)
        XCTAssertEqual(key(3, "f", function: true), .leaveFullScreen)
        XCTAssertNil(key(3, "f", command: true), "Command-F is Find")
        XCTAssertNil(key(3, "f", command: true, shift: true, control: true))
        XCTAssertNil(key(3, "f", control: true))
        XCTAssertNil(key(3, "f"))
    }

    func testOnALayoutWithoutLatinLettersTheKeysPlaceCounts() {
        XCTAssertEqual(key(46, "ь", command: true), .minimise)
        XCTAssertEqual(key(3, "а", command: true, control: true), .leaveFullScreen)
        XCTAssertNil(key(45, "т", command: true))
        XCTAssertNil(key(46, "n", command: true), "on a Latin layout the letter counts, wherever it is")
    }

    // MARK: Minimising and bringing back, with the tray

    /// The tray and the windows showing, kept together as the window tray keeps them.
    private struct Screen {
        var book = WindowTrayBook()
        var deck = FullScreenDeck()
        let capacity = 2

        mutating func open(_ key: PopupKey, _ title: String) {
            book.showing(key, title: title)
            for sent in deck.show(key, capacity: capacity) { minimise(sent) }
        }

        mutating func minimise(_ key: PopupKey) {
            book.minimise(key, title: "")
            deck.hide(key)
        }

        mutating func restore(_ key: PopupKey) {
            book.restore(key)
            for sent in deck.show(key, capacity: capacity) { minimise(sent) }
        }

        mutating func close(_ key: PopupKey) {
            book.closed(key)
            deck.hide(key)
        }
    }

    func testMinimisingPutsATabInTheStatusBarAndClickingItBringsTheWindowBackOnTheRight() {
        var screen = Screen()
        screen.open(a, "Delivery on Friday")
        screen.open(b, "Quarterly figures")
        screen.minimise(a)
        XCTAssertEqual(screen.deck.showing, [b])
        XCTAssertEqual(screen.book.tray.map(\.key), [a])
        XCTAssertEqual(screen.book.tray.map(\.title), ["Delivery on Friday"])
        screen.restore(a)
        XCTAssertEqual(screen.deck.showing, [b, a])
        XCTAssertTrue(screen.book.tray.isEmpty)
    }

    func testBringingBackAThirdSendsTheOneInFrontLeastRecentlyToTheEndOfTheTabs() {
        var screen = Screen()
        screen.open(a, "One")
        screen.open(b, "Two")
        screen.open(draft, "Re: Two")
        XCTAssertEqual(screen.deck.showing, [b, draft])
        XCTAssertEqual(screen.book.tray.map(\.key), [a])
        screen.deck.cameForward(b)
        screen.restore(a)
        XCTAssertEqual(screen.deck.showing, [b, a])
        XCTAssertEqual(screen.book.tray.map(\.key), [draft])
        XCTAssertEqual(screen.book.entry(draft)?.title, "Re: Two", "its tab keeps its title")
    }

    func testClosingAWindowLeavesTheOtherShowingAndTheTabsAsTheyWere() {
        var screen = Screen()
        screen.open(a, "One")
        screen.open(b, "Two")
        screen.open(draft, "Re: Two")
        screen.close(draft)
        XCTAssertEqual(screen.deck.showing, [b])
        XCTAssertEqual(screen.book.tray.map(\.key), [a])
        screen.close(a)
        XCTAssertTrue(screen.book.tray.isEmpty)
        XCTAssertEqual(screen.book.opening(a), .open)
    }
}
