import Foundation
import AppKit
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

// MARK: - Following the engines

/// What a running Gmail engine's folders and drafts are followed by.
struct EngineWatch {
    let engine: ObjectIdentifier
    var tasks: [Task<Void, Never>]
}

extension AppModel {
    /// Follows which accounts are on the Gmail API and which of their engines run.
    func listenToEngines() {
        listeners.append(Task { [weak self] in
            guard let self else { return }
            for await roster in await self.coordinator.rosterUpdates() {
                self.applyRoster(roster)
            }
        })
    }

    /// "Show All Gmail Labels" for each Google account: its engine starts with it, and is told
    /// at once when the owner changes it in the sidebar's menu or in Settings.
    func followLabelsShown() async {
        for account in await store.allAccounts() where GmailLabelsShown.all(for: account.id) {
            await coordinator.setShowsAllLabels(true, accountID: account.id)
        }
        guard labelsShownObserver == nil else { return }
        let coordinator = coordinator
        labelsShownObserver = NotificationCenter.default.addObserver(forName: .falconGmailLabelsShownChanged, object: nil,
                                                                     queue: .main) { note in
            guard let accountID = note.object as? UUID else { return }
            let shown = GmailLabelsShown.all(for: accountID)
            Task { await coordinator.setShowsAllLabels(shown, accountID: accountID) }
        }
    }

    func applyRoster(_ roster: GmailEngineRoster) {
        let left = gmailEngineAccounts.subtracting(roster.gmailAccounts)
        let runningBefore = Set(engineAssemblies.keys)
        gmailEngineAccounts = roster.gmailAccounts
        engineSwitchNotices = roster.notices
        engineAssemblies = roster.running
        for (accountID, assembly) in roster.running where engineWatches[accountID]?.engine != ObjectIdentifier(assembly.engine) {
            watch(assembly, accountID: accountID)
        }
        for accountID in Array(engineWatches.keys) where roster.running[accountID] == nil {
            engineWatches.removeValue(forKey: accountID)?.tasks.forEach { $0.cancel() }
        }
        // Accounts back on IMAP show their stored folders again; accounts on the Gmail API whose
        // engine has not started show none of their IMAP store's.
        for accountID in roster.gmailAccounts where roster.running[accountID] == nil && folders[accountID]?.contains(where: { $0.gmailLabelID == nil && $0.role != .all }) == true {
            folders[accountID] = []
        }
        if !left.isEmpty {
            Task {
                for accountID in left { self.folders[accountID] = await self.store.folders(for: accountID) }
                self.refreshDockBadge()
                await self.reloadMessages()
            }
        }
        if Set(roster.running.keys) != runningBefore {
            mergedList = nil
            let store = storeList
            let index = sharedListIndex
            let engines = roster.gmailAccounts
            Task { await store.share(with: index, engineAccounts: engines) }
        }
        refreshDockBadge()
    }

    private func watch(_ assembly: GmailAccountAssembly, accountID: UUID) {
        engineWatches.removeValue(forKey: accountID)?.tasks.forEach { $0.cancel() }
        let engine = assembly.engine
        let drafts = assembly.drafts
        let folderTask = Task { [weak self] in
            for await list in await engine.folderUpdates() {
                guard let self else { return }
                self.folders[accountID] = list
                self.refreshDockBadge()
                // A folder of the account chosen before its folders were known, as at launch,
                // is shown in the table as soon as they are.
                if !self.engineList.isShown, case .folder(let id)? = self.selection, list.contains(where: { $0.id == id }) {
                    await self.reloadMessages()
                }
            }
        }
        let draftTask = Task { [weak self] in
            for await event in await drafts.events() {
                self?.engineDraftEvent(event, accountID: accountID)
            }
        }
        engineWatches[accountID] = EngineWatch(engine: ObjectIdentifier(engine), tasks: [folderTask, draftTask])
        rekeyCategories(accountID: accountID, assembly: assembly)
        saveLeftoverDrafts(of: accountID)
    }

    /// Messages of the account left over from the last session that could not reach Drafts
    /// before its engine ran go now, as `saveLeftoverDrafts` saves every account's at launch.
    private func saveLeftoverDrafts(of accountID: UUID) {
        guard sessionWindowsRestored else { return }
        let inTabs = (tabs + minimizedTabs).compactMap { tab -> UUID? in
            if case .compose(let id) = tab { return id } else { return nil }
        }
        let open = composeWindowDrafts.union(inTabs)
        for (id, draft) in drafts where draft.accountID == accountID && !open.contains(id) && !unsentDrafts.isSaving(id) {
            closeUnsent(id)
        }
    }

