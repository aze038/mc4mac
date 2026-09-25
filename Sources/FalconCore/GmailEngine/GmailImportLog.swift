import Foundation

/// Which mail FalconMail imported itself (§9.1), so its echo in the history is never new mail,
/// never starts flood mode, and never runs rules or notifications.
///
/// The store keeps the ids Gmail gave each import for 7 days. What it cannot know is an import
/// Gmail has taken but not yet answered: a check running in that moment sees a message nobody
/// placed. So each import is named by its Message-ID before it is uploaded, and while any import
/// is on its way, or has just answered, a message found deep in the order is left to be placed at
/// the next check, by which time the import's answer has placed it and logged it.
public struct GmailImportLog: Sendable {
    /// How long after an import's answer its echo may still reach a check that had already
    /// started.
    public static let settle: TimeInterval = 60

    private var inFlight: [String: Int] = [:]
    private var lastAnswer: Date?

    public init() {}

    /// Whether an import is on its way to Gmail, or answered so recently that its echo may be in
    /// a check that has not seen the answer.
    public func isImporting(at now: Date) -> Bool {
        !inFlight.isEmpty || lastAnswer.map { now.timeIntervalSince($0) < Self.settle } ?? false
    }

    /// Whether a message with this Message-ID is being imported now.
    public func isImporting(messageID: String) -> Bool {
        !messageID.isEmpty && inFlight[Self.key(messageID)] != nil
    }

    public mutating func willImport(messageID: String) {
        inFlight[Self.key(messageID), default: 0] += 1
    }

    /// The import answered, or failed; either way it is no longer on its way.
    public mutating func finished(messageID: String, at now: Date) {
        let key = Self.key(messageID)
        if let count = inFlight[key] {
            inFlight[key] = count > 1 ? count - 1 : nil
        }
        lastAnswer = now
    }

    private static func key(_ messageID: String) -> String {
        messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")).lowercased()
    }
}

extension GmailAccountEngine {
    /// G6's import calls this before uploading each message.
    public func willImport(messageID: String) {
        importLog.willImport(messageID: messageID)
    }

    /// An import answered: the message goes into the index at once, where it belongs by its date,
    /// and into the import log, so its echo in the history changes nothing.
    public func didImport(_ answer: GmailMessage, messageID: String, date: Date) async throws {
        importLog.finished(messageID: messageID, at: now())
        guard let ref = answer.ref else { return }
        try await store.noteImported([ref.id], at: now())
        guard await store.record(for: ref.id) == nil else { return }
        let placement = GmailDeepPlacement(ref: ref, labels: answer.labels, internalDate: answer.receivedDate ?? date, attributes: [])
        let (changes, waiting) = await deepChanges(for: [placement], work: .background(.transfer))
        try await store.commit(GmailJournalBatch(changes: changes + waiting.map { .awaitingPlacement($0) }))
        for ref in waiting { awaiting[ref.id.raw] = ref }
        publishIndexChange(ids: [ref.id])
    }

    public func importFailed(messageID: String) {
        importLog.finished(messageID: messageID, at: now())
    }
}
