import Foundation

/// The Gmail API calls FalconMail makes, with the quota units each costs. The prices are Google's
/// for projects created from 1 May 2026, which pay four times the old price for reading a
/// message, a thread or an attachment.
public enum GmailMethod: String, Sendable, CaseIterable, Hashable {
    case profile, labelsList, labelsGet, labelsCreate, labelsDelete, sendAsList
    case messagesList, messagesGet, attachmentsGet, threadsGet, historyList
    case messagesModify, messagesBatchModify, messagesBatchDelete, messagesTrash, messagesUntrash
    case messagesSend, messagesImport, messagesInsert
    case draftsCreate, draftsUpdate, draftsDelete, draftsList

    public var units: Int {
        switch self {
        case .profile, .labelsList, .labelsGet, .sendAsList: return 1
        case .historyList: return 2
        case .labelsCreate, .labelsDelete, .messagesList, .messagesModify, .messagesUntrash, .draftsList: return 5
        case .draftsCreate, .draftsDelete: return 10
        case .draftsUpdate: return 15
        case .messagesGet, .attachmentsGet, .messagesTrash: return 20
        case .messagesImport, .messagesInsert: return 25
        case .threadsGet: return 40
        case .messagesBatchModify, .messagesBatchDelete: return 50
        case .messagesSend: return 100
        }
    }
}

extension GmailMethod {
    /// Which way a call's bytes mostly go, which decides the pauses and byte budgets it answers to.
    public enum Direction: Sendable, Hashable {
        /// Reads, which Google's download allowance counts.
        case download
        /// Whole messages uploaded, which Google's upload allowance counts.
        case upload
        /// Label changes and deletes: a few bytes each way.
        case change
    }

    public var direction: Direction {
        switch self {
        case .messagesSend, .messagesImport, .messagesInsert, .draftsCreate, .draftsUpdate:
            return .upload
        case .labelsCreate, .labelsDelete, .messagesModify, .messagesBatchModify, .messagesBatchDelete,
             .messagesTrash, .messagesUntrash, .draftsDelete:
            return .change
        case .profile, .labelsList, .labelsGet, .sendAsList, .messagesList, .messagesGet, .attachmentsGet,
             .threadsGet, .historyList, .draftsList:
            return .download
        }
    }
}

/// Keeps one account's Gmail API use within a rolling minute's budget, for v1.10.0's search and
/// opening of messages found only on Gmail. The Gmail engine books through `GmailBudget` instead.
/// Google allows 6,000 units a minute per user; FalconMail stays at half that so a busy moment
/// never nears suspension.
/// A rate refusal halves the budget, which then recovers by a tenth of the full budget a minute,
/// and Retry-After holds every call back until it has passed. A used-up daily quota or a
/// disabled API refuses every call at once, without asking Google, until it can have changed.
public actor GmailQuotaLimiter {
    public static let defaultUnitsPerMinute = 3_000

    public let unitsPerMinute: Int
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var ledger: [(at: Date, units: Int)] = []
    private var reducedLimit: Double?
    private var reducedAt = Date.distantPast
    private var pausedUntil = Date.distantPast
    private var held: (until: Date, refusal: GoogleAPIError)?
    public private(set) var spent: [GmailMethod: Int] = [:]
    public private(set) var calls: [GmailMethod: Int] = [:]

    public init(unitsPerMinute: Int = GmailQuotaLimiter.defaultUnitsPerMinute,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void) {
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

    /// However often Google refuses, the budget keeps a quarter, which still fits a page of 25
    /// search results (505 units), so a recovering account can always finish one.
    private var lowestLimit: Double { Double(unitsPerMinute) / 4 }

    /// Waits until `method` fits in the budget, then books its units and returns when it did. A
    /// wait longer than `maxWait` is not made: the call is refused as rate-limited so an
    /// interactive caller can fall back at once instead of hanging.
    @discardableResult
    public func acquire(_ method: GmailMethod, maxWait: TimeInterval = .infinity) async throws -> Date {
        let units = method.units
        while true {
            try Task.checkCancellation()
            let current = now()
            if let held, held.until > current { throw held.refusal }
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
                    return current
                }
                wait = timeUntilRoom(for: units, limit: currentLimit, at: current)
            }
            guard wait <= maxWait else {
                throw GoogleAPIError(kind: .rateLimited, detail: "local budget", retryAfter: wait)
            }
            try await sleep(wait)
        }
    }

    /// Google refused a call booked at `sentAt` for its rate: halve the budget and hold every call
    /// back for Retry-After when Google gave one. Calls sent before the last halving are refusals
    /// from the same burst, such as all of a page's concurrent fetches at once, so they halve
    /// the budget once between them rather than once each.
    public func throttled(retryAfter: TimeInterval?, sentAt: Date) {
        let current = now()
        if sentAt > reducedAt {
            reducedLimit = max(lowestLimit, Double(currentLimit) / 2)
            reducedAt = current
        }
        if let retryAfter { pausedUntil = max(pausedUntil, current.addingTimeInterval(retryAfter)) }
    }

    /// Google said the day's quota is used up, or that the Gmail API is off for the project.
    /// Asking again would only be refused again, so every call is refused here until the quota
    /// resets, or for ten minutes for a disabled API in case someone turns it on meanwhile.
    public func hold(_ refusal: GoogleAPIError) {
        let current = now()
        switch refusal.kind {
        case .quotaExhausted: held = (GoogleAPIError.quotaReset(after: current), refusal)
        case .apiDisabled: held = (current.addingTimeInterval(600), refusal)
        default: break
        }
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
