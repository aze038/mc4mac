import Foundation

/// When a Google account's next check for changes is due (§4.1).
///
/// Every 30 seconds while the owner has done something in the last half hour, whether FalconMail
/// is in front or not, since notifications matter most when another app is; every 2 minutes once
/// he has not, or the screen is locked; never while the Mac sleeps. Waking, a change of network,
/// Send & Receive and a change Gmail has just confirmed check at once, and a message that has just
/// gone out is looked for 2 and 10 seconds later. While Google has asked FalconMail to wait,
/// nothing is checked until the time it gave. A check is one call of 2 units, so the half-minute
/// pace costs about 240 units an hour.
public struct GmailPollSchedule: Sendable, Equatable {
    public struct Settings: Sendable, Equatable {
        public var activeInterval: TimeInterval = 30
        public var idleInterval: TimeInterval = 120
        /// How long after the owner's last input checks keep the active pace.
        public var activeFor: TimeInterval = 30 * 60
        /// Offline, a check costs nothing, since nothing reaches Google; trying now and then
        /// finds the network back even where nothing tells the engine that it changed.
        public var offlineRetry: TimeInterval = 120
        public var afterSend: [TimeInterval] = [2, 10]

        public init() {}
    }

    public var settings: Settings
    public private(set) var activity: OwnerActivity
    public private(set) var lastCheck: Date?
    /// Google asked FalconMail to wait until then.
    public private(set) var pausedUntil: Date?
    /// Blocked until the owner or an administrator acts: looked at again only then.
    public private(set) var blockedUntil: Date?
    /// The account must be signed in again: nothing is checked until the engine is started again
    /// or the owner asks.
    public private(set) var stopped = false
    public private(set) var offline = false
    /// Checks asked for at set times, such as those after a message went out.
    public private(set) var extra: [Date] = []

    public init(settings: Settings = Settings(), now: Date) {
        self.settings = settings
        activity = .active(at: now)
    }

    public mutating func noteActivity(_ activity: OwnerActivity) {
        self.activity = activity
    }

    /// A check ended, whatever its outcome; checks asked for at or before now are done.
    public mutating func checkEnded(at now: Date) {
        lastCheck = now
        extra.removeAll { $0 <= now }
    }

    public mutating func messageSent(at now: Date) {
        extra += settings.afterSend.map { now.addingTimeInterval($0) }
        extra.sort()
    }

    public mutating func pause(until date: Date?) { pausedUntil = date }
    public mutating func block(until date: Date?) { blockedUntil = date }
    public mutating func stop(_ on: Bool) { stopped = on }
    public mutating func setOffline(_ on: Bool) { offline = on }

    /// The owner asked, the Mac woke or the network changed: whatever held checks back is looked
    /// at again now, except a wait Google asked for.
    public mutating func clearHolds() {
        stopped = false
        blockedUntil = nil
        offline = false
    }

    /// The interval between checks now; nil when nothing is checked at all.
    public func interval(at now: Date) -> TimeInterval? {
        if stopped { return nil }
        switch activity {
        case .asleep:
            return nil
        case .active(let at):
            if offline { return settings.offlineRetry }
            return now.timeIntervalSince(at) < settings.activeFor ? settings.activeInterval : settings.idleInterval
        case .idle:
            return offline ? settings.offlineRetry : settings.idleInterval
        }
    }

    /// When the next check is due; nil when none is.
    public func nextCheck(after now: Date) -> Date? {
        guard let interval = interval(at: now) else { return nil }
        var due = lastCheck.map { $0.addingTimeInterval(interval) } ?? now
        if let soonest = extra.first, !offline { due = min(due, soonest) }
        if let blockedUntil { due = max(due, blockedUntil) }
        if let pausedUntil { due = max(due, pausedUntil) }
        return due
    }
}

/// What the engine says of an account's health (§4.7, §10.2), from how its checks go.
///
/// A check that fails for a moment says `.connecting`, quietly; one still failing after two
/// minutes says the account is offline and why. A wait Google asks for is a pause, not a failure,
/// and says nothing at all unless it has lasted, or will last, more than a minute, so the many
/// short waits of a first day never make the status line flicker. A refusal only the owner or an
/// administrator can lift says so at once.
struct GmailHealthTracker: Sendable {
    let email: String
    private(set) var health: AccountHealth?
    private(set) var failingSince: Date?
    private(set) var pausedSince: Date?

    static let quietFailures: TimeInterval = 120
    static let quietPause: TimeInterval = 60

    init(email: String) {
        self.email = email
    }

    /// What follows a check, for the engine to act on.
    struct Verdict: Equatable {
        /// Set only when the health changes.
        var health: AccountHealth?
        /// The sentence for the status line, sent as `.error` after the health.
        var sentence: String?
        /// No check before this.
        var pausedUntil: Date?
        /// Looked at again only then.
        var blockedUntil: Date?
        /// Nothing is checked until the owner acts.
        var stops = false
        var offline = false
    }

