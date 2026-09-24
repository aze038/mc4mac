import Foundation

/// A tagged NO or BAD, kept whole so that what went wrong is decided from the server's own
/// response code rather than from any sentence written for a person.
public struct IMAPServerError: Error, LocalizedError, Sendable, Equatable {
    public var status: IMAPStatus
    /// The bracketed response code, such as `AUTHENTICATIONFAILED` or `WEBALERT https://…`.
    public var code: String?
    public var text: String
    /// The command's name only. Its arguments can carry a password or a token.
    public var command: String
    public var mailbox: String?

    public init(status: IMAPStatus, code: String?, text: String, command: String, mailbox: String? = nil) {
        self.status = status
        self.code = code
        self.text = text
        self.command = command
        self.mailbox = mailbox
    }

    /// The code's first word, upper-cased.
    public var codeName: String? {
        code?.split(separator: " ").first.map { $0.uppercased() }
    }

    public var errorDescription: String? { "The mail server refused the request." }
}

/// An untagged BYE: the server has ended the session, whether or not it closes the socket.
public struct IMAPBye: Error, LocalizedError, Sendable, Equatable {
    public var code: String?
    public var text: String

    public init(code: String?, text: String) {
        self.code = code
        self.text = text
    }

    public var codeName: String? {
        code?.split(separator: " ").first.map { $0.uppercased() }
    }

    public var errorDescription: String? { "The mail server ended the connection." }
}

/// A mailbox whose UIDVALIDITY is no longer the one its UIDs were read under: every UID from
/// before would now name some other message, so the work was not done.
public struct IMAPMailboxRenumbered: Error, LocalizedError, Sendable, Equatable {
    public var mailbox: String
    public var expected: UInt32
    public var found: UInt32

    public var errorDescription: String? { "The mailbox was rebuilt on the server, so that no longer applies." }
}

/// A UID FETCH that came back without the message: it has been moved or deleted since.
public struct IMAPMessageMissing: Error, LocalizedError, Sendable, Equatable {
    public var mailbox: String?
    public var uid: UInt32

    public var errorDescription: String? { "This message was moved or deleted on the server." }
}

/// Deleting for good was refused because the server can only purge every message marked for
/// deletion at once, and others besides these were marked.
public struct IMAPExpungeRefused: Error, LocalizedError, Sendable, Equatable {
    public var mailbox: String?
    /// Messages marked for deletion that were not ours to purge.
    public var others: [UInt32]

    public var errorDescription: String? {
        "Nothing was deleted: another message in this folder is marked for deletion, and this server can only delete them all at once."
    }
}
