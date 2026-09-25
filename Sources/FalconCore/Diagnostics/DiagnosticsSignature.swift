import Foundation

/// Grouping keys. A signature names where and how something failed, never with what: the
/// same failure at the same place reads the same on every Mac and every run, so the triage
/// can count it. It is `Area.code@File.swift:function` for a logged failure,
/// `Area.code@Binary:function` for a crash or hang (see `CrashIdentity`), and `Area.code@Binary`
/// for MetricKit's CPU and disk-write reports.
///
/// The place is the function rather than the line: lines move whenever code above them
/// changes, nearly every release and above all in the one that fixes the failure, which would
/// make a fixed issue look new and lose its notes.
public enum DiagnosticsSignature {
    public static func make(area: String, code: String, file: String, function: String) -> String {
        "\(word(area)).\(word(code))@\(fileName(file)):\(word(String(function.prefix { $0 != "(" })))"
    }

    /// `AccountSyncer.swift` from `FalconCore/AccountSyncer.swift`.
    public static func fileName(_ file: String) -> String {
        file.split(separator: "/").last.map(String.init) ?? file
    }

    public static func make(area: String, code: String, place: String) -> String {
        "\(word(area)).\(word(code))@\(word(place))"
    }

    /// Letters, dots, dashes and underscores only: whatever else a caller passes, a number
    /// included, cannot split one failure into many signatures.
    static func word(_ text: String) -> String {
        let allowed = CharacterSet.letters.union(CharacterSet(charactersIn: "._-")).subtracting(.nonBaseCharacters)
        let kept = String(String.UnicodeScalarView(text.unicodeScalars.filter { allowed.contains($0) && $0.isASCII }))
        let collapsed = kept.replacingOccurrences(of: "\\.{2,}", with: ".", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        return collapsed.isEmpty ? "unknown" : String(collapsed.prefix(60))
    }

    // MARK: Codes

    /// What kind of failure this was, from the error itself where there is one and otherwise
    /// from the words of the message.
    public static func code(for error: (any Error)?, message: String) -> String {
        if let error, let code = code(for: error) { return code }
        if let code = classify(message) { return code }
        if let error { return typeName(of: error) }
        return shape(of: message)
    }

    static func code(for error: any Error) -> String? {
        if error is CancellationError { return "cancelled" }
        if let failure = error as? MailServiceError { return code(forFailure: failure) }
        if let refusal = error as? GoogleAPIError { return code(forRefusal: refusal) }
        // Setting an account up, a refused sign-in is a wrong name or password.
        if let probe = error as? AccountProbeFailure { return probe.failure.kind == .needsSignIn ? "wrongPassword" : code(forFailure: probe.failure) }
        if isMailEngineError(error) { return code(forFailure: MailServiceError.classify(error, email: "", isGoogle: false)) }
        if error is FolderIndexUnreadable { return "unreadable" }
        if let f = error as? FalconError {
            switch f {
            case .notAuthenticated: return "notSignedIn"
            case .cancelled: return "cancelled"
            case .http(let status, let text): return classify(text) == "throttled" ? "throttled" : httpCode(status)
            case .protocolError(let text): return classify(text) ?? "protocol"
            case .network(let text): return classify(text) ?? "network"
            case .storage(let text): return classify(text) ?? "storage"
            case .invalidInput(let text): return classify(text) ?? "invalidInput"
            }
        }
        if let u = error as? URLError { return urlCode(u.code) }
        if error is DecodingError { return "corrupt" }
        if error is EncodingError { return "encoding" }
        let ns = error as NSError
        switch ns.domain {
        case NSURLErrorDomain: return urlCode(URLError.Code(rawValue: ns.code))
        case NSCocoaErrorDomain: return cocoaCode(ns.code)
        case NSPOSIXErrorDomain: return posixCode(Int32(ns.code))
        default: return classify(error.localizedDescription)
        }
    }

    /// The mail engine's own failures, typed from the server's status, response code and SMTP
    /// code: their kind decides the code, whatever words the server used.
    static func code(forFailure failure: MailServiceError) -> String {
        switch failure.kind {
        case .throttled: return "throttled"
        case .overBudget: return "dailyLimit"
        case .overUploadBudget: return "uploadLimit"
        case .tooManyConnections: return "tooManyConnections"
        case .webSignInRequired: return "webSignIn"
        case .connectionDropped: return "connectionClosed"
        case .needsSignIn: return "notSignedIn"
        case .messageGone: return "messageGone"
        case .folderGone: return "noMailbox"
        case .mailboxRenumbered: return "mailboxRebuilt"
        case .expungeRefused: return "expungeRefused"
        case .temporary: return "temporary"
        case .sendingLimit: return "sendingLimit"
        case .recipientRefused: return "recipientRejected"
        case .folderListUnreadable: return "folderListUnreadable"
        case .refused: return "serverRefused"
        // Something on this Mac, described by macOS or FalconMail rather than by a server.
        case .local: return classify(failure.detail) ?? "local"
        }
    }

    /// A Google API's refusal, from its HTTP status and reason code.
    static func code(forRefusal refusal: GoogleAPIError) -> String {
        switch refusal.kind {
        case .rateLimited: return "throttled"
        case .quotaExhausted: return "apiQuota"
        case .apiDisabled: return "apiDisabled"
        case .insufficientPermissions: return "noScope"
        case .needsSignIn: return "notSignedIn"
        case .clientRejected: return "clientRejected"
        case .notFound: return "messageGone"
        case .temporary: return "temporary"
        case .offline: return "offline"
        case .historyExpired: return "historyExpired"
        case .domainPolicy: return "domainPolicy"
        case .gmailNotEnabled: return "gmailNotEnabled"
        case .sendingLimit: return "sendingLimit"
        case .downloadLimit: return "downloadPaused"
        case .uploadLimit: return "uploadPaused"
        case .tooLarge: return "tooLarge"
        case .other: return refusal.httpStatus > 0 ? httpCode(refusal.httpStatus) : "serverRefused"
        }
    }

    static func isMailEngineError(_ error: any Error) -> Bool {
        switch error {
        case is IMAPServerError, is IMAPBye, is IMAPMailboxRenumbered, is IMAPMessageMissing, is IMAPNotSent,
             is IMAPAppendUnconfirmed, is IMAPExpungeRefused, is StreamStalled, is SMTPServerError:
            return true
        default:
            return false
        }
    }

    static func httpCode(_ status: Int) -> String {
        switch status {
        case 401: return "unauthorised"
        case 403: return "forbidden"
        case 404: return "notFound"
        case 408: return "timeout"
        case 413: return "tooLarge"
        case 429: return "tooManyRequests"
        case 500...599: return "serverError"
        default: return "clientError"
        }
    }

    static func urlCode(_ code: URLError.Code) -> String {
        switch code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return "offline"
        case .timedOut: return "timeout"
        case .cannotFindHost, .dnsLookupFailed: return "dns"
        case .cannotConnectToHost: return "refused"
        case .networkConnectionLost: return "connectionClosed"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected: return "tls"
        case .cancelled: return "cancelled"
        case .badServerResponse, .cannotParseResponse: return "badResponse"
        case .userAuthenticationRequired, .userCancelledAuthentication: return "auth"
        default: return "network"
        }
    }

    static func cocoaCode(_ code: Int) -> String {
        switch code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return "fileMissing"
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return "noPermission"
        case NSFileWriteOutOfSpaceError: return "diskFull"
        case NSFileReadCorruptFileError, NSPropertyListReadCorruptError, NSCoderReadCorruptError: return "corrupt"
        case NSUserCancelledError: return "cancelled"
        default: return "fileError"
        }
    }

