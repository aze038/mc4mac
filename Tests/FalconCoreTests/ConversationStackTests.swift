import XCTest
@testable import FalconCore

/// The conversation stack in the reading pane: every message of a conversation one under
/// another, newest at the top; the newest open and the rest folded to a line, unread or not;
/// mail read message by message; a card's own Reply, Reply All and Forward acting on that card's
/// message.
final class ConversationStackTests: XCTestCase {
    private let account = UUID()
    private let folder = UUID()
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func message(_ uid: UInt32, minutesAgo: Double, read: Bool = true, snippet: String = "") -> MessageSummary {
        MessageSummary(accountID: account, folderID: folder, uid: uid, messageID: "<\(uid)@example.com>", inReplyTo: "",
                       references: [], subject: "Pallet count", from: EmailAddress(name: "Sam", address: "sam@example.com"),
                       to: [], cc: [], date: now - minutesAgo * 60, flags: read ? [.seen] : [], size: 1_000, snippet: snippet,
                       hasAttachments: false)
    }

    // MARK: order

    func testTheNewestMessageIsOnTopWhateverOrderTheyCameIn() {
        let oldest = message(1, minutesAgo: 300)
        let middle = message(2, minutesAgo: 60)
        let newest = message(3, minutesAgo: 5)
        let stack = ConversationStack([middle, oldest, newest])
        XCTAssertEqual(stack.messages.map(\.uid), [3, 2, 1])
        XCTAssertEqual(stack.newest?.uid, 3)
    }

    func testTwoMessagesSentInTheSameSecondKeepTheOrderTheyCameIn() {
        let a = message(1, minutesAgo: 10)
        let b = message(2, minutesAgo: 10)
        XCTAssertEqual(ConversationStack([a, b]).messages.map(\.uid), [1, 2])
        XCTAssertEqual(ConversationStack([b, a]).messages.map(\.uid), [2, 1])
    }

    // MARK: which cards start open

    func testOnlyTheNewestStartsOpenAndTheRestFoldedReadOrNot() {
        let messages = [
            message(4, minutesAgo: 5),
            message(3, minutesAgo: 60, read: false),
            message(2, minutesAgo: 600),
            message(1, minutesAgo: 6_000, read: false),
        ]
        let stack = ConversationStack(messages)
        XCTAssertEqual(stack.expanded, [messages[0].id])
        XCTAssertEqual(stack.expandedMessages.map(\.uid), [4])
        for folded in messages.dropFirst() { XCTAssertFalse(stack.isExpanded(folded.id)) }
        XCTAssertEqual(ConversationStack.startsOpen(messages.reversed()), [messages[0].id])
    }

    // MARK: reading message by message

    func testSelectingAConversationsRowMarksReadOnlyItsNewestMessage() {
        let messages = [
            message(4, minutesAgo: 5, read: false),
            message(3, minutesAgo: 60),
            message(2, minutesAgo: 600, read: false),
            message(1, minutesAgo: 6_000, read: false),
        ]
        XCTAssertEqual(ConversationStack(messages).toMarkRead.map(\.uid), [4])
        XCTAssertEqual(ReadMarking.toMarkRead(selecting: .conversation(messages.reversed())).map(\.uid), [4])
    }

    func testSelectingAConversationWhoseNewestIsReadMarksNothingAndLeavesTheOthersUnread() {
        let messages = [message(3, minutesAgo: 5), message(2, minutesAgo: 60, read: false), message(1, minutesAgo: 600, read: false)]
        XCTAssertEqual(ReadMarking.toMarkRead(selecting: .conversation(messages)), [])
    }

    func testSelectingOneOfAConversationsMessageLinesMarksReadOnlyThatMessage() {
        let messages = [
            message(3, minutesAgo: 5, read: false),
            message(2, minutesAgo: 60, read: false),
            message(1, minutesAgo: 600, read: false),
        ]
        XCTAssertEqual(ReadMarking.toMarkRead(selecting: .message(messages[1])).map(\.uid), [2])
        XCTAssertEqual(ReadMarking.toMarkRead(selecting: .message(messages[2])).map(\.uid), [1])
        XCTAssertEqual(ReadMarking.toMarkRead(selecting: .message(message(5, minutesAgo: 1))), [])
    }