    /// The Inbox a Gmail engine announced new mail from, before the sidebar has its folders.
    func engineInbox(accountID: UUID, folderID: UUID) -> FolderInfo? {
        guard usesGmailEngine(accountID) else { return nil }
        var inbox = FolderInfo(id: folderID, accountID: accountID, path: "INBOX", name: "Inbox", delimiter: "/", role: .inbox,
                               attributes: [], isSelectable: true)
        inbox.gmailLabelID = .inbox
        return inbox
    }

    private func engineDraftEvent(_ event: GmailDraftEvent, accountID: UUID) {
        switch event {
        case .saved(let ref):
            // A save that had waited reached Gmail: the copy on this Mac may go, unless the
            // message is open to be written again.
            let id = ref.localID
            let open = composeWindowDrafts.contains(id) || (tabs + minimizedTabs).contains(.compose(id))
            if !open, drafts[id] != nil { drafts[id] = nil }
            statusText = "Draft saved to \(folder(accountID: accountID, role: .drafts)?.name ?? "Drafts")"
        case .provisional(let list):
            engineProvisionalDrafts[accountID] = list.isEmpty ? nil : list
        }
    }

    // MARK: - The switch, from Settings → Accounts

    /// The owner's switch for the account: on unless he turned it off.
    func gmailEngineChoice(for account: AccountInfo) -> Bool {
        GmailEngineSwitch.isOn(account, in: coordinator.switches)
    }

    /// Turns the account's switch on or off. Nil when it moved, else the sentence that says why
    /// it could not yet.
    @discardableResult
    func setGmailEngine(_ on: Bool, for account: AccountInfo) async -> String? {
        let refused = await coordinator.setGmailEngine(on, for: account)
        applyRoster(await coordinator.roster)
        if let refused { engineSwitchNotices[account.id] = refused }
        await reloadMessages()
        return refused
    }

    // MARK: - Outlook's categories, re-keyed to Gmail's ids

    /// Adds, beside each category kept for a stored row of the account, the same category under
    /// its Gmail row's id, once, in the background and in batches of 50, keeping every old key
    /// (§12.2). Carried on at each start until every key has been looked at.
    private func rekeyCategories(accountID: UUID, assembly: GmailAccountAssembly) {
        guard !categoriesRekeying.contains(accountID) else { return }
        let files = GmailFiles(layout: layout, accountID: accountID)
        let record = GmailMigrationFile(files: files).load()
        let rekeyer = GmailCategoryRekeyer(accountID: accountID, reader: LegacyStoreReader(layout: layout, accountID: accountID),
                                           matcher: GmailMessageMatcher(accountID: accountID, transport: assembly.transport))
        var done = Set(record.categoryKeysDone ?? [])
        guard !rekeyer.keysToRekey(in: categoryAssignments, done: done).isEmpty else { return }
        categoriesRekeying.insert(accountID)
        Task { [weak self] in
            defer { self?.categoriesRekeying.remove(accountID) }
            while let self, !Task.isCancelled {
                let result = await rekeyer.rekey(self.categoryAssignments, done: done, limit: 50)
                if !result.added.isEmpty { self.categoryAssignments = GmailCategoryRekeyer.merged(self.categoryAssignments, with: result) }
                done.formUnion(result.done)
                let finished = done
                GmailMigrationFile(files: files).update { record in
                    record.categoryKeysDone = Array(finished).sorted()
                    record.legacyCategoryKeys = Array(Set((record.legacyCategoryKeys ?? []) + result.legacy)).sorted()
                }
                if result.interrupted || result.done.isEmpty { return }
                if rekeyer.keysToRekey(in: self.categoryAssignments, done: done).isEmpty {
                    Log.info("gmail", "\(self.accountName(accountID)): categories now follow Gmail's ids")
                    return
                }
            }
        }
    }
}

// MARK: - Actions

/// The status line and Undo banner's words for changes the Gmail engine made, as the IMAP
/// engine's are worded.
enum EngineActionText {
    static func verbTitle(_ verb: MailActionRequest.Verb) -> String {
        switch verb {
        case .markRead: return "Mark as Read"
        case .markUnread: return "Mark as Unread"
        case .flag: return "Flag"
        case .unflag: return "Unflag"
        case .archive: return "Archive"
        case .move: return "Move"
        case .copy: return "Copy"
        case .delete: return "Delete"
        case .deleteForever: return "Delete"
        case .junk: return "Junk"
        case .notJunk: return "Not Junk"
        case .mute: return "Ignore"
        case .unmute: return "Stop Ignoring"
        case .moveToFocused: return "Move to Focused"
        case .moveToOther: return "Move to Other"
        }
    }

