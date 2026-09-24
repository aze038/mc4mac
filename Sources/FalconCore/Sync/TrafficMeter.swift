import Foundation

/// Where a connection reports the bytes it moves, so that everything FalconMail asks of a mail
/// server counts against that account's allowance: headers, flags, bodies, uploads, and the
/// commands and replies around them.
public struct TrafficTap: Sendable {
    public var received: @Sendable (Int) -> Void
    public var sent: @Sendable (Int) -> Void

    public init(received: @escaping @Sendable (Int) -> Void, sent: @escaping @Sendable (Int) -> Void) {
        self.received = received
        self.sent = sent
    }

    public static let none = TrafficTap(received: { _ in }, sent: { _ in })
}

/// What a transfer is measured against, per account over the last 24 hours.
public enum TrafficBudget: Sendable, CaseIterable {
    /// Downloads nobody is waiting for: copies kept for offline reading, and archive jobs.
    case background
    /// Everything downloaded. Past it nothing more is asked of the server until older hours
    /// leave the window.
    case download
    /// Messages uploaded: drafts, imports and copies of sent mail.
    case upload
}

public struct TrafficLimits: Sendable, Equatable {
    public var background: Int
    public var download: Int
    public var upload: Int

    public init(background: Int, download: Int, upload: Int) {
        self.background = background
        self.download = download
        self.upload = upload
    }

    /// Google allows 2,500 MB of IMAP download and about 500 MB of upload per account a day,
    /// and suspends an account that goes past them; these stay well clear of both.
    public static let standard = TrafficLimits(background: 300 * 1024 * 1024, download: 1_800 * 1024 * 1024,
                                               upload: 400 * 1024 * 1024)

    func limit(_ budget: TrafficBudget) -> Int {
        switch budget {
        case .background: return background
        case .download: return download
        case .upload: return upload
        }
    }
}

/// One hour of an account's traffic.
struct TrafficHour: Codable, Equatable {
    /// Hours since 1970, UTC.
    var hour: Int
    var down: Int
    var up: Int
    var background: Int

    func bytes(_ budget: TrafficBudget) -> Int {
        switch budget {
        case .background: return background
        case .download: return down
        case .upload: return up
        }
    }
}

/// One account's entry in bandwidth.json. `day` and `bytes`, the download of that UTC day, are
/// all that earlier builds read and write, so a downgrade still finds a sensible count; `hours`
/// is the rolling window, which they ignore.
struct TrafficRecord: Codable {
    var day: String
    var bytes: Int
    var hours: [TrafficHour]?
}

/// Counts every IMAP byte each account moves, down and up, over a rolling 24 hours in hourly
/// buckets. A count that started again at midnight would let a full allowance through just
/// before it and another just after, which a provider counting any 24 hours sees as double.
/// Thread-safe, so a connection can count as bytes arrive without waiting on anything.
public final class TrafficMeter: @unchecked Sendable {
    public let limits: TrafficLimits
    private let url: URL
    private let writable: Bool
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    /// Keyed by account id as stored, oldest hour first.
    private var hours: [String: [TrafficHour]] = [:]
    private var dirty = false

    public init(layout: FileLayout = FileLayout(), limits: TrafficLimits = .standard,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.limits = limits
        self.now = now
        url = layout.root.appendingPathComponent("bandwidth.json")
        let stored = AtomicFile.loadJSON([String: TrafficRecord].self, from: url, what: "the download count")
        writable = stored.canSave
        let current = TrafficMeter.hourIndex(now())
        for (key, record) in stored.value ?? [:] {
            hours[key] = record.hours ?? TrafficMeter.seed(record, currentHour: current)
        }
    }

    public static let shared = TrafficMeter()

    /// A count written by an earlier build, which knew only today's total, taken as downloaded
    /// at the start of that UTC day so that it leaves the window no later than it should.
    private static func seed(_ record: TrafficRecord, currentHour: Int) -> [TrafficHour] {
        let dayStart = currentHour - currentHour % 24
        guard record.bytes > 0, record.day == dayName(hour: currentHour) else { return [] }
        return [TrafficHour(hour: dayStart, down: record.bytes, up: 0, background: 0)]
    }

