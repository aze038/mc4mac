import Foundation

/// A refusal from a Google API, classified from typed values only: the HTTP status, the API's
/// reason code and status, the OAuth error code or the URL error. Display text never decides
/// the kind, so rewording a message can never change what FalconMail does about it.
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
        case other
    }

    public var kind: Kind
    public var httpStatus: Int
    /// The API's own reason code, such as `rateLimitExceeded`, kept for the log.
    public var reason: String?
    /// The server's text. For the log only; it is never shown and never classified.
    public var detail: String
    public var retryAfter: TimeInterval?

    public init(kind: Kind, httpStatus: Int = 0, reason: String? = nil, detail: String = "", retryAfter: TimeInterval? = nil) {
        self.kind = kind
        self.httpStatus = httpStatus
        self.reason = reason
        self.detail = detail
        self.retryAfter = retryAfter
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

    /// Classifies an HTTP answer. `retryAfter` is the raw Retry-After header.
    public static func parse(status: Int, body: Data, retryAfter header: String? = nil, now: Date = Date()) -> GoogleAPIError {
        let envelope = try? JSONDecoder().decode(Envelope.self, from: body)
        let api = envelope?.error
        let reasons = ((api?.errors ?? []).compactMap(\.reason) + (api?.details ?? []).compactMap(\.reason)
                       + [envelope?.oauthError].compactMap { $0 }).map { $0.lowercased() }
        let apiStatus = api?.status?.uppercased()
        let detail = api?.message ?? envelope?.oauthDescription ?? String(body.utf8Lossy.prefix(300))
        let kind = classify(status: status, reasons: reasons, apiStatus: apiStatus)
        return GoogleAPIError(kind: kind, httpStatus: status, reason: reasons.first, detail: detail,
                              retryAfter: retryAfterSeconds(header, now: now))
    }

    public static func parse(_ error: URLError) -> GoogleAPIError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
            return GoogleAPIError(kind: .offline, detail: "URLError \(error.code.rawValue)")
        case .timedOut:
            return GoogleAPIError(kind: .temporary, detail: "URLError \(error.code.rawValue)")
        default:
            return GoogleAPIError(kind: .other, detail: "URLError \(error.code.rawValue)")
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
        case .other: return "Gmail refused the search for \(email); showing matches on this Mac. Details are in the log."
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
