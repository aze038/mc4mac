import XCTest
@testable import FalconCore

final class RowFetchSchedulerTests: XCTestCase {
    private let account = UUID()

    private func keys(_ range: Range<Int>) -> [RowKey] {
        range.map { .gmail(account: account, id: GmailMessageID(raw: 0x1000 + UInt64($0))) }
    }

    /// A screen of old mail: 40% conversations at 40 units, the rest single messages at 20.
    private func mixedCost(_ key: RowKey) -> Int {
        guard let id = key.gmailID else { return 0 }
        return id.raw % 5 < 2 ? 40 : 20
    }

    // MARK: - The scroll

    func testNothingIsAskedForDuringAFlingAndTheScreenAndOneAheadOnceItSettles() {
        var planner = ScrollFetchPlanner()
        planner.reset(rowCount: 200_000)
        let first = planner.scrolled(to: 0..<25, at: 0)
        XCTAssertEqual(first.visible, 0..<25, "the first screen at once")

        // Five screens in a tenth of a second is a fling.
        var time = 0.0
        for step in 1...20 {
            time += 0.02
            let plan = planner.scrolled(to: (step * 25)..<(step * 25 + 25), at: time)
            XCTAssertNil(plan.visible, "nothing is fetched during a fling")
            XCTAssertNil(plan.ahead)
            XCTAssertNotNil(plan.settleAt)
        }
        XCTAssertTrue(planner.isFlinging)
        // The settle check fires too early while the scroll is still moving.
        XCTAssertNil(planner.settled(at: time + 0.05).visible)
        let rest = planner.settled(at: time + ScrollFetchPlanner.settleDelay)
        XCTAssertEqual(rest.visible, 500..<525)
        XCTAssertEqual(rest.ahead, 525..<550, "one screen ahead in the scroll's direction")
    }

    func testReadingSlowlyAsksForEachScreenAsItComesAndAheadOnlyAfterAPause() {
        var planner = ScrollFetchPlanner()
        planner.reset(rowCount: 1_000)
        _ = planner.scrolled(to: 100..<125, at: 0)
        // Upwards, a screen a second: slow enough to read.
        let plan = planner.scrolled(to: 75..<100, at: 1)
        XCTAssertEqual(plan.visible, 75..<100)
        XCTAssertNil(plan.ahead)
        let rest = planner.settled(at: 1.2)
        XCTAssertEqual(rest.ahead, 50..<75, "upwards, the screen above")
        XCTAssertNil(rest.visible, "the screen was already asked for")
    }

    func testTheAheadScreenStopsAtTheListsEnds() {
        var planner = ScrollFetchPlanner()
        planner.reset(rowCount: 40)
        _ = planner.scrolled(to: 0..<25, at: 0)
        _ = planner.scrolled(to: 10..<35, at: 1)
        XCTAssertEqual(planner.settled(at: 2).ahead, 35..<40)
    }

    // MARK: - Landings

    func testALandingHoldsAtMost25RowsAndTheScreenAheadGoesTenAtATime() {
        let scheduler = RowFetchScheduler()
        scheduler.request(keys(0..<60), priority: .visible) { _ in 20 }
        let first = scheduler.next(at: 0)
        XCTAssertEqual(first?.keys, keys(0..<25))
        XCTAssertEqual(first?.units, 500)
        XCTAssertEqual(first?.priority, .visible)
        let second = scheduler.next(at: 0)
        XCTAssertEqual(second?.keys, keys(25..<50))
        XCTAssertNil(scheduler.next(at: 0), "the budget's thousand units are spent")
        scheduler.finished(keys(0..<50))
        // The owner scrolled back to rows already filled: the rest of the old screen is dropped.
        scheduler.request([], priority: .visible) { _ in 20 }
        scheduler.request(keys(100..<130), priority: .ahead) { _ in 20 }
        XCTAssertNil(scheduler.next(at: 5), "background work waits while the budget is low")
        let ahead = scheduler.next(at: 60)
        XCTAssertEqual(ahead?.keys, keys(100..<110))
        XCTAssertEqual(ahead?.priority, .ahead)
    }

