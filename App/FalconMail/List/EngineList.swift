import AppKit
import SwiftUI
import FalconCore

/// The message table in the mailbox window: whether it shows the list, and what its selection
/// means to the rest of the app.
///
/// The table shows every folder of a Google account on the Gmail API, and All Inboxes, the smart
/// folders and a search once any account is on it; the stored rows of accounts on IMAP keep the
/// list they have always had. What is selected in the table is read into the messages the reading
/// pane, the ribbon, the menus, the keys and reading by mail already work on, the app's
/// `threads` and `selectedMessageIDs`, so each of them works the same for a row of the table as
/// for a stored one:
/// - a lone message's row stands for that message;
/// - a conversation's row stands for its messages in the folder, newest first, stacked in the
///   reading pane with the newest open, and reading it marks only the newest read;
/// - a message line of an opened conversation stands for that message alone, and reading it marks
///   only that message read.
///
/// Up to 1,000 selected rows are read this way; above that nothing is handed on as a part of the
/// selection, and the commands that can act on a whole view take `targets(for:)` instead.
@MainActor
@Observable
final class EngineList {
    let controller = ListController()
    /// Whether the table shows the list now.
    private(set) var isShown = false
    /// Set while a Google account's engine has not started yet, which nothing is shown of in the
    /// meantime: its old IMAP copy is kept only for going back to an earlier FalconMail.
    private(set) var waitingFor: String?
    /// How many rows are selected, above 1,000 too.
    var selectionCount: Int { controller.selectionCount }
    /// Every folder the sidebar shows for the accounts on the Gmail API has been listed in full.
    private(set) var everyFolderListed = true

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var shownView: ListView?
    @ObservationIgnored private var shownSource: ObjectIdentifier?
    @ObservationIgnored private var resolving: Task<Void, Never>?
    /// What was last handed to the app, so a change the app makes itself can be told apart.
    @ObservationIgnored private(set) var handedIDs: Set<String> = []
    /// Runs when the app emptied its selection while rows stayed selected in the table: unless the
    /// rows leave the list meanwhile, as after Delete, the table's selection is read again.
    @ObservationIgnored private var emptiedWait: Task<Void, Never>?
    @ObservationIgnored private var listedCheck: Task<Void, Never>?
    @ObservationIgnored private let waiting = WaitingListSource()
    /// The view each message window was opened from, by the window's message id, which its
    /// commands' folder rules are read from.
    @ObservationIgnored private var windowViews: [String: ListView] = [:]

    init() {
        controller.onApplied = { [weak self] change, before in self?.applied(change, selectedBefore: before) }
    }

    // MARK: - Showing the list

    /// Shows the app's sidebar selection in the table when the table shows it, and says whether it
    /// does. The app's own list takes over when it does not.
    func reload(_ model: AppModel) async -> Bool {
        self.model = model
        guard model.showsInTable(model.selection), let view = model.listView(for: model.selection) else {
            if isShown { hide() }
            return false
        }
        if !isShown { isShown = true }
        guard let source = model.listSource(for: model.selection) else {
            let email = model.tableAccount(for: model.selection).map { model.accountName($0) }
            if waitingFor != email { waitingFor = email ?? "Gmail" }
            shownView = nil
            shownSource = nil
            await controller.show(view, from: waiting)
            handOver([], ids: [])
            return true
        }
        if waitingFor != nil { waitingFor = nil }
        let id = ObjectIdentifier(source)
        if shownView == view, shownSource == id { return true }
        shownView = view
        shownSource = id
        await controller.show(view, from: source)
        noteFolderShown(view, model: model)
        checkEveryFolderListed()
        readSelection(byOwner: false)
        return true
    }

    /// The same view again once the list's settings change, when the table shows it.
    func refreshIfShown(_ model: AppModel) {
        guard isShown else { return }
        Task { _ = await reload(model) }
    }

