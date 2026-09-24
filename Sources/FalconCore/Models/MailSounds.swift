import Foundation

/// The six moments Legacy Outlook can play a sound for, in the order its Notifications and
/// Sounds pane lists them: down the left column, then down the right.
public enum MailSoundEvent: String, CaseIterable, Sendable, Identifiable {
    // The first four keep the names earlier builds stored their custom sounds under.
    case newMessage = "newMail"
    case messageSent = "sent"
    case reminder
    case syncError = "error"
    case noNewMessages = "noMail"
    case welcome

    public var id: String { rawValue }

    /// Outlook plays every sound but Welcome until it is told otherwise.
    public var isOnByDefault: Bool { self != .welcome }
}

/// Decides whether something that happens in the app plays a sound, and which.
///
/// Mail servers, NATs and VPNs close an idle connection every few minutes, and waking or
/// changing network does the same; the reconnect a few seconds later finishes a pass. So a
/// failure sounds only once it has lasted: when a sync fails again `lastingFailure` or more
/// after the episode's first failure, with no finished pass between. It sounds once per episode,
/// and the episode lasts until that account next finishes a sync. No new messages is played
/// only for a check the reader asked for, once every account in it has finished without new
/// mail; a check in which an account failed, or that runs past `checkTimeout`, stays quiet, and a
/// sync the app runs by itself never plays it.
public struct MailSoundGate {
    public var isEnabled: (MailSoundEvent) -> Bool
    /// Accounts in a failure episode.
    private var failing: [UUID: FailureEpisode] = [:]
    /// Welcome has had its one chance this launch; a mailbox window opened again is no launch.
    private var welcomed = false
    private var check: ManualCheck?

    /// Long enough for a slow mailbox; an account that has not answered by then is taken to be
    /// stuck, and a sound that late would no longer read as the answer to the reader's check.
    public static let checkTimeout: TimeInterval = 300

    /// Long enough for the retries after a dropped connection (ten, then thirty seconds on) to
    /// have failed too, short enough that a mailbox that cannot sync is heard about in a minute.
    public static let lastingFailure: TimeInterval = 60

    private struct FailureEpisode {
        let started: TimeInterval
        var sounded = false
    }

    private struct ManualCheck {
        var waiting: Set<UUID>
        var foundNewMail = false
        var failed = false
        let started: Date
    }

    public init(isEnabled: @escaping (MailSoundEvent) -> Bool) {
        self.isEnabled = isEnabled
    }

    public mutating func launched() -> MailSoundEvent? {
        guard !welcomed else { return nil }
        welcomed = true
        return sound(.welcome)
    }

    public func newMailArrived() -> MailSoundEvent? { sound(.newMessage) }

    public func messageSent() -> MailSoundEvent? { sound(.messageSent) }

    /// A sync or its connection failed. `uptime` is read from a clock that stops while the Mac
    /// sleeps, so a connection that died as the lid closed has not been failing all night.
    public mutating func syncFailed(_ account: UUID, uptime: TimeInterval) -> MailSoundEvent? {
        var episode = failing[account] ?? FailureEpisode(started: uptime)
        // Marked even while the sound is off, so turning it on mid-episode replays nothing.
        let lasted = !episode.sounded && uptime - episode.started >= Self.lastingFailure
        if lasted { episode.sounded = true }
        failing[account] = episode
        if var current = check, current.waiting.remove(account) != nil {
            current.failed = true
            check = current.waiting.isEmpty ? nil : current
        }
        return lasted ? sound(.syncError) : nil
    }

    public mutating func syncSucceeded(_ account: UUID) {
        failing[account] = nil
    }

    /// The reader asked these accounts for new mail. Accounts that are offline are left out by
    /// the caller: they answer only once they are back, long after the question.
    public mutating func manualCheckStarted(accounts: Set<UUID>, at now: Date) {
        check = accounts.isEmpty ? nil : ManualCheck(waiting: accounts, started: now)
    }

    /// An account finished the pass a check asked for.
    public mutating func checkFinished(_ account: UUID, foundNewMail: Bool, at now: Date) -> MailSoundEvent? {
        guard var current = check, current.waiting.contains(account) else { return nil }
        guard now.timeIntervalSince(current.started) <= Self.checkTimeout else {
            check = nil
            return nil
        }
        current.waiting.remove(account)
        current.foundNewMail = current.foundNewMail || foundNewMail
        guard current.waiting.isEmpty else {
            check = current
            return nil
        }
        check = nil
        return current.foundNewMail || current.failed ? nil : sound(.noNewMessages)
    }

    private func sound(_ event: MailSoundEvent) -> MailSoundEvent? {
        isEnabled(event) ? event : nil
    }
}