    func testRowsNotYetSentAreDroppedWhenTheyLeaveTheScreenAndRowsOnTheirWayAreShared() {
        let scheduler = RowFetchScheduler()
        scheduler.pause(until: 100)
        scheduler.request(keys(0..<25), priority: .visible) { _ in 20 }
        XCTAssertNil(scheduler.next(at: 0), "Gmail has asked FalconMail to wait")
        scheduler.request(keys(200..<225), priority: .visible) { _ in 20 }
        XCTAssertEqual(scheduler.pendingVisible, keys(200..<225), "the first screen scrolled away before it was sent")

        let open = RowFetchScheduler()
        open.request(keys(0..<25), priority: .visible) { _ in 20 }
        let landing = open.next(at: 0)!
        XCTAssertTrue(open.isInFlight(landing.keys[0]))
        open.request(keys(0..<25), priority: .visible) { _ in 20 }
        XCTAssertNil(open.next(at: 0), "rows already on their way are not asked for again")
        open.finished(landing.keys)
        XCTAssertFalse(open.isInFlight(landing.keys[0]))
    }

    func testBackgroundWorkNeverTakesTheBudgetBelowFiveHundred() {
        let budget = TokenBucketEstimate()
        let scheduler = RowFetchScheduler(budget: budget)
        scheduler.request(keys(0..<30), priority: .ahead) { _ in 40 }
        var sent = 0
        while let landing = scheduler.next(at: 0) { sent += landing.units }
        XCTAssertEqual(sent, 400, "one landing of ten at 40 units, and the next would pass the floor")
        XCTAssertGreaterThanOrEqual(budget.level(at: 0), 500)
        scheduler.request(keys(50..<75), priority: .visible) { _ in 20 }
        XCTAssertNotNil(scheduler.next(at: 0), "a click finds units")
    }

    /// The owner jumps through old mail never seen before, ten screens in a minute. The budget
    /// holds 1,000 units and refills 2,000 a minute; a screen of old mail costs about 700.
    func testTheFifthToTenthLandingInAMinuteShowTheFooterAtOnceAndEachFillsWithin25Seconds() {
        let scheduler = RowFetchScheduler()
        var filled: [Int: Double] = [:]
        var footerAtOnce: [Int: Bool] = [:]
        var screen = 0
        var time = 0.0
        var requestedAt: [Int: Double] = [:]
        // A landing goes as soon as the budget has room; the owner stays on the tenth screen.
        func run(until end: Double) {
            while time < end {
                if let landing = scheduler.next(at: time) {
                    XCTAssertLessThanOrEqual(landing.keys.count, 25)
                    scheduler.finished(landing.keys)
                    filled[screen] = time - requestedAt[screen]!
                }
                time += 0.1
            }
        }
        for s in 1...10 {
            screen = s
            requestedAt[s] = time
            scheduler.request(keys((s * 1_000)..<(s * 1_000 + 25)), priority: .visible, cost: mixedCost)
            footerAtOnce[s] = scheduler.isWaitingOnBudget(at: time)
            run(until: time + 6)
        }
        run(until: time + 30)
        XCTAssertEqual(filled[1] ?? 99, 0, accuracy: 0.001, "the first landing after a pause fills at once")
        for s in 5...10 {
            XCTAssertEqual(footerAtOnce[s], true, "landing \(s) shows the footer at once")
        }
        XCTAssertNotNil(filled[10])
        XCTAssertLessThanOrEqual(filled[10] ?? 99, 25, "the screen the owner stays on fills within 25 seconds")
        for (s, wait) in filled { XCTAssertLessThanOrEqual(wait, 25, "landing \(s)") }
    }

    func testReadingDownwardsAtAScreenEveryTwentySecondsNeverWaits() {
        let scheduler = RowFetchScheduler()
        var time = 0.0
        for s in 0..<15 {
            scheduler.request(keys((s * 25)..<(s * 25 + 25)), priority: .visible) { _ in 20 }
            XCTAssertFalse(scheduler.isWaitingOnBudget(at: time), "screen \(s)")
            let landing = scheduler.next(at: time)
            XCTAssertNotNil(landing)
            scheduler.finished(landing?.keys ?? [])
            time += 20
        }
    }

    func testAPauseFromGmailHoldsLandingsBackUntilItEnds() {
        let scheduler = RowFetchScheduler()
        scheduler.pause(until: 30)
        scheduler.request(keys(0..<5), priority: .visible) { _ in 20 }
        XCTAssertNil(scheduler.next(at: 10))
        XCTAssertEqual(scheduler.delay(at: 10) ?? 0, 20, accuracy: 0.001)
        XCTAssertNotNil(scheduler.next(at: 30))
    }
}