    static func summary(_ receipts: [ActionReceipt], folderName: (UUID) -> String?) -> String {
        guard let first = receipts.first else { return "" }
        let count = receipts.reduce(0) { $0 + $1.messageCount }
        let subject = "\(count) \(MailActionRecord.noun(count))"
        switch first.verb {
        case .markRead: return "Marked \(subject) as read"
        case .markUnread: return "Marked \(subject) as unread"
        case .flag: return "Flagged \(subject)"
        case .unflag: return "Unflagged \(subject)"
        case .archive: return "Archived \(subject)"
        case .move(let to): return folderName(to).map { "Moved \(subject) to \($0)" } ?? "Moved \(subject)"
        case .copy(let to): return folderName(to).map { "Copied \(subject) to \($0)" } ?? "Copied \(subject)"
        case .delete, .deleteForever: return "Deleted \(subject)"
        case .junk: return "Moved \(subject) to Junk Email"
        case .notJunk: return "Moved \(subject) to the Inbox"
        case .mute: return "Ignored \(subject)"
        case .unmute: return "Stopped ignoring \(subject)"
        case .moveToFocused: return "Moved \(subject) to Focused"
        case .moveToOther: return "Moved \(subject) to Other"
        }
    }

    /// Moving to one of Gmail's own folders is that folder's action (§7.1).
    static func moveVerb(to folder: FolderInfo) -> MailActionRequest.Verb {
        switch folder.role {
        case .all: return .archive
        case .trash: return .delete
        case .junk: return .junk
        default: return .move(to: folder.id)
        }
    }
}

extension AppModel {
    /// The view a change to `message` is made in: the one the list shows when the message was
    /// read in it, else the one its window or tab was opened from, else the folder the row was
    /// seen in. A Gmail message is in many folders at once, so the folder's rules come from where
    /// the owner was looking, never from a stored row (§7.2): Archive in a window opened from Sent
    /// follows Sent's rules whatever folder the list shows.
    func engineContext(for message: MessageSummary) -> ListView {
        let opened = engineList.openedView(for: message.id)
        if let view = listView(for: selection) {
            switch view.scope {
            case .allInboxes where opened == nil, .search where opened == nil: return view
            case .folder(let id) where id == message.folderID: return view
            default: break
            }
        }
        return opened ?? ListView(scope: .folder(message.folderID), conversations: false)
    }

    /// A change to messages of one Google account on the Gmail API, in pieces of at most 1,000.
    func performOnEngine(_ verb: MailActionRequest.Verb, _ group: [MessageSummary], accountID: UUID,
                         conversations: Bool = false) async throws -> [ActionReceipt] {
        let keys = group.compactMap { RowKey(string: $0.id) }.filter(\.isGmail)
        guard let first = group.first, !keys.isEmpty else { return [] }
        let context = engineContext(for: first)
        var receipts: [ActionReceipt] = []
        for start in stride(from: 0, to: keys.count, by: ActionTargets.largestItemList) {
            let chunk = keys[start..<min(start + ActionTargets.largestItemList, keys.count)]
            let items = chunk.map { conversations ? ActionItem.conversation($0) : ActionItem.message($0) }
            let receipt = try await coordinator.perform(MailActionRequest(verb: verb, targets: .items(items), context: context),
                                                        accountID: accountID)
            receipts.append(receipt)
        }
        if let notice = receipts.compactMap(\.notice).first { statusText = notice }
        return receipts
    }

    /// A change to every message of a view, described by the view rather than by its ids, as
    /// Delete All and Mark All as Read are (§7.4).
    func performOnEngineView(_ verb: MailActionRequest.Verb, in view: ListView, accountID: UUID) {
        Task {
            do {
                let receipt = try await coordinator.perform(MailActionRequest(verb: verb, targets: .wholeView(except: []), context: view),
                                                            accountID: accountID)
                if let notice = receipt.notice { statusText = notice }
            } catch {
                showActionError(error.localizedDescription, names: Log.names(heldBy: error))
            }
        }
    }

