import Foundation

/// A refusal from a Google API, classified from typed values: the HTTP status, the API's reason
/// code and status, the OAuth error code or the URL error, and for the Gmail engine the call that
/// was refused. Display text never decides whether FalconMail waits or gives up. The one reading
/// of words is the engine's for a 429, where Google names a sending limit or too many requests at
/// once only in its message: a reworded message leaves an ordinary rate-limit wait.
public struct GoogleAPIError: Error, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// 429, or 403 `rateLimitExceeded` / `userRateLimitExceeded`: slow down and retry.
        case rateLimited
        /// 403 `dailyLimitExceeded` / `quotaExceeded`: nothing more until the quota resets.
        case quotaExhausted
        /// 403 `accessNotConfigured` / `SERVICE_DISABLED`: the Gmail API is off for the project.
        case apiDisabled
        /// 403 `insufficientPermissions`: the sign-in did not grant the scope.
        case insufficientPermissions
        /// 401, or OAuth `invalid_grant`: the account has to sign in again.
        case needsSignIn
        /// OAuth `unauthorized_client`, `admin_policy_enforced` or `access_denied`.
        case clientRejected
        /// 404: the message or label is gone.
        case notFound
        /// 5xx, `backendError`, or a request that timed out.
        case temporary
        /// No network.
        case offline
        /// 404 on `history.list`: Gmail no longer keeps changes from that far back.
        case historyExpired
        /// 403 `domainPolicy`: the Workspace administrator has turned off Gmail access for apps.
        case domainPolicy
        /// 400 `failedPrecondition`: Gmail is not turned on for the user.
        case gmailNotEnabled
        /// 429 on a send: the account's daily sending limit.
        case sendingLimit
        /// 429 for the API's download allowance, which all of the user's API clients share.
        case downloadLimit
        /// 429 for the API's upload allowance, which all of the user's API clients share, an
        /// import in another app among them.
        case uploadLimit
        /// 413, or `payloadTooLarge`: more than Gmail takes in one message.
        case tooLarge
        case other
    }

    /// Whether Gmail can have acted on the request that was refused.
    public enum Delivery: String, Sendable, Equatable {
        /// Gmail answered with a refusal and did nothing.
        case answered
        /// The request never left the Mac: no connection could be made, the token could not be
        /// had, or FalconMail held it back itself. Sending it again cannot do anything twice.
        case notSent
        /// It may have reached Gmail and been acted on: a timeout, a dropped connection or a
        /// server error. A send refused this way is looked for, never sent again blindly.
        case unknown
    }

    public var kind: Kind
    public var httpStatus: Int
    /// The API's own reason code, such as `rateLimitExceeded`, kept for the log.
    public var reason: String?
    /// The server's text. For the log only; it is never shown.
    public var detail: String
    public var retryAfter: TimeInterval?
    /// A 429 about how many requests the user's clients have open at once rather than how many
    /// units they spend: fewer batch parts at a time help, and a smaller unit budget would not.
    public var isConcurrencyLimit: Bool
    public var delivery: Delivery

    public init(kind: Kind, httpStatus: Int = 0, reason: String? = nil, detail: String = "", retryAfter: TimeInterval? = nil,
                isConcurrencyLimit: Bool = false, delivery: Delivery = .answered) {
        self.kind = kind
        self.httpStatus = httpStatus
        self.reason = reason
        self.detail = detail
        self.retryAfter = retryAfter
        self.isConcurrencyLimit = isConcurrencyLimit
        self.delivery = delivery
    }

    /// Whether a later try can succeed with nothing changed: Google asked FalconMail to wait, or
    /// the network or Gmail had a moment's trouble. Anything else is a definite refusal, which a
    /// change the owner made is put back for (§7.3 of the engine design).
    public var waits: Bool {
        switch kind {
        case .rateLimited, .quotaExhausted, .temporary, .offline, .sendingLimit, .downloadLimit, .uploadLimit:
            return true
        case .apiDisabled, .insufficientPermissions, .needsSignIn, .clientRejected, .notFound, .historyExpired,
             .domainPolicy, .gmailNotEnabled, .tooLarge, .other:
            return false
        }
    }
}

