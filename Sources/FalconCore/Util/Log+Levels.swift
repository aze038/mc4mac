import Foundation

public enum LogLevel: String, Sendable {
    case warning, error
}

/// One warning or error, as the diagnostics centre receives it. Info lines never become one,
/// so nothing the engine writes only to its own log, such as a server's reply or a folder's
/// name in a line about a pass, ever reaches the centre.
public struct LogRecord: Sendable {
    public let level: LogLevel
    public let area: String
    public let message: String
    public let error: (any Error)?
    public let account: AccountInfo?
    /// What kind of failure this was, where the caller knows it better than the error does,
    /// such as a file set aside. Otherwise the centre works it out from `error`.
    public let code: String?
    /// Folder and file names the message holds. The redactor takes each of them out wherever
    /// it stands, whether or not it knew the name already, a short one such as HR included.
    public let names: [String]
    /// Plain facts beside the message, such as the account's status, for the event's context.
    public let details: [String: String]
    public let file: String
    public let function: String
    public let line: Int
    public let date: Date

    public init(level: LogLevel, area: String, message: String, error: (any Error)? = nil, account: AccountInfo? = nil,
                code: String? = nil, names: [String] = [], details: [String: String] = [:],
                file: String, function: String, line: Int, date: Date = Date()) {
        self.level = level
        self.area = area
        self.message = message
        self.error = error
        self.account = account
        self.code = code
        self.names = names
        self.details = details
        self.file = file
        self.function = function
        self.line = line
        self.date = date
    }
}

extension Log {
    private static let observerLock = NSLock()
    private static var storedObserver: (@Sendable (LogRecord) -> Void)?

    /// Receives every warning and error, and nothing else. Called on the logging thread, so it
    /// must hand the record off rather than do work there.
    public static var observer: (@Sendable (LogRecord) -> Void)? {
        get { observerLock.withLock { storedObserver } }
        set { observerLock.withLock { storedObserver = newValue } }
    }

    /// Something went wrong but FalconMail carried on, such as a paused connection.
    ///
    /// The line goes into the log file as `[area] warning: message`, with every address but the
    /// account's own taken out. `logAs` is for a line the engine has always written to its log
    /// about this failure: it is written exactly as before, under that area and without a
    /// level, with every address but `keeping` taken out when that is given, as the engine's
    /// lines about a server's reply always have been. Diagnostics gets the message whole, so
    /// that its own redactor sees everything, the name written beside an address included.
    public static func warning(_ area: String, _ message: @autoclosure () -> String, error: (any Error)? = nil,
                               account: AccountInfo? = nil, code: String? = nil, names: [String] = [],
                               details: [String: String] = [:], logAs engineArea: String? = nil, keeping own: String? = nil,
                               file: String = #fileID, function: String = #function, line: Int = #line) {
        emit(LogRecord(level: .warning, area: area, message: message(), error: error, account: account, code: code,
                       names: names, details: details, file: file, function: function, line: line), logAs: engineArea, keeping: own)
    }

    /// Something failed that the person may notice. Written as `warning` describes.
    public static func error(_ area: String, _ message: @autoclosure () -> String, error: (any Error)? = nil,
                             account: AccountInfo? = nil, code: String? = nil, names: [String] = [],
                             details: [String: String] = [:], logAs engineArea: String? = nil, keeping own: String? = nil,
                             file: String = #fileID, function: String = #function, line: Int = #line) {
        emit(LogRecord(level: .error, area: area, message: message(), error: error, account: account, code: code,
                       names: names, details: details, file: file, function: function, line: line), logAs: engineArea, keeping: own)
    }

    /// A failure the mail engine met, as a warning or an error by what kind of failure it is
    /// (see `MailServiceError.logLevel`) unless `level` says otherwise. Its signature and title
    /// come from that kind, never from the server's words, which reach diagnostics only in the
    /// message, redacted there. Written as `warning` describes.
    public static func failure(_ area: String, _ failure: MailServiceError, _ message: @autoclosure () -> String,
                               level: LogLevel? = nil, account: AccountInfo? = nil, names: [String] = [],
                               details: [String: String] = [:], logAs engineArea: String? = nil, keeping own: String? = nil,
                               file: String = #fileID, function: String = #function, line: Int = #line) {
        emit(LogRecord(level: level ?? failure.logLevel, area: area, message: message(), error: failure, account: account,
                       names: names, details: details, file: file, function: function, line: line), logAs: engineArea, keeping: own)
    }

    private static func emit(_ record: LogRecord, logAs engineArea: String?, keeping own: String?) {
        if let engineArea {
            info(engineArea, own.map { redacted(record.message, keeping: $0) } ?? record.message)
        } else {
            info(record.area, "\(record.level.rawValue): \(redacted(record.message, keeping: own ?? record.account?.email ?? ""))")
        }
        observer?(record)
    }
}

extension MailServiceError {
    /// A warning when the failure passes by itself, or only says that the server changed under
    /// FalconMail, which then brings the folder up to date; an error when what the owner asked
    /// for did not happen, or the account waits for them.
    public var logLevel: LogLevel {
        switch kind {
        case .throttled, .overBudget, .overUploadBudget, .tooManyConnections, .connectionDropped, .temporary,
             .messageGone, .mailboxRenumbered:
            return .warning
        case .webSignInRequired, .needsSignIn, .folderGone, .expungeRefused, .sendingLimit, .recipientRefused,
             .folderListUnreadable, .local, .refused:
            return .error
        }
    }
}

extension AccountHealth {
    /// The status in one word, without the time a pause ends, for a diagnostics event's context.
    public var diagnosticsName: String {
        switch self {
        case .connecting: return "connecting"
        case .online: return "online"
        case .offline: return "offline"
        case .imapPaused: return "imapPaused"
        case .needsSignIn: return "needsSignIn"
        case .blocked: return "blocked"
        }
    }
}
