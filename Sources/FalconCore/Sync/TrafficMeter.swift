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

/// One account's entry in bandwidth.json: the download of that UTC day, all the previous
/// release reads and writes. It rewrites the whole file with nothing else in it, so the hourly
/// count this build keeps lives in traffic.json, which it never touches.
struct TrafficRecord: Codable {
    var day: String
    var bytes: Int
}

/// Counts every IMAP byte each account moves, down and up, over a rolling 24 hours in hourly
/// buckets. A count that started again at midnight would let a full allowance through just
/// before it and another just after, which a provider counting any 24 hours sees as double.
/// Thread-safe, so a connection can count as bytes arrive without waiting on anything.
public final class TrafficMeter: @unchecked Sendable {
    public let limits: TrafficLimits
    private let countURL: URL
    private let hoursURL: URL
    private let countWritable: Bool
    private let hoursWritable: Bool
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    /// Keyed by account id as stored, oldest hour first, kept for two days so that a day's
    /// total in bandwidth.json can be told apart from what the previous release added to it.
    private var hours: [String: [TrafficHour]] = [:]
    private var dirty = false

    public init(layout: FileLayout = FileLayout(), limits: TrafficLimits = .standard,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.limits = limits
        self.now = now
        countURL = layout.root.appendingPathComponent("bandwidth.json")
        hoursURL = layout.root.appendingPathComponent("traffic.json")
        let counts = AtomicFile.loadJSON([String: TrafficRecord].self, from: countURL, what: "the download count")
        let hourly = AtomicFile.loadJSON([String: [TrafficHour]].self, from: hoursURL, what: "the hourly traffic count")
        countWritable = counts.canSave
        hoursWritable = hourly.canSave
        hours = hourly.value ?? [:]
        let current = TrafficMeter.hourIndex(now())
        let modified = (try? FileManager.default.attributesOfItem(atPath: countURL.path)[.modificationDate]) as? Date
        let written = modified.map(TrafficMeter.hourIndex) ?? current
        for (key, record) in counts.value ?? [:] {
            guard let extra = TrafficMeter.uncounted(record, in: hours[key] ?? [], writtenHour: written, currentHour: current) else { continue }
            var list = hours[key] ?? []
            if let i = list.firstIndex(where: { $0.hour == extra.hour }) {
                list[i].down += extra.down
            } else {
                list.append(extra)
                list.sort { $0.hour < $1.hour }
            }
            hours[key] = list
            dirty = true
        }
    }

    public static let shared = TrafficMeter()

    /// Downloads in a day's total that the hourly count does not hold: what the previous
    /// release, which knows only the total, added since this build last saved, or the whole of
    /// a count from before this build. None can have come after the file was written, so they
    /// are placed at that hour, within their day, and stay in the window at least as long as
    /// they belong there.
    private static func uncounted(_ record: TrafficRecord, in list: [TrafficHour], writtenHour: Int, currentHour: Int) -> TrafficHour? {
        guard record.bytes > 0, let dayStart = hourIndex(day: record.day) else { return nil }
        let counted = list.filter { $0.hour >= dayStart && $0.hour < dayStart + 24 }.reduce(0) { $0 + $1.down }
        guard record.bytes > counted else { return nil }
        var hour = min(writtenHour, currentHour)
        // A file written before the day it counts has a clock to blame: the latest hour is safe.
        if hour < dayStart { hour = currentHour }
        hour = min(hour, dayStart + 23)
        guard hour > currentHour - 24 else { return nil }
        return TrafficHour(hour: hour, down: record.bytes - counted, up: 0, background: 0)
    }

    static func hourIndex(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 3600).rounded(.down))
    }

    private static func dayFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    private static func dayName(hour: Int) -> String {
        dayFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(hour) * 3600))
    }

    /// The first hour of a day named as bandwidth.json names it.
    private static func hourIndex(day: String) -> Int? {
        dayFormatter().date(from: day).map(hourIndex)
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
            var list = kept(account.uuidString, currentHour: current)
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

    /// The account's hours of the last two days. Called under the lock.
    private func kept(_ key: String, currentHour: Int) -> [TrafficHour] {
        (hours[key] ?? []).filter { $0.hour > currentHour - 48 }
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

    /// Saves the counts, so that a relaunch cannot undo the protection: the hours in
    /// traffic.json, and today's download in bandwidth.json, where the previous release finds
    /// it. A save cut short between the two loses nothing: what a day's total holds beyond the
    /// hours is counted from it when next read.
    public func persist() {
        let current = TrafficMeter.hourIndex(now())
        let dayStart = current - current % 24
        let today = TrafficMeter.dayName(hour: current)
        lock.withLock {
            guard dirty else { return }
            var hourly: [String: [TrafficHour]] = [:]
            var counts: [String: TrafficRecord] = [:]
            for key in hours.keys {
                let list = kept(key, currentHour: current)
                guard !list.isEmpty else { continue }
                hourly[key] = list
                counts[key] = TrafficRecord(day: today, bytes: list.filter { $0.hour >= dayStart }.reduce(0) { $0 + $1.down })
            }
            do {
                if hoursWritable { try AtomicFile.writeJSON(hourly, to: hoursURL) }
                if countWritable { try AtomicFile.writeJSON(counts, to: countURL) }
                dirty = false
            } catch {
                Log.info("store", "could not save the download count: \(error.localizedDescription)")
            }
        }
    }
}
