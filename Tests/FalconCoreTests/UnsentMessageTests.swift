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

    // MARK: Saving to Drafts, Discard and Undo, across a quit

    /// A message being written, as ComposeDraft is in the app: what it says, and the copy in
    /// Drafts it is linked to, if any.
    private struct Written: Codable, Sendable, Identifiable, Equatable {
        var id = UUID()
        var text: String
        var copy: String?
    }

    /// The server's Drafts folder: each copy's text by its id.
    @MainActor
    private final class DraftsFolder {
        var copies: [String: String] = [:]
        var saves = 0

        /// A save adds a copy in place of the one the message is linked to.
        func save(_ message: Written) {
            saves += 1
            if let copy = message.copy { copies[copy] = nil }
            copies["saved-\(saves)"] = message.text
        }

        func delete(_ copy: String) { copies[copy] = nil }
    }

    /// Holds a save's answer back until the test gives it.
    private actor Answer {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var given = false

        func wait() async {
            guard !given else { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func give() {
            given = true
            waiting.forEach { $0.resume() }
            waiting = []
        }
    }

    private struct Offline: Error {}

    private func dataDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("UnsentDrafts-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// One launch of FalconMail over the files kept in `directory`.
    @MainActor
    private func launch(_ directory: URL, _ folder: DraftsFolder) -> UnsentDrafts<Written, String> {
        let unsent = UnsentDrafts<Written, String>(directory: directory)
        unsent.deleteCopy = { folder.delete($0) }
        return unsent
    }

    private func filesOnThisMac(_ directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    @MainActor
    func testTheFileOnThisMacStaysUntilTheServerAnswersTheSave() async {
        let directory = dataDirectory()
        let folder = DraftsFolder()
        let unsent = launch(directory, folder)
        let message = Written(text: "Figures attached")
        let answer = Answer()
        let saving = unsent.save(message) { message in
            await answer.wait()
            folder.save(message)
        }
        // Its window closes, which lets go of it, while the server has not yet answered.
        unsent.forget(message.id)
        await Task.yield()
        XCTAssertEqual(filesOnThisMac(directory), ["\(message.id.uuidString).json"], "kept on this Mac while the save is under way")
        XCTAssertTrue(unsent.isSaving(message.id))
        await answer.give()
        let failure = await saving.value
        XCTAssertNil(failure)
        XCTAssertEqual(Array(folder.copies.values), ["Figures attached"])
        XCTAssertEqual(filesOnThisMac(directory), [], "gone from this Mac once the server has it")
    }

    @MainActor
    func testASaveTheServerRefusesKeepsTheMessageOnThisMac() async {
        let directory = dataDirectory()
        let folder = DraftsFolder()
        let unsent = launch(directory, folder)
        let message = Written(text: "Figures attached")
        let failure = await unsent.save(message) { _ in throw Offline() }.value
        XCTAssertTrue(failure is Offline)
        XCTAssertEqual(launch(directory, folder).leftovers(), [message], "the next launch saves it")
    }

    @MainActor
    func testAQuitBeforeTheServerAnswersSavesTheMessageExactlyOnceAtTheNextLaunch() async {
        let directory = dataDirectory()
        let folder = DraftsFolder()
        folder.copies["draft-41"] = "Plan v1"
        // A draft reopened from Drafts, changed and closed; FalconMail quits before the server
        // answers. The quit waits for it, but no longer than it allows.
        let message = Written(text: "Plan v2", copy: "draft-41")
        let first = launch(directory, folder)
        let unanswered = first.save(message) { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) }
        first.forget(message.id)
        let finished = await first.finish(within: 0.1)
        XCTAssertFalse(finished)
        XCTAssertEqual(filesOnThisMac(directory), ["\(message.id.uuidString).json"])
        // The process ends with the save still unanswered.
        unanswered.cancel()
        _ = await unanswered.value

        let second = launch(directory, folder)
        let left = second.leftovers()
        XCTAssertEqual(left, [message], "the next launch finds it, still linked to its copy in Drafts")
        let saving = second.save(left[0]) { folder.save($0) }
        XCTAssertEqual(second.leftovers(), [], "one being saved is not left over a second time")
        let failure = await saving.value
        XCTAssertNil(failure)
        XCTAssertEqual(launch(directory, folder).leftovers(), [], "nor at the launch after")
        XCTAssertEqual(folder.saves, 1, "saved exactly once")
        XCTAssertEqual(folder.copies, ["saved-1": "Plan v2"], "in place of its old copy, not beside it")
        XCTAssertEqual(filesOnThisMac(directory), [])
    }

    @MainActor
    func testSavesOfOneMessageNeverOvertakeOneAnother() async {
        let directory = dataDirectory()
        let folder = DraftsFolder()
        let unsent = launch(directory, folder)
        var message = Written(text: "Plan v1")
        let answer = Answer()
        let first = unsent.save(message) { message in
            await answer.wait()
            folder.save(message)
        }
        message.text = "Plan v2"
        // The second save is held too, so what stays on this Mac is looked at before it can end,
        // whichever task runs first once the first save is answered.
        let secondAnswer = Answer()
        let second = unsent.save(message) { message in
            await secondAnswer.wait()
            folder.save(message)
        }
        await Task.yield()
        XCTAssertEqual(folder.saves, 0, "the newer save waits for the one under way")
        await answer.give()
        _ = await first.value
        XCTAssertEqual(filesOnThisMac(directory).count, 1, "the newer content stays on this Mac until it is saved")
        await secondAnswer.give()
        _ = await second.value
        XCTAssertEqual(folder.copies["saved-2"], "Plan v2", "the newest content is saved last")
        XCTAssertEqual(filesOnThisMac(directory), [])
    }

    @MainActor
    func testDiscardThenQuitWithinTheUndoWindowLeavesNothingInDraftsOrOnThisMac() async {
        let directory = dataDirectory()
        let folder = DraftsFolder()
        folder.copies["draft-41"] = "Plan v1"
        let unsent = launch(directory, folder)
        let message = Written(text: "Plan v2", copy: "draft-41")
        unsent.keep(message)
        unsent.discard(message.id, copy: message.copy)
        XCTAssertEqual(folder.copies["draft-41"], "Plan v1", "its copy in Drafts stays while Undo is offered")
        let finished = await unsent.finish(within: 5)
        XCTAssertTrue(finished)
        XCTAssertEqual(folder.copies, [:], "nothing in Drafts")
        XCTAssertEqual(filesOnThisMac(directory), [], "nothing on this Mac")
        XCTAssertEqual(launch(directory, folder).leftovers(), [], "and nothing comes back at the next launch")
    }

    @MainActor
    func testACopyTheQuitCouldNotDeleteGoesAtTheNextLaunchAndTheMessageNeverComesBack() async {
        let directory = dataDirectory()
        let folder = DraftsFolder()
        folder.copies["draft-41"] = "Plan v1"
        let first = launch(directory, folder)
        first.deleteCopy = { _ in throw Offline() }
        let message = Written(text: "Plan v2", copy: "draft-41")
        first.keep(message)
        first.discard(message.id, copy: message.copy)
        _ = await first.finish(within: 5)
        XCTAssertEqual(folder.copies["draft-41"], "Plan v1")
        XCTAssertEqual(filesOnThisMac(directory), ["\(message.id.uuidString).discarded"], "only the marker is on this Mac")
        // As if a crash had come between writing the marker and taking the message's file away.
        first.keep(message)

        let second = launch(directory, folder)
        XCTAssertEqual(second.leftovers(), [], "a discarded message is never saved back to Drafts")
        let deleted = await Waiting.upTo(5, for: second.deleteDiscarded())
        XCTAssertTrue(deleted)
        XCTAssertEqual(folder.copies, [:])
        XCTAssertEqual(filesOnThisMac(directory), [])
    }

    @MainActor
    func testOnceUndoIsOverTheCopyInDraftsIsDeleted() async {
        let directory = dataDirectory()
        let folder = DraftsFolder()
        folder.copies["draft-41"] = "Plan v1"
        let unsent = launch(directory, folder)
        let message = Written(text: "Plan v2", copy: "draft-41")
        unsent.keep(message)
        unsent.discard(message.id, copy: message.copy)
        unsent.undoEnded(message.id)
        let deleted = await unsent.finish(within: 5)
        XCTAssertTrue(deleted)
        XCTAssertEqual(folder.copies, [:])
        XCTAssertEqual(filesOnThisMac(directory), [])
    }

    @MainActor
    func testUndoWithinTheWindowKeepsTheSavedCopyAndTheLinkToIt() async {
        let directory = dataDirectory()
        let folder = DraftsFolder()
        folder.copies["draft-41"] = "Plan v1"
        let unsent = launch(directory, folder)
        let message = Written(text: "Plan v2", copy: "draft-41")
        unsent.keep(message)
        unsent.discard(message.id, copy: message.copy)
        unsent.undoDiscard(message)
        // The window's end arriving late, and a quit, change nothing once Undo was pressed.
        unsent.undoEnded(message.id)
        let finished = await unsent.finish(within: 5)
        XCTAssertTrue(finished)
        XCTAssertEqual(folder.copies, ["draft-41": "Plan v1"], "the saved copy stays")
        XCTAssertEqual(filesOnThisMac(directory), ["\(message.id.uuidString).json"], "and the message is on this Mac again")
        let reopened = launch(directory, folder).leftovers()
        XCTAssertEqual(reopened.first?.copy, "draft-41", "still linked to its copy")
        // Closed again, it takes that copy's place rather than adding a second.
        let failure = await unsent.save(message) { folder.save($0) }.value
        XCTAssertNil(failure)
        XCTAssertEqual(folder.copies, ["saved-1": "Plan v2"])
    }

    func testOpeningADraftAlreadyBeingWrittenBringsThatOneForward() {
        let open = UUID()
        let other = UUID()
        let among: [(draft: UUID, row: String?)] = [(other, nil), (open, "a|d|41")]
        XCTAssertEqual(UnsentMessage.alreadyOpen(row: "a|d|41", among: among), open)
        XCTAssertNil(UnsentMessage.alreadyOpen(row: "a|d|42", among: among))
    }
}
