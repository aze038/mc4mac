import SwiftUI
import Observation
import AppKit
import FalconCore

enum FocusedTab: String, CaseIterable, Identifiable {
    case focused, other

    var id: String { rawValue }
    var title: LocalizedStringKey { self == .focused ? "Focused" : "Other" }
}

enum SmartFolder: String, Hashable, Codable, CaseIterable {
    case unread, flagged, attachments

    var scope: MessageScope {
        switch self {
        case .unread: return .unread
        case .flagged: return .flagged
        case .attachments: return .attachments
        }
    }

    var title: String {
        switch self {
        case .unread: return "Unread"
        case .flagged: return "Flagged"
        case .attachments: return "With Attachments"
        }
    }

    func matches(_ message: MessageSummary) -> Bool {
        switch self {
        case .unread: return !message.isRead
        case .flagged: return message.isFlagged
        case .attachments: return message.hasAttachments
        }
    }
}

enum SidebarSelection: Hashable, Codable {
    case unified
    case smart(SmartFolder)
    case folder(UUID)
    case archive(UUID)
    case calendar
    case contacts
    case outbox
}

enum MarkReadPolicy: String, CaseIterable, Identifiable {
    case delay, never

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .delay: return "After a delay"
        case .never: return "Never"
        }
    }
}

enum AdvanceAfterAction: String, CaseIterable, Identifiable {
    case next, previous, list

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .next: return "Select the next message"
        case .previous: return "Select the previous message"
        case .list: return "Go back to the list"
        }
    }
}

enum MessageFilter: String, CaseIterable, Identifiable {
    case unread, flagged

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .unread: return "Unread"
        case .flagged: return "Flagged"
        }
    }

    var symbol: String {
        switch self {
        case .unread: return "envelope.badge"
        case .flagged: return "flag"
        }
    }

    func matches(_ message: MessageSummary) -> Bool {
        switch self {
        case .unread: return !message.isRead
        case .flagged: return message.isFlagged
        }
    }
}

struct PendingUndo: Identifiable {
    let id = UUID()
    var records: [MailActionRecord]
    var summary: String
    var verbTitle: String
}

struct MessageThread: Identifiable, Hashable {
    var id: String { latest.id }
    var messages: [MessageSummary]
    var latest: MessageSummary { messages[0] }
    var unreadCount: Int { messages.filter { !$0.isRead }.count }
}

@MainActor
@Observable
final class AppModel {
    let layout = FileLayout()
    let store: MailStore
    let tokens: TokenStore
    let rules: RuleStore
    let mutes: MuteStore
    let indexer = SpotlightIndexer()
    let coordinator: SyncCoordinator
    let outbox: Outbox
    let contacts: ContactStore
    let archives: ArchiveRecordStore
    let notifications = NotificationService()
    let updates = UpdateManager()
    let session: SessionStore
    let moveTargets: MoveTargets
    /// A variable only so the debug snapshots can show stand-in signatures.
    var signatures: SignatureLibrary

    var accounts: [AccountInfo] = [] {
        didSet { myAddressCache = Set(accounts.map { $0.email.lowercased() }) }
    }
    var folders: [UUID: [FolderInfo]] = [:] {
        didSet { rebuildFolderIndex() }
    }
    @ObservationIgnored private var folderByID: [UUID: FolderInfo] = [:]
    @ObservationIgnored private var junkFolderIDCache = Set<UUID>()
    var unifiedUnread = 0
    var selection: SidebarSelection? = .unified
    var messages: [MessageSummary] = []
    var threads: [MessageThread] = []
    var selectedMessageIDs = Set<String>()
    var expandedThreadIDs = Set<String>() {
        didSet { if expandedThreadIDs != oldValue { rebuildRows() } }
    }
    /// The rendered row list. Kept as stored state because building it walks every thread, and
    /// SwiftUI reads it on each body evaluation.
    var rowCache: [ListRow] = []
    var rowIndex: [String: ListRow] = [:]
    var accountsNeedingSignIn = Set<UUID>()
    @ObservationIgnored var lastMailSelection: SidebarSelection?
    var isSearching = false
    var statusText = "Ready"
    var online: [UUID: Bool] = [:]
    var outboxItems: [OutboxItem] = []
    var archiveRecords: [ArchiveRecord] = []
    var errorMessage: String?
    var actionError: String?
    var actionErrorNeedsDismissal = false
    var pendingUndo: PendingUndo?
    var contactList: [ContactInfo] = [] {
        didSet { contactAddressCache = Set(contactList.map { $0.email.lowercased() }) }
    }
    @ObservationIgnored private var contactAddressCache = Set<String>()
    @ObservationIgnored private var myAddressCache = Set<String>()
    var openMessageWindows = Set<String>()
    var tabs: [WorkspaceTab] = []
    var minimizedTabs: [WorkspaceTab] = []
    var activeTab: WorkspaceTab?
    var tabTitles: [String: String] = [:]
    var cacheSizeBytes = 0
    var showsMovePalette = false
    var focusSearchToken = 0
    var keyChordHint: String?
    var mutedThreads: [MutedThread] = []
    var syncingAccounts: Set<UUID> = []
    var categoryCache: [MailCategory] = CategoryStore.load()
    var categoryAssignments: [String: [String]] = CategoryStore.assignments() {
        didSet { CategoryStore.saveAssignments(categoryAssignments) }
    }
    var workOffline = Preferences.bool(Pref.offlineMode, default: false)
    var allAccountsExpanded = true
    /// How many messages the list holds. Growing this is what "Load older messages" does first;
    /// only once the window covers everything stored does it ask the server for more.
    var listWindow = AppModel.listPageSize
    var storedInSelection = 0
    static let listPageSize = 300
    var focusedTab = FocusedTab.focused
    private var listDensityStorage = Preferences.string("listDensity", default: ListDensity.cozy.rawValue)
    var listDensity: ListDensity {
        get { ListDensity.stored(listDensityStorage) }
        set { listDensityStorage = newValue.rawValue; Preferences.set(newValue.rawValue, "listDensity") }
    }

    var downloadedToday: [UUID: Int] = [:]

    func refreshBandwidth() async {
        var out: [UUID: Int] = [:]
        for account in accounts { out[account.id] = await BandwidthMeter.shared.spentToday(account.id) }
        downloadedToday = out
    }

    var offlineAccounts: [AccountInfo] {
        guard accountsNeedingSignIn.isEmpty else { return [] }
        return accounts.filter { $0.isEnabled && online[$0.id] == false }
    }

    var syncingSummary: String? {
        let names = accounts.filter { syncingAccounts.contains($0.id) }.map(\.email)
        guard !names.isEmpty else { return nil }
        return names.count == 1 ? "Syncing \(names[0])" : "Syncing \(names.count) accounts"
    }
    private var collapsedAccountsStorage = Set(Preferences.string("collapsedAccounts", default: "").split(separator: ",").map(String.init))

    func isAccountExpanded(_ id: UUID) -> Bool { !collapsedAccountsStorage.contains(id.uuidString) }

    func setAccountExpanded(_ id: UUID, _ expanded: Bool) {
        if expanded { collapsedAccountsStorage.remove(id.uuidString) } else { collapsedAccountsStorage.insert(id.uuidString) }
        Preferences.set(collapsedAccountsStorage.sorted().joined(separator: ","), "collapsedAccounts")
    }
    var notificationPolicy = NotificationPolicy()
    var migrationInProgress = false

    private var searchTextStorage = ""
    var searchText: String {
        get { searchTextStorage }
        set {
            guard newValue != searchTextStorage else { return }
            searchTextStorage = newValue
            searchTextDidChange()
        }
    }

    private var filtersStorage: Set<MessageFilter> = []
    var filters: Set<MessageFilter> {
        get { filtersStorage }
        set {
            guard newValue != filtersStorage else { return }
            filtersStorage = newValue
            rebuildThreads()
        }
    }

    private var draftsStorage: [UUID: ComposeDraft] = [:]
    var drafts: [UUID: ComposeDraft] {
        get { draftsStorage }
        set {
            let old = draftsStorage
            draftsStorage = newValue
            for (id, d) in newValue where old[id] != d { scheduleDraftSave(id) }
            for id in old.keys where newValue[id] == nil { pendingDraftSaves[id]?.cancel(); pendingDraftSaves[id] = nil; session.removeDraft(id) }
        }
    }