    /// The table's actions, by row keys, in the view they were taken in: through the Gmail engine
    /// for a Google account on the Gmail API. Stored rows' actions go through the stored rows'
    /// own paths, which take their summaries.
    @discardableResult
    func perform(_ verb: MailActionRequest.Verb, on targets: ActionTargets, in view: ListView, accountID: UUID) async -> ActionReceipt? {
        do {
            let receipt = try await coordinator.perform(MailActionRequest(verb: verb, targets: targets, context: view), accountID: accountID)
            if let notice = receipt.notice { statusText = notice }
            offerUndo([], receipts: [receipt])
            return receipt
        } catch {
            showActionError(error.localizedDescription, names: Log.names(heldBy: error))
            return nil
        }
    }

    /// Ignore and Stop Ignoring on the Gmail engine: its mutes file the conversation away now and
    /// its later mail as it arrives, and Stop Ignoring leaves no twin record behind (§7.6).
    func muteOnEngine(_ threads: [MessageThread], mute: Bool) {
        for (accountID, group) in Dictionary(grouping: threads, by: { $0.latest.accountID }) {
            let latest = group.map(\.latest)
            Task {
                do {
                    let receipts = try await performOnEngine(mute ? .mute : .unmute, latest, accountID: accountID, conversations: true)
                    mutedThreads = await mutes.all()
                    if mute {
                        removeFromList(group.flatMap(\.messages))
                        statusText = group.count == 1 ? "Muted: \(latest[0].subject.isEmpty ? "(no subject)" : latest[0].subject)"
                            : "Muted \(group.count) conversations"
                        offerUndo([], receipts: receipts)
                    }
                } catch {
                    showActionError(error.localizedDescription, names: Log.names(heldBy: error))
                }
            }
        }
    }

    // MARK: - Opening

    /// A Gmail row's message through its engine: from the Mac for the newest 1,000, otherwise
    /// from Gmail into memory, its text first and its pictures after. Nil while the account's
    /// engine is not running.
    func engineBody(for message: MessageSummary, purpose: OpenPurpose) async throws -> MIMEMessage? {
        guard let key = RowKey(string: message.id), key.isGmail else { return nil }
        if let opened = openedServerMessages[message.id], opened.pendingInlineImages.isEmpty { return opened.message }
        guard let assembly = await runningAssembly(message.accountID) else { return nil }
        var last: GmailOpenedMessage?
        for try await stage in await assembly.engine.open(key, purpose: purpose) {
            last = stage.content
            remember(stage.content, for: message.id)
        }
        return last?.message
    }

    /// The whole message as Gmail holds it, in memory only.
    func engineRawMessage(_ message: MessageSummary) async -> Data? {
        guard let key = RowKey(string: message.id), key.isGmail, let assembly = await runningAssembly(message.accountID) else { return nil }
        return try? await assembly.engine.rawMessage(key)
    }

    /// An attachment of a Gmail row, fetched when it is opened, saved or forwarded.
    func engineAttachmentData(_ message: MessageSummary, _ stub: GmailAttachmentStub) async throws -> Data? {
        guard let key = RowKey(string: message.id), key.isGmail, let assembly = await runningAssembly(message.accountID) else { return nil }
        return try await assembly.engine.attachmentData(stub, of: key)
    }

    /// Whether a message's attachments are known by name and size only and fetched when opened:
    /// a row found only on Gmail, and any message of a Google account on the Gmail API.
    func fetchesAttachmentsFromGmail(_ message: MessageSummary) -> Bool {
        message.isServerOnly || usesGmailEngine(message.accountID)
    }

    /// The account's running engine, asked of the coordinator when the roster has not reached
    /// the app yet, as at launch.
    func runningAssembly(_ accountID: UUID) async -> GmailAccountAssembly? {
        if let known = engineAssemblies[accountID] { return known }
        return await coordinator.assembly(for: accountID)
    }

    /// A Gmail row's details for a window or tab that has only its key, in the view it was seen
    /// in, or the account's Inbox. While Gmail cannot be reached the last details known are
    /// given, so a window stays open with what it had; nil only when the message is gone.
    func engineMessage(id: String) async -> MessageSummary? {
        guard let key = RowKey(string: id), key.isGmail, let accountID = key.accountID else { return nil }
        let view = engineList.openedView(for: id) ?? listView(for: selection).flatMap { view -> ListView? in
            if case .folder(let folderID) = view.scope, folder(folderID)?.accountID != accountID { return nil }
            return view
        } ?? folder(accountID: accountID, role: .inbox).map { ListView(scope: .folder($0.id), conversations: false) }
            ?? ListView(scope: .allInboxes)
        guard let assembly = await runningAssembly(accountID) else { return engineSummaries[id] }
        switch await assembly.list.summary(for: key, in: view) {
        case .available(let summary):
            engineSummaries[id] = summary
            return summary
        case .gone:
            engineSummaries[id] = nil
            return nil
        case .unavailable:
            return engineSummaries[id]
        }
    }

