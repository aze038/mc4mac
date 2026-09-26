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
    /// Changes the Gmail engine holds for their undo window, which Undo drops unsent.
    var receipts: [ActionReceipt] = []
}

/// What a fetch of a message's text for a reader came to.
enum ReaderBody: Sendable {
    case parsed(MIMEMessage)
    /// Its account is not running, or the fetch was called off.
    case unavailable
    /// The sentence saying why, and the folder names it holds.
    case failed(String, [String])
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
    /// Messages being written, kept on this Mac until Drafts has them, and discarded ones whose
    /// copy in Drafts is still to go.
    @ObservationIgnored let unsentDrafts: UnsentDrafts<ComposeDraft, MessageSummary>
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
    /// The message table, which shows the list of every account on the Gmail API (see EngineList).
    let engineList = EngineList()
    var accountsNeedingSignIn = Set<UUID>()
    @ObservationIgnored var lastMailSelection: SidebarSelection?
    var isSearching = false
    /// One line under the list when some account's results come from this Mac instead of Gmail.
    var searchNotice: String?
    var searchHasMore = false
    var isLoadingMoreResults = false
    var statusText = "Ready"
    var online: [UUID: Bool] = [:]
    var accountStatus = AccountStatusBoard()
    var outboxItems: [OutboxItem] = []
    var archiveRecords: [ArchiveRecord] = []
    /// The alert on screen. Set it with `showAlert`, which tells diagnostics which folder names
    /// the sentence holds. When set directly, the sentence is taken to hold none.
    var errorMessage: String? {
        didSet {
            if errorMessage == nil {
                shownAlertNames = []
            } else if let errorMessage, errorMessage != oldValue {
                Log.error("Alert", errorMessage, names: alertNames)
                shownAlertNames = alertNames
            }
            alertNames = []
        }
    }
    /// The folder and file names in the next `errorMessage`, which diagnostics take out of it.
    @ObservationIgnored private var alertNames: [String] = []
    /// The names in the alert on screen, kept for a notice added to it.
    @ObservationIgnored private var shownAlertNames: [String] = []
    var actionError: String?
    var actionErrorNeedsDismissal = false
    var pendingUndo: PendingUndo?
    var contactList: [ContactInfo] = [] {
        didSet { contactAddressCache = Set(contactList.map { $0.email.lowercased() }) }
    }
    @ObservationIgnored private var contactAddressCache = Set<String>()
    @ObservationIgnored private var myAddressCache = Set<String>()
    var openMessageWindows = Set<String>()
    /// The message each message window shows, as it last read it, for the Message menu's
    /// commands while that window is in front.
    var messageWindowRows: [String: MessageSummary] = [:]
    /// Which window is in front, for the commands that act on it.
    var frontWindow = FrontWindow.mailbox
    var tabs: [WorkspaceTab] = []
    var minimizedTabs: [WorkspaceTab] = []
    var activeTab: WorkspaceTab?
    var tabTitles: [String: String] = [:]
    var cacheSizeBytes = 0
    var showsMovePalette = false
    /// The messages the palette was opened for, when not the selection.
    var movePaletteMessages: [MessageSummary]?
    /// The message window the palette is open over, nil for the mailbox window.
    var movePaletteWindow: String?
    /// Moves on whenever stored messages change, so a message open in a window or tab of its own
    /// reads its flags again and its ribbon shows what it is now.
    var openMessagesRevision = 0
    @ObservationIgnored var openMessagesRefresh: Task<Void, Never>?
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
        for account in accounts { out[account.id] = TrafficMeter.shared.used(.download, by: account.id) }
        downloadedToday = out
    }

    /// Accounts to offer a retry for: ones that cannot be reached. One Gmail asked to slow down
    /// or that waits for the owner already says so in the status line, and a retry would not help.
    var offlineAccounts: [AccountInfo] {
        guard accountsNeedingSignIn.isEmpty else { return [] }
        return accounts.filter { account in
            guard account.isEnabled, case .offline = accountStatus.health[account.id] else { return false }
            return true
        }
    }

    /// Why each account that is paused or blocked is not syncing, in the words the engine gave,
    /// kept on show until it syncs again. Offline accounts and ones to sign in again have a
    /// button of their own instead.
    var pausedAccountNotices: [(account: AccountInfo, text: String)] {
        accounts.compactMap { account in
            guard account.isEnabled, let text = accountStatus.problems[account.id] else { return nil }
            switch accountStatus.health[account.id] {
            case .imapPaused, .apiPaused, .blocked: return (account, text)
            default: return nil
            }
        }
    }

    /// False while an account cannot sync, when "All folders are up to date" would not be true.
    var everyAccountReachable: Bool {
        accountStatus.allReachable(accounts.filter(\.isEnabled).map(\.id))
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

    var filtersStorage: Set<MessageFilter> = []
    var filters: Set<MessageFilter> {
        get { filtersStorage }
        set {
            guard newValue != filtersStorage else { return }
            filtersStorage = newValue
            rebuildThreads()
        }
    }

    /// The message discarded last, which the status bar offers to bring back for a while.
    var discarded = DiscardedMessage<ComposeDraft>()
    @ObservationIgnored var discardExpiry: Task<Void, Never>?

    private var draftsStorage: [UUID: ComposeDraft] = [:]
    var drafts: [UUID: ComposeDraft] {
        get { draftsStorage }
        set {
            let old = draftsStorage
            draftsStorage = newValue
            for (id, d) in newValue where old[id] != d { scheduleDraftSave(id) }
            for id in old.keys where newValue[id] == nil { pendingDraftSaves[id]?.cancel(); pendingDraftSaves[id] = nil; unsentDrafts.forget(id) }
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
    private var openInWindowStorage = MessageOpening.opensInWindow(
        stored: UserDefaults.standard.object(forKey: MessageOpening.preferenceKey) as? Bool)
    /// Settings → Reading: whether a double-clicked message opens in a window of its own, as
    /// Outlook's does, or in a tab of the mailbox window.
    var openInWindowOnDoubleClick: Bool {
        get { openInWindowStorage }
        set { openInWindowStorage = newValue; Preferences.set(newValue, MessageOpening.preferenceKey) }
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
    /// The session the last quit saved, whose entries for accounts now on the Gmail API are
    /// written back untouched for an earlier FalconMail (§12.2).
    @ObservationIgnored var previousSession: SessionState?
    /// Whether the windows of the last session have been restored, after which drafts left over
    /// from it are saved.
    var sessionWindowsRestored: Bool { restoredState == nil }
    @ObservationIgnored private var knownSentIDs = Set<UUID>()
    @ObservationIgnored var soundGate = MailSoundGate(isEnabled: SoundLibrary.isEnabled)
    @ObservationIgnored private var bodyCache: [String: MIMEMessage] = [:]
    /// The texts readers are waiting for, each fetched once however many readers want it.
    @ObservationIgnored private let readerFetches = SharedFetches<String, ReaderBody>()
    @ObservationIgnored var listeners: [Task<Void, Never>] = []
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var sessionSaveTask: Task<Void, Never>?
    @ObservationIgnored private var pendingDraftSaves: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var pendingReadID: String?
    @ObservationIgnored private var actionErrorTask: Task<Void, Never>?
    @ObservationIgnored private var searchDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var liveSearchNeedle = ""
    @ObservationIgnored private var submittedSearchQuery: String?
    @ObservationIgnored private var serverSearchDebounce: Task<Void, Never>?
    @ObservationIgnored var serverSearch: ServerSearchRun?
    @ObservationIgnored var gmailClients: [UUID: GmailAPIClient] = [:]
    @ObservationIgnored var gmailOpeners: [UUID: GmailOpener] = [:]
    /// Rows found only on the server, by id, so a tab or window can show one after the search moves on.
    @ObservationIgnored var serverRows: [String: MessageSummary] = [:]
    /// Messages opened from Gmail, held in memory only and never written to disk.
    @ObservationIgnored var openedServerMessages: [String: GmailOpenedMessage] = [:]
    @ObservationIgnored var openedServerOrder: [String] = []
    /// The messages of the conversation each message window or tab was opened for, newest
    /// first, by the id of the newest, which the window or tab is known by. A window or tab
    /// opened for one message has none, and shows that message alone.
    @ObservationIgnored var conversationWindows: [String: [String]] = [:]
    @ObservationIgnored var serverAttachmentBytes: [String: Data] = [:]
    @ObservationIgnored private var undoExpiryTask: Task<Void, Never>?
    @ObservationIgnored var openMainWindow: (@MainActor () -> Void)?
    @ObservationIgnored var openComposeWindow: (@MainActor (UUID) -> Void)?
    /// Messages whose pictures from the web the owner loaded once in the reader, this session.
    @ObservationIgnored var remotePicturesLoaded: Set<String> = []
    /// Fetches the pictures from the web a quoted original or a signature shows; the snapshot
    /// gives it one that never reaches the network.
    @ObservationIgnored var remotePictureLoader = RemotePictureLoader.web
    /// Drafts just opened whose quoted original's pictures from the web are to be fetched and
    /// put in by their compose window.
    @ObservationIgnored var picturesToFetch: Set<UUID> = []
    @ObservationIgnored private var importingSignatures = false
    /// The drafts being written in compose windows of their own; with those in tabs, they are
    /// the drafts that are not left over.
    @ObservationIgnored var composeWindowDrafts: Set<UUID> = []

    // The Gmail engine (see AppModel+Engines).
    /// Google accounts switched to the Gmail API, whether or not their engine runs yet: nothing
    /// for them may go by IMAP or SMTP, or read their old IMAP store.
    var gmailEngineAccounts: Set<UUID> = []
    /// The running Gmail engines, by account, each with its list, actions, drafts and sender.
    var engineAssemblies: [UUID: GmailAccountAssembly] = [:]
    /// Why a Google account is not on the Gmail API yet although its switch is on, or why the
    /// switch could not be turned off, by account, for Settings → Accounts.
    var engineSwitchNotices: [UUID: String] = [:]
    /// The stored rows of accounts on IMAP, as the table reads them.
    @ObservationIgnored let storeList: StoreListSource
    /// All Inboxes over accounts on both engines, made again when the engines change.
    @ObservationIgnored var mergedList: (engines: Set<UUID>, source: MergedListSource)?
    /// The search the Gmail engines run, while its results are shown.
    var engineSearch: EngineSearchRun?
    /// Drafts saved on this Mac that Gmail has not got yet, by account, which Drafts shows as
    /// provisional rows and counts.
    var engineProvisionalDrafts: [UUID: [GmailProvisionalDraft]] = [:]
    /// The message a notification asked to show, for the list to select once it has its row.
    var pendingReveal: RowKey?
    /// What each running engine's folders and drafts are followed by.
    @ObservationIgnored var engineWatches: [UUID: EngineWatch] = [:]
    /// The last details known of Gmail rows shown in windows and tabs, kept while Gmail cannot be
    /// reached so a window stays open with what it had.
    @ObservationIgnored var engineSummaries: [String: MessageSummary] = [:]
    /// Accounts whose categories are being given Gmail's ids now.
    @ObservationIgnored var categoriesRekeying: Set<UUID> = []
    /// When each draft was last saved to Gmail by itself while being written.
    @ObservationIgnored var engineAutosavedAt: [UUID: Date] = [:]
    /// Sleep and screen-lock observers, which set how often the Gmail engines check.
    @ObservationIgnored var activityObservers: [NSObjectProtocol] = []
    /// Follows "Show All Gmail Labels", which each Google account's engine is told of.
    @ObservationIgnored var labelsShownObserver: NSObjectProtocol?

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
            self.unsentDrafts.keep(d)
            self.pendingDraftSaves[id] = nil
            self.autosaveEngineDraft(d)
        }
    }

    init() {
        Log.start(in: layout.root)
        AppModel.keepCachesOffDisk()
        let info = Bundle.main.infoDictionary
        Log.info("app", "launch version=\(info?["CFBundleShortVersionString"] as? String ?? "?") build=\(info?["CFBundleVersion"] as? String ?? "?") data=\(layout.root.path)")
        let store = MailStore(layout: layout)
        let tokens = TokenStore(clientConfigProvider: { OAuthConfigLoader.load() }, knownClientConfigs: { OAuthConfigLoader.all() })
        let rules = RuleStore(layout: layout)
        let mutes = MuteStore(layout: layout)
        self.store = store
        self.storeList = StoreListSource(store: store)
        self.tokens = tokens
        self.rules = rules
        self.mutes = mutes
        // Google accounts signed in with Google run on the Gmail API, and the read-only part of the
        // probe runs once for each when its engine first starts.
        let coordinator = SyncCoordinator(store: store, tokens: tokens, rules: rules, mutes: mutes, indexer: indexer,
                                          pendingActions: PendingActionStore(layout: layout), probe: SyncCoordinator.readOnlyProbe)
        self.coordinator = coordinator
        // Mail of a Google account on the Gmail API goes by Gmail's own send, never by SMTP.
        let smtp = SMTPSender(store: store, tokens: tokens, coordinator: coordinator)
        self.outbox = Outbox(layout: layout, sender: RoutingSender(smtp: smtp, route: { await coordinator.sendRoute(for: $0) }),
                             undoWindow: 10)
        self.contacts = ContactStore(layout: layout)
        self.archives = ArchiveRecordStore(layout: layout)
        self.session = SessionStore(layout: layout)
        self.unsentDrafts = UnsentDrafts(directory: session.draftsDirectory)
        self.moveTargets = MoveTargets(layout: layout)
        self.signatures = SignatureLibrary(store: SignatureStore(layout: layout))
    }

    /// HTTP responses are kept in memory only, and what earlier builds' web and HTTP caches
    /// left in ~/Library/Caches is removed, once.
    private static func keepCachesOffDisk() {
        URLCache.shared = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 0, directory: nil)
        let removed = "legacyCachesRemoved"
        guard !UserDefaults.standard.bool(forKey: removed),
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        LegacyCaches.remove(from: caches, runningAs: Bundle.main.bundleIdentifier)
        UserDefaults.standard.set(true, forKey: removed)
    }

    func bootstrap() async {
        SoundLibrary.carryOverEarlierChoices()
        play(soundGate.launched())
        do { try await store.load() } catch { showAlert(for: error) }
        // Google accounts on the Gmail API, paused or not, are held to it before anything can
        // send or show their IMAP store's rows.
        await coordinator.prime()
        applyRoster(await coordinator.roster)
        restoredState = session.load()
        previousSession = restoredState
        unsentDrafts.isOpen = { [weak self] id in self?.draftsStorage[id] != nil }
        unsentDrafts.deleteCopy = { [weak self] row in try await self?.deleteStoredCopy(row) }
        for d in unsentDrafts.leftovers() { drafts[d.id] = d }
        if let s = restoredState {
            selection = s.selection ?? .unified
            searchText = s.searchText
            // A restored search filters what is here; it does not ask Gmail until the reader does.
            serverSearchDebounce?.cancel()
            serverSearchDebounce = nil
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
        listenToEngines()
        followOwnerActivity()
        await followLabelsShown()
        watchForWake()
        await coordinator.startAll()
        // Copies in Drafts of messages discarded just before the last quit, which it could not delete.
        unsentDrafts.deleteDiscarded()
        await reloadMessages()
        if let s = restoredState {
            let ids = Set(s.selectedMessageIDs)
            selectedMessageIDs = ids.filter { rowIndex[$0] != nil }
            // The row selected in the table at the last quit is selected again once its account's
            // engine shows it.
            if selectedMessageIDs.isEmpty, let first = s.gmailSelectedMessageIDs?.first {
                pendingReveal = RowKey(string: ListRow.childMessageID(first) ?? first)
                engineList.revealPending()
            }
            await restoreTabs(s.openTabs + (s.gmailTabs ?? []), minimized: s.minimizedTabs + (s.gmailMinimizedTabs ?? []),
                              active: s.gmailActiveTab ?? s.activeTab)
        }
        Task { await syncContacts() }
        noteUnreadableFiles()
    }

    /// Says once which stored files could not be read. Each was kept, untouched, for the owner
    /// or a later build to recover, rather than being quietly replaced. Called at launch and
    /// again after each pass of the engine, which reads some files only when it first needs
    /// them: the actions waiting for the server, and the index of a folder not yet opened.
    private func noteUnreadableFiles() {
        guard let notice = StoredFileNotices.takeNotice() else { return }
        if let shown = errorMessage {
            showAlert(shown + "\n\n" + notice.text, names: shownAlertNames + notice.names)
        } else {
            showAlert(notice.text, names: notice.names)
        }
    }

    /// Shows the owner `text`. `names` are the folder and file names in it, which diagnostics
    /// take out of the alert it is told about.
    func showAlert(_ text: String, names: [String] = []) {
        alertNames = names
        errorMessage = text
    }

    /// Shows the owner what went wrong. The folder names in the error's sentence, such as HR in
    /// "The messages listed for HR of ana@example.com could not be read", are kept out of
    /// diagnostics.
    func showAlert(for error: any Error) {
        showAlert(error.localizedDescription, names: Log.names(heldBy: error))
    }

    /// The message windows the last session left open, read once at launch: those to open again
    /// and those to put back into the tray. Drafts that no window holds go to Drafts now.
    var messageWindowsToRestore: (open: [String], tray: [String]) {
        let state = restoredState
        restoredState = nil
        saveLeftoverDrafts()
        // Windows of accounts now on the Gmail API that an earlier build left are its own, and
        // are carried forward rather than opened; the Gmail engine's windows open by their key.
        let engines = gmailEngineAccounts
        let earlier = (state?.openMessageWindows ?? []).filter { SessionCarryForward.carried([$0], engineAccounts: engines).isEmpty }
        let gmail = state?.gmailWindows ?? []
        var restored = WindowTrayBook.restoring(messageWindows: earlier, inTray: state?.trayMessageWindows)
        restored.open += gmail.filter { !$0.inTray }.map(\.rowKey)
        restored.tray += gmail.filter(\.inTray).map(\.rowKey)
        return restored
    }

    /// Puts the messages that were in the tray at the last quit back into it, each under its
    /// subject, without opening their windows until they are taken out. One no longer stored is
    /// left out.
    func shelveMessageWindows(_ ids: [String]) async {
        for id in ids {
            guard let message = await message(id: id) else { continue }
            WindowTray.shared.shelve(.message(id), title: message.subject.isEmpty ? "(no subject)" : message.subject)
        }
    }

    func currentSessionState() -> SessionState {
        // Rows found only on the server exist for this session alone, so none is saved for the next.
        func stored(_ id: String) -> Bool { GmailServerRow.reference(from: ListRow.childMessageID(id) ?? id) == nil }
        func storedTab(_ tab: WorkspaceTab) -> Bool {
            if case .message(let id) = tab { return stored(id) }
            return true
        }
        let windows = WindowTray.shared.book.messageWindows
        // Rows of Google accounts on the Gmail API go into fields of their own; what the last
        // session had there for such an account, which this build does not show, is carried
        // forward untouched for an earlier FalconMail.
        let engines = gmailEngineAccounts
        let previous = previousSession
        func earlier(_ ids: [String], _ old: [String]?) -> [String] {
            SessionCarryForward.earlierList(ids.filter(stored), previous: old ?? [], engineAccounts: engines)
        }
        func isGmail(_ tab: WorkspaceTab) -> Bool {
            if case .message(let id) = tab { return RowKey(string: id)?.isGmail == true }
            return false
        }
        func carriedTabs(_ old: [WorkspaceTab]?) -> [WorkspaceTab] {
            (old ?? []).filter { tab in
                if case .message(let id) = tab { return !SessionCarryForward.carried([id], engineAccounts: engines).isEmpty }
                return false
            }
        }
        let gmailWindows = SessionCarryForward.split(windows.all).gmail.map { key in
            GmailWindowEntry(rowKey: key, contextLabel: nil, inTray: windows.inTray.contains(key),
                             title: messageWindowRows[key]?.subject ?? tabTitles[WorkspaceTab.message(key).id])
        }
        let openTabs = tabs.filter { storedTab($0) && !isGmail($0) } + carriedTabs(previous?.openTabs)
        let minimized = minimizedTabs.filter { storedTab($0) && !isGmail($0) } + carriedTabs(previous?.minimizedTabs)
        var state = SessionState(selection: selection, selectedMessageIDs: earlier(Array(selectedMessageIDs), previous?.selectedMessageIDs),
                                 searchText: searchText,
                                 openMessageWindows: earlier(windows.all, previous?.openMessageWindows),
                                 trayMessageWindows: earlier(windows.inTray, previous?.trayMessageWindows),
                                 openDraftIDs: Array(drafts.keys),
                                 openTabs: openTabs.uniqued(), minimizedTabs: minimized.uniqued(),
                                 activeTab: activeTab.flatMap { storedTab($0) && !isGmail($0) ? $0 : nil })
        state.gmailWindows = gmailWindows.isEmpty ? nil : gmailWindows
        let selectedGmail = SessionCarryForward.split(Array(selectedMessageIDs)).gmail
        state.gmailSelectedMessageIDs = selectedGmail.isEmpty ? nil : selectedGmail
        let gmailTabs = tabs.filter(isGmail)
        let gmailMinimized = minimizedTabs.filter(isGmail)
        state.gmailTabs = gmailTabs.isEmpty ? nil : gmailTabs
        state.gmailMinimizedTabs = gmailMinimized.isEmpty ? nil : gmailMinimized
        state.gmailActiveTab = activeTab.flatMap { isGmail($0) ? $0 : nil }
        return state
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
        await finishDrafts()
        await store.flushAll()
        let wind = Task {
            await self.flushPendingActions()
            await self.coordinator.stopAll()
        }
        _ = await Waiting.upTo(2, for: [wind])
    }

    /// How long a quit waits for messages closed just before it to reach Drafts.
    static let draftSaveWait: TimeInterval = 5

    /// Before a quit or a relaunch: every message being written is kept on this Mac, the quit
    /// waits up to five seconds for those closed just before it to reach Drafts, and the copies
    /// in Drafts of discarded messages go, Undo being over. What does not finish in time is
    /// finished at the next launch: a save that was not answered is saved once more, and a copy
    /// not deleted is deleted then.
    private func finishDrafts() async {
        for d in drafts.values { unsentDrafts.keep(d) }
        discardExpiry?.cancel()
        discardExpiry = nil
        let finished = await unsentDrafts.finish(within: AppModel.draftSaveWait)
        if !finished { Log.info("app", "quit before every draft reached Drafts; the rest go at the next launch") }
        // A save refused meanwhile hands its message back, to be kept for the next launch.
        for d in drafts.values { unsentDrafts.keep(d) }
    }

    private func listen() {
        listeners.append(Task { [weak self] in
            guard let self else { return }
            for await change in await self.store.changes() {
                switch change {
                case .accountsChanged: await self.refreshAccounts()
                case .foldersChanged(let accountID):
                    // A Google account on the Gmail API shows its engine's folders, never its IMAP store's.
                    guard !self.usesGmailEngine(accountID) else { break }
                    self.folders[accountID] = await self.store.folders(for: accountID)
                    self.refreshDockBadge()
                case .messagesChanged(let folderID):
                    self.scheduleReload(for: folderID)
                    self.noteStoredMessagesChanged()
                case .contactsChanged: self.contactList = await self.contacts.all()
                }
            }
        })
        listeners.append(Task { [weak self] in
            guard let self else { return }
            for await event in self.coordinator.events {
                // The sync error and No new messages sounds follow the engine's own view of each
                // account, so a quiet reconnect or a pause it keeps on purpose plays nothing.
                self.play(self.soundGate.hear(event, uptime: ProcessInfo.processInfo.systemUptime, now: Date()))
                switch event {
                case .started(let id):
                    self.syncingAccounts.insert(id)
                    self.statusText = "Checking \(self.accountName(id)) for new mail"
                case .progress(let id, let text):
                    self.syncingAccounts.insert(id)
                    self.statusText = text
                case .finished(let id):
                    DiagnosticsService.shared.noteSyncPass()
                    self.syncingAccounts.remove(id)
                    self.statusText = "Up to date"
                    // "All folders are up to date." waits for every folder of every account on the
                    // Gmail API, whatever the list shows.
                    if self.usesGmailEngine(id) { self.engineList.checkEveryFolderListed() }
                    self.noteUnreadableFiles()
                    await self.refreshBandwidth()
                case .checked: break
                case .error(let id, let message):
                    self.syncingAccounts.remove(id)
                    self.statusText = message
                    self.accountStatus.apply(event)
                    self.noteUnreadableFiles()
                case .problem(_, let message): self.statusText = message
                case .actionFailed(_, let message, let names): self.showActionError(message, names: names)
                case .health(let id, let health):
                    self.accountStatus.apply(event)
                    self.online[id] = health.isReachable
                    if health == .needsSignIn { self.accountsNeedingSignIn.insert(id) } else { self.accountsNeedingSignIn.remove(id) }
                    if health.isFailing { self.soundIfFailureLasts(id) }
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

    /// Connections that slept with the Mac may be dead without knowing it, so every account
    /// opens fresh ones when it wakes.
    private func watchForWake() {
        guard wakeObserver == nil else { return }
        let coordinator = coordinator
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                         queue: .main) { _ in
            Task { await coordinator.macWoke() }
        }
    }

    func accountName(_ id: UUID) -> String { accounts.first { $0.id == id }?.email ?? "account" }

    /// The engine announces only mail dated within the last day and not from the account itself.
    private func announce(_ list: [MessageSummary], accountID: UUID, folderID: UUID) {
        guard !migrationInProgress, let account = accounts.first(where: { $0.id == accountID }),
              let folder = folder(folderID) ?? engineInbox(accountID: accountID, folderID: folderID) else { return }
        guard notifications.announce(list, account: account, folder: folder, policy: notificationPolicy) else { return }
        play(soundGate.newMailArrived())
    }

    func play(_ sound: MailSoundEvent?) {
        if let sound { SoundLibrary.play(sound) }
    }

    /// An account the engine says cannot sync may say nothing more by itself, as one waiting to
    /// be signed in again does, so the gate is asked once more when its failure may have lasted.
    private func soundIfFailureLasts(_ id: UUID) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((MailSoundGate.lastingFailure + 1) * 1_000_000_000))
            guard let self, self.accounts.contains(where: { $0.id == id && $0.isEnabled }) else { return }
            self.play(self.soundGate.failureLasted(id, uptime: ProcessInfo.processInfo.systemUptime))
        }
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
        if usesGmailEngine(messageID: messageID) {
            applyFromEngineNotification(action, messageID: messageID)
            return
        }
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
        if usesGmailEngine(messageID: messageID) {
            revealEngineMessage(messageID)
            return
        }
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

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        guard !WindowTray.shared.orderMailboxWindowFront() else { return }
        openMainWindow?()
    }

    func alreadyShowing(_ folderID: UUID) -> Bool {
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
        importCarriedOverSignatures()
        var map: [UUID: [FolderInfo]] = [:]
        for a in accounts {
            map[a.id] = usesGmailEngine(a.id) ? (folders[a.id] ?? []) : await store.folders(for: a.id)
        }
        folders = map
        refreshDockBadge()
    }

    /// Account signatures carried over as HTML source become the signatures they describe,
    /// with their pictures, fetched from the web once; see SignatureLibrary.
    private func importCarriedOverSignatures() {
        guard !importingSignatures, !signatures.book.carriedOverHTML.isEmpty else { return }
        importingSignatures = true
        let loader = remotePictureLoader
        Task {
            await signatures.importCarriedOverHTML(loader: loader)
            importingSignatures = false
        }
    }

    /// Maintained whenever folders change, so reading it from a view body costs nothing.
    var unifiedUnreadCount: Int { unifiedUnread }

    func refreshDockBadge() {
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
        // The table shows it: nothing is read from the stored rows.
        if await reloadEngineList() { return }
        do {
            if submittedSearchQuery != nil {
                // Sync reloads come often; asking Gmail again for each would spend the quota.
                await refreshSearchRows()
                return
            }
            let window = listWindow
            let shown = selection
            let loaded: [MessageSummary]
            let stored: Int
            switch shown {
            case .unified:
                loaded = try await store.unifiedInbox(limit: window)
                stored = try await store.unifiedCount()
            case .smart(let kind):
                let scope = kind.scope
                loaded = try await store.unifiedInbox(limit: window, scope: scope)
                stored = try await store.unifiedCount(scope: scope)
            case .folder(let id):
                loaded = try await store.messages(in: id, limit: window)
                stored = try await store.storedCount(in: id)
            default:
                loaded = []
                stored = 0
            }
            // A search submitted, or another mailbox chosen, while the store was read has its own
            // rows on screen by now, and they are not to be replaced with this mailbox's.
            guard submittedSearchQuery == nil, selection == shown else { return }
            messages = loaded
            storedInSelection = stored
            rebuildThreads()
        } catch {
            showAlert(for: error)
        }
    }

    private func matches(_ message: MessageSummary, _ needle: String) -> Bool {
        if message.subject.localizedCaseInsensitiveContains(needle) { return true }
        if message.from.name.localizedCaseInsensitiveContains(needle) { return true }
        if message.from.address.localizedCaseInsensitiveContains(needle) { return true }
        return message.snippet.localizedCaseInsensitiveContains(needle)
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
        return list.filter { matches($0, liveSearchNeedle) }
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

    func rebuildThreads() {
        // The table's rows are its own; the threads are then its selected rows' (see EngineList).
        guard !engineList.isShown else { return }
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
        // A conversation's row takes its newest message's id, so a reply arriving renames it,
        // and folding a conversation takes away its message lines: the selection moves to the
        // row now showing what was selected rather than being dropped, and the reading pane
        // keeps showing it. Only what is no longer listed at all is let go.
        let kept = ReadingSelection.carried(selectedMessageIDs, rows: Set(rowIndex.keys),
                                            conversations: threads.map { $0.messages.map(\.id) })
        if kept != selectedMessageIDs { selectedMessageIDs = kept }
    }

    func runSearch(fetchRows: Bool = true) async {
        serverSearchDebounce?.cancel()
        serverSearchDebounce = nil
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        let needle = liveSearchNeedle
        liveSearchNeedle = ""
        let q = searchText.trimmed
        guard !q.isEmpty else {
            submittedSearchQuery = nil
            cancelServerSearch()
            await reloadMessages()
            return
        }
        // Return after the pause has already asked the Gmail engines for ids fetches the rows' text.
        if submittedSearchQuery == q, engineSearch?.query == q, serverSearch == nil {
            if fetchRows { fetchEngineSearchRows() }
            return
        }
        // Return after the pause has already asked Gmail would only ask again, at twice the units.
        if submittedSearchQuery == q, let run = serverSearch {
            let scopes = searchScopes()
            if run.status.repeats(query: q, scopes: scopes, viaGmail: gmailAccounts(in: scopes)) { return }
        }
        // What typing filtered stays on screen until the first results replace it.
        if !needle.isEmpty {
            messages = messages.filter { matches($0, needle) }
            rebuildThreads()
        }
        submittedSearchQuery = q
        await startSearch(q, fetchRows: fetchRows)
    }

    /// Typing filters what is loaded at once; a pause of 600 ms with three or more characters
    /// then asks the server, as Return does.
    private func searchTextDidChange() {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        serverSearchDebounce?.cancel()
        serverSearchDebounce = nil
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
        guard needle.count >= 3 else { return }
        serverSearchDebounce = Task { [weak self] in
            _ = try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self, self.searchTextStorage.trimmed == needle else { return }
            self.serverSearchDebounce = nil
            // The Gmail engines are asked for the matching ids only while the owner may still be
            // typing (5 units), and for the rows' text after a second and a half more.
            await self.runSearch(fetchRows: false)
            guard let run = self.engineSearch, run.query == needle else { return }
            self.serverSearchDebounce = Task { [weak self] in
                _ = try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled, let self, self.searchTextStorage.trimmed == needle, self.engineSearch?.id == run.id else { return }
                self.serverSearchDebounce = nil
                self.fetchEngineSearchRows()
            }
        }
    }

    private func applyIncrementalSearch(_ needle: String) {
        let leavingFullResults = submittedSearchQuery != nil
        guard needle != liveSearchNeedle || leavingFullResults else { return }
        liveSearchNeedle = needle
        submittedSearchQuery = nil
        if leavingFullResults {
            cancelServerSearch()
            Task { await reloadMessages() }
        } else {
            rebuildThreads()
        }
    }

    func resetSearch() {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        serverSearchDebounce?.cancel()
        serverSearchDebounce = nil
        cancelServerSearch()
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

    /// The Home ribbon's Read/Unread and the U key: every message selected, each conversation's
    /// row standing for all its messages, read while any is unread and else unread, as Outlook does.
    func toggleReadOnSelection() {
        let list = selectedMessages
        guard !list.isEmpty else { return }
        markRead(list, ReadMarking.readUnreadMarksRead(list))
    }

    func toggleFlagOnSelection() {
        let list = selectedMessages
        guard let first = list.first else { return }
        setFlagged(list, !first.isFlagged)
    }

    func composeNew() {
        guard let account = accounts.first else { return }
        openCompose(.blank(account: account, signature: signature(for: account, .newMessages)), origin: .new)
    }

    func replyToSelection(all: Bool) {
        guard let thread = currentThread else { return }
        reply(to: thread.latest, all: all)
    }

    func forwardSelection() {
        guard let thread = currentThread else { return }
        forward(thread.latest)
    }

    /// Reply and Reply All, from the ribbon, the menus, the keys and the reading pane alike.
    /// The window opens once the original is downloaded (see originalForQuoting). `then` runs
    /// once the reply is open, as a message window closes after it.
    func reply(to message: MessageSummary, all: Bool, then: (() -> Void)? = nil) {
        guard let account = account(for: message) else { return }
        Task {
            let parsed = await originalForQuoting(message, forwarding: false)
            openReply(to: message, parsed: parsed, account: account, all: all)
            then?()
        }
    }

    /// Forward, as Reply opens.
    func forward(_ message: MessageSummary, then: (() -> Void)? = nil) {
        guard let account = account(for: message) else { return }
        Task {
            let parsed = await originalForQuoting(message, forwarding: true)
            openForward(message, parsed: parsed, account: account)
            then?()
        }
    }

    /// The original a reply or forward quotes, downloaded in full first when this Mac holds only
    /// its headers, so that the quote is the original as rich text with its pictures, not the
    /// few words the list shows. A message found only on the server comes with the pictures its
    /// text shows and, for a forward, its attachments. When it cannot be downloaded the owner is
    /// told so in one sentence and nil comes back: the quote is then those few words, without a
    /// picture's code or address (see QuotedText).
    func originalForQuoting(_ message: MessageSummary, forwarding: Bool) async -> MIMEMessage? {
        do {
            if message.isServerOnly {
                let text = try await openServerMessage(message, trigger: .asked)
                if forwarding { return await parsedBodyForForwarding(message) ?? text }
                return await serverBodyWithInlineImages(message) ?? text
            }
            if usesGmailEngine(message.accountID), let text = try await engineBody(for: message, purpose: .replyOrForward) {
                if forwarding { return await parsedBodyForForwarding(message) ?? text }
                return text
            }
            if let parsed = try await downloadedBody(for: message) { return parsed }
            Log.warning("Reply", "The original could not be downloaded to quote it: its account is not running",
                        account: account(for: message))
        } catch is CancellationError {
            return nil
        } catch {
            Log.warning("Reply", "The original could not be downloaded to quote it", error: error, account: account(for: message),
                        names: Log.names(heldBy: error))
        }
        showAlert(forwarding
                  ? "The original message could not be downloaded, so the forward does not include all of its text or its attachments."
                  : "The original message could not be downloaded, so the reply does not quote all of it.")
        return nil
    }

    /// Whether pictures from the web load for `message`: always, or because the owner loaded
    /// them for it in the reader.
    func loadsRemotePictures(for message: MessageSummary) -> Bool {
        loadRemoteImages || remotePicturesLoaded.contains(message.id)
    }

    /// A reply opened to be written, its original quoted with its pictures; those from the web
    /// are fetched when they load for the message, and are otherwise empty boxes.
    func openReply(to message: MessageSummary, parsed: MIMEMessage?, account: AccountInfo, all: Bool) {
        openCompose(.reply(to: message, parsed: parsed, account: account, all: all, signature: signature(for: account, .replies)),
                    origin: .reply, fetchingPictures: loadsRemotePictures(for: message))
    }

    func openForward(_ message: MessageSummary, parsed: MIMEMessage?, account: AccountInfo) {
        openCompose(.forward(message, parsed: parsed, account: account, signature: signature(for: account, .replies)),
                    origin: .reply, fetchingPictures: loadsRemotePictures(for: message))
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
        MoveTargets.folder(for: target, in: folders[target.accountID] ?? [])
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
        guard !selectionIsReadOnly else {
            statusText = AppModel.readOnlyNotice
            return
        }
        guard WindowTray.shared.orderMailboxWindowFront() else { return }
        movePaletteMessages = nil
        movePaletteWindow = nil
        showsMovePalette = true
    }

    /// Move in a message window's ribbon: the palette opens over that window and moves that
    /// message, whatever the mailbox window has selected.
    func openMovePalette(for message: MessageSummary) {
        guard !message.isServerOnly else {
            statusText = AppModel.readOnlyNotice
            return
        }
        movePaletteMessages = [message]
        movePaletteWindow = message.id
        showsMovePalette = true
    }

    func closeMovePalette() {
        showsMovePalette = false
        movePaletteMessages = nil
        movePaletteWindow = nil
    }

    /// What the open palette moves: the message of the window it opened over, else the selection.
    var paletteMessages: [MessageSummary] {
        movePaletteMessages ?? selectedMessages
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
        let accountIDs = Set(paletteMessages.map(\.accountID))
        return accounts.flatMap { folders[$0.id] ?? [] }.filter { MoveTargets.offers($0) && accountIDs.contains($0.accountID) }
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

    /// False when nothing it holds could move there, as when it is the folder they are in.
    @discardableResult
    func commitPalette(_ folder: FolderInfo) -> Bool {
        let list = paletteMessages
        closeMovePalette()
        return move(list, to: folder)
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
                showAlert("Could not read the original message to attach it.")
                return
            }
            let signature = signature(for: account, .replies)
            if parts.count == 1, let raw = await rawBody(for: first) {
                openCompose(.forwardAsAttachment(first, raw: raw, account: account, signature: signature), origin: .reply)
                return
            }
            var draft = ComposeDraft(accountID: account.id)
            draft.subject = "Fwd: \(parts.count) messages"
            draft.open(lead: "\n\n", signature: signature)
            draft.attachments = parts
            openCompose(draft, origin: .reply)
        }
    }

    /// A message's text when it has been opened this session, found without fetching anything.
    /// The conversation stack looks for it, and for the message's first words, in a later
    /// message's quote; its words are worked out away from the main thread, and only when the
    /// first words were not found.
    func openedBody(of message: MessageSummary) -> MIMEMessage? {
        bodyCache[message.id] ?? openedServerMessages[message.id]?.message
    }

    #if DEBUG
    /// For the debug snapshots, which have no account to fetch a message's text from.
    func snapshotBody(_ parsed: MIMEMessage, for id: String) { bodyCache[id] = parsed }
    #endif

    func parsedBody(for message: MessageSummary) async -> MIMEMessage? {
        if message.isServerOnly { return await serverBody(for: message) }
        do {
            return try await downloadedBody(for: message)
        } catch {
            showAlert(for: error)
            return nil
        }
    }

    /// The whole of a message this Mac lists, from what it holds or downloaded now. Nil when
    /// its account is not running; throws when the download fails.
    private func downloadedBody(for message: MessageSummary) async throws -> MIMEMessage? {
        if let cached = bodyCache[message.id] { return cached }
        // A Google account on the Gmail API opens through its engine: from the Mac for the newest
        // 1,000, from Gmail into memory for any other.
        if usesGmailEngine(message.accountID) { return try await engineBody(for: message, purpose: .window) }
        guard let syncer = await coordinator.syncer(for: message.accountID) else { return nil }
        let parsed = try await syncer.parsedMessage(for: message)
        bodyCache[message.id] = parsed
        if bodyCache.count > 200 { bodyCache.removeAll() }
        return parsed
    }

    /// How long a reader waits for a message's text before showing its first words with a
    /// line saying it is still coming, and how much silence from the server a fetch for a
    /// reader sits through before the connection is given up and opened afresh.
    static let readerBodyDeadline: TimeInterval = 12
    static let readerReplyPatience: TimeInterval = 20
    /// How many times a reader waits out the deadline before it stops and offers Try Again.
    static let readerBodyRounds = 4

    /// A message's text for the reading pane, a message window or tab, or a card of the
    /// conversation stack. Never waits on the server for ever: after `readerBodyDeadline` the
    /// reader is told through `slow`, shows the message's first words and waits again, joining
    /// the same fetch, which gives up a connection that has fallen silent and so is tried again
    /// on a fresh one. Two readers of one message, as the pane and the window a double-click
    /// opened, share one fetch rather than queueing a second behind it, and a reader that moves
    /// on stops waiting at once. `problem` is the sentence the reader shows in place of the text.
    func readerBody(for message: MessageSummary, slow: (String) -> Void) async -> (parsed: MIMEMessage?, problem: String?) {
        if let cached = bodyCache[message.id] { return (cached, nil) }
        // A Google account on the Gmail API opens through its engine, never over IMAP; the
        // engine's own opener waits and gives up on its own, and a failure is shown in the pane.
        if usesGmailEngine(message.accountID) {
            do {
                return (try await engineBody(for: message, purpose: .window), nil)
            } catch is CancellationError {
                return (nil, nil)
            } catch {
                if Task.isCancelled { return (nil, nil) }
                Log.warning("reader", "a message's text could not be opened through the Gmail API for the reader: \(error.localizedDescription)")
                return (nil, error.localizedDescription)
            }
        }
        let coordinator = coordinator
        let patience = AppModel.readerReplyPatience
        for round in 1...AppModel.readerBodyRounds {
            let outcome = await readerFetches.value(for: message.id, within: AppModel.readerBodyDeadline) {
                guard let syncer = await coordinator.syncer(for: message.accountID) else { return .unavailable }
                do {
                    return .parsed(try await syncer.parsedMessage(for: message, replyWithin: patience))
                } catch is CancellationError {
                    return .unavailable
                } catch {
                    return .failed(error.localizedDescription, Log.names(heldBy: error))
                }
            }
            switch outcome {
            case .finished(.parsed(let parsed)):
                bodyCache[message.id] = parsed
                if bodyCache.count > 200 { bodyCache.removeAll() }
                return (parsed, nil)
            case .finished(.unavailable), .cancelled:
                return (nil, nil)
            case .finished(.failed(let sentence, let names)):
                Log.warning("reader", "a message's text could not be fetched for the reader: \(sentence)", names: names)
                return (nil, sentence)
            case .timedOut:
                Log.warning("reader", "a message's text took longer than \(Int(AppModel.readerBodyDeadline)) s to fetch (round \(round) of \(AppModel.readerBodyRounds)); its first words are shown meanwhile",
                            details: ["inFlight": String(readerFetches.inFlight)])
                if Task.isCancelled { return (nil, nil) }
                // Still nothing after a second wait: the connection the text comes over is closed
                // when it has gone quiet, so that the fetch starts again on a fresh one.
                if round >= 2, let syncer = await coordinator.syncer(for: message.accountID) {
                    _ = await syncer.dropOpConnection(ifQuietFor: AppModel.readerReplyPatience)
                }
                if round < AppModel.readerBodyRounds { slow("This message is taking longer than usual to download. FalconMail is still trying.") }
            }
        }
        return (nil, "This message could not be downloaded just now.")
    }

    func rawBody(for message: MessageSummary) async -> Data? {
        guard !message.isServerOnly else { return nil }
        if usesGmailEngine(message.accountID) { return await engineRawMessage(message) }
        guard let syncer = await coordinator.syncer(for: message.accountID) else { return nil }
        return try? await syncer.body(for: message)
    }

    /// Carries out a change on messages, each account's through its own engine: `engine`, the
    /// change as the Gmail engine takes it, for a Google account on the Gmail API, and `op` over
    /// IMAP for any other. An account with neither running says so, and its rows come back,
    /// rather than the change being skipped in silence (§7.7).
    private func perform(_ messages: [MessageSummary], announcing: Bool = true, engine verb: MailActionRequest.Verb? = nil,
                         _ op: @escaping (AccountSyncer, [MessageSummary]) async throws -> [MailActionRecord]) {
        let messages = MessageActions.actionable(messages)
        guard !messages.isEmpty else { return }
        Task {
            var records: [MailActionRecord] = []
            var receipts: [ActionReceipt] = []
            var failure: (any Error)?
            for (accountID, group) in Dictionary(grouping: messages, by: { $0.accountID }) {
                if usesGmailEngine(accountID) {
                    guard let verb else { continue }
                    do {
                        receipts.append(contentsOf: try await performOnEngine(verb, group, accountID: accountID))
                    } catch {
                        Log.info("action", "\(self.accountName(accountID)): \(error.localizedDescription)")
                        failure = error
                    }
                    continue
                }
                guard let syncer = await coordinator.syncer(for: accountID) else {
                    failure = GmailEngineUnavailable(account: accountName(accountID), doing: "this")
                    continue
                }
                do {
                    records.append(contentsOf: try await op(syncer, group))
                } catch {
                    Log.info("action", "\(self.accountName(accountID)): \(error.localizedDescription)")
                    failure = error
                }
            }
            guard announcing else { return }
            if let failure {
                showActionError(failure.localizedDescription, names: Log.names(heldBy: failure))
                await reloadMessages()
            }
            offerUndo(records, receipts: receipts)
        }
    }

    /// Shows `message` under the toolbar for a while. `names` are the folder names in it, which
    /// diagnostics take out.
    func showActionError(_ message: String, names: [String] = []) {
        Log.error("Alert", message, names: names)
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

    func offerUndo(_ records: [MailActionRecord], receipts: [ActionReceipt] = []) {
        let undoable = receipts.filter(\.isUndoable)
        guard !records.isEmpty || !undoable.isEmpty else { return }
        undoExpiryTask?.cancel()
        undoExpiryTask = nil
        guard undoActionSeconds > 0 else { pendingUndo = nil; return }
        let undo: PendingUndo
        if let first = records.first {
            undo = PendingUndo(records: records, summary: MailActionRecord.summary(for: records), verbTitle: first.verbTitle, receipts: undoable)
        } else {
            undo = PendingUndo(records: [], summary: EngineActionText.summary(undoable, folderName: { [weak self] in self?.folder($0)?.name }),
                               verbTitle: EngineActionText.verbTitle(undoable[0].verb), receipts: undoable)
        }
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
            for receipt in undo.receipts where await coordinator.undo(receipt.id, accountID: receipt.accountID) {
                restored += receipt.messageCount
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
        perform(actionable(list).filter { $0.isRead != read }, engine: read ? .markRead : .markUnread) {
            try await $0.setFlag(.seen, on: $1, enabled: read)
        }
    }

    static let readOnlyNotice = "Messages found only on the server can be read and replied to, not changed."

    /// The messages an action may touch, saying so when the reader picked only ones it may not.
    func actionable(_ list: [MessageSummary]) -> [MessageSummary] {
        let kept = MessageActions.actionable(list)
        if kept.isEmpty, !list.isEmpty { statusText = AppModel.readOnlyNotice }
        return kept
    }

    /// Whether anything selected is a row found only on the server, which no action may change.
    var selectionIsReadOnly: Bool { selectedMessages.contains { $0.isServerOnly } }

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
        let onEngine = list.filter { usesGmailEngine($0.accountID) }
        for folder in onEngine {
            performOnEngineView(.markRead, in: ListView(scope: .folder(folder.id), filters: [.unread], conversations: false),
                                accountID: folder.accountID)
        }
        let list = list.filter { !usesGmailEngine($0.accountID) }
        if !onEngine.isEmpty { statusText = "Marked every message as read in \(name)" }
        guard !list.isEmpty else { return }
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
        perform(list.filter { !$0.isRead }, announcing: false, engine: .markRead) { try await $0.setFlag(.seen, on: $1, enabled: true, silent: true) }
    }

    func cancelPendingRead() {
        readTask?.cancel()
        readTask = nil
        pendingReadID = nil
    }

    func residentThread(containing message: MessageSummary) -> MessageThread? {
        threads.first { $0.messages.contains { $0.id == message.id } }
    }

    /// What the list's row `id` shows in the reading pane, as the list holds it now: a
    /// conversation's row its stack, one of its message lines (tagged `child:`) that message.
    func readingLine(_ id: String) -> ReadMarking.Line? {
        switch rowIndex[id] {
        case .thread(let thread): return .conversation(thread.messages)
        case .message(let message, _): return .message(message)
        default: return ReadMarking.line(tagged: id, in: threads.map(\.messages))
        }
    }

    /// Selecting a line reads, once the delay has passed with it still selected, the one message
    /// the reading pane shows open: a message line's own message, or a conversation row's newest.
    func selectionDidChange() {
        cancelPendingRead()
        if Preferences.bool(Pref.autoExpandConversation, default: true),
           selectedMessageIDs.count == 1, let id = selectedMessageIDs.first,
           let thread = threads.first(where: { $0.id == id }), thread.messages.count > 1 {
            expandedThreadIDs.insert(id)
        }
        guard readPolicy == .delay else { return }
        guard selectedMessageIDs.count == 1, let id = selectedMessageIDs.first, let line = readingLine(id) else { return }
        guard !ReadMarking.toMarkRead(selecting: line).isEmpty else { return }
        pendingReadID = id
        let nanoseconds = UInt64(max(1, markReadDelaySeconds)) * 1_000_000_000
        readTask = Task { [weak self] in
            _ = try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            guard self.pendingReadID == id, self.selectedMessageIDs == [id], let current = self.readingLine(id) else { return }
            self.readTask = nil
            self.pendingReadID = nil
            self.markReadSilently(ReadMarking.toMarkRead(selecting: current))
        }
    }

    func setFlagged(_ list: [MessageSummary], _ flagged: Bool) {
        perform(actionable(list), engine: flagged ? .flag : .unflag) { try await $0.setFlag(.flagged, on: $1, enabled: flagged) }
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

    func removeFromList(_ list: [MessageSummary]) {
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
        let list = actionable(list)
        guard !list.isEmpty else { return }
        removeFromList(list)
        perform(list, engine: .archive) { try await $0.archive($1) }
    }

    func delete(_ list: [MessageSummary]) {
        let list = actionable(list)
        guard !list.isEmpty else { return }
        removeFromList(list)
        perform(list, engine: .delete) { try await $0.delete($1) }
    }

    @discardableResult
    func move(_ list: [MessageSummary], to folder: FolderInfo) -> Bool {
        applyMove(list, to: folder)
    }

    private func applyMove(_ list: [MessageSummary], to folder: FolderInfo) -> Bool {
        let targets = actionable(list).filter { $0.accountID == folder.accountID && $0.folderID != folder.id }
        guard !targets.isEmpty else { return false }
        moveTargets.record(folder: folder)
        removeFromList(targets)
        perform(targets, engine: EngineActionText.moveVerb(to: folder)) { try await $0.move($1, to: folder) }
        return true
    }

    /// Whether Labels can act on the selection: messages of one Google account on the Gmail
    /// engine, which is where labels exist.
    var canLabelSelection: Bool {
        let accounts = Set(selectedMessages.map(\.accountID))
        guard accounts.count == 1, let account = accounts.first else { return false }
        return usesGmailEngine(account)
    }

    /// The selected messages' account's own labels, the ones the owner made, A to Z. Gmail's
    /// system labels (Inbox, Sent, Spam and the like) are folders with a role and are left out.
    var labelsForSelection: [FolderInfo] {
        guard canLabelSelection, let account = selectedMessages.first?.accountID else { return [] }
        return (folders[account] ?? [])
            .filter { $0.role == .other && $0.gmailLabelID != nil && !($0.gmailLabelID?.value.hasPrefix("CATEGORY_") ?? false) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Adds `label` to messages, as Gmail's Label as does: they stay where they are and show in
    /// that label too. Undo takes the label off again.
    func addLabel(_ label: FolderInfo, to list: [MessageSummary]) {
        let targets = actionable(list).filter { $0.accountID == label.accountID && usesGmailEngine($0.accountID) }
        guard !targets.isEmpty else { return }
        perform(targets, engine: .copy(to: label.id)) { _, _ in [] }
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
        let list = actionable(list)
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
        perform(moving, engine: role == .junk ? .junk : .notJunk) { syncer, group in
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
        let onEngine = threads.filter { usesGmailEngine($0.latest.accountID) }
        if !onEngine.isEmpty { muteOnEngine(onEngine, mute: true) }
        let onIMAP = threads.filter { !usesGmailEngine($0.latest.accountID) }
        guard !onIMAP.isEmpty else { return }
        let editable = onIMAP.filter { MessageActions.allowsChanges($0.messages) }
        if editable.isEmpty, !onIMAP.isEmpty { statusText = AppModel.readOnlyNotice }
        let threads = editable
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
        if usesGmailEngine(thread.latest.accountID), mutedRecord(for: thread) != nil {
            muteOnEngine([thread], mute: false)
            return
        }
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
            if usesGmailEngine(account.id) {
                do {
                    // labels.create; the sidebar takes the new folder from the engine.
                    _ = try await coordinator.createFolder(named: name, in: account)
                } catch {
                    showAlert(for: error)
                }
                return
            }
            guard let syncer = await coordinator.syncer(for: account.id) else {
                showAlert("\(account.email) is not connected yet.")
                return
            }
            do {
                try await syncer.createMailbox(named: name)
                await refreshAccounts()
            } catch {
                showAlert(for: error)
            }
        }
    }

    func purgeEverything(in folder: FolderInfo) {
        if usesGmailEngine(folder.accountID) {
            // Every message the folder holds on Gmail, after the owner confirmed it, described by
            // the view rather than by the rows loaded.
            performOnEngineView(.deleteForever, in: ListView(scope: .folder(folder.id), conversations: false), accountID: folder.accountID)
            return
        }
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

    /// Every message of a Google account on the Gmail API is in its list already, so Load older is
    /// never offered for one.
    var canShowMore: Bool {
        if case .folder(let id) = selection, let folder = folder(id), usesGmailEngine(folder.accountID) { return false }
        return messages.count < storedInSelection
    }

    func loadOlder() {
        if canShowMore {
            listWindow += AppModel.listPageSize
            Task { await reloadMessages() }
            return
        }
        guard case .folder(let id) = selection, let folder = folder(id), !usesGmailEngine(folder.accountID) else { return }
        Task {
            guard let syncer = await coordinator.syncer(for: folder.accountID) else { return }
            statusText = "Loading older messages in \(folder.name)"
            do { try await syncer.loadOlder(folder: folder) } catch { showAlert(for: error) }
            statusText = "Up to date"
        }
    }

    /// Forgets `address` as one of the recent addresses, as the suggestion list's remove button
    /// asks; a contact list's entry for it stays.
    func forgetRecentAddress(_ address: String) {
        contactList.removeAll { $0.isRecentAddress && $0.email.caseInsensitiveCompare(address) == .orderedSame }
        Task { try? await contacts.forgetRecent(address) }
    }

    func newDraft(_ draft: ComposeDraft) -> UUID {
        drafts[draft.id] = draft
        return draft.id
    }

    /// Double-click, Return, Open in the File menu and Open in Separate Window. A draft in Drafts
    /// opens to be written; any other message opens to be read, in a window of its own unless
    /// the owner chose tabs. Opened from a conversation's row, `conversation` is that
    /// conversation, and its window or tab shows all its messages as the reading pane does.
    func openMessage(_ message: MessageSummary, conversation: MessageThread? = nil, forceWindow: Bool = false,
                     openWindow: (String) -> Void) {
        let inDrafts = folder(message.folderID)?.role == .drafts
        switch MessageOpening.destination(inDraftsFolder: inDrafts, opensInWindow: openInWindowOnDoubleClick, forceWindow: forceWindow) {
        case .editDraft:
            editStoredDraft(message)
        case .window:
            markReadOnOpen(message)
            noteConversation(conversation, openedAs: message.id)
            showMessageWindow(message.id, openWindow: openWindow)
        case .tab:
            markReadOnOpen(message)
            noteConversation(conversation, openedAs: message.id)
            openMessageTab(message)
        }
    }

    /// A window or tab already open for the message is brought forward as it is.
    private func noteConversation(_ conversation: MessageThread?, openedAs id: String) {
        guard let conversation, conversation.messages.count > 1, conversation.messages.contains(where: { $0.id == id }) else { return }
        guard !openMessageWindows.contains(id), !(tabs + minimizedTabs).contains(.message(id)) else { return }
        conversationWindows[id] = ConversationStack.newestFirst(conversation.messages).map(\.id)
    }

    /// Opening a message whose window is already open brings that window forward, out of the
    /// tray if it is there, rather than opening a second one.
    func showMessageWindow(_ id: String, openWindow: (String) -> Void) {
        if !WindowTray.shared.bringForward(.message(id)) { openWindow(id) }
    }

    /// Brings forward the compose window or tab already holding draft `id`, or opens one for it.
    func showCompose(_ id: UUID) {
        if WindowTray.shared.bringForward(.compose(id)) { return }
        if (tabs + minimizedTabs).contains(.compose(id)) { return openTab(.compose(id)) }
        if Preferences.bool(Pref.composeInWindow, default: true), let open = openComposeWindow {
            open(id)
        } else {
            openTab(.compose(id))
        }
    }

    /// Coalesced, since a busy sync can change stored messages dozens of times a second.
    private func noteStoredMessagesChanged() {
        let showsOne = !openMessageWindows.isEmpty || (tabs + minimizedTabs).contains { if case .message = $0 { return true } else { return false } }
        guard showsOne, openMessagesRefresh == nil else { return }
        openMessagesRefresh = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self else { return }
            self.openMessagesRevision &+= 1
            self.openMessagesRefresh = nil
        }
    }

    private func editStoredDraft(_ message: MessageSummary) {
        // Opened twice, it would be two copies, each adding its own to Drafts as it closes.
        let open = drafts.values.map { (draft: $0.id, row: $0.sourceMessage == nil ? nil : $0.sourceMessageID) }
        if let id = UnsentMessage.alreadyOpen(row: message.id, among: open) { return showCompose(id) }
        Task {
            guard let parsed = await parsedBody(for: message) else {
                showActionError("Could not open that draft.")
                return
            }
            var draft = ComposeDraft.from(parsed: parsed, accountID: message.accountID)
            draft.sourceMessageID = message.id
            draft.sourceMessage = message
            // Its pictures from the web are fetched as a reply's are when they always load.
            openCompose(draft, origin: .reopenedDraft, fetchingPictures: loadRemoteImages)
        }
    }

    /// Saves the message closed as `id` to its account's Drafts folder. It stays on this Mac until
    /// the server has it, so a quit or a crash while it uploads leaves it for the next launch, and
    /// a save that fails hands it back to be kept and tried again.
    func saveDraftToServer(_ id: UUID) {
        guard let draft = drafts[id] else { return }
        guard !draft.isBlank, let account = accounts.first(where: { $0.id == draft.accountID }) else {
            drafts[id] = nil
            return
        }
        let saving = unsentDrafts.save(draft) { [weak self] draft in
            guard let self else { throw CancellationError() }
            try await self.uploadDraft(draft, account: account)
        }
        // Its file on this Mac stays while the save is under way.
        drafts[id] = nil
        Task {
            switch await saving.value {
            case nil:
                statusText = "Draft saved to \(folder(accountID: account.id, role: .drafts)?.name ?? "Drafts")"
            case is DraftsUnavailable:
                drafts[id] = draft
            case let deferred as GmailDraftDeferred:
                // Kept on this Mac and shown in Drafts; it goes to Gmail by itself, and its copy
                // here goes once Gmail has it.
                drafts[id] = draft
                statusText = deferred.sentence
            case is GmailDraftDiscarded:
                break
            case let error?:
                drafts[id] = draft
                showActionError("Could not save the draft: \(error.localizedDescription)", names: Log.names(heldBy: error))
            }
        }
    }

    /// One save of `draft` to its account's Drafts folder. The copy it was reopened from goes as
    /// soon as the new one is there, before the save counts as done, so that the message is
    /// replaced in Drafts rather than added beside itself, even by a quit just after.
    private func uploadDraft(_ draft: ComposeDraft, account: AccountInfo) async throws {
        if usesGmailEngine(account.id) {
            try await saveEngineDraft(draft, account: account, reason: .close)
            return
        }
        guard let folder = folder(accountID: account.id, role: .drafts), let syncer = await coordinator.syncer(for: account.id) else {
            throw DraftsUnavailable()
        }
        // With its Bcc recipients, which only the owner's copy in Drafts ever holds.
        let raw = MIMEBuilder.build(try draft.outgoing(from: account, asDraft: true), keepingBcc: true)
        try await syncer.append(raw: raw, to: folder, flags: [.draft, .seen], date: Date())
        await purgeStoredDraft(draft)
    }

    /// Removes the stored copy `draft` was opened from, now that it is saved again or sent. Only
    /// the row it was opened from goes, and only while its UID still names that message: after
    /// Drafts was renumbered the UID may name another draft, which is left alone, as is the copy
    /// of a draft kept by an earlier build that did not record its row.
    func purgeStoredDraft(_ draft: ComposeDraft) async {
        // A Gmail draft reopened is updated in place, never saved beside itself.
        guard !usesGmailEngine(draft.accountID) else { return }
        guard let opened = UnsentMessage.draftCopy(openedFrom: draft.sourceMessage, recordedID: draft.sourceMessageID) else { return }
        do {
            try await deleteStoredCopy(opened)
        } catch {
            Log.info("action", "\(accountName(opened.accountID)): the draft's earlier copy stays in Drafts: \(error.localizedDescription)")
        }
    }

    /// Deletes `row`, a message's copy in Drafts, while its UID still names that message. It
    /// returns once the account has taken the delete in hand, which it carries out even across a
    /// quit. A copy already gone, or of an account since removed, needs nothing more.
    func deleteStoredCopy(_ row: MessageSummary) async throws {
        if usesGmailEngine(row.accountID) {
            try await deleteEngineDraftCopy(row)
            return
        }
        guard accounts.contains(where: { $0.id == row.accountID }), let stored = await store.currentRow(of: row) else { return }
        guard let syncer = await coordinator.syncer(for: row.accountID) else { throw DraftsUnavailable() }
        removeFromList([stored])
        try await syncer.purge([stored])
    }

    /// Closes, as closing any message not yet sent does, the drafts that no compose window or tab
    /// holds, such as those open at the last quit: what was written goes to the Drafts folder.
    /// One still being written is saved only as it closes: a copy saved from under it would be
    /// one that Discard could not take back and that closing would add a second copy beside.
    func saveLeftoverDrafts() {
        let inTabs = (tabs + minimizedTabs).compactMap { if case .compose(let id) = $0 { return id } else { return nil } }
        let open = composeWindowDrafts.union(inTabs)
        for id in drafts.keys where !open.contains(id) { closeUnsent(id) }
    }

    /// A message opened in a window or tab of its own is read at once: that message alone, the
    /// newest when a conversation's row was opened, its other messages staying as they were.
    private func markReadOnOpen(_ message: MessageSummary) {
        guard readPolicy != .never else { return }
        cancelPendingRead()
        markReadSilently([message])
    }

    /// A folded card of the conversation stack opened by a click is read as a message selected
    /// in the list is: once the delay has passed. The stack cancels the task returned when the
    /// card is folded again, or the stack closes, before then. Nil when there is nothing to wait
    /// for.
    func readAfterDelay(_ message: MessageSummary) -> Task<Void, Never>? {
        guard readPolicy == .delay, !message.isRead else { return nil }
        let nanoseconds = UInt64(max(1, markReadDelaySeconds)) * 1_000_000_000
        return Task { [weak self] in
            _ = try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.markReadSilently([self.messages.first { $0.id == message.id } ?? message])
        }
    }

    func send(_ draft: ComposeDraft) throws {
        guard let account = accounts.first(where: { $0.id == draft.accountID }) else { throw FalconError.storage("account missing") }
        let message = try draft.outgoing(from: account)
        Task {
            do {
                await outbox.setUndoWindow(TimeInterval(undoSendSeconds))
                // A Google account on the Gmail API sends in the replied conversation, and its
                // Gmail draft goes once Gmail confirms the send.
                let link = await engineDraftLink(for: draft, account: account)
                let item = try await outbox.enqueue(accountID: account.id, from: account.email, message: message, sendAt: draft.scheduledAt,
                                                    gmailThreadID: link.thread, gmailDraftID: link.draftID)
                await writeSidecar(draft, for: item.id)
                await purgeStoredDraft(draft)
                try? await contacts.recordUse(accountID: account.id, addresses: message.to + message.cc + message.bcc)
                contactList = await contacts.all()
            } catch {
                showAlert(for: error)
            }
        }
        drafts[draft.id] = nil
        closeTab(.compose(draft.id))
    }

    /// The Bcc line of `message`: its own Bcc header, as a copy in Sent kept by another program
    /// or a draft has, and the Bcc recipients written down when FalconMail sent it, which Gmail's
    /// copy in Sent Mail does not name.
    func bcc(of message: MessageSummary, parsed: MIMEMessage?) -> [EmailAddress] {
        recipientLines(of: message, parsed: parsed).bcc
    }

    /// The To, Cc and Bcc lines of the reading pane, a message's window and its conversation,
    /// for stored messages and Google messages on the Gmail API alike (see ReaderRecipients).
    func recipientLines(of message: MessageSummary, parsed: MIMEMessage?) -> ReaderRecipients {
        let sentBcc = outbox.sentBcc
        return ReaderRecipients(message, parsed: parsed, recorded: { sentBcc.bcc(forMessageID: $0) })
    }

    var sendingSoonItems: [OutboxItem] {
        outboxItems.filter { $0.isSendingSoon(within: TimeInterval(undoSendSeconds)) }
    }

    func cancelAndReopen(_ item: OutboxItem) {
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
            // Where it opens follows the compose setting, as every other message being written does,
            // and its pictures from the web are fetched as a reopened draft's are.
            openCompose(draft, origin: .outboxRecall, fetchingPictures: loadRemoteImages)
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
        let (parsed, sidecar) = await Task.detached(priority: .userInitiated) { () -> (MIMEMessage?, ComposeDraftSidecar?) in
            (raw.map { MIMEParser.parse($0) }, AtomicFile.readJSON(ComposeDraftSidecar.self, from: url))
        }.value
        if let sidecar {
            return sidecar.draft(attachments: parsed.map { ComposeDraft.outgoingAttachments(of: $0) } ?? [])
        }
        // Read on the main thread, where AppKit reads HTML.
        guard let parsed else { return nil }
        var draft = ComposeDraft.from(parsed: parsed, accountID: accountID)
        // What was queued holds no Bcc header; the item itself keeps who was in each box.
        if let to = item.to { draft.to = OutgoingRecipients.box(to) }
        if let cc = item.cc { draft.cc = OutgoingRecipients.box(cc) }
        if let bcc = item.bcc { draft.bcc = OutgoingRecipients.box(bcc) }
        return draft
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
        // An account set up with an app password becomes a Google account, which the Gmail API
        // serves; its IMAP store stays as it was.
        account.provider = "google"
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
            for a in accounts where a.isEnabled {
                do { try await coordinator.runRulesOnInbox(a) } catch { showAlert(for: error) }
            }
            statusText = "Rules applied"
        }
    }

    func reloadArchives() async {
        archiveRecords = await archives.all()
    }

    /// Uploads the files' messages, pausing whenever the account's daily upload allowance is
    /// spent or Gmail asks for quiet, and syncing the folder for them now and then rather than
    /// after every message.
    func importFiles(_ urls: [URL], into folder: FolderInfo) {
        Task {
            // Each failure has reached diagnostics once already, from the engine or the import. A
            // Google account on the Gmail API imports with messages.import.
            let outcome = await coordinator.importFiles(urls, into: folder)
            for failure in outcome.failures { showAlert(for: failure) }
            statusText = "Imported \(outcome.imported) messages into \(folder.name)"
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
        Log.info("app", "quit")
        cancelPendingRead()
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        serverSearchDebounce?.cancel()
        serverSearchDebounce = nil
        cancelServerSearch()
        // Before the actions are flushed, which sends the deletes of discarded messages' copies too.
        await finishDrafts()
        await flushPendingActions()
        saveSessionNow()
        signatures.saveNow()
        await store.flushAll()
        await coordinator.stopAll()
        Log.flush()
    }
}

extension Array where Element: Hashable {
    /// The elements in their order, each once.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

extension Outbox {
    func setUndoWindow(_ seconds: TimeInterval) {
        undoWindow = seconds
    }
}

