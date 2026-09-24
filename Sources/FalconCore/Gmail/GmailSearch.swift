import Foundation

/// Search hits that exist only on the server. Their rows carry a folder id no stored folder has,
/// so every action path that looks up a message's folder finds nothing to act on.
public enum GmailServerRow {
    public static let folderID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    private static let prefix = "gmail/"

    /// Unlike a stored row's id this has no colons, so `MailStore.message(id:)` never resolves it.
    public static func id(accountID: UUID, gmailID: String) -> String {
        prefix + accountID.uuidString + "/" + gmailID
    }

    public static func reference(from id: String) -> (accountID: UUID, gmailID: String)? {
        guard id.hasPrefix(prefix) else { return nil }
        let parts = id.dropFirst(prefix.count).split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let accountID = UUID(uuidString: parts[0]), !parts[1].isEmpty else { return nil }
        return (accountID, parts[1])
    }

    /// A row built from a `format=metadata` answer. Its thread key is Gmail's thread, so it groups
    /// with other server-only hits of the same conversation and never with stored rows.
    public static func summary(for m: GmailMessage, accountID: UUID) -> MessageSummary {
        let labels = Set(m.labelIds ?? [])
        var flags = MessageFlags()
        if !labels.contains("UNREAD") { flags.insert(.seen) }
        if labels.contains("STARRED") { flags.insert(.flagged) }
        if labels.contains("DRAFT") { flags.insert(.draft) }
        let type = ContentType.parse(m.header("Content-Type"))
        var summary = MessageSummary(
            accountID: accountID, folderID: folderID, uid: 0,
            messageID: AddressParser.messageIDs(m.header("Message-ID")).first ?? "",
            inReplyTo: AddressParser.messageIDs(m.header("In-Reply-To")).first ?? "",
            references: AddressParser.messageIDs(m.header("References")),
            subject: RFC2047.decode(m.header("Subject") ?? ""),
            from: AddressParser.parse(m.header("From")).first ?? EmailAddress(address: ""),
            to: AddressParser.parse(m.header("To")),
            cc: AddressParser.parse(m.header("Cc")),
            date: m.receivedDate ?? m.header("Date").flatMap(RFC5322Date.parse) ?? .distantPast,
            flags: flags, size: m.sizeEstimate ?? 0, snippet: decodeEntities(m.snippet ?? ""),
            hasAttachments: type.mimeType == "multipart/mixed", threadKey: "gm:" + m.threadId)
        summary.id = id(accountID: accountID, gmailID: m.id)
        return summary
    }

    /// Gmail's snippet arrives HTML-escaped.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&nbsp;": " "]
        var out = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let tail = rest[amp...]
            guard let semi = tail.prefix(10).firstIndex(of: ";") else {
                out += "&"
                rest = rest[rest.index(after: amp)...]
                continue
            }
            let entity = String(tail[...semi])
            if let value = named[entity] {
                out += value
            } else if entity.hasPrefix("&#"), let code = entity.hasPrefix("&#x") || entity.hasPrefix("&#X")
                        ? UInt32(entity.dropFirst(3).dropLast(), radix: 16) : UInt32(entity.dropFirst(2).dropLast()),
                      let scalar = Unicode.Scalar(code) {
                out.unicodeScalars.append(scalar)
            } else {
                out += entity
            }
            rest = rest[rest.index(after: semi)...]
        }
        return out + rest
    }
}

extension MessageSummary {
    /// A search hit that exists only on the server: it can be read and replied to, never changed.
    public var isServerOnly: Bool { folderID == GmailServerRow.folderID }
}

/// Which messages an action may touch. A hit that exists only on the server has no stored
/// folder to act in until actions go through the Gmail API, so archive, delete, move, flag,
/// read state, mute and categories all leave it out; reading and replying still work.
public enum MessageActions {
    public static func actionable(_ messages: [MessageSummary]) -> [MessageSummary] {
        messages.filter { !$0.isServerOnly }
    }

    /// Whether a control acting on these messages should be offered at all.
    public static func allowsChanges(_ messages: [MessageSummary]) -> Bool {
        !messages.isEmpty && !messages.contains { $0.isServerOnly }
    }
}

/// Where one account is searched: the whole account, or one of its folders.
public struct MailSearchScope: Sendable {
    public var account: AccountInfo
    public var folder: FolderInfo?

    public init(account: AccountInfo, folder: FolderInfo? = nil) {
        self.account = account
        self.folder = folder
    }
}

