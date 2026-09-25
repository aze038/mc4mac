import Foundation

/// The shape of one account's Gmail budget on this Mac. Google gives each user 6,000 units a
/// minute, shared by every copy of FalconMail on the account and by olm2cloud, so FalconMail
/// takes at most half of it for an account on one Mac, and less while another app imports.
public struct GmailBudgetPolicy: Sendable, Equatable {
    /// The bucket holds at most this: a click always finds units, and background work cannot
    /// spend a whole minute's worth in its first seconds.
    public var capacity: Int
    /// Refilled this much a minute, so no 60 seconds ever book more than capacity + refill:
    /// 3,000, v1.10.0's figure and half of Google's per-user 6,000.
    public var refillPerMinute: Int
    /// While another app is importing into the account: at most 500 + 1,500 in any minute.
    public var floodCapacity: Int
    public var floodRefillPerMinute: Int
    /// Background work never takes the bucket below this, so a click always finds units.
    public var backgroundReserve: Int
    public var floodBackgroundReserve: Int
    /// Background work's most in any 60 seconds while the owner has done something in the last
    /// `activeWindow` seconds, and while another app imports.
    public var backgroundPerMinuteWhileActive: Int
    public var backgroundPerMinuteInFlood: Int
    public var activeWindow: TimeInterval
    /// Actions on a whole view, which give way to everything the owner is waiting for.
    public var bulkPerMinute: Int
    /// A rate refusal halves the refill, never below this share of it, and it then recovers by
    /// `recoveryPerMinute` of it each minute.
    public var lowestRefillShare: Double
    public var recoveryPerMinute: Double
    /// HTTP requests in flight, and how many of them bulk and background work may hold, so two
    /// are always free for a click.
    public var maxRequests: Int
    public var maxBackgroundRequests: Int
    /// Batch parts in flight: one screen of rows for checks and clicks, and background work's own.
    public var foregroundParts: Int
    public var backgroundParts: Int
    /// After a "too many concurrent requests" refusal both part limits halve for this long.
    public var partsCut: TimeInterval
    /// How long a daily allowance refusal pauses for when Google gives no retry time.
    public var allowancePause: TimeInterval
    /// How long Gmail API being off for the project holds every call before asking again.
    public var disabledHold: TimeInterval

    public init(capacity: Int = 1_000, refillPerMinute: Int = 2_000, floodCapacity: Int = 500, floodRefillPerMinute: Int = 1_500,
                backgroundReserve: Int = 500, floodBackgroundReserve: Int = 250, backgroundPerMinuteWhileActive: Int = 1_000,
                backgroundPerMinuteInFlood: Int = 500, activeWindow: TimeInterval = 10, bulkPerMinute: Int = 1_500,
                lowestRefillShare: Double = 0.25, recoveryPerMinute: Double = 0.1, maxRequests: Int = 4,
                maxBackgroundRequests: Int = 2, foregroundParts: Int = 25, backgroundParts: Int = 10,
                partsCut: TimeInterval = 600, allowancePause: TimeInterval = 3_600, disabledHold: TimeInterval = 600) {
        self.capacity = capacity
        self.refillPerMinute = refillPerMinute
        self.floodCapacity = floodCapacity
        self.floodRefillPerMinute = floodRefillPerMinute
        self.backgroundReserve = backgroundReserve
        self.floodBackgroundReserve = floodBackgroundReserve
        self.backgroundPerMinuteWhileActive = backgroundPerMinuteWhileActive
        self.backgroundPerMinuteInFlood = backgroundPerMinuteInFlood
        self.activeWindow = activeWindow
        self.bulkPerMinute = bulkPerMinute
        self.lowestRefillShare = lowestRefillShare
        self.recoveryPerMinute = recoveryPerMinute
        self.maxRequests = maxRequests
        self.maxBackgroundRequests = maxBackgroundRequests
        self.foregroundParts = foregroundParts
        self.backgroundParts = backgroundParts
        self.partsCut = partsCut
        self.allowancePause = allowancePause
        self.disabledHold = disabledHold
    }

    public static let standard = GmailBudgetPolicy()
}

extension WorkClass {
    /// Place in the queue: lower goes first. Checks and new mail lead, so no amount of scrolling
    /// can delay new mail; background work is ranked within itself.
    public var rank: Int {
        switch self {
        case .checks: return 0
        case .interactive: return 1
        case .bulk: return 2
        case .background(let work): return 3 + work.rawValue
        }
    }

