import XCTest
@testable import FalconCore

/// Every cell of the design's table of actions by folder, every move target, and what happens to
/// a change between the click and Gmail: held, undone, sent, retried, refused, replayed after a
/// relaunch, and dropped after a day. Everything runs against the in-memory Gmail.
final class GmailActionTests: XCTestCase {
    private var fixtures: [ActionsFixture] = []

    override func tearDown() async throws {
        for fixture in fixtures { await fixture.cleanUp() }
        fixtures = []
    }

    private func fixture(clock: ActionClock = ActionClock(), undoWindow: TimeInterval = 0) async throws -> ActionsFixture {
        let made = try await ActionsFixture(clock: clock, undoWindow: undoWindow)
        fixtures.append(made)
        return made
    }

    // MARK: - The table, cell by cell

    private struct Cell {
        var name: String
        var folder: String
        var verb: (ActionsFixture) -> MailActionRequest.Verb
        var before: (ActionsFixture) -> Set<GmailLabelID>
        /// Nil when the action is refused in that folder.
        var after: ((ActionsFixture) -> Set<GmailLabelID>)?
        var notice: String? = nil
    }

    private func move(_ name: String) -> (ActionsFixture) -> MailActionRequest.Verb {
        { .move(to: $0.folders[name]!.id) }
    }

    private func copy(_ name: String) -> (ActionsFixture) -> MailActionRequest.Verb {
        { .copy(to: $0.folders[name]!.id) }
    }

    private func labels(_ fixed: Set<GmailLabelID>, _ user: [String] = []) -> (ActionsFixture) -> Set<GmailLabelID> {
        { f in fixed.union(user.map { f.label($0) }) }
    }

    private func run(_ cells: [Cell], file: StaticString = #filePath, line: UInt = #line) async throws {
        let f = try await fixture()
        for cell in cells {
            let ref = try await f.add(cell.name, labels: cell.before(f))
            let context: ListView = cell.folder == "search" ? ListView(scope: .search(UUID())) : f.view(cell.folder)
            let request = MailActionRequest(verb: cell.verb(f), targets: .items([.message(f.key(ref))]), context: context)
            guard let expected = cell.after else {
                do {
                    _ = try await f.actions.perform(request)
                    XCTFail("\(cell.name): should be refused", file: file, line: line)
                } catch let error as GmailActionError {
                    XCTAssertFalse(error.sentence.isEmpty, cell.name, file: file, line: line)
                }
                XCTAssertEqual(f.gmailLabels(ref), cell.before(f), "\(cell.name): Gmail is untouched", file: file, line: line)
                let shown = await f.shown(ref)
                XCTAssertEqual(shown, cell.before(f), "\(cell.name): the row is untouched", file: file, line: line)
                continue
            }
            let receipt = try await f.actions.perform(request)
            if let notice = cell.notice { XCTAssertEqual(receipt.notice, notice, cell.name, file: file, line: line) }
            let shown = await f.shown(ref)
            XCTAssertEqual(shown, expected(f), "\(cell.name): the row changes at once", file: file, line: line)
            let flushed = await f.flush()
            XCTAssertTrue(flushed, "\(cell.name): sent", file: file, line: line)
            XCTAssertEqual(f.gmailLabels(ref), expected(f), "\(cell.name): Gmail", file: file, line: line)
        }
    }

    func testActionsThatDoNotDependOnTheFolder() async throws {
        try await run([
            Cell(name: "mark read", folder: "Inbox", verb: { _ in .markRead }, before: labels([.inbox, .unread]), after: labels([.inbox])),
            Cell(name: "mark unread", folder: "Inbox", verb: { _ in .markUnread }, before: labels([.inbox]), after: labels([.inbox, .unread])),
            Cell(name: "flag", folder: "Inbox", verb: { _ in .flag }, before: labels([.inbox]), after: labels([.inbox, .starred])),
            Cell(name: "unflag", folder: "Inbox", verb: { _ in .unflag }, before: labels([.inbox, .starred]), after: labels([.inbox])),
            Cell(name: "copy to a folder", folder: "Inbox", verb: copy("Clients"), before: labels([.inbox]), after: labels([.inbox], ["Clients"])),
            Cell(name: "copy to Starred", folder: "Inbox", verb: copy("Starred"), before: labels([.inbox]), after: labels([.inbox, .starred])),
            Cell(name: "junk", folder: "Inbox", verb: { _ in .junk }, before: labels([.inbox, .unread]), after: labels([.spam, .unread])),
            Cell(name: "not junk", folder: "Junk Email", verb: { _ in .notJunk }, before: labels([.spam]), after: labels([.inbox])),
            Cell(name: "not junk leaves mail outside Junk Email", folder: "Archive", verb: { _ in .notJunk }, before: labels([]),
                 after: labels([])),
            Cell(name: "mute", folder: "Inbox", verb: { _ in .mute }, before: labels([.inbox, .unread]), after: labels([])),
            Cell(name: "move to Focused", folder: "Inbox", verb: { _ in .moveToFocused }, before: labels([.inbox, .categoryPromotions]),
                 after: labels([.inbox, .categoryPersonal])),
            Cell(name: "move to Focused leaves Focused mail", folder: "Inbox", verb: { _ in .moveToFocused },
                 before: labels([.inbox, .categoryUpdates]), after: labels([.inbox, .categoryUpdates])),
            Cell(name: "move to Other", folder: "Inbox", verb: { _ in .moveToOther }, before: labels([.inbox, .categoryPersonal]),
                 after: labels([.inbox, .categoryPromotions])),
            Cell(name: "move to Other from no category", folder: "Inbox", verb: { _ in .moveToOther }, before: labels([.inbox]),
                 after: labels([.inbox, .categoryPromotions])),
            Cell(name: "move to Other leaves Other mail", folder: "Inbox", verb: { _ in .moveToOther },
                 before: labels([.inbox, .categorySocial]), after: labels([.inbox, .categorySocial]))
        ])
    }

    func testArchiveInEveryFolder() async throws {
        try await run([
            Cell(name: "Inbox", folder: "Inbox", verb: { _ in .archive }, before: labels([.inbox], ["Clients"]), after: labels([], ["Clients"])),
            Cell(name: "search", folder: "search", verb: { _ in .archive }, before: labels([.inbox]), after: labels([])),
            Cell(name: "a label", folder: "Clients", verb: { _ in .archive }, before: labels([.inbox], ["Clients"]), after: labels([.inbox])),
            Cell(name: "Archive keeps the flag", folder: "Archive", verb: { _ in .archive }, before: labels([.inbox, .starred]),
                 after: labels([.starred])),
            Cell(name: "Starred keeps the flag", folder: "Starred", verb: { _ in .archive }, before: labels([.inbox, .starred]),
                 after: labels([.starred])),
            Cell(name: "Important keeps Important", folder: "Important", verb: { _ in .archive }, before: labels([.inbox, .important]),
                 after: labels([.important])),
            Cell(name: "Sent", folder: "Sent", verb: { _ in .archive }, before: labels([.sent]), after: nil),
            Cell(name: "Drafts", folder: "Drafts", verb: { _ in .archive }, before: labels([.draft]), after: nil),
            Cell(name: "Junk Email goes to Archive", folder: "Junk Email", verb: { _ in .archive }, before: labels([.spam]), after: labels([])),
            Cell(name: "Deleted Items goes to Archive", folder: "Deleted Items", verb: { _ in .archive }, before: labels([.trash], ["Clients"]),
                 after: labels([], ["Clients"]))
        ])
    }

