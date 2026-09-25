import Foundation
import FalconCore

// Which engine serves each account, and where the list reads each sidebar selection from.
//
// A Google account switched to the Gmail API is served by its Gmail engine alone
// (`GmailAccountAssembly`): its folders, list, actions, drafts, sending, imports, archive job
// and search. Every other account keeps the IMAP engine and its stored rows. The list, message
// windows, notifications and every action ask here which it is, so nothing meant for a Google
// account on the Gmail API reaches IMAP or SMTP, and nothing reads its old IMAP store, which is
// kept exactly as it was so an earlier FalconMail can take the account back.

/// A search the Gmail engines run, shown as the list's view `.search(id)`.
struct EngineSearchRun {
    let id: UUID
    let query: String
    /// The Google accounts on the Gmail engine it covers.
    let accounts: Set<UUID>
}

extension AppModel {
    // MARK: - Which engine

    /// The Gmail engine of `accountID` while it runs; nil for an account on IMAP, and for a
    /// switched one whose engine has not started yet.
    func engine(for accountID: UUID) -> GmailAccountEngine? {
        engineAssemblies[accountID]?.engine
    }

    /// Everything the Gmail engine of `accountID` is made of: its list, actions, drafts, sender,
    /// importer and search.
    func assembly(for accountID: UUID) -> GmailAccountAssembly? {
        engineAssemblies[accountID]
    }

    /// Whether `accountID` is a Google account on the Gmail API, running or not. Such an account
    /// never uses IMAP or SMTP; while its engine is not running, what is asked of it waits or
    /// says so, and never goes by IMAP instead.
    func usesGmailEngine(_ accountID: UUID) -> Bool {
        gmailEngineAccounts.contains(accountID)
    }

    /// Whether the message named by `id`, a row's id or key string, belongs to an account on the
    /// Gmail API.
    func usesGmailEngine(messageID id: String) -> Bool {
        guard let key = RowKey(string: id) else { return false }
        if key.isGmail { return true }
        return key.accountID.map(usesGmailEngine) ?? false
    }

    // MARK: - What the list reads

    /// The view the list shows for a sidebar selection, with the list's own settings: sort,
    /// conversations, date groups, the Unread and Flagged filters and Focused or Other. Nil for
    /// a selection that shows no message list, such as the calendar. While a search's results
    /// are shown, the view of those results.
    func listView(for selection: SidebarSelection?) -> ListView? {
        var filters = Set<ListFilter>()
        for filter in self.filters {
            switch filter {
            case .unread: filters.insert(.unread)
            case .flagged: filters.insert(.flagged)
            }
        }
        let scope: ListView.Scope
        switch selection {
        case .unified?:
            scope = .allInboxes
        case .smart(let kind)?:
            scope = .allInboxes
            switch kind {
            case .unread: filters.insert(.unread)
            case .flagged: filters.insert(.flagged)
            case .attachments: filters.insert(.attachments)
            }
        case .folder(let id)?:
            scope = .folder(id)
        default:
            return nil
        }
        if let search = engineSearch, searchCovers(selection, search) {
            return ListView(scope: .search(search.id), filters: filters, sort: listSortSpec, conversations: groupByThread,
                            dateGroups: showInGroups)
        }
        if Preferences.bool(Pref.focusedInbox, default: false), showsFocusedTabs(for: scope) {
            filters.insert(focusedTab == .focused ? .focused : .other)
        }
        return ListView(scope: scope, filters: filters, sort: listSortSpec, conversations: groupByThread, dateGroups: showInGroups)
    }

    /// The list's sort as the engines take it.
    var listSortSpec: ListSortSpec {
        ListSortSpec(key: ListSortKey(rawValue: listSort) ?? .date, ascending: sortAscending)
    }

    /// Focused and Other split the Inbox, and All Inboxes, as Outlook's do.
    private func showsFocusedTabs(for scope: ListView.Scope) -> Bool {
        switch scope {
        case .allInboxes: return true
        case .folder(let id): return folder(id)?.role == .inbox
        case .search: return false
        }
    }

    private func searchCovers(_ selection: SidebarSelection?, _ search: EngineSearchRun) -> Bool {
        switch selection {
        case .unified?, .smart?: return true
        case .folder(let id)?: return folder(id).map { search.accounts.contains($0.accountID) } ?? false
        default: return false
        }
    }

    /// Where the list's rows come from for a selection: a folder of a Google account on the
    /// Gmail API from its engine; All Inboxes, when any account is on the engine, from every
    /// account's rows merged by date; anything else from the stored rows. Nil for a selection
    /// with no message list, and for a folder whose Google account's engine has not started yet.
    func listSource(for selection: SidebarSelection?) -> (any ListSource)? {
        switch selection {
        case .unified?, .smart?:
            if let search = engineSearch { return searchSource(search) }
            return allInboxesSource()
        case .folder(let id)?:
            guard let accountID = folder(id)?.accountID else { return nil }
            if usesGmailEngine(accountID) { return assembly(for: accountID)?.list }
            return storeList
        default:
            return nil
        }
    }

    /// The source a search's view is read from: one account's list, or every covered account's
    /// merged.
    private func searchSource(_ search: EngineSearchRun) -> (any ListSource)? {
        let lists = search.accounts.compactMap { assembly(for: $0)?.list }
        if lists.count == 1 { return lists[0] }
        return lists.isEmpty ? nil : MergedListSource(index: sharedListIndex, gmail: lists)
    }

    /// All Inboxes: the stored rows alone while no account is on the Gmail engine, and otherwise
    /// every account's Inbox merged by date, made again only when the running engines change.
    private func allInboxesSource() -> any ListSource {
        let running = Set(engineAssemblies.keys)
        guard !running.isEmpty else { return storeList }
        if let made = mergedList, made.engines == running { return made.source }
        let lists = running.sorted { $0.uuidString < $1.uuidString }.compactMap { engineAssemblies[$0]?.list }
        var others: [UUID: any ListSource] = [:]
        for account in accounts where !usesGmailEngine(account.id) { others[account.id] = storeList }
        let merged = MergedListSource(index: sharedListIndex, gmail: lists, others: others)
        mergedList = (running, merged)
        let store = storeList
        let index = sharedListIndex
        let engines = gmailEngineAccounts
        Task { await store.share(with: index, engineAccounts: engines) }
        return merged
    }

    /// The one index every Google account's list builds its views in, so All Inboxes and a search
    /// over several accounts are built in one place.
    var sharedListIndex: ListIndex { coordinator.listIndex }

    /// What reply, forward, a message window and a notification need of the message named by
    /// `key`, with the folder it is seen in taken from `view`: from its Gmail engine for a Google
    /// account on the Gmail API, and from the stored rows otherwise. `gone` only when the message
    /// is no longer there; offline, or while Gmail asks FalconMail to wait, `unavailable`.
    func summary(for key: RowKey, in view: ListView) async -> RowAvailability {
        guard let accountID = key.accountID else { return .gone }
        if usesGmailEngine(accountID) {
            guard let list = assembly(for: accountID)?.list else {
                return .unavailable(reason: "\(accountName(accountID)) isn't connected yet.")
            }
            return await list.summary(for: key, in: view)
        }
        guard case .stored(let id) = key, let message = try? await store.message(id: id) else { return .gone }
        return .available(message)
    }
}