    /// Bulk and background work share the requests and batch parts that clicks never need.
    var isDeferrable: Bool {
        switch self {
        case .bulk, .background: return true
        case .checks, .interactive: return false
        }
    }
}

/// What one HTTP request asks of the budget before it is sent.
public struct GmailBooking: Sendable, Equatable {
    public var work: WorkClass
    /// Every call it carries, with how many of each: a batch counts each part, as Google does.
    public var calls: [GmailMethod: Int]
    public var direction: GmailMethod.Direction
    /// A message send, which a sending-limit pause holds back.
    public var isSend: Bool
    /// An import, which stops first when uploads near their budget.
    public var isImport: Bool
    /// Bytes it will upload, known before it goes.
    public var uploadBytes: Int

    public init(work: WorkClass, calls: [GmailMethod: Int], direction: GmailMethod.Direction, isSend: Bool = false,
                isImport: Bool = false, uploadBytes: Int = 0) {
        self.work = work
        self.calls = calls
        self.direction = direction
        self.isSend = isSend
        self.isImport = isImport
        self.uploadBytes = uploadBytes
    }

    public init(_ method: GmailMethod, work: WorkClass, uploadBytes: Int = 0) {
        self.init(work: work, calls: [method: 1], direction: method.direction, isSend: method == .messagesSend,
                  isImport: method == .messagesImport, uploadBytes: uploadBytes)
    }

    public var units: Int { calls.reduce(0) { $0 + $1.key.units * $1.value } }
    public var parts: Int { max(1, calls.values.reduce(0, +)) }
}

/// A request let through by the budget. It holds its request and batch parts until it is
/// finished; its units are spent, whatever Gmail answers.
public struct GmailTicket: Sendable {
    public let id: UInt64
    public let booking: GmailBooking
    /// When the units were booked, which tells refusals from one burst apart from later ones.
    public let admittedAt: Date
    let holdsGate: Bool
}

/// Requests and batch parts in flight for one account.
public struct GmailInFlight: Sendable, Equatable {
    public var requests = 0
    public var deferrableRequests = 0
    public var foregroundParts = 0
    public var backgroundParts = 0

    public var parts: Int { foregroundParts + backgroundParts }
}

/// One booking the budget let through, for tests and the daily report.
public struct GmailGrant: Sendable, Equatable {
    public var at: Date
    public var units: Int
    public var work: WorkClass
    public var parts: Int
}

/// At most this many background requests in flight across every account on the Mac, so five
/// accounts set up at once share the network rather than each taking its own share of it.
public final class GmailBackgroundGate: @unchecked Sendable {
    public static let shared = GmailBackgroundGate(limit: 8)

    public let limit: Int
    private let lock = NSLock()
    private var held = 0
    private var waiting: [ObjectIdentifier: WeakBudget] = [:]

    public init(limit: Int) {
        self.limit = limit
    }

    public var inFlight: Int { lock.withLock { held } }

    /// Takes a place when one is free; otherwise remembers `budget`, which is woken when one is.
    func tryEnter(_ budget: GmailBudget) -> Bool {
        lock.withLock {
            if held < limit {
                held += 1
                return true
            }
            waiting[ObjectIdentifier(budget)] = WeakBudget(budget)
            return false
        }
    }

    func leave() {
        let woken: [GmailBudget] = lock.withLock {
            held = max(0, held - 1)
            let all = waiting.values.compactMap(\.budget)
            waiting.removeAll()
            return all
        }
        for budget in woken { Task { await budget.wake() } }
    }

    private final class WeakBudget {
        weak var budget: GmailBudget?
        init(_ budget: GmailBudget) { self.budget = budget }
    }
}

