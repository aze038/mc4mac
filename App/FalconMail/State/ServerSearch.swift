import Foundation
import FalconCore

/// One submitted search: each account's share of it, which accounts have more to show, and why
/// any account's results come from this Mac instead of Gmail.
@MainActor
final class ServerSearchRun {
    let query: String
    var searches: [UUID: any MailAccountSearch] = [:]
    var hasMore: [UUID: Bool] = [:]
    var fallbacks: [UUID: (email: String, error: GoogleAPIError)] = [:]
    var spotlightIDs: [String]?
    var task: Task<Void, Never>?

    init(query: String) {
        self.query = query
    }

    /// One line for every account that fell back, however many there are.
    var notice: String? {
        let list = fallbacks.values.sorted { $0.email < $1.email }
        guard let first = list.first else { return nil }
        if list.count == 1 || list.allSatisfy({ $0.error.kind == .offline }) { return first.error.searchNotice(email: first.email) }
        return "Gmail search isn't available for \(list.map(\.email).joined(separator: ", ")) right now; showing matches on this Mac."
    }
}

extension AppModel {
    /// Gmail accounts signed in through Google search through the API; an account on an app
    /// password has no token for it, and one whose syncing is off is not contacted.
    func usesGmailAPI(_ account: AccountInfo) -> Bool {
        account.provider == "google" && !account.usesPassword && account.isEnabled && !workOffline
    }

    /// One client per account, so every search and open shares that account's unit budget.
    func gmailClient(for accountID: UUID) -> GmailAPIClient? {
        guard let account = accounts.first(where: { $0.id == accountID }), usesGmailAPI(account) else { return nil }
        if let client = gmailClients[accountID] { return client }
        let client = GmailAPIClient(api: GoogleAPI(tokens: tokens, accountID: accountID))
        gmailClients[accountID] = client
        return client
    }

    /// Where a search looks, from the Search settings: every mailbox, the current account, or the
    /// current folder. The default searches the folder being read, the whole account from its
    /// Inbox and every account from All Inboxes.
    func searchScopes() -> [MailSearchScope] {
        var current: FolderInfo?
        if case .folder(let id) = selection { current = folder(id) }
        let owner = current.flatMap { f in accounts.first { $0.id == f.accountID } }
        let everywhere = accounts.map { MailSearchScope(account: $0) }
        switch Preferences.string("searchScope", default: "smart") {
        case "all":
            return everywhere
        case "mailbox":
            return owner.map { [MailSearchScope(account: $0)] } ?? everywhere
        case "folder", "subfolders":
            if let owner, let current { return [MailSearchScope(account: owner, folder: current)] }
            guard selection == .unified else { return everywhere }
            return accounts.map { MailSearchScope(account: $0, folder: folder(accountID: $0.id, role: .inbox)) }
        default:
            if let owner, let current { return [MailSearchScope(account: owner, folder: current.role == .inbox ? nil : current)] }
            return everywhere
        }
    }

    /// Runs a submitted search. Each account answers on its own and its first page shows the
    /// moment it arrives, merged with the others by date.
    func startSearch(_ query: String) async {
        cancelServerSearch()
        let run = ServerSearchRun(query: query)
        serverSearch = run
        forgetServerRows()
        messages = []
        searchNotice = nil
        searchHasMore = false
        rebuildThreads()
        let includeDeleted = Preferences.bool("searchIncludeDeleted", default: true)
        for scope in searchScopes() {
            if usesGmailAPI(scope.account), let client = gmailClient(for: scope.account.id) {
                run.searches[scope.account.id] = GmailAccountSearch(client: client, store: store, scope: scope, query: query,
                                                                    includeSpamTrash: scope.folder == nil && includeDeleted)
            } else {
                run.searches[scope.account.id] = LocalAccountSearch(store: store, scope: scope, query: query)
            }
        }
        isSearching = !run.searches.isEmpty
        await fetchPages(of: Array(run.searches.keys), in: run)
        if serverSearch === run { isSearching = false }
    }