    static func posixCode(_ code: Int32) -> String {
        switch code {
        case ECONNRESET: return "connectionReset"
        case ETIMEDOUT: return "timeout"
        case ECONNREFUSED: return "refused"
        case ENETUNREACH, EHOSTUNREACH, ENETDOWN: return "unreachable"
        case EPIPE, ENOTCONN: return "connectionClosed"
        case ENOSPC: return "diskFull"
        case EACCES, EPERM: return "noPermission"
        case ENOENT: return "fileMissing"
        default: return "systemError"
        }
    }

    /// Server replies and FalconMail's own messages, read for what they mean. The first rule
    /// that matches wins, so the more particular come first.
    private static let rules: [(code: String, phrases: [String])] = [
        ("throttled", ["bandwidth limit", "command or bandwidth", "too many simultaneous", "lockdown", "try again later",
                       "rate limit", "ratelimit", "too many requests", "[throttled]", "[limit]", "too many login"]),
        ("dailyLimit", ["safe download limit", "download limit", "downloaded today"]),
        ("appPassword", ["application-specific password", "app password"]),
        ("signInExpired", ["invalid_grant", "token has been expired", "expired or revoked"]),
        ("notSignedIn", ["not signed in", "needs to sign in"]),
        ("auth", ["authentication failed", "authenticationfailed", "invalid credentials", "username and password not accepted",
                  "login failed", "auth failed", "authentication unsuccessful", "bad credentials", "incorrect password",
                  "5.7.8", "5.7.9", "535 "]),
        ("quota", ["over quota", "overquota", "quota exceeded", "mailbox full", "mailbox is full"]),
        ("tooLarge", ["too large", "size exceeds", "message size", "exceeds the maximum"]),
        ("recipientRejected", ["recipient"]),
        ("messageRejected", ["message rejected", "rejected your message", "550 ", "552 ", "554 "]),
        ("tls", ["certificate", "tls", "ssl", "handshake"]),
        ("dns", ["could not be found", "nodename nor servname", "no such host", "host not found", "dns"]),
        ("offline", ["not connected to the internet", "offline", "network is down", "internet connection appears"]),
        ("unreachable", ["no route to host", "host is down", "network is unreachable", "could not connect", "cannot connect"]),
        ("timeout", ["timed out", "timeout", "took too long"]),
        ("refused", ["connection refused", "server refused connection"]),
        ("connectionReset", ["connection reset", "reset by peer"]),
        ("connectionClosed", ["connection closed", "closed by peer", "connection lost", "broken pipe", "server closed session",
                              "socket is not connected"]),
        ("noMailbox", ["trycreate", "no such mailbox", "mailbox doesn't exist", "mailbox does not exist", "unknown mailbox",
                       "folder missing"]),
        ("noTrash", ["no trash folder"]),
        ("mailboxRebuilt", ["rebuilt on the server", "uidvalidity"]),
        ("wrongPassword", ["wrong password", "password is incorrect", "decryption failed", "authentication tag"]),
        ("encrypted", ["encrypted"]),
        ("notConnected", ["not connected yet", "not running", "not connected"]),
        ("messageGone", ["no longer here", "not returned"]),
        ("noPermission", ["permission", "not permitted", "access denied", "not allowed"]),
        ("diskFull", ["no space", "disk full", "not enough space", "out of space"]),
        ("fileMissing", ["no such file", "doesn’t exist", "doesn't exist", "couldn’t be opened", "could not be opened"]),
        ("corrupt", ["correct format", "corrupt", "damaged", "could not be decoded", "couldn’t be read", "unreadable"]),
        ("cancelled", ["cancelled", "canceled"]),
        ("protocol", ["unexpected response", "bad command", "protocol error", "parse"]),
    ]