/// One account's Gmail API budget on this Mac: a token bucket of units, the classes of work that
/// take from it in order, the requests and batch parts in flight, the pauses Google asks for,
/// and the account's API bytes against their daily budgets.
///
/// Every request is admitted here before it is sent and finished here when its answer is in.
/// Work waits in one queue, checks first and background last, and nothing of a lower class takes
/// units while something above it waits for them.
public actor GmailBudget {
    public nonisolated let accountID: UUID
    public nonisolated let policy: GmailBudgetPolicy
    private nonisolated let meter: TrafficMeter?
    private nonisolated let gate: GmailBackgroundGate?
    private nonisolated let clock: @Sendable () -> Date
    private nonisolated let sleeper: @Sendable (TimeInterval) async throws -> Void
    private nonisolated let jitter: @Sendable () -> Double

    private var level: Double
    private var levelAt: Date
    /// The refill a minute after rate refusals, while it recovers; nil at the full rate.
    private var reducedRefill: Double?
    private var reducedAt = Date.distantPast
    private var flood = false
    private var ownerActiveAt = Date.distantPast
    private var bulkSpent: [(at: Date, units: Int)] = []
    private var backgroundSpent: [(at: Date, units: Int)] = []

    private var flight = GmailInFlight()
    public private(set) var peak = GmailInFlight()
    private var partsCutUntil = Date.distantPast

    private enum Scope: Hashable { case all, downloads, uploads, sends }
    private var pauses: [Scope: GmailPause] = [:]
    /// A daily cap the owner set on the project, or the API off: every call is refused at once.
    private var held: GmailPause?

    private struct Waiter {
        let id: UInt64
        let booking: GmailBooking
        let rank: Int
        let deadline: Date?
        let maxPause: TimeInterval
        let continuation: CheckedContinuation<GmailTicket, Error>
    }

    private var waiters: [Waiter] = []
    private var nextID: UInt64 = 0
    private var timerAt: Date?

    private var units: [GmailMethod: Int] = [:]
    private var calls: [GmailMethod: Int] = [:]
    private var bytesDown = 0
    private var bytesUp = 0
    private var refusals: [String: Int] = [:]
    private var grants: [GmailGrant] = []
    private static let keptGrants = 20_000

    public init(accountID: UUID, policy: GmailBudgetPolicy = .standard, meter: TrafficMeter? = nil,
                gate: GmailBackgroundGate? = .shared,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
                    try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                },
                jitter: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        self.accountID = accountID
        self.policy = policy
        self.meter = meter
        self.gate = gate
        self.clock = now
        self.sleeper = sleep
        self.jitter = jitter
        level = Double(policy.capacity)
        levelAt = now()
    }

    /// The budget's clock, which tests move by hand.
    public nonisolated func now() -> Date { clock() }

    /// Waits on the budget's clock, so a test's clock decides how long a backoff takes.
    public nonisolated func sleep(_ seconds: TimeInterval) async throws {
        try await sleeper(seconds)
    }

    // MARK: Admission

    /// Waits until the request may go: its units are in the bucket for its class, a request and
    /// its batch parts are free, and no pause Google asked for holds it back. Then books it.
    ///
    /// It gives up with a refusal rather than wait longer than `maxWait` in the queue, or than
    /// `maxPause` for a pause Google asked for: the caller can then say so, and try later.
    /// A daily cap, the API being off and FalconMail's own byte budgets refuse at once.
    public func admit(_ booking: GmailBooking, maxWait: TimeInterval = .infinity,
                      maxPause: TimeInterval = .infinity) async throws -> GmailTicket {
        try Task.checkCancellation()
        let start = clock()
        settle(start)
        if let refusal = standingRefusal(for: booking, maxPause: maxPause, at: start) { throw refusal }
        if waiters.isEmpty, maxWait.isFinite, let wait = unitWait(for: booking, at: start), wait > maxWait {
            throw GoogleAPIError(kind: .rateLimited, reason: "localBudget", detail: "waiting for the account's budget",
                                 retryAfter: wait, delivery: .notSent)
        }
        let id = nextID
        nextID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GmailTicket, Error>) in
                let waiter = Waiter(id: id, booking: booking, rank: booking.work.rank,
                                    deadline: maxWait.isFinite ? start.addingTimeInterval(maxWait) : nil,
                                    maxPause: maxPause, continuation: continuation)
                let place = waiters.firstIndex { ($0.rank, $0.id) > (waiter.rank, waiter.id) } ?? waiters.count
                waiters.insert(waiter, at: place)
                pump()
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    /// The request's answer is in, or it failed: its request and parts are free again, and the
    /// bytes it moved are counted.
    public func finish(_ ticket: GmailTicket, down: Int = 0, up: Int = 0) {
        flight.requests -= 1
        if ticket.booking.work.isDeferrable {
            flight.deferrableRequests -= 1
            flight.backgroundParts -= ticket.booking.parts
        } else {
            flight.foregroundParts -= ticket.booking.parts
        }
        if ticket.holdsGate { gate?.leave() }
        record(down: down, up: up, work: ticket.booking.work, isImport: ticket.booking.isImport)
        pump()
    }

    /// Counts bytes moved outside a ticket's answer.
    public func record(down: Int, up: Int, work: WorkClass, isImport: Bool) {
        guard down > 0 || up > 0 else { return }
        bytesDown += max(0, down)
        bytesUp += max(0, up)
        meter?.recordAPI(down: down, up: up, background: work.isBackground ? down : 0, imported: isImport ? up : 0, for: accountID)
    }

    /// Google refused a request booked at `sentAt`. Returns how long to wait before trying it
    /// again, or nil when trying again cannot help until something changes.
    ///
    /// A rate refusal halves the refill and holds every call until its retry time; refusals of
    /// calls sent before the last halving came from the same burst and halve it only once. A
    /// concurrency refusal halves the batch parts in flight instead. The daily allowances pause
    /// only what they are about: downloads, uploads or sends.
    @discardableResult
    public func note(_ refusal: GoogleAPIError, sentAt: Date, attempt: Int) -> TimeInterval? {
        let now = clock()
        settle(now)
        if refusal.httpStatus > 0 {
            refusals["\(refusal.httpStatus) \(refusal.reason ?? refusal.kind.rawValue)", default: 0] += 1
        }
        defer { pump() }
        switch refusal.kind {
        case .rateLimited:
            let wait = max(refusal.retryAfter ?? backoff(attempt), 0)
            if refusal.isConcurrencyLimit {
                partsCutUntil = now.addingTimeInterval(policy.partsCut)
                return max(wait, 1)
            }
            if sentAt > reducedAt {
                reducedRefill = max(lowestRefill, refillPerMinute(at: now) / 2)
                reducedAt = now
            }
            pause(.all, until: now.addingTimeInterval(wait), refusal)
            return wait
        case .quotaExhausted:
            held = GmailPause(until: GoogleAPIError.quotaReset(after: now), refusal: refusal)
            return nil
        case .apiDisabled:
            held = GmailPause(until: now.addingTimeInterval(policy.disabledHold), refusal: refusal)
            return nil
        case .downloadLimit:
            pause(.downloads, until: now.addingTimeInterval(refusal.retryAfter ?? policy.allowancePause), refusal)
            return nil
        case .uploadLimit:
            pause(.uploads, until: now.addingTimeInterval(refusal.retryAfter ?? policy.allowancePause), refusal)
            return nil
        case .sendingLimit:
            pause(.sends, until: now.addingTimeInterval(refusal.retryAfter ?? policy.allowancePause), refusal)
            return nil
        case .temporary:
            return backoff(attempt)
        default:
            return nil
        }
    }

    /// Google's advice for retrying: 2ⁿ seconds and up to one more at random, at most 64, and
    /// never less than a second before the first retry.
    public nonisolated func backoff(_ attempt: Int) -> TimeInterval {
        max(1, min(pow(2, Double(max(0, attempt))) + jitter(), 64))
    }

    // MARK: What the engine tells it

    /// Another app is importing into the account, which shares Google's per-user budget.
    public func setFloodMode(_ on: Bool) {
        settle(clock())
        flood = on
        if on { level = min(level, Double(policy.floodCapacity)) }
        pump()
    }

    public func noteOwnerActivity(at date: Date) {
        ownerActiveAt = max(ownerActiveAt, date)
        pump()
    }

    // MARK: What it says about itself

    /// The latest-ending pause Google asked for that still holds, with its refusal.
    public func pause() -> GmailPause? {
        let now = clock()
        return ([held] + pauses.values.map { Optional($0) }).compactMap { $0 }.filter { $0.until > now }.max { $0.until < $1.until }
    }

    public func usage() -> GmailUsage {
        GmailUsage(units: units, calls: calls, bytesDown: bytesDown, bytesUp: bytesUp)
    }

    /// Google's refusals so far, keyed by status and reason, for the daily report.
    public func refusalCounts() -> [String: Int] { refusals }

    public func inFlight() -> GmailInFlight { flight }

    /// The most recent bookings, oldest first.
    public func recentGrants() -> [GmailGrant] { grants }

    public var isFloodMode: Bool { flood }

    /// Units in the bucket now.
    public func available() -> Int {
        settle(clock())
        return Int(level.rounded(.down))
    }

    /// The largest batch the class may send at once: its share of batch parts, and the units the
    /// bucket can ever give it in one go. A batch planned within these never waits forever.
    public func batchLimits(for work: WorkClass) -> (parts: Int, units: Int) {
        let now = clock()
        let cut = now < partsCutUntil
        let capacity = self.capacity
        if work.isDeferrable {
            let parts = cut ? policy.backgroundParts / 2 : policy.backgroundParts
            let units: Int
            if case .background = work {
                units = capacity - reserve
            } else {
                units = min(capacity, policy.bulkPerMinute)
            }
            return (max(1, parts), max(1, units))
        }
        let parts = cut ? policy.foregroundParts / 2 : policy.foregroundParts
        return (max(1, parts), capacity)
    }

    // MARK: Inside

    func wake() { pump() }

    private var capacity: Int { flood ? policy.floodCapacity : policy.capacity }
    private var reserve: Int { flood ? policy.floodBackgroundReserve : policy.backgroundReserve }
    private var lowestRefill: Double { Double(policy.refillPerMinute) * policy.lowestRefillShare }

    private func refillPerMinute(at now: Date) -> Double {
        let full = Double(flood ? policy.floodRefillPerMinute : policy.refillPerMinute)
        guard let reduced = reducedRefill else { return full }
        let minutes = max(0, now.timeIntervalSince(reducedAt) / 60)
        return min(full, reduced + Double(policy.refillPerMinute) * policy.recoveryPerMinute * minutes)
    }

    /// Brings the bucket, the recovery and the windows up to `now`.
    private func settle(_ now: Date) {
        let elapsed = now.timeIntervalSince(levelAt)
        if elapsed > 0 {
            level = min(Double(capacity), level + refillPerMinute(at: levelAt) / 60 * elapsed)
            levelAt = now
        }
        if reducedRefill != nil, refillPerMinute(at: now) >= Double(policy.refillPerMinute) { reducedRefill = nil }
        bulkSpent.removeAll { now.timeIntervalSince($0.at) >= 60 }
        backgroundSpent.removeAll { now.timeIntervalSince($0.at) >= 60 }
        pauses = pauses.filter { $0.value.until > now }
        if let held, held.until <= now { self.held = nil }
    }

    private func pause(_ scope: Scope, until: Date, _ refusal: GoogleAPIError) {
        if let existing = pauses[scope], existing.until >= until { return }
        pauses[scope] = GmailPause(until: until, refusal: refusal)
    }

    private func pauseEnd(for booking: GmailBooking) -> GmailPause? {
        var found: [GmailPause] = []
        if let p = pauses[.all] { found.append(p) }
        if booking.direction == .download, booking.work != .checks, let p = pauses[.downloads] { found.append(p) }
        if booking.direction == .upload, let p = pauses[.uploads] { found.append(p) }
        if booking.isSend, let p = pauses[.sends] { found.append(p) }
        return found.max { $0.until < $1.until }
    }

    /// Refusals that no amount of waiting in the queue can change: a hold, a pause longer than
    /// the caller will wait, and FalconMail's own byte budgets, which free up only by the hour.
    private func standingRefusal(for booking: GmailBooking, maxPause: TimeInterval, at now: Date) -> GoogleAPIError? {
        if let held, held.until > now {
            var refusal = held.refusal
            refusal.retryAfter = held.until.timeIntervalSince(now)
            refusal.delivery = .notSent
            return refusal
        }
        if let pause = pauseEnd(for: booking), pause.until.timeIntervalSince(now) > maxPause {
            var refusal = pause.refusal
            refusal.retryAfter = pause.until.timeIntervalSince(now)
            refusal.delivery = .notSent
            return refusal
        }
        guard let meter else { return nil }
        func own(_ kind: GoogleAPIError.Kind, _ budget: APITrafficBudget, adding bytes: Int = 0) -> GoogleAPIError {
            GoogleAPIError(kind: kind, reason: "localBudget", detail: "FalconMail's own daily budget",
                           retryAfter: meter.whenAllowsAPI(budget, adding: bytes, for: accountID).timeIntervalSince(now),
                           delivery: .notSent)
        }
        if booking.direction == .download, booking.work != .checks, !meter.allowsAPI(.download, for: accountID) {
            return own(.downloadLimit, .download)
        }
        if booking.direction == .download, booking.work.isBackground, !meter.allowsAPI(.background, for: accountID) {
            return own(.downloadLimit, .background)
        }
        if booking.isImport {
            if !meter.allowsAPI(.imports, adding: booking.uploadBytes, for: accountID) {
                return own(.uploadLimit, .imports, adding: booking.uploadBytes)
            }
            if !meter.allowsAPI(.upload, adding: booking.uploadBytes, for: accountID) {
                return own(.uploadLimit, .upload, adding: booking.uploadBytes)
            }
        }
        return nil
    }

    /// Units a booking needs in the bucket before it may take them.
    private func need(_ booking: GmailBooking) -> Double {
        var units = booking.units
        if booking.work.isBackground { units += reserve }
        return Double(min(units, capacity))
    }

    /// How long until the bucket holds what the booking needs, if nothing else takes from it.
    private func unitWait(for booking: GmailBooking, at now: Date) -> TimeInterval? {
        let deficit = need(booking) - level
        guard deficit > 0 else { return nil }
        return deficit / max(refillPerMinute(at: now) / 60, 0.001)
    }

    /// When a class's own cap in any 60 seconds leaves room for `units`, or nil when it does now.
    private func classCapWait(for booking: GmailBooking, at now: Date) -> Date? {
        let cap: Int
        let spent: [(at: Date, units: Int)]
        switch booking.work {
        case .bulk:
            cap = policy.bulkPerMinute
            spent = bulkSpent
        case .background:
            let active = now.timeIntervalSince(ownerActiveAt) < policy.activeWindow
            if flood {
                cap = policy.backgroundPerMinuteInFlood
            } else if active {
                cap = policy.backgroundPerMinuteWhileActive
            } else {
                return nil
            }
            spent = backgroundSpent
        case .checks, .interactive:
            return nil
        }
        let units = min(booking.units, cap)
        var total = spent.reduce(0) { $0 + $1.units }
        guard total + units > cap else { return nil }
        var when: Date?
        for entry in spent {
            total -= entry.units
            if total + units <= cap {
                when = entry.at.addingTimeInterval(60)
                break
            }
        }
        // While only the owner's activity limits it, background may speed up once he stops.
        if case .background = booking.work, !flood {
            let quiet = ownerActiveAt.addingTimeInterval(policy.activeWindow)
            return min(when ?? quiet, quiet)
        }
        return when ?? now.addingTimeInterval(60)
    }

    private enum Verdict {
        case grant
        case refuse(GoogleAPIError)
        /// Waits for time to pass until the date, or for something to be finished when nil.
        /// `blocksAll` stops every later waiter from taking units; otherwise only those of lower
        /// classes are stopped.
        case wait(until: Date?, blocksAll: Bool, blocksLower: Bool)
    }

    private func evaluate(_ waiter: Waiter, unitsBlocked: Bool, at now: Date) -> Verdict {
        let booking = waiter.booking
        if let refusal = standingRefusal(for: booking, maxPause: waiter.maxPause, at: now) { return .refuse(refusal) }
        if let pause = pauseEnd(for: booking) { return .wait(until: pause.until, blocksAll: false, blocksLower: false) }
        if flight.requests >= policy.maxRequests
            || (booking.work.isDeferrable && flight.deferrableRequests >= policy.maxBackgroundRequests) {
            return .wait(until: nil, blocksAll: false, blocksLower: true)
        }
        let limits = batchLimits(for: booking.work)
        let pool = booking.work.isDeferrable ? flight.backgroundParts : flight.foregroundParts
        // A batch larger than its whole share still goes once the share is empty, or it never would.
        if pool > 0, pool + booking.parts > limits.parts {
            return .wait(until: nil, blocksAll: false, blocksLower: true)
        }
        if unitsBlocked { return .wait(until: nil, blocksAll: false, blocksLower: false) }
        if let until = classCapWait(for: booking, at: now) { return .wait(until: until, blocksAll: false, blocksLower: true) }
        if let wait = unitWait(for: booking, at: now) {
            return .wait(until: now.addingTimeInterval(wait), blocksAll: true, blocksLower: true)
        }
        return .grant
    }

    /// Lets through every waiter that may go now, in order, and sets a timer for the next moment
    /// something could change by time alone.
    private func pump() {
        let now = clock()
        settle(now)
        var blockAll = false
        var blockBelow: Int?
        var wake: Date?
        func soonest(_ date: Date?) {
            guard let date else { return }
            wake = wake.map { min($0, date) } ?? date
        }
        var i = 0
        while i < waiters.count {
            let waiter = waiters[i]
            let unitsBlocked = blockAll || (blockBelow.map { waiter.rank > $0 } ?? false)
            switch evaluate(waiter, unitsBlocked: unitsBlocked, at: now) {
            case .grant:
                var holdsGate = false
                if case .background = waiter.booking.work, let gate {
                    guard gate.tryEnter(self) else {
                        blockBelow = min(blockBelow ?? waiter.rank, waiter.rank)
                        i += 1
                        continue
                    }
                    holdsGate = true
                }
                waiters.remove(at: i)
                waiter.continuation.resume(returning: take(waiter.booking, holdsGate: holdsGate, at: now))
                continue
            case .refuse(let refusal):
                waiters.remove(at: i)
                waiter.continuation.resume(throwing: refusal)
                continue
            case .wait(let until, let blocksAll, let blocksLower):
                // Past its deadline, a waiter that still cannot go gives up. No timer is set for
                // the deadline alone: it is looked at whenever the budget is woken for something
                // else, which a waiter held up by the bucket always is.
                if let deadline = waiter.deadline, now >= deadline {
                    waiters.remove(at: i)
                    waiter.continuation.resume(throwing: GoogleAPIError(
                        kind: .rateLimited, reason: "localBudget", detail: "waited too long for the account's budget",
                        retryAfter: unitWait(for: waiter.booking, at: now) ?? 1, delivery: .notSent))
                    continue
                }
                if blocksAll { blockAll = true }
                if blocksLower { blockBelow = min(blockBelow ?? waiter.rank, waiter.rank) }
                soonest(until)
                i += 1
            }
        }
        if let wake { schedule(wake) }
    }

    private func take(_ booking: GmailBooking, holdsGate: Bool, at now: Date) -> GmailTicket {
        let units = booking.units
        level -= Double(units)
        flight.requests += 1
        if booking.work.isDeferrable {
            flight.deferrableRequests += 1
            flight.backgroundParts += booking.parts
        } else {
            flight.foregroundParts += booking.parts
        }
        peak.requests = max(peak.requests, flight.requests)
        peak.deferrableRequests = max(peak.deferrableRequests, flight.deferrableRequests)
        peak.foregroundParts = max(peak.foregroundParts, flight.foregroundParts)
        peak.backgroundParts = max(peak.backgroundParts, flight.backgroundParts)
        switch booking.work {
        case .bulk: bulkSpent.append((now, units))
        case .background: backgroundSpent.append((now, units))
        case .checks, .interactive: break
        }
        for (method, count) in booking.calls {
            self.units[method, default: 0] += method.units * count
            calls[method, default: 0] += count
        }
        grants.append(GmailGrant(at: now, units: units, work: booking.work, parts: booking.parts))
        if grants.count > GmailBudget.keptGrants { grants.removeFirst(grants.count - GmailBudget.keptGrants / 2) }
        let ticket = GmailTicket(id: nextID, booking: booking, admittedAt: now, holdsGate: holdsGate)
        nextID += 1
        return ticket
    }

    private func cancel(_ id: UInt64) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: i)
        waiter.continuation.resume(throwing: CancellationError())
        pump()
    }

    /// One timer at a time, for the earliest moment time alone lets something through. A later
    /// one already set is left to fire harmlessly.
    private func schedule(_ date: Date) {
        let now = clock()
        // Nothing that is due now can change by waiting for it, so a timer is always for later.
        let date = max(date, now.addingTimeInterval(0.001))
        if let timerAt, timerAt <= date, timerAt > now { return }
        timerAt = date
        let delay = date.timeIntervalSince(now)
        Task { [weak self] in
            guard let self else { return }
            try? await self.sleep(delay)
            await self.timerFired(date)
        }
    }

    private func timerFired(_ date: Date) {
        if timerAt == date { timerAt = nil }
        pump()
    }
}