    private func hide() {
        isShown = false
        waitingFor = nil
        shownView = nil
        shownSource = nil
        resolving?.cancel()
        emptiedWait?.cancel()
        controller.stop()
        handedIDs = []
    }

    /// The engine lists the folder shown first while it lists the mailbox.
    private func noteFolderShown(_ view: ListView, model: AppModel) {
        guard case .folder(let id) = view.scope, let folder = model.folder(id), let engine = model.engine(for: folder.accountID) else { return }
        let label = folder.gmailLabelID
        Task { await engine.noteSelectedFolder(label) }
    }

    /// Asks each engine whether it has listed everything, for "All folders are up to date.".
    func checkEveryFolderListed() {
        guard let model else { return }
        listedCheck?.cancel()
        let engines = model.gmailEngineAccounts.compactMap { model.engine(for: $0) }
        let waiting = model.gmailEngineAccounts.count != engines.count
        listedCheck = Task { [weak self] in
            var listed = !waiting
            for engine in engines where listed {
                let state = await engine.listingState()
                let labels = await engine.labels()
                listed = ListStatusText.everyFolderListed(allMailComplete: state.allMailComplete, labels: labels)
            }
            guard !Task.isCancelled, let self else { return }
            if self.everyFolderListed != listed { self.everyFolderListed = listed }
            self.controller.everyFolderListed = listed
        }
    }

    // MARK: - The selection

    /// The owner changed the selection in the table.
    func tableSelectionChanged() {
        emptiedWait?.cancel()
        readSelection(byOwner: true)
    }

    /// Reads the table's selection into the app's. A conversation's row the owner selects alone
    /// opens out, as Settings → Reading asks.
    private func readSelection(byOwner: Bool) {
        resolving?.cancel()
        guard let model, let view = controller.view else { return }
        let snapshot = controller.snapshot
        let selection = controller.selection
        guard let rows = snapshot.selectedRows(selection), !rows.isEmpty else {
            handOver([], ids: [])
            return
        }
        if byOwner, rows.count == 1, rows[0].kind == .conversation, !controller.isExpanded(rows[0].row),
           Preferences.bool(Pref.autoExpandConversation, default: true) {
            let row = rows[0].row
            Task { await controller.toggleExpanded(row: row) }
        }
        let content = controller.content
        resolving = Task { [weak self] in
            var threads: [MessageThread] = []
            var ids: [String] = []
            for row in rows {
                guard !Task.isCancelled else { return }
                if let (thread, id) = await EngineList.thread(for: row, view: view, model: model, content: content) {
                    if !threads.contains(where: { $0.id == thread.id }) { threads.append(thread) }
                    ids.append(id)
                }
            }
            guard !Task.isCancelled, let self, self.controller.selection == selection else { return }
            self.handOver(threads, ids: ids)
        }
    }

    private func handOver(_ threads: [MessageThread], ids: [String]) {
        handedIDs = Set(ids)
        model?.adoptTableSelection(threads, ids: ids)
    }

    /// Waits for the selection being read, for a command chosen from the menu of rows just
    /// right-clicked.
    func whenRead(_ body: @escaping @MainActor () -> Void) {
        let pending = resolving
        Task {
            await pending?.value
            body()
        }
    }