    func testAMessageLinesTagIsThatMessageAndAConversationRowsTagIsTheConversation() {
        // Selecting a message line once found no conversation by its tag, so nothing was read.
        let conversation = [message(3, minutesAgo: 5, read: false), message(2, minutesAgo: 60, read: false)]
        let other = [message(9, minutesAgo: 1)]
        let list = [other, conversation]
        let line = ReadMarking.line(tagged: ReadMarking.messageLineTag + conversation[1].id, in: list)
        XCTAssertEqual(line, .message(conversation[1]))
        XCTAssertEqual(line.map { ReadMarking.toMarkRead(selecting: $0).map(\.uid) }, [2])
        XCTAssertEqual(ReadMarking.line(tagged: conversation[0].id, in: list), .conversation(conversation))
        XCTAssertNil(ReadMarking.line(tagged: conversation[1].id, in: list), "a message line is tagged, not named by its id")
        XCTAssertNil(ReadMarking.line(tagged: ReadMarking.messageLineTag + "gone", in: list))
        XCTAssertNil(ReadMarking.line(tagged: "group:Today", in: list))
    }

    func testAConversationOfOneMessageReadsThatMessage() {
        let only = message(1, minutesAgo: 5, read: false)
        XCTAssertEqual(ReadMarking.toMarkRead(selecting: .conversation([only])), [only])
        XCTAssertEqual(ReadMarking.toMarkRead(selecting: .message(only)), [only])
    }

    func testOpeningAFoldedUnreadCardReadsOnlyThatCard() {
        let messages = [
            message(4, minutesAgo: 5),
            message(3, minutesAgo: 60, read: false),
            message(2, minutesAgo: 600, read: false),
            message(1, minutesAgo: 6_000),
        ]
        var stack = ConversationStack(messages)
        XCTAssertEqual(stack.toggle(messages[2].id)?.uid, 2)
        XCTAssertTrue(stack.isExpanded(messages[2].id))
        XCTAssertFalse(stack.isExpanded(messages[1].id))
        // Opening a read card, or folding one again, reads nothing.
        XCTAssertNil(stack.toggle(messages[3].id))
        XCTAssertNil(stack.toggle(messages[2].id))
        XCTAssertNil(stack.toggle("not in this conversation"))
        XCTAssertEqual(stack.toMarkRead, [])
    }

    func testExpandAllOpensEveryCardAndReadsNone() {
        let messages = [
            message(3, minutesAgo: 5, read: false),
            message(2, minutesAgo: 60, read: false),
            message(1, minutesAgo: 600, read: false),
        ]
        var stack = ConversationStack(messages)
        stack.toggleAll()
        XCTAssertTrue(stack.allExpanded)
        XCTAssertEqual(stack.toMarkRead.map(\.uid), [3], "the newest, which showing the stack reads; Expand all adds none")
        stack.expandAll()
        XCTAssertEqual(stack.toMarkRead.map(\.uid), [3])
    }

    func testTheRibbonsReadUnreadActsOnEveryMessageOfTheConversation() {
        // The newest read and the others not, as message-by-message reading leaves it: read.
        let partly = [message(3, minutesAgo: 5), message(2, minutesAgo: 60, read: false), message(1, minutesAgo: 600, read: false)]
        XCTAssertTrue(ReadMarking.readUnreadMarksRead(partly))
        XCTAssertTrue(ReadMarking.readUnreadMarksRead([message(2, minutesAgo: 5, read: false), message(1, minutesAgo: 60)]))
        // Every message read: unread, all of them.
        XCTAssertFalse(ReadMarking.readUnreadMarksRead([message(2, minutesAgo: 5), message(1, minutesAgo: 60)]))
    }

    // MARK: opening and folding

