import XCTest
@testable import FalconCore

/// The Gmail engine's budget for one account: the token bucket, the classes of work, requests and
/// batch parts in flight, the pauses Google asks for, and the API's byte budgets.
final class GmailBudgetTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Log.isEnabled = false
    }

    override func tearDown() {
        Log.isEnabled = true
        super.tearDown()
    }

    private func landing(_ rows: Int = 25, work: WorkClass = .interactive) -> GmailBooking {
        GmailBooking(work: work, calls: [.messagesGet: rows], direction: .download)
    }

    /// The largest sum of units granted in any 60 seconds.
    private func busiestMinute(_ grants: [GmailGrant]) -> Int {
        var best = 0
        var total = 0
        var start = 0
        for grant in grants {
            total += grant.units
            while grant.at.timeIntervalSince(grants[start].at) >= 60 {
                total -= grants[start].units
                start += 1
            }
            best = max(best, total)
        }
        return best
    }

    private func virtualBudget(_ clock: VirtualClock, policy: GmailBudgetPolicy = .standard, meter: TrafficMeter? = nil,
                               account: UUID = UUID()) -> GmailBudget {
        GmailBudget(accountID: account, policy: policy, meter: meter, gate: GmailBackgroundGate(limit: 8), now: { clock.now },
                    sleep: { clock.advance($0) }, jitter: { 0 })
    }

    // MARK: The bucket

    func testNoSixtySecondsEverBookMoreThanThreeThousandUnits() async throws {
        let clock = VirtualClock()
        let budget = virtualBudget(clock)
        for i in 0..<300 {
            let b = i % 3 == 0 ? landing() : GmailBooking(.threadsGet, work: .interactive)
            let ticket = try await budget.admit(b)
            await budget.finish(ticket)
        }
        let grants = await budget.recentGrants()
        XCTAssertLessThanOrEqual(busiestMinute(grants), 3_000)
        XCTAssertGreaterThanOrEqual(busiestMinute(grants), 2_900, "and it does use what it has")
        // The first thousand go at once; after that 2,000 a minute.
        let total = grants.reduce(0) { $0 + $1.units }
        let expected = Double(total - 1_000) / 2_000 * 60
        XCTAssertEqual(clock.now.timeIntervalSince(grants[0].at), expected, accuracy: 30)
    }

    func testAnotherAppImportingKeepsEveryMinuteAtOrBelowTwoThousand() async throws {
        let clock = VirtualClock()
        let budget = virtualBudget(clock)
        let first = try await budget.admit(landing(10))
        await budget.finish(first)
        await budget.setFloodMode(true)
        let available = await budget.available()
        XCTAssertLessThanOrEqual(available, 500, "the bucket holds at most 500 while another app imports")
        let floodStart = clock.now
        for _ in 0..<200 {
            let ticket = try await budget.admit(landing(20))
            await budget.finish(ticket)
        }
        let grants = await budget.recentGrants().filter { $0.at >= floodStart }
        XCTAssertLessThanOrEqual(busiestMinute(grants), 2_000)
        XCTAssertGreaterThanOrEqual(busiestMinute(grants), 1_600, "landings of 400 fill all but the last part of it")
        let limits = await budget.batchLimits(for: .interactive)
        XCTAssertEqual(limits.units, 500, "a landing is split to fit the smaller bucket")
        let background = await budget.batchLimits(for: .background(.cacheFill))
        XCTAssertEqual(background.units, 250)
    }

    func testBackgroundNeverTakesTheBucketBelowItsReserve() async throws {
        let clock = VirtualClock()
        let budget = virtualBudget(clock)
        for _ in 0..<120 {
            let ticket = try await budget.admit(GmailBooking(work: .background(.cacheFill), calls: [.messagesGet: 10], direction: .download))
            let left = await budget.available()
            XCTAssertGreaterThanOrEqual(left, 500)
            await budget.finish(ticket)
        }
        await budget.setFloodMode(true)
        for _ in 0..<40 {
            let ticket = try await budget.admit(GmailBooking(work: .background(.index), calls: [.messagesList: 10], direction: .download))
            let left = await budget.available()
            XCTAssertGreaterThanOrEqual(left, 250)
            await budget.finish(ticket)
        }
    }

    func testAClickDuringABackgroundBurstGetsItsUnitsWithinATenthOfASecond() async throws {
        let clock = SteppedClock()
        let budget = GmailTestKit.budget(clock)
        // Background work fills the newest thousand as fast as the budget lets it, two requests
        // at a time, each answered after a second.
        let background = Task {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<2 {
                    group.addTask {
                        while !Task.isCancelled {
                            let ticket = try await budget.admit(GmailBooking(work: .background(.cacheFill), calls: [.messagesGet: 10],
                                                                             direction: .download))
                            await clock.sleep(1)
                            await budget.finish(ticket)
                        }
                    }
                }
                try await group.waitForAll()
            }
        }
        await clock.run(for: 20, step: 0.25)
        let before = await budget.available()
        XCTAssertLessThan(before, 800, "the burst is using the bucket")
        let asked = clock.now
        let click = Task { try await budget.admit(landing(25)) }
        var granted: Date?
        for _ in 0..<10 {
            await clock.run(for: 0.01, step: 0.01)
            if let grant = await budget.recentGrants().last(where: { $0.work == .interactive }) {
                granted = grant.at
                break
            }
        }
        let at = try XCTUnwrap(granted, "the click was let through")
        XCTAssertLessThanOrEqual(at.timeIntervalSince(asked), 0.1)
        let ticket = try await click.value
        await budget.finish(ticket)
        background.cancel()
        await clock.run(for: 2, step: 0.5)
    }

    func testChecksGoFirstThenClicksThenBulkThenBackgroundByRank() async throws {
        let clock = SteppedClock()
        let budget = GmailTestKit.budget(clock)
        // Empty the bucket.
        let drain = try await budget.admit(GmailBooking(work: .interactive, calls: [.threadsGet: 25], direction: .download))
        await budget.finish(drain)
        let order = OrderRecorder()
        var tasks: [Task<Void, Error>] = []
        let queued: [(String, WorkClass)] = [("index", .background(.index)), ("bulk", .bulk), ("readAhead", .background(.readAhead)),
                                             ("click", .interactive), ("check", .checks)]
        for (name, work) in queued {
            tasks.append(Task {
                let ticket = try await budget.admit(GmailBooking(work: work, calls: [.messagesGet: 5], direction: .download))
                order.append(name)
                await budget.finish(ticket)
            })
            await SteppedClock.settle()
        }
        await clock.run(for: 120, step: 0.5)
        for task in tasks { try await task.value }
        XCTAssertEqual(order.all, ["check", "click", "bulk", "readAhead", "index"])
    }

    // MARK: Classes of work

    func testBulkWorkTakesAtMostFifteenHundredAMinute() async throws {
        let clock = VirtualClock()
        let budget = virtualBudget(clock)
        for _ in 0..<100 {
            let ticket = try await budget.admit(GmailBooking(.messagesBatchModify, work: .bulk))
            await budget.finish(ticket)
        }
        let grants = await budget.recentGrants()
        XCTAssertLessThanOrEqual(busiestMinute(grants), 1_500)
        XCTAssertGreaterThan(busiestMinute(grants), 1_400)
    }

    func testBackgroundKeepsToAThousandAMinuteWhileTheOwnerWorksAndFiveHundredDuringAFlood() async throws {
        let clock = VirtualClock()
        // The owner counts as active for an hour after each input, so he works throughout.
        let budget = virtualBudget(clock, policy: GmailBudgetPolicy(activeWindow: 3_600))
        let start = clock.now
        for _ in 0..<100 {
            await budget.noteOwnerActivity(at: clock.now)
            let ticket = try await budget.admit(GmailBooking(work: .background(.index), calls: [.messagesList: 10], direction: .download))
            await budget.finish(ticket)
        }
        let active = await budget.recentGrants().filter { $0.at >= start }
        XCTAssertLessThanOrEqual(busiestMinute(active), 1_000)

        clock.advance(120)
        await budget.setFloodMode(true)
        let floodStart = clock.now
        for _ in 0..<60 {
            let ticket = try await budget.admit(GmailBooking(work: .background(.index), calls: [.messagesList: 10], direction: .download))
            await budget.finish(ticket)
        }
        let flood = await budget.recentGrants().filter { $0.at >= floodStart }
        XCTAssertLessThanOrEqual(busiestMinute(flood), 500)

        // Idle and no flood, background may use everything above the reserve.
        clock.advance(3_700)
        await budget.setFloodMode(false)
        clock.advance(60)
        let idleStart = clock.now
        for _ in 0..<60 {
            let ticket = try await budget.admit(GmailBooking(work: .background(.index), calls: [.messagesList: 10], direction: .download))
            await budget.finish(ticket)
        }
        let idle = await budget.recentGrants().filter { $0.at >= idleStart }
        XCTAssertGreaterThan(busiestMinute(idle), 1_500)
        XCTAssertLessThanOrEqual(busiestMinute(idle), 2_500)
    }

    // MARK: In flight

    func testAtMostFourRequestsAndTwoOfThemForBulkAndBackground() async throws {
        let clock = SteppedClock()
        let budget = GmailTestKit.budget(clock)
        let small = GmailBooking(work: .background(.cacheFill), calls: [.labelsGet: 1], direction: .download)
        let b1 = try await budget.admit(small)
        let b2 = try await budget.admit(small)
        let third = Task { try await budget.admit(small) }
        let bulk = Task { try await budget.admit(GmailBooking(.messagesModify, work: .bulk)) }
        await SteppedClock.settle()
        var flight = await budget.inFlight()
        XCTAssertEqual(flight.deferrableRequests, 2, "background holds at most two")
        let c1 = try await budget.admit(GmailBooking(.profile, work: .interactive))
        let c2 = try await budget.admit(GmailBooking(.profile, work: .checks))
        flight = await budget.inFlight()
        XCTAssertEqual(flight.requests, 4, "two are always there for clicks and checks")
        let fifth = Task { try await budget.admit(GmailBooking(.profile, work: .interactive)) }
        await SteppedClock.settle()
        flight = await budget.inFlight()
        XCTAssertEqual(flight.requests, 4)
        await budget.finish(c1)
        let t5 = try await fifth.value
        await budget.finish(b1)
        await SteppedClock.settle()
        flight = await budget.inFlight()
        XCTAssertEqual(flight.deferrableRequests, 2, "bulk ranks above background, and takes the freed place")
        let bulkTicket = try await bulk.value
        XCTAssertEqual(bulkTicket.booking.work, .bulk)
        for ticket in [c2, t5, b2, bulkTicket] { await budget.finish(ticket) }
        let t3 = try await third.value
        await budget.finish(t3)
        let peak = await budget.peak
        XCTAssertEqual(peak.requests, 4)
        XCTAssertEqual(peak.deferrableRequests, 2)
    }

    func testAtMostThirtyFivePartsInFlightAndAConcurrencyRefusalHalvesThemForTenMinutes() async throws {
        let clock = SteppedClock()
        let budget = GmailTestKit.budget(clock, policy: GmailBudgetPolicy(capacity: 100_000, refillPerMinute: 1_000_000))
        let rows = try await budget.admit(landing(25))
        let background = try await budget.admit(GmailBooking(work: .background(.cacheFill), calls: [.messagesGet: 10], direction: .download))
        let more = Task { try await budget.admit(landing(1)) }
        await SteppedClock.settle()
        var flight = await budget.inFlight()
        XCTAssertEqual(flight.parts, 35)
        await budget.finish(rows)
        let t = try await more.value
        await budget.finish(t)
        await budget.finish(background)

        let refusal = GoogleAPIError(kind: .rateLimited, httpStatus: 429, reason: "rateLimitExceeded", isConcurrencyLimit: true)
        let wait = await budget.note(refusal, sentAt: clock.now, attempt: 0)
        XCTAssertEqual(wait ?? 0, 1, accuracy: 0.01)
        var limits = await budget.batchLimits(for: .interactive)
        XCTAssertEqual(limits.parts, 12)
        limits = await budget.batchLimits(for: .background(.readAhead))
        XCTAssertEqual(limits.parts, 5)
        let available = await budget.available()
        XCTAssertEqual(available, 100_000 - 35 * 20 - 20, "a concurrency refusal leaves the units alone")
        flight = await budget.inFlight()
        XCTAssertEqual(flight.parts, 0)
        let half = try await budget.admit(landing(12))
        let over = Task { try await budget.admit(landing(1)) }
        await SteppedClock.settle()
        flight = await budget.inFlight()
        XCTAssertEqual(flight.foregroundParts, 12)
        await budget.finish(half)
        await budget.finish(try await over.value)
        await clock.run(for: 601, step: 30)
        limits = await budget.batchLimits(for: .interactive)
        XCTAssertEqual(limits.parts, 25, "back to 25 after ten minutes")
    }

    func testTheMacWideGateLetsEightBackgroundRequestsGoAtOnce() async throws {
        let clock = SteppedClock()
        let gate = GmailBackgroundGate(limit: 8)
        let budgets = (0..<5).map { _ in GmailTestKit.budget(clock, gate: gate) }
        let small = GmailBooking(work: .background(.index), calls: [.labelsGet: 1], direction: .download)
        var tickets: [(GmailBudget, GmailTicket)] = []
        for budget in budgets.prefix(4) {
            tickets.append((budget, try await budget.admit(small)))
            tickets.append((budget, try await budget.admit(small)))
        }
        XCTAssertEqual(gate.inFlight, 8)
        let ninth = Task { try await budgets[4].admit(small) }
        await SteppedClock.settle()
        XCTAssertEqual(gate.inFlight, 8)
        let click = try await budgets[4].admit(GmailBooking(.profile, work: .interactive))
        XCTAssertEqual(gate.inFlight, 8, "clicks never wait for the gate")
        await budgets[4].finish(click)
        let (owner, first) = tickets.removeFirst()
        await owner.finish(first)
        let t9 = try await ninth.value
        XCTAssertEqual(gate.inFlight, 8)
        await budgets[4].finish(t9)
        for (budget, ticket) in tickets { await budget.finish(ticket) }
        XCTAssertEqual(gate.inFlight, 0)
    }

    // MARK: Refusals

    func testARateRefusalHalvesTheRefillOncePerBurstAndItRecoversByATenthAMinute() async throws {
        let clock = VirtualClock()
        let budget = virtualBudget(clock)
        let sent = clock.now
        clock.advance(0.2)
        let refusal = GoogleAPIError(kind: .rateLimited, httpStatus: 429, reason: "rateLimitExceeded", retryAfter: 5)
        for _ in 0..<8 { _ = await budget.note(refusal, sentAt: sent, attempt: 0) }
        var pause = await budget.pause()
        XCTAssertEqual(pause?.until.timeIntervalSince(clock.now) ?? 0, 5, accuracy: 0.01)
        // Drain the bucket, then measure how fast it refills: 1,000 a minute after one halving.
        let drain = try await budget.admit(GmailBooking(work: .interactive, calls: [.threadsGet: 25], direction: .download))
        await budget.finish(drain)
        let start = clock.now
        for _ in 0..<10 {
            let ticket = try await budget.admit(landing(25))
            await budget.finish(ticket)
        }
        // 5,000 units at 1,000 a minute that grows by 200 each minute: 1,000t + 100t² = 5,000.
        let minutes = clock.now.timeIntervalSince(start) / 60
        XCTAssertEqual(minutes, 3.66, accuracy: 0.1)
        // A refusal of a call sent after the halving halves it again, never below a quarter.
        for _ in 0..<6 {
            clock.advance(1)
            _ = await budget.note(GoogleAPIError(kind: .rateLimited, httpStatus: 429), sentAt: clock.now, attempt: 0)
        }
        clock.advance(2)
        let empty = try await budget.admit(GmailBooking(work: .interactive, calls: [.messagesGet: 50], direction: .download))
        await budget.finish(empty)
        let low = clock.now
        let ticket = try await budget.admit(landing(25))
        await budget.finish(ticket)
        XCTAssertLessThanOrEqual(clock.now.timeIntervalSince(low), 60.5, "500 units take at most a minute at a quarter of the refill")
        clock.advance(15 * 60)
        pause = await budget.pause()
        XCTAssertNil(pause)
        let full = try await budget.admit(GmailBooking(work: .interactive, calls: [.threadsGet: 25], direction: .download))
        await budget.finish(full)
        let refill = clock.now
        let next = try await budget.admit(GmailBooking(work: .interactive, calls: [.threadsGet: 25], direction: .download))
        await budget.finish(next)
        XCTAssertEqual(clock.now.timeIntervalSince(refill), 30, accuracy: 0.5, "recovered: 2,000 a minute again")
    }

    func testADailyCapOrTheAPIOffRefusesEveryCallAtOnceUntilItCanHaveChanged() async throws {
        let clock = VirtualClock()
        let budget = virtualBudget(clock)
        _ = await budget.note(GoogleAPIError(kind: .quotaExhausted, httpStatus: 403, reason: "dailylimitexceeded"), sentAt: clock.now, attempt: 0)
        do {
            _ = try await budget.admit(GmailBooking(.historyList, work: .checks))
            XCTFail("held until midnight Pacific")
        } catch let refusal as GoogleAPIError {
            XCTAssertEqual(refusal.kind, .quotaExhausted)
            XCTAssertEqual(refusal.delivery, .notSent)
            XCTAssertEqual(clock.now.addingTimeInterval(refusal.retryAfter ?? 0).timeIntervalSince1970,
                           GoogleAPIError.quotaReset(after: clock.now).timeIntervalSince1970, accuracy: 1)
        }
        XCTAssertEqual(clock.slept, 0)
        clock.advance(GoogleAPIError.quotaReset(after: clock.now).timeIntervalSince(clock.now) + 1)
        let ticket = try await budget.admit(GmailBooking(.historyList, work: .checks))
        await budget.finish(ticket)

        _ = await budget.note(GoogleAPIError(kind: .apiDisabled, httpStatus: 403), sentAt: clock.now, attempt: 0)
        do {
            _ = try await budget.admit(GmailBooking(.profile, work: .interactive))
            XCTFail("held for ten minutes")
        } catch let refusal as GoogleAPIError {
            XCTAssertEqual(refusal.kind, .apiDisabled)
            XCTAssertEqual(refusal.retryAfter ?? 0, 600, accuracy: 1)
        }
        clock.advance(601)
        let after = try await budget.admit(GmailBooking(.profile, work: .interactive))
        await budget.finish(after)
        let counts = await budget.refusalCounts()
        XCTAssertEqual(counts["403 dailylimitexceeded"], 1)
    }

    func testEachAllowancePausesOnlyWhatItIsAbout() async throws {
        let clock = VirtualClock()
        let budget = virtualBudget(clock)
        func goes(_ b: GmailBooking) async -> GoogleAPIError.Kind? {
            do {
                let ticket = try await budget.admit(b, maxPause: 60)
                await budget.finish(ticket)
                return nil
            } catch let refusal as GoogleAPIError {
                return refusal.kind
            } catch {
                return .other
            }
        }
        let read = GmailBooking(.messagesGet, work: .interactive)
        let check = GmailBooking(.historyList, work: .checks)
        let send = GmailBooking(.messagesSend, work: .interactive)
        let draft = GmailBooking(.draftsCreate, work: .interactive)
        let change = GmailBooking(.messagesModify, work: .interactive)

        _ = await budget.note(GoogleAPIError(kind: .downloadLimit, httpStatus: 429, retryAfter: 7_200), sentAt: clock.now, attempt: 0)
        var got = await goes(read)
        XCTAssertEqual(got, .downloadLimit)
        got = await goes(check)
        XCTAssertNil(got, "new mail still arrives")
        got = await goes(send)
        XCTAssertNil(got)
        got = await goes(change)
        XCTAssertNil(got)
        clock.advance(7_201)

        _ = await budget.note(GoogleAPIError(kind: .uploadLimit, httpStatus: 429, retryAfter: 3_600), sentAt: clock.now, attempt: 0)
        got = await goes(send)
        XCTAssertEqual(got, .uploadLimit)
        got = await goes(draft)
        XCTAssertEqual(got, .uploadLimit)
        got = await goes(read)
        XCTAssertNil(got)
        clock.advance(3_601)

        _ = await budget.note(GoogleAPIError(kind: .sendingLimit, httpStatus: 429, retryAfter: 3_600), sentAt: clock.now, attempt: 0)
        got = await goes(send)
        XCTAssertEqual(got, .sendingLimit)
        got = await goes(draft)
        XCTAssertNil(got, "draft saves go on while sending waits")
        let pause = await budget.pause()
        XCTAssertEqual(pause?.refusal.kind, .sendingLimit)
    }

    func testAShortPauseIsWaitedOutAndALongOneHandedBack() async throws {
        let clock = VirtualClock()
        let budget = virtualBudget(clock)
        _ = await budget.note(GoogleAPIError(kind: .rateLimited, httpStatus: 429, retryAfter: 20), sentAt: clock.now, attempt: 0)
        let ticket = try await budget.admit(GmailBooking(.messagesGet, work: .interactive), maxPause: 60)
        XCTAssertEqual(clock.slept, 20, accuracy: 0.1)
        await budget.finish(ticket)
        _ = await budget.note(GoogleAPIError(kind: .rateLimited, httpStatus: 429, retryAfter: 90), sentAt: clock.now, attempt: 0)
        do {
            _ = try await budget.admit(GmailBooking(.messagesGet, work: .interactive), maxPause: 60)
            XCTFail("90 seconds is more than it waits")
        } catch let refusal as GoogleAPIError {
            XCTAssertEqual(refusal.retryAfter ?? 0, 90, accuracy: 0.1)
        }
    }

    func testAWaitLongerThanTheCallerAllowsIsRefusedAtOnce() async throws {
        let clock = VirtualClock()
        let budget = virtualBudget(clock)
        let drain = try await budget.admit(GmailBooking(work: .interactive, calls: [.threadsGet: 25], direction: .download))
        await budget.finish(drain)
        do {
            _ = try await budget.admit(landing(25), maxWait: 5)
            XCTFail("500 units take 15 seconds to come back")
        } catch let refusal as GoogleAPIError {
            XCTAssertEqual(refusal.kind, .rateLimited)
            XCTAssertEqual(refusal.reason, "localBudget")
            XCTAssertEqual(refusal.retryAfter ?? 0, 15, accuracy: 0.5)
        }
        XCTAssertEqual(clock.slept, 0)
    }

    func testACancelledWaiterLeavesTheQueue() async throws {
        let clock = SteppedClock()
        let budget = GmailTestKit.budget(clock)
        let drain = try await budget.admit(GmailBooking(work: .interactive, calls: [.threadsGet: 25], direction: .download))
        await budget.finish(drain)
        let waiting = Task { try await budget.admit(landing(25)) }
        await SteppedClock.settle()
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("cancelled")
        } catch is CancellationError {}
        let later = Task { try await budget.admit(landing(10)) }
        await clock.run(for: 7, step: 0.5)
        let ticket = try await later.value
        await budget.finish(ticket)
    }

    // MARK: Bytes

    func testTheAPIsOwnByteBudgetsStopWhatTheyAreAbout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("falcon-g1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = VirtualClock()
        let limits = TrafficLimits(background: 1_000_000, download: 1_000_000, upload: 1_000_000,
                                   api: APITrafficLimits(background: 8_000, download: 15_000, imports: 3_000, upload: 4_000))
        let meter = TrafficMeter(layout: FileLayout(root: root), limits: limits, now: { clock.now })
        let account = UUID()
        let budget = virtualBudget(clock, meter: meter, account: account)
        func goes(_ b: GmailBooking) async -> GoogleAPIError? {
            do {
                let ticket = try await budget.admit(b)
                await budget.finish(ticket)
                return nil
            } catch let refusal as GoogleAPIError {
                return refusal
            } catch {
                return nil
            }
        }
        let background = GmailBooking(work: .background(.cacheFill), calls: [.messagesGet: 1], direction: .download)
        let read = GmailBooking(.messagesGet, work: .interactive)
        let check = GmailBooking(.historyList, work: .checks)
        await budget.record(down: 9_000, up: 0, work: .background(.cacheFill), isImport: false)
        var refusal = await goes(background)
        XCTAssertEqual(refusal?.kind, .downloadLimit)
        XCTAssertEqual(refusal?.reason, "localBudget")
        XCTAssertEqual(refusal?.delivery, .notSent)
        refusal = await goes(read)
        XCTAssertNil(refusal, "work the owner asks for goes on past the background budget")
        await budget.record(down: 7_000, up: 0, work: .interactive, isImport: false)
        refusal = await goes(read)
        XCTAssertEqual(refusal?.kind, .downloadLimit)
        refusal = await goes(check)
        XCTAssertNil(refusal, "only checks go on past the whole download budget")

        let small = Data(count: 1_000)
        let importing = GmailBooking(.messagesImport, work: .background(.transfer), uploadBytes: small.count)
        refusal = await goes(importing)
        XCTAssertNil(refusal)
        await budget.record(down: 0, up: 2_500, work: .background(.transfer), isImport: true)
        refusal = await goes(importing)
        XCTAssertEqual(refusal?.kind, .uploadLimit, "imports stop first, keeping room for sending")
        refusal = await goes(GmailBooking(.messagesSend, work: .interactive, uploadBytes: small.count))
        XCTAssertNil(refusal)
        await budget.record(down: 0, up: 2_000, work: .interactive, isImport: false)
        refusal = await goes(GmailBooking(.draftsUpdate, work: .interactive, uploadBytes: small.count))
        XCTAssertNil(refusal, "sends and drafts are never held by FalconMail's own upload budget")

        // A day later everything has room again.
        clock.advance(25 * 3_600)
        refusal = await goes(background)
        XCTAssertNil(refusal)
        refusal = await goes(importing)
        XCTAssertNil(refusal)
    }

    func testTheAPIsBytesAreKeptApartAndTheFileStaysReadable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("falcon-g1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = VirtualClock()
        let layout = FileLayout(root: root)
        let imap = UUID()
        let google = UUID()
        let meter = TrafficMeter(layout: layout, now: { clock.now })
        meter.record(down: 5_000, up: 100, for: imap)
        meter.persist()
        let imapOnly = try String(contentsOf: root.appendingPathComponent("traffic.json"), encoding: .utf8)
        XCTAssertFalse(imapOnly.contains("api"), "an account with no API traffic is written as before")

        meter.recordAPI(down: 7_000, up: 300, background: 2_000, imported: 100, for: google)
        XCTAssertEqual(meter.usedAPI(.download, by: google), 7_000)
        XCTAssertEqual(meter.usedAPI(.background, by: google), 2_000)
        XCTAssertEqual(meter.usedAPI(.imports, by: google), 100)
        XCTAssertEqual(meter.usedAPI(.upload, by: google), 300)
        XCTAssertEqual(meter.used(.download, by: google), 0)
        XCTAssertEqual(meter.usedAPI(.download, by: imap), 0)
        meter.persist()

        let reloaded = TrafficMeter(layout: layout, now: { clock.now })
        XCTAssertEqual(reloaded.usedAPI(.download, by: google), 7_000)
        XCTAssertEqual(reloaded.used(.download, by: imap), 5_000)

        // The previous release's shape of an hour, without the new fields, still reads.
        struct OldHour: Codable { var hour: Int; var down: Int; var up: Int; var background: Int }
        let data = try Data(contentsOf: root.appendingPathComponent("traffic.json"))
        let old = try JSONDecoder().decode([String: [OldHour]].self, from: data)
        XCTAssertEqual(old[google.uuidString]?.first?.down, 0)
        XCTAssertEqual(old[imap.uuidString]?.first?.down, 5_000)
    }
}

/// Names in the order they were appended, from any task.
final class OrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []

    func append(_ name: String) { lock.withLock { names.append(name) } }
    var all: [String] { lock.withLock { names } }
}
