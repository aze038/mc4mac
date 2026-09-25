import Foundation
import FalconCore

/// One submitted search: each account's share of it and where it stands.
@MainActor
final class ServerSearchRun {
    var status: MailSearchStatus
    let scopes: [MailSearchScope]
    var searches: [UUID: any MailAccountSearch] = [:]
    var task: Task<Void, Never>?
    private var spotlight: Task<[String], Never>?

    init(query: String, scopes: [MailSearchScope], viaGmail: Set<UUID>) {
        status = MailSearchStatus(query: query, scopes: scopes, viaGmail: viaGmail)
        self.scopes = scopes
    }

    var query: String { status.query }

    /// Spotlight's matches for the query, asked for once however many accounts need them.
    func spotlightIDs(_ indexer: SpotlightIndexer) async -> [String] {
        let query = status.query
        let running = spotlight ?? Task { await indexer.search(query) }
        spotlight = running
        return await running.value
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
        let client = GmailAPIClient(api: GoogleAPI(tokens: tokens, accountID: accountID),
                                    limiter: GmailQuotaLimiter(sleep: GmailWait.sleep))
        gmailClients[accountID] = client
        return client
    }

    func gmailOpener(for accountID: UUID) -> GmailOpener? {
        guard let client = gmailClient(for: accountID) else { return nil }
        if let opener = gmailOpeners[accountID] { return opener }
        let opener = GmailOpener(client: client, sleep: GmailWait.sleep)
        gmailOpeners[accountID] = opener
        return opener
    }