public struct MailSearchPage: Sendable {
    public var accountID: UUID
    public var messages: [MessageSummary]
    public var hasMore: Bool
    /// The rows came from the messages kept on this Mac rather than from Gmail.
    public var isLocal: Bool
    /// Why this account's search went to the messages kept on this Mac, on the page where it did.
    public var fallback: GoogleAPIError?
    /// Why the page stopped short while the search stays with Gmail: Gmail asked for a pause, and
    /// the hits not yet shown come with the next page.
    public var paused: GoogleAPIError?

    public init(accountID: UUID, messages: [MessageSummary], hasMore: Bool, isLocal: Bool,
                fallback: GoogleAPIError? = nil, paused: GoogleAPIError? = nil) {
        self.accountID = accountID
        self.messages = messages
        self.hasMore = hasMore
        self.isLocal = isLocal
        self.fallback = fallback
        self.paused = paused
    }
}

public enum MailSearchResults {
    /// Adds a page to the rows already shown, newest first, one row per message, so accounts'
    /// pages can arrive in any order.
    public static func merge(_ shown: [MessageSummary], _ page: [MessageSummary]) -> [MessageSummary] {
        var seen = Set(shown.map(\.id))
        let added = page.filter { seen.insert($0.id).inserted }
        guard !added.isEmpty else { return shown }
        return (shown + added).sorted { $0.date > $1.date }
    }
}

/// One account's share of a search, a page at a time.
public protocol MailAccountSearch: Actor {
    func nextPage() async -> MailSearchPage
}

/// Search over the messages kept on this Mac, for accounts that are not Gmail and for Gmail
/// when the API cannot answer.
public actor LocalAccountSearch: MailAccountSearch {
    private let store: MailStore
    private let scope: MailSearchScope
    private let query: String
    private var done = false

    public init(store: MailStore, scope: MailSearchScope, query: String) {
        self.store = store
        self.scope = scope
        self.query = query
    }

    public func nextPage() async -> MailSearchPage {
        let accountID = scope.account.id
        guard !done else { return MailSearchPage(accountID: accountID, messages: [], hasMore: false, isLocal: true) }
        done = true
        var found = (try? await store.search(query, accountID: accountID)) ?? []
        if let folder = scope.folder, folder.role != .all { found = found.filter { $0.folderID == folder.id } }
        return MailSearchPage(accountID: accountID, messages: found, hasMore: false, isLocal: true)
    }
}