    /// Before the first check: the account is connecting, which is no failure.
    mutating func starting() -> AccountHealth? {
        guard health == nil else { return nil }
        health = .connecting
        return .connecting
    }

    /// A check went through. True in `recovered` when it ends a failure or a pause that was shown.
    mutating func succeeded() -> (health: AccountHealth?, recovered: Bool) {
        let recovered = failingSince != nil || health.map { $0 != .online && $0 != .connecting } ?? false
        failingSince = nil
        pausedSince = nil
        return (change(to: .online), recovered)
    }

    mutating func failed(_ error: GoogleAPIError, pause: GmailPause?, now: Date) -> Verdict {
        switch error.kind {
        case .rateLimited, .quotaExhausted, .downloadLimit, .uploadLimit:
            let until = pauseEnd(error, pause: pause, now: now)
            let since = pausedSince ?? now
            pausedSince = since
            failingSince = nil
            guard until.timeIntervalSince(since) > Self.quietPause || now.timeIntervalSince(since) > Self.quietPause else {
                return Verdict(pausedUntil: until)
            }
            let changed = change(to: .apiPaused(until: until))
            return Verdict(health: changed, sentence: changed == nil ? nil : pauseSentence(error.kind, until: until), pausedUntil: until)
        case .needsSignIn:
            failingSince = nil
            return Verdict(health: change(to: .needsSignIn), sentence: "\(email) needs you to sign in again.", stops: true)
        case .insufficientPermissions:
            failingSince = nil
            return Verdict(health: change(to: .needsSignIn),
                           sentence: "FalconMail needs permission to read and send mail for \(email). Sign in again and leave every box ticked.",
                           stops: true)
        case .clientRejected, .domainPolicy, .gmailNotEnabled, .apiDisabled:
            failingSince = nil
            let reason = blockedSentence(error.kind)
            let recheck: TimeInterval = error.kind == .apiDisabled ? 600 : 3_600
            return Verdict(health: change(to: .blocked(reason: reason)), sentence: reason,
                           blockedUntil: now.addingTimeInterval(recheck))
        default:
            let since = failingSince ?? now
            failingSince = since
            pausedSince = nil
            let isOffline = error.kind == .offline
            guard now.timeIntervalSince(since) >= Self.quietFailures else {
                // Quietly: most failures are over with the next check.
                return Verdict(health: health == .online || health == nil ? change(to: .connecting) : nil, offline: isOffline)
            }
            let changed = change(to: .offline(since: since))
            let sentence = isOffline ? "Offline — showing the messages kept on this Mac." : "Reconnecting to \(email)…"
            return Verdict(health: changed, sentence: changed == nil ? nil : sentence, offline: isOffline)
        }
    }

    /// Google's own time when it gave one, else the transport's pause, else a minute. A daily cap
    /// the owner set holds everything until Google's day ends, at midnight Pacific.
    private func pauseEnd(_ error: GoogleAPIError, pause: GmailPause?, now: Date) -> Date {
        if error.kind == .quotaExhausted { return GoogleAPIError.quotaReset(after: now) }
        if let seconds = error.retryAfter { return max(now.addingTimeInterval(seconds), pause?.until ?? .distantPast) }
        if let until = pause?.until, until > now { return until }
        return now.addingTimeInterval(60)
    }

    private func pauseSentence(_ kind: GoogleAPIError.Kind, until: Date) -> String {
        let time = GoogleAPIError.timeText(until)
        switch kind {
        case .quotaExhausted:
            return "Today's Gmail allowance for FalconMail is used up until \(time). Mail on this Mac stays available; changes you make are sent then."
        case .downloadLimit:
            return "FalconMail has paused downloading older mail for \(email) until \(time), to stay within Gmail's daily limit. New mail still arrives."
        case .uploadLimit:
            return "Gmail has paused uploads for \(email) until \(time); an import may be using the allowance. The message stays in the Outbox."
        default:
            return "Waiting a moment before loading more of \(email)'s messages."
        }
    }

    private func blockedSentence(_ kind: GoogleAPIError.Kind) -> String {
        switch kind {
        case .clientRejected:
            return "Google didn't accept FalconMail's sign-in for \(email). Sign in again; if it keeps happening, the Workspace administrator may need to allow FalconMail."
        case .domainPolicy:
            return "The Workspace administrator has turned off Gmail access for apps like FalconMail for \(email)."
        case .gmailNotEnabled:
            return "Gmail isn't turned on for \(email)."
        default:
            return "Google has turned off FalconMail's access to Gmail for now. FalconMail will try again later."
        }
    }

    private mutating func change(to new: AccountHealth) -> AccountHealth? {
        guard health != new else { return nil }
        health = new
        return new
    }
}