    private var listSortStorage = Preferences.string("listSort", default: ListSort.date.rawValue)
    private var sortAscendingStorage = Preferences.bool("listSortAscending", default: false)
    var sortAscending: Bool {
        get { sortAscendingStorage }
        set { sortAscendingStorage = newValue; Preferences.set(newValue, "listSortAscending"); rebuildThreads() }
    }
    private var showInGroupsStorage = Preferences.bool("showInGroups", default: false)
    var showInGroups: Bool {
        get { showInGroupsStorage }
        set { showInGroupsStorage = newValue; Preferences.set(newValue, "showInGroups"); rebuildThreads() }
    }

    func restoreListDefaults() {
        listSort = ListSort.date.rawValue
        sortAscending = false
        showInGroups = false
        groupByThread = true
    }
    var listSort: String {
        get { listSortStorage }
        set { listSortStorage = newValue; Preferences.set(newValue, "listSort"); rebuildThreads() }
    }
    private var groupByThreadStorage = Preferences.bool("groupByThread", default: true)
    var groupByThread: Bool {
        get { groupByThreadStorage }
        set { groupByThreadStorage = newValue; Preferences.set(newValue, "groupByThread"); rebuildThreads() }
    }
    private var undoSendSecondsStorage = Preferences.int("undoSendSeconds", default: 10)
    var undoSendSeconds: Int {
        get { undoSendSecondsStorage }
        set { undoSendSecondsStorage = newValue; Preferences.set(newValue, "undoSendSeconds") }
    }
    private var loadRemoteImagesStorage = Preferences.bool("loadRemoteImages", default: false)
    var loadRemoteImages: Bool {
        get { loadRemoteImagesStorage }
        set { loadRemoteImagesStorage = newValue; Preferences.set(newValue, "loadRemoteImages") }
    }
    private var openInWindowStorage = Preferences.bool("openInWindowOnDoubleClick", default: false)
    var openInWindowOnDoubleClick: Bool {
        get { openInWindowStorage }
        set { openInWindowStorage = newValue; Preferences.set(newValue, "openInWindowOnDoubleClick") }
    }
    private var appearanceStorage = Preferences.string("appearance", default: AppAppearance.system.rawValue)
    var appearance: String {
        get { appearanceStorage }
        set { appearanceStorage = newValue; Preferences.set(newValue, "appearance") }
    }
    private var offlineBodiesStorage = Preferences.int("offlineBodies", default: 150)
    var offlineBodies: Int {
        get { offlineBodiesStorage }
        set { offlineBodiesStorage = newValue; Preferences.set(newValue, "offlineBodies"); applyOfflineSettings() }
    }
    private var maxOfflineMBStorage = Preferences.int("maxOfflineMB", default: 5)
    var maxOfflineMB: Int {
        get { maxOfflineMBStorage }
        set { maxOfflineMBStorage = newValue; Preferences.set(newValue, "maxOfflineMB"); applyOfflineSettings() }
    }
    private var markReadPolicyStorage = Preferences.string("markReadPolicy", default: MarkReadPolicy.delay.rawValue)
    var markReadPolicy: String {
        get { markReadPolicyStorage }
        set { markReadPolicyStorage = newValue; Preferences.set(newValue, "markReadPolicy"); cancelPendingRead() }
    }
    private var markReadDelayStorage = Preferences.int("markReadDelaySeconds", default: 2)
    var markReadDelaySeconds: Int {
        get { markReadDelayStorage }
        set { markReadDelayStorage = newValue; Preferences.set(newValue, "markReadDelaySeconds"); cancelPendingRead() }
    }
    private var undoActionSecondsStorage = Preferences.int("undoActionSeconds", default: 5)
    var undoActionSeconds: Int {
        get { undoActionSecondsStorage }
        set { undoActionSecondsStorage = newValue; Preferences.set(newValue, "undoActionSeconds"); applyUndoWindow() }
    }
    private var advanceAfterActionStorage = Preferences.string("advanceAfterAction", default: AdvanceAfterAction.next.rawValue)
    var advanceAfterAction: String {
        get { advanceAfterActionStorage }
        set { advanceAfterActionStorage = newValue; Preferences.set(newValue, "advanceAfterAction") }
    }
    private var singleKeyShortcutsStorage = Preferences.bool(AppModel.singleKeyShortcutsKey, default: true)
    var singleKeyShortcuts: Bool {
        get { singleKeyShortcutsStorage }
        set { singleKeyShortcutsStorage = newValue; Preferences.set(newValue, AppModel.singleKeyShortcutsKey) }
    }
    private var pinFiltersStorage = Preferences.bool("pinFilters", default: false)
    var pinFilters: Bool {
        get { pinFiltersStorage }
        set { pinFiltersStorage = newValue; Preferences.set(newValue, "pinFilters") }
    }
    private var dockBadgeStorage = Preferences.bool("dockBadge", default: true)
    var dockBadge: Bool {
        get { dockBadgeStorage }
        set { dockBadgeStorage = newValue; Preferences.set(newValue, "dockBadge"); refreshDockBadge() }
    }

    static let singleKeyShortcutsKey = "singleKeyShortcuts"

    private var readPolicy: MarkReadPolicy { MarkReadPolicy(rawValue: markReadPolicyStorage) ?? .delay }
    private var advancePolicy: AdvanceAfterAction { AdvanceAfterAction(rawValue: advanceAfterActionStorage) ?? .next }

    @ObservationIgnored private var restoredState: SessionState?
    @ObservationIgnored private var knownSentIDs = Set<UUID>()
    @ObservationIgnored private var soundGate = MailSoundGate(isEnabled: SoundLibrary.isEnabled)
    @ObservationIgnored private var bodyCache: [String: MIMEMessage] = [:]
    @ObservationIgnored private var listeners: [Task<Void, Never>] = []
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var sessionSaveTask: Task<Void, Never>?
    @ObservationIgnored private var pendingDraftSaves: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var pendingReadID: String?
    @ObservationIgnored private var actionErrorTask: Task<Void, Never>?
    @ObservationIgnored private var searchDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var liveSearchNeedle = ""
    @ObservationIgnored private var submittedSearchQuery: String?
    @ObservationIgnored private var undoExpiryTask: Task<Void, Never>?
    @ObservationIgnored var openMainWindow: (@MainActor () -> Void)?
    @ObservationIgnored var openComposeWindow: (@MainActor (UUID) -> Void)?

    private func applyOfflineSettings() {
        Task { await coordinator.setBodyPrefetch(offlineBodies, maxBytes: maxOfflineMB * 1024 * 1024) }
    }

    private func applyUndoWindow() {
        Task { await coordinator.setUndoWindow(TimeInterval(undoActionSeconds)) }
    }

    private func scheduleDraftSave(_ id: UUID) {
        pendingDraftSaves[id]?.cancel()
        pendingDraftSaves[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self, let d = self.draftsStorage[id] else { return }
            self.session.saveDraft(d)
            self.pendingDraftSaves[id] = nil
        }
    }

    init() {
        let store = MailStore(layout: layout)
        let tokens = TokenStore { OAuthConfigLoader.load() }
        let rules = RuleStore(layout: layout)
        let mutes = MuteStore(layout: layout)
        self.store = store
        self.tokens = tokens
        self.rules = rules
        self.mutes = mutes
        let coordinator = SyncCoordinator(store: store, tokens: tokens, rules: rules, mutes: mutes, indexer: indexer,
                                          pendingActions: PendingActionStore(layout: layout))
        self.coordinator = coordinator
        self.outbox = Outbox(layout: layout, sender: SMTPSender(store: store, tokens: tokens, coordinator: coordinator), undoWindow: 10)
        self.contacts = ContactStore(layout: layout)
        self.archives = ArchiveRecordStore(layout: layout)
        self.session = SessionStore(layout: layout)
        self.moveTargets = MoveTargets(layout: layout)
        self.signatures = SignatureLibrary(store: SignatureStore(layout: layout))
    }

