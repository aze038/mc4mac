import Foundation

/// Where what FalconMail itself puts on Gmail goes into the account's index at once, from
/// Gmail's answer: a message sent, each save of a draft, a message imported. So Sent, Drafts
/// and the import's folder show it straight away, and when the history's echo of it arrives the
/// message is already known and nothing is fetched again (§4.6).
///
/// The account's engine implements it, since it is the store's only writer and has to tell the
/// list; `GmailStorePlacer` does the store's part, for the engine to call and for tests. None of
/// it is ever the only record: a placement lost to a crash comes back with the history's echo,
/// which is why nothing here is written with a cursor and nothing here can fail a send or a save.
public protocol GmailUploadPlacing: Sendable {
    /// A message FalconMail sent or saved as a draft just now: above every other message, with
    /// `labels`, and kept on the Mac with its text from `raw`, at no cost. `previous` is a
    /// draft's earlier message, which Gmail deleted when it saved the new one. `messageID` is
    /// Gmail's Message-ID for it when that differs from the one in `raw`, so replies to it
    /// thread.
    func placeUploaded(_ message: GmailMessage, labels: Set<GmailLabelID>, raw: Data, replacing previous: GmailMessageID?,
                       messageID: String?) async
    /// A message FalconMail imported, placed among the mail of its own day: just above
    /// `neighbour`, the newest message received before that day, or at the very bottom when no
    /// message is older. Never at the top, so an import never looks like new mail.
    func placeImported(_ message: GmailMessage, labels: Set<GmailLabelID>, date: Date, above neighbour: GmailMessageID?) async
    /// Messages FalconMail deleted from Gmail itself, such as a discarded draft.
    func forget(_ ids: [GmailMessageID]) async
    /// An import ended, or has run for a day. Its messages are placed to the day only; listing
    /// All Mail again puts each in its exact place, which only the engine can start.
    func importEnded() async
}

