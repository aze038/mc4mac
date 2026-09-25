import Foundation

// Fetching rows' text as the owner scrolls. The table asks for what is on screen once the scroll
// is slow enough to read, and for one screen ahead once it settles; each account's source then
// sends those as landings of at most 25 rows, drops what has scrolled away before it was sent,
// shares what is already on its way, and says at once when rows must wait for Gmail's budget.

// MARK: - What the table asks for

/// What to ask for after a scroll.
public struct ScrollPlan: Equatable, Sendable {
    /// Rows on screen now, to fetch at once.
    public var visible: Range<Int>?
    /// One screen ahead in the scroll's direction, fetched in the background.
    public var ahead: Range<Int>?
    /// When to call `settled(at:)`, if nothing scrolls before then.
    public var settleAt: TimeInterval?

    public init(visible: Range<Int>? = nil, ahead: Range<Int>? = nil, settleAt: TimeInterval? = nil) {
        self.visible = visible
        self.ahead = ahead
        self.settleAt = settleAt
    }
}

/// Decides from the scroll alone when rows are worth fetching. During a fling nothing is: the
/// rows fly past before their text could arrive, and fetching them would spend the budget the
/// rows where the scroll stops need.
public struct ScrollFetchPlanner: Sendable {
    /// How long the scroll must rest before it counts as settled.
    public static let settleDelay: TimeInterval = 0.1
    /// Faster than this, in screens a second, is a fling.
    public static let flingSpeed: Double = 3

    private var visible: Range<Int>?
    private var lastTime: TimeInterval?
    private var direction = 1
    /// Screens a second at the last scroll.
    public private(set) var speed: Double = 0
    public private(set) var rowCount = 0
    /// What was last asked for as visible, so the same rows are not asked for twice in a row.
    private var requested: Range<Int>?

    public init() {}

    public var isFlinging: Bool { speed >= ScrollFetchPlanner.flingSpeed }

    /// The list has `rowCount` rows now.
    public mutating func reset(rowCount: Int) {
        self.rowCount = rowCount
        requested = nil
    }

    /// The rows on screen are now `range`.
    public mutating func scrolled(to range: Range<Int>, at time: TimeInterval) -> ScrollPlan {
        let rows = clamp(range)
        defer {
            visible = rows
            lastTime = time
        }
        guard let previous = visible, let last = lastTime else {
            speed = 0
            return ask(rows, settleAt: time + ScrollFetchPlanner.settleDelay)
        }
        let moved = rows.lowerBound - previous.lowerBound
        if moved != 0 { direction = moved > 0 ? 1 : -1 }
        let elapsed = max(time - last, 0.001)
        let screen = Double(max(rows.count, 1))
        speed = Double(abs(moved)) / screen / elapsed
        if isFlinging { return ScrollPlan(settleAt: time + ScrollFetchPlanner.settleDelay) }
        return ask(rows, settleAt: time + ScrollFetchPlanner.settleDelay)
    }

    /// Nothing has scrolled for `settleDelay`: what is on screen now, and one screen ahead.
    public mutating func settled(at time: TimeInterval) -> ScrollPlan {
        guard let rows = visible else { return ScrollPlan() }
        if let last = lastTime, time - last < ScrollFetchPlanner.settleDelay - 0.000_1 {
            return ScrollPlan(settleAt: last + ScrollFetchPlanner.settleDelay)
        }
        speed = 0
        var plan = ask(rows, settleAt: nil)
        let screen = max(rows.count, 1)
        let ahead = direction > 0 ? rows.upperBound..<(rows.upperBound + screen) : (rows.lowerBound - screen)..<rows.lowerBound
        let clamped = clamp(ahead)
        plan.ahead = clamped.isEmpty ? nil : clamped
        return plan
    }

    private mutating func ask(_ rows: Range<Int>, settleAt: TimeInterval?) -> ScrollPlan {
        guard !rows.isEmpty, rows != requested else { return ScrollPlan(settleAt: settleAt) }
        requested = rows
        return ScrollPlan(visible: rows, settleAt: settleAt)
    }

