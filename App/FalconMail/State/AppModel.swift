import SwiftUI
import Combine
import AppKit
import FalconCore

enum SidebarSelection: Hashable {
    case unified
    case folder(UUID)
    case archive(UUID)
    case calendar
    case outbox
}

struct MessageThread: Identifiable, Hashable {
    var id: String { latest.id }
    var messages: [MessageSummary]
    var latest: MessageSummary { messages[0] }
    var unreadCount: Int { messages.filter { !$0.isRead }.count }
}

@MainActor
final class AppModel: ObservableObject {
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

    @Published var accounts: [AccountInfo] = []
    @Published var folders: [UUID: [FolderInfo]] = [:]
    @Published var selection: SidebarSelection? = .unified
    @Published var messages: [MessageSummary] = []
    @Published var threads: [MessageThread] = []
    @Published var selectedMessageIDs = Set<String>()
    @Published var searchText = ""
    @Published var isSearching = false
    @Published var statusText = "Ready"
    @Published var online: [UUID: Bool] = [:]
    @Published var outboxItems: [OutboxItem] = []
    @Published var archiveRecords: [ArchiveRecord] = []
    @Published var errorMessage: String?
    @Published var drafts: [UUID: ComposeDraft] = [:]
    @Published var contactList: [ContactInfo] = []

    @AppStorage("groupByThread") var groupByThread = true { didSet { rebuildThreads() } }
    @AppStorage("undoSendSeconds") var undoSendSeconds = 10
    @AppStorage("loadRemoteImages") var loadRemoteImages = false

    private var bodyCache: [String: MIMEMessage] = [:]
    private var listeners: [Task<Void, Never>] = []
    private var reloadTask: Task<Void, Never>?

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
    }

    func bootstrap() async {
        do { try await store.load() } catch { errorMessage = error.localizedDescription }
        await refreshAccounts()
        archiveRecords = await archives.all()
        contactList = await contacts.all()
        await notifications.requestPermission()
        listen()
        await coordinator.startAll()
        await reloadMessages()
        Task { await syncContacts() }
    }

    private func listen() {
        listeners.append(Task { [weak self] in
            guard let self else { return }
            for await change in await self.store.changes() {
                switch change {
                case .accountsChanged: await self.refreshAccounts()
                case .foldersChanged: await self.refreshAccounts()
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
            for await items in await self.outbox.updates() { self.outboxItems = items }
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
        selectedMessageIDs = selectedMessageIDs.filter { id in threads.contains { $0.id == id } }
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
            let raw = try await syncer.body(for: message)
            let parsed = MIMEParser.parse(raw)
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
    }

    func undoSend(_ item: OutboxItem) {
        Task { try? await outbox.cancel(item.id) }
    }

    func addGoogleAccount() async throws {
        guard let config = OAuthConfigLoader.load() else {
            throw FalconError.invalidInput("Add your Google OAuth client ID in Settings → Google first.")
        }
        let flow = GoogleSignInFlow(config: config)
        let result = try await flow.run(openURL: { url in
            DispatchQueue.main.async { _ = NSWorkspace.shared.open(url) }
        })
        let account = accounts.first { $0.email.caseInsensitiveCompare(result.email) == .orderedSame }
            ?? AccountInfo.google(email: result.email, displayName: result.name)
        try await tokens.save(result.token, for: account.id)
        try await store.saveAccount(account)
        await refreshAccounts()
        await coordinator.start(account: account)
        Task { await syncContacts() }
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
        await coordinator.stopAll()
        await store.flushAll()
    }
}

extension Outbox {
    func setUndoWindow(_ seconds: TimeInterval) {
        undoWindow = seconds
    }
}