public enum GoogleErrorParser {
    private struct APIErrorBody: Decodable {
        struct Item: Decodable { var reason: String? }
        struct Detail: Decodable { var reason: String? }
        var code: Int?
        var message: String?
        var status: String?
        var errors: [Item]?
        var details: [Detail]?
    }

    private struct Envelope: Decodable {
        var error: APIErrorBody?
        var oauthError: String?
        var oauthDescription: String?

        enum CodingKeys: String, CodingKey { case error, error_description }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            error = try? c.decode(APIErrorBody.self, forKey: .error)
            oauthError = error == nil ? try? c.decode(String.self, forKey: .error) : nil
            oauthDescription = try? c.decode(String.self, forKey: .error_description)
        }
    }

    private static let rateReasons: Set<String> = ["ratelimitexceeded", "userratelimitexceeded", "rate_limit_exceeded"]
    private static let quotaReasons: Set<String> = ["dailylimitexceeded", "quotaexceeded", "resource_exhausted_quota"]
    private static let disabledReasons: Set<String> = ["accessnotconfigured", "service_disabled", "api_disabled"]
    private static let permissionReasons: Set<String> = ["insufficientpermissions", "access_token_scope_insufficient"]
    private static let signInReasons: Set<String> = ["autherror", "invalid_grant", "unauthenticated", "invalid_token"]
    private static let rejectedReasons: Set<String> = ["unauthorized_client", "admin_policy_enforced", "access_denied", "org_internal"]
    private static let temporaryReasons: Set<String> = ["backenderror", "internalerror", "unavailable"]
    private static let policyReasons: Set<String> = ["domainpolicy"]
    private static let notEnabledReasons: Set<String> = ["failedprecondition"]
    private static let tooLargeReasons: Set<String> = ["payloadtoolarge", "uploadtoolarge", "requestentitytoolarge"]

    /// Classifies an HTTP answer. `retryAfter` is the raw Retry-After header.
    public static func parse(status: Int, body: Data, retryAfter header: String? = nil, now: Date = Date()) -> GoogleAPIError {
        let answer = Answer(status: status, body: body)
        return GoogleAPIError(kind: classify(status: status, reasons: answer.reasons, apiStatus: answer.apiStatus),
                              httpStatus: status, reason: answer.reasons.first, detail: answer.detail,
                              retryAfter: retryAfterSeconds(header, now: now), delivery: delivery(status: status))
    }

    /// Classifies an answer to one of the Gmail engine's calls, which knows what it asked for.
    /// Beyond `parse(status:body:)`, it tells apart what the engine handles differently: a 404
    /// from `history.list`, which means the history has expired; a Workspace policy, Gmail not
    /// turned on, and a message too large; and the 429s that Google gives the same status and
    /// reason, which differ in what they pause.
    ///
    /// Google tells a sending limit and a concurrency limit apart from a rate limit only in its
    /// message ("User-rate limit exceeded (Mail sending)", "Too many concurrent requests for
    /// user"), so for a 429 alone those two documented phrases are read. Each only chooses which
    /// wait applies; a reworded message leaves an ordinary rate-limit wait, which is always safe.
    /// A 429 whose retry time is longer than `longRetry` is a daily allowance: downloads or
    /// uploads by the call's direction, which comes from the call itself, not from any text.
    public static func parse(status: Int, body: Data, retryAfter header: String?, now: Date = Date(),
                             method: GmailMethod) -> GoogleAPIError {
        let answer = Answer(status: status, body: body)
        let reasons = answer.reasons
        func has(_ set: Set<String>) -> Bool { reasons.contains { set.contains($0) } }
        var kind = classify(status: status, reasons: reasons, apiStatus: answer.apiStatus)
        let retry = retryAfterSeconds(header, now: now) ?? retryTime(inMessage: answer.detail, now: now)
        var concurrent = false
        switch kind {
        case .notFound where method == .historyList:
            kind = .historyExpired
        case .other, .insufficientPermissions, .notFound:
            if has(policyReasons) {
                kind = .domainPolicy
            } else if has(notEnabledReasons) || (status == 400 && answer.apiStatus == "FAILED_PRECONDITION") {
                kind = .gmailNotEnabled
            } else if status == 413 || has(tooLargeReasons) {
                kind = .tooLarge
            }
        case .rateLimited where status == 429:
            let text = answer.detail.lowercased()
            if text.contains("(mail sending)") {
                kind = .sendingLimit
            } else if text.contains("concurrent requests") {
                concurrent = true
            } else if let retry, retry >= longRetry {
                switch method.direction {
                case .upload: kind = .uploadLimit
                case .download: kind = .downloadLimit
                case .change: break
                }
            }
        default:
            break
        }
        return GoogleAPIError(kind: kind, httpStatus: status, reason: reasons.first, detail: answer.detail,
                              retryAfter: retry, isConcurrencyLimit: concurrent, delivery: delivery(status: status))
    }

    /// A 429 that asks for a wait this long is about a daily allowance, not the minute's rate:
    /// Google's per-minute refusals ask for seconds, its daily ones for hours.
    public static let longRetry: TimeInterval = 15 * 60

    /// A server error may come after Gmail acted; any other answer is a refusal that did nothing.
    private static func delivery(status: Int) -> GoogleAPIError.Delivery {
        status >= 500 ? .unknown : .answered
    }

    private struct Answer {
        var reasons: [String]
        var apiStatus: String?
        var detail: String

        init(status: Int, body: Data) {
            let envelope = try? JSONDecoder().decode(Envelope.self, from: body)
            let api = envelope?.error
            reasons = ((api?.errors ?? []).compactMap(\.reason) + (api?.details ?? []).compactMap(\.reason)
                       + [envelope?.oauthError].compactMap { $0 }).map { $0.lowercased() }
            apiStatus = api?.status?.uppercased()
            detail = api?.message ?? envelope?.oauthDescription ?? String(body.utf8Lossy.prefix(300))
        }
    }

    /// Gmail gives the retry time of a daily limit in its message, as "Retry after
    /// 2026-09-25T13:00:00.000Z", rather than in a Retry-After header. It is a time, read as one;
    /// nothing is classified by it.
    static func retryTime(inMessage message: String, now: Date) -> TimeInterval? {
        guard let range = message.range(of: "retry after ", options: .caseInsensitive) else { return nil }
        let rest = message[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let token = String(rest.prefix { !$0.isWhitespace && $0 != "(" }).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)"))
        guard let date = ISO8601DateFormatter.fractional.date(from: token) ?? ISO8601DateFormatter.archive.date(from: token) else {
            return nil
        }
        return max(0, date.timeIntervalSince(now))
    }

    public static func parse(_ error: URLError) -> GoogleAPIError {
        let detail = "URLError \(error.code.rawValue)"
        switch error.code {
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed,
             .internationalRoamingOff:
            return GoogleAPIError(kind: .offline, detail: detail, delivery: .notSent)
        case .networkConnectionLost:
            // The connection was there and went: whatever was on it may have arrived.
            return GoogleAPIError(kind: .offline, detail: detail, delivery: .unknown)
        case .timedOut:
            return GoogleAPIError(kind: .temporary, detail: detail, delivery: .unknown)
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
             .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection, .badURL, .unsupportedURL:
            // Refused before a byte of the request was sent.
            return GoogleAPIError(kind: .other, detail: detail, delivery: .notSent)
        default:
            return GoogleAPIError(kind: .other, detail: detail, delivery: .unknown)
        }
    }

    private static func classify(status: Int, reasons: [String], apiStatus: String?) -> GoogleAPIError.Kind {
        func has(_ set: Set<String>) -> Bool { reasons.contains { set.contains($0) } }
        if has(rejectedReasons) { return .clientRejected }
        if status == 401 || has(signInReasons) || apiStatus == "UNAUTHENTICATED" { return .needsSignIn }
        if has(disabledReasons) { return .apiDisabled }
        if has(quotaReasons) { return .quotaExhausted }
        if status == 429 || has(rateReasons) { return .rateLimited }
        if has(permissionReasons) { return .insufficientPermissions }
        if status == 404 { return .notFound }
        if status >= 500 || has(temporaryReasons) { return .temporary }
        if status == 403, apiStatus == "RESOURCE_EXHAUSTED" { return .rateLimited }
        if status == 403, apiStatus == "PERMISSION_DENIED" { return .insufficientPermissions }
        return .other
    }

    /// Retry-After is either a number of seconds or an HTTP date.
    public static func retryAfterSeconds(_ header: String?, now: Date = Date()) -> TimeInterval? {
        guard let raw = header?.trimmed, !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

extension GoogleAPIError: LocalizedError {
    /// For something the reader did that failed, such as opening a message found only on the server.
    public var errorDescription: String? {
        switch kind {
        case .rateLimited: return "Gmail is busy. Try again in a moment."
        case .quotaExhausted: return "Today's Gmail allowance is used up. Try again after \(GoogleAPIError.timeText(GoogleAPIError.quotaReset()))."
        case .apiDisabled: return "Gmail API is off for this build's Google project."
        case .insufficientPermissions: return "FalconMail was not given permission to read this mailbox through Gmail. Sign in again to allow it."
        case .needsSignIn: return "This account needs you to sign in again."
        case .clientRejected: return "Google didn't accept FalconMail's sign-in. Sign in again; if it keeps happening, the Workspace administrator may need to allow FalconMail."
        case .notFound: return "This message was moved or deleted on another device."
        case .temporary: return "Gmail had a temporary problem. Try again in a moment."
        case .offline: return "You're offline, and this message is not kept on this Mac."
        case .historyExpired: return "Gmail no longer keeps the changes since FalconMail last looked, so it is listing the mailbox again."
        case .domainPolicy: return "The Workspace administrator has turned off Gmail access for apps like FalconMail."
        case .gmailNotEnabled: return "Gmail isn't turned on for this account."
        case .sendingLimit: return "Gmail's daily sending limit for this account was reached. The message stays in the Outbox."
        case .downloadLimit: return "FalconMail has paused downloading from Gmail for a while, to stay within Gmail's daily limit."
        case .uploadLimit: return "Gmail has paused uploads for this account for a while; an import may be using the allowance."
        case .tooLarge: return "Gmail can't send more than 25 MB of attachments in one message. Remove some, or share them from Google Drive."
        case .other: return "Gmail refused the request. Details are in the log."
        }
    }

    /// One plain sentence for the search list when an account's results come from this Mac
    /// instead of Gmail.
    public func searchNotice(email: String, now: Date = Date()) -> String {
        switch kind {
        case .offline: return "Offline — showing the messages kept on this Mac."
        case .rateLimited: return "Gmail is busy; showing matches on this Mac for \(email)."
        case .quotaExhausted:
            return "Today's Gmail allowance for \(email) is used up until \(GoogleAPIError.timeText(GoogleAPIError.quotaReset(after: now))); showing matches on this Mac."
        case .apiDisabled: return "Gmail API is off for this build's Google project; showing matches on this Mac."
        case .insufficientPermissions: return "FalconMail may not search \(email) through Gmail; showing matches on this Mac."
        case .needsSignIn: return "\(email) needs you to sign in again; showing matches on this Mac."
        case .clientRejected: return "Google didn't accept FalconMail's sign-in for \(email); showing matches on this Mac."
        case .temporary, .notFound: return "Gmail had a temporary problem; showing matches on this Mac for \(email)."
        case .domainPolicy:
            return "The Workspace administrator has turned off Gmail access for apps like FalconMail for \(email); showing matches on this Mac."
        case .gmailNotEnabled: return "Gmail isn't turned on for \(email); showing matches on this Mac."
        case .downloadLimit:
            return "FalconMail has paused downloading from Gmail for \(email), to stay within Gmail's daily limit; showing matches on this Mac."
        case .historyExpired, .sendingLimit, .uploadLimit, .tooLarge, .other:
            return "Gmail refused the search for \(email); showing matches on this Mac. Details are in the log."
        }
    }

    /// One plain sentence for the search list when an account's results stopped short because
    /// Gmail asked for a pause, and Show more fetches the rest.
    public func pausedNotice(email: String) -> String {
        switch kind {
        case .rateLimited: return "Gmail is busy; Show more fetches the rest of the results for \(email) in a moment."
        default: return "Gmail had a temporary problem; Show more fetches the rest of the results for \(email)."
        }
    }

    /// Gmail's daily quota resets at midnight Pacific time.
    public static func quotaReset(after now: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        let start = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? now.addingTimeInterval(86_400)
    }

    static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
