import XCTest
@testable import FalconCore

/// The conversation stack in the reading pane: every message of a conversation one under
/// another, newest at the top; the newest and the unread open, the rest folded to a line; a
/// card's own Reply, Reply All and Forward acting on that card's message.
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

    func testTheNewestAndEveryUnreadMessageStartOpenAndTheRestFolded() {
        let messages = [
            message(4, minutesAgo: 5),
            message(3, minutesAgo: 60, read: false),
            message(2, minutesAgo: 600),
            message(1, minutesAgo: 6_000),
        ]
        let stack = ConversationStack(messages)
        XCTAssertEqual(stack.expanded, [messages[0].id, messages[1].id])
        XCTAssertEqual(stack.expandedMessages.map(\.uid), [4, 3])
        XCTAssertFalse(stack.isExpanded(messages[2].id))
        XCTAssertFalse(stack.isExpanded(messages[3].id))
    }

    func testAnOldUnreadMessageStartsOpenEvenAtTheBottom() {
        let messages = [message(3, minutesAgo: 5), message(2, minutesAgo: 60), message(1, minutesAgo: 600, read: false)]
        XCTAssertEqual(ConversationStack(messages).expandedMessages.map(\.uid), [3, 1])
    }

    func testOpeningTheStackMarksReadTheUnreadCardsItOpensWhichIsEveryUnreadOne() {
        let messages = [
            message(4, minutesAgo: 5, read: false),
            message(3, minutesAgo: 60),
            message(2, minutesAgo: 600, read: false),
            message(1, minutesAgo: 6_000),
        ]
        let stack = ConversationStack(messages)
        XCTAssertEqual(stack.toMarkRead.map(\.uid), [4, 2])
        XCTAssertEqual(Set(stack.toMarkRead.map(\.id)), Set(messages.filter { !$0.isRead }.map(\.id)))
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
        stack.toggle(messages[1].id)
        // Marked read meanwhile: the unread card the reader folded stays folded.
        messages[1].isRead = true
        stack.update(messages)
        XCTAssertEqual(stack.expanded, [messages[0].id, messages[2].id])
        XCTAssertTrue(stack.messages[1].isRead)
    }

    func testAMessageThatArrivesOpensWhenItIsTheNewestOrUnreadAndOneThatGoesLeavesTheStack() {
        let first = [message(2, minutesAgo: 60), message(1, minutesAgo: 600)]
        var stack = ConversationStack(first)
        let arrived = message(4, minutesAgo: 1)
        let unreadOlder = message(3, minutesAgo: 30, read: false)
        let readOlder = message(5, minutesAgo: 40)
        stack.update([arrived, unreadOlder, readOlder, first[0]])
        XCTAssertEqual(stack.messages.map(\.uid), [4, 3, 5, 2])
        XCTAssertEqual(stack.expanded, [arrived.id, unreadOlder.id, first[0].id])
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
