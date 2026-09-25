import XCTest
@testable import FalconCore

/// When checks run (§4.1): the pace by the owner's activity, the holds, and the engine's loop
/// keeping to them on its own.
final class GmailPollScheduleTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func testThePaceFollowsTheOwner() {
        var schedule = GmailPollSchedule(now: t0)
        XCTAssertEqual(schedule.nextCheck(after: t0), t0, "the first check is due at once")
        schedule.checkEnded(at: t0)
        XCTAssertEqual(schedule.nextCheck(after: t0), t0.addingTimeInterval(30), "every 30 seconds while the owner is active")
        schedule.noteActivity(.active(at: t0.addingTimeInterval(-29 * 60)))
        XCTAssertEqual(schedule.interval(at: t0), 30)
        XCTAssertEqual(schedule.interval(at: t0.addingTimeInterval(61)), 120, "every 2 minutes after half an hour without input")
        schedule.noteActivity(.idle(since: t0))
        XCTAssertEqual(schedule.nextCheck(after: t0), t0.addingTimeInterval(120), "or with the screen locked")
        schedule.noteActivity(.asleep)
        XCTAssertNil(schedule.nextCheck(after: t0), "nothing while the Mac sleeps")
    }

    func testHoldsDelayAndStopChecks() {
        var schedule = GmailPollSchedule(now: t0)
        schedule.checkEnded(at: t0)
        schedule.messageSent(at: t0)
        XCTAssertEqual(schedule.nextCheck(after: t0), t0.addingTimeInterval(2))
        schedule.checkEnded(at: t0.addingTimeInterval(2))
        XCTAssertEqual(schedule.nextCheck(after: t0.addingTimeInterval(2)), t0.addingTimeInterval(10))
        schedule.pause(until: t0.addingTimeInterval(300))
        XCTAssertEqual(schedule.nextCheck(after: t0.addingTimeInterval(2)), t0.addingTimeInterval(300), "nothing before Google's time")
        schedule.pause(until: nil)
        schedule.block(until: t0.addingTimeInterval(3_600))
        XCTAssertEqual(schedule.nextCheck(after: t0.addingTimeInterval(2)), t0.addingTimeInterval(3_600))
        schedule.clearHolds()
        schedule.stop(true)
        XCTAssertNil(schedule.nextCheck(after: t0))
        schedule.clearHolds()
        schedule.setOffline(true)
        XCTAssertEqual(schedule.interval(at: t0), 120)
    }

    func testTheLoopChecksOnItsOwnAtTheOwnersPace() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        for i in 0..<5 { gmail.add(subject: "Old \(i)", labels: [.inbox], date: clock.now().addingTimeInterval(-Double(5 - i) * 86_400)) }
        let rig = GmailEngineRig(transport: gmail, clock: clock)
        await rig.engine.start()
        try await eventually("the first listing") { await rig.engine.state.backfill?.phase == .complete }
        func settled() async throws -> Int {
            var last = -1
            var count = await rig.engine.checksCompleted
            while last != count {
                last = count
                try await Task.sleep(nanoseconds: 50_000_000)
                count = await rig.engine.checksCompleted
            }
            return count
        }
        var checks = try await settled()
        clock.advance(by: 30)
        try await eventually("a check 30 seconds later") { await rig.engine.checksCompleted > checks }
        checks = try await settled()
        clock.advance(by: 10)
        try await Task.sleep(nanoseconds: 100_000_000)
        let early = await rig.engine.checksCompleted
        XCTAssertEqual(early, checks, "none sooner")

        await rig.engine.noteOwnerActivity(.idle(since: clock.now()))
        clock.advance(by: 30)
        try await Task.sleep(nanoseconds: 100_000_000)
        let idle = await rig.engine.checksCompleted
        XCTAssertEqual(idle, checks, "idle: not after 30 seconds")
        clock.advance(by: 90)
        try await eventually("a check two minutes after the last") { await rig.engine.checksCompleted > checks }
        checks = try await settled()

        await rig.engine.noteOwnerActivity(.asleep)
        clock.advance(by: 600)
        try await Task.sleep(nanoseconds: 100_000_000)
        let asleep = await rig.engine.checksCompleted
        XCTAssertEqual(asleep, checks, "nothing while the Mac sleeps")
        clock.advance(by: 1)
        let fresh = gmail.add(subject: "Came in during sleep", labels: [.inbox, .unread], date: clock.now())
        await rig.engine.noteOwnerActivity(.active(at: clock.now()))
        try await eventually("a check on waking") { rig.events.announcedSubjects.contains("Came in during sleep") }
        let placed = await rig.store.record(for: fresh.id)
        XCTAssertNotNil(placed)
        await rig.finish()
    }
}