    private func clamp(_ range: Range<Int>) -> Range<Int> {
        let low = min(max(range.lowerBound, 0), rowCount)
        let high = min(max(range.upperBound, low), rowCount)
        return low..<high
    }
}

// MARK: - The budget

/// How long spending units now would wait for the account's Gmail budget. The engine's own
/// limiter decides in the end; this lets the list say at once that rows are waiting, and keep a
/// landing back long enough that scrolling away can still drop it.
public protocol RowFetchBudget: AnyObject {
    /// Seconds until `units` could be spent, for work of `priority`; 0 when they can be now.
    func wait(for units: Int, priority: RowPriority, at time: TimeInterval) -> TimeInterval
    func spend(_ units: Int, at time: TimeInterval)
    /// Gmail asked FalconMail to wait until `time`.
    func pause(until time: TimeInterval)
}

/// A copy of the account's token bucket: it holds 1,000 units and refills 2,000 a minute, so no
/// minute passes 3,000. Rows on screen may spend it to nothing; background work never takes it
/// below 500, so a click always finds units.
public final class TokenBucketEstimate: RowFetchBudget {
    public let capacity: Double
    public let refillPerSecond: Double
    public let backgroundFloor: Double
    private var level: Double
    private var updated: TimeInterval?
    private var pausedUntil: TimeInterval = 0

    public init(capacity: Double = 1_000, refillPerMinute: Double = 2_000, backgroundFloor: Double = 500) {
        self.capacity = capacity
        refillPerSecond = refillPerMinute / 60
        self.backgroundFloor = backgroundFloor
        level = capacity
    }

    public func level(at time: TimeInterval) -> Double {
        refill(to: time)
        return level
    }

    public func wait(for units: Int, priority: RowPriority, at time: TimeInterval) -> TimeInterval {
        refill(to: time)
        let floor = priority == .visible ? 0 : backgroundFloor
        let wanted = min(Double(units) + floor, capacity)
        let pause = max(0, pausedUntil - time)
        guard level < wanted else { return pause }
        return max(pause, (wanted - level) / refillPerSecond)
    }

    public func spend(_ units: Int, at time: TimeInterval) {
        refill(to: time)
        level -= Double(units)
    }

    public func pause(until time: TimeInterval) {
        pausedUntil = max(pausedUntil, time)
    }

    /// What the account's real bucket holds at `time`, so the copy follows what other work spent.
    public func setLevel(_ units: Double, at time: TimeInterval) {
        refill(to: time)
        level = min(capacity, units)
    }

    private func refill(to time: TimeInterval) {
        if let updated, time > updated { level = min(capacity, level + (time - updated) * refillPerSecond) }
        if updated == nil || time > updated! { updated = time }
    }
}

// MARK: - Landings

/// One HTTP batch of rows.
public struct RowLanding: Equatable, Sendable {
    public var keys: [RowKey]
    public var priority: RowPriority
    public var units: Int

    public init(keys: [RowKey], priority: RowPriority, units: Int) {
        self.keys = keys
        self.priority = priority
        self.units = units
    }
}

/// Turns requests for rows into landings. Rows on screen go first, at most 25 to a landing; the
/// screen ahead follows in landings of 10, as all background work does, and then rows wanted
/// for a sort by sender, recipient or subject. A request that has not been sent is dropped when
/// its rows leave the screen, and a row already on its way is never asked for again.
public final class RowFetchScheduler {
    public static let visibleBatch = 25
    public static let backgroundBatch = 10

    private let budget: RowFetchBudget
    private var visible: [RowKey] = []
    private var ahead: [RowKey] = []
    /// Rows a sort wants, which scrolling does not replace.
    private var background: [RowKey] = []
    private var cost: [RowKey: Int] = [:]
    private var inFlight: Set<RowKey> = []
    public private(set) var landingsSent = 0

    public init(budget: RowFetchBudget = TokenBucketEstimate()) {
        self.budget = budget
    }