/// Search through the Gmail API. Hits come back as ids, newest first; only a page of them is
/// turned into rows at a time, each either the row already stored under its Message-ID or a
/// read-only row from its metadata. When Gmail cannot answer, the rest of the search runs over
/// the messages kept on this Mac and the page says why. Once Gmail has shown results, a request
/// to slow down only shortens a page: the rest waits for the next one.
public actor GmailAccountSearch: MailAccountSearch {
    struct Target: Equatable {
        var query: String
        var labelIDs: [String]
        var includeSpamTrash: Bool
    }

    private let client: GmailAPIClient
    private let store: MailStore
    private let scope: MailSearchScope
    private let query: String
    private let includeSpamTrash: Bool
    private let pageSize: Int
    private let listSize: Int
    private let concurrency = 8
    private var target: Target?
    private var pending: [GmailMessageRef] = []
    private var pageToken: String?
    private var listed = false
    private var seen = Set<String>()
    private var labelNames: [String: String]?
    private var local: LocalAccountSearch?
    private var shownFromGmail = false
    private var lastPage: Task<MailSearchPage, Never>?

    public init(client: GmailAPIClient, store: MailStore, scope: MailSearchScope, query: String,
                includeSpamTrash: Bool, pageSize: Int = 25, listSize: Int = 100) {
        self.client = client
        self.store = store
        self.scope = scope
        self.query = query
        self.includeSpamTrash = includeSpamTrash
        self.pageSize = pageSize
        self.listSize = listSize
    }

    private var accountID: UUID { scope.account.id }

    /// Pages come one after another even when callers overlap, such as a click on Show more
    /// while the last row scrolls in, so no hit is fetched twice or skipped.
    public func nextPage() async -> MailSearchPage {
        let previous = lastPage
        let page = Task { () -> MailSearchPage in
            _ = await previous?.value
            return await self.fetchPage()
        }
        lastPage = page
        return await withTaskCancellationHandler { await page.value } onCancel: { page.cancel() }
    }

    private func fetchPage() async -> MailSearchPage {
        if let local { return await local.nextPage() }
        var rows: [MessageSummary] = []
        do {
            let target = try await resolvedTarget()
            while pending.count < pageSize, !listed || pageToken != nil {
                let list = try await client.list(query: target.query, labelIDs: target.labelIDs, pageToken: pageToken,
                                                 maxResults: listSize, includeSpamTrash: target.includeSpamTrash)
                listed = true
                pending += (list.messages ?? []).filter { seen.insert($0.id).inserted }
                pageToken = list.nextPageToken
            }
            let resolved = await resolve(Array(pending.prefix(pageSize)))
            rows = resolved.rows
            pending.removeAll { resolved.done.contains($0.id) }
            if let failure = resolved.failure { throw failure }
            shownFromGmail = true
            return MailSearchPage(accountID: accountID, messages: rows, hasMore: hasMore, isLocal: false)
        } catch let error as GoogleAPIError {
            if error.kind == .rateLimited || error.kind == .temporary, shownFromGmail || !rows.isEmpty {
                shownFromGmail = true
                return MailSearchPage(accountID: accountID, messages: rows, hasMore: hasMore, isLocal: false, paused: error)
            }
            let fallback = LocalAccountSearch(store: store, scope: scope, query: query)
            local = fallback
            var page = await fallback.nextPage()
            // Rows Gmail already gave are kept; the store's own copies of them merge by id.
            page.messages = MailSearchResults.merge(rows, page.messages)
            page.fallback = error
            return page
        } catch {
            // Cancelled because the search was dropped; hits not yet shown stay pending.
            return MailSearchPage(accountID: accountID, messages: rows, hasMore: hasMore, isLocal: false)
        }
    }

    private var hasMore: Bool { !pending.isEmpty || pageToken != nil || !listed }

    /// Gmail's own words for the folder, added to what the reader typed, which goes through
    /// unchanged so every Gmail operator works.
    static func target(query: String, folder: FolderInfo?, includeSpamTrash: Bool, labelID: String?) -> Target {
        guard let folder else { return Target(query: query, labelIDs: [], includeSpamTrash: includeSpamTrash) }
        func scoped(_ term: String, spamTrash: Bool = false) -> Target {
            Target(query: term + " " + query, labelIDs: [], includeSpamTrash: spamTrash)
        }
        switch folder.role {
        case .inbox: return scoped("in:inbox")
        case .sent: return scoped("in:sent")
        case .drafts: return scoped("in:drafts")
        case .junk: return scoped("in:spam", spamTrash: true)
        case .trash: return scoped("in:trash", spamTrash: true)
        case .flagged: return scoped("is:starred")
        case .important: return scoped("is:important")
        case .all, .archive: return Target(query: query, labelIDs: [], includeSpamTrash: false)
        case .other:
            if let labelID { return Target(query: query, labelIDs: [labelID], includeSpamTrash: false) }
            let name = ModifiedUTF7.decode(folder.path).lowercased()
                .replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "-")
            return scoped("label:" + name)
        }
    }

    private func resolvedTarget() async throws -> Target {
        if let target { return target }
        var labelID: String?
        if let folder = scope.folder, folder.role == .other {
            let wanted = ModifiedUTF7.decode(folder.path)
            labelID = try await labels().first { $0.value.caseInsensitiveCompare(wanted) == .orderedSame }?.key
        }
        let resolved = GmailAccountSearch.target(query: query, folder: scope.folder, includeSpamTrash: includeSpamTrash, labelID: labelID)
        target = resolved
        return resolved
    }

    /// Label names by id, fetched once and only when a user label is involved.
    private func labels() async throws -> [String: String] {
        if let labelNames { return labelNames }
        var names: [String: String] = [:]
        for label in try await client.labels() { names[label.id] = label.name }
        labelNames = names
        return names
    }

    private struct Resolved {
        var rows: [MessageSummary] = []
        /// Hits dealt with: shown, or gone from Gmail since the list.
        var done = Set<String>()
        var failure: Error?
    }

    /// Rows for as many of these hits as Gmail answers for. After the first refusal no more are
    /// asked for; those left over stay pending for the next page instead of costing the rows
    /// already fetched.
    private func resolve(_ refs: [GmailMessageRef]) async -> Resolved {
        let client = self.client
        var result = Resolved()
        var fetched = [GmailMessage?](repeating: nil, count: refs.count)
        await withTaskGroup(of: (Int, Result<GmailMessage?, Error>).self) { group in
            var next = 0
            while next < min(concurrency, refs.count) {
                let index = next
                group.addTask { (index, await GmailAccountSearch.metadata(client, refs[index].id)) }
                next += 1
            }
            while let (index, answer) = await group.next() {
                switch answer {
                case .success(let message):
                    result.done.insert(refs[index].id)
                    fetched[index] = message
                case .failure(let error):
                    if result.failure == nil { result.failure = error }
                }
                if result.failure == nil, next < refs.count {
                    let index = next
                    group.addTask { (index, await GmailAccountSearch.metadata(client, refs[index].id)) }
                    next += 1
                }
            }
        }
        let messages = fetched.compactMap { $0 }
        let ids = Set(messages.compactMap { GmailAccountSearch.usableMessageID($0.header("Message-ID")) })
        let stored = await store.storedMessages(withMessageIDs: ids, accountID: accountID)
        let folders = Dictionary(await store.folders(for: accountID).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        result.rows.reserveCapacity(messages.count)
        for message in messages {
            let hit = GmailServerRow.summary(for: message, accountID: accountID)
            if let messageID = GmailAccountSearch.usableMessageID(message.header("Message-ID")),
               let candidates = stored[messageID]?.filter({ GmailAccountSearch.sameMessage($0, hit) }),
               let row = await storedRow(among: candidates, labelIDs: Set(message.labelIds ?? []), folders: folders) {
                result.rows.append(row)
            } else {
                result.rows.append(hit)
            }
        }
        return result
    }

    /// A Message-ID that can name one message. Broken mailers send an empty `<>` or one without
    /// a domain, which many unrelated messages share.
    static func usableMessageID(_ header: String?) -> String? {
        guard let id = AddressParser.messageIDs(header).first, id.count > 4, id.contains("@") else { return nil }
        return id
    }

    /// Some senders reuse a Message-ID, so a stored copy counts as the hit only when its subject
    /// or its date agrees too. A row with actions on the wrong message would be worse than a
    /// read-only one for the right message.
    static func sameMessage(_ stored: MessageSummary, _ hit: MessageSummary) -> Bool {
        func words(_ subject: String) -> [Substring] { subject.lowercased().split(whereSeparator: \.isWhitespace) }
        if words(stored.subject) == words(hit.subject) { return true }
        return abs(stored.date.timeIntervalSince(hit.date)) <= 86_400
    }

    /// A message deleted between the list and the fetch is left out rather than failing the page.
    private static func metadata(_ client: GmailAPIClient, _ id: String) async -> Result<GmailMessage?, Error> {
        do {
            return .success(try await client.metadata(id: id))
        } catch let error as GoogleAPIError where error.kind == .notFound {
            return .success(nil)
        } catch {
            return .failure(error)
        }
    }

    /// The stored copy whose folder agrees with where Gmail says the message is now. A copy left in
    /// a folder the message has since left would act on the wrong mailbox, so it is not used.
    private func storedRow(among candidates: [MessageSummary], labelIDs: Set<String>,
                           folders: [UUID: FolderInfo]) async -> MessageSummary? {
        let placed = candidates.compactMap { m in folders[m.folderID].map { (m, $0) } }
        var userLabels: Set<String> = []
        if placed.contains(where: { $0.1.role == .other }), let names = try? await labels() {
            userLabels = Set(labelIDs.compactMap { names[$0]?.lowercased() })
        }
        let consistent = placed.filter { GmailAccountSearch.folder($0.1, holds: labelIDs, userLabels: userLabels) }
        let preferred = consistent.min { a, b in
            GmailAccountSearch.preference(a.1, scope: scope.folder) < GmailAccountSearch.preference(b.1, scope: scope.folder)
        }
        return preferred?.0
    }

    static func folder(_ folder: FolderInfo, holds labels: Set<String>, userLabels: Set<String>) -> Bool {
        switch folder.role {
        case .inbox: return labels.contains("INBOX")
        case .sent: return labels.contains("SENT")
        case .drafts: return labels.contains("DRAFT")
        case .junk: return labels.contains("SPAM")
        case .trash: return labels.contains("TRASH")
        case .flagged: return labels.contains("STARRED")
        case .important: return labels.contains("IMPORTANT")
        case .all, .archive: return !labels.contains("SPAM") && !labels.contains("TRASH")
        case .other: return userLabels.contains(ModifiedUTF7.decode(folder.path).lowercased())
        }
    }

    /// The searched folder's own copy first, then the Inbox, labels and system folders, and All
    /// Mail last, so actions on the row behave as they do from that folder today.
    static func preference(_ folder: FolderInfo, scope: FolderInfo?) -> Int {
        if folder.id == scope?.id { return 0 }
        switch folder.role {
        case .inbox: return 1
        case .other: return 2
        case .sent: return 3
        case .drafts: return 4
        case .flagged, .important: return 5
        case .junk: return 6
        case .trash: return 7
        case .archive: return 8
        case .all: return 9
        }
    }
}
