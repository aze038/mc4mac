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

public enum AccountProbe {
    public static func test(_ s: CustomServerSettings) async throws {
        let imap = IMAPClient(host: s.imapHost, port: s.imapPort)
        do {
            try await imap.connect()
            try await imap.login(user: s.username, password: s.password)
            await imap.logout()
        } catch {
            throw FalconError.invalidInput("Incoming mail (IMAP \(s.imapHost):\(s.imapPort)): \(probeSentence(error, settings: s))")
        }
        let smtp = SMTPClient(host: s.smtpHost, port: s.smtpPort)
        do {
            try await smtp.connect()
            try await smtp.authenticatePlain(user: s.username, password: s.password)
            await smtp.quit()
        } catch {
            throw FalconError.invalidInput("Outgoing mail (SMTP \(s.smtpHost):\(s.smtpPort)): \(probeSentence(error, settings: s))")
        }
    }

    /// Setting up an account, a refused sign-in is a wrong name or password rather than one to
    /// sign in again, and the server's own words help put it right.
    static func probeSentence(_ error: Error, settings s: CustomServerSettings) -> String {
        let failure = MailServiceError.classify(error, email: s.username, isGoogle: false)
        Log.info("probe", "\(s.imapHost): \(failure.kind.rawValue): \(Log.redacted(failure.detail, keeping: s.username))")
        switch failure.kind {
        case .needsSignIn: return "the server did not accept the user name or password."
        case .connectionDropped: return "the server could not be reached."
        default: return failure.sentence
        }
    }
}
