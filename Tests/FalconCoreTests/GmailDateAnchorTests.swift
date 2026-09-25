import XCTest
@testable import FalconCore

/// Date group headers from anchors: the groups are the list's own, and an anchor is asked again
/// only when something could have moved it.
final class GmailDateAnchorTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Baku")!
        calendar.firstWeekday = 2
        return calendar
    }()

    private let locale = Locale(identifier: "en_GB")

    private func date(_ text: String) -> Date {
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return format.date(from: text)!
    }

    /// `ListSort.dayKey` as the list has it (App/FalconMail/State/ListRows.swift), with the clock
    /// and calendar given.
    private func dayKey(_ date: Date, now: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        if let week = calendar.date(byAdding: .day, value: -7, to: now), date > week { return "Earlier this week" }
        if let month = calendar.date(byAdding: .month, value: -1, to: now), date > month { return "Earlier this month" }
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.locale = locale
        format.dateFormat = "MMMM yyyy"
        return format.string(from: date)
    }

    /// The group a message falls in by the boundaries: the title of the last boundary it is older than.
    private func group(_ date: Date, in boundaries: [GmailDateBoundary]) -> String {
        boundaries.last { date < $0.date }?.title ?? GmailDateGroups.newestTitle
    }

    func testTheGroupsAreTheListsOwn() {
        let now = date("2026-09-25 15:30:00")
        let boundaries = GmailDateGroups.boundaries(now: now, oldest: date("2025-11-03 09:00:00"), calendar: calendar, locale: locale)
        XCTAssertEqual(boundaries.prefix(4).map(\.title), ["Yesterday", "Earlier this week", "Earlier this month", "August 2026"])
        XCTAssertEqual(boundaries.dropFirst(4).map(\.title), ["July 2026", "June 2026", "May 2026", "April 2026", "March 2026", "February 2026",
                                                              "January 2026", "December 2025", "November 2025"])
        XCTAssertEqual(boundaries[0].date, date("2026-09-25 00:00:00"))
        XCTAssertEqual(boundaries[4].date, date("2026-08-01 00:00:00"))
        XCTAssertEqual(boundaries.map(\.date), boundaries.map(\.date).sorted(by: >), "newest first")

        let samples = ["2026-09-25 23:59:00", "2026-09-25 00:00:00", "2026-09-24 23:59:59", "2026-09-24 00:00:00", "2026-09-23 12:00:00",
                       "2026-09-18 15:30:01", "2026-09-18 15:30:00", "2026-09-18 15:29:59", "2026-09-01 00:00:00", "2026-08-25 15:30:01",
                       "2026-08-25 15:30:00", "2026-08-25 15:29:59", "2026-08-01 00:00:00", "2026-07-31 23:59:59", "2026-02-14 10:00:00",
                       "2025-11-03 09:00:00"]
        for sample in samples.map(date) {
            XCTAssertEqual(group(sample, in: boundaries), dayKey(sample, now: now), "\(sample)")
        }
    }

    func testWithoutTheOldestDateOnlyTheRecentGroupsAreWorkedOut() {
        let boundaries = GmailDateGroups.boundaries(now: date("2026-03-10 08:00:00"), oldest: nil, calendar: calendar, locale: locale)
        XCTAssertEqual(boundaries.map(\.title), ["Yesterday", "Earlier this week", "Earlier this month", "February 2026"])
    }

    func testOnlyMissingAnchorsAndTheRecentOnesAfterMidnightAreAskedAgain() {
        let now = date("2026-09-25 15:30:00")
        let boundaries = GmailDateGroups.boundaries(now: now, oldest: date("2026-05-01 00:00:00"), calendar: calendar, locale: locale)
        let askedYesterday = date("2026-09-24 22:00:00")
        var anchors = boundaries.map { GmailDateAnchor(boundary: $0.date, id: nil, order: nil, askedAt: askedYesterday) }
        anchors.removeLast()
        let due = GmailDateAnchoring.boundariesToAsk(boundaries, anchors: anchors, now: now, calendar: calendar)
        XCTAssertEqual(due, Array(boundaries.prefix(4).map(\.date)) + [boundaries.last!.date],
                       "the recent four move at midnight, the months never; one month has no anchor yet")
        let fresh = anchors.map { GmailDateAnchor(boundary: $0.boundary, id: nil, order: nil, askedAt: now) }
        XCTAssertEqual(GmailDateAnchoring.boundariesToAsk(boundaries, anchors: fresh, now: now, calendar: calendar), [boundaries.last!.date])
    }

    func testAnAnchorIsAskedAgainOnlyWhenAMessageLandsDirectlyAboveIt() {
        let index = GmailIndex()
        index.apply(GmailListingPage(chain: .allMail(after: nil, before: nil), refs: (0..<10).map { GmailIndexTests.ref($0) }, firstOrder: 1_000))
        let snapshot = index.snapshot()
        let june = GmailDateAnchor(boundary: date("2026-06-01 00:00:00"), id: GmailIndexTests.ref(6).id, order: 1_000 - 6 * 16, askedAt: Date())
        let may = GmailDateAnchor(boundary: date("2026-05-01 00:00:00"), id: nil, order: nil, askedAt: Date())
        XCTAssertTrue(GmailDateAnchoring.boundariesToAskAgain([june, may], placed: [], in: snapshot).isEmpty)

        // Placed between the anchor and the message above it: it may be older than the boundary.
        index.apply(.place(GmailIndexTests.ref(100), order: 1_000 - 6 * 16 + 8, labels: [], attributes: []))
        XCTAssertEqual(GmailDateAnchoring.boundariesToAskAgain([june, may], placed: [GmailIndexTests.ref(100).id], in: index.snapshot()),
                       [june.boundary])
        // Placed higher up, above a message already newer than the boundary: nothing moves.
        index.apply(.place(GmailIndexTests.ref(101), order: 1_000 - 2 * 16 + 8, labels: [], attributes: []))
        XCTAssertTrue(GmailDateAnchoring.boundariesToAskAgain([june, may], placed: [GmailIndexTests.ref(101).id], in: index.snapshot()).isEmpty)
        // Placed below everything: a boundary with no older message may have one now.
        index.apply(.place(GmailIndexTests.ref(102), order: 1, labels: [], attributes: []))
        XCTAssertEqual(GmailDateAnchoring.boundariesToAskAgain([june, may], placed: [GmailIndexTests.ref(102).id], in: index.snapshot()),
                       [may.boundary])
    }

    func testAnAnchorFollowsItsMessageAndMovesDownWhenItIsDeleted() {
        let index = GmailIndex()
        index.apply(GmailListingPage(chain: .allMail(after: nil, before: nil), refs: (0..<10).map { GmailIndexTests.ref($0) }, firstOrder: 1_000))
        let anchor = GmailDateAnchor(boundary: date("2026-06-01 00:00:00"), id: GmailIndexTests.ref(6).id, order: 1_000 - 6 * 16, askedAt: Date())
        // Renumbered to make room: the anchor reads its message's new order.
        index.apply(.place(GmailIndexTests.ref(6), order: 1_000 - 6 * 16 - 4, labels: [], attributes: []))
        XCTAssertEqual(GmailDateAnchoring.resolve([anchor], in: index.snapshot()).first?.order, 1_000 - 6 * 16 - 4)
        // Deleted: the next older message is now the newest one older than the boundary.
        index.apply(.tombstone(GmailIndexTests.ref(6).id))
        let moved = GmailDateAnchoring.resolve([anchor], in: index.snapshot()).first
        XCTAssertEqual(moved?.id, GmailIndexTests.ref(7).id)
        XCTAssertEqual(moved?.order, 1_000 - 7 * 16)
        // The oldest deleted too: no message is older than the boundary any more.
        for n in 7..<10 { index.apply(.tombstone(GmailIndexTests.ref(n).id)) }
        let none = GmailDateAnchoring.resolve([GmailDateAnchor(boundary: anchor.boundary, id: GmailIndexTests.ref(9).id, order: 1_000 - 9 * 16,
                                                               askedAt: Date())], in: index.snapshot()).first
        XCTAssertNil(none?.id)
        XCTAssertNil(none?.order)
    }
}
