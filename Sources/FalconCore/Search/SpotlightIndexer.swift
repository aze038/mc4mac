import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

public struct SearchHit: Sendable, Hashable {
    public var messageID: String
    public var score: Double
}

public actor SpotlightIndexer {
    private let index = CSSearchableIndex(name: "com.falconmail.messages")

    public init() {}

    public func index(_ messages: [MessageSummary], bodies: [String: String] = [:]) async {
        guard !messages.isEmpty else { return }
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
        try? await index.deleteSearchableItems(withIdentifiers: ids)
    }

    public func removeAccount(_ accountID: UUID) async {
        try? await index.deleteSearchableItems(withDomainIdentifiers: [accountID.uuidString])
    }

    public func search(_ text: String, limit: Int = 500) async -> [String] {
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

final class HitCollector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var ids: [String] = []
    func add(_ new: [String]) {
        lock.lock()
        ids.append(contentsOf: new)
        lock.unlock()
    }
}
