import Foundation

/// Which messages a list wants. Kept here so the filtering happens inside the store actor
/// rather than by copying every message to the main thread first.
public enum MessageScope: String, Sendable, Hashable {
    case all, unread, flagged, attachments

    public func matches(_ m: MessageSummary) -> Bool {
        switch self {
        case .all: return true
        case .unread: return !m.isRead
        case .flagged: return m.isFlagged
        case .attachments: return m.hasAttachments
        }
    }
}

public enum StoreChange: Sendable {
    case accountsChanged
    case foldersChanged(accountID: UUID)
    case messagesChanged(folderID: UUID)
    case contactsChanged
}

/// Why an account's folder list could not be used. Its folders and their messages are kept on
/// disk under ids only that list knows, so the account is left alone rather than given a new
/// list that would orphan them.
public struct FolderListProblem: Sendable, Equatable {
    public var detail: String
    public var fileName: String
}

public actor MailStore {
    public let layout: FileLayout
    private var accounts: [AccountInfo] = []
    /// The name the account list is kept under when it could not be read. Accounts are neither
    /// added nor removed meanwhile: a new list would give them new ids, orphaning the mail,
    /// folders and sign-ins stored under the old ones, and download everything again.
    private var accountListProblem: String?
    private var folders: [UUID: [FolderInfo]] = [:]
    private var folderListProblems: [UUID: FolderListProblem] = [:]
    /// Folders a list from the server left out, and when the first such list came.
    private var missingSince: [UUID: Date] = [:]
    private var folderStores: [UUID: FolderStore] = [:]
    private var folderStoreLoads: [UUID: Task<FolderStore, Error>] = [:]
    private var changeContinuations: [UUID: AsyncStream<StoreChange>.Continuation] = [:]

    public init(layout: FileLayout = FileLayout()) {
        self.layout = layout
    }

    public func load() throws {
        try layout.ensureDirectory(layout.root)
        let what = "the account list"
        switch AtomicFile.loadJSON([AccountInfo].self, from: layout.accountsFile, what: what) {
        case .loaded(let list):
            accounts = list
        case .missing:
            // One set aside at an earlier launch still holds the ids that every account's
            // stored mail is filed under.
            if let aside = AtomicFile.setAsideCopies(of: layout.accountsFile).last {
                Log.warning("Store", "no account list, and \(aside.lastPathComponent) is still set aside; accounts are not added or removed",
                            code: "stillSetAside", logAs: "store")
                StoredFileNotices.add(what)
                accountListProblem = aside.lastPathComponent
            }
        case .setAside(let aside, _):
            accountListProblem = aside.lastPathComponent
        case .unreadable:
            accountListProblem = layout.accountsFile.lastPathComponent
        }
        for a in accounts {
            let file = layout.foldersFile(a.id)
            switch AtomicFile.loadJSON([FolderInfo].self, from: file, what: "the folder list for \(a.email)") {
            case .loaded(let list):
                folders[a.id] = list
            case .missing:
                folders[a.id] = []
                if let aside = AtomicFile.setAsideCopies(of: file).last {
                    // A new list would give every folder a new id, orphaning the ones stored
                    // under the list that was set aside, just as at the launch that set it aside.
                    Log.warning("Store", "\(a.email): no folder list, and \(aside.lastPathComponent) is still set aside; not syncing",
                                account: a, code: "stillSetAside", logAs: "store")
                    StoredFileNotices.add("the folder list for \(a.email)")
                    folderListProblems[a.id] = FolderListProblem(detail: "an earlier folder list is still set aside", fileName: aside.lastPathComponent)
                }
            case .setAside(let aside, let detail):
                folders[a.id] = []
                folderListProblems[a.id] = FolderListProblem(detail: detail, fileName: aside.lastPathComponent)
            case .unreadable(let detail):
                folders[a.id] = []
                folderListProblems[a.id] = FolderListProblem(detail: detail, fileName: file.lastPathComponent)
            }
        }
    }

    /// Set when the account's folder list could not be read at launch; nothing writes a new one.
    public func folderListProblem(_ accountID: UUID) -> FolderListProblem? {
        folderListProblems[accountID]
    }

    public func changes() -> AsyncStream<StoreChange> {
        let id = UUID()
        return AsyncStream { continuation in
            changeContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        changeContinuations[id] = nil
    }

    private func emit(_ change: StoreChange) {
        for c in changeContinuations.values { c.yield(change) }
    }

    public func allAccounts() -> [AccountInfo] { accounts }

    public func account(_ id: UUID) -> AccountInfo? { accounts.first { $0.id == id } }

    private func refuseIfAccountListUnread() throws {
        guard let kept = accountListProblem else { return }
        throw FalconError.storage("FalconMail could not read its list of accounts, which is kept as \(kept). No account is added or removed "
                                  + "until that list can be read again, so the mail stored for the accounts in it stays theirs.")
    }

    public func saveAccount(_ account: AccountInfo) throws {
        try refuseIfAccountListUnread()
        if let i = accounts.firstIndex(where: { $0.id == account.id }) { accounts[i] = account } else { accounts.append(account) }
        try AtomicFile.writeJSON(accounts, to: layout.accountsFile)
        if folders[account.id] == nil { folders[account.id] = [] }
        emit(.accountsChanged)
    }

    public func removeAccount(_ id: UUID) throws {
        try refuseIfAccountListUnread()
        accounts.removeAll { $0.id == id }
        try AtomicFile.writeJSON(accounts, to: layout.accountsFile)
        for f in folders[id] ?? [] { folderStores[f.id] = nil }
        folders[id] = nil
        try? FileManager.default.removeItem(at: layout.accountDirectory(id))
        emit(.accountsChanged)
    }

    public func folders(for accountID: UUID) -> [FolderInfo] {
        (folders[accountID] ?? []).sorted { a, b in
            if a.role.sortOrder != b.role.sortOrder { return a.role.sortOrder < b.role.sortOrder }
            return a.path.localizedCaseInsensitiveCompare(b.path) == .orderedAscending
        }
    }

    public func allFolders() -> [FolderInfo] { accounts.flatMap { folders(for: $0.id) } }

    public func folder(_ id: UUID) -> FolderInfo? {
        for list in folders.values { if let f = list.first(where: { $0.id == id }) { return f } }
        return nil
    }

    public func folder(accountID: UUID, role: FolderRole) -> FolderInfo? {
        folders[accountID]?.first { $0.role == role }
    }

    public func folder(accountID: UUID, path: String) -> FolderInfo? {
        folders[accountID]?.first { $0.path == path }
    }

    /// Brings the account's stored folders into line with a list the server gave, and returns
    /// the folders that list named, as stored, which are the ones to sync.
    ///
    /// A folder the list leaves out keeps its record and everything stored for it, its rows,
    /// offline copies and what Load older brought, until a list at least `goneAfter` later leaves
    /// it out too: a server can leave folders out of one reply, or give none at all, and a folder
    /// dropped for that would have to be listed again from scratch while the server still held
    /// all of it. A list without INBOX, which every IMAP server lists, leaves nothing out.
    public func reconcileFolders(accountID: UUID, listed: [IMAPFolderInfo], goneAfter: TimeInterval = 60,
                                 now: Date = Date()) throws -> [FolderInfo] {
        try refuseIfFolderListUnread(accountID)
        var unlisted = folders[accountID] ?? []
        var result: [FolderInfo] = []
        var named = Set<UUID>()
        for l in listed where !result.contains(where: { $0.path == l.path }) {
            if var f = unlisted.first(where: { $0.path == l.path }) {
                f.name = l.displayName
                f.attributes = l.attributes
                f.role = l.role
                f.isSelectable = l.isSelectable
                f.delimiter = l.delimiter
                result.append(f)
                named.insert(f.id)
                unlisted.removeAll { $0.id == f.id }
                missingSince[f.id] = nil
            } else {
                let f = FolderInfo(accountID: accountID, path: l.path, name: l.displayName, delimiter: l.delimiter,
                                   role: l.role, attributes: l.attributes, isSelectable: l.isSelectable)
                result.append(f)
                named.insert(f.id)
            }
        }
        let believed = listed.contains { $0.role == .inbox }
        let email = account(accountID)?.email ?? "an account"
        if !believed, !unlisted.isEmpty {
            Log.info("store", "\(email): a folder list without INBOX (\(listed.count) folders) takes no folder off this Mac")
        }
        for f in unlisted {
            if believed, let since = missingSince[f.id], now.timeIntervalSince(since) >= goneAfter {
                Log.info("store", "\(email) \(f.path): left out of the server's folder lists since \(ISO8601DateFormatter.archive.string(from: since)); removed")
                missingSince[f.id] = nil
                folderStores[f.id] = nil
                try? FileManager.default.removeItem(at: layout.folderDirectory(accountID: accountID, folderID: f.id))
                continue
            }
            if believed, missingSince[f.id] == nil {
                missingSince[f.id] = now
                Log.info("store", "\(email) \(f.path): left out of the server's folder list; kept until a later list leaves it out too")
            }
            result.append(f)
        }
        folders[accountID] = result
        try AtomicFile.writeJSON(result, to: layout.foldersFile(accountID))
        emit(.foldersChanged(accountID: accountID))
        return folders(for: accountID).filter { named.contains($0.id) }
    }

    public func updateFolder(_ folder: FolderInfo) throws {
        try refuseIfFolderListUnread(folder.accountID)
        guard var list = folders[folder.accountID], let i = list.firstIndex(where: { $0.id == folder.id }) else { return }
        list[i] = folder
        folders[folder.accountID] = list
        try AtomicFile.writeJSON(list, to: layout.foldersFile(folder.accountID))
        emit(.foldersChanged(accountID: folder.accountID))
    }

    /// Changes the stored record as it is now. Anyone who read a copy, awaited something and
    /// then saved that whole copy would put back whatever another caller changed meanwhile,
    /// such as the cursors a sync pass or Load older moved.
    public func updateFolder(_ id: UUID, _ change: (inout FolderInfo) -> Void) throws {
        guard var f = folder(id) else { return }
        let before = f
        change(&f)
        guard f != before else { return }
        try updateFolder(f)
    }

    private func refuseIfFolderListUnread(_ accountID: UUID) throws {
        guard let problem = folderListProblems[accountID] else { return }
        throw FalconError.storage("The folder list could not be read and was kept as \(problem.fileName), so it is not written again.")
    }

    /// The folder's message store, loaded once however many callers ask at the same moment: two
    /// stores on one folder would each append to its journal and write over each other.
    public func folderStore(_ folder: FolderInfo) async throws -> FolderStore {
        if let s = folderStores[folder.id] { return s }
        if let loading = folderStoreLoads[folder.id] { return try await loading.value }
        let s = FolderStore(accountID: folder.accountID, folderID: folder.id,
                            directory: layout.folderDirectory(accountID: folder.accountID, folderID: folder.id),
                            name: "\(folder.path) of \(account(folder.accountID)?.email ?? "an account")",
                            names: [folder.path, folder.name])
        let loading = Task { () async throws -> FolderStore in
            try await s.load()
            if await s.snapshotSetAside != nil {
                // The messages it listed are fetched again from the server rather than left
                // missing: with the cursors kept, the next sync would look only for mail newer
                // than them. Done before anyone waiting for this load carries on, so that none
                // of them reads the old cursors.
                try self.updateFolder(folder.id) { current in
                    current.lastSyncedUID = 0
                    current.oldestSyncedUID = 0
                }
            }
            self.folderStores[folder.id] = s
            return s
        }
        folderStoreLoads[folder.id] = loading
        defer { folderStoreLoads[folder.id] = nil }
        return try await loading.value
    }

    public func messages(in folderID: UUID) async throws -> [MessageSummary] {
        guard let f = folder(folderID) else { return [] }
        let s = try await folderStore(f)
        return await s.all().sorted { $0.date > $1.date }
    }

    /// The newest `limit` messages in a folder. Use this for anything the reader looks at:
    /// pulling an entire folder into memory stalls the interface once a mailbox grows large.
    public func messages(in folderID: UUID, limit: Int, scope: MessageScope = .all) async throws -> [MessageSummary] {
        guard let f = folder(folderID) else { return [] }
        return await (try await folderStore(f)).newest(limit, scope: scope)
    }

    public func storedCount(in folderID: UUID, scope: MessageScope = .all) async throws -> Int {
        guard let f = folder(folderID) else { return 0 }
        return await (try await folderStore(f)).matchCount(scope)
    }

    public func unifiedInbox() async throws -> [MessageSummary] {
        var out: [MessageSummary] = []
        for a in accounts {
            if let inbox = folder(accountID: a.id, role: .inbox) {
                out.append(contentsOf: try await messages(in: inbox.id))
            }
        }
        return out.sorted { $0.date > $1.date }
    }

    public func unifiedInbox(limit: Int, scope: MessageScope = .all) async throws -> [MessageSummary] {
        var out: [MessageSummary] = []
        for a in accounts {
            guard let inbox = folder(accountID: a.id, role: .inbox) else { continue }
            out.append(contentsOf: try await messages(in: inbox.id, limit: limit, scope: scope))
        }
        guard out.count > limit else { return out.sorted { $0.date > $1.date } }
        return Array(out.sorted { $0.date > $1.date }.prefix(limit))
    }

    public func unifiedCount(scope: MessageScope = .all) async throws -> Int {
        var total = 0
        for a in accounts {
            guard let inbox = folder(accountID: a.id, role: .inbox) else { continue }
            total += try await storedCount(in: inbox.id, scope: scope)
        }
        return total
    }

    public func message(id: String) async throws -> MessageSummary? {
        let parts = id.split(separator: ":").map(String.init)
        guard parts.count == 3, let folderID = UUID(uuidString: parts[1]), let uid = UInt32(parts[2]), let f = folder(folderID) else { return nil }
        return try await folderStore(f).message(uid: uid)
    }

    /// The row `read` was read from, as the store holds it now, or nil when its UID no longer
    /// names that message: the folder was renumbered or the message removed since, and the row
    /// now at that UID, if any, is another message that nothing done for `read` may touch.
    public func currentRow(of read: MessageSummary) async -> MessageSummary? {
        guard let f = folder(read.folderID), let fs = try? await folderStore(f) else { return nil }
        return await fs.current([read]).isEmpty ? nil : await fs.message(uid: read.uid)
    }

    /// Stored copies of messages in one account, by Message-ID, so a hit from a server search
    /// can be shown as the row the reader already has. A folder that cannot be loaded is skipped.
    public func storedMessages(withMessageIDs ids: Set<String>, accountID: UUID) async -> [String: [MessageSummary]] {
        guard !ids.isEmpty else { return [:] }
        var out: [String: [MessageSummary]] = [:]
        for f in folders(for: accountID) where f.isSelectable {
            guard let fs = try? await folderStore(f) else { continue }
            for m in await fs.messages(withMessageIDs: ids) { out[m.messageID, default: []].append(m) }
        }
        return out
    }

    public func notifyMessagesChanged(folderID: UUID) {
        emit(.messagesChanged(folderID: folderID))
    }

    public func notifyContactsChanged() {
        emit(.contactsChanged)
    }

    public func refreshCounts(folderID: UUID) async throws {
        guard let f = folder(folderID) else { return }
        let store = try await folderStore(f)
        let total = await store.count
        let unread = await store.unreadCount()
        try updateFolder(folderID) { current in
            current.totalCount = total
            current.unreadCount = unread
        }
    }

    public func cacheSizeBytes() async -> Int {
        var total = 0
        for f in allFolders() {
            if let s = try? await folderStore(f) { total += await s.bodyCacheSize() }
        }
        return total
    }

    public func clearBodyCache() async {
        for f in allFolders() {
            if let s = try? await folderStore(f) { try? await s.clearBodies() }
            emit(.messagesChanged(folderID: f.id))
        }
    }

    public func flushAll() async {
        for s in folderStores.values { try? await s.flush() }
    }

    public func search(_ query: String, accountID: UUID?) async throws -> [MessageSummary] {
        let q = query.lowercased().trimmed
        guard !q.isEmpty else { return [] }
        let tokens = ArchiveTerms.tokenize(q)
        var out: [MessageSummary] = []
        for a in accounts where accountID == nil || a.id == accountID {
            for f in folders(for: a.id) where f.isSelectable && f.role != .all {
                let fs = try await folderStore(f)
                if tokens.isEmpty {
                    let all = await fs.all()
                    out.append(contentsOf: all.filter { $0.subject.lowercased().contains(q) || $0.from.address.lowercased().contains(q) })
                } else {
                    for uid in await fs.search(tokens: tokens) {
                        if let m = await fs.message(uid: uid) { out.append(m) }
                    }
                }
            }
        }
        return out.sorted { $0.date > $1.date }
    }
}
