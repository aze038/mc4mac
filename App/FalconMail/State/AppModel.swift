import SwiftUI
import Observation
import AppKit
import FalconCore

enum SidebarSelection: Hashable, Codable {
    case unified
    case folder(UUID)
    case archive(UUID)
    case calendar
    case contacts
    case outbox
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
    let indexer = SpotlightIndexer()
    let coordinator: SyncCoordinator
    let outbox: Outbox
    let contacts: ContactStore
    let archives: ArchiveRecordStore
    let notifications = NotificationService()
    let updates = UpdateManager()
    let session: SessionStore

    var accounts: [AccountInfo] = []
    var folders: [UUID: [FolderInfo]] = [:]
    var selection: SidebarSelection? = .unified
    var messages: [MessageSummary] = []
    var threads: [MessageThread] = []
    var selectedMessageIDs = Set<String>()
    var searchText = ""
    var isSearching = false
    var statusText = "Ready"
    var online: [UUID: Bool] = [:]
    var outboxItems: [OutboxItem] = []
    var archiveRecords: [ArchiveRecord] = []
    var errorMessage: String?
    var contactList: [ContactInfo] = []
    var openMessageWindows = Set<String>()
    var tabs: [WorkspaceTab] = []
    var minimizedTabs: [WorkspaceTab] = []
    var activeTab: WorkspaceTab?
    var tabTitles: [String: String] = [:]
    var cacheSizeBytes = 0

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
    private var sentSoundStorage = Preferences.string("sentSound", default: "Pop")
    var sentSound: String {
        get { sentSoundStorage }
        set { sentSoundStorage = newValue; Preferences.set(newValue, "sentSound") }
    }

    @ObservationIgnored private var restoredState: SessionState?
    @ObservationIgnored private var knownSentIDs = Set<UUID>()
    @ObservationIgnored private var bodyCache: [String: MIMEMessage] = [:]
    @ObservationIgnored private var listeners: [Task<Void, Never>] = []
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var sessionSaveTask: Task<Void, Never>?
    @ObservationIgnored private var pendingDraftSaves: [UUID: Task<Void, Never>] = [:]

    private func applyOfflineSettings() {
        Task { await coordinator.setBodyPrefetch(offlineBodies, maxBytes: maxOfflineMB * 1024 * 1024) }
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
        self.store = store
        self.tokens = tokens
        self.rules = rules
        self.coordinator = SyncCoordinator(store: store, tokens: tokens, rules: rules, indexer: indexer)
        self.outbox = Outbox(layout: layout, sender: SMTPSender(store: store, tokens: tokens), undoWindow: 10)
        self.contacts = ContactStore(layout: layout)
        self.archives = ArchiveRecordStore(layout: layout)
        self.session = SessionStore(layout: layout)
    }

    func bootstrap() async {
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
        await refreshAccounts()
        archiveRecords = await archives.all()
        contactList = await contacts.all()
        await notifications.requestPermission()
        listen()
        await coordinator.startAll()
        await reloadMessages()
        if let s = restoredState {
            let ids = Set(s.selectedMessageIDs)
            selectedMessageIDs = ids.filter { id in threads.contains { $0.id == id } }
            await restoreTabs(s.openTabs, minimized: s.minimizedTabs, active: s.activeTab)
        }
        Task { await syncContacts() }
    }

    var windowsToRestore: (messages: [String], drafts: [UUID]) {
        let state = restoredState
        restoredState = nil
        let tabDrafts = Set((tabs + minimizedTabs).compactMap { if case .compose(let id) = $0 { return id } else { return nil } })
        return (state?.openMessageWindows ?? [], drafts.keys.filter { !tabDrafts.contains($0) })
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
        for d in drafts.values { session.saveDraft(d) }
        await store.flushAll()
        let stop = Task { await coordinator.stopAll() }
        let timeout = Task { _ = try? await Task.sleep(nanoseconds: 2_000_000_000) }
        _ = await Task.select(stop, timeout)
    }

    private func listen() {
        listeners.append(Task { [weak self] in
            guard let self else { return }
            for await change in await self.store.changes() {
                switch change {
                case .accountsChanged: await self.refreshAccounts()
                case .foldersChanged(let accountID): self.folders[accountID] = await self.store.folders(for: accountID)
                case .messagesChanged(let folderID): self.scheduleReload(for: folderID)
                case .contactsChanged: self.contactList = await self.contacts.all()
                }
            }
        })
        listeners.append(Task { [weak self] in
            guard let self else { return }
            for await event in self.coordinator.events {
                switch event {
                case .started(let id): self.statusText = "Syncing \(self.accountName(id))"
                case .progress(_, let text): self.statusText = text
                case .finished: self.statusText = "Up to date"
                case .error(let id, let message): self.statusText = "\(self.accountName(id)): \(message)"
                case .online(let id, let on): self.online[id] = on
                case .newMessages(let id, _, let list):
                    self.notifications.notify(newMessages: list, accountEmail: self.accountName(id))
                case .folderSynced: break
                }
            }
        })
        listeners.append(Task { [weak self] in
            guard let self else { return }
            for await items in await self.outbox.updates() {
                let sent = Set(items.filter { $0.status == .sent }.map { $0.id })
                if !self.knownSentIDs.isEmpty || !self.outboxItems.isEmpty, !sent.subtracting(self.knownSentIDs).isEmpty {
                    SystemSounds.play(self.sentSound)
                }
                self.knownSentIDs = sent
                self.outboxItems = items
            }
        })
    }

