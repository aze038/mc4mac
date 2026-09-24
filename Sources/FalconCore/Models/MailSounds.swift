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
/// Mailbox sync error follows what the engine says of each account (`hear`). Mail servers, NATs
/// and VPNs close an idle connection every few minutes, and waking or changing network does the
/// same: the engine retries such a connection quietly (`AccountHealth.connecting`), and the
/// reconnect a few seconds later finishes a pass. A pause the engine keeps on purpose, for a
/// throttle, the day's allowance or a server that allows no more connections
/// (`AccountHealth.imapPaused`), is no failure at all, and neither is a rule or a muted
/// conversation that fails inside a pass (`SyncEvent.problem`). So the sound plays only for an
/// account the engine says cannot sync (`AccountHealth.isFailing`), once its episode has lasted
/// `lastingFailure`: counted from the episode's first failure, a quiet one included, and heard at
/// a failure then or asked for by `failureLasted`. It sounds once per episode, and the episode
/// lasts until that account next finishes a sync. No new messages is played only for a check
/// the reader asked for, once every account in it has finished without new mail; a check in
/// which an account failed or paused, or that runs past `checkTimeout`, stays quiet, and a sync
/// the app runs by itself, or the engine's own sync of one folder, never plays it.
public struct MailSoundGate {
    public var isEnabled: (MailSoundEvent) -> Bool
    /// Accounts in a failure episode.
    private var failing: [UUID: FailureEpisode] = [:]
    /// What the engine last said of each account.
    private var health: [UUID: AccountHealth] = [:]
    /// Welcome has had its one chance this launch; a mailbox window opened again is no launch.
    private var welcomed = false
    private var check: ManualCheck?

    /// Long enough for a slow mailbox; an account that has not answered by then is taken to be
    /// stuck, and a sound that late would no longer read as the answer to the reader's check.
    public static let checkTimeout: TimeInterval = 300

    /// Long enough for the engine's first retries after a failure to have failed too, short
    /// enough that a mailbox that cannot sync is heard about in a minute.
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

    /// One of the engine's events, as the app hears it, and the sound it plays, if any. A
    /// message that arrived is not decided here: it sounds (`newMailArrived`) when the account's
    /// notify setting lets it through. `uptime` is read from a clock that stops while the Mac
    /// sleeps, so a connection that died as the lid closed has not been failing all night.
    public mutating func hear(_ event: SyncEvent, uptime: TimeInterval, now: Date) -> MailSoundEvent? {
        switch event {
        case .health(let account, let new):
            let before = health.updateValue(new, forKey: account)
            switch new {
            case .online:
                return nil
            case .connecting:
                // The first connection of a launch is no failure. After that, a connection
                // dropped and being retried quietly begins an episode, silently: most are over
                // with the next pass.
                if before != nil, failing[account] == nil { failing[account] = FailureEpisode(started: uptime) }
                return nil
            case .imapPaused:
                // Kept on purpose, so no failure; but the account cannot answer a check in time.
                leaveCheck(account)
                return nil
            case .offline, .needsSignIn, .blocked:
                return syncFailed(account, uptime: uptime)
            }
        case .error(let account, _):
            // The engine says why just after the health; a pause's reason is no failure.
            guard health[account]?.isFailing == true else { return nil }
            return syncFailed(account, uptime: uptime)
        case .finished(let account):
            syncSucceeded(account)
            return nil
        case .checked(let account, let foundNewMail):
            return checkFinished(account, foundNewMail: foundNewMail, at: now)
        default:
            return nil
        }
    }

    /// Asked a while after the engine said an account cannot sync, for an account that may say
    /// nothing more by itself, such as one waiting to be signed in again: whether its failure has
    /// lasted, so that it sounds now.
    public mutating func failureLasted(_ account: UUID, uptime: TimeInterval) -> MailSoundEvent? {
        guard health[account]?.isFailing == true, failing[account] != nil else { return nil }
        return syncFailed(account, uptime: uptime)
    }

    /// A sync or its connection failed.
    public mutating func syncFailed(_ account: UUID, uptime: TimeInterval) -> MailSoundEvent? {
        var episode = failing[account] ?? FailureEpisode(started: uptime)
        // Marked even while the sound is off, so turning it on mid-episode replays nothing.
        let lasted = !episode.sounded && uptime - episode.started >= Self.lastingFailure
        if lasted { episode.sounded = true }
        failing[account] = episode
        leaveCheck(account)
        return lasted ? sound(.syncError) : nil
    }

    /// The account will not answer the check in time, so the check says nothing.
    private mutating func leaveCheck(_ account: UUID) {
        guard var current = check, current.waiting.remove(account) != nil else { return }
        current.failed = true
        check = current.waiting.isEmpty ? nil : current
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

extension AccountHealth {
    /// The engine cannot sync the account and is not holding back on purpose: it is offline
    /// past the quiet retries, needs signing in again, or waits for the owner.
    public var isFailing: Bool {
        switch self {
        case .offline, .needsSignIn, .blocked: return true
        case .connecting, .online, .imapPaused: return false
        }
    }
}
