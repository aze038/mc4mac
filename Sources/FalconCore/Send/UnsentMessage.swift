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
        /// A discarded message brought back by Undo. Its copy on this Mac went with Discard, and
        /// the copy in Drafts it is still linked to may be older than what was written.
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

    /// The message already open to be written from the row `rowID` in Drafts, among `open` as
    /// (draft, the row it was reopened from). Opening that row again brings it forward rather
    /// than a second copy, since each copy closed would add its own to Drafts.
    public static func alreadyOpen(row rowID: String, among open: [(draft: UUID, row: String?)]) -> UUID? {
        open.first { $0.row == rowID }?.draft
    }
}

/// The messages being written that FalconMail keeps on this Mac, one file each in `<data>/Drafts`,
/// and the discarded ones whose copy in the Drafts folder is still to go. The owner's rule is
/// that closing a message saves it to Drafts without asking and only Discard throws it away, so
/// neither may ever leave a message nowhere, nor bring back one thrown away.
///
/// - `<id>.json` holds a message open to be written, or one closed and on its way to Drafts. It
///   goes only once the server has the message, so a quit or a crash before the server answers
///   leaves it for the next launch, which saves it then, once. The file keeps the message's link
///   to its copy in Drafts, if it has one, so that save replaces that copy rather than adding one.
/// - `<id>.discarded` marks a message discarded whose copy in Drafts, `Copy`, is still to be
///   deleted. The copy stays while Undo is offered, and Undo takes the marker away, so the
///   message comes back still linked to it. Once Undo is over the copy is deleted, or at a quit
///   if that comes first, or at the next launch if the quit could not; the message never comes
///   back. Earlier builds read only the `.json` files, so they pass the marker by.
@MainActor
public final class UnsentDrafts<Draft: Codable & Sendable & Identifiable, Copy: Codable & Sendable> where Draft.ID == UUID {
    public let directory: URL
    /// Whether a message is open to be written again, as after its save failed, so that its file
    /// stays when a save of an earlier version of it finishes.
    public var isOpen: @MainActor (UUID) -> Bool = { _ in false }
    /// Deletes a discarded message's copy in Drafts, returning once the delete is sure to happen.
    /// Throwing keeps the marker, to try again at the quit or the next launch.
    public var deleteCopy: @MainActor (Copy) async throws -> Void = { _ in }

    private struct Marker: Codable {
        var id: UUID
        var copy: Copy
        var discardedAt: Date
    }

    private var saving: [UUID: (turn: Int, task: Task<(any Error)?, Never>)] = [:]
    private var turns = 0
    private var deleting: [UUID: Task<Void, Never>] = [:]

    public init(directory: URL) {
        self.directory = directory
    }