    // MARK: - Drafts (§8.4)

    /// The link a message being written has to its Gmail draft.
    func engineDraftRef(for draft: ComposeDraft, account: AccountInfo, assembly: GmailAccountAssembly) async -> DraftRef {
        await GmailDraftLinking.ref(localID: draft.id, accountID: account.id, email: account.email, threadID: draft.gmailThreadID,
                                    reopenedFrom: draft.sourceMessage, drafts: assembly.drafts)
    }

    /// Saves a message closed, or saved, to Gmail's Drafts: created the first time, updated after.
    /// Throws `DraftsUnavailable` while the engine is not running, and `GmailDraftDeferred` while
    /// Gmail cannot take it, when it goes by itself later; either way the copy on this Mac stays.
    func saveEngineDraft(_ draft: ComposeDraft, account: AccountInfo, reason: DraftSaveReason) async throws {
        guard let assembly = await runningAssembly(account.id) else { throw DraftsUnavailable() }
        let raw = MIMEBuilder.build(try draft.outgoing(from: account, requireRecipients: false))
        let ref = await engineDraftRef(for: draft, account: account, assembly: assembly)
        _ = try await assembly.drafts.save(raw, as: ref, bcc: AddressParser.parse(draft.bcc), reason: reason)
    }

    /// The automatic save while a message is written on the Gmail engine, at most once a minute
    /// while its content changes (open question 14).
    func autosaveEngineDraft(_ draft: ComposeDraft) {
        guard usesGmailEngine(draft.accountID), !draft.isBlank, !draft.isUntouched,
              let account = accounts.first(where: { $0.id == draft.accountID }) else { return }
        let now = Date()
        if let last = engineAutosavedAt[draft.id], now.timeIntervalSince(last) < 60 { return }
        engineAutosavedAt[draft.id] = now
        Task {
            guard let assembly = await runningAssembly(account.id),
                  let raw = try? MIMEBuilder.build(draft.outgoing(from: account, requireRecipients: false)) else { return }
            let ref = await engineDraftRef(for: draft, account: account, assembly: assembly)
            _ = try? await assembly.drafts.autosave(raw, as: ref, bcc: AddressParser.parse(draft.bcc))
        }
    }

    /// Discard on the Gmail engine: Gmail's copy is deleted once Undo is over, and a quit
    /// meanwhile finishes the delete rather than saving the message back.
    func discardEngineDraft(_ draft: ComposeDraft) {
        guard usesGmailEngine(draft.accountID), let account = accounts.first(where: { $0.id == draft.accountID }) else { return }
        engineAutosavedAt[draft.id] = nil
        Task {
            guard let assembly = await runningAssembly(account.id) else { return }
            let ref = await engineDraftRef(for: draft, account: account, assembly: assembly)
            await assembly.drafts.discard(ref, undoWindow: DiscardedMessage<ComposeDraft>.undoWindow)
        }
    }

    /// Undo of Discard: Gmail's copy is kept, still linked to the message.
    func undoEngineDiscard(_ draft: ComposeDraft) {
        guard usesGmailEngine(draft.accountID) else { return }
        Task { _ = await runningAssembly(draft.accountID)?.drafts.undoDiscard(draft.id) }
    }

    /// A message closed with nothing to keep: a Gmail draft this session's automatic save made
    /// for it is deleted again, so no stray copy stays in Drafts.
    func closeEngineDraftQuietly(_ draft: ComposeDraft) {
        guard usesGmailEngine(draft.accountID), let account = accounts.first(where: { $0.id == draft.accountID }) else { return }
        engineAutosavedAt[draft.id] = nil
        Task {
            guard let assembly = await runningAssembly(account.id) else { return }
            let ref = await engineDraftRef(for: draft, account: account, assembly: assembly)
            await assembly.drafts.closeWithoutSaving(ref)
        }
    }

    /// The conversation a message sent from the Gmail engine goes in, and the Gmail draft that
    /// goes once the send is confirmed. Nothing for any other account.
    func engineDraftLink(for draft: ComposeDraft, account: AccountInfo) async -> (thread: GmailThreadID?, draftID: String?) {
        guard usesGmailEngine(account.id), let assembly = await runningAssembly(account.id) else { return (nil, nil) }
        let ref = await engineDraftRef(for: draft, account: account, assembly: assembly)
        let handed = await assembly.drafts.handOver(draft.id)
        engineAutosavedAt[draft.id] = nil
        return (draft.gmailThreadID ?? handed?.threadID ?? ref.threadID, handed?.gmailDraftID ?? ref.gmailDraftID)
    }