    func testAClickOpensAFoldedCardAndAnotherFoldsItAgain() {
        let messages = [message(2, minutesAgo: 5), message(1, minutesAgo: 60)]
        var stack = ConversationStack(messages)
        stack.toggle(messages[1].id)
        XCTAssertTrue(stack.isExpanded(messages[1].id))
        stack.toggle(messages[1].id)
        XCTAssertFalse(stack.isExpanded(messages[1].id))
        stack.toggle("not in this conversation")
        XCTAssertEqual(stack.expanded, [messages[0].id])
    }

    func testExpandAllOpensEveryCardThenCollapseAllLeavesOnlyTheNewestOpen() {
        let messages = [message(3, minutesAgo: 5), message(2, minutesAgo: 60, read: false), message(1, minutesAgo: 600)]
        var stack = ConversationStack(messages)
        XCTAssertFalse(stack.allExpanded)
        stack.toggleAll()
        XCTAssertTrue(stack.allExpanded)
        XCTAssertEqual(stack.expandedMessages.count, 3)
        stack.toggleAll()
        XCTAssertEqual(stack.expanded, [messages[0].id])
        XCTAssertFalse(stack.allExpanded)
    }

    func testReadingTheConversationAgainKeepsWhatTheReaderOpenedAndFolded() {
        var messages = [message(3, minutesAgo: 5), message(2, minutesAgo: 60, read: false), message(1, minutesAgo: 600)]
        var stack = ConversationStack(messages)
        stack.toggle(messages[2].id)
        // Marked read meanwhile: the unread card, never opened, stays folded.
        messages[1].isRead = true
        stack.update(messages)
        XCTAssertEqual(stack.expanded, [messages[0].id, messages[2].id])
        XCTAssertTrue(stack.messages[1].isRead)
    }

    func testAMessageThatArrivesOpensOnlyWhenItIsTheNewestAndOneThatGoesLeavesTheStack() {
        let first = [message(2, minutesAgo: 60), message(1, minutesAgo: 600)]
        var stack = ConversationStack(first)
        let arrived = message(4, minutesAgo: 1)
        let unreadOlder = message(3, minutesAgo: 30, read: false)
        let readOlder = message(5, minutesAgo: 40)
        stack.update([arrived, unreadOlder, readOlder, first[0]])
        XCTAssertEqual(stack.messages.map(\.uid), [4, 3, 5, 2])
        XCTAssertEqual(stack.expanded, [arrived.id, first[0].id])
    }

    // MARK: the messages a reply may quote

    func testACardsEarlierMessagesAreTheOnesBelowIt() {
        let messages = [message(3, minutesAgo: 5), message(2, minutesAgo: 60), message(1, minutesAgo: 600)]
        let stack = ConversationStack(messages)
        XCTAssertEqual(stack.older(than: messages[0].id).map(\.uid), [2, 1])
        XCTAssertEqual(stack.older(than: messages[2].id), [])
        XCTAssertEqual(stack.older(than: "gone"), [])
    }

    func testAFoldedCardShowsTheMessagesFirstWordsOnOneLine() {
        let folded = message(1, minutesAgo: 60, snippet: "Hello Alex,\n\n  the pallets\tarrived.")
        XCTAssertEqual(ConversationStack.preview(of: folded), "Hello Alex, the pallets arrived.")
    }

    // MARK: which message an action acts on

    func testACardsOwnButtonsActOnThatCardsMessageAndTheRibbonOnTheNewest() {
        let messages = [message(3, minutesAgo: 5), message(2, minutesAgo: 60), message(1, minutesAgo: 600)]
        let stack = ConversationStack(messages.reversed())
        XCTAssertEqual(stack.target(of: .card(messages[1].id))?.uid, 2)
        XCTAssertEqual(stack.target(of: .card(messages[2].id))?.uid, 1)
        XCTAssertEqual(stack.target(of: .conversation)?.uid, 3)
    }

    func testACardNoLongerInTheStackActsOnNothing() {
        let stack = ConversationStack([message(2, minutesAgo: 5), message(1, minutesAgo: 60)])
        XCTAssertNil(stack.target(of: .card("moved away")))
    }
}
