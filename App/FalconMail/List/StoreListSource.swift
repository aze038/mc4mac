import Foundation
import FalconCore

/// Today's stored rows, for accounts that are not on the Gmail engine, through the same interface
/// as a Google account's list, so the table, the selection and message windows work one way for
/// every account. A view is the folder's stored rows grouped and sorted by the list's existing
/// code; every row's text is known at once, and a change to the folder's store sends the view
/// again.
actor StoreListSource: ListSourceExtras {
    private let store: MailStore
    private nonisolated let rowsOut = RowBroadcast<[RowKey: MessageRowContent]>()
    private var messages: [String: MessageSummary] = [:]
    private var threads: [String: [MessageSummary]] = [:]
    private var expanded: [ListView.Scope: Set<String>] = [:]
    private var listening: Task<Void, Never>?
    /// The accounts on the Gmail engine, whose rows this source leaves to it.
    private var engineAccounts: Set<UUID> = []
    private weak var mergedIndex: ListIndex?

    private nonisolated let watchers = ListWatchers()
    /// What each watched view's watchers were last sent, which the next change is worked out from.
    private var sent: [ListView: ListSnapshot] = [:]

    init(store: MailStore) {
        self.store = store
    }

    nonisolated var rows: AsyncStream<[RowKey: MessageRowContent]> { rowsOut.subscribe() }

    /// Leaves these accounts' rows to the Gmail engine, and gives the index the other accounts'
    /// Inbox rows for All Inboxes, again each time they change.
    func share(with index: ListIndex, engineAccounts: Set<UUID>) async {
        self.engineAccounts = engineAccounts
        mergedIndex = index
        startListening()
        await index.setStoredInboxRows(await inboxRows())
    }

    // MARK: - ListSource

    func snapshot(of view: ListView) async -> ListSnapshot {
        let snapshot = await read(view)
        // What the caller now shows is what the next change is worked out from.
        if watchers.isWatched(view) { sent[view] = snapshot }
        return snapshot
    }

    private func read(_ view: ListView) async -> ListSnapshot {
        startListening()
        let loaded: [MessageSummary]
        do {
            switch view.scope {
            case .folder(let id):
                loaded = try await store.messages(in: id)
            case .allInboxes:
                loaded = try await store.unifiedInbox().filter { !engineAccounts.contains($0.accountID) }
            case .search:
                loaded = []
            }
        } catch {
            Log.info("list", "stored rows could not be read: \(error.localizedDescription)")
            loaded = []
        }
        return await build(view, from: loaded)
    }

    nonisolated func changes(of view: ListView) -> AsyncStream<ListDiff> {
        watchers.diffStream(for: view)
    }

    nonisolated func footers(of view: ListView) -> AsyncStream<[ListFooter]> {
        // Stored rows are all on the Mac, so nothing ever waits and nothing is hidden.
        let (stream, continuation) = AsyncStream.makeStream(of: [ListFooter].self)
        continuation.yield([])
        return stream
    }

    nonisolated func requestRows(_ keys: [RowKey], priority: RowPriority) {
        Task { await self.answer(keys) }
    }

    func summary(for key: RowKey, in view: ListView) async -> RowAvailability {
        guard case .stored(let id) = key, let message = try? await store.message(id: id) else { return .gone }
        return .available(message)
    }

    func setExpanded(_ keys: Set<RowKey>, in view: ListView) async {
        var ids = Set<String>()
        for key in keys {
            guard case .stored(let id) = key else { continue }
            // Any message of the conversation names it, by its thread's newest.
            let thread = threads.first { $0.value.contains { $0.id == id } }?.key ?? id
            ids.insert(thread)
        }
        expanded[view.scope] = ids
        await rebuild { $0.scope == view.scope }
    }

    // MARK: - Building a view

    private func build(_ view: ListView, from loaded: [MessageSummary]) async -> ListSnapshot {
        var shown = loaded
        if view.filters.contains(.unread) || view.filters.contains(.flagged) || view.filters.contains(.attachments) {
            shown = shown.filter { m in
                (!view.filters.contains(.unread) || !m.isRead) && (!view.filters.contains(.flagged) || m.isFlagged)
                    && (!view.filters.contains(.attachments) || m.hasAttachments)
            }
        }
        let grouped: [MessageThread] = view.conversations
            ? ConversationThreader.group(shown).map { MessageThread(messages: $0) }
            : shown.map { MessageThread(messages: [$0]) }
        var names: [UUID: String] = [:]
        var folderNames: [UUID: String] = [:]
        for account in await store.allAccounts() { names[account.id] = account.email }
        for folder in await store.allFolders() { folderNames[folder.id] = folder.name }
        let sort = ListSort(rawValue: view.sort.key.rawValue) ?? .date
        let sorted = sort.apply(grouped, ascending: view.sort.ascending, names: { names[$0] ?? "Account" },
                                folders: { folderNames[$0] ?? "Folder" })

        var rows = ContiguousArray<DisplayRecord>()
        rows.reserveCapacity(sorted.count)
        var keys: [String] = []
        var sources: [UUID] = []
        var sourceOf: [UUID: UInt8] = [:]
        var headers: [Int: String] = [:]
        var groupOf: [String: UInt16] = [:]
        var lastGroup: String?
        let opened = expanded[view.scope] ?? []
        for thread in sorted {
            let latest = thread.latest
            let source: UInt8 = sourceOf[latest.accountID] ?? {
                sources.append(latest.accountID)
                let made = UInt8(truncatingIfNeeded: sources.count - 1)
                sourceOf[latest.accountID] = made
                return made
            }()
            var group: UInt16 = 0
            if view.dateGroups {
                let title = sort.key(thread, names: { names[$0] ?? "Account" }, folders: { folderNames[$0] ?? "Folder" })
                group = groupOf[title] ?? {
                    let made = UInt16(truncatingIfNeeded: groupOf.count)
                    groupOf[title] = made
                    headers[Int(made)] = title
                    return made
                }()
                if title != lastGroup { rows.append(.header(group: group)) }
                lastGroup = title
            }
            let many = thread.messages.count > 1
            var bits = StoreListSource.bits(of: thread.messages)
            if many, opened.contains(latest.id) { bits.insert(.expanded) }
            let slot = Int32(keys.count)
            keys.append(latest.id)
            rows.append(DisplayRecord(key: UInt64(slot), slot: slot, bits: bits,
                                      members: UInt16(clamping: thread.messages.count), unread: UInt16(clamping: thread.unreadCount),
                                      group: group, kind: many ? .conversation : .message, source: source))
            if many, opened.contains(latest.id) {
                for message in thread.messages {
                    let childSlot = Int32(keys.count)
                    keys.append(message.id)
                    rows.append(DisplayRecord(key: UInt64(childSlot), slot: childSlot, bits: StoreListSource.bits(of: [message]),
                                              unread: message.isRead ? 0 : 1, group: group, kind: .child, source: source))
                }
            }
        }
        for thread in sorted {
            threads[thread.latest.id] = thread.messages
            for message in thread.messages { messages[message.id] = message }
        }
        return ListSnapshot(view: view, rows: rows, headers: headers, complete: true, itemCount: shown.count, sources: sources,
                            storedKeys: keys)
    }

    static func bits(of messages: [MessageSummary]) -> DisplayBits {
        var bits: DisplayBits = [.storedRow, .attachmentKnown]
        if messages.contains(where: { !$0.isRead }) { bits.insert(.unread) }
        if messages.contains(where: \.isFlagged) { bits.insert(.flagged) }
        if messages.contains(where: \.hasAttachments) { bits.insert(.hasAttachment) }
        if messages.contains(where: \.isDraft) { bits.insert(.draft) }
        return bits
    }

    /// Every row's text is on the Mac, so a request is answered at once.
    private func answer(_ keys: [RowKey]) {
        var out: [RowKey: MessageRowContent] = [:]
        for key in keys {
            guard case .stored(let id) = key, let message = messages[id] else { continue }
            var content = MessageRowContent(key: key, from: message.from, to: message.to, subject: message.subject,
                                            preview: message.snippet, date: message.date, size: message.size,
                                            hasAttachments: message.hasAttachments)
            if let members = threads[id], members.count > 1 {
                let oldestFirst = members.reversed()
                content.conversation = ConversationContent(
                    senders: oldestFirst.map(\.from), messageCount: members.count, newestDate: members[0].date,
                    members: oldestFirst.map { ConversationMember(key: .stored($0.id), from: $0.from, date: $0.date) })
            }
            out[key] = content
        }
        if !out.isEmpty { rowsOut.send(out) }
    }

    /// Inbox rows of accounts not on the engine, grouped as conversations, for All Inboxes.
    private func inboxRows() async -> [ListStoredRow] {
        let inbox = ((try? await store.unifiedInbox()) ?? []).filter { !engineAccounts.contains($0.accountID) }
        return ConversationThreader.group(inbox).map { members in
            let latest = members[0]
            return ListStoredRow(key: latest.id, accountID: latest.accountID, date: latest.date, bits: StoreListSource.bits(of: members),
                                 members: UInt16(clamping: members.count), unread: UInt16(clamping: members.filter { !$0.isRead }.count),
                                 kind: members.count > 1 ? .conversation : .message,
                                 facts: ListRowFacts(date: latest.date, from: latest.from.displayName,
                                                     to: latest.to.first?.displayName ?? "", subject: latest.subject),
                                 children: members.map { ListStoredChild(key: $0.id, bits: StoreListSource.bits(of: [$0])) })
        }
    }

    // MARK: - Watching

    private func startListening() {
        guard listening == nil else { return }
        let changes = Task { await store.changes() }
        listening = Task { [weak self] in
            for await change in await changes.value {
                guard let self else { return }
                if case .messagesChanged(let folderID) = change { await self.changed(folderID) }
            }
        }
    }

    private func changed(_ folderID: UUID) async {
        let isInbox = await store.folder(folderID)?.role == .inbox
        await rebuild { view in
            switch view.scope {
            case .folder(let id): return id == folderID
            case .allInboxes: return isInbox
            case .search: return false
            }
        }
        if isInbox, let index = mergedIndex { await index.setStoredInboxRows(await inboxRows()) }
    }

    private func rebuild(_ affected: (ListView) -> Bool) async {
        for view in watchers.diffViews where affected(view) {
            let new = await read(view)
            defer { sent[view] = new }
            guard let old = sent[view] else { continue }
            let diff = ListDiffer.diff(from: old, to: new)
            guard !diff.inserted.isEmpty || !diff.removed.isEmpty || !diff.reloaded.isEmpty || old.itemCount != new.itemCount else { continue }
            watchers.send(diff, for: view)
        }
        for view in sent.keys where !watchers.isWatched(view) { sent[view] = nil }
    }
}
