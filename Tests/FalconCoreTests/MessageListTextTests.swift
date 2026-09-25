import XCTest
@testable import FalconCore

final class MessageListTextTests: XCTestCase {
    private let account = UUID()
    private let folder = UUID()
    private var uid: UInt32 = 0

    private func message(from name: String, _ address: String, at date: Date) -> MessageSummary {
        uid += 1
        return MessageSummary(accountID: account, folderID: folder, uid: uid, messageID: "<\(uid)@example.com>", inReplyTo: "",
                              references: [], subject: "Pallet count", from: EmailAddress(name: name, address: address),
                              to: [], cc: [], date: date, flags: [], size: 1_000, hasAttachments: false)
    }

    // MARK: participants

    func testAConversationNamesEveryoneWhoWroteNewestFirstEachOnce() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let thread = [
            message(from: "Maya Lindqvist", "maya@example.com", at: now),
            message(from: "Tom Okafor", "tom@example.com", at: now - 60),
            message(from: "Maya Lindqvist", "maya@example.com", at: now - 86_400),
            message(from: "Tom Okafor", "tom@example.com", at: now - 90_000),
        ]
        XCTAssertEqual(MessageListText.participants(thread), "Maya Lindqvist, Tom Okafor")
    }

    func testTheNewestWriterComesFirstWhateverOrderTheMessagesCameIn() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let thread = [
            message(from: "Tom Okafor", "tom@example.com", at: now - 600),
            message(from: "Maya Lindqvist", "maya@example.com", at: now),
        ]
        XCTAssertEqual(MessageListText.participants(thread), "Maya Lindqvist, Tom Okafor")
    }

    func testOneMessageNamesItsSenderAsTheServerGaveIt() {
        let one = message(from: "'Northwind Weekly' via Example Group", "group@example.com", at: Date())
        XCTAssertEqual(MessageListText.participants([one]), "'Northwind Weekly' via Example Group")
    }

    func testAnAddressInAnotherCaseIsTheSamePersonAndOneWithoutANameShowsItsAddress() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let thread = [
            message(from: "", "orders@example.com", at: now),
            message(from: "Priya Raman", "Priya@Example.com", at: now - 60),
            message(from: "Priya R.", "priya@example.com", at: now - 120),
        ]
        XCTAssertEqual(MessageListText.participants(thread), "orders@example.com, Priya Raman")
    }

    func testSendersWithoutAnAddressAreKnownByName() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let thread = [
            message(from: "Help Desk", "", at: now),
            message(from: "help desk", "", at: now - 60),
            message(from: "Sam Lee", "", at: now - 120),
        ]
        XCTAssertEqual(MessageListText.participants(thread), "Help Desk, Sam Lee")
    }

    // MARK: dates

    private func formats(_ identifier: String) -> MessageListText.DateFormats {
        MessageListText.DateFormats(locale: Locale(identifier: identifier), timeZone: TimeZone(identifier: "Asia/Baku")!)
    }

    private func date(_ text: String) -> Date {
        let parser = ISO8601DateFormatter()
        parser.timeZone = TimeZone(identifier: "Asia/Baku")!
        return parser.date(from: text)!
    }

    func testTodayShowsTheTimeInTheRegionsClock() {
        let now = date("2026-09-25T10:30:00+04:00")
        XCTAssertEqual(MessageListText.date(date("2026-09-25T00:34:00+04:00"), now: now, formats: formats("ru_RU")), "00:34")
        XCTAssertEqual(MessageListText.date(date("2026-09-25T09:05:00+04:00"), now: now, formats: formats("en_GB")), "09:05")
        let american = MessageListText.date(date("2026-09-25T09:05:00+04:00"), now: now, formats: formats("en_US"))
        XCTAssertTrue(american.hasPrefix("9:05") && american.hasSuffix("AM"), american)
    }

    func testTheDayBeforeIsYesterdayRightUpToMidnight() {
        let now = date("2026-09-25T00:10:00+04:00")
        XCTAssertEqual(MessageListText.date(date("2026-09-24T23:59:00+04:00"), now: now, formats: formats("ru_RU")), "Yesterday")
        XCTAssertEqual(MessageListText.date(date("2026-09-24T00:00:00+04:00"), now: now, formats: formats("ru_RU")), "Yesterday")
    }

    func testOlderDatesUseTheRegionsShortDateNotAWeekday() {
        let now = date("2026-09-25T10:30:00+04:00")
        let older = date("2026-09-23T16:00:00+04:00")
        XCTAssertEqual(MessageListText.date(older, now: now, formats: formats("ru_RU")), "23.09.2026")
        XCTAssertEqual(MessageListText.date(older, now: now, formats: formats("en_GB")), "23/09/2026")
        XCTAssertEqual(MessageListText.date(older, now: now, formats: formats("en_US")), "9/23/26")
    }

    func testADateAfterTodayIsShownAsADate() {
        let now = date("2026-09-25T10:30:00+04:00")
        XCTAssertEqual(MessageListText.date(date("2026-09-26T08:00:00+04:00"), now: now, formats: formats("ru_RU")), "26.09.2026")
    }

    // MARK: previews

    func testAPreviewStaysOnOneLine() {
        XCTAssertEqual(MessageListText.preview("Hello Sam,\n\nThe figures\tare below.  "), "Hello Sam, The figures are below.")
        XCTAssertEqual(MessageListText.preview("Already one line."), "Already one line.")
        XCTAssertEqual(MessageListText.preview(""), "")
    }
}