    /// The next page from every account that has more, for "Show more" and for reaching the end
    /// of the list.
    func loadMoreSearchResults() {
        guard let run = serverSearch, run.task == nil, !isSearching else { return }
        let waiting = run.hasMore.filter(\.value).map(\.key)
        guard !waiting.isEmpty else { return }
        isLoadingMoreResults = true
        Task { await fetchPages(of: waiting, in: run) }
    }

    func cancelServerSearch() {
        serverSearch?.task?.cancel()
        serverSearch = nil
        searchNotice = nil
        searchHasMore = false
        isLoadingMoreResults = false
        isSearching = false
    }

    private func fetchPages(of accountIDs: [UUID], in run: ServerSearchRun) async {
        let searches = accountIDs.compactMap { run.searches[$0] }
        let task = Task { @MainActor [weak self] in
            await withTaskGroup(of: MailSearchPage.self) { group in
                for search in searches { group.addTask { await search.nextPage() } }
                for await page in group {
                    guard !Task.isCancelled, let self else { continue }
                    await self.absorb(page, into: run)
                    if self.serverSearch === run { self.isSearching = false }
                }
            }
        }
        run.task = task
        await task.value
        guard serverSearch === run else { return }
        run.task = nil
        isLoadingMoreResults = false
    }

    private func absorb(_ page: MailSearchPage, into run: ServerSearchRun) async {
        var rows = page.messages
        if page.isLocal { rows += await spotlightHits(for: page.accountID, in: run) }
        guard serverSearch === run else { return }
        run.hasMore[page.accountID] = page.hasMore
        if let error = page.fallback {
            let email = accountName(page.accountID)
            run.fallbacks[page.accountID] = (email, error)
            Log.info("search", "\(email) searched on this Mac: \(error.kind.rawValue) \(error.httpStatus) \(error.reason ?? "-") \(error.detail)")
        }
        for row in rows where row.isServerOnly { serverRows[row.id] = row }
        messages = MailSearchResults.merge(messages, rows)
        searchNotice = run.notice
        searchHasMore = run.hasMore.values.contains(true)
        rebuildThreads()
    }

    /// Spotlight matches message text the store's own index may not hold, for accounts searched
    /// on this Mac, as the local search always did.
    private func spotlightHits(for accountID: UUID, in run: ServerSearchRun) async -> [MessageSummary] {
        if run.spotlightIDs == nil { run.spotlightIDs = await indexer.search(run.query) }
        let prefix = accountID.uuidString + ":"
        let scopeFolder = searchScopes().first { $0.account.id == accountID }?.folder
        var out: [MessageSummary] = []
        for id in run.spotlightIDs ?? [] where id.hasPrefix(prefix) {
            guard let m = try? await store.message(id: id) else { continue }
            if let scopeFolder, scopeFolder.role != .all, m.folderID != scopeFolder.id { continue }
            out.append(m)
        }
        return out
    }

    /// Brings stored rows in the results up to date after a sync without asking Gmail again.
    func refreshSearchRows() async {
        var updated: [String: MessageSummary] = [:]
        var gone = Set<String>()
        for m in messages where !m.isServerOnly {
            if let current = try? await store.message(id: m.id) { updated[m.id] = current } else { gone.insert(m.id) }
        }
        // Pages that arrived while the store was read are kept.
        messages = messages.compactMap { gone.contains($0.id) ? nil : (updated[$0.id] ?? $0) }
        rebuildThreads()
    }

    /// A stored message or one found only on the server, for a tab or window that has only the id.
    func message(id: String) async -> MessageSummary? {
        if let row = serverRows[id] { return row }
        return try? await store.message(id: id)
    }

    /// Drops rows and opened messages from earlier searches unless a tab or window still shows one.
    private func forgetServerRows() {
        var shown = openMessageWindows
        for case .message(let id) in tabs + minimizedTabs { shown.insert(id) }
        serverRows = serverRows.filter { shown.contains($0.key) }
        for id in openedServerOrder where !shown.contains(id) { forgetOpened(id) }
    }

