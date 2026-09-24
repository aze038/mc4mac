import Foundation
import CryptoKit

/// Closing a message that has not been sent, the way Legacy Outlook closes one: straight away
/// when nothing in it would be lost, otherwise only once the alert has been answered.
public enum UnsentMessage {
    public static let alertTitle = "You are closing a message that has not been sent."
    public static let alertMessage = "To save the message, click Save as Draft. The message will be saved in your Drafts folder."

    /// The alert's buttons, top to bottom as Outlook stacks them.
    public enum Choice: CaseIterable, Sendable {
        case saveAsDraft, discardChanges, continueWriting

        public var title: String {
            switch self {
            case .saveAsDraft: return "Save as Draft"
            case .discardChanges: return "Discard Changes"
            case .continueWriting: return "Continue Writing"
            }
        }

        /// Return saves, as the blue default button does; Escape goes back to the message.
        public var keyEquivalent: String {
            switch self {
            case .saveAsDraft: return "\r"
            case .discardChanges: return ""
            case .continueWriting: return "\u{1b}"
            }
        }

        /// Whether the window or tab closes once this is chosen.
        public var closes: Bool { self != .continueWriting }

        /// Whether what was written goes on to the Drafts folder as closing always sent it.
        public var keepsDraft: Bool { self == .saveAsDraft }
    }

    public enum Closing: Equatable, Sendable {
        /// Close without asking and keep nothing of this window: the message is as it was
        /// opened, which a fresh message or its copy in Drafts still holds, or has nothing in it.
        case discardQuietly
        /// Put the alert up and do what its answer says.
        case ask
    }

    public static func closing(untouched: Bool, blank: Bool) -> Closing {
        untouched || blank ? .discardQuietly : .ask
    }

    /// A digest of a message's content, compared with the one taken when it was opened to tell
    /// whether anything has been written since. Each part is counted in with its length, so
    /// text moved from one field to the next still reads as a change.
    public static func fingerprint(_ parts: [Data]) -> String {
        var hasher = SHA256()
        for part in parts {
            withUnsafeBytes(of: UInt64(part.count).littleEndian) { hasher.update(bufferPointer: $0) }
            hasher.update(data: part)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