    static func classify(_ message: String) -> String? {
        let text = message.lowercased()
        guard !text.isEmpty else { return nil }
        for rule in rules where rule.phrases.contains(where: { text.contains($0) }) {
            if rule.code == "recipientRejected", !(text.contains("rejected") || text.contains("refused") || text.contains("unknown")) {
                continue
            }
            return rule.code
        }
        if let status = text.range(of: #"\bhttp (\d{3})\b"#, options: .regularExpression)
            .flatMap({ Int(text[$0].dropFirst(5)) }) {
            return httpCode(status)
        }
        return nil
    }

    static func typeName(of error: any Error) -> String {
        let ns = error as NSError
        let name = String(describing: type(of: error))
        return name == "NSError" || name.hasPrefix("__") ? word(ns.domain) : word(name)
    }

    /// The first words of a message nobody has classified yet, as a stable key: numbers,
    /// quoted text and references are gone, so every occurrence reads alike.
    static func shape(of message: String) -> String {
        let cleaned = DiagnosticsRedactor.blankingQuoted(message)
            .replacingOccurrences(of: #"<[^<>]*>"#, with: " ", options: .regularExpression)
        let words = cleaned.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count > 1 }.prefix(5)
        guard let first = words.first else { return "unknown" }
        let rest = words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
        return word(first.lowercased() + rest.joined())
    }

    // MARK: Crashes

    static let exceptionNames: [Int64: String] = [
        1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC", 4: "EXC_EMULATION", 5: "EXC_SOFTWARE",
        6: "EXC_BREAKPOINT", 7: "EXC_SYSCALL", 8: "EXC_MACH_SYSCALL", 9: "EXC_RPC_ALERT", 10: "EXC_CRASH",
        11: "EXC_RESOURCE", 12: "EXC_GUARD", 13: "EXC_CORPSE_NOTIFY",
    ]

    static let signalNames: [Int64: String] = [
        1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 7: "SIGEMT", 8: "SIGFPE",
        9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV", 12: "SIGSYS", 13: "SIGPIPE", 14: "SIGALRM", 15: "SIGTERM",
    ]

    /// `EXC_BAD_ACCESS.SIGSEGV`, the code of a crash.
    public static func crashCode(exception: String?, signal: String?) -> String {
        let parts = [exception, signal].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "unknown" : parts.joined(separator: ".")
    }

    /// Frames every crash passes through on its way down: raising, aborting, trapping.
    /// The first frame outside them is where the crash is worth grouping by.
    static let machineryImages: Set<String> = [
        "libsystem_kernel.dylib", "libsystem_pthread.dylib", "libsystem_c.dylib", "libc++abi.dylib",
        "libobjc.A.dylib", "libswiftCore.dylib", "CoreFoundation", "libdispatch.dylib", "libsystem_platform.dylib",
        "libsystem_malloc.dylib", "libdyld.dylib", "dyld",
    ]
}

// MARK: - Titles

/// A short sentence someone who does not program understands, the same for every event of
/// one signature: it is built only from the area, the code and the kind, never from the
/// message, so no number or reference can reach it.
public enum DiagnosticsTitle {
    public static func make(kind: DiagnosticsKind, area: String, code: String) -> String {
        let title: String
        switch kind {
        case .crash: title = crashSentence(code)
        case .hang: title = "FalconMail stopped responding for a while"
        case .cpu: title = "FalconMail kept the processor busy for a long time"
        case .diskwrite: title = "FalconMail wrote an unusually large amount to disk"
        case .health: title = "Daily health report"
        case .launch: title = code == "unclean" ? "FalconMail started again after it quit unexpectedly" : "FalconMail started"
        case .error, .warning: title = failureTitle(area: area, code: code)
        }
        return String(title.prefix(DiagnosticsEvent.maxTitle))
    }