    func testMoveInEveryFolder() async throws {
        try await run([
            Cell(name: "Inbox", folder: "Inbox", verb: move("Projects"), before: labels([.inbox]), after: labels([], ["Projects"])),
            Cell(name: "search", folder: "search", verb: move("Projects"), before: labels([.inbox]), after: labels([], ["Projects"])),
            Cell(name: "a label", folder: "Clients", verb: move("Projects"), before: labels([.inbox], ["Clients"]),
                 after: labels([.inbox], ["Projects"])),
            Cell(name: "Archive keeps the flag", folder: "Archive", verb: move("Projects"), before: labels([.inbox, .starred]),
                 after: labels([.starred], ["Projects"])),
            Cell(name: "Starred keeps the flag", folder: "Starred", verb: move("Projects"), before: labels([.inbox, .starred]),
                 after: labels([.starred], ["Projects"])),
            Cell(name: "Important keeps Important", folder: "Important", verb: move("Projects"), before: labels([.inbox, .important]),
                 after: labels([.important], ["Projects"])),
            Cell(name: "Sent keeps its copy", folder: "Sent", verb: move("Projects"), before: labels([.sent]),
                 after: labels([.sent], ["Projects"]), notice: "Moved to Projects. Gmail keeps a copy in Sent."),
            Cell(name: "Drafts", folder: "Drafts", verb: move("Projects"), before: labels([.draft]), after: nil),
            Cell(name: "Junk Email", folder: "Junk Email", verb: move("Projects"), before: labels([.spam]), after: labels([], ["Projects"])),
            Cell(name: "Deleted Items removes TRASH", folder: "Deleted Items", verb: move("Projects"), before: labels([.trash]),
                 after: labels([], ["Projects"])),
            Cell(name: "Deleted Items to Inbox", folder: "Deleted Items", verb: move("Inbox"), before: labels([.trash]), after: labels([.inbox])),
            Cell(name: "to the folder it is in", folder: "Clients", verb: move("Clients"), before: labels([.inbox], ["Clients"]),
                 after: labels([.inbox], ["Clients"]))
        ])
    }

    func testDeleteInEveryFolder() async throws {
        try await run([
            Cell(name: "Inbox", folder: "Inbox", verb: { _ in .delete }, before: labels([.inbox]), after: labels([.inbox, .trash])),
            Cell(name: "search", folder: "search", verb: { _ in .delete }, before: labels([.inbox]), after: labels([.inbox, .trash])),
            Cell(name: "a label", folder: "Clients", verb: { _ in .delete }, before: labels([], ["Clients"]), after: labels([.trash], ["Clients"])),
            Cell(name: "Archive", folder: "Archive", verb: { _ in .delete }, before: labels([.starred]), after: labels([.starred, .trash])),
            Cell(name: "Starred", folder: "Starred", verb: { _ in .delete }, before: labels([.starred]), after: labels([.starred, .trash])),
            Cell(name: "Important", folder: "Important", verb: { _ in .delete }, before: labels([.important]),
                 after: labels([.important, .trash])),
            Cell(name: "Sent", folder: "Sent", verb: { _ in .delete }, before: labels([.sent]), after: labels([.sent, .trash])),
            Cell(name: "Junk Email", folder: "Junk Email", verb: { _ in .delete }, before: labels([.spam]), after: labels([.trash])),
            Cell(name: "Deleted Items asks first", folder: "Deleted Items", verb: { _ in .delete }, before: labels([.trash]), after: nil),
            Cell(name: "for good outside Deleted Items and Junk Email", folder: "Inbox", verb: { _ in .deleteForever },
                 before: labels([.inbox]), after: nil)
        ])
    }

    func testEveryMoveTarget() async throws {
        try await run([
            Cell(name: "to Drafts", folder: "Inbox", verb: move("Drafts"), before: labels([.inbox]), after: nil),
            Cell(name: "to Sent", folder: "Inbox", verb: move("Sent"), before: labels([.inbox]), after: nil),
            Cell(name: "to Archive is Archive", folder: "Inbox", verb: move("Archive"), before: labels([.inbox], ["Clients"]),
                 after: labels([], ["Clients"])),
            Cell(name: "to Starred flags and removes nothing", folder: "Inbox", verb: move("Starred"), before: labels([.inbox]),
                 after: labels([.inbox, .starred])),
            Cell(name: "to Deleted Items is Delete", folder: "Inbox", verb: move("Deleted Items"), before: labels([.inbox]),
                 after: labels([.inbox, .trash])),
            Cell(name: "to Junk Email is Junk", folder: "Inbox", verb: move("Junk Email"), before: labels([.inbox]), after: labels([.spam])),
            Cell(name: "to Inbox from Archive", folder: "Archive", verb: move("Inbox"), before: labels([.starred]),
                 after: labels([.inbox, .starred])),
            Cell(name: "to Inbox from a label", folder: "Clients", verb: move("Inbox"), before: labels([], ["Clients"]),
                 after: labels([.inbox])),
            Cell(name: "to Inbox from Junk Email", folder: "Junk Email", verb: move("Inbox"), before: labels([.spam]), after: labels([.inbox])),
            Cell(name: "to Important", folder: "Inbox", verb: move("Important"), before: labels([.inbox]), after: labels([.important])),
            Cell(name: "to a label", folder: "Inbox", verb: move("Clients"), before: labels([.inbox]), after: labels([], ["Clients"])),
            Cell(name: "copy to Deleted Items", folder: "Inbox", verb: copy("Deleted Items"), before: labels([.inbox]), after: nil),
            Cell(name: "copy to Sent", folder: "Inbox", verb: copy("Sent"), before: labels([.inbox]), after: nil),
            Cell(name: "copy to Archive changes nothing", folder: "Inbox", verb: copy("Archive"), before: labels([.inbox]),
                 after: labels([.inbox]))
        ])
        let f = try await fixture()
        XCTAssertFalse(GmailActionRules.isMoveTarget(f.folders["Drafts"]!))
        XCTAssertFalse(GmailActionRules.isMoveTarget(f.folders["Sent"]!))
        for name in ["Inbox", "Archive", "Starred", "Important", "Deleted Items", "Junk Email", "Clients"] {
            XCTAssertTrue(GmailActionRules.isMoveTarget(f.folders[name]!), name)
        }
        let imap = FolderInfo(accountID: UUID(), path: "[Gmail]/Sent Mail", name: "Sent Mail", delimiter: "/", role: .sent,
                              attributes: [], isSelectable: true)
        XCTAssertTrue(GmailActionRules.isMoveTarget(imap), "an IMAP account's folders keep their own rules")
    }

