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
    /// The selection is being read, from Gmail if need be, for the reading pane. Commands on the
    /// selection wait for it (`whenRead`), so they act on the rows the table shows selected.
    var isReading: Bool { reads.isReading }
    let reads = ListSelectionReads()

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var shownView: ListView?
    @ObservationIgnored private var shownSource: ObjectIdentifier?
    /// What was last handed to the app, so a change the app makes itself can be told apart.
    @ObservationIgnored private(set) var handedIDs: Set<String> = []
    /// Runs when the app emptied its selection while rows stayed selected in the table: unless the
    /// rows leave the list meanwhile, as after Delete, the table's selection is read again.
    @ObservationIgnored private var emptiedWait: Task<Void, Never>?
    @ObservationIgnored private var listedCheck: Task<Void, Never>?
    @ObservationIgnored private let waiting = WaitingListSource()
    /// False only in the offscreen snapshots, which run no engine to ask.
    @ObservationIgnored private var asksEngines = true
    /// The view each message window was opened from, by the window's message id, which its
    /// commands' folder rules are read from.
    @ObservationIgnored private var windowViews: [String: ListView] = [:]
    /// How often the message waiting to be revealed was looked for, and not found, in the same
    /// view listed in full.
    @ObservationIgnored private var revealMisses: (key: RowKey?, view: ListView?, count: Int) = (nil, nil, 0)
    /// Tries in one view listed in full before a message waiting to be revealed is given up.
    static let revealTries = 3

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
        if shownView == view, shownSource == id {
            revealPending()
            return true
        }
        shownView = view
        shownSource = id
        await controller.show(view, from: source)
        noteFolderShown(view, model: model)
        checkEveryFolderListed()
        if !revealPending() { readSelection(byOwner: false) }
        return true
    }

    /// Selects the row of the message a notification's click asked to show, or the one selected
    /// at the last quit, once the table shows it. False while there is none, or its row is not in
    /// the list shown yet, when it is tried again as the list changes.
    ///
    /// A message a view listed in full still does not show after three tries is given up, as one
    /// deleted on another device overnight: nothing keeps looking for it on every change of the
    /// list.
    @discardableResult
    func revealPending() -> Bool {
        guard isShown, let model, let key = model.pendingReveal, controller.view != nil else { return false }
        guard let row = row(of: key) else {
            if controller.snapshot.complete, let view = controller.view {
                let misses = revealMisses.key == key && revealMisses.view == view ? revealMisses.count + 1 : 1
                revealMisses = (key, view, misses)
                if misses >= EngineList.revealTries {
                    model.pendingReveal = nil
                    revealMisses = (nil, nil, 0)
                }
            }
            return false
        }
        model.pendingReveal = nil
        revealMisses = (nil, nil, 0)
        emptiedWait?.cancel()
        controller.select(rows: [row])
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
        reads.stop()
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
        guard let model, asksEngines else { return }
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

    /// The owner changed the selection in the table, which a message still waiting to be shown
    /// no longer takes over.
    func tableSelectionChanged() {
        emptiedWait?.cancel()
        model?.pendingReveal = nil
        readSelection(byOwner: true)
    }

    /// Reads the table's selection into the app's. A conversation's row the owner selects alone
    /// opens out, as Settings → Reading asks.
    ///
    /// The reading pane switches to the rows now selected at once, showing what their rows say
    /// (`reads.placeholder`) until their messages are read, and never waits for the read of an
    /// earlier selection; a read that ends after a newer one began is thrown away. Commands on the
    /// selection wait for the read (see `whenRead`), so they act on the rows shown selected.
    private func readSelection(byOwner: Bool) {
        guard let model, let view = controller.view else {
            if reads.isReading { reads.handOverAtOnce(reads.shownTargets) }
            return
        }
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
        let targets = rows.map(\.target)
        // The pane leaves the rows it showed at once: a read-after-delay of theirs is not due.
        if targets != reads.shownTargets { model.cancelPendingRead() }
        // One row is read in full for the reading pane, from Gmail if need be. Several rows are
        // read from what the Mac knows, the index and the rows' text, never fetched: selecting a
        // thousand rows to delete them must not cost a thousand calls.
        let fetching = rows.count == 1
        reads.start(targets, placeholder: ListReadingPlaceholder.of(targets, content: content)) { [weak self] generation in
            var threads: [MessageThread] = []
            var ids: [String] = []
            for row in rows {
                guard !Task.isCancelled else { return }
                if let (thread, id) = await EngineList.thread(for: row, view: view, model: model, content: content, fetching: fetching) {
                    if !threads.contains(where: { $0.id == thread.id }) { threads.append(thread) }
                    ids.append(id)
                }
            }
            guard let self, self.reads.isCurrent(generation) else { return }
            if self.controller.selection != selection {
                // The rows moved meanwhile, as when mail arrived above them: still the same
                // messages, handed over as read. Other messages are read again, so that nothing
                // waiting on the read is left acting on these.
                let now = self.controller.snapshot.selectedRows(self.controller.selection)
                guard SelectedListRow.standForTheSameMessages(now, rows) else {
                    self.readSelection(byOwner: false)
                    return
                }
            }
            self.handOver(threads, ids: ids, generation: generation)
        }
    }

    /// Hands the messages read over to the app, and the reading pane shows them. A read overtaken
    /// by a newer one (`generation` no longer current) hands nothing over.
    private func handOver(_ threads: [MessageThread], ids: [String], generation: Int? = nil) {
        if let generation {
            guard reads.isCurrent(generation) else { return }
        }
        handedIDs = Set(ids)
        model?.adoptTableSelection(threads, ids: ids)
        // After the app holds them, so the commands that waited act on these messages.
        if let generation {
            reads.handOver(generation)
        } else {
            reads.handOverAtOnce([])
        }
    }

    /// Try Again in the reading pane, after the rows selected could not be read in time.
    func retryRead() {
        readSelection(byOwner: false)
    }

    /// What the reading pane shows while the rows just selected are read; nil once they are.
    var readingPlaceholder: ListReadingPlaceholder? { isShown ? reads.placeholder : nil }

    /// Runs a command on the selection once the rows the table shows selected have been read
    /// into the app's selection: at once when they have, and otherwise once the read is handed
    /// over, so that Delete pressed just after moving to the next row deletes that row, never the
    /// one selected before. After the read ran past its deadline the command is not run, and the
    /// status line says why.
    func whenRead(_ body: @escaping @MainActor () -> Void) {
        guard isShown else { return body() }
        if !reads.whenRead(body) {
            model?.statusText = ListStatusText.selectionStillReading
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
        // A message line's tag asks for the line, any other id for its own row; each is found in
        // one pass over the rows for all of them.
        var lines: [RowKey] = []
        var own: [RowKey] = []
        for id in ids {
            if let child = ListRow.childMessageID(id) {
                if let key = RowKey(string: child) { lines.append(key) }
            } else if let key = RowKey(string: id) {
                own.append(key)
            }
        }
        var rows = IndexSet()
        for row in snapshot.rowIndexes(of: lines, line: true).values { rows.insert(row) }
        for row in snapshot.rowIndexes(of: own, line: false).values { rows.insert(row) }
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
            if !diff.inserted.isEmpty || !diff.removed.isEmpty {
                checkEveryFolderListed()
                revealPending()
            }
        case .reload:
            if !revealPending() { readSelection(byOwner: false) }
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

    /// The view a message window or tab was opened from, which its folder rules are read in.
    func openedView(for id: String) -> ListView? { windowViews[id] }

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
    /// is one of them, then every row in one pass over their numbers.
    func row(of key: RowKey) -> Int? {
        let snapshot = controller.snapshot
        if case .rows(let chosen) = controller.selection.form, chosen.count <= ActionTargets.largestItemList,
           let row = chosen.first(where: { snapshot.rowKey(at: $0) == key }) {
            return row
        }
        return snapshot.row(of: key)
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
    static func thread(for row: SelectedListRow, view: ListView, model: AppModel, content: RowContentStore,
                       fetching: Bool = true) async -> (MessageThread, String)? {
        switch row.kind {
        case .message:
            guard let message = await summary(row.key, view: view, model: model, content: content, fetching: fetching) else { return nil }
            return (MessageThread(messages: [message]), message.id)
        case .conversation:
            let messages = await members(of: row.key, view: view, model: model, content: content, fetching: fetching)
            guard !messages.isEmpty else { return nil }
            let thread = MessageThread(messages: messages)
            return (thread, thread.id)
        case .member(let parent):
            let messages = await members(of: parent, view: view, model: model, content: content, fetching: fetching)
            if let message = messages.first(where: { $0.id == row.key.stringValue }) {
                return (MessageThread(messages: messages), ListRow.childTag(message.id))
            }
            // A message of the conversation filed in another folder, such as the owner's reply in
            // Sent: shown and acted on alone.
            guard let message = await summary(row.key, view: view, model: model, content: content, fetching: fetching) else { return nil }
            return (MessageThread(messages: [message]), ListRow.childTag(message.id))
        }
    }

    /// A conversation's messages in the view, newest first: from the index for a Google account,
    /// whose row knows only its newest; from its row's text for stored rows, which lists them all.
    static func members(of key: RowKey, view: ListView, model: AppModel, content: RowContentStore,
                        fetching: Bool = true) async -> [MessageSummary] {
        var keys: [RowKey] = []
        var index: GmailIndexSnapshot?
        if case .gmail(let account, let id) = key, let engine = model.engine(for: account) {
            index = await engine.index()
            // Worked out by the engine, off the main thread, from its conversations' own slots.
            let folderID: UUID??
            switch view.scope {
            case .folder(let folder): folderID = .some(folder)
            case .allInboxes: folderID = .some(nil)
            case .search: folderID = nil
            }
            if let folderID, let members = await engine.conversationMembers(of: id, folderID: folderID) {
                keys = members.map { .gmail(account: account, id: $0) }
            }
        } else if let members = content.peek(key)?.conversation?.members, !members.isEmpty {
            keys = members.map(\.key).reversed()
        }
        if !keys.contains(key) { keys.insert(key, at: 0) }
        var found: [Int: MessageSummary] = [:]
        if !fetching, let index {
            for (i, member) in keys.enumerated() {
                found[i] = indexSummary(member, index: index, content: content, view: view, model: model)
            }
        } else {
            await withTaskGroup(of: (Int, MessageSummary?).self) { group in
                for (i, member) in keys.enumerated() {
                    group.addTask { @MainActor in
                        (i, await summary(member, view: view, model: model, content: content, standIn: member == key, fetching: fetching))
                    }
                }
                for await (i, message) in group { if let message { found[i] = message } }
            }
        }
        let messages = keys.indices.compactMap { found[$0] }
        // The index gives a Google conversation newest first already, by when Gmail received each
        // message, whatever its Date says; stored rows go by their dates.
        if index != nil { return messages }
        return messages.sorted { ($0.internalDate ?? $0.date) > ($1.internalDate ?? $1.date) }
    }

    /// What the app knows of the message `key` names. Offline, or while Gmail asks FalconMail to
    /// wait, a message not on the Mac is still shown by what its row says, so the reading pane can
    /// say it opens once back online; nil when it is gone.
    static func summary(_ key: RowKey, view: ListView, model: AppModel, content: RowContentStore,
                        standIn: Bool = true, fetching: Bool = true) async -> MessageSummary? {
        if !fetching, case .gmail(let account, _) = key, let engine = model.engine(for: account) {
            return indexSummary(key, index: await engine.index(), content: content, view: view, model: model)
        }
        switch await model.summary(for: key, in: view) {
        case .available(let message): return message
        case .gone: return nil
        case .unavailable:
            guard standIn, let row = content.peek(key), let accountID = key.accountID else { return nil }
            return standInSummary(key, row: row, accountID: accountID, view: view, model: model)
        }
    }

    /// A Google message as the Mac knows it without asking Gmail: its read state, flag, labels and
    /// conversation from the index, and who sent it, its subject and date from its row when known.
    /// Enough for every command on a selection of several rows; nil when it is not in the index.
    static func indexSummary(_ key: RowKey, index: GmailIndexSnapshot, content: RowContentStore, view: ListView,
                             model: AppModel) -> MessageSummary? {
        guard case .gmail(let accountID, let id) = key, let slot = index.slotByID[id.raw] else { return nil }
        let record = index.records[Int(slot)]
        guard !record.attributes.contains(.tombstone) else { return nil }
        let labels = index.labels(atSlot: slot)
        let row = content.peek(key)
        var flags = MessageFlags()
        if !labels.contains(.unread) { flags.insert(.seen) }
        if labels.contains(.starred) { flags.insert(.flagged) }
        if labels.contains(.draft) { flags.insert(.draft) }
        var message = MessageSummary(accountID: accountID, folderID: folderID(for: labels, accountID: accountID, view: view, model: model),
                                     uid: 0, messageID: "", inReplyTo: "", references: [], subject: row?.subject ?? "",
                                     from: row?.from ?? EmailAddress(address: ""), to: row?.to ?? [], cc: [],
                                     date: row?.date ?? .distantPast, flags: flags, size: row?.size ?? 0, snippet: row?.preview ?? "",
                                     hasAttachments: row?.hasAttachments ?? record.attributes.contains(.hasAttachment),
                                     threadKey: record.gmailThreadID.threadKey)
        message.id = key.stringValue
        message.gmailID = id
        message.gmailThreadID = record.gmailThreadID
        message.labelIDs = labels.sorted()
        return message
    }

    /// The folder a Google message is seen in: the view's own folder, or, in All Inboxes and a
    /// search, the one its labels name first.
    private static func folderID(for labels: Set<GmailLabelID>, accountID: UUID, view: ListView, model: AppModel) -> UUID {
        if case .folder(let id) = view.scope { return id }
        let folders = model.folders[accountID] ?? []
        for label in [GmailLabelID.inbox, .draft, .sent, .trash, .spam] where labels.contains(label) {
            if let folder = folders.first(where: { $0.gmailLabelID == label }) { return folder.id }
        }
        return folders.first(where: { $0.role == .all })?.id ?? folders.first?.id ?? UUID()
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

#if DEBUG
extension EngineList {
    /// For the offscreen snapshots, which run no engine: shows `view` from `source` as an engine's
    /// list would be shown.
    func snapshotShow(_ view: ListView, from source: any ListSource, model: AppModel, everyFolderListed: Bool) async {
        self.model = model
        asksEngines = false
        isShown = true
        waitingFor = nil
        await controller.show(view, from: source)
        snapshotEveryFolderListed(everyFolderListed)
    }

    func snapshotEveryFolderListed(_ listed: Bool) {
        everyFolderListed = listed
        controller.everyFolderListed = listed
    }
}
#endif

/// The list's source while a Google account's engine has not started: nothing, until it has.
final class WaitingListSource: ListSource, @unchecked Sendable {
    func snapshot(of view: ListView) async -> ListSnapshot { .empty(view) }
    func changes(of view: ListView) -> AsyncStream<ListDiff> { AsyncStream { $0.finish() } }
    func requestRows(_ keys: [RowKey], priority: RowPriority) {}
    var rows: AsyncStream<[RowKey: MessageRowContent]> { AsyncStream { $0.finish() } }
    func summary(for key: RowKey, in view: ListView) async -> RowAvailability { .unavailable(reason: "") }
}