/// The store's part of placing uploads, with no list to tell. The engine calls it from inside
/// its own isolation, so the store still has one writer.
public actor GmailStorePlacer: GmailUploadPlacing {
    private let store: any GmailStore
    private let now: @Sendable () -> Date
    /// When each message imported this session was dated, so messages of one day go in date
    /// order among themselves. The index holds no dates.
    private var importedDates: [UInt64: Date] = [:]

    public init(store: any GmailStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    public func placeUploaded(_ message: GmailMessage, labels: Set<GmailLabelID>, raw: Data, replacing previous: GmailMessageID?,
                              messageID: String?) async {
        guard let ref = message.ref else { return }
        let index = await store.index()
        // Placed again with Gmail's Message-ID, it keeps the place it was given the first time.
        let order = index.record(for: ref.id)?.order ?? GmailStorePlacer.orderAbove(index)
        var changes: [GmailChange] = []
        if let previous, previous != ref.id { changes.append(.tombstone(previous)) }
        let parsed = MIMEParser.parse(raw)
        changes.append(.place(ref, order: order, labels: labels, attributes: GmailStorePlacer.attributes(of: parsed, size: raw.count)))
        do {
            try await store.commit(GmailJournalBatch(changes: changes))
            let cached = GmailCachedMessage(uploaded: parsed, ref: ref, size: message.sizeEstimate ?? raw.count,
                                            date: message.receivedDate ?? now(), messageID: messageID, at: now())
            try await store.cache(cached, body: GmailReducedBody(uploaded: parsed))
        } catch {
            Log.warning("Gmail", "could not place an uploaded message in the index; the history's echo will: \(error.localizedDescription)",
                        error: error)
        }
    }

    public func placeImported(_ message: GmailMessage, labels: Set<GmailLabelID>, date: Date, above neighbour: GmailMessageID?) async {
        guard let ref = message.ref else { return }
        let index = await store.index()
        if index.record(for: ref.id) != nil { return }
        let order = placeAmongItsDay(index, date: date, neighbour: neighbour)
        importedDates[ref.id.raw] = date
        let parsedSize = message.sizeEstimate.map { GmailRecordAttributes.sized($0) } ?? []
        do {
            try await store.commit(GmailJournalBatch(changes: [.place(ref, order: order, labels: labels, attributes: parsedSize)]))
        } catch {
            Log.warning("Gmail", "could not place an imported message in the index; listing All Mail will: \(error.localizedDescription)",
                        error: error)
        }
    }

    public func forget(_ ids: [GmailMessageID]) async {
        guard !ids.isEmpty else { return }
        do {
            try await store.commit(GmailJournalBatch(changes: ids.map { .tombstone($0) }))
        } catch {
            Log.warning("Gmail", "could not take deleted messages out of the index; the history's echo will: \(error.localizedDescription)",
                        error: error)
        }
    }

    public func importEnded() async {
        importedDates = [:]
    }

    // MARK: - Orders

    /// Above the newest message.
    static func orderAbove(_ index: GmailIndexSnapshot) -> UInt32 {
        guard let top = index.byOrder.last else { return GmailIndexRecord.orderStep }
        let order = index.records[Int(top)].order
        return order > UInt32.max - GmailIndexRecord.orderStep ? UInt32.max : order + GmailIndexRecord.orderStep
    }

    /// Just above `neighbour`, after any message imported this session that is of the same day
    /// and no newer, and below the first message that is newer or not imported. Where the gap
    /// of 16 is used up the order repeats, and the index then orders by id, which for Gmail
    /// grows with time; listing All Mail when the import ends puts every one right.
    private func placeAmongItsDay(_ index: GmailIndexSnapshot, date: Date, neighbour: GmailMessageID?) -> UInt32 {
        let slots = index.byOrder
        var position: Int
        if let neighbour, let slot = index.slotByID[neighbour.raw], let found = slots.firstIndex(of: slot) {
            position = found
        } else {
            position = -1
        }
        // Past messages of the same import that belong below this one.
        while position + 1 < slots.count, let their = importedDates[index.records[Int(slots[position + 1])].id], their <= date {
            position += 1
        }
        let low: UInt32 = position >= 0 ? index.records[Int(slots[position])].order : 0
        let high: UInt32
        if position + 1 < slots.count {
            high = index.records[Int(slots[position + 1])].order
        } else {
            high = low > UInt32.max - 2 * GmailIndexRecord.orderStep ? UInt32.max : low + 2 * GmailIndexRecord.orderStep
        }
        guard high > low + 1 else { return low }
        return low + (high - low) / 2
    }

    static func attributes(of parsed: MIMEMessage, size: Int) -> GmailRecordAttributes {
        var attributes = GmailRecordAttributes.sized(size)
        attributes.insert(.attachmentKnown)
        if parsed.attachments.contains(where: { !$0.isInline }) { attributes.insert(.hasAttachment) }
        return attributes
    }
}

extension GmailRecordAttributes {
    /// A known size, in the band the list sorts and filters by.
    static func sized(_ bytes: Int) -> GmailRecordAttributes {
        var attributes: GmailRecordAttributes = [.sizeKnown]
        attributes.sizeBand = SizeBand(bytes: bytes)
        return attributes
    }
}

extension GmailCachedMessage {
    /// What FalconMail knows of a message it uploaded, from the bytes it uploaded: a row, and
    /// the headers a reply needs, at no cost. `messageID` is Gmail's, when it replaced the one
    /// in the bytes.
    init(uploaded parsed: MIMEMessage, ref: GmailRef, size: Int, date: Date, messageID: String?, at cachedAt: Date) {
        let stubs = parsed.attachments.map {
            GmailCachedAttachment(partID: "", attachmentID: nil, filename: $0.filename, mimeType: $0.mimeType, size: $0.size,
                                  contentID: $0.contentID, isInline: $0.isInline)
        }
        self.init(id: ref.id, threadID: ref.threadID, from: parsed.from, to: parsed.to, cc: parsed.cc,
                  bcc: AddressParser.parse(parsed.headers.first("Bcc")), replyTo: parsed.replyTo, subject: parsed.subject,
                  preview: String(parsed.snippet.prefix(100)), date: date, size: size,
                  hasAttachments: parsed.attachments.contains { !$0.isInline },
                  messageID: messageID.flatMap { AddressParser.messageIDs($0).first } ?? parsed.messageID,
                  inReplyTo: parsed.inReplyTo, references: parsed.references, attachments: stubs, cachedAt: cachedAt)
    }
}

extension GmailReducedBody {
    /// The text and HTML of an uploaded message, with the inline pictures of 100 KB or less
    /// that its HTML shows.
    init(uploaded parsed: MIMEMessage) {
        let pictures = parsed.attachments.compactMap { a -> GmailInlineImage? in
            guard a.isInline, let cid = a.contentID, a.size <= 100_000 else { return nil }
            return GmailInlineImage(contentID: cid, mimeType: a.mimeType, data: a.data)
        }
        self.init(textPlain: parsed.textPlain, textHTML: parsed.textHTML, inlineImages: pictures)
    }
}