    /// The app changed its selection itself: a notification's message revealed, a row chosen by
    /// the keys, or the selection emptied as rows are about to leave the list.
    func appSelectionChanged(_ ids: Set<String>) {
        guard isShown, ids != handedIDs else { return }
        emptiedWait?.cancel()
        if ids.isEmpty {
            guard !controller.selection.isEmpty else { return }
            // Rows about to leave the list: the table keeps them selected, so that the next row
            // is selected once they go. If they stay, as when an action fails, the selection is
            // read again.
            emptiedWait = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.readSelection(byOwner: false)
            }
            return
        }
        let snapshot = controller.snapshot
        var rows = IndexSet()
        for id in ids {
            let keyString = ListRow.childMessageID(id) ?? id
            guard let key = RowKey(string: keyString) else { continue }
            let wantsLine = ListRow.childMessageID(id) != nil
            if let row = snapshot.rows.indices.first(where: { i in
                snapshot.rowKey(at: i) == key && (snapshot.rows[i].displayKind == .child) == wantsLine
            }) ?? snapshot.rows.indices.first(where: { snapshot.rowKey(at: $0) == key }) {
                rows.insert(row)
            }
        }
        guard !rows.isEmpty else { return }
        controller.select(rows: rows)
        readSelection(byOwner: false)
    }

    /// Selects the row of `key`, as a quick action or a swipe that needs a selection does.
    func select(_ key: RowKey) {
        let snapshot = controller.snapshot
        guard let row = row(of: key) else { return }
        if controller.selection.indexes(in: snapshot) != [row] { controller.select(rows: [row]) }
        readSelection(byOwner: false)
    }

    /// What a command acts on, for the commands that can act on a whole view.
    func targets(for command: ListCommand) -> ListTargets { controller.targets(for: command) }

    // MARK: - Changes from the list

    private func applied(_ change: ListControllerChange, selectedBefore: ListSelection) {
        guard isShown else { return }
        switch change {
        case .diff(let diff):
            if case .rows(let selected) = selectedBefore.form, !selected.isEmpty, selected.isSubset(of: diff.removed) {
                advance(from: selected, removed: diff.removed)
            } else if diff.reloaded.contains(where: { controller.selection.contains($0) })
                        || diff.removed.contains(where: { selectedBefore.contains($0) }) {
                // A selected row changed, as when it was read or flagged elsewhere, or some of the
                // selection left: what the reading pane shows is read again. Rows that only moved
                // are the same messages.
                readSelection(byOwner: false)
            }
            if !diff.inserted.isEmpty || !diff.removed.isEmpty { checkEveryFolderListed() }
        case .reload:
            readSelection(byOwner: false)
            checkEveryFolderListed()
        case .selection, .content:
            break
        }
    }

    /// Every selected row left the list, as after Delete or Archive: the next row is selected, or
    /// the one before, or none, as Settings → Reading says.
    private func advance(from selected: IndexSet, removed: IndexSet) {
        emptiedWait?.cancel()
        let policy = AdvanceAfterAction(rawValue: model?.advanceAfterAction ?? "") ?? .next
        guard policy != .list,
              let row = ListAdvance.row(selected: selected, removed: removed, in: controller.snapshot, forward: policy == .next) else {
            handOver([], ids: [])
            return
        }
        controller.select(rows: [row])
        readSelection(byOwner: false)
    }

    // MARK: - Moving by the keys

    enum Move { case next, previous, nextUnread, previousUnread }

    /// J, K, N and P: the next or previous row, or the next or previous with unread mail.
    @discardableResult
    func move(_ move: Move) -> Bool {
        guard isShown else { return false }
        let snapshot = controller.snapshot
        guard !snapshot.rows.isEmpty else { return true }
        let selected = controller.selection.indexes(in: snapshot)
        func unread(_ i: Int) -> Bool {
            let record = snapshot.rows[i]
            return record.displayKind != .header && (record.unread > 0 || record.displayBits.contains(.unread))
        }
        let target: Int?
        switch move {
        case .next:
            target = snapshot.selectableRow(from: (selected.last ?? -1) + 1, forward: true) ?? selected.last
        case .previous:
            target = snapshot.selectableRow(from: (selected.first ?? snapshot.rows.count) - 1, forward: false) ?? selected.first
        case .nextUnread:
            let start = (selected.last ?? -1) + 1
            target = start < snapshot.rows.count ? (start..<snapshot.rows.count).first(where: unread) : nil
            if target == nil { model?.statusText = "No more unread conversations" }
        case .previousUnread:
            let end = selected.first ?? snapshot.rows.count
            target = (0..<end).last(where: unread)
            if target == nil { model?.statusText = "No earlier unread conversations" }
        }
        guard let target else { return true }
        controller.select(rows: [target])
        readSelection(byOwner: true)
        return true
    }

    // MARK: - Opening

    /// The view a message window reads its message in: the one it was opened from, or its
    /// account's Inbox, as for a window opened from a notification or brought back at launch.
    func windowView(for id: String, model: AppModel) -> ListView {
        if let view = windowViews[id] { return view }
        if let account = RowKey(string: id)?.accountID, let inbox = model.folder(accountID: account, role: .inbox) {
            return ListView(scope: .folder(inbox.id))
        }
        return ListView(scope: .allInboxes)
    }

    /// Double-click, Return and Command-O on a row: its message, or its conversation, opens in a
    /// window of its own, or a draft opens to be written.
    func open(_ key: RowKey, openWindow: @escaping (String) -> Void) {
        guard let model, let view = controller.view else { return }
        let snapshot = controller.snapshot
        guard let row = row(of: key), let selected = snapshot.selectedRows(ListSelection(rows: [row]))?.first else { return }
        let content = controller.content
        Task {
            guard let (thread, _) = await EngineList.thread(for: selected, view: view, model: model, content: content) else {
                model.statusText = "This message was moved or deleted on another device."
                return
            }
            if case .member = selected.kind, let message = thread.messages.first(where: { $0.id == key.stringValue }) {
                self.windowViews[message.id] = view
                model.openMessage(message, openWindow: openWindow)
            } else {
                self.windowViews[thread.latest.id] = view
                model.openMessage(thread.latest, conversation: thread, openWindow: openWindow)
            }
        }
    }

    /// The row showing `key`: the selected ones are looked at first, as the row acted on usually
    /// is one of them.
    func row(of key: RowKey) -> Int? {
        let snapshot = controller.snapshot
        let selected = controller.selection.indexes(in: snapshot)
        if selected.count <= ActionTargets.largestItemList, let row = selected.first(where: { snapshot.rowKey(at: $0) == key }) {
            return row
        }
        return snapshot.rows.indices.first { snapshot.rowKey(at: $0) == key }
    }

    /// A row's own messages for its quick actions and its swipe, whatever is selected.
    func thread(forKey key: RowKey) async -> MessageThread? {
        guard let model, let view = controller.view else { return nil }
        let snapshot = controller.snapshot
        guard let row = row(of: key), let selected = snapshot.selectedRows(ListSelection(rows: [row]))?.first else { return nil }
        guard let (thread, _) = await EngineList.thread(for: selected, view: view, model: model, content: controller.content) else {
            return nil
        }
        if case .member = selected.kind, let message = thread.messages.first(where: { $0.id == key.stringValue }) {
            return MessageThread(messages: [message])
        }
        return thread
    }

    // MARK: - Reading rows into messages

    /// The messages a selected row stands for, newest first, and the id the app's selection knows
    /// it by: the conversation's newest message's for its row, the line's tag for a message line.
    static func thread(for row: SelectedListRow, view: ListView, model: AppModel,
                       content: RowContentStore) async -> (MessageThread, String)? {
        switch row.kind {
        case .message:
            guard let message = await summary(row.key, view: view, model: model, content: content) else { return nil }
            return (MessageThread(messages: [message]), message.id)
        case .conversation:
            let messages = await members(of: row.key, view: view, model: model, content: content)
            guard !messages.isEmpty else { return nil }
            let thread = MessageThread(messages: messages)
            return (thread, thread.id)
        case .member(let parent):
            let messages = await members(of: parent, view: view, model: model, content: content)
            if let message = messages.first(where: { $0.id == row.key.stringValue }) {
                return (MessageThread(messages: messages), ListRow.childTag(message.id))
            }
            // A message of the conversation filed in another folder, such as the owner's reply in
            // Sent: shown and acted on alone.
            guard let message = await summary(row.key, view: view, model: model, content: content) else { return nil }
            return (MessageThread(messages: [message]), ListRow.childTag(message.id))
        }
    }

    /// A conversation's messages in the view, newest first: from the index for a Google account,
    /// whose row knows only its newest; from its row's text for stored rows, which lists them all.
    static func members(of key: RowKey, view: ListView, model: AppModel, content: RowContentStore) async -> [MessageSummary] {
        var keys: [RowKey] = []
        if case .gmail(let account, let id) = key, let engine = model.engine(for: account) {
            let index = await engine.index()
            if let record = index.record(for: id) {
                var label: GmailLabelID?
                var known = true
                switch view.scope {
                case .folder(let folderID):
                    label = await engine.labels().first { $0.folderID == folderID }?.id
                case .allInboxes:
                    label = .inbox
                case .search:
                    known = false
                }
                if known {
                    keys = index.conversationMembers(thread: record.threadID, label: label).map { .gmail(account: account, id: $0) }
                }
            }
        } else if let members = content.peek(key)?.conversation?.members, !members.isEmpty {
            keys = members.map(\.key).reversed()
        }
        if !keys.contains(key) { keys.insert(key, at: 0) }
        var found: [Int: MessageSummary] = [:]
        await withTaskGroup(of: (Int, MessageSummary?).self) { group in
            for (i, member) in keys.enumerated() {
                group.addTask { @MainActor in (i, await summary(member, view: view, model: model, content: content, standIn: member == key)) }
            }
            for await (i, message) in group { if let message { found[i] = message } }
        }
        let messages = keys.indices.compactMap { found[$0] }
        return messages.sorted { ($0.internalDate ?? $0.date) > ($1.internalDate ?? $1.date) }
    }

    /// What the app knows of the message `key` names. Offline, or while Gmail asks FalconMail to
    /// wait, a message not on the Mac is still shown by what its row says, so the reading pane can
    /// say it opens once back online; nil when it is gone.
    static func summary(_ key: RowKey, view: ListView, model: AppModel, content: RowContentStore,
                        standIn: Bool = true) async -> MessageSummary? {
        switch await model.summary(for: key, in: view) {
        case .available(let message): return message
        case .gone: return nil
        case .unavailable:
            guard standIn, let row = content.peek(key), let accountID = key.accountID else { return nil }
            return standInSummary(key, row: row, accountID: accountID, view: view, model: model)
        }
    }

    /// A message known only by its row: who sent it, its subject and date.
    static func standInSummary(_ key: RowKey, row: MessageRowContent, accountID: UUID, view: ListView,
                               model: AppModel) -> MessageSummary {
        let folderID: UUID
        if case .folder(let id) = view.scope {
            folderID = id
        } else {
            folderID = model.folder(accountID: accountID, role: .inbox)?.id ?? UUID()
        }
        var message = MessageSummary(accountID: accountID, folderID: folderID, uid: 0, messageID: "", inReplyTo: "", references: [],
                                     subject: row.subject, from: row.from, to: row.to, cc: [], date: row.date, flags: [.seen],
                                     size: row.size ?? 0, snippet: row.preview, hasAttachments: row.hasAttachments ?? false)
        message.id = key.stringValue
        message.gmailID = key.gmailID
        return message
    }
}

/// The list's source while a Google account's engine has not started: nothing, until it has.
final class WaitingListSource: ListSource, @unchecked Sendable {
    func snapshot(of view: ListView) async -> ListSnapshot { .empty(view) }
    func changes(of view: ListView) -> AsyncStream<ListDiff> { AsyncStream { $0.finish() } }
    func requestRows(_ keys: [RowKey], priority: RowPriority) {}
    var rows: AsyncStream<[RowKey: MessageRowContent]> { AsyncStream { $0.finish() } }
    func summary(for key: RowKey, in view: ListView) async -> RowAvailability { .unavailable(reason: "") }
}
