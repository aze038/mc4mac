import XCTest
@testable import FalconCore

final class UnsentMessageTests: XCTestCase {
    func testAMessageAsItWasOpenedOrWithNothingInItClosesWithoutAsking() {
        XCTAssertEqual(UnsentMessage.closing(untouched: true, blank: false), .discardQuietly)
        XCTAssertEqual(UnsentMessage.closing(untouched: false, blank: true), .discardQuietly)
        XCTAssertEqual(UnsentMessage.closing(untouched: true, blank: true), .discardQuietly)
    }

    func testAMessageWithSomethingWrittenAsksFirst() {
        XCTAssertEqual(UnsentMessage.closing(untouched: false, blank: false), .ask)
    }

    func testTheAlertReadsAsOutlooksWithItsButtonsInOutlooksOrder() {
        XCTAssertEqual(UnsentMessage.alertTitle, "You are closing a message that has not been sent.")
        XCTAssertEqual(UnsentMessage.alertMessage,
                       "To save the message, click Save as Draft. The message will be saved in your Drafts folder.")
        XCTAssertEqual(UnsentMessage.Choice.allCases.map(\.title), ["Save as Draft", "Discard Changes", "Continue Writing"])
    }

    func testReturnSavesAndEscapeGoesBackToTheMessage() {
        XCTAssertEqual(UnsentMessage.Choice.allCases.filter { $0.keyEquivalent == "\r" }, [.saveAsDraft])
        XCTAssertEqual(UnsentMessage.Choice.allCases.filter { $0.keyEquivalent == "\u{1b}" }, [.continueWriting])
    }

    func testOnlySaveKeepsTheDraftAndOnlyContinueKeepsTheWindow() {
        XCTAssertEqual(UnsentMessage.Choice.allCases.map(\.closes), [true, true, false])
        XCTAssertEqual(UnsentMessage.Choice.allCases.map(\.keepsDraft), [true, false, false])
    }

    func testTheFingerprintChangesWithAnyPartAndWithTextMovedBetweenParts() {
        let parts = ["ann@example.com", "", "Figures", "Hello"].map { Data($0.utf8) }
        XCTAssertEqual(UnsentMessage.fingerprint(parts), UnsentMessage.fingerprint(parts))
        XCTAssertNotEqual(UnsentMessage.fingerprint(parts),
                          UnsentMessage.fingerprint(["ann@example.com", "", "Figures", "Hello!"].map { Data($0.utf8) }))
        XCTAssertNotEqual(UnsentMessage.fingerprint(["ab", "c"].map { Data($0.utf8) }),
                          UnsentMessage.fingerprint(["a", "bc"].map { Data($0.utf8) }))
    }
}