    private func fileURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    private func markerURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".discarded") }

    private func files(_ pathExtension: String) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.pathExtension == pathExtension }
    }

    private func markers() -> [Marker] {
        files("discarded").compactMap { AtomicFile.readJSON(Marker.self, from: $0) }
    }

    // MARK: Messages being written

    /// Keeps `draft` on this Mac as it is now.
    public func keep(_ draft: Draft) {
        try? AtomicFile.writeJSON(draft, to: fileURL(draft.id))
    }

    /// Lets go of a message no longer being written. Its file stays while a save of it is under
    /// way, until the server has it.
    public func forget(_ id: UUID) {
        guard saving[id] == nil else { return }
        try? FileManager.default.removeItem(at: fileURL(id))
    }

    /// What the last session left on this Mac: messages open at the quit, and those closed whose
    /// save the server never confirmed. A discarded message is never among them, even when its
    /// file outlived the writing of its marker.
    public func leftovers() -> [Draft] {
        let discarded = Set(markers().map(\.id))
        var left: [Draft] = []
        for url in files("json") {
            guard let draft = AtomicFile.readJSON(Draft.self, from: url) else { continue }
            if discarded.contains(draft.id) {
                try? FileManager.default.removeItem(at: url)
            } else if saving[draft.id] == nil {
                left.append(draft)
            }
        }
        return left
    }

    // MARK: Saving to Drafts

    /// Whether a save of message `id` is under way.
    public func isSaving(_ id: UUID) -> Bool { saving[id] != nil }

    /// Saves `draft` to Drafts with `upload`, which returns once the server has it. The file on
    /// this Mac is written first and goes only then, so a quit or a crash before the server
    /// answers leaves it for the next launch. A save of the same message already under way
    /// finishes first, so saves never overtake one another and the newest content is what stays.
    /// The task answers nil once the server has the message, or the error, the file staying.
    @discardableResult
    public func save(_ draft: Draft, upload: @escaping @MainActor (Draft) async throws -> Void) -> Task<(any Error)?, Never> {
        let id = draft.id
        keep(draft)
        turns += 1
        let turn = turns
        let earlier = saving[id]?.task
        let task = Task { @MainActor [weak self] () -> (any Error)? in
            _ = await earlier?.value
            var failure: (any Error)?
            do {
                try await upload(draft)
            } catch {
                failure = error
            }
            // A later save of the message holds the newer content, and its file stays for it.
            guard let self, self.saving[id]?.turn == turn else { return failure }
            self.saving[id] = nil
            if failure == nil, !self.isOpen(id) { try? FileManager.default.removeItem(at: self.fileURL(id)) }
            return failure
        }
        saving[id] = (turn, task)
        return task
    }

    // MARK: Discard

    /// Discard. The message's file on this Mac goes at once. Its copy in Drafts, `copy`, stays
    /// while Undo is offered, marked to be deleted; the marker is written before the file goes,
    /// so that a crash in between cannot bring the message back at the next launch.
    public func discard(_ id: UUID, copy: Copy?, at now: Date = Date()) {
        if let copy { try? AtomicFile.writeJSON(Marker(id: id, copy: copy, discardedAt: now), to: markerURL(id)) }
        try? FileManager.default.removeItem(at: fileURL(id))
    }

    /// Undo, while it is offered. The message is kept on this Mac again before its marker goes,
    /// so it is always in one place or the other, and its copy in Drafts is no longer deleted.
    public func undoDiscard(_ draft: Draft) {
        keep(draft)
        try? FileManager.default.removeItem(at: markerURL(draft.id))
    }

    /// Undo is over for message `id`: its copy in Drafts, if one is marked, is deleted now.
    public func undoEnded(_ id: UUID) {
        guard let marker = AtomicFile.readJSON(Marker.self, from: markerURL(id)) else { return }
        startDelete(marker)
    }

    /// Deletes the copies in Drafts of every message discarded and not brought back, as at a
    /// launch for those a quit left marked.
    @discardableResult
    public func deleteDiscarded() -> [Task<Void, Never>] {
        for marker in markers() { startDelete(marker) }
        return Array(deleting.values)
    }

    private func startDelete(_ marker: Marker) {
        guard deleting[marker.id] == nil else { return }
        let deleteCopy = self.deleteCopy
        let url = markerURL(marker.id)
        deleting[marker.id] = Task { @MainActor [weak self] in
            do {
                try await deleteCopy(marker.copy)
                try? FileManager.default.removeItem(at: url)
            } catch {
                Log.info("Drafts", "a discarded draft's copy could not be deleted yet (\(type(of: error))); it is tried again at the quit or the next launch")
            }
            self?.deleting[marker.id] = nil
        }
    }

    // MARK: Quitting

    /// At a quit: waits up to `seconds` for the saves under way to be answered and for the copies
    /// of discarded messages to go, Undo being over for them all, and says whether everything
    /// finished. Whatever did not stays on this Mac for the next launch to finish.
    public func finish(within seconds: TimeInterval) async -> Bool {
        deleteDiscarded()
        let saves = saving.values.map { entry in Task<Void, Never> { _ = await entry.task.value } }
        return await Waiting.upTo(seconds, for: saves + Array(deleting.values))
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
