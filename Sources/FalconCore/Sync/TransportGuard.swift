import Foundation

/// Keeps IMAP and SMTP away from Google accounts on the Gmail API (§12.5).
///
/// Every IMAP and SMTP connection asks it first, with the host and the user name it will sign in
/// as: `IMAPClient.connect`, `SMTPClient.connect` and the account check made while an account is
/// set up. A connection for a Google account on the Gmail API is refused, whatever the host, and
/// logged as `gmail.imapBlocked`, so a mistake fails loudly and never reaches Google's IMAP. A
/// connection to Google's IMAP or SMTP hosts for any other account, such as one set up with an
/// app password or one whose switch is off, goes ahead and is logged as `gmail.imapUsed` once a
/// day for each account, so the daily report shows every account still using IMAP with Google.
public final class TransportGuard: @unchecked Sendable {
    public enum Transport: String, Sendable {
        case imap = "IMAP"
        case smtp = "SMTP"
    }

    /// One connection the guard stopped.
    public struct Refusal: Sendable, Equatable {
        public var transport: Transport
        public var host: String
        public var accountID: UUID
        public var at: Date
    }

    public static let shared = TransportGuard()

    /// Google's IMAP and SMTP hosts, under both of Google's mail domains.
    public static let googleHosts: Set<String> = ["imap.gmail.com", "smtp.gmail.com", "imap.googlemail.com", "smtp.googlemail.com"]

    public static func isGoogleHost(_ host: String) -> Bool {
        googleHosts.contains(host.trimmingCharacters(in: .whitespaces).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))
    }

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    /// Accounts on the Gmail API, by the addresses they sign in as.
    private var switched: [String: UUID] = [:]
    private var refused: [Refusal] = []
    /// Connections to Google's hosts by accounts not on the Gmail API, by address.
    private var googleConnections: [String: Int] = [:]
    /// The day each account's use of Google's IMAP or SMTP was last logged, by address and transport.
    private var usedLogged: [String: Date] = [:]

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    // MARK: Which accounts are on the Gmail API

    /// From now on no IMAP or SMTP connection is let through for `account`.
    public func blockMailServers(for account: AccountInfo) {
        lock.withLock {
            for address in TransportGuard.addresses(of: account) { switched[address] = account.id }
        }
    }

    /// `account` may use IMAP and SMTP again, as when its switch is turned off.
    public func allowMailServers(for accountID: UUID) {
        lock.withLock { switched = switched.filter { $0.value != accountID } }
    }

    /// Whether IMAP and SMTP are refused for the account signing in as `user`.
    public func blocks(user: String) -> Bool {
        lock.withLock { switched[user.lowercased()] != nil }
    }

    public var blockedAccounts: Set<UUID> {
        lock.withLock { Set(switched.values) }
    }

    // MARK: Asking

    /// Throws for an account on the Gmail API, before anything is sent; lets every other
    /// connection go, noting one to Google's hosts.
    public func check(_ transport: Transport, host: String, user: String?) throws {
        let user = user?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let date = now()
        let blocked: UUID? = lock.withLock {
            guard let id = switched[user] else { return nil }
            refused.append(Refusal(transport: transport, host: host, accountID: id, at: date))
            return id
        }
        if blocked != nil {
            Log.error("gmail", "\(user): an \(transport.rawValue) connection to \(host) was stopped: this Google account uses the Gmail API only",
                      code: "imapBlocked", details: ["transport": transport.rawValue, "host": host], keeping: user)
            throw MailServiceError(kind: .local, email: user, isGoogle: true,
                                   detail: "\(transport.rawValue) is not used for Google accounts on the Gmail API.")
        }
        guard TransportGuard.isGoogleHost(host) else { return }
        let firstToday: Bool = lock.withLock {
            googleConnections[user, default: 0] += 1
            let key = user + "|" + transport.rawValue
            if let last = usedLogged[key], Calendar.current.isDate(last, inSameDayAs: date) { return false }
            usedLogged[key] = date
            return true
        }
        if firstToday {
            Log.warning("gmail", "\(user) still uses \(transport.rawValue) with Google (\(host))", code: "imapUsed",
                        details: ["transport": transport.rawValue, "host": host], keeping: user)
        }
    }

    // MARK: What it saw

    /// Every connection it stopped, oldest first.
    public var refusals: [Refusal] {
        lock.withLock { refused }
    }

    /// Connections to Google's IMAP and SMTP hosts by accounts not on the Gmail API, by address,
    /// for the daily report. It should hold none for an account on the Gmail API.
    public var connectionsToGoogle: [String: Int] {
        lock.withLock { googleConnections }
    }

    static func addresses(of account: AccountInfo) -> Set<String> {
        Set([account.email, account.loginName].map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
    }
}