    func bootstrap() async {
        SoundLibrary.carryOverEarlierChoices()
        play(soundGate.launched())
        do { try await store.load() } catch { errorMessage = error.localizedDescription }
        restoredState = session.load()
        for d in session.loadDrafts() { drafts[d.id] = d }
        if let s = restoredState {
            selection = s.selection ?? .unified
            searchText = s.searchText
        }
        updates.beforeRelaunch = { [weak self] in await self?.prepareForRelaunch() }
        updates.start()
        await coordinator.setBodyPrefetch(offlineBodies, maxBytes: maxOfflineMB * 1024 * 1024)
        await coordinator.setUndoWindow(TimeInterval(undoActionSeconds))
        await refreshAccounts()
        archiveRecords = await archives.all()
        mutedThreads = await mutes.all()
        notificationPolicy = NotificationPolicy.load(layout: layout)
        contactList = await contacts.all()
        await notifications.requestPermission()
        listen()
        await coordinator.startAll()
        await reloadMessages()
        if let s = restoredState {
            let ids = Set(s.selectedMessageIDs)
            selectedMessageIDs = ids.filter { rowIndex[$0] != nil }
            await restoreTabs(s.openTabs, minimized: s.minimizedTabs, active: s.activeTab)
        }
        Task { await syncContacts() }
    }

    var windowsToRestore: [String] {
        let state = restoredState
        restoredState = nil
        saveLeftoverDrafts()
        return state?.openMessageWindows ?? []
    }

    func currentSessionState() -> SessionState {
        SessionState(selection: selection, selectedMessageIDs: Array(selectedMessageIDs), searchText: searchText,
                     openMessageWindows: Array(openMessageWindows), openDraftIDs: Array(drafts.keys),
                     openTabs: tabs, minimizedTabs: minimizedTabs, activeTab: activeTab)
    }