    func testCommandsAvailableByFolder() {
        XCTAssertFalse(GmailActionRules.isAvailable(.archive, in: .sent))
        XCTAssertFalse(GmailActionRules.isAvailable(.archive, in: .drafts))
        XCTAssertFalse(GmailActionRules.isAvailable(.move(to: UUID()), in: .drafts))
        XCTAssertTrue(GmailActionRules.isAvailable(.move(to: UUID()), in: .sent))
        XCTAssertTrue(GmailActionRules.isAvailable(.delete, in: .deletedItems), "offered, and asks first")
        XCTAssertTrue(GmailActionRules.isAvailable(.deleteForever, in: .junkEmail))
        XCTAssertFalse(GmailActionRules.isAvailable(.deleteForever, in: .inbox))
        XCTAssertTrue(GmailActionRules.isAvailable(.archive, in: .deletedItems))
    }

    func testFocusedAndOtherFollowTheUpdatesSetting() throws {
        let other = GmailFocusRule(updatesAreOther: true)
        guard case .labels(let toFocused, _, _) = try GmailActionRules.plan(.moveToFocused, in: .inbox, focus: other),
              case .labels(let toOther, _, _) = try GmailActionRules.plan(.moveToOther, in: .inbox, focus: other) else {
            return XCTFail("label changes")
        }
        XCTAssertEqual(toFocused.delta(for: [.inbox, .categoryUpdates])?.remove, [.categoryUpdates])
        XCTAssertEqual(toFocused.delta(for: [.inbox, .categoryUpdates])?.add, [.categoryPersonal])
        XCTAssertNil(toOther.delta(for: [.inbox, .categoryUpdates]), "Updates is Other already")
        XCTAssertEqual(toOther.delta(for: [.inbox, .categoryPersonal])?.remove, [.categoryPersonal])
    }

    // MARK: - Where the folder comes from

    func testTheFolderComesFromTheViewNotFromTheRow() async throws {
        // Open a message in label X, go to the Inbox, archive it: only INBOX goes.
        let f = try await fixture()
        let ref = try await f.add("In X and the Inbox", labels: [.inbox, f.label("Clients")])
        let opened = MailActionRequest(verb: .markRead, targets: .items([.message(f.key(ref))]), context: f.view("Clients"))
        _ = try await f.actions.perform(opened)
        try await f.perform(.archive, [ref], in: "Inbox")
        let flushed = await f.flush()
        XCTAssertTrue(flushed)
        XCTAssertEqual(f.gmailLabels(ref), [f.label("Clients")])
    }

    func testAConversationActsOnTheMembersItsViewShows() async throws {
        let f = try await fixture()
        let first = try await f.add("Quote", labels: [.inbox, f.label("Clients")])
        let reply = try await f.add("Re: Quote", labels: [.sent], thread: first.threadID)
        let later = try await f.add("Re: Quote", labels: [.inbox, .unread, f.label("Clients")], thread: first.threadID)
        let request = MailActionRequest(verb: .archive, targets: .items([.conversation(f.key(later))]), context: f.view("Clients"))
        let receipt = try await f.actions.perform(request)
        XCTAssertEqual(receipt.messageCount, 2)
        _ = await f.flush()
        XCTAssertEqual(f.gmailLabels(first), [.inbox])
        XCTAssertEqual(f.gmailLabels(later), [.inbox, .unread])
        XCTAssertEqual(f.gmailLabels(reply), [.sent], "the owner's reply in Sent is not in the view and is left alone")
    }

    func testOnlyMessagesWhoseStateFlipsAreCounted() async throws {
        let f = try await fixture()
        let unread = try await f.add("Unread", labels: [.inbox, .unread])
        let read = try await f.add("Read", labels: [.inbox])
        let receipt = try await f.perform(.markRead, [unread, read], in: "Inbox")
        XCTAssertEqual(receipt.messageCount, 1)
        _ = await f.flush()
        XCTAssertEqual(f.gmail.calls[.messagesModify], 1, "the read message is never sent")
    }

    // MARK: - Calls

    func testFewMessagesGoOneByOneAndManyInBatchesOfAThousand() async throws {
        let f = try await fixture()
        var few: [GmailRef] = []
        for i in 0..<9 { few.append(try await f.add("Few \(i)")) }
        try await f.perform(.flag, few, in: "Inbox")
        _ = await f.flush()
        XCTAssertEqual(f.gmail.calls[.messagesModify], 9)
        XCTAssertNil(f.gmail.calls[.messagesBatchModify])

        var many: [GmailRef] = []
        for i in 0..<10 { many.append(try await f.add("Many \(i)")) }
        try await f.perform(.flag, many, in: "Inbox")
        _ = await f.flush()
        XCTAssertEqual(f.gmail.calls[.messagesBatchModify], 1)
        XCTAssertTrue(many.allSatisfy { f.gmailLabels($0)?.contains(.starred) == true })
    }

    func testAThousandAndOneSelectedRowsAreRefused() async throws {
        let f = try await fixture()
        let ref = try await f.add()
        let items = (0...1_000).map { _ in ActionItem.message(f.key(ref)) }
        do {
            _ = try await f.actions.perform(MailActionRequest(verb: .archive, targets: .items(items), context: f.view("Inbox")))
            XCTFail("more than 1,000 rows never act on the first thousand")
        } catch let error as GmailActionError {
            XCTAssertEqual(error.kind, .tooManySelected)
            XCTAssertEqual(error.sentence, "Select 1,000 messages or fewer for this command.")
        }
        XCTAssertEqual(f.gmailLabels(ref), [.inbox, .unread])
    }

    func testMovingToAnotherAccountsFolderIsRefused() async throws {
        let f = try await fixture()
        let ref = try await f.add()
        var elsewhere = FolderInfo(accountID: UUID(), path: "Other", name: "Other", delimiter: "/", role: .other, attributes: [],
                                   isSelectable: true)
        elsewhere.gmailLabelID = "Label_99"
        f.host.folderList += [elsewhere]
        do {
            try await f.perform(.move(to: elsewhere.id), [ref], in: "Inbox")
            XCTFail("a move stays within the account")
        } catch let error as GmailActionError {
            XCTAssertEqual(error.kind, .notAvailable)
        }
    }

    // MARK: - Undo