    func accountName(_ id: UUID) -> String { accounts.first { $0.id == id }?.email ?? "account" }

    func refreshAccounts() async {
        accounts = await store.allAccounts()
        var map: [UUID: [FolderInfo]] = [:]
        for a in accounts { map[a.id] = await store.folders(for: a.id) }
        folders = map
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
            try? await Task.sleep(nanoseconds: 300_000_000)
            await self?.reloadMessages()
            self?.reloadTask = nil
        }
    }

    func reloadMessages() async {
        do {
            if !searchText.trimmed.isEmpty {
                await runSearch()
                return
            }
            switch selection {
            case .unified: messages = try await store.unifiedInbox()
            case .folder(let id): messages = try await store.messages(in: id)
            default: messages = []
            }
            rebuildThreads()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func rebuildThreads() {
        if groupByThread {
            threads = ConversationThreader.group(messages).map { MessageThread(messages: $0) }
        } else {
            threads = messages.map { MessageThread(messages: [$0]) }
        }
        let valid = selectedMessageIDs.filter { id in threads.contains { $0.id == id } }
        if valid != selectedMessageIDs { selectedMessageIDs = valid }
    }

    func runSearch() async {
        let q = searchText.trimmed
        guard !q.isEmpty else { await reloadMessages(); return }
        isSearching = true
        defer { isSearching = false }
        var found = (try? await store.search(q, accountID: nil)) ?? []
        var seen = Set(found.map { $0.id })
        for id in await indexer.search(q) where !seen.contains(id) {
            if let m = try? await store.message(id: id) { found.append(m); seen.insert(id) }
        }
        messages = found.sorted { $0.date > $1.date }
        rebuildThreads()
    }

    func select(_ s: SidebarSelection?) {
        selection = s
        selectedMessageIDs = []
        searchText = ""
        Task { await reloadMessages() }
        saveSession()
    }

    var selectedThreads: [MessageThread] { threads.filter { selectedMessageIDs.contains($0.id) } }
    var selectedMessages: [MessageSummary] { selectedThreads.flatMap { $0.messages } }
    var currentThread: MessageThread? { selectedMessageIDs.count == 1 ? threads.first { $0.id == selectedMessageIDs.first! } : nil }

    func account(for message: MessageSummary) -> AccountInfo? { accounts.first { $0.id == message.accountID } }
    func folder(_ id: UUID) -> FolderInfo? { folders.values.flatMap { $0 }.first { $0.id == id } }

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

    private func perform(_ messages: [MessageSummary], _ op: @escaping (AccountSyncer, [MessageSummary]) async throws -> Void) {
        Task {
            for (accountID, group) in Dictionary(grouping: messages, by: { $0.accountID }) {
                guard let syncer = await coordinator.syncer(for: accountID) else { continue }
                do { try await op(syncer, group) } catch { errorMessage = error.localizedDescription }
            }
        }
    }

    func markRead(_ list: [MessageSummary], _ read: Bool) {
        perform(list.filter { $0.isRead != read }) { try await $0.setFlag(.seen, on: $1, enabled: read) }
    }

    func setFlagged(_ list: [MessageSummary], _ flagged: Bool) {
        perform(list) { try await $0.setFlag(.flagged, on: $1, enabled: flagged) }
    }

    func archive(_ list: [MessageSummary]) {
        selectedMessageIDs = []
        perform(list) { try await $0.archive($1) }
    }

    func delete(_ list: [MessageSummary]) {
        selectedMessageIDs = []
        perform(list) { try await $0.delete($1) }
    }

    func move(_ list: [MessageSummary], to folder: FolderInfo) {
        selectedMessageIDs = []
        perform(list.filter { $0.accountID == folder.accountID }) { try await $0.move($1, to: folder) }
    }

    func syncNow() {
        Task { await coordinator.syncNow() }
    }

    func loadOlder() {
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
        if forceWindow || openInWindowOnDoubleClick { openWindow(message.id) } else { openMessageTab(message) }
    }

    func send(_ draft: ComposeDraft) throws {
        guard let account = accounts.first(where: { $0.id == draft.accountID }) else { throw FalconError.storage("account missing") }
        let message = try draft.outgoing(from: account)
        Task {
            do {
                await outbox.setUndoWindow(TimeInterval(undoSendSeconds))
                _ = try await outbox.enqueue(accountID: account.id, from: account.email, message: message, sendAt: draft.scheduledAt)
                try? await contacts.recordUse(accountID: account.id, addresses: message.to + message.cc + message.bcc)
                contactList = await contacts.all()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        drafts[draft.id] = nil
        closeTab(.compose(draft.id))
    }

    func undoSend(_ item: OutboxItem) {
        Task { try? await outbox.cancel(item.id) }
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
        saveSessionNow()
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
