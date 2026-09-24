import Foundation

public enum LogLevel: String, Sendable {
    case warning, error
}

/// One warning or error line, as the diagnostics centre receives it. Info lines never become one.
public struct LogRecord: Sendable {
    public let level: LogLevel
    public let area: String
    public let message: String
    public let error: (any Error)?
    public let account: AccountInfo?
    public let file: String
    public let line: Int
    public let date: Date

    public init(level: LogLevel, area: String, message: String, error: (any Error)? = nil, account: AccountInfo? = nil,
                file: String, line: Int, date: Date = Date()) {
        self.level = level
        self.area = area
        self.message = message
        self.error = error
        self.account = account
        self.file = file
        self.line = line
        self.date = date
    }
}

extension Log {
    private static let observerLock = NSLock()
    private static var storedObserver: (@Sendable (LogRecord) -> Void)?

    /// Receives every warning and error. Called on the logging thread, so it must hand the
    /// record off rather than do work there.
    public static var observer: (@Sendable (LogRecord) -> Void)? {
        get { observerLock.withLock { storedObserver } }
        set { observerLock.withLock { storedObserver = newValue } }
    }

    /// Something went wrong but FalconMail carried on, such as a paused connection.
    public static func warning(_ area: String, _ message: @autoclosure () -> String, error: (any Error)? = nil,
                               account: AccountInfo? = nil, file: String = #fileID, line: Int = #line) {
        emit(.warning, area, message(), error, account, file, line)
    }

    /// Something failed that the person may notice.
    public static func error(_ area: String, _ message: @autoclosure () -> String, error: (any Error)? = nil,
                             account: AccountInfo? = nil, file: String = #fileID, line: Int = #line) {
        emit(.error, area, message(), error, account, file, line)
    }

    private static func emit(_ level: LogLevel, _ area: String, _ message: String, _ error: (any Error)?,
                             _ account: AccountInfo?, _ file: String, _ line: Int) {
        info(area, "\(level.rawValue): \(message)")
        observer?(LogRecord(level: level, area: area, message: message, error: error, account: account, file: file, line: line))
    }
}
