import Foundation

/// The Gmail API calls FalconMail makes, with the quota units each costs.
public enum GmailMethod: String, Sendable, CaseIterable, Hashable {
    case profile, labelsList, messagesList, messagesGet, attachmentsGet

    public var units: Int {
        switch self {
        case .profile, .labelsList: return 1
        case .messagesList, .attachmentsGet: return 5
        case .messagesGet: return 20
        }
    }
}

/// Keeps one account's Gmail API use within a rolling minute's budget. Google allows 6,000 units
/// a minute per user; FalconMail stays at half that so a busy moment never nears suspension.
/// A rate refusal halves the budget, which then recovers by a tenth of the full budget a minute,
/// and Retry-After holds every call back until it has passed.
public actor GmailQuotaLimiter {
    public static let defaultUnitsPerMinute = 3_000

    public let unitsPerMinute: Int
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var ledger: [(at: Date, units: Int)] = []
    private var reducedLimit: Double?
    private var reducedAt = Date.distantPast
    private var pausedUntil = Date.distantPast
    public private(set) var spent: [GmailMethod: Int] = [:]
    public private(set) var calls: [GmailMethod: Int] = [:]

    public init(unitsPerMinute: Int = GmailQuotaLimiter.defaultUnitsPerMinute,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
                    try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                }) {
        self.unitsPerMinute = unitsPerMinute
        self.now = now
        self.sleep = sleep
    }

    /// The budget for the current minute, after any halving and the recovery since.
    public var currentLimit: Int {
        guard let reduced = reducedLimit else { return unitsPerMinute }
        let minutes = max(0, now().timeIntervalSince(reducedAt) / 60)
        let recovered = reduced + Double(unitsPerMinute) * 0.1 * minutes
        return recovered >= Double(unitsPerMinute) ? unitsPerMinute : Int(recovered)
    }

    /// Waits until `method` fits in the budget, then books its units. A wait longer than
    /// `maxWait` is not made: the call is refused as rate-limited so an interactive caller can
    /// fall back at once instead of hanging.
    public func acquire(_ method: GmailMethod, maxWait: TimeInterval = .infinity) async throws {
        let units = method.units
        while true {
            try Task.checkCancellation()
            let current = now()
            ledger.removeAll { current.timeIntervalSince($0.at) >= 60 }
            var wait: TimeInterval = 0
            if pausedUntil > current {
                wait = pausedUntil.timeIntervalSince(current)
            } else {
                let used = ledger.reduce(0) { $0 + $1.units }
                // A single call is always allowed into an empty minute, whatever its size.
                if used + units <= currentLimit || ledger.isEmpty {
                    ledger.append((current, units))
                    spent[method, default: 0] += units
                    calls[method, default: 0] += 1
                    return
                }
                wait = timeUntilRoom(for: units, limit: currentLimit, at: current)
            }
            guard wait <= maxWait else {
                throw GoogleAPIError(kind: .rateLimited, detail: "local budget", retryAfter: wait)
            }
            try await sleep(wait)
        }
    }

    /// Google refused a call for its rate: halve the budget and hold every call back for
    /// Retry-After when Google gave one.
    public func throttled(retryAfter: TimeInterval?) {
        let current = now()
        reducedLimit = max(Double(unitsPerMinute) / 16, Double(currentLimit) / 2)
        reducedAt = current
        if let retryAfter { pausedUntil = max(pausedUntil, current.addingTimeInterval(retryAfter)) }
    }

    /// Holds every call back for a while without cutting the budget, as after a server error.
    public func backOff(_ seconds: TimeInterval) {
        pausedUntil = max(pausedUntil, now().addingTimeInterval(seconds))
    }

    private func timeUntilRoom(for units: Int, limit: Int, at current: Date) -> TimeInterval {
        var used = ledger.reduce(0) { $0 + $1.units }
        for entry in ledger {
            used -= entry.units
            if used + units <= limit { return max(0.001, 60 - current.timeIntervalSince(entry.at)) }
        }
        return max(0.001, 60 - current.timeIntervalSince(ledger.first?.at ?? current))
    }
}
