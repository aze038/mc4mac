import XCTest
@testable import FalconCore

final class UnsentMessageTests: XCTestCase {
    /// What closing does for a message that came from `origin` and was then changed or not, the
    /// way ComposeDraft takes its digests: when it opens, and again as it closes.
    private func closing(_ origin: UnsentMessage.Origin, opened: String, now: String, blank: Bool = false) -> UnsentMessage.Closing {
        let openedDigest = origin.remembersOpening ? UnsentMessage.fingerprint([Data(opened.utf8)]) : nil
        return UnsentMessage.closing(openedDigest: openedDigest, digest: UnsentMessage.fingerprint([Data(now.utf8)]), blank: blank)
    }

    func testClosingANewMessageWithSomethingWrittenSavesItToDrafts() {
        XCTAssertEqual(closing(.new, opened: "\n\n-- \nAlex", now: "Figures attached\n\n-- \nAlex"), .saveToDrafts)
    }

    func testClosingANewMessageAsItOpenedOrWithNothingInItJustCloses() {
        XCTAssertEqual(closing(.new, opened: "\n\n-- \nAlex", now: "\n\n-- \nAlex"), .closeQuietly)
        XCTAssertEqual(closing(.new, opened: "", now: "typed then deleted", blank: true), .closeQuietly)
    }

    func testClosingAReplySavesItOnceSomethingIsWritten() {
        XCTAssertEqual(closing(.reply, opened: "Re: Figures|quoted", now: "Thanks!|Re: Figures|quoted"), .saveToDrafts)
        // The message it answers still holds everything in an untouched reply.
        XCTAssertEqual(closing(.reply, opened: "Re: Figures|quoted", now: "Re: Figures|quoted"), .closeQuietly)
    }

    func testClosingADraftReopenedFromDraftsSavesOnlyWhatChanged() {
        XCTAssertEqual(closing(.reopenedDraft, opened: "Plan v1", now: "Plan v2"), .saveToDrafts)
        // Its copy in Drafts already holds it as it is.
        XCTAssertEqual(closing(.reopenedDraft, opened: "Plan v1", now: "Plan v1"), .closeQuietly)
    }

    func testAMessageCalledBackFromTheOutboxIsNeverDroppedByClosing() {
        XCTAssertEqual(closing(.outboxRecall, opened: "Invoice", now: "Invoice"), .saveToDrafts)
        XCTAssertEqual(closing(.outboxRecall, opened: "Invoice", now: "Invoice, corrected"), .saveToDrafts)
    }

    func testAMessageBroughtBackByUndoIsSavedEvenUnchanged() {
        XCTAssertEqual(closing(.undoneDiscard, opened: "Plan v1", now: "Plan v1"), .saveToDrafts)
    }

    func testAnEmptyMessageJustClosesWhereverItCameFrom() {
        for origin in UnsentMessage.Origin.allCases {
            XCTAssertEqual(closing(origin, opened: "x", now: "", blank: true), .closeQuietly, "\(origin)")
        }
    }

    func testOnlyOutboxRecallsAndUndoneDiscardsForgetHowTheyOpened() {
        XCTAssertEqual(UnsentMessage.Origin.allCases.filter { !$0.remembersOpening }, [.outboxRecall, .undoneDiscard])
    }

    func testTheFingerprintChangesWithAnyPartAndWithTextMovedBetweenParts() {
        let parts = ["ann@example.com", "", "Figures", "Hello"].map { Data($0.utf8) }
        XCTAssertEqual(UnsentMessage.fingerprint(parts), UnsentMessage.fingerprint(parts))
        XCTAssertNotEqual(UnsentMessage.fingerprint(parts),
                          UnsentMessage.fingerprint(["ann@example.com", "", "Figures", "Hello!"].map { Data($0.utf8) }))
        XCTAssertNotEqual(UnsentMessage.fingerprint(["ab", "c"].map { Data($0.utf8) }),
                          UnsentMessage.fingerprint(["a", "bc"].map { Data($0.utf8) }))
    }

    // MARK: Discard

    private let account = UUID()
    private let drafts = UUID()

    private func row(uid: UInt32, subject: String) -> MessageSummary {
        MessageSummary(accountID: account, folderID: drafts, uid: uid, messageID: "<\(uid)@example.com>", inReplyTo: "",
                       references: [], subject: subject, from: EmailAddress(name: "Alex", address: "alex@example.com"),
                       to: [], cc: [], date: Date(timeIntervalSince1970: 1_790_000_000), flags: [.draft, .seen], size: 100,
                       hasAttachments: false)
    }

    func testDiscardTakesTheDraftsCopyTheMessageWasReopenedFrom() {
        let opened = row(uid: 41, subject: "Plan")
        XCTAssertEqual(UnsentMessage.draftCopy(openedFrom: opened, recordedID: opened.id), opened)
    }

    func testDiscardLeavesDraftsAloneForAMessageNotReopenedFromThere() {
        XCTAssertNil(UnsentMessage.draftCopy(openedFrom: nil, recordedID: nil))
        // A draft kept by an earlier build recorded only an id, never the row.
        XCTAssertNil(UnsentMessage.draftCopy(openedFrom: nil, recordedID: row(uid: 41, subject: "Plan").id))
    }

    func testDiscardLeavesAnotherDraftsRowAlone() {
        let opened = row(uid: 41, subject: "Plan")
        let other = row(uid: 42, subject: "Budget")
        XCTAssertNil(UnsentMessage.draftCopy(openedFrom: opened, recordedID: other.id))
    }

    func testUndoBringsBackTheDiscardedMessageWithinTenSeconds() {
        var discarded = DiscardedMessage<String>()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        discarded.discard("Plan v2", now: now)
        XCTAssertTrue(discarded.offersUndo(at: now.addingTimeInterval(9.9)))
        XCTAssertEqual(discarded.undo(at: now.addingTimeInterval(9.9)), "Plan v2")
        XCTAssertNil(discarded.held, "a message brought back is no longer held")
        XCTAssertNil(discarded.undo(at: now.addingTimeInterval(9.9)))
    }

    func testUndoIsNoLongerOfferedOnceTenSecondsHavePassed() {
        var discarded = DiscardedMessage<String>()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        discarded.discard("Plan v2", now: now)
        XCTAssertFalse(discarded.offersUndo(at: now.addingTimeInterval(10)))
        XCTAssertNil(discarded.undo(at: now.addingTimeInterval(10)))
    }

    func testOnlyTheLastDiscardedMessageCanBeBroughtBack() {
        var discarded = DiscardedMessage<String>()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let first = discarded.discard("Plan", now: now)
        discarded.discard("Budget", now: now.addingTimeInterval(2))
        // The first one's banner going does not take the second one's away.
        discarded.letGo(first.id)
        XCTAssertEqual(discarded.undo(at: now.addingTimeInterval(3)), "Budget")
    }

    func testTheBannerGoingLetsTheMessageGo() {
        var discarded = DiscardedMessage<String>()
        let held = discarded.discard("Plan", now: Date(timeIntervalSince1970: 1_790_000_000))
        discarded.letGo(held.id)
        XCTAssertNil(discarded.undo(at: Date(timeIntervalSince1970: 1_790_000_001)))
    }
}
