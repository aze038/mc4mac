import Foundation
import CryptoKit

/// Closing and discarding a message that has not been sent, the owner's way rather than Legacy
/// Outlook's: closing never asks and keeps whatever was written in the Drafts folder, and only
/// Discard throws a message away, with a short while to take that back.
public enum UnsentMessage {
    /// How a message came to be open for writing, which decides whether closing it as it was
    /// opened would lose anything.
    public enum Origin: Sendable, CaseIterable {
        /// A new message, from New Message, a mailto link or the Compose key.
        case new
        /// A reply or a forward, whose quoted original and addresses the message it answers
        /// still holds.
        case reply
        /// A draft opened again from the Drafts folder, which keeps its copy there.
        case reopenedDraft
        /// A send called back from the Outbox, of which there is no other copy anywhere.
        case outboxRecall
        /// A discarded message brought back by Undo, whose stored copies went with it.
        case undoneDiscard

        /// Whether the message as it was opened is held somewhere else too, or holds nothing
        /// anyone wrote, so that closing it unchanged loses nothing.
        public var remembersOpening: Bool {
            switch self {
            case .new, .reply, .reopenedDraft: return true
            case .outboxRecall, .undoneDiscard: return false
            }
        }
    }

    public enum Closing: Equatable, Sendable {
        /// Close and keep nothing of it: it has nothing in it, or it is as it was opened, which a
        /// fresh message, the message it answers or its copy in Drafts still holds.
        case closeQuietly
        /// Close and keep it in the Drafts folder, without asking.
        case saveToDrafts
    }

    /// What closing a message does. `openedDigest` is its `fingerprint` as it was opened, nil
    /// when nothing else holds it; `digest` is its fingerprint now.
    public static func closing(openedDigest: String?, digest: String, blank: Bool) -> Closing {
        if blank { return .closeQuietly }
        if let openedDigest, openedDigest == digest { return .closeQuietly }
        return .saveToDrafts
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

    /// The stored copy in Drafts that goes when a message is saved again, sent or discarded: the
    /// row it was reopened from, and only while that row is the one it recorded. A draft kept by
    /// an earlier build recorded no row, and its copy is left where it is. Whether the row's UID
    /// still names that message, after Drafts was renumbered, the store answers.
    public static func draftCopy(openedFrom row: MessageSummary?, recordedID: String?) -> MessageSummary? {
        guard let row, row.id == recordedID else { return nil }
        return row
    }
}

/// The message discarded last, held in memory so that Undo can bring it back into a compose
/// window for a short while. Only the last is held: discarding another lets the first go.
public struct DiscardedMessage<Draft: Sendable>: Sendable {
    /// How long Undo is offered, as long as Outlook's banner stays.
    public static var undoWindow: TimeInterval { 10 }

    public struct Held: Sendable, Identifiable {
        public let id: UUID
        public let draft: Draft
        public let until: Date
    }

    public private(set) var held: Held?

    public init() {}

    /// Holds `draft`, discarded at `now`, until Undo is no longer offered for it.
    @discardableResult
    public mutating func discard(_ draft: Draft, now: Date) -> Held {
        let held = Held(id: UUID(), draft: draft, until: now.addingTimeInterval(Self.undoWindow))
        self.held = held
        return held
    }

    /// Whether Undo is still offered at `now`.
    public func offersUndo(at now: Date) -> Bool {
        guard let held else { return false }
        return now < held.until
    }

    /// The message to open again, or nil when there is none or its time is up; either way it is
    /// no longer held.
    public mutating func undo(at now: Date) -> Draft? {
        defer { held = nil }
        guard let held, now < held.until else { return nil }
        return held.draft
    }

    /// Lets go of the message held as `id`, as when its banner goes; one discarded since stays.
    public mutating func letGo(_ id: UUID) {
        guard held?.id == id else { return }
        held = nil
    }
}