    // MARK: - Opening messages found only on the server

    /// The text of a message found only on the server, fetched into memory. Its attachments are
    /// fetched only when opened, saved or forwarded.
    func serverBody(for message: MessageSummary) async -> MIMEMessage? {
        if let opened = openedServerMessages[message.id] { return opened.message }
        guard let reference = GmailServerRow.reference(from: message.id) else { return nil }
        guard let client = gmailClient(for: reference.accountID) else {
            errorMessage = GoogleAPIError(kind: .offline).localizedDescription
            return nil
        }
        do {
            let opened = try await client.openText(id: reference.gmailID)
            remember(opened, for: message.id)
            return opened.message
        } catch is CancellationError {
            return nil
        } catch {
            reportServerError(error, accountID: reference.accountID, doing: "open")
            return nil
        }
    }

    /// The same text with the small pictures it shows inline, or nil when there are none to fetch.
    func serverBodyWithInlineImages(_ message: MessageSummary) async -> MIMEMessage? {
        guard let opened = openedServerMessages[message.id], !opened.pendingInlineImages.isEmpty,
              let client = gmailClient(for: message.accountID) else { return nil }
        do {
            let richer = try await client.withInlineImages(opened)
            remember(richer, for: message.id)
            return richer.message
        } catch {
            return nil
        }
    }

    /// Attachments to list under the header: everything except pictures the text shows inline.
    func serverAttachments(for message: MessageSummary) -> [GmailAttachmentStub] {
        guard let opened = openedServerMessages[message.id] else { return [] }
        let html = opened.message.textHTML?.lowercased() ?? ""
        return opened.attachments.filter { stub in
            guard let cid = stub.contentID else { return true }
            return !html.contains("cid:" + cid.lowercased())
        }
    }

    func serverAttachmentData(_ message: MessageSummary, _ stub: GmailAttachmentStub) async -> Data? {
        let key = message.id + "#" + stub.id
        if let data = serverAttachmentBytes[key] { return data }
        guard let reference = GmailServerRow.reference(from: message.id), let client = gmailClient(for: reference.accountID) else { return nil }
        do {
            let data = try await client.attachmentData(messageID: reference.gmailID, stub: stub)
            if openedServerMessages[message.id] != nil { serverAttachmentBytes[key] = data }
            return data
        } catch is CancellationError {
            return nil
        } catch {
            reportServerError(error, accountID: reference.accountID, doing: "fetch an attachment of")
            return nil
        }
    }

    /// A forward carries the original's attachments, so a message found only on the server has
    /// them fetched first.
    func parsedBodyForForwarding(_ message: MessageSummary) async -> MIMEMessage? {
        let parsed = await parsedBody(for: message)
        guard message.isServerOnly, var opened = openedServerMessages[message.id] else { return parsed }
        for stub in serverAttachments(for: message) {
            guard let data = await serverAttachmentData(message, stub) else { continue }
            opened.add(data, for: stub)
        }
        return opened.message
    }

    private func reportServerError(_ error: Error, accountID: UUID, doing action: String) {
        let apiError = error as? GoogleAPIError ?? GoogleAPIError(kind: .other, detail: String(describing: error))
        Log.info("search", "\(accountName(accountID)) could not \(action) a message found on the server: \(apiError.kind.rawValue) \(apiError.httpStatus) \(apiError.reason ?? "-")")
        errorMessage = apiError.localizedDescription
    }

    /// Keeps the twenty most recently opened messages; their fetched attachments go with them.
    private func remember(_ opened: GmailOpenedMessage, for id: String) {
        openedServerMessages[id] = opened
        openedServerOrder.removeAll { $0 == id }
        openedServerOrder.append(id)
        while openedServerOrder.count > 20 { forgetOpened(openedServerOrder[0]) }
    }

    private func forgetOpened(_ id: String) {
        openedServerMessages[id] = nil
        openedServerOrder.removeAll { $0 == id }
        serverAttachmentBytes = serverAttachmentBytes.filter { !$0.key.hasPrefix(id + "#") }
    }
}