    func saveSession() {
        sessionSaveTask?.cancel()
        sessionSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            self.session.save(self.currentSessionState())
        }
    }

    func saveSessionNow() {
        sessionSaveTask?.cancel()
        session.save(currentSessionState())
    }

    func prepareForRelaunch() async {
        saveSessionNow()
        signatures.saveNow()
        for d in drafts.values { session.saveDraft(d) }
        await store.flushAll()
        let wind = Task {
            await self.flushPendingActions()
            await self.coordinator.stopAll()
        }
        let timeout = Task { _ = try? await Task.sleep(nanoseconds: 2_000_000_000) }
        _ = await Task.select(wind, timeout)
    }

    private func listen() {
        listeners.append(Task { [weak self] in
            guard let self else { return }
            for await change in await self.store.changes() {
                switch change {
                case .accountsChanged: await self.refreshAccounts()
                case .foldersChanged(let accountID):
                    self.folders[accountID] = await self.store.folders(for: accountID)
                    self.refreshDockBadge()
                case .messagesChanged(let folderID): self.scheduleReload(for: folderID)
                case .contactsChanged: self.contactList = await self.contacts.all()
                }
            }
        })
        listeners.append(Task { [weak self] in
            guard let self else { return }
            for await event in self.coordinator.events {
                switch event {
                case .started(let id):
                    self.syncingAccounts.insert(id)
                    self.statusText = "Checking \(self.accountName(id)) for new mail"
                case .progress(let id, let text):
                    self.syncingAccounts.insert(id)
                    self.statusText = text
                case .finished(let id):
                    self.syncingAccounts.remove(id)
                    self.soundGate.syncSucceeded(id)
                    self.statusText = "Up to date"
                    await self.refreshBandwidth()
                case .checked(let id, let found):
                    self.play(self.soundGate.checkFinished(id, foundNewMail: found, at: Date()))
                case .error(let id, let message):
                    self.syncingAccounts.remove(id)
                    self.play(self.soundGate.syncFailed(id, uptime: ProcessInfo.processInfo.systemUptime))
                    if message == FalconError.notAuthenticated.localizedDescription {
                        self.accountsNeedingSignIn.insert(id)
                        self.statusText = "\(self.accountName(id)) needs to sign in again"
                    } else {
                        self.statusText = "\(self.accountName(id)): \(message)"
                    }
                case .problem(let id, let message): self.statusText = "\(self.accountName(id)): \(message)"
                case .actionFailed(_, let message): self.showActionError(message)
                case .online(let id, let on): self.online[id] = on
                case .newMessages(let id, let folderID, let list):
                    self.announce(list, accountID: id, folderID: folderID)
                case .folderSynced: break
                }
            }
        })
        listeners.append(Task { [weak self] in
            guard let self else { return }
            for await items in await self.outbox.updates() {
                let sent = Set(items.filter { $0.status == .sent }.map { $0.id })
                let newlySent = sent.subtracting(self.knownSentIDs)
                if !self.knownSentIDs.isEmpty || !self.outboxItems.isEmpty, !newlySent.isEmpty {
                    self.play(self.soundGate.messageSent())
                }
                for id in newlySent { self.discardSidecar(id) }
                self.knownSentIDs = sent
                self.outboxItems = items
            }
        })
    }

    func accountName(_ id: UUID) -> String { accounts.first { $0.id == id }?.email ?? "account" }

    private func announce(_ list: [MessageSummary], accountID: UUID, folderID: UUID) {
        guard !migrationInProgress, let account = accounts.first(where: { $0.id == accountID }), let folder = folder(folderID) else { return }
        let recent = list.filter { $0.date > Date().addingTimeInterval(-48 * 3600) }
        guard !recent.isEmpty, notifications.announce(recent, account: account, folder: folder, policy: notificationPolicy) else { return }
        play(soundGate.newMailArrived())
    }

    private func play(_ sound: MailSoundEvent?) {
        if let sound { SoundLibrary.play(sound) }
    }

    func setNotifyMode(_ mode: NotifyMode, for accountID: UUID) {
        notificationPolicy.setMode(mode, for: accountID)
        notificationPolicy.save(layout: layout)
    }

    func addVIP(_ entry: String) {
        notificationPolicy.addVIP(entry)
        notificationPolicy.save(layout: layout)
    }

    func removeVIP(_ entry: String) {
        notificationPolicy.removeVIP(entry)
        notificationPolicy.save(layout: layout)
    }

    func handleNotificationAction(_ action: MailNotificationAction, messageID: String) {
        switch action {
        case .reveal: reveal(messageID: messageID)
        case .archive, .delete, .markRead, .flag: applyFromNotification(action, messageID: messageID)
        }
    }

    private func applyFromNotification(_ action: MailNotificationAction, messageID: String) {
        guard !messageID.isEmpty else { return }
        Task {
            guard let message = try? await store.message(id: messageID) else {
                showActionError("That message is no longer here")
                return
            }
            switch action {
            case .archive: archive([message])
            case .delete: delete([message])
            case .markRead: markRead([message], true)
            case .flag: setFlagged([message], true)
            case .reveal: break
            }
        }
    }

    func reveal(messageID: String) {
        showMainWindow()
        guard !messageID.isEmpty else { return }
        Task {
            guard let message = try? await store.message(id: messageID) else {
                statusText = "That message is no longer here"
                return
            }
            cancelPendingRead()
            resetSearch()
            if !pinFilters { filtersStorage = [] }
            if !alreadyShowing(message.folderID) { selection = .folder(message.folderID) }
            await reloadMessages()
            selectRevealedThread(containing: message)
            saveSession()
        }
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        guard !WindowTray.shared.orderMailboxWindowFront() else { return }
        openMainWindow?()
    }

    private func alreadyShowing(_ folderID: UUID) -> Bool {
        switch selection {
        case .unified: return folder(folderID)?.role == .inbox
        case .folder(let id): return id == folderID
        default: return false
        }
    }

    private func selectRevealedThread(containing message: MessageSummary) {
        if let thread = residentThread(containing: message) {
            selectedMessageIDs = [thread.id]
            return
        }
        guard !filtersStorage.isEmpty else { return }
        filtersStorage = []
        rebuildThreads()
        guard let thread = residentThread(containing: message) else { return }
        selectedMessageIDs = [thread.id]
    }

    func refreshAccounts() async {
        accounts = await store.allAccounts()
        signatures.adopt(accounts)
        var map: [UUID: [FolderInfo]] = [:]
        for a in accounts { map[a.id] = await store.folders(for: a.id) }
        folders = map
        refreshDockBadge()
    }

    /// Maintained whenever folders change, so reading it from a view body costs nothing.
    var unifiedUnreadCount: Int { unifiedUnread }

    private func refreshDockBadge() {
        guard dockBadgeStorage else {
            NSApp.dockTile.badgeLabel = nil
            return
        }
        let count = unifiedUnreadCount
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    private func scheduleReload(for folderID: UUID) {
        let relevant: Bool
        switch selection {
        case .unified: relevant = folders.values.flatMap { $0 }.contains { $0.id == folderID && $0.role == .inbox }
        case .folder(let id): relevant = id == folderID
        default: relevant = false
        }
        guard relevant, reloadTask == nil else { return }
        reloadTask = Task { [weak self] in
            // A busy sync can deliver dozens of batches a second. Coalescing them into one
            // reload keeps the list from being rebuilt faster than anyone can read it.
            try? await Task.sleep(nanoseconds: 600_000_000)
            await self?.reloadMessages()
            self?.reloadTask = nil
        }
    }

    func reloadMessages() async {
        do {
            if let query = submittedSearchQuery {
                await runFullSearch(query)
                return
            }
            let window = listWindow
            switch selection {
            case .unified:
                messages = try await store.unifiedInbox(limit: window)
                storedInSelection = try await store.unifiedCount()
            case .smart(let kind):
                let scope = kind.scope
                messages = try await store.unifiedInbox(limit: window, scope: scope)
                storedInSelection = try await store.unifiedCount(scope: scope)
            case .folder(let id):
                messages = try await store.messages(in: id, limit: window)
                storedInSelection = try await store.storedCount(in: id)
            default:
                messages = []
                storedInSelection = 0
            }
            rebuildThreads()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func matchesNeedle(_ message: MessageSummary) -> Bool {
        if message.subject.localizedCaseInsensitiveContains(liveSearchNeedle) { return true }
        if message.from.name.localizedCaseInsensitiveContains(liveSearchNeedle) { return true }
        if message.from.address.localizedCaseInsensitiveContains(liveSearchNeedle) { return true }
        return message.snippet.localizedCaseInsensitiveContains(liveSearchNeedle)
    }

    private var visibleMessages: [MessageSummary] {
        var list = messages
        if !Preferences.bool(Pref.showSentInConversations, default: true) {
            list = list.filter { !myAddressCache.contains($0.from.address.lowercased()) }
        }
        if Preferences.bool(Pref.focusedInbox, default: false), showsMessageList {
            list = list.filter { isFocused($0) == (focusedTab == .focused) }
        }
        guard !liveSearchNeedle.isEmpty else { return list }
        return list.filter { matchesNeedle($0) }
    }

    /// Mail from someone in the address book, or addressed to the reader by name, counts as Focused.
    /// Anything that looks like a mailing list or a no-reply sender falls to Other.
    func isFocused(_ message: MessageSummary) -> Bool {
        let address = message.from.address.lowercased()
        if knownContactAddresses.contains(address) { return true }
        let local = address.split(separator: "@").first.map(String.init) ?? ""
        let bulk = ["noreply", "no-reply", "donotreply", "do-not-reply", "notifications", "notification",
                    "newsletter", "news", "info", "support", "marketing", "mailer", "bounce", "updates", "alerts"]
        if bulk.contains(where: { local.contains($0) }) { return false }
        return message.to.contains { myAddressCache.contains($0.address.lowercased()) }
    }

    private var knownContactAddresses: Set<String> { contactAddressCache }

    private func passesFilters(_ thread: MessageThread) -> Bool {
        filtersStorage.allSatisfy { filter in thread.messages.contains { filter.matches($0) } }
    }

    private func rebuildThreads() {
        let visible = visibleMessages
        let grouped: [MessageThread]
        if groupByThread {
            grouped = ConversationThreader.group(visible).map { MessageThread(messages: $0) }
        } else {
            grouped = visible.map { MessageThread(messages: [$0]) }
        }
        let filtered = filtersStorage.isEmpty ? grouped : grouped.filter { passesFilters($0) || selectedMessageIDs.contains($0.id) }
        let sort = ListSort(rawValue: listSortStorage) ?? .date
        threads = sort.apply(filtered, ascending: sortAscendingStorage,
                             names: { [weak self] in self?.accountName($0) ?? "Account" },
                             folders: { [weak self] in self?.folder($0)?.name ?? "Folder" })
        rebuildRows()
        let valid = selectedMessageIDs.filter { rowIndex[$0] != nil }
        if valid != selectedMessageIDs { selectedMessageIDs = valid }
    }

    func runSearch() async {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        liveSearchNeedle = ""
        let q = searchText.trimmed
        guard !q.isEmpty else {
            submittedSearchQuery = nil
            await reloadMessages()
            return
        }
        submittedSearchQuery = q
        await runFullSearch(q)
    }

    private func runFullSearch(_ query: String) async {
        isSearching = true
        defer { isSearching = false }
        var found = (try? await store.search(query, accountID: nil)) ?? []
        var seen = Set(found.map { $0.id })
        for id in await indexer.search(query) where !seen.contains(id) {
            if let m = try? await store.message(id: id) { found.append(m); seen.insert(id) }
        }
        messages = found.sorted { $0.date > $1.date }
        rebuildThreads()
    }

    private func searchTextDidChange() {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        let needle = searchTextStorage.trimmed
        guard !needle.isEmpty else {
            applyIncrementalSearch("")
            return
        }
        searchDebounceTask = Task { [weak self] in
            _ = try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            self.searchDebounceTask = nil
            self.applyIncrementalSearch(needle)
        }
    }

    private func applyIncrementalSearch(_ needle: String) {
        let leavingFullResults = submittedSearchQuery != nil
        guard needle != liveSearchNeedle || leavingFullResults else { return }
        liveSearchNeedle = needle
        submittedSearchQuery = nil
        if leavingFullResults {
            Task { await reloadMessages() }
        } else {
            rebuildThreads()
        }
    }

    private func resetSearch() {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        liveSearchNeedle = ""
        submittedSearchQuery = nil
        searchTextStorage = ""
    }

    func toggleFilter(_ filter: MessageFilter) {
        var updated = filtersStorage
        if updated.contains(filter) { updated.remove(filter) } else { updated.insert(filter) }
        filters = updated
    }

    func clearFilters() {
        filters = []
    }

    func select(_ s: SidebarSelection?) {
        cancelPendingRead()
        selection = s
        listWindow = AppModel.listPageSize
        selectedMessageIDs = []
        expandedThreadIDs = []
        switch s {
        case .unified, .smart, .folder, .archive, .outbox: lastMailSelection = s
        default: break
        }
        resetSearch()
        if !pinFilters { filtersStorage = [] }
        Task { await reloadMessages() }
        saveSession()
    }

    var selectedThreads: [MessageThread] { threads.filter { selectedMessageIDs.contains($0.id) } }
    var selectedMessages: [MessageSummary] {
        guard !selectedMessageIDs.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [MessageSummary] = []
        for id in selectedMessageIDs {
            switch rowIndex[id] {
            case .thread(let thread):
                for m in thread.messages where seen.insert(m.id).inserted { out.append(m) }
            case .message(let m, _):
                if seen.insert(m.id).inserted { out.append(m) }
            default: continue
            }
        }
        return out
    }
    var firstSelectedMessage: MessageSummary? { selectedMessages.first }

    private var junkFolderIDs: Set<UUID> { junkFolderIDCache }

    var selectionIsAllInJunk: Bool {
        let list = selectedMessages
        return !list.isEmpty && list.allSatisfy { folder($0.folderID)?.role == .junk }
    }
    var currentThread: MessageThread? {
        guard selectedMessageIDs.count == 1, let id = selectedMessageIDs.first else { return nil }
        switch rowIndex[id] {
        case .thread(let thread): return thread
        case .message(let message, _): return MessageThread(messages: [message])
        default: break
        }
        if let thread = threads.first(where: { $0.id == id }) { return thread }
        guard let messageID = ListRow.childMessageID(id) else { return nil }
        for thread in threads {
            if let message = thread.messages.first(where: { $0.id == messageID }) { return MessageThread(messages: [message]) }
        }
        return nil
    }

    func account(for message: MessageSummary) -> AccountInfo? { accounts.first { $0.id == message.accountID } }
    func folder(_ id: UUID) -> FolderInfo? { folderByID[id] }

    private func rebuildFolderIndex() {
        var byID: [UUID: FolderInfo] = [:]
        var junk = Set<UUID>()
        var unread = 0
        for (accountID, list) in folders {
            let enabled = accounts.first { $0.id == accountID }?.isEnabled ?? true
            for f in list {
                byID[f.id] = f
                if f.role == .junk { junk.insert(f.id) }
                if f.role == .inbox, enabled { unread += f.unreadCount }
            }
        }
        folderByID = byID
        junkFolderIDCache = junk
        unifiedUnread = unread
    }

    var showsMessageList: Bool {
        switch selection {
        case .unified, .smart, .folder: return true
        default: return false
        }
    }

    var keyboardAccountID: UUID? {
        if let id = selectedMessages.first?.accountID { return id }
        if case .folder(let id) = selection, let f = folder(id) { return f.accountID }
        return accounts.first?.id
    }

    func toggleReadOnSelection() {
        let list = selectedMessages
        guard let first = list.first else { return }
        markRead(list, !first.isRead)
    }

    func toggleFlagOnSelection() {
        let list = selectedMessages
        guard let first = list.first else { return }
        setFlagged(list, !first.isFlagged)
    }

    func composeNew() {
        guard let account = accounts.first else { return }
        openCompose(.blank(account: account, signature: signature(for: account, .newMessages)))
    }

    func replyToSelection(all: Bool) {
        guard let thread = currentThread, let account = account(for: thread.latest) else { return }
        Task {
            let parsed = await parsedBody(for: thread.latest)
            openCompose(.reply(to: thread.latest, parsed: parsed, account: account, all: all,
                               signature: signature(for: account, .replies)))
        }
    }

    func forwardSelection() {
        guard let thread = currentThread, let account = account(for: thread.latest) else { return }
        Task {
            let parsed = await parsedBody(for: thread.latest)
            openCompose(.forward(thread.latest, parsed: parsed, account: account, signature: signature(for: account, .replies)))
        }
    }

    /// The signature a message from the account starts with, as the Signatures pane sets it.
    func signature(for account: AccountInfo, _ use: SignatureUse) -> Signature? {
        signatures.signature(for: account.id, use)
    }

    func focusSearch() {
        focusSearchToken += 1
    }

    func clearSearch() {
        guard !searchText.isEmpty else { return }
        searchText = ""
    }

    func jumpToAllInboxes() {
        select(.unified)
    }

    func jump(to role: FolderRole) {
        guard let accountID = keyboardAccountID else { return }
        guard let target = (folders[accountID] ?? []).first(where: { $0.role == role && $0.isSelectable }) else {
            statusText = "No \(role.rawValue) mailbox on \(accountName(accountID))"
            return
        }
        select(.folder(target.id))
    }

    func folder(for target: MoveTarget) -> FolderInfo? {
        (folders[target.accountID] ?? []).first { $0.path == target.folderPath && $0.isSelectable }
    }

    var lastMoveTarget: FolderInfo? {
        guard let target = moveTargets.last else { return nil }
        return folder(for: target)
    }

    func isRecentTarget(_ folder: FolderInfo) -> Bool {
        moveTargets.entry(for: folder) != nil
    }

    func openMovePalette() {
        guard !selectedMessageIDs.isEmpty else { return }
        guard WindowTray.shared.orderMailboxWindowFront() else { return }
        showsMovePalette = true
    }

    func closeMovePalette() {
        showsMovePalette = false
    }

    func moveToLastTarget() {
        let list = selectedMessages
        guard !list.isEmpty else { return }
        guard let target = lastMoveTarget, list.contains(where: { $0.accountID == target.accountID }) else {
            openMovePalette()
            return
        }
        move(list, to: target)
    }

    private var moveScope: [FolderInfo] {
        let accountIDs = Set(selectedMessages.map(\.accountID))
        return accounts.flatMap { folders[$0.id] ?? [] }.filter { $0.isSelectable && accountIDs.contains($0.accountID) }
    }

    func paletteTargets(matching query: String) -> [FolderInfo] {
        let scope = moveScope
        let needle = query.trimmed.lowercased()
        guard !needle.isEmpty else { return Array(recentFirst(scope).prefix(12)) }
        let scored = scope.compactMap { folder -> (folder: FolderInfo, tier: Int)? in
            guard let tier = FolderMatch.tier(for: folder, accountEmail: accountName(folder.accountID), needle: needle) else { return nil }
            return (folder, tier)
        }
        let ranked = scored.sorted { a, b in
            guard a.tier == b.tier else { return a.tier < b.tier }
            return usedMoreRecently(a.folder, than: b.folder)
        }
        return ranked.prefix(12).map { $0.folder }
    }

    private func recentFirst(_ scope: [FolderInfo]) -> [FolderInfo] {
        let byID = Dictionary(scope.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ordered: [FolderInfo] = []
        var seen = Set<UUID>()
        for target in moveTargets.recent() {
            guard let match = folder(for: target), let scoped = byID[match.id], !seen.contains(scoped.id) else { continue }
            ordered.append(scoped)
            seen.insert(scoped.id)
        }
        return ordered + scope.filter { !seen.contains($0.id) }
    }

    private func usedMoreRecently(_ a: FolderInfo, than b: FolderInfo) -> Bool {
        let left = moveTargets.entry(for: a)
        let right = moveTargets.entry(for: b)
        let leftCount = left?.useCount ?? 0
        let rightCount = right?.useCount ?? 0
        guard leftCount == rightCount else { return leftCount > rightCount }
        let leftUsed = left?.lastUsed ?? .distantPast
        let rightUsed = right?.lastUsed ?? .distantPast
        guard leftUsed == rightUsed else { return leftUsed > rightUsed }
        return a.path.localizedCaseInsensitiveCompare(b.path) == .orderedAscending
    }

    func commitPalette(_ folder: FolderInfo) {
        showsMovePalette = false
        move(selectedMessages, to: folder)
    }

    func forwardAsAttachment(_ messages: [MessageSummary]) {
        guard let first = messages.first, let account = account(for: first) else { return }
        Task {
            var parts: [OutgoingAttachment] = []
            for m in messages {
                guard let raw = await rawBody(for: m) else { continue }
                var name = m.subject.trimmed.isEmpty ? "Forwarded message" : m.subject.trimmed
                name = name.replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression)
                if name.count > 60 { name = String(name.prefix(60)) }
                parts.append(OutgoingAttachment(filename: name + ".eml", mimeType: "message/rfc822", data: raw))
            }
            guard !parts.isEmpty else {
                errorMessage = "Could not read the original message to attach it."
                return
            }
            let signature = signature(for: account, .replies)
            if parts.count == 1, let raw = await rawBody(for: first) {
                openCompose(.forwardAsAttachment(first, raw: raw, account: account, signature: signature))
                return
            }
            var draft = ComposeDraft(accountID: account.id)
            draft.subject = "Fwd: \(parts.count) messages"
            draft.open(lead: "\n\n", signature: signature)
            draft.attachments = parts
            openCompose(draft)
        }
    }

    func parsedBody(for message: MessageSummary) async -> MIMEMessage? {
        if let cached = bodyCache[message.id] { return cached }
        guard let syncer = await coordinator.syncer(for: message.accountID) else { return nil }
        do {
            let parsed = try await syncer.parsedMessage(for: message)
            bodyCache[message.id] = parsed
            if bodyCache.count > 200 { bodyCache.removeAll() }
            return parsed
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func rawBody(for message: MessageSummary) async -> Data? {
        guard let syncer = await coordinator.syncer(for: message.accountID) else { return nil }
        return try? await syncer.body(for: message)
    }

    private func perform(_ messages: [MessageSummary], announcing: Bool = true,
                         _ op: @escaping (AccountSyncer, [MessageSummary]) async throws -> [MailActionRecord]) {
        guard !messages.isEmpty else { return }
        Task {
            var records: [MailActionRecord] = []
            var failure: String?
            for (accountID, group) in Dictionary(grouping: messages, by: { $0.accountID }) {
                guard let syncer = await coordinator.syncer(for: accountID) else { continue }
                do {
                    records.append(contentsOf: try await op(syncer, group))
                } catch {
                    failure = error.localizedDescription
                }
            }
            guard announcing else { return }
            if let failure {
                showActionError(failure)
                await reloadMessages()
            }
            offerUndo(records)
        }
    }

    private func showActionError(_ message: String) {
        actionErrorTask?.cancel()
        actionErrorTask = nil
        actionError = message
        guard WindowTray.shared.mailboxWindowIsShowing else {
            actionErrorNeedsDismissal = true
            return
        }
        actionErrorNeedsDismissal = false
        actionErrorTask = Task { [weak self] in
            _ = try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.actionError = nil
            self.actionErrorTask = nil
        }
    }

    func dismissActionError() {
        actionErrorTask?.cancel()
        actionErrorTask = nil
        actionError = nil
        actionErrorNeedsDismissal = false
    }

    private func offerUndo(_ records: [MailActionRecord]) {
        guard let first = records.first else { return }
        undoExpiryTask?.cancel()
        undoExpiryTask = nil
        guard undoActionSeconds > 0 else { pendingUndo = nil; return }
        let undo = PendingUndo(records: records, summary: MailActionRecord.summary(for: records), verbTitle: first.verbTitle)
        pendingUndo = undo
        let nanoseconds = UInt64(undoActionSeconds) * 1_000_000_000
        undoExpiryTask = Task { [weak self] in
            _ = try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self, self.pendingUndo?.id == undo.id else { return }
            self.pendingUndo = nil
            self.undoExpiryTask = nil
        }
    }

    var canUndoAction: Bool { pendingUndo != nil }

    func undoLastAction() {
        guard let undo = pendingUndo else { return }
        undoExpiryTask?.cancel()
        undoExpiryTask = nil
        pendingUndo = nil
        Task {
            var restored = 0
            for record in undo.records {
                guard let syncer = await coordinator.syncer(for: record.accountID) else { continue }
                if await syncer.undo(record.id) { restored += record.messages.count }
            }
            statusText = restored > 0 ? "Restored \(restored) \(MailActionRecord.noun(restored))" : "Too late to undo"
        }
    }

    private func flushPendingActions() async {
        undoExpiryTask?.cancel()
        undoExpiryTask = nil
        pendingUndo = nil
        await coordinator.flushPendingActions()
    }

    func markRead(_ list: [MessageSummary], _ read: Bool) {
        perform(list.filter { $0.isRead != read }) { try await $0.setFlag(.seen, on: $1, enabled: read) }
    }

    private var markAllReadFolders: [FolderInfo] {
        switch selection {
        case .unified: return accounts.flatMap { folders[$0.id] ?? [] }.filter { $0.role == .inbox }
        case .folder(let id): return folder(id).map { [$0] } ?? []
        default: return []
        }
    }

    var canMarkAllRead: Bool {
        markAllReadFolders.contains { $0.unreadCount > 0 }
    }

    func markAllReadInSelection() {
        let list = markAllReadFolders
        guard let first = list.first else { return }
        markAllRead(in: list, named: list.count == 1 ? first.name : "All Inboxes")
    }

    func markAllRead(in folder: FolderInfo) {
        markAllRead(in: [folder], named: folder.name)
    }

    private func markAllRead(in list: [FolderInfo], named name: String) {
        Task {
            var unread: [MessageSummary] = []
            for f in list {
                let all = (try? await store.messages(in: f.id)) ?? []
                unread.append(contentsOf: all.filter { !$0.isRead })
            }
            guard !unread.isEmpty else {
                statusText = "No unread messages in \(name)"
                return
            }
            markRead(unread, true)
            statusText = "Marked \(unread.count) \(MailActionRecord.noun(unread.count)) as read in \(name)"
        }
    }

    private func markReadSilently(_ list: [MessageSummary]) {
        perform(list.filter { !$0.isRead }, announcing: false) { try await $0.setFlag(.seen, on: $1, enabled: true, silent: true) }
    }

    private func cancelPendingRead() {
        readTask?.cancel()
        readTask = nil
        pendingReadID = nil
    }

    private func residentThread(containing message: MessageSummary) -> MessageThread? {
        threads.first { $0.messages.contains { $0.id == message.id } }
    }

    func selectionDidChange() {
        cancelPendingRead()
        if Preferences.bool(Pref.autoExpandConversation, default: true),
           selectedMessageIDs.count == 1, let id = selectedMessageIDs.first,
           let thread = threads.first(where: { $0.id == id }), thread.messages.count > 1 {
            expandedThreadIDs.insert(id)
        }
        guard readPolicy == .delay else { return }
        guard selectedMessageIDs.count == 1, let id = selectedMessageIDs.first else { return }
        guard let selected = threads.first(where: { $0.id == id }), selected.unreadCount > 0 else { return }
        pendingReadID = id
        let nanoseconds = UInt64(max(1, markReadDelaySeconds)) * 1_000_000_000
        readTask = Task { [weak self] in
            _ = try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            guard self.pendingReadID == id, self.selectedMessageIDs == [id] else { return }
            guard let current = self.threads.first(where: { $0.id == id }) else { return }
            self.readTask = nil
            self.pendingReadID = nil
            self.markReadSilently(current.messages)
        }
    }

    func setFlagged(_ list: [MessageSummary], _ flagged: Bool) {
        perform(list) { try await $0.setFlag(.flagged, on: $1, enabled: flagged) }
    }

    private func rowVanishes(_ row: ListRow, removing ids: Set<String>) -> Bool {
        switch row {
        case .group: return false
        case .thread(let thread): return thread.messages.allSatisfy { ids.contains($0.id) }
        case .message(let message, _): return ids.contains(message.id)
        }
    }

    private func advanceTarget(removing ids: Set<String>, in current: [ListRow]) -> String? {
        guard advancePolicy != .list else { return nil }
        let vanishing = current.indices.filter { rowVanishes(current[$0], removing: ids) }
        guard let first = vanishing.min(), let last = vanishing.max() else { return nil }
        let forward = current[current.index(after: last)...].first { !rowVanishes($0, removing: ids) }?.id
        let backward = current[..<first].last { !rowVanishes($0, removing: ids) }?.id
        return advancePolicy == .next ? (forward ?? backward) : (backward ?? forward)
    }

    private func removeFromList(_ list: [MessageSummary]) {
        let ids = Set(list.map(\.id))
        let current = rowCache
        let touchesSelection = !selectedMessageIDs.isEmpty
            && selectedMessageIDs.contains { id in rowIndex[id].map { rowVanishes($0, removing: ids) } ?? false }
        let target = touchesSelection ? advanceTarget(removing: ids, in: current) : nil
        messages.removeAll { ids.contains($0.id) }
        rebuildThreads()
        guard touchesSelection else { return }
        selectedMessageIDs = target.map { [$0] } ?? []
    }

    func archive(_ list: [MessageSummary]) {
        removeFromList(list)
        perform(list) { try await $0.archive($1) }
    }

    func delete(_ list: [MessageSummary]) {
        removeFromList(list)
        perform(list) { try await $0.delete($1) }
    }

    func move(_ list: [MessageSummary], to folder: FolderInfo) {
        applyMove(list, to: folder)
    }

    private func applyMove(_ list: [MessageSummary], to folder: FolderInfo) {
        let targets = list.filter { $0.accountID == folder.accountID && $0.folderID != folder.id }
        guard !targets.isEmpty else { return }
        moveTargets.record(folder: folder)
        removeFromList(targets)
        perform(targets) { try await $0.move($1, to: folder) }
    }

    func isInJunk(_ list: [MessageSummary]) -> Bool {
        !list.isEmpty && list.allSatisfy { folder($0.folderID)?.role == .junk }
    }

    func moveToJunk(_ list: [MessageSummary]) {
        route(list, to: .junk, missing: "No junk mailbox on")
    }

    func markNotJunk(_ list: [MessageSummary]) {
        route(list, to: .inbox, missing: "No inbox on")
    }

    func toggleJunk(_ list: [MessageSummary]) {
        if isInJunk(list) { markNotJunk(list) } else { moveToJunk(list) }
    }

    func toggleJunkOnSelection() {
        toggleJunk(selectedMessages)
    }

    private func route(_ list: [MessageSummary], to role: FolderRole, missing: String) {
        var found: [UUID: FolderInfo] = [:]
        var moving: [MessageSummary] = []
        for (accountID, group) in Dictionary(grouping: list, by: { $0.accountID }) {
            guard let destination = (folders[accountID] ?? []).first(where: { $0.role == role && $0.isSelectable }) else {
                statusText = "\(missing) \(accountName(accountID))"
                continue
            }
            found[accountID] = destination
            moving.append(contentsOf: group.filter { $0.folderID != destination.id })
        }
        let destinations = found
        guard !moving.isEmpty else { return }
        removeFromList(moving)
        perform(moving) { syncer, group in
            guard let first = group.first, let destination = destinations[first.accountID] else { return [] }
            return try await syncer.move(group, to: destination)
        }
    }

    func mutedRecord(for thread: MessageThread) -> MutedThread? {
        let latest = thread.latest
        return MuteStore.match(in: mutedThreads, accountID: latest.accountID, threadKey: latest.threadKey,
                               messageID: latest.messageID, references: latest.references,
                               inReplyTo: latest.inReplyTo)
    }

    func isMuted(_ thread: MessageThread) -> Bool { mutedRecord(for: thread) != nil }

    func mute(_ threads: [MessageThread]) {
        let records = threads.compactMap { muteRecord(for: $0) }
        guard !records.isEmpty else { return }
        Task {
            for record in records { await mutes.mute(record) }
            mutedThreads = await mutes.all()
        }
        let list = threads.flatMap { $0.messages }
        markReadSilently(list)
        archive(list)
        statusText = records.count == 1 ? "Muted: \(muteTitle(records[0]))" : "Muted \(records.count) conversations"
    }

    func unmute(_ muted: MutedThread) {
        Task {
            await mutes.unmute(accountID: muted.accountID, threadKey: muted.threadKey)
            mutedThreads = await mutes.all()
        }
    }

    func toggleMute(_ thread: MessageThread) {
        if let record = mutedRecord(for: thread) { unmute(record) } else { mute([thread]) }
    }

    func muteSelection() {
        mute(selectedThreads)
    }

    private func muteRecord(for thread: MessageThread) -> MutedThread? {
        let latest = thread.latest
        let key = latest.threadKey.isEmpty ? latest.messageID : latest.threadKey
        guard !key.isEmpty else { return nil }
        let ids = Set(thread.messages.map { $0.messageID }.filter { !$0.isEmpty })
        return MutedThread(accountID: latest.accountID, threadKey: key, messageIDs: ids,
                           normalizedSubject: ConversationThreader.normalizedSubject(latest.subject),
                           subject: latest.subject, mutedAt: Date())
    }

    private func muteTitle(_ record: MutedThread) -> String {
        record.subject.isEmpty ? "(no subject)" : record.subject
    }

    func setWorkOffline(_ offline: Bool) {
        workOffline = offline
        Preferences.set(offline, Pref.offlineMode)
        Task {
            if offline {
                await coordinator.stopAll()
                statusText = "Working offline"
            } else {
                await coordinator.startAll()
                statusText = "Ready"
            }
        }
    }

    func createFolder(named name: String, in account: AccountInfo) {
        Task {
            guard let syncer = await coordinator.syncer(for: account.id) else {
                errorMessage = "\(account.email) is not connected yet."
                return
            }
            do {
                try await syncer.createMailbox(named: name)
                await refreshAccounts()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func purgeEverything(in folder: FolderInfo) {
        let doomed = messages.filter { $0.folderID == folder.id }
        guard !doomed.isEmpty else { return }
        removeFromList(doomed)
        perform(doomed, announcing: false) { try await $0.purge($1) }
    }

    func syncNow() {
        Task { await coordinator.syncNow() }
    }

    /// Send & Receive and Check for New Mail: a sync the reader asked for, which says No new
    /// messages when it finds none. Accounts known to be offline are not waited for; they are
    /// retrying on their own and would answer long after the question.
    func checkForNewMail() {
        Task {
            let asked = await coordinator.runningAccountIDs.filter { online[$0] != false }
            soundGate.manualCheckStarted(accounts: asked, at: Date())
            await coordinator.checkForNewMail()
        }
    }

    var canShowMore: Bool { messages.count < storedInSelection }

    func loadOlder() {
        if canShowMore {
            listWindow += AppModel.listPageSize
            Task { await reloadMessages() }
            return
        }
        guard case .folder(let id) = selection, let folder = folder(id) else { return }
        Task {
            guard let syncer = await coordinator.syncer(for: folder.accountID) else { return }
            statusText = "Loading older messages in \(folder.name)"
            do { try await syncer.loadOlder(folder: folder) } catch { errorMessage = error.localizedDescription }
            statusText = "Up to date"
        }
    }

    func newDraft(_ draft: ComposeDraft) -> UUID {
        drafts[draft.id] = draft
        return draft.id
    }

    func openMessage(_ message: MessageSummary, forceWindow: Bool = false, openWindow: (String) -> Void) {
        if folder(message.folderID)?.role == .drafts { return editStoredDraft(message) }
        markReadOnOpen(message)
        if forceWindow || openInWindowOnDoubleClick { openWindow(message.id) } else { openMessageTab(message) }
    }

    private func editStoredDraft(_ message: MessageSummary) {
        Task {
            guard let parsed = await parsedBody(for: message) else {
                showActionError("Could not open that draft.")
                return
            }
            var draft = ComposeDraft.from(parsed: parsed, accountID: message.accountID)
            draft.sourceMessageID = message.id
            openCompose(draft)
        }
    }

    func saveDraftToServer(_ id: UUID) {
        guard let draft = drafts[id] else { return }
        drafts[id] = nil
        guard !draft.isBlank, let account = accounts.first(where: { $0.id == draft.accountID }) else { return }
        Task {
            guard let folder = folder(accountID: account.id, role: .drafts), let syncer = await coordinator.syncer(for: account.id) else {
                drafts[id] = draft
                return
            }
            do {
                let raw = MIMEBuilder.build(try draft.outgoing(from: account, requireRecipients: false))
                try await syncer.append(raw: raw, to: folder, flags: [.draft, .seen], date: Date())
                await purgeStoredDraft(draft.sourceMessageID)
                statusText = "Draft saved to \(folder.name)"
            } catch {
                drafts[id] = draft
                showActionError("Could not save the draft: \(error.localizedDescription)")
            }
        }
    }

    func purgeStoredDraft(_ messageID: String?) async {
        guard let messageID, let stored = try? await store.message(id: messageID) else { return }
        removeFromList([stored])
        perform([stored], announcing: false) { try await $0.purge($1) }
    }

    func saveLeftoverDrafts() {
        let openIDs = Set((tabs + minimizedTabs).compactMap { if case .compose(let id) = $0 { return id } else { return nil } })
        for id in drafts.keys where !openIDs.contains(id) { saveDraftToServer(id) }
    }

    private func markReadOnOpen(_ message: MessageSummary) {
        guard readPolicy != .never else { return }
        cancelPendingRead()
        markReadSilently(residentThread(containing: message)?.messages ?? [message])
    }

    func send(_ draft: ComposeDraft) throws {
        guard let account = accounts.first(where: { $0.id == draft.accountID }) else { throw FalconError.storage("account missing") }
        let message = try draft.outgoing(from: account)
        Task {
            do {
                await outbox.setUndoWindow(TimeInterval(undoSendSeconds))
                let item = try await outbox.enqueue(accountID: account.id, from: account.email, message: message, sendAt: draft.scheduledAt)
                await writeSidecar(draft, for: item.id)
                await purgeStoredDraft(draft.sourceMessageID)
                try? await contacts.recordUse(accountID: account.id, addresses: message.to + message.cc + message.bcc)
                contactList = await contacts.all()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        drafts[draft.id] = nil
        closeTab(.compose(draft.id))
    }

    var sendingSoonItems: [OutboxItem] {
        outboxItems.filter { $0.isSendingSoon(within: TimeInterval(undoSendSeconds)) }
    }

    func cancelAndReopen(_ item: OutboxItem, openWindow: @escaping (UUID) -> Void) {
        Task {
            let cancelled = (try? await outbox.cancel(item.id)) ?? false
            let title = outboxTitle(item)
            guard cancelled else {
                statusText = "Too late to stop “\(title)”"
                return
            }
            let draft = await queuedDraft(for: item)
            await outbox.remove(item.id)
            guard let draft else {
                statusText = "Cancelled “\(title)”, but the message could not be reopened"
                return
            }
            if openInWindowOnDoubleClick {
                _ = newDraft(draft)
                openWindow(draft.id)
            } else {
                openCompose(draft)
            }
            statusText = "Reopened “\(title)” as a draft"
        }
    }

    private func outboxTitle(_ item: OutboxItem) -> String {
        item.subject.isEmpty ? "(no subject)" : item.subject
    }

    private func sidecarURL(_ itemID: UUID) -> URL {
        Outbox.draftSidecarURL(directory: layout.outboxDirectory, id: itemID)
    }

    private func writeSidecar(_ draft: ComposeDraft, for itemID: UUID) async {
        let sidecar = ComposeDraftSidecar(draft)
        let url = sidecarURL(itemID)
        let write = Task.detached(priority: .utility) { () -> Void in
            try? AtomicFile.writeJSON(sidecar, to: url)
        }
        await write.value
    }

    private func discardSidecar(_ itemID: UUID) {
        let url = sidecarURL(itemID)
        Task.detached(priority: .utility) { () -> Void in
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func queuedDraft(for item: OutboxItem) async -> ComposeDraft? {
        let raw = await outbox.rawMessage(for: item.id)
        let url = sidecarURL(item.id)
        let accountID = item.accountID
        return await Task.detached(priority: .userInitiated) { () -> ComposeDraft? in
            let parsed = raw.map { MIMEParser.parse($0) }
            let attachments = parsed.map { ComposeDraft.outgoingAttachments(of: $0) } ?? []
            if let sidecar = AtomicFile.readJSON(ComposeDraftSidecar.self, from: url) {
                return sidecar.draft(attachments: attachments)
            }
            guard let parsed else { return nil }
            return ComposeDraft.from(parsed: parsed, accountID: accountID)
        }.value
    }

    func addGoogleAccount(loginHint: String? = nil) async throws {
        guard let config = OAuthConfigLoader.load() else {
            throw FalconError.invalidInput("This build has no Google sign-in configured. Use a build from GitHub Releases, or set the values under Settings → Advanced.")
        }
        let flow = GoogleSignInFlow(config: config, redirect: OAuthConfigLoader.redirect(for: config))
        let result = try await flow.run(openURL: { url in
            DispatchQueue.main.async { _ = NSWorkspace.shared.open(url) }
        }, loginHint: loginHint)
        var account = accounts.first { $0.email.caseInsensitiveCompare(result.email) == .orderedSame }
            ?? AccountInfo.google(email: result.email, displayName: result.name)
        account.authMethod = "oauth"
        accountsNeedingSignIn.remove(account.id)
        try await tokens.save(result.token, for: account.id)
        try await store.saveAccount(account)
        await refreshAccounts()
        await coordinator.start(account: account)
        Task { await syncContacts() }
        if let hint = loginHint, hint.caseInsensitiveCompare(result.email) != .orderedSame {
            statusText = "Signed in as \(result.email), not \(hint)"
        }
    }

    func addCustomAccount(email: String, displayName: String, settings: CustomServerSettings) async throws {
        var account = accounts.first { $0.email.caseInsensitiveCompare(email) == .orderedSame }
            ?? AccountInfo.custom(email: email, displayName: displayName, imapHost: settings.imapHost, imapPort: settings.imapPort,
                                  smtpHost: settings.smtpHost, smtpPort: settings.smtpPort, username: settings.username)
        account.provider = "imap"
        account.authMethod = "password"
        account.imapHost = settings.imapHost
        account.imapPort = settings.imapPort
        account.smtpHost = settings.smtpHost
        account.smtpPort = settings.smtpPort
        account.username = settings.username
        if !displayName.isEmpty { account.displayName = displayName }
        try await tokens.savePassword(settings.password, for: account.id)
        try await store.saveAccount(account)
        await refreshAccounts()
        await coordinator.start(account: account)
    }

    func removeAccount(_ account: AccountInfo) {
        Task {
            await coordinator.stop(accountID: account.id)
            await tokens.remove(accountID: account.id)
            await indexer.removeAccount(account.id)
            try? await store.removeAccount(account.id)
            await refreshAccounts()
            if case .folder = selection { select(.unified) }
        }
    }

    func setAccountSyncing(_ account: AccountInfo, _ on: Bool) {
        var updated = account
        updated.isEnabled = on
        if let i = accounts.firstIndex(where: { $0.id == account.id }) { accounts[i] = updated }
        Task {
            try? await store.saveAccount(updated)
            if on {
                await coordinator.start(account: updated)
            } else {
                await coordinator.stop(accountID: updated.id)
                online[updated.id] = false
            }
            await refreshAccounts()
        }
    }

    func saveAccount(_ account: AccountInfo) {
        Task {
            try? await store.saveAccount(account)
            await refreshAccounts()
        }
    }

    func syncContacts() async {
        for a in accounts where a.provider == "google" {
            let client = GooglePeopleClient(tokens: tokens, accountID: a.id)
            if let list = try? await client.fetchAll() {
                try? await contacts.replace(accountID: a.id, source: "google", with: list.filter { $0.source == "google" })
                try? await contacts.replace(accountID: a.id, source: "google-other", with: list.filter { $0.source == "google-other" })
            }
        }
        contactList = await contacts.all()
    }

    func refreshCacheSize() async {
        cacheSizeBytes = await store.cacheSizeBytes()
    }

    func clearCache() {
        Task {
            await store.clearBodyCache()
            await refreshCacheSize()
            statusText = "Offline copies removed"
        }
    }

    func runRulesNow() {
        Task {
            statusText = "Applying rules to inboxes"
            for a in accounts {
                guard let syncer = await coordinator.syncer(for: a.id) else { continue }
                do { try await syncer.runRulesOnInbox() } catch { errorMessage = error.localizedDescription }
            }
            statusText = "Rules applied"
        }
    }

    func reloadArchives() async {
        archiveRecords = await archives.all()
    }

    func importFiles(_ urls: [URL], into folder: FolderInfo) {
        Task {
            guard let syncer = await coordinator.syncer(for: folder.accountID) else { return }
            var count = 0
            for url in urls {
                do {
                    if url.pathExtension.lowercased() == "mbox" {
                        for m in MboxReader.messages(in: try Data(contentsOf: url)) {
                            try await syncer.append(raw: m.raw, to: folder, flags: m.flags, date: m.date)
                            count += 1
                        }
                    } else {
                        let m = try EMLImport.message(at: url)
                        try await syncer.append(raw: m.raw, to: folder, flags: m.flags, date: m.date)
                        count += 1
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            statusText = "Imported \(count) messages into \(folder.name)"
        }
    }

    func exportSelectedAsEML(to directory: URL) {
        let list = selectedMessages
        Task {
            var count = 0
            for m in list {
                guard let raw = await rawBody(for: m) else { continue }
                let safe = m.subject.replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression).prefix(60)
                let name = "\(m.uid)-\(safe.isEmpty ? "message" : String(safe)).eml"
                try? raw.write(to: directory.appendingPathComponent(name))
                count += 1
            }
            statusText = "Exported \(count) messages"
        }
    }

    func shutdown() async {
        cancelPendingRead()
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        await flushPendingActions()
        saveSessionNow()
        signatures.saveNow()
        for d in drafts.values { session.saveDraft(d) }
        await store.flushAll()
        await coordinator.stopAll()
    }
}

extension Outbox {
    func setUndoWindow(_ seconds: TimeInterval) {
        undoWindow = seconds
    }
}