    private static func failureTitle(area: String, code: String) -> String {
        let a = area.lowercased()
        if let special = specials[a + "." + code] { return special }
        let reason = reasons[code] ?? "something unexpected went wrong"
        if a == "alert" { return "FalconMail showed an error: \(reason)" }
        return "\(activity(a)) failed: \(reason)"
    }

    private static let specials: [String: String] = [
        "imap.throttled": "The mail server paused the connection: too many requests",
        "imap.tooManyConnections": "The mail server refused a connection: other apps were using all it allows",
        "imap.dailyLimit": "Downloads paused: today's safe download limit was reached",
        "imap.uploadLimit": "Uploads paused: today's safe upload limit was reached",
        "imap.webSignIn": "The mail server wants a sign-in in a web browser first",
        "sync.dailyLimit": "Offline copies paused: today's safe download limit was reached",
        "sync.folderListUnreadable": "Syncing stopped: the folder list kept on this Mac could not be read",
        "store.setAside": "A file FalconMail keeps could not be read, so it was set aside and kept",
        "store.stillSetAside": "A file FalconMail set aside earlier still waits to be looked at",
        "store.unreadable": "A file FalconMail keeps could not be read",
        "store.journalLinesSkipped": "Some lines of a folder's saved list could not be read and were skipped",
        "outbox.interrupted": "A message was being sent when FalconMail stopped, so it is held in the Outbox",
        "smtp.sendingLimit": "Sending a message failed: the daily sending limit was reached, so it is held in the Outbox",
        "archive.expungeRefused": "Archived mail was kept on the server: another message there was marked for deletion",
        "archive.mailboxRebuilt": "Archived mail was kept on the server: the folder was rebuilt while it was archived",
        "oauth.unknownClient": "Google sign-in must be renewed: it was made by a FalconMail this one cannot renew",
        "smtp.auth": "Sending a message failed: the server refused the password",
        "smtp.notSignedIn": "Sending a message failed: the account needs to sign in again",
        "imap.auth": "Checking for new mail failed: the server refused the password",
        "imap.notSignedIn": "Checking for new mail failed: the account needs to sign in again",
        "oauth.signInExpired": "Google sign-in expired and needs to be renewed",
        "oauth.notSignedIn": "Google sign-in expired and needs to be renewed",
    ]

    private static func activity(_ area: String) -> String {
        switch area {
        case "imap", "sync": return "Checking for new mail"
        case "smtp", "send": return "Sending a message"
        case "actions", "action": return "Changing messages on the server"
        case "rules": return "Applying a rule"
        case "mute": return "Filing a muted conversation"
        case "archive": return "Archiving mail"
        case "import": return "Importing mail"
        case "export": return "Exporting mail"
        case "drafts": return "Saving a draft"
        case "signin", "auth", "oauth": return "Signing in"
        case "contacts": return "Syncing contacts"
        case "calendar": return "Using the calendar"
        case "update": return "Updating FalconMail"
        case "install": return "Moving FalconMail to Applications"
        case "signatures": return "Loading signatures"
        case "store", "storage": return "Saving mail on this Mac"
        case "net": return "Connecting to the server"
        case "drive": return "Using Google Drive"
        case "open": return "Opening a message"
        case "search": return "Searching on the server"
        case "outbox": return "Saving the Outbox"
        case "folders": return "Creating a folder"
        case "older": return "Loading older messages"
        case "save": return "Saving a message on the server"
        default: return "A task in FalconMail"
        }
    }

