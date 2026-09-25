import Foundation

public struct CustomServerSettings: Sendable, Hashable {
    public var imapHost: String
    public var imapPort: UInt16
    public var smtpHost: String
    public var smtpPort: UInt16
    public var username: String
    public var password: String

    public init(imapHost: String, imapPort: UInt16 = 993, smtpHost: String, smtpPort: UInt16 = 465, username: String, password: String) {
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.username = username
        self.password = password
    }

    public static func guess(for email: String) -> CustomServerSettings {
        let domain = email.split(separator: "@").last.map(String.init)?.lowercased() ?? ""
        switch domain {
        case "gmail.com", "googlemail.com":
            return CustomServerSettings(imapHost: "imap.gmail.com", smtpHost: "smtp.gmail.com", username: email, password: "")
        case "outlook.com", "hotmail.com", "live.com", "msn.com":
            return CustomServerSettings(imapHost: "outlook.office365.com", smtpHost: "smtp.office365.com", smtpPort: 587, username: email, password: "")
        case "yahoo.com":
            return CustomServerSettings(imapHost: "imap.mail.yahoo.com", smtpHost: "smtp.mail.yahoo.com", username: email, password: "")
        case "icloud.com", "me.com", "mac.com":
            return CustomServerSettings(imapHost: "imap.mail.me.com", smtpHost: "smtp.mail.me.com", smtpPort: 587, username: email, password: "")
        default:
            return CustomServerSettings(imapHost: "imap.\(domain)", smtpHost: "smtp.\(domain)", username: email, password: "")
        }
    }

    public static func looksLikeGoogle(_ email: String) -> Bool {
        let domain = email.split(separator: "@").last.map(String.init)?.lowercased() ?? ""
        return domain == "gmail.com" || domain == "googlemail.com"
    }
}

/// A server setting that did not work, in the words shown while an account is set up, with
/// the failure's kind kept for diagnostics.
public struct AccountProbeFailure: Error, LocalizedError, Sendable {
    public var failure: MailServiceError
    /// What the owner is shown, naming the account by its user name.
    public var message: String
    /// The same sentence with the user name left out, for the log and diagnostics: a user name
    /// that is not an address, such as kmuradov, is nothing the redactor would know to take out.
    public var logMessage: String

    public var errorDescription: String? { message }
}

public enum AccountProbe {
    /// What a new account set up on Google's own IMAP or SMTP servers is told. Google accounts are
    /// signed in with Google and use the Gmail API, never IMAP or SMTP, so none is checked there.
    public static let useGoogleSignIn = "Gmail and Google Workspace accounts are added with Sign in with Google, which uses the Gmail API "
        + "rather than IMAP. Choose Google instead."

    /// Whether the settings name Google's own IMAP or SMTP servers.
    public static func namesGoogleServers(_ s: CustomServerSettings) -> Bool {
        TransportGuard.isGoogleHost(s.imapHost) || TransportGuard.isGoogleHost(s.smtpHost)
    }

    /// Signs in to the servers once to see that the settings work. A new account set up on
    /// Google's servers is refused before anything is sent: it is added with Sign in with Google
    /// instead. `existingAccount` is for a password renewed on an account added that way before
    /// this build, which stays on IMAP until the owner signs in with Google.
    public static func test(_ s: CustomServerSettings, existingAccount: Bool = false) async throws {
        if namesGoogleServers(s), !existingAccount {
            Log.info("probe", "\(s.imapHost): not checked: a Google account is added with Sign in with Google")
            throw AccountProbeFailure(failure: MailServiceError(kind: .local, email: s.username, isGoogle: true, detail: useGoogleSignIn),
                                      message: useGoogleSignIn, logMessage: useGoogleSignIn)
        }
        let imap = IMAPClient(host: s.imapHost, port: s.imapPort, user: s.username)
        do {
            try await imap.connect()
            try await imap.login(user: s.username, password: s.password)
            await imap.logout()
        } catch {
            throw failure(error, settings: s, "Incoming mail (IMAP \(s.imapHost):\(s.imapPort))")
        }
        let smtp = SMTPClient(host: s.smtpHost, port: s.smtpPort, user: s.username)
        do {
            try await smtp.connect()
            try await smtp.authenticatePlain(user: s.username, password: s.password)
            await smtp.quit()
        } catch {
            throw failure(error, settings: s, "Outgoing mail (SMTP \(s.smtpHost):\(s.smtpPort))")
        }
    }

    /// What to write to the log and diagnostics about a failed check of an account's settings:
    /// a probe's sentence without the user name, or any other error's description.
    public static func logDescription(of error: Error) -> String {
        (error as? AccountProbeFailure)?.logMessage ?? error.localizedDescription
    }

    static func failure(_ error: Error, settings s: CustomServerSettings, _ side: String) -> AccountProbeFailure {
        let failure = MailServiceError.classify(error, email: s.username, isGoogle: false)
        Log.info("probe", "\(s.imapHost): \(failure.kind.rawValue): \(Log.redacted(failure.detail, keeping: s.username))")
        var unnamed = failure
        unnamed.email = "the account"
        return AccountProbeFailure(failure: failure, message: "\(side): \(probeSentence(failure))",
                                   logMessage: "\(side): \(probeSentence(unnamed))")
    }

    /// Setting up an account, a refused sign-in is a wrong name or password rather than one to
    /// sign in again, and the server's own words help put it right.
    static func probeSentence(_ failure: MailServiceError) -> String {
        switch failure.kind {
        case .needsSignIn: return "the server did not accept the user name or password."
        case .connectionDropped: return "the server could not be reached."
        default: return failure.sentence
        }
    }
}