    func testUndoWithinTheWindowSendsNothing() async throws {
        let f = try await fixture(undoWindow: 60)
        let ref = try await f.add()
        let receipt = try await f.perform(.archive, [ref], in: "Inbox")
        XCTAssertTrue(receipt.isUndoable)
        XCTAssertNotNil(receipt.heldUntil)
        let shown = await f.shown(ref)
        XCTAssertEqual(shown, [.unread], "the row leaves the Inbox at once")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.pendingFile.path), "saved before it is sent")
        let undone = await f.actions.undo(receipt.id)
        XCTAssertTrue(undone)
        let back = await f.shown(ref)
        XCTAssertEqual(back, [.inbox, .unread])
        let flushed = await f.flush()
        XCTAssertTrue(flushed)
        XCTAssertNil(f.gmail.attempts[.messagesModify])
        XCTAssertNil(f.gmail.attempts[.messagesBatchModify])
        XCTAssertEqual(f.gmailLabels(ref), [.inbox, .unread])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.pendingFile.path), "nothing waits")
        let again = await f.actions.undo(receipt.id)
        XCTAssertFalse(again)
    }

    func testTheWindowEndsAndTheChangeIsSent() async throws {
        let clock = ActionClock()
        let f = try await fixture(clock: clock, undoWindow: 5)
        let ref = try await f.add()
        try await f.perform(.archive, [ref], in: "Inbox")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(f.gmail.attempts[.messagesModify], "held while the window lasts")
        clock.advance(5)
        let sent = await f.eventually { f.gmailLabels(ref) == [.unread] }
        XCTAssertTrue(sent)
        let committed = await f.eventually { f.host.commits == 1 }
        XCTAssertTrue(committed)
    }

    func testUndoAfterSendingReversesOnlyTheDeltas() async throws {
        let f = try await fixture()
        let unread = try await f.add("Unread", labels: [.inbox, .unread])
        let read = try await f.add("Read", labels: [.inbox])
        let receipt = try await f.perform(.markRead, [unread, read], in: "Inbox")
        _ = await f.flush()
        XCTAssertEqual(f.gmailLabels(unread), [.inbox])
        let undone = await f.actions.undo(receipt.id)
        XCTAssertTrue(undone)
        let shown = await f.shown(unread)
        XCTAssertEqual(shown, [.inbox, .unread], "shown at once")
        _ = await f.flush()
        XCTAssertEqual(f.gmailLabels(unread), [.inbox, .unread])
        XCTAssertEqual(f.gmailLabels(read), [.inbox], "the message that was read before stays read")
        XCTAssertEqual(f.gmail.calls[.messagesModify], 2)
    }

    func testUndoWhileBeingSentReversesWhatWent() async throws {
        let f = try await fixture(clock: ActionClock(instant: true))
        let ref = try await f.add()
        // The first call fails in a way that may have reached Gmail; Undo comes while it waits.
        f.gmail.fail(.messagesModify, with: GoogleAPIError(kind: .temporary, httpStatus: 503, reason: "backendError"))
        f.gmail.fail(.messagesModify, with: GoogleAPIError(kind: .temporary, httpStatus: 503, reason: "backendError"))
        let receipt = try await f.perform(.archive, [ref], in: "Inbox")
        let tried = await f.eventually { (f.gmail.attempts[.messagesModify] ?? 0) >= 1 }
        XCTAssertTrue(tried)
        let undone = await f.actions.undo(receipt.id)
        XCTAssertTrue(undone)
        let shown = await f.shown(ref)
        XCTAssertEqual(shown, [.inbox, .unread])
        let flushed = await f.flush()
        XCTAssertTrue(flushed)
        XCTAssertEqual(f.gmailLabels(ref), [.inbox, .unread], "whatever reached Gmail was put back")
    }

    func testAPhoneDeleteDuringAHeldDeleteSurvivesUndo() async throws {
        let f = try await fixture(undoWindow: 60)
        let ref = try await f.add()
        let receipt = try await f.perform(.delete, [ref], in: "Inbox")
        // Deleted on the phone while the owner's delete waits in its window.
        f.gmail.relabel(ref.id, adding: [.trash])
        await f.host.sync()
        let undone = await f.actions.undo(receipt.id)
        XCTAssertTrue(undone)
        let shown = await f.shown(ref)
        XCTAssertEqual(shown, [.inbox, .unread, .trash], "the phone's delete stands")
        let flushed = await f.flush()
        XCTAssertTrue(flushed)
        XCTAssertNil(f.gmail.attempts[.messagesModify], "nothing of the owner's was sent")
    }

    func testChangesFromOtherDevicesOnOtherLabelsPassWhileAChangeWaits() async throws {
        let f = try await fixture(undoWindow: 60)
        let ref = try await f.add()
        try await f.perform(.archive, [ref], in: "Inbox")
        let held = await f.actions.heldLabels()
        XCTAssertEqual(held.labels(for: ref.id), [.inbox])
        // The phone puts it back in the Inbox and flags it: the flag shows, the Inbox waits.
        f.gmail.relabel(ref.id, adding: [.inbox, .starred])
        await f.host.sync()
        let shown = await f.shown(ref)
        XCTAssertEqual(shown, [.unread, .starred], "the owner's archive shows until Gmail has it")
        let flushed = await f.flush()
        XCTAssertTrue(flushed)
        XCTAssertEqual(f.gmailLabels(ref), [.unread, .starred])
        let after = await f.shown(ref)
        XCTAssertEqual(after, [.unread, .starred], "read back from Gmail once sent")
    }

    func testTheEchoOfWhatGmailHasAlreadyPassesWhileTheRestWaits() async throws {
        var recording: RecordingTransport?
        let clock = ActionClock()
        let f = try await ActionsFixture(clock: clock, undoWindow: 0, transport: { gmail in
            let wire = RecordingTransport(gmail, clock: clock)
            wire.failingModifyCalls = [2]
            recording = wire
            return wire
        })
        fixtures.append(f)
        XCTAssertNotNil(recording)
        let first = try await f.add("First")
        let second = try await f.add("Second")
        try await f.perform(.archive, [first, second], in: "Inbox")
        let halfway = await f.eventually { f.gmailLabels(first) == [.unread] }
        XCTAssertTrue(halfway, "the first went; the second waits to retry")
        // A check brings the echo of the first, and the phone flags it.
        f.gmail.relabel(first.id, adding: [.inbox])
        await f.host.sync()
        let shown = await f.shown(first)
        XCTAssertEqual(shown, [.inbox, .unread], "Gmail has the owner's change for it, so what came after shows")
        let saved = PendingGmailOpsFile(url: f.pendingFile).load().ops
        XCTAssertEqual(saved.first?.skippedRecords, [], "nothing held back for a message Gmail has confirmed")
        clock.advance(120)
        let flushed = await f.flush()
        XCTAssertTrue(flushed)
        XCTAssertEqual(f.gmailLabels(second), [.unread])
        XCTAssertNil(f.gmail.calls[.messagesGet], "nothing had to be read back")
        XCTAssertEqual(f.host.relistings, 0)
    }

    // MARK: - Failures

    func testARateLimit403NeverPutsRowsBack() async throws {
        let f = try await fixture(clock: ActionClock(instant: true))
        let ref = try await f.add()
        for reason in ["rateLimitExceeded", "userRateLimitExceeded"] {
            f.gmail.fail(.messagesModify, with: GoogleAPIError(kind: .rateLimited, httpStatus: 403, reason: reason, retryAfter: 2))
        }
        f.gmail.fail(.messagesModify, with: GoogleAPIError(kind: .quotaExhausted, httpStatus: 403, reason: "dailyLimitExceeded"))
        try await f.perform(.archive, [ref], in: "Inbox")
        let sent = await f.eventually(5) { f.gmailLabels(ref) == [.unread] }
        XCTAssertTrue(sent)
        XCTAssertEqual(f.gmail.attempts[.messagesModify], 4)
        let shown = await f.shown(ref)
        XCTAssertEqual(shown, [.unread])
        XCTAssertTrue(f.host.notices.isEmpty, "a pause is not a failure")
    }

    func testADefiniteRefusalPutsRowsBackAndSaysWhy() async throws {
        let f = try await fixture()
        let ref = try await f.add()
        f.gmail.fail(.messagesModify, with: GoogleAPIError(kind: .domainPolicy, httpStatus: 403, reason: "domainPolicy"))
        try await f.perform(.archive, [ref], in: "Inbox")
        let flushed = await f.flush()
        XCTAssertTrue(flushed)
        let shown = await f.shown(ref)
        XCTAssertEqual(shown, [.inbox, .unread], "the row is back")
        XCTAssertEqual(f.host.notices.count, 1)
        XCTAssertTrue(f.host.notices[0].hasPrefix("Gmail didn't accept that change, so the messages are back as they were."))
    }

    func testAFolderGoneMeanwhileIsSaid() async throws {
        let f = try await fixture()
        let ref = try await f.add()
        f.gmail.fail(.messagesModify, with: GoogleAPIError(kind: .notFound, httpStatus: 404, reason: "notFound"))
        f.gmail.fail(.labelsGet, with: GoogleAPIError(kind: .notFound, httpStatus: 404, reason: "notFound"))
        try await f.perform(.move(to: f.folders["Projects"]!.id), [ref], in: "Inbox")
        _ = await f.flush()
        XCTAssertEqual(f.host.notices, ["The folder “Projects” no longer exists on the server."])
        XCTAssertEqual(f.host.labelReloads, 1, "the labels are read again")
        let shown = await f.shown(ref)
        XCTAssertEqual(shown, [.inbox, .unread])
    }

    func testAMessageGoneMeanwhileLeavesTheChange() async throws {
        let f = try await fixture(undoWindow: 60)
        let kept = try await f.add("Kept")
        let gone = try await f.add("Gone")
        try await f.perform(.archive, [kept, gone], in: "Inbox")
        f.gmail.delete(gone.id)
        let flushed = await f.flush()
        XCTAssertTrue(flushed)
        XCTAssertEqual(f.gmailLabels(kept), [.unread])
        XCTAssertTrue(f.host.notices.isEmpty)
        let record = await f.store.record(for: gone.id)
        XCTAssertTrue(record?.attributes.contains(.tombstone) ?? false, "it leaves the list")
    }

    func testAMessageDeletedForGoodElsewhereLeavesAWaitingChange() async throws {
        let f = try await fixture(undoWindow: 60)
        let ref = try await f.add()
        try await f.perform(.archive, [ref], in: "Inbox")
        f.gmail.delete(ref.id)
        await f.host.sync()
        let pending = await f.actions.pendingMessageIDs()
        XCTAssertTrue(pending.isEmpty)
        _ = await f.flush()
        XCTAssertNil(f.gmail.attempts[.messagesModify])
    }

    // MARK: - Pending changes across launches

    func testReplayAfterARestartAppliesOnce() async throws {
        let f = try await fixture(undoWindow: 60)
        let ref = try await f.add()
        try await f.perform(.archive, [ref], in: "Inbox")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.pendingFile.path))
        await f.relaunch()
        let sent = await f.eventually { f.gmailLabels(ref) == [.unread] }
        XCTAssertTrue(sent, "sent at once: the undo window ended with the run that made it")
        let empty = await f.eventually { !FileManager.default.fileExists(atPath: f.pendingFile.path) }
        XCTAssertTrue(empty)
        await f.relaunch()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(f.gmail.calls[.messagesModify], 1)
        let pending = await f.actions.hasPendingChanges()
        XCTAssertFalse(pending)
    }

    func testAChangeOlderThanADayIsDropped() async throws {
        let clock = ActionClock()
        let f = try await fixture(clock: clock, undoWindow: 60)
        let ref = try await f.add()
        try await f.perform(.archive, [ref], in: "Inbox")
        clock.advance(25 * 3600)
        await f.relaunch()
        let shown = await f.eventually { await f.shown(ref) == [.inbox, .unread] }
        XCTAssertTrue(shown, "its row is put back from Gmail's state")
        XCTAssertNil(f.gmail.attempts[.messagesModify])
        let pending = await f.actions.hasPendingChanges()
        XCTAssertFalse(pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.pendingFile.path))
    }

    func testAMessageTouchedSinceIsLeftOutAfterAGap() async throws {
        let f = try await fixture(undoWindow: 60)
        let touched = try await f.add("Touched")
        let quiet = try await f.add("Quiet")
        try await f.perform(.archive, [touched, quiet], in: "Inbox")
        await f.actions.stop()
        // While FalconMail was closed, the phone flagged one of them.
        f.gmail.relabel(touched.id, adding: [.starred])
        await f.relaunch()
        let sent = await f.eventually { f.gmailLabels(quiet) == [.unread] }
        XCTAssertTrue(sent)
        let pending = await f.eventually { await !f.actions.hasPendingChanges() }
        XCTAssertTrue(pending)
        XCTAssertEqual(f.gmailLabels(touched), [.inbox, .unread, .starred], "someone acted on it since, so it is left alone")
        let shown = await f.shown(touched)
        XCTAssertEqual(shown, [.inbox, .unread, .starred], "and its row is read back from Gmail")
        XCTAssertEqual(f.host.notices, ["Some changes made before FalconMail last closed were not sent, because the mail has changed since."])
    }

    func testExpiredHistoryAfterAGapDropsTheChange() async throws {
        let f = try await fixture(undoWindow: 60)
        let ref = try await f.add()
        try await f.perform(.archive, [ref], in: "Inbox")
        await f.actions.stop()
        f.gmail.add(subject: "While closed")
        f.gmail.expireHistory()
        await f.relaunch()
        let dropped = await f.eventually { await !f.actions.hasPendingChanges() }
        XCTAssertTrue(dropped)
        XCTAssertEqual(f.host.relistings, 1, "the account is listed again")
        XCTAssertEqual(f.gmailLabels(ref), [.inbox, .unread])
        XCTAssertNil(f.gmail.attempts[.messagesModify])
    }

    func testFlushAtQuitEndsTheWindowAndSends() async throws {
        let f = try await fixture(undoWindow: 600)
        let ref = try await f.add()
        try await f.perform(.flag, [ref], in: "Inbox")
        let flushed = await f.flush(5)
        XCTAssertTrue(flushed)
        XCTAssertEqual(f.gmailLabels(ref), [.inbox, .unread, .starred])
    }

    func testFlushGivesUpWhileGmailCannotBeReached() async throws {
        let f = try await fixture(undoWindow: 0)
        let ref = try await f.add()
        f.gmail.failAlways(.messagesModify, with: GoogleAPIError(kind: .offline, detail: "URLError -1009"))
        try await f.perform(.flag, [ref], in: "Inbox")
        let flushed = await f.flush(0.3)
        XCTAssertFalse(flushed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.pendingFile.path), "kept for the next launch")
        let shown = await f.shown(ref)
        XCTAssertEqual(shown, [.inbox, .unread, .starred], "offline, the owner's change still shows")
        f.gmail.failAlways(.messagesModify, with: nil)
        await f.actions.networkChanged()
        let sent = await f.eventually { f.gmailLabels(ref)?.contains(.starred) == true }
        XCTAssertTrue(sent)
    }

    func testPendingChangesKeepToTheirOwnFile() async throws {
        let f = try await fixture(undoWindow: 60)
        let ref = try await f.add()
        try await f.perform(.archive, [ref], in: "Inbox")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.pendingFile.path))
        XCTAssertEqual(f.pendingFile.deletingLastPathComponent().lastPathComponent, "Gmail")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.layout.pendingActionsFile.path),
                       "v1.10.0's pending actions are never written")
        let saved = PendingGmailOpsFile(url: f.pendingFile).load().ops
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].verb, "archive")
        XCTAssertEqual(saved[0].contextLabel, .inbox)
        XCTAssertEqual(saved[0].deltas, [PendingGmailOp.Delta(add: [], remove: [.inbox], ids: [ref.id])])
        XCTAssertNotNil(saved[0].knownAt)
        XCTAssertTrue(saved[0].isHeld)
    }

    func testLargeChangesAreSavedPacked() throws {
        let ids = (1...2_500).map { GmailMessageID(raw: 0x1900_0000_0000_0000 + UInt64($0)) }
        let op = PendingGmailOp(id: UUID(), kind: .labels, verb: "archive",
                                deltas: [PendingGmailOp.Delta(add: [], remove: [.inbox], ids: ids),
                                         PendingGmailOp.Delta(add: [.starred], remove: [], ids: Array(ids.prefix(3)))],
                                contextLabel: .inbox, createdAt: Date(timeIntervalSince1970: 1_790_000_000), knownAt: HistoryID(raw: 42),
                                phase: .committing(attempt: 2),
                                wholeView: PendingGmailOp.ViewPredicate(label: .inbox, filters: [.unread], excluded: 1),
                                skippedRecords: [PendingGmailOp.KeptRecord(history: HistoryID(raw: 43), id: ids[0], added: [.inbox], removed: [])])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pending-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = PendingGmailOpsFile(url: url)
        try file.save([op])
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"packed\""))
        XCTAssertTrue(text.contains("\"ids\":[\"19"), "a small group stays readable")
        XCTAssertLessThan(text.utf8.count, 2_500 * 13)
        let loaded = file.load()
        XCTAssertTrue(loaded.canSave)
        XCTAssertEqual(loaded.ops, [op])
        try file.save([])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "no file when nothing waits")
    }

    func testAnUnreadablePendingFileIsSetAsideNotOverwritten() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("falcon-gmail-actions-\(UUID().uuidString)", isDirectory: true)
        let accountID = UUID()
        let files = GmailFiles(layout: FileLayout(root: root), accountID: accountID)
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: files.pendingOps)
        let f = try await ActionsFixture(accountID: accountID, undoWindow: 60, root: root)
        fixtures.append(f)
        XCTAssertEqual(AtomicFile.setAsideCopies(of: files.pendingOps).count, 1)
        _ = StoredFileNotices.take()
    }

    // MARK: - Whole views

    func testMarkAllAsReadInAViewIsBulkAndNotUndone() async throws {
        let f = try await fixture(clock: ActionClock(instant: true))
        var unread: [GmailRef] = []
        for i in 0..<12 { unread.append(try await f.add("Unread \(i)")) }
        let read = try await f.add("Read", labels: [.inbox])
        let elsewhere = try await f.add("Archived", labels: [.unread])
        let request = MailActionRequest(verb: .markRead, targets: .wholeView(except: []), context: f.view("Inbox"))
        let receipt = try await f.actions.perform(request)
        XCTAssertEqual(receipt.messageCount, 12)
        XCTAssertFalse(receipt.isUndoable)
        _ = await f.flush()
        XCTAssertTrue(unread.allSatisfy { f.gmailLabels($0) == [.inbox] })
        XCTAssertEqual(f.gmailLabels(read), [.inbox])
        XCTAssertEqual(f.gmailLabels(elsewhere), [.unread], "only the view")
        XCTAssertEqual(f.gmail.calls[.messagesBatchModify], 1)
        let undone = await f.actions.undo(receipt.id)
        XCTAssertFalse(undone)
    }

    func testSelectAllLeavesOutWhatTheOwnerUnselectedAndLaterMail() async throws {
        let f = try await fixture(undoWindow: 60)
        var refs: [GmailRef] = []
        for i in 0..<11 { refs.append(try await f.add("Mail \(i)")) }
        let request = MailActionRequest(verb: .archive, targets: .wholeView(except: [.message(f.key(refs[3]))]), context: f.view("Inbox"))
        let receipt = try await f.actions.perform(request)
        XCTAssertEqual(receipt.messageCount, 10)
        XCTAssertTrue(receipt.isUndoable)
        let later = try await f.add("Arrived after")
        _ = await f.flush()
        XCTAssertEqual(f.gmailLabels(refs[3]), [.inbox, .unread])
        XCTAssertEqual(f.gmailLabels(later), [.inbox, .unread], "mail that arrived later is left alone")
        XCTAssertEqual(refs.filter { f.gmailLabels($0) == [.unread] }.count, 10)
    }

    func testAWholeViewFilteredToUnread() async throws {
        let f = try await fixture()
        let unread = try await f.add("Unread")
        let read = try await f.add("Read", labels: [.inbox])
        let request = MailActionRequest(verb: .flag, targets: .wholeView(except: []), context: f.view("Inbox", filters: [.unread]))
        _ = try await f.actions.perform(request)
        _ = await f.flush()
        XCTAssertEqual(f.gmailLabels(unread), [.inbox, .unread, .starred])
        XCTAssertEqual(f.gmailLabels(read), [.inbox])
    }

    func testAWholeSearchIsTakenFromTheList() async throws {
        let f = try await fixture()
        let hit = try await f.add("Hit")
        let miss = try await f.add("Miss")
        let search = MailActionRequest(verb: .archive, targets: .wholeView(except: []), context: ListView(scope: .search(UUID())))
        do {
            _ = try await f.actions.perform(search)
            XCTFail("the index alone does not know a search's hits")
        } catch let error as GmailActionError {
            XCTAssertEqual(error.kind, .tooManySelected)
        }
        f.host.viewMessages = [hit.id]
        _ = try await f.actions.perform(search)
        _ = await f.flush()
        XCTAssertEqual(f.gmailLabels(hit), [.unread])
        XCTAssertEqual(f.gmailLabels(miss), [.inbox, .unread])
    }

    func testTwoHundredThousandArchivedInBulkWithinTheBudget() async throws {
        let clock = ActionClock(instant: true)
        let accountID = UUID()
        let inner = MemoryGmailTransport(accountID: accountID)
        let transport = RecordingTransport(inner, clock: clock, recordOnly: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("falcon-gmail-bulk-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryGmailStore(accountID: accountID, files: GmailFiles(layout: FileLayout(root: root), accountID: accountID))
        let total = 200_000
        for page in 0..<(total / 500) {
            let refs = (0..<500).map { i -> GmailRef in
                let n = UInt64(total - page * 500 - i)
                return GmailRef(id: GmailMessageID(raw: 0x1800_0000_0000_0000 + n), threadID: GmailThreadID(raw: 0x1800_0000_0000_0000 + n))
            }
            try await store.appendListingPage(GmailListingPage(chain: .allMail(after: nil, before: nil), refs: refs,
                                                               firstOrder: UInt32(total - page * 500) * 16, labels: [.inbox]))
        }
        let host = ActionsHost(store: store, gmail: inner)
        var inbox = FolderInfo(accountID: accountID, path: "INBOX", name: "Inbox", delimiter: "/", role: .inbox, attributes: [], isSelectable: true)
        inbox.gmailLabelID = .inbox
        host.folderList = [inbox]
        host.cursor = HistoryID(raw: 1)
        let layout = FileLayout(root: root)
        let actions = GmailActions(accountID: accountID, transport: transport, store: store, mutes: MuteStore(layout: layout),
                                   host: host, undoWindow: 0, clock: clock.clock)
        host.actions = actions
        await actions.start()
        defer { Task { await actions.stop() } }

        let started = Date()
        let receipt = try await actions.perform(MailActionRequest(verb: .archive, targets: .wholeView(except: []),
                                                                  context: ListView(scope: .folder(inbox.id))))
        XCTAssertEqual(receipt.messageCount, total)
        let shown = await store.labels(of: GmailMessageID(raw: 0x1800_0000_0000_0000 + 12_345))
        XCTAssertEqual(shown, [], "every row changes at once")
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
        var done = false
        for _ in 0..<600 where !done {
            done = await !actions.hasPendingChanges()
            if !done { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        XCTAssertTrue(done)
        let calls = transport.bulkCalls.filter { $0.method == .messagesBatchModify }
        XCTAssertLessThanOrEqual(calls.count, 200)
        XCTAssertEqual(calls.reduce(0) { $0 + $1.ids }, total)
        XCTAssertTrue(calls.allSatisfy { $0.work == .bulk }, "bulk work gives way to the owner's")
        for call in calls {
            let window = calls.filter { $0.at >= call.at && $0.at < call.at.addingTimeInterval(60) }
            XCTAssertLessThanOrEqual(window.count * GmailMethod.messagesBatchModify.units, 1_500)
        }
        let minutes = (calls.last!.at.timeIntervalSince(calls.first!.at)) / 60
        XCTAssertGreaterThanOrEqual(minutes, 6, "10,000 units at 1,500 a minute, the first minute's share at once")
        XCTAssertLessThan(minutes, 8)
    }

    func testBulkWorkReportsItsProgress() async throws {
        let f = try await fixture(clock: ActionClock(instant: true))
        for i in 0..<25 { try await f.add("Mail \(i)") }
        f.gmail.fail(.messagesBatchModify, with: GoogleAPIError(kind: .temporary, httpStatus: 503, reason: "backendError"))
        let receipt = try await f.actions.perform(MailActionRequest(verb: .archive, targets: .wholeView(except: []), context: f.view("Inbox")))
        let before = await f.actions.bulkProgress()
        XCTAssertEqual(before.map(\.total), [25])
        XCTAssertEqual(before.first?.id, receipt.id)
        _ = await f.flush()
        let after = await f.actions.bulkProgress()
        XCTAssertTrue(after.isEmpty, "done")
    }

    func testBulkWorkDoesNotHoldUpTheOwner() async throws {
        let f = try await fixture(clock: ActionClock(instant: true))
        for i in 0..<15 { try await f.add("Mail \(i)") }
        // The bulk change stalls on a busy Gmail; a flag set meanwhile goes all the same.
        f.gmail.failAlways(.messagesBatchModify, with: GoogleAPIError(kind: .temporary, httpStatus: 503, reason: "backendError"))
        _ = try await f.actions.perform(MailActionRequest(verb: .archive, targets: .wholeView(except: []), context: f.view("Inbox")))
        let one = try await f.add("Flag me", labels: [.starred])
        try await f.perform(.markUnread, [one], in: "Starred")
        let sent = await f.eventually { f.gmailLabels(one) == [.starred, .unread] }
        XCTAssertTrue(sent)
        f.gmail.failAlways(.messagesBatchModify, with: nil)
        await f.actions.networkChanged()
        let pending = await f.eventually(5) { await !f.actions.hasPendingChanges() }
        XCTAssertTrue(pending)
    }

    // MARK: - Delete for good, Drafts

    func testDeleteForGoodInDeletedItems() async throws {
        let f = try await fixture()
        let doomed = try await f.add("Old", labels: [.trash])
        let receipt = try await f.perform(.deleteForever, [doomed], in: "Deleted Items")
        XCTAssertFalse(receipt.isUndoable)
        XCTAssertNil(receipt.heldUntil, "the owner confirmed it already")
        _ = await f.flush()
        XCTAssertNil(f.gmail.message(doomed.id))
        let record = await f.store.record(for: doomed.id)
        XCTAssertTrue(record?.attributes.contains(.tombstone) ?? false)
        XCTAssertEqual(f.host.checks, 1, "a check runs first")
        XCTAssertEqual(f.gmail.calls[.messagesList], 1, "and Deleted Items is listed afresh")
    }

    func testEmptyDeletedItemsLeavesAMessageRestoredOnThePhone() async throws {
        let f = try await fixture()
        var doomed: [GmailRef] = []
        for i in 0..<5 { doomed.append(try await f.add("Old \(i)", labels: [.trash])) }
        let restored = try await f.add("Restored", labels: [.trash])
        let inbox = try await f.add("Inbox mail")
        // Restored on the phone a moment before Empty Folder; the Mac has not seen it yet.
        f.gmail.relabel(restored.id, removing: [.trash])
        let request = MailActionRequest(verb: .deleteForever, targets: .wholeView(except: []), context: f.view("Deleted Items"))
        let receipt = try await f.actions.perform(request)
        XCTAssertEqual(receipt.messageCount, 6)
        _ = await f.flush()
        XCTAssertTrue(doomed.allSatisfy { f.gmail.message($0.id) == nil })
        XCTAssertEqual(f.gmailLabels(restored), [], "restored a moment ago, so it stays, in Archive")
        XCTAssertEqual(f.gmailLabels(inbox), [.inbox, .unread])
        let record = await f.store.record(for: restored.id)
        XCTAssertFalse(record?.attributes.contains(.provisional) ?? true, "its row shows again")
        XCTAssertFalse(record?.attributes.contains(.tombstone) ?? true)
    }

    func testDeleteForGoodTrustsOnlyAFreshListing() async throws {
        let f = try await fixture()
        let restored = try await f.add("Restored", labels: [.trash])
        let doomed = try await f.add("Doomed", labels: [.trash])
        // Restored elsewhere, and the index behind: the fresh listing still saves it.
        f.gmail.relabel(restored.id, removing: [.trash])
        f.host.cursor = f.gmail.historyID
        let request = MailActionRequest(verb: .deleteForever, targets: .wholeView(except: []), context: f.view("Deleted Items"))
        _ = try await f.actions.perform(request)
        _ = await f.flush()
        XCTAssertNotNil(f.gmail.message(restored.id))
        XCTAssertNil(f.gmail.message(doomed.id))
    }

    func testEmptyJunkEmail() async throws {
        let f = try await fixture()
        let junk = try await f.add("Spam", labels: [.spam])
        _ = try await f.actions.perform(MailActionRequest(verb: .deleteForever, targets: .wholeView(except: []), context: f.view("Junk Email")))
        _ = await f.flush()
        XCTAssertNil(f.gmail.message(junk.id))
    }

    private func draft(_ f: ActionsFixture, _ subject: String) async throws -> (ref: GmailRef, draftID: String) {
        let raw = Data("Subject: \(subject)\r\nMessage-ID: <\(UUID().uuidString)@falconmail>\r\nContent-Type: text/plain\r\n\r\nText".utf8)
        let draft = try await f.gmail.createDraft(raw, threadID: nil, work: .interactive)
        let ref = draft.message!.ref!
        try await f.store.commit(GmailJournalBatch(changes: [.place(ref, order: 1_000_000, labels: [.draft], attributes: [])],
                                                   cursor: f.gmail.historyID))
        f.host.cursor = f.gmail.historyID
        return (ref, draft.id)
    }

    func testDeleteInDraftsDiscardsAfterTheWindow() async throws {
        let f = try await fixture(undoWindow: 60)
        let (ref, draftID) = try await draft(f, "Unfinished")
        let receipt = try await f.perform(.delete, [ref], in: "Drafts")
        XCTAssertTrue(receipt.isUndoable)
        let shown = await f.shown(ref)
        XCTAssertEqual(shown, [], "it leaves Drafts at once")
        XCTAssertNotNil(f.gmail.draftIDs[draftID], "Gmail keeps nothing of a deleted draft, so it waits for the window")
        _ = await f.flush()
        XCTAssertNil(f.gmail.draftIDs[draftID])
        XCTAssertEqual(f.gmail.calls[.draftsDelete], 1)
    }

    func testUndoKeepsADiscardedDraft() async throws {
        let f = try await fixture(undoWindow: 60)
        let (ref, draftID) = try await draft(f, "Keep me")
        let receipt = try await f.perform(.delete, [ref], in: "Drafts")
        let undone = await f.actions.undo(receipt.id)
        XCTAssertTrue(undone)
        let shown = await f.shown(ref)
        XCTAssertEqual(shown, [.draft])
        _ = await f.flush()
        XCTAssertNotNil(f.gmail.draftIDs[draftID])
        XCTAssertNil(f.gmail.attempts[.draftsDelete])
    }

    func testADraftDeletedOnceItsWindowEndedCannotBeUndone() async throws {
        let f = try await fixture(clock: ActionClock(instant: true), undoWindow: 5)
        let (ref, draftID) = try await draft(f, "Gone")
        let receipt = try await f.perform(.delete, [ref], in: "Drafts")
        let deleted = await f.eventually { f.gmail.draftIDs[draftID] == nil }
        XCTAssertTrue(deleted)
        let undone = await f.actions.undo(receipt.id)
        XCTAssertFalse(undone, "Gmail keeps nothing of a deleted draft")
        _ = await f.flush()
        XCTAssertNil(f.gmail.attempts[.messagesModify], "and DRAFT is never asked for")
    }

    func testAMessageTheIndexDoesNotHoldYetIsAskedAbout() async throws {
        let f = try await fixture()
        let hit = f.gmail.add(subject: "Search hit", labels: [.inbox, .unread])
        let receipt = try await f.actions.perform(MailActionRequest(verb: .archive, targets: .items([.message(f.key(hit))]),
                                                                    context: ListView(scope: .search(UUID()))))
        XCTAssertEqual(receipt.messageCount, 1)
        _ = await f.flush()
        XCTAssertEqual(f.gmailLabels(hit), [.unread])
        XCTAssertEqual(f.gmail.calls[.messagesGet], 1, "one minimal read for its labels")
    }

    // MARK: - Mutes

    func testMuteFilesTheConversationAndUndoUnmutes() async throws {
        let f = try await fixture(undoWindow: 60)
        let first = try await f.add("Thread", labels: [.inbox, .unread])
        let second = try await f.add("Re: Thread", labels: [.inbox, .unread], thread: first.threadID)
        let receipt = try await f.actions.perform(MailActionRequest(verb: .mute, targets: .items([.conversation(f.key(second))]),
                                                                    context: f.view("Inbox")))
        XCTAssertEqual(receipt.messageCount, 2)
        var muted = await f.mutes.all()
        XCTAssertEqual(muted.map(\.threadKey), [first.threadID.threadKey])
        let undone = await f.actions.undo(receipt.id)
        XCTAssertTrue(undone)
        muted = await f.mutes.all()
        XCTAssertTrue(muted.isEmpty)
        let shown = await f.shown(first)
        XCTAssertEqual(shown, [.inbox, .unread])
    }

    // MARK: - New folders

    func testNewFolderIsALabel() async throws {
        let f = try await fixture()
        let top = try await f.actions.createFolder(named: " Freight ", parent: nil)
        XCTAssertEqual(top.name, "Freight")
        let nested = try await f.actions.createFolder(named: "Acme", parent: f.folders["Clients"]!.id)
        XCTAssertEqual(nested.name, "Clients/Acme")
        XCTAssertEqual(f.gmail.calls[.labelsCreate], 2)
        XCTAssertEqual(f.host.labelReloads, 2)
        do {
            _ = try await f.actions.createFolder(named: "freight", parent: nil)
            XCTFail("a name Gmail has already")
        } catch let error as GmailActionError {
            XCTAssertEqual(error.kind, .folderExists)
        }
        do {
            _ = try await f.actions.createFolder(named: "  ", parent: nil)
            XCTFail("a folder needs a name")
        } catch let error as GmailActionError {
            XCTAssertEqual(error.kind, .emptyName)
        }
        let underSystem = try await f.actions.createFolder(named: "Loose", parent: f.folders["Inbox"]!.id)
        XCTAssertEqual(underSystem.name, "Loose", "Gmail's own folders hold no labels")
    }
}
