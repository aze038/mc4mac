import Foundation

public enum StoreChange: Sendable {
    case accountsChanged
    case foldersChanged(accountID: UUID)
    case messagesChanged(folderID: UUID)
    case contactsChanged
}

public actor MailStore {
    public let layout: FileLayout
    private var accounts: [AccountInfo] = []
    private var folders: [UUID: [FolderInfo]] = [:]
    private var folderStores: [UUID: FolderStore] = [:]
    private var changeContinuations: [UUID: AsyncStream<StoreChange>.Continuation] = [:]

    public init(layout: FileLayout = FileLayout()) {
        self.layout = layout
    }

    public func load() throws {
        try layout.ensureDirectory(layout.root)
        accounts = AtomicFile.readJSON([AccountInfo].self, from: layout.accountsFile) ?? []
        for a in accounts {
            folders[a.id] = AtomicFile.readJSON([FolderInfo].self, from: layout.foldersFile(a.id)) ?? []
        }
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

    public func saveAccount(_ account: AccountInfo) throws {
        if let i = accounts.firstIndex(where: { $0.id == account.id }) { accounts[i] = account } else { accounts.append(account) }
        try AtomicFile.writeJSON(accounts, to: layout.accountsFile)
        if folders[account.id] == nil { folders[account.id] = [] }
        emit(.accountsChanged)
    }

    public func removeAccount(_ id: UUID) throws {
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

    public func reconcileFolders(accountID: UUID, listed: [IMAPFolderInfo]) throws -> [FolderInfo] {
        var existing = folders[accountID] ?? []
        var result: [FolderInfo] = []
        for l in listed {
            if var f = existing.first(where: { $0.path == l.path }) {
                f.name = l.displayName
                f.attributes = l.attributes
                f.role = l.role
                f.isSelectable = l.isSelectable
                f.delimiter = l.delimiter
                result.append(f)
                existing.removeAll { $0.id == f.id }
            } else {
                result.append(FolderInfo(accountID: accountID, path: l.path, name: l.displayName, delimiter: l.delimiter,
                                         role: l.role, attributes: l.attributes, isSelectable: l.isSelectable))
            }
        }
        for gone in existing {
            folderStores[gone.id] = nil
            try? FileManager.default.removeItem(at: layout.folderDirectory(accountID: accountID, folderID: gone.id))
        }
        folders[accountID] = result
        try AtomicFile.writeJSON(result, to: layout.foldersFile(accountID))
        emit(.foldersChanged(accountID: accountID))
        return folders(for: accountID)
    }

    public func updateFolder(_ folder: FolderInfo) throws {
        guard var list = folders[folder.accountID], let i = list.firstIndex(where: { $0.id == folder.id }) else { return }
        list[i] = folder
        folders[folder.accountID] = list
        try AtomicFile.writeJSON(list, to: layout.foldersFile(folder.accountID))
        emit(.foldersChanged(accountID: folder.accountID))
    }

    public func folderStore(_ folder: FolderInfo) async throws -> FolderStore {
        if let s = folderStores[folder.id] { return s }
        let s = FolderStore(accountID: folder.accountID, folderID: folder.id,
                            directory: layout.folderDirectory(accountID: folder.accountID, folderID: folder.id))
        try await s.load()
        folderStores[folder.id] = s
        return s
    }

    public func messages(in folderID: UUID) async throws -> [MessageSummary] {
        guard let f = folder(folderID) else { return [] }
        let s = try await folderStore(f)
        return await s.all().sorted { $0.date > $1.date }
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

    public func message(id: String) async throws -> MessageSummary? {
        let parts = id.split(separator: ":").map(String.init)
        guard parts.count == 3, let folderID = UUID(uuidString: parts[1]), let uid = UInt32(parts[2]), let f = folder(folderID) else { return nil }
        return try await folderStore(f).message(uid: uid)
    }

    public func notifyMessagesChanged(folderID: UUID) {
        emit(.messagesChanged(folderID: folderID))
    }

    public func notifyContactsChanged() {
        emit(.contactsChanged)
    }

    public func refreshCounts(folderID: UUID) async throws {
        guard var f = folder(folderID) else { return }
        let all = try await folderStore(f).all()
        f.totalCount = all.count
        f.unreadCount = all.filter { !$0.isRead }.count
        try updateFolder(f)
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
