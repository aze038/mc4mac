import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

public struct SearchHit: Sendable, Hashable {
    public var messageID: String
    public var score: Double
}

public actor SpotlightIndexer {
    private let index: CSSearchableIndex?
    /// What an indexer that keeps its entries in memory holds, by account, for tests.
    private var held: [UUID: Set<String>] = [:]

    public init() {
        index = CSSearchableIndex(name: "com.falconmail.messages")
    }

    private init(inMemory: Void) {
        index = nil
    }

    /// An indexer that keeps what it would give Spotlight in memory, and never reaches Spotlight.
    public static func inMemory() -> SpotlightIndexer { SpotlightIndexer(inMemory: ()) }

    /// The ids an in-memory indexer holds for an account.
    public func entries(for accountID: UUID) -> Set<String> { held[accountID] ?? [] }

    public func index(_ messages: [MessageSummary], bodies: [String: String] = [:]) async {
        guard !messages.isEmpty else { return }
        guard let index else {
            for m in messages { held[m.accountID, default: []].insert(m.id) }
            return
        }
        let items = messages.map { m -> CSSearchableItem in
            let attrs = CSSearchableItemAttributeSet(contentType: UTType.emailMessage)
            attrs.title = m.subject
            attrs.authorNames = [m.from.displayName]
            attrs.authorEmailAddresses = [m.from.address]
            attrs.recipientEmailAddresses = (m.to + m.cc).map { $0.address }
            attrs.recipientNames = (m.to + m.cc).map { $0.displayName }
            attrs.contentCreationDate = m.date
            attrs.textContent = bodies[m.id] ?? m.snippet
            attrs.contentDescription = m.snippet
            let item = CSSearchableItem(uniqueIdentifier: m.id, domainIdentifier: m.accountID.uuidString, attributeSet: attrs)
            return item
        }
        try? await index.indexSearchableItems(items)
    }

    public func remove(ids: [String]) async {
        guard !ids.isEmpty else { return }
        guard let index else {
            let gone = Set(ids)
            for account in Array(held.keys) { held[account]?.subtract(gone) }
            return
        }
        try? await index.deleteSearchableItems(withIdentifiers: ids)
    }

    public func removeAccount(_ accountID: UUID) async {
        guard let index else {
            held[accountID] = nil
            return
        }
        try? await index.deleteSearchableItems(withDomainIdentifiers: [accountID.uuidString])
    }

    public func search(_ text: String, limit: Int = 500) async -> [String] {
        guard index != nil else { return [] }
        let escaped = text.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "*", with: "")
        guard !escaped.trimmed.isEmpty else { return [] }
        let words = escaped.split(separator: " ").map(String.init)
        let clauses = words.map { w in
            "(title == \"*\(w)*\"cdw || textContent == \"*\(w)*\"cdw || authorNames == \"*\(w)*\"cdw || authorEmailAddresses == \"*\(w)*\"cdw || recipientEmailAddresses == \"*\(w)*\"cdw)"
        }
        let queryString = clauses.joined(separator: " && ")
        let context = CSSearchQueryContext()
        context.fetchAttributes = ["contentCreationDate"]
        let query = CSSearchQuery(queryString: queryString, queryContext: context)
        let collector = HitCollector()
        query.foundItemsHandler = { items in collector.add(items.map { $0.uniqueIdentifier }) }
        return await withCheckedContinuation { cont in
            query.completionHandler = { _ in cont.resume(returning: Array(collector.ids.prefix(limit))) }
            query.start()
        }
    }
}

// MARK: - A Google account on the Gmail engine

extension SpotlightIndexer {
    /// Keeps Spotlight's entries for a Google account on the Gmail engine to the messages it
    /// keeps on the Mac, the newest 1,000 (§2.4): each is indexed as it is kept and removed when
    /// it leaves, and nothing else of the account is in Spotlight. It runs until `changes` ends,
    /// as when the engine stops, looking again after each change to the index, at most every
    /// `pause`, and every `every` besides, since the cache fills in the background.
    public func follow(accountID: UUID, store: any GmailStore, changes: AsyncStream<GmailIndexChange>,
                       pause: TimeInterval = 10, every: TimeInterval = 120) async {
        await removeAccount(accountID)
        var indexed = Set<GmailMessageID>()
        indexed = await keep(accountID: accountID, store: store, indexed: indexed)
        let ticks = AsyncStream<Void> { continuation in
            let pump = Task {
                for await _ in changes { continuation.yield(()) }
                continuation.finish()
            }
            let timer = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(every * 1_000_000_000))
                    continuation.yield(())
                }
            }
            continuation.onTermination = { _ in
                pump.cancel()
                timer.cancel()
            }
        }
        var last = Date.distantPast
        for await _ in ticks {
            guard !Task.isCancelled else { return }
            let wait = pause - Date().timeIntervalSince(last)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            last = Date()
            indexed = await keep(accountID: accountID, store: store, indexed: indexed)
        }
    }

    /// Indexes the kept messages not yet in Spotlight and removes those no longer kept.
    private func keep(accountID: UUID, store: any GmailStore, indexed: Set<GmailMessageID>) async -> Set<GmailMessageID> {
        let kept = await store.cachedIDs()
        let gone = indexed.subtracting(kept)
        let new = Array(kept.subtracting(indexed))
        if !gone.isEmpty { await remove(ids: gone.map { RowKey.gmail(account: accountID, id: $0).stringValue }) }
        var summaries: [MessageSummary] = []
        for start in stride(from: 0, to: new.count, by: 200) {
            let chunk = Array(new[start..<min(start + 200, new.count)])
            for message in (await store.cachedMessages(chunk)).values {
                summaries.append(SpotlightIndexer.summary(message, accountID: accountID))
            }
        }
        await index(summaries)
        return kept
    }

    static func summary(_ message: GmailCachedMessage, accountID: UUID) -> MessageSummary {
        var summary = MessageSummary(accountID: accountID, folderID: GmailServerRow.folderID, uid: 0, messageID: message.messageID,
                                     inReplyTo: message.inReplyTo, references: message.references, subject: message.subject,
                                     from: message.from, to: message.to, cc: message.cc, date: message.date, flags: [],
                                     size: message.size, snippet: message.preview, hasAttachments: message.hasAttachments,
                                     threadKey: message.threadID.threadKey)
        summary.id = RowKey.gmail(account: accountID, id: message.id).stringValue
        summary.gmailID = message.id
        summary.gmailThreadID = message.threadID
        return summary
    }
}

final class HitCollector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var ids: [String] = []
    func add(_ new: [String]) {
        lock.lock()
        ids.append(contentsOf: new)
        lock.unlock()
    }
}