    /// A copy in Drafts that a discarded message left, on a Google account on the Gmail API: its
    /// Gmail draft, found by its Gmail id or, for one saved over IMAP before the switch, by its
    /// Message-ID, and deleted. Throws while the engine is not running, to try again later.
    func deleteEngineDraftCopy(_ row: MessageSummary) async throws {
        guard let assembly = await runningAssembly(row.accountID) else { throw DraftsUnavailable() }
        let ref = await GmailDraftLinking.ref(localID: UUID(), accountID: row.accountID, email: accountName(row.accountID), threadID: nil,
                                              reopenedFrom: row, drafts: assembly.drafts)
        guard ref.gmailDraftID != nil else { return }
        try await assembly.drafts.delete(ref)
    }

    // MARK: - Notifications (§4.7)

    /// A notification's button on a Gmail row: the change goes through the Gmail engine as if
    /// made in the Inbox, and can be undone as any other.
    func applyFromEngineNotification(_ action: MailNotificationAction, messageID: String) {
        let verb: MailNotificationVerb
        switch action {
        case .archive: verb = .archive
        case .delete: verb = .delete
        case .markRead: verb = .markRead
        case .flag: verb = .flag
        case .reveal: return reveal(messageID: messageID)
        }
        Task {
            do {
                guard let receipt = try await coordinator.actOnNotification(verb, messageID: messageID) else {
                    showActionError("\(accountName(RowKey(string: messageID)?.accountID ?? UUID())) isn't connected, so this wasn't done.")
                    return
                }
                offerUndo([], receipts: [receipt])
            } catch {
                showActionError(error.localizedDescription)
            }
        }
    }

    /// Clicking a notification of a Gmail row: its Inbox is shown, on Focused or Other as its
    /// category puts it when Focused Inbox is on, and the row is selected.
    func revealEngineMessage(_ messageID: String) {
        Task {
            guard let target = await coordinator.notificationTarget(messageID: messageID) else {
                statusText = "That message is no longer here"
                return
            }
            switch target.availability {
            case .gone:
                statusText = "This message was moved or deleted on another device."
                return
            case .unavailable(let reason):
                statusText = reason
            case .available(let summary):
                engineSummaries[messageID] = summary
                let other: Set<GmailLabelID> = [.categorySocial, .categoryPromotions, .categoryForums]
                let labels = Set(summary.labelIDs ?? [])
                focusedTab = labels.isDisjoint(with: other) ? .focused : .other
            }
            cancelPendingRead()
            resetSearch()
            if !pinFilters { filtersStorage = [] }
            if !alreadyShowing(target.inbox.id) { selection = .folder(target.inbox.id) }
            pendingReveal = target.key
            selectedMessageIDs = [messageID]
            await reloadMessages()
            saveSession()
        }
    }
}

/// The account's Drafts folder cannot be reached for now, as while it is being set up or its
/// syncing is off: the message stays on this Mac, to be saved later, and nothing is said.
struct DraftsUnavailable: Error {}

// MARK: - How often the Gmail engines check

extension AppModel {
    /// The Gmail engines check every 30 seconds while the owner has used the Mac in the last half
    /// hour, in FalconMail or any other app, every 2 minutes after that or with the screen locked,
    /// and not at all while the Mac sleeps (§4.1). What the owner does is read from the system's
    /// own count of seconds since the last input, once a minute, which needs no permission.
    func followOwnerActivity() {
        guard activityObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let coordinator = coordinator
        func tell(_ activity: OwnerActivity) { Task { await coordinator.noteOwnerActivity(activity) } }
        activityObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            tell(.asleep)
        })
        activityObservers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            tell(.idle(since: Date()))
        })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            activityObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in tell(.active(at: Date())) })
        }
        listeners.append(Task(priority: .utility) {
            while !Task.isCancelled {
                // The last input, whenever it was: the engines keep the half-minute pace for half
                // an hour after it.
                await coordinator.noteOwnerActivity(.active(at: Date().addingTimeInterval(-AppModel.secondsSinceInput())))
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        })
    }

    nonisolated static func secondsSinceInput() -> TimeInterval {
        guard let any = CGEventType(rawValue: UInt32.max) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }
}
