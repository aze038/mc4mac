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

// MARK: - What FalconMail puts on Gmail itself (§4.6, §8.1, §9.1)

/// The engine places what FalconMail uploads, since it is the store's only writer and tells the
/// list: the sender, the drafts and the importer hand it Gmail's answers.
extension GmailAccountEngine: GmailUploadPlacing {
    /// A message FalconMail sent or saved as a draft just now goes into the index at once, above
    /// everything, with its row and text kept from the bytes it uploaded, so Sent, Drafts and the
    /// conversation update before the send returns; its echo in the history then changes nothing.
    public func placeUploaded(_ message: GmailMessage, labels: Set<GmailLabelID>, raw: Data, replacing previous: GmailMessageID?,
                              messageID: String?) async {
        guard let ref = message.ref else { return }
        await loadIfNeeded()
        let parsed = MIMEParser.parse(raw)
        var changes: [GmailChange] = []
        if let previous, previous != ref.id { changes.append(.tombstone(previous)) }
        let order: UInt32
        if let record = await store.record(for: ref.id), !record.attributes.contains(.tombstone) {
            // Placed again with Gmail's Message-ID, it keeps the place it was given the first time.
            order = record.order
        } else {
            order = GmailOrderSpace.top(count: 1, above: ceiling)[0]
            ceiling = order
        }
        changes.append(.place(ref, order: order, labels: labels, attributes: GmailStorePlacer.attributes(of: parsed, size: raw.count)))
        let cached = GmailCachedMessage(uploaded: parsed, ref: ref, size: message.sizeEstimate ?? raw.count,
                                        date: message.receivedDate ?? now(), messageID: messageID, at: now())
        do {
            try await store.commit(GmailJournalBatch(changes: changes))
            try await store.cache(cached, body: GmailReducedBody(uploaded: parsed))
        } catch {
            // Never the only record: the history's echo places it.
            Log.info("gmail", "\(account.email): an uploaded message could not be placed yet; its echo will: \(error.localizedDescription)")
        }
        placedDuringRelist?.insert(ref.id.raw)
        publishRows([.gmail(account: accountID, id: ref.id): GmailMessageBuilder.row(cached, accountID: accountID)])
        publishIndexChange(ids: Set([ref.id] + (previous.map { [$0] } ?? [])))
    }

    /// An import is on its way to Gmail: until it answers, a message a check finds deep in the
    /// order is left for the next check, by when the answer has placed and logged it.
    public func willImport(messageID: String?) async {
        importLog.willImport(messageID: messageID ?? "")
    }

    public func imported(_ id: GmailMessageID, messageID: String?) async throws {
        importLog.finished(messageID: messageID ?? "", at: now())
        try await store.noteImported([id], at: now())
    }

    public func importFailed(messageID: String?) async {
        importLog.finished(messageID: messageID ?? "", at: now())
    }

    public func placeImported(_ message: GmailMessage, labels: Set<GmailLabelID>, date: Date, above neighbour: GmailMessageID?) async {
        await loadIfNeeded()
        await importPlacer.placeImported(message, labels: labels, date: date, above: neighbour)
        guard let id = message.gmailID else { return }
        placedDuringRelist?.insert(id.raw)
        publishIndexChange(ids: [id])
    }

    /// Messages FalconMail deleted from Gmail itself, such as a discarded draft or the one a save
    /// replaced.
    public func forget(_ ids: [GmailMessageID]) async {
        guard !ids.isEmpty else { return }
        do {
            try await store.commit(GmailJournalBatch(changes: ids.map { .tombstone($0) }))
        } catch {
            Log.info("gmail", "\(account.email): deleted messages could not leave the index yet; the history's echo will: \(error.localizedDescription)")
        }
        publishIndexChange(ids: Set(ids))
    }

    /// Imported messages are placed to the day; listing All Mail again puts each in its exact
    /// place, once nothing else is being listed.
    public func importEnded() async {
        await importPlacer.importEnded()
        importRelistWanted = true
        wakeLoop()
    }

    /// The listing an import asked for.
    func importRelist() async {
        do {
            let result = try await relist(labels: [], allMail: true, replaceBits: false, confirmRemovals: false, work: .background(.index))
            if !result.changes.isEmpty { try await store.commit(GmailJournalBatch(changes: result.changes, cursor: cursor)) }
            figures.relistings += 1
            await anchorFiller.indexChanged()
            publishIndexChange(ids: [], everything: true)
        } catch {
            importRelistWanted = true
            Log.warning("gmail", "\(account.email): listing All Mail after an import stopped; it goes on later", error: error, account: account,
                        code: (error as? GoogleAPIError)?.kind.rawValue)
        }
    }
}
