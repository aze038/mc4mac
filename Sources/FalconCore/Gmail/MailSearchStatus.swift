import Foundation

/// Where a submitted search stands across its accounts, apart from its rows: which accounts have
/// more to show, which fell back to the messages on this Mac and which stopped short because
/// Gmail asked for a pause.
public struct MailSearchStatus: Sendable {
    public struct Account: Sendable {
        public var email: String
        public var error: GoogleAPIError
    }

    public let query: String
    private let scopeKeys: Set<String>
    public private(set) var hasMore: [UUID: Bool] = [:]
    public private(set) var fallbacks: [UUID: Account] = [:]
    public private(set) var pauses: [UUID: Account] = [:]
    public private(set) var pagesReceived = 0

    /// `viaGmail` holds the accounts searched through Gmail rather than on this Mac.
    public init(query: String, scopes: [MailSearchScope], viaGmail: Set<UUID>) {
        self.query = query
        scopeKeys = MailSearchStatus.keys(scopes, viaGmail: viaGmail)
    }

    public mutating func record(_ page: MailSearchPage, email: String) {
        pagesReceived += 1
        hasMore[page.accountID] = page.hasMore
        if let error = page.fallback { fallbacks[page.accountID] = Account(email: email, error: error) }
        pauses[page.accountID] = page.paused.map { Account(email: email, error: $0) }
    }

    public var anyMore: Bool { hasMore.values.contains(true) }

    /// The accounts with more to show.
    public var accountsWithMore: [UUID] { hasMore.filter(\.value).map(\.key) }

    /// Whether submitting `query` over `scopes` would only repeat this search, spending its units
    /// again. A search that fell back to this Mac is worth submitting again, as Gmail may answer
    /// now.
    public func repeats(query: String, scopes: [MailSearchScope], viaGmail: Set<UUID>) -> Bool {
        query == self.query && fallbacks.isEmpty && MailSearchStatus.keys(scopes, viaGmail: viaGmail) == scopeKeys
    }

    /// One line, however many accounts fell back or paused. Falling back says more about the
    /// results shown, so it comes first.
    public var notice: String? {
        let fell = fallbacks.values.sorted { $0.email < $1.email }
        if let first = fell.first {
            if fell.count == 1 || fell.allSatisfy({ $0.error.kind == .offline }) { return first.error.searchNotice(email: first.email) }
            return "Gmail search isn't available for \(fell.map(\.email).joined(separator: ", ")) right now; showing matches on this Mac."
        }
        let paused = pauses.values.sorted { $0.email < $1.email }
        guard let first = paused.first else { return nil }
        if paused.count == 1 { return first.error.pausedNotice(email: first.email) }
        return "Gmail is busy; Show more fetches the rest of the results in a moment."
    }

    private static func keys(_ scopes: [MailSearchScope], viaGmail: Set<UUID>) -> Set<String> {
        Set(scopes.map { scope in
            [scope.account.id.uuidString, scope.folder?.id.uuidString ?? "all", viaGmail.contains(scope.account.id) ? "gmail" : "mac"]
                .joined(separator: "/")
        })
    }
}