    static func hourIndex(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 3600).rounded(.down))
    }

    private static func dayName(hour: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(hour) * 3600))
    }

    /// Counts the connection's bytes against `account`, and its downloads against the
    /// background allowance too when it only ever does background work.
    public func tap(for account: UUID, background: Bool = false) -> TrafficTap {
        TrafficTap(received: { [self] bytes in record(down: bytes, background: background ? bytes : 0, for: account) },
                   sent: { [self] bytes in record(up: bytes, for: account) })
    }

    /// Adds to the account's counts. Bytes a connection already counted as downloaded are
    /// marked as background with `background` alone.
    public func record(down: Int = 0, up: Int = 0, background: Int = 0, for account: UUID) {
        guard down > 0 || up > 0 || background > 0 else { return }
        let current = TrafficMeter.hourIndex(now())
        lock.withLock {
            var list = window(account.uuidString, currentHour: current)
            if let i = list.firstIndex(where: { $0.hour == current }) {
                list[i].down += max(0, down)
                list[i].up += max(0, up)
                list[i].background += max(0, background)
            } else {
                list.append(TrafficHour(hour: current, down: max(0, down), up: max(0, up), background: max(0, background)))
                list.sort { $0.hour < $1.hour }
            }
            hours[account.uuidString] = list
            dirty = true
        }
    }

    /// The account's hours still inside the 24-hour window. Called under the lock. Hours ahead
    /// of the clock, as after it was set back, still count: an allowance errs on the safe side.
    private func window(_ key: String, currentHour: Int) -> [TrafficHour] {
        (hours[key] ?? []).filter { $0.hour > currentHour - 24 }
    }

    /// What the account has moved against `budget` over the last 24 hours.
    public func used(_ budget: TrafficBudget, by account: UUID) -> Int {
        let current = TrafficMeter.hourIndex(now())
        return lock.withLock { window(account.uuidString, currentHour: current).reduce(0) { $0 + $1.bytes(budget) } }
    }

    /// Whether `bytes` more fit inside the budget. Something larger than the whole budget
    /// still goes through when nothing else has been used, or it could never go at all.
    public func allows(_ budget: TrafficBudget, adding bytes: Int = 0, for account: UUID) -> Bool {
        let spent = used(budget, by: account)
        return spent == 0 || spent + max(0, bytes) <= limits.limit(budget)
    }

    /// The first time `allows` holds again, as the oldest hours leave the window.
    public func whenAllows(_ budget: TrafficBudget, adding bytes: Int = 0, for account: UUID) -> Date {
        let moment = now()
        let current = TrafficMeter.hourIndex(moment)
        let list = lock.withLock { window(account.uuidString, currentHour: current) }
        var remaining = list.reduce(0) { $0 + $1.bytes(budget) }
        let limit = limits.limit(budget)
        guard remaining > 0, remaining + max(0, bytes) > limit else { return moment }
        for entry in list {
            remaining -= entry.bytes(budget)
            if remaining == 0 || remaining + max(0, bytes) <= limit {
                return Date(timeIntervalSince1970: TimeInterval(entry.hour + 24) * 3600)
            }
        }
        return moment.addingTimeInterval(24 * 3600)
    }

    /// Saves the counts, so that a relaunch cannot undo the protection. Earlier builds find
    /// today's download in the fields they know.
    public func persist() {
        let current = TrafficMeter.hourIndex(now())
        let dayStart = current - current % 24
        let today = TrafficMeter.dayName(hour: current)
        lock.withLock {
            guard dirty, writable else { return }
            var out: [String: TrafficRecord] = [:]
            for key in hours.keys {
                let list = window(key, currentHour: current)
                guard !list.isEmpty else { continue }
                let bytes = list.filter { $0.hour >= dayStart }.reduce(0) { $0 + $1.down }
                out[key] = TrafficRecord(day: today, bytes: bytes, hours: list)
            }
            do {
                try AtomicFile.writeJSON(out, to: url)
                dirty = false
            } catch {
                Log.info("store", "could not save the download count: \(error.localizedDescription)")
            }
        }
    }
}