    /// A search on the Gmail engines that asked for ids only while the owner typed now fetches
    /// the text of the first hits too, as Return or a pause of a second and a half asks.
    func fetchEngineSearchRows() {
        guard let run = engineSearch else { return }
        Task { await coordinator.search(run.query, id: run.id, accounts: run.accounts, fetchRows: true) }
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

    /// The accounts in these scopes that search through Gmail rather than on this Mac.
    func gmailAccounts(in scopes: [MailSearchScope]) -> Set<UUID> {
        Set(scopes.filter { usesGmailAPI($0.account) }.map(\.account.id))
    }

    /// Runs a submitted search. Each account answers on its own and its first page shows the
    /// moment it arrives, merged with the others by date. The rows on screen stay until then, so
    /// the list never goes blank while Gmail is asked.
    func startSearch(_ query: String, fetchRows: Bool = true) async {
        cancelServerSearch()
        var scopes = searchScopes()
        // Google accounts on the Gmail API search through their engines, whose hits are rows every
        // action works on, shown as the list's view of the search.
        let onEngine = Set(scopes.map(\.account.id).filter { engineAssemblies[$0] != nil })
        if !onEngine.isEmpty {
            let run = EngineSearchRun(id: UUID(), query: query, accounts: onEngine)
            engineSearch = run
            Task { await coordinator.search(query, id: run.id, accounts: onEngine, fetchRows: fetchRows) }
            scopes.removeAll { onEngine.contains($0.account.id) }
            guard !scopes.isEmpty else {
                messages = []
                rebuildThreads()
                return
            }
        }
        let viaGmail = gmailAccounts(in: scopes)
        let run = ServerSearchRun(query: query, scopes: scopes, viaGmail: viaGmail)
        serverSearch = run
        let includeDeleted = Preferences.bool("searchIncludeDeleted", default: true)
        for scope in scopes {
            if viaGmail.contains(scope.account.id), let client = gmailClient(for: scope.account.id) {
                run.searches[scope.account.id] = GmailAccountSearch(client: client, store: store, scope: scope, query: query,
                                                                    includeSpamTrash: scope.folder == nil && includeDeleted)
            } else {
                run.searches[scope.account.id] = LocalAccountSearch(store: store, scope: scope, query: query)
            }
        }
        guard !run.searches.isEmpty else {
            messages = []
            rebuildThreads()
            return
        }
        // Spotlight runs alongside Gmail rather than after it for accounts known to search here.
        if run.searches.values.contains(where: { $0 is LocalAccountSearch }) {
            Task { _ = await run.spotlightIDs(indexer) }
        }
        isSearching = true
        await fetchPages(of: Array(run.searches.keys), in: run)
        if serverSearch === run { isSearching = false }
    }

    /// The next page from every account that has more, for "Show more" and for reaching the end
    /// of the list. A second request while one is loading is ignored, so a click and the last row
    /// scrolling in never fetch the same page twice.
    func loadMoreSearchResults() {
        guard let run = serverSearch, run.task == nil, !isSearching, !isLoadingMoreResults else { return }
        let waiting = run.status.accountsWithMore
        guard !waiting.isEmpty else { return }
        isLoadingMoreResults = true
        Task { await fetchPages(of: waiting, in: run) }
    }

    func cancelServerSearch() {
        if let run = engineSearch {
            engineSearch = nil
            Task { await coordinator.endSearch(run.id, accounts: run.accounts) }
        }
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
                    self.absorb(page, into: run)
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

    private func absorb(_ page: MailSearchPage, into run: ServerSearchRun) {
        guard serverSearch === run else { return }
        let email = accountName(page.accountID)
        let first = run.status.pagesReceived == 0
        run.status.record(page, email: email)
        let account = accounts.first { $0.id == page.accountID }
        if let error = page.fallback {
            Log.warning("Search", "\(email) searched on this Mac: \(error.kind.rawValue) \(error.httpStatus) \(error.reason ?? "-") \(error.detail)",
                        error: error, account: account, logAs: "search")
        } else if let error = page.paused {
            Log.warning("Search", "\(email) paused by Gmail after \(page.messages.count) rows: \(error.kind.rawValue) \(error.httpStatus) \(error.reason ?? "-") \(error.detail)",
                        error: error, account: account, logAs: "search")
        }
        if first {
            forgetServerRows()
            messages = []
        }
        show(page.messages, in: run)
        if page.isLocal { addSpotlightHits(for: page.accountID, in: run) }
    }

    private func show(_ rows: [MessageSummary], in run: ServerSearchRun) {
        for row in rows where row.isServerOnly { serverRows[row.id] = row }
        messages = MailSearchResults.merge(messages, rows)
        searchNotice = run.status.notice
        searchHasMore = run.status.anyMore
        rebuildThreads()
    }

    /// Spotlight's matches join the list when they come, so a slow Spotlight query never holds
    /// back another account's page.
    private func addSpotlightHits(for accountID: UUID, in run: ServerSearchRun) {
        Task { [weak self] in
            guard let self else { return }
            let rows = await self.spotlightHits(for: accountID, in: run)
            guard self.serverSearch === run, !rows.isEmpty else { return }
            self.show(rows, in: run)
        }
    }

    /// Spotlight matches message text the store's own index may not hold, for accounts searched
    /// on this Mac, as the local search always did.
    private func spotlightHits(for accountID: UUID, in run: ServerSearchRun) async -> [MessageSummary] {
        let ids = await run.spotlightIDs(indexer)
        let prefix = accountID.uuidString + ":"
        let scopeFolder = run.scopes.first { $0.account.id == accountID }?.folder
        var out: [MessageSummary] = []
        for id in ids where id.hasPrefix(prefix) {
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

    /// A stored message, one found only on the server, or a Gmail row of an account on the Gmail
    /// API, for a tab or window that has only the id.
    func message(id: String) async -> MessageSummary? {
        if let row = serverRows[id] { return row }
        if RowKey(string: id)?.isGmail == true { return await engineMessage(id: id) }
        return try? await store.message(id: id)
    }

    /// Drops rows and opened messages from earlier searches unless a tab or window still shows one.
    private func forgetServerRows() {
        var shown = openMessageWindows
        for case .message(let id) in tabs + minimizedTabs { shown.insert(id) }
        // A window or tab showing a conversation shows all its messages.
        for id in Array(shown) { shown.formUnion(conversationWindows[id] ?? []) }
        serverRows = serverRows.filter { shown.contains($0.key) }
        for id in openedServerOrder where !shown.contains(id) { forgetOpened(id) }
    }

    // MARK: - Opening messages found only on the server

    /// The text of a message found only on the server, for Reply and Forward, which the reader
    /// asked for, so it is fetched at once and a refusal is told as an alert.
    func serverBody(for message: MessageSummary) async -> MIMEMessage? {
        do {
            return try await openServerMessage(message, trigger: .asked)
        } catch is CancellationError {
            return nil
        } catch {
            reportServerError(error, accountID: message.accountID, doing: "open")
            return nil
        }
    }

    /// Opens a message found only on the server into memory: its text now, its attachments only
    /// when opened, saved or forwarded. The reading pane opens it as its selection moves, which
    /// waits a moment in case the arrow keys are only passing over it; everything else the reader
    /// asked for opens at once. A refusal is thrown as `GoogleAPIError` for the caller to show
    /// where it belongs.
    func openServerMessage(_ message: MessageSummary, trigger: GmailOpener.Trigger) async throws -> MIMEMessage {
        if let opened = openedServerMessages[message.id] { return opened.message }
        guard let reference = GmailServerRow.reference(from: message.id) else {
            throw GoogleAPIError(kind: .other, detail: "not a row found on the server")
        }
        guard let opener = gmailOpener(for: reference.accountID) else { throw GoogleAPIError(kind: .offline) }
        let opened = try await opener.openText(id: reference.gmailID, trigger: trigger)
        // Inline pictures fetched meanwhile by another caller are kept.
        if openedServerMessages[message.id] == nil { remember(opened, for: message.id) }
        return openedServerMessages[message.id]?.message ?? opened.message
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
        openedServerMessages[message.id]?.listedAttachments ?? []
    }

    func serverAttachmentData(_ message: MessageSummary, _ stub: GmailAttachmentStub) async -> Data? {
        let key = message.id + "#" + stub.id
        if let data = serverAttachmentBytes[key] { return data }
        if !message.isServerOnly, usesGmailEngine(message.accountID) {
            do {
                let data = try await engineAttachmentData(message, stub)
                if let data, openedServerMessages[message.id] != nil { serverAttachmentBytes[key] = data }
                return data
            } catch is CancellationError {
                return nil
            } catch {
                reportServerError(error, accountID: message.accountID, doing: "fetch an attachment of")
                return nil
            }
        }
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

    /// A forward carries the original's attachments and the pictures its text refers to, so a
    /// message found only on the server has them all fetched first.
    func parsedBodyForForwarding(_ message: MessageSummary) async -> MIMEMessage? {
        let parsed = await parsedBody(for: message)
        guard fetchesAttachmentsFromGmail(message), var opened = openedServerMessages[message.id] else { return parsed }
        for stub in opened.unfetchedAttachments {
            guard let data = await serverAttachmentData(message, stub) else { continue }
            opened.add(data, for: stub)
        }
        return opened.message
    }

    private func reportServerError(_ error: Error, accountID: UUID, doing action: String) {
        let apiError = error as? GoogleAPIError ?? GoogleAPIError(kind: .other, detail: String(describing: error))
        Log.warning("Open", "\(accountName(accountID)) could not \(action) a message found on the server: \(apiError.kind.rawValue) \(apiError.httpStatus) \(apiError.reason ?? "-")",
                    error: apiError, account: accounts.first { $0.id == accountID }, logAs: "search")
        showAlert(for: apiError)
    }

    /// Keeps the twenty most recently opened messages; their fetched attachments go with them.
    func remember(_ opened: GmailOpenedMessage, for id: String) {
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