    private static let reasons: [String: String] = [
        "throttled": "the server asked FalconMail to slow down",
        "dailyLimit": "today's safe download limit was reached",
        "appPassword": "the server wants an app password",
        "signInExpired": "the sign-in has expired",
        "notSignedIn": "the account needs to sign in again",
        "auth": "the server refused the password or sign-in",
        "quota": "the mailbox is full",
        "tooLarge": "it was too large",
        "recipientRejected": "the server refused a recipient",
        "messageRejected": "the server refused the message",
        "tls": "the secure connection failed",
        "dns": "the server's name could not be found",
        "offline": "this Mac is offline",
        "unreachable": "the server could not be reached",
        "timeout": "the server took too long to answer",
        "refused": "the server refused the connection",
        "connectionReset": "the connection dropped",
        "connectionClosed": "the connection dropped",
        "network": "a network problem",
        "noMailbox": "a folder is missing on the server",
        "noTrash": "the account has no Trash folder",
        "mailboxRebuilt": "the folder was rebuilt on the server",
        "wrongPassword": "the password was wrong",
        "encrypted": "it needs a password",
        "notConnected": "the account was not connected yet",
        "messageGone": "the message was no longer there",
        "noPermission": "FalconMail was not allowed to use a file",
        "diskFull": "this Mac is out of disk space",
        "fileMissing": "a file was missing",
        "corrupt": "some data was damaged or unreadable",
        "encoding": "some data could not be saved",
        "fileError": "a file could not be read or written",
        "systemError": "macOS reported an error",
        "cancelled": "it was cancelled",
        "protocol": "the server gave an unexpected answer",
        "badResponse": "the server gave an unexpected answer",
        "unauthorised": "the server did not accept the sign-in",
        "forbidden": "the server refused access",
        "notFound": "the server could not find what was asked for",
        "tooManyRequests": "too many requests",
        "serverError": "the server had a problem",
        "clientError": "the server rejected the request",
        "storage": "saving on this Mac failed",
        "invalidInput": "a setting or value was not accepted",
        "uploadLimit": "today's safe upload limit was reached",
        "tooManyConnections": "other apps were using all the connections the server allows",
        "webSignIn": "the server wants a sign-in in a web browser first",
        "expungeRefused": "another message in the folder was marked for deletion",
        "temporary": "the server had a temporary problem",
        "sendingLimit": "the daily sending limit was reached",
        "folderListUnreadable": "the folder list kept on this Mac could not be read",
        "serverRefused": "the server refused the request",
        "local": "something on this Mac went wrong",
        "apiQuota": "today's Gmail allowance was used up",
        "apiDisabled": "the Gmail API is switched off for FalconMail",
        "noScope": "FalconMail was not given permission to use Gmail",
        "clientRejected": "Google did not accept FalconMail's sign-in",
        "setAside": "a file could not be read, so it was set aside",
        "stillSetAside": "a file set aside earlier still waits to be looked at",
        "unreadable": "a file could not be read",
        "interrupted": "FalconMail stopped while it was under way",
        "journalLinesSkipped": "some saved lines could not be read",
        "unknownClient": "the sign-in was made by a FalconMail this one cannot renew",
    ]

    /// The plain sentence for a crash of this code, which `CrashIdentity` adds its details to.
    static func crashSentence(_ code: String) -> String {
        let parts = Set(code.split(separator: ".").map(String.init))
        if parts.contains("EXC_BAD_ACCESS") || parts.contains("SIGSEGV") || parts.contains("SIGBUS") {
            return "FalconMail crashed: it used memory it should not have"
        }
        if parts.contains("EXC_BREAKPOINT") || parts.contains("EXC_BAD_INSTRUCTION") || parts.contains("SIGTRAP") || parts.contains("SIGILL") {
            return "FalconMail crashed: a safety check in its code failed"
        }
        if parts.contains("SIGABRT") { return "FalconMail crashed: it stopped itself after an internal error" }
        if parts.contains("EXC_RESOURCE") { return "FalconMail was stopped for using too many resources" }
        if parts.contains("EXC_GUARD") { return "FalconMail crashed: it misused a protected system resource" }
        if parts.contains("EXC_ARITHMETIC") || parts.contains("SIGFPE") { return "FalconMail crashed: a calculation went wrong" }
        if parts.contains("SIGKILL") { return "FalconMail was stopped by macOS" }
        return "FalconMail crashed"
    }
}