    public var hasPending: Bool { !visible.isEmpty || !ahead.isEmpty || !background.isEmpty }
    public var pendingBackground: [RowKey] { background }
    public var pendingVisible: [RowKey] { visible }
    public var pendingAhead: [RowKey] { ahead }
    public func isInFlight(_ key: RowKey) -> Bool { inFlight.contains(key) }

    /// Rows on screen now, or ahead of it, with what each costs to fetch. Rows of the same kind
    /// asked for before and not sent yet are dropped unless asked for again.
    public func request(_ keys: [RowKey], priority: RowPriority, cost price: (RowKey) -> Int) {
        var seen = Set<RowKey>()
        let wanted = keys.filter { !inFlight.contains($0) && seen.insert($0).inserted }
        for key in wanted { cost[key] = price(key) }
        switch priority {
        case .visible:
            visible = wanted
            // What is on screen now is not also ahead of it.
            let now = Set(wanted)
            ahead.removeAll { now.contains($0) }
        case .ahead:
            let shown = Set(visible)
            ahead = wanted.filter { !shown.contains($0) }
        }
        background.removeAll { cost[$0] == nil || Set(visible).contains($0) }
        let live = Set(visible).union(ahead).union(background)
        cost = cost.filter { live.contains($0.key) }
    }

    /// Rows wanted in the background whatever the scroll does, such as those a sort by sender
    /// would group: sent after the screen ahead, ten at a time.
    public func requestInBackground(_ keys: [RowKey], cost price: (RowKey) -> Int) {
        let queued = Set(background).union(visible).union(ahead).union(inFlight)
        for key in keys where !queued.contains(key) {
            cost[key] = price(key)
            background.append(key)
        }
    }

    /// Rows on screen are waiting for Gmail's budget, which the list's footer says at once.
    public func isWaitingOnBudget(at time: TimeInterval) -> Bool {
        guard !visible.isEmpty else { return false }
        return budget.wait(for: units(of: Array(visible.prefix(RowFetchScheduler.visibleBatch))), priority: .visible, at: time) > 0
    }

    /// The landing to send now, if the budget has room for it; its rows are then in flight.
    public func next(at time: TimeInterval) -> RowLanding? {
        let (priority, keys) = nextKeys()
        guard !keys.isEmpty else { return nil }
        let units = units(of: keys)
        guard budget.wait(for: units, priority: priority, at: time) <= 0 else { return nil }
        budget.spend(units, at: time)
        let sent = Set(keys)
        visible.removeAll { sent.contains($0) }
        ahead.removeAll { sent.contains($0) }
        background.removeAll { sent.contains($0) }
        inFlight.formUnion(sent)
        for key in keys { cost[key] = nil }
        landingsSent += 1
        return RowLanding(keys: keys, priority: priority, units: units)
    }

    /// Seconds until the next landing could go; nil when nothing waits.
    public func delay(at time: TimeInterval) -> TimeInterval? {
        let (priority, keys) = nextKeys()
        guard !keys.isEmpty else { return nil }
        return budget.wait(for: units(of: keys), priority: priority, at: time)
    }

    private func nextKeys() -> (RowPriority, [RowKey]) {
        if !visible.isEmpty { return (.visible, Array(visible.prefix(RowFetchScheduler.visibleBatch))) }
        if !ahead.isEmpty { return (.ahead, Array(ahead.prefix(RowFetchScheduler.backgroundBatch))) }
        return (.ahead, Array(background.prefix(RowFetchScheduler.backgroundBatch)))
    }

    /// A landing's rows arrived, or failed; either way they are no longer on their way.
    public func finished(_ keys: [RowKey]) {
        inFlight.subtract(keys)
    }

    /// Gmail asked FalconMail to wait.
    public func pause(until time: TimeInterval) {
        budget.pause(until: time)
    }

    private func units(of keys: [RowKey]) -> Int {
        keys.reduce(0) { $0 + (cost[$1] ?? 0) }
    }
}
