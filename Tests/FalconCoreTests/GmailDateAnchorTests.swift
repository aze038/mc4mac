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

    /// The list's groups: `ListSort.dayKey`'s (App/FalconMail/State/ListRows.swift), with each edge
    /// at a local midnight as the list draws them, so the anchors behind its headers hold all day.
    private func listGroup(_ date: Date, now: Date) -> String {
        let today = calendar.startOfDay(for: now)
        if date >= today { return "Today" }
        if date >= calendar.date(byAdding: .day, value: -1, to: today)! { return "Yesterday" }
        if date >= calendar.date(byAdding: .day, value: -6, to: today)! { return "Earlier this week" }
        if date >= calendar.date(byAdding: .month, value: -1, to: today)! { return "Earlier this month" }
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
                       "2026-09-19 00:00:01", "2026-09-19 00:00:00", "2026-09-18 23:59:59", "2026-09-01 00:00:00", "2026-08-25 00:00:01",
                       "2026-08-25 00:00:00", "2026-08-24 23:59:59", "2026-08-01 00:00:00", "2026-07-31 23:59:59", "2026-02-14 10:00:00",
                       "2025-11-03 09:00:00"]
        for sample in samples.map(date) {
            XCTAssertEqual(group(sample, in: boundaries), listGroup(sample, now: now), "\(sample)")
            XCTAssertEqual(ListDateGroups(now: now, calendar: calendar).title(for: sample), listGroup(sample, now: now), "\(sample)")
        }
        let later = GmailDateGroups.boundaries(now: date("2026-09-25 23:10:00"), oldest: date("2025-11-03 09:00:00"), calendar: calendar,
                                               locale: locale)
        XCTAssertEqual(later.map(\.date), boundaries.map(\.date), "the same boundaries all day, so anchors asked in the morning hold")
    }

    func testWithoutTheOldestDateOnlyTheRecentGroupsAreWorkedOut() {
        let boundaries = GmailDateGroups.boundaries(now: date("2026-03-10 08:00:00"), oldest: nil, calendar: calendar, locale: locale)
        XCTAssertEqual(boundaries.map(\.title), ["Yesterday", "Earlier this week", "Earlier this month", "February 2026"])
    }

    func testOnlyBoundariesWithoutAnAnchorAreAskedAndYesterdaysAnchorsStillHoldToday() {
        let now = date("2026-09-25 15:30:00")
        let boundaries = GmailDateGroups.boundaries(now: now, oldest: date("2026-05-01 00:00:00"), calendar: calendar, locale: locale)
        let askedYesterday = date("2026-09-24 22:00:00")
        var anchors = boundaries.map { GmailDateAnchor(boundary: $0.date, id: nil, order: nil, askedAt: askedYesterday) }
        anchors.removeLast()
        XCTAssertEqual(GmailDateAnchoring.boundariesToAsk(boundaries, anchors: anchors), [boundaries.last!.date],
                       "a boundary is a fixed midnight, so only the month with no anchor yet is asked")
        // After midnight the new day's boundaries are new dates; yesterday's midnight is still one of them.
        let tomorrow = GmailDateGroups.boundaries(now: date("2026-09-26 08:00:00"), oldest: date("2026-05-01 00:00:00"), calendar: calendar,
                                                  locale: locale)
        let due = GmailDateAnchoring.boundariesToAsk(tomorrow, anchors: anchors + [GmailDateAnchor(boundary: boundaries.last!.date, id: nil,
                                                                                                     order: nil, askedAt: now)])
        XCTAssertTrue(due.contains(date("2026-09-26 00:00:00")))
        XCTAssertFalse(due.contains(date("2026-09-25 00:00:00")), "today's midnight was asked already, as the Today boundary")
        XCTAssertLessThanOrEqual(due.count, GmailDateGroups.recentCount)
    }

    func testDailyBoundariesAddEveryMidnightOfTheLastMonth() {
        let now = date("2026-09-25 15:30:00")
        let daily = GmailDateGroups.boundaries(now: now, oldest: date("2026-05-01 00:00:00"), daily: true, calendar: calendar, locale: locale)
        let plain = GmailDateGroups.boundaries(now: now, oldest: date("2026-05-01 00:00:00"), calendar: calendar, locale: locale)
        XCTAssertTrue(Set(plain.map(\.date)).isSubset(of: Set(daily.map(\.date))))
        XCTAssertTrue(daily.contains { $0.date == date("2026-09-10 00:00:00") && $0.title == "Earlier this month" })
        XCTAssertTrue(daily.contains { $0.date == date("2026-09-22 00:00:00") && $0.title == "Earlier this week" })
        XCTAssertEqual(daily.map(\.date), daily.map(\.date).sorted(by: >))
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
