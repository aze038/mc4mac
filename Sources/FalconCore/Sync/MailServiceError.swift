import Foundation

/// A failure put the way the owner should hear it: one plain sentence, with the server's own
/// words kept in `detail` for the log. What kind of failure it is comes only from typed values
/// (the IMAP status and response code, a BYE, the server's reply text, an SMTP code), never from
/// a sentence FalconMail wrote, so rewording any of them cannot change what the engine does.
public struct MailServiceError: Error, LocalizedError, Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case throttled, overBudget, tooManyConnections, webSignInRequired, connectionDropped, needsSignIn
        case messageGone, folderGone, mailboxRenumbered, expungeRefused, temporary
        case sendingLimit, recipientRefused, local, refused
    }

    public var kind: Kind
    public var email: String
    public var isGoogle: Bool
    /// The server's words or the underlying error, for the log only.
    public var detail: String
    public var retryAfter: Date?
    /// The folder, address or file the sentence names.
    public var name: String?

    public init(kind: Kind, email: String, isGoogle: Bool, detail: String = "", retryAfter: Date? = nil, name: String? = nil) {
        self.kind = kind
        self.email = email
        self.isGoogle = isGoogle
        self.detail = detail
        self.retryAfter = retryAfter
        self.name = name
    }

    public init(kind: Kind, account: AccountInfo, detail: String = "", retryAfter: Date? = nil, name: String? = nil) {
        self.init(kind: kind, email: account.email, isGoogle: account.provider == "google", detail: detail,
                  retryAfter: retryAfter, name: name)
    }

    public var errorDescription: String? { sentence }

    public var sentence: String {
        let service = isGoogle ? "Gmail" : "The mail server"
        let folder = name.map { "“\($0)”" } ?? "the folder"
        switch kind {
        case .throttled:
            return "\(service) asked FalconMail to slow down for \(email). Mail on this Mac stays available; downloads resume \(MailServiceError.when(retryAfter))."
        case .overBudget:
            return "\(email) has used today's download allowance. Mail on this Mac and new mail stay available; older messages open again \(MailServiceError.when(retryAfter))."
        case .tooManyConnections:
            let minutes = max(1, Int(((retryAfter ?? Date()).timeIntervalSinceNow / 60).rounded()))
            return "Other apps are using \(email)'s connections. Retrying in \(minutes) minute\(minutes == 1 ? "" : "s")."
        case .webSignInRequired:
            return "\(isGoogle ? "Google" : "The mail server") wants you to sign in to \(email) in a web browser first. FalconMail will retry after that."
        case .connectionDropped:
            return "Reconnecting to \(email)…"
        case .needsSignIn:
            return "\(email) needs you to sign in again."
        case .messageGone:
            return "This message was moved or deleted on the server."
        case .folderGone:
            return "The folder \(folder) no longer exists on the server."
        case .mailboxRenumbered:
            return "The folder \(folder) was rebuilt on the server, so that no longer applies. FalconMail is reloading it."
        case .expungeRefused:
            return "Nothing was deleted from \(folder): another message there is marked for deletion, and this server can only delete them all at once."
        case .temporary:
            return "\(service) had a temporary problem. Retrying."
        case .sendingLimit:
            return "\(isGoogle ? "Gmail's daily sending limit" : "The daily sending limit") for \(email) was reached. The message stays in the Outbox."
        case .recipientRefused:
            return "\(service) refused the address \(name ?? "of a recipient")."
        case .local:
            return detail
        case .refused:
            return "\(email): the server refused a request. Details are in the log."
        }
    }

    /// Worth trying again by itself, later, without the owner doing anything.
    public var isTransient: Bool {
        switch kind {
        case .connectionDropped, .temporary, .throttled, .tooManyConnections: return true
        default: return false
        }
    }

    private static func when(_ date: Date?) -> String {
        guard let date else { return "shortly" }
        let f = DateFormatter()
        f.dateStyle = Calendar.current.isDate(date, inSameDayAs: Date()) ? .none : .medium
        f.timeStyle = .short
        return "at " + f.string(from: date)
    }

    public static func classify(_ error: Error, account: AccountInfo) -> MailServiceError {
        classify(error, email: account.email, isGoogle: account.provider == "google")
    }

    public static func classify(_ error: Error, email: String, isGoogle: Bool) -> MailServiceError {
        func make(_ kind: Kind, _ detail: String, name: String? = nil) -> MailServiceError {
            MailServiceError(kind: kind, email: email, isGoogle: isGoogle, detail: detail, name: name)
        }
        switch error {
        case let e as MailServiceError:
            return e
        case let e as IMAPBye:
            let detail = "BYE \(e.code.map { "[\($0)] " } ?? "")\(e.text)"
            return make(serverKind(code: e.codeName, text: e.text, command: nil, isBye: true), detail)
        case let e as IMAPServerError:
            let detail = "\(e.command) \(e.status.rawValue) \(e.code.map { "[\($0)] " } ?? "")\(e.text)"
            return make(serverKind(code: e.codeName, text: e.text, command: e.command, isBye: false), detail, name: e.mailbox)
        case let e as IMAPMailboxRenumbered:
            return make(.mailboxRenumbered, "UIDVALIDITY \(e.expected) is now \(e.found)", name: e.mailbox)
        case let e as IMAPMessageMissing:
            return make(.messageGone, "UID \(e.uid) not returned")
        case let e as IMAPExpungeRefused:
            return make(.expungeRefused, "\(e.others.count) other messages marked \\Deleted and no UIDPLUS", name: e.mailbox)
        case let e as SMTPServerError:
            return make(smtpKind(e), "SMTP \(e.stage.rawValue) \(e.code) \(e.text)", name: e.stage == .recipient ? e.recipient : nil)
        case let e as FalconError:
            switch e {
            case .notAuthenticated: return make(.needsSignIn, "no usable sign-in")
            case .network(let s): return make(.connectionDropped, s)
            case .http(let status, let s):
                if status == 401 { return make(.needsSignIn, "HTTP \(status) \(s)") }
                if status == 429 || status >= 500 { return make(.temporary, "HTTP \(status) \(s)") }
                return make(.refused, "HTTP \(status) \(s)")
            case .protocolError(let s): return make(.refused, s)
            case .storage, .invalidInput, .cancelled: return make(.local, e.localizedDescription)
            }
        case let e as URLError:
            return make(.connectionDropped, "URLError \(e.code.rawValue)")
        default:
            return make(.local, error.localizedDescription)
        }
    }

    /// What an IMAP refusal or BYE means, from its response code and the server's own text.
    static func serverKind(code: String?, text: String, command: String?, isBye: Bool) -> Kind {
        let said = text.lowercased()
        if code == "THROTTLED" || said.contains("command or bandwidth") || said.contains("bandwidth limit") || said.contains("lockdown") {
            return .throttled
        }
        if said.contains("too many simultaneous connections") { return .tooManyConnections }
        if code == "WEBALERT" || said.contains("web browser") || said.contains("web login") { return .webSignInRequired }
        if code == "AUTHENTICATIONFAILED" || code == "AUTHORIZATIONFAILED" || code == "EXPIRED" { return .needsSignIn }
        if code == "UNAVAILABLE" || code == "INUSE" { return .temporary }
        if code == "NONEXISTENT" || code == "TRYCREATE" { return .folderGone }
        if !isBye, command == "LOGIN" || command == "AUTHENTICATE" { return .needsSignIn }
        return isBye ? .connectionDropped : .refused
    }

    static func smtpKind(_ e: SMTPServerError) -> Kind {
        let said = e.text.lowercased()
        if e.enhancedCode == "5.4.5" || said.contains("sending limit") || said.contains("sending quota") { return .sendingLimit }
        if (400..<500).contains(e.code) { return .temporary }
        if e.stage == .authentication { return .needsSignIn }
        if e.stage == .recipient { return .recipientRefused }
        return .refused
    }
}

/// One status per account, driving the line under the folders. It changes only when the
/// engine's view of the account changes, and every change is logged.
public enum AccountHealth: Sendable, Equatable {
    case connecting
    case online
    /// Unreachable for long enough to say so; reconnecting quietly meanwhile.
    case offline(since: Date)
    case imapPaused(until: Date)
    case needsSignIn
    /// Stopped until the owner does something; the reason is the sentence to show.
    case blocked(reason: String)

    public var isReachable: Bool {
        switch self {
        case .connecting, .online: return true
        default: return false
        }
    }

    var logName: String {
        switch self {
        case .connecting: return "connecting"
        case .online: return "online"
        case .offline: return "offline"
        case .imapPaused(let until): return "imapPaused until=\(ISO8601DateFormatter.archive.string(from: until))"
        case .needsSignIn: return "needsSignIn"
        case .blocked: return "blocked"
        }
    }
}
