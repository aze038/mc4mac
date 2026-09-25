import Foundation
import XCTest
@testable import FalconCore

/// A clock the tests move by hand. In `instant` mode a wait moves the clock on by itself at once,
/// so seven minutes of bulk work run in a moment; otherwise waits take real time and the clock
/// stands still until a test moves it, so an undo window never ends by itself.
final class ActionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    let instant: Bool

    init(_ start: Date = Date(timeIntervalSince1970: 1_790_000_000), instant: Bool = false) {
        current = start
        self.instant = instant
    }

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }

    var clock: GmailActionClock {
        GmailActionClock(now: { [self] in now }, sleep: { [self] seconds in
            if instant {
                advance(max(0, seconds))
                await Task.yield()
            } else {
                try await Task.sleep(nanoseconds: UInt64(min(max(seconds, 0), 0.05) * 1_000_000_000))
            }
        })
    }
}

/// The engine's part, played for the actions: it journals their changes with its cursor, lists
/// the account's folders, and runs a small check for changes that screens history through the
/// actions as the engine's own check does.
final class ActionsHost: GmailActionsHost, @unchecked Sendable {
    let store: MemoryGmailStore
    let gmail: MemoryGmailTransport
    private let lock = NSLock()
    private var _cursor: HistoryID?
    private var _folders: [FolderInfo] = []
    private var _notices: [String] = []
    private var _relistings = 0
    private var _checks = 0
    private var _commits = 0
    private var _labelReloads = 0
    private var _own: Set<String> = []
    private var _updatesAreOther = false
    private var _viewMessages: [GmailMessageID]?
    weak var actions: GmailActions?

    init(store: MemoryGmailStore, gmail: MemoryGmailTransport) {
        self.store = store
        self.gmail = gmail
    }

    var cursor: HistoryID? {
        get { lock.withLock { _cursor } }
        set { lock.withLock { _cursor = newValue } }
    }
    var folderList: [FolderInfo] {
        get { lock.withLock { _folders } }
        set { lock.withLock { _folders = newValue } }
    }
    var notices: [String] { lock.withLock { _notices } }
    var relistings: Int { lock.withLock { _relistings } }
    var checks: Int { lock.withLock { _checks } }
    var commits: Int { lock.withLock { _commits } }
    var labelReloads: Int { lock.withLock { _labelReloads } }
    var own: Set<String> {
        get { lock.withLock { _own } }
        set { lock.withLock { _own = newValue } }
    }
    var updatesOther: Bool {
        get { lock.withLock { _updatesAreOther } }
        set { lock.withLock { _updatesAreOther = newValue } }
    }
    var viewMessages: [GmailMessageID]? {
        get { lock.withLock { _viewMessages } }
        set { lock.withLock { _viewMessages = newValue } }
    }

    func currentCursor() async -> HistoryID? { cursor }
    func folders() async -> [FolderInfo] { folderList }

    func applyLocally(_ changes: [GmailChange]) async {
        try? await store.commit(GmailJournalBatch(changes: changes, cursor: cursor))
    }

    func checkForChanges() async {
        lock.withLock { _checks += 1 }
        await sync()
    }

    func changeCommitted() async { lock.withLock { _commits += 1 } }
    func labelsChanged() async { lock.withLock { _labelReloads += 1 } }
    func needsRelisting() async { lock.withLock { _relistings += 1 } }
    func notice(_ text: String, names: [String]) async { lock.withLock { _notices.append(text) } }
    func messages(in view: ListView) async -> [GmailMessageID]? { viewMessages }
    func ownAddresses() async -> Set<String> { own }
    func updatesAreOther() async -> Bool { updatesOther }

    /// A check for changes as the engine runs one: history since the cursor, screened by the
    /// actions, applied to the index, and the cursor moved in the same batch.
    func sync() async {
        guard let start = cursor else { return }
        var token: String?
        var records: [GmailHistoryRecord] = []
        var last = start
        repeat {
            guard let page = try? await gmail.history(since: start, types: Set(GmailHistoryType.allCases), label: nil,
                                                     pageToken: token, work: .checks) else { return }
            records += page.records
            last = page.historyID
            token = page.nextPageToken
        } while token != nil
        let screened = await actions?.screen(records) ?? records
        var changes: [GmailChange] = []
        let index = await store.index()
        var next = index.byOrder.last.map { index.records[Int($0)].order } ?? 0
        for record in screened {
            for added in record.messagesAdded where index.record(for: added.ref.id) == nil {
                next += GmailIndexRecord.orderStep
                changes.append(.place(added.ref, order: next, labels: Set(added.labels ?? []), attributes: []))
            }
            for deleted in record.messagesDeleted { changes.append(.tombstone(deleted.ref.id)) }
            for change in record.labelsAdded { changes.append(.relabel(change.message.ref.id, adding: Set(change.labels), removing: [])) }
            for change in record.labelsRemoved { changes.append(.relabel(change.message.ref.id, adding: [], removing: Set(change.labels))) }
        }
        try? await store.commit(GmailJournalBatch(changes: changes, cursor: last))
        cursor = last
    }
}

/// One Google account's actions against the in-memory Gmail and store, with its folders.
final class ActionsFixture: @unchecked Sendable {
    let accountID: UUID
    let gmail: MemoryGmailTransport
    let store: MemoryGmailStore
    let host: ActionsHost
    let layout: FileLayout
    let root: URL
    let mutes: MuteStore
    let rules: RuleStore
    let clock: ActionClock
    private(set) var actions: GmailActions
    /// What the actions talk to: the in-memory Gmail, or something standing in front of it.
    let wire: any GmailTransport
    var folders: [String: FolderInfo] = [:]
    var userLabels: [String: GmailLabelID] = [:]

    init(accountID: UUID = UUID(), clock: ActionClock = ActionClock(), undoWindow: TimeInterval = 60, userLabels: [String] = ["Clients", "Projects"],
         root existing: URL? = nil, gmail existingGmail: MemoryGmailTransport? = nil, store existingStore: MemoryGmailStore? = nil,
         bulkUnitsPerMinute: Int = 1_500, transport: ((MemoryGmailTransport) -> any GmailTransport)? = nil) async throws {
        self.accountID = accountID
        self.clock = clock
        root = existing ?? FileManager.default.temporaryDirectory.appendingPathComponent("falcon-gmail-actions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        layout = FileLayout(root: root)
        gmail = existingGmail ?? MemoryGmailTransport(accountID: accountID)
        store = existingStore ?? MemoryGmailStore(accountID: accountID, files: GmailFiles(layout: FileLayout(root: root), accountID: accountID))
        host = ActionsHost(store: store, gmail: gmail)
        mutes = MuteStore(layout: layout)
        rules = RuleStore(layout: layout)
        wire = transport?(gmail) ?? gmail
        actions = GmailActions(accountID: accountID, transport: wire, store: store, mutes: mutes, rules: rules, host: host,
                               undoWindow: undoWindow, clock: clock.clock, bulkUnitsPerMinute: bulkUnitsPerMinute)
        host.actions = actions
        if existingGmail == nil {
            for name in userLabels { self.userLabels[name] = gmail.addUserLabel(named: name) }
        } else {
            for (id, label) in gmail.userLabels { self.userLabels[label.name] = id }
        }
        try await buildFolders()
        host.cursor = gmail.historyID
        await actions.start()
    }

    /// Starts the account's actions again over the same files, Gmail and index, as a relaunch.
    func relaunch(clock newClock: ActionClock? = nil, undoWindow: TimeInterval = 60) async {
        await actions.stop()
        actions = GmailActions(accountID: accountID, transport: wire, store: store, mutes: mutes, rules: rules, host: host,
                               undoWindow: undoWindow, clock: (newClock ?? clock).clock)
        host.actions = actions
        await actions.start()
    }

    private func buildFolders() async throws {
        func folder(_ name: String, path: String, role: FolderRole, label: GmailLabelID?) -> FolderInfo {
            var info = FolderInfo(accountID: accountID, path: path, name: name, delimiter: "/", role: role, attributes: [], isSelectable: true)
            info.gmailLabelID = label
            return info
        }
        var list = [
            folder("Inbox", path: "INBOX", role: .inbox, label: .inbox),
            folder("Drafts", path: "[Gmail]/Drafts", role: .drafts, label: .draft),
            folder("Archive", path: "[Gmail]/All Mail", role: .all, label: nil),
            folder("Sent", path: "[Gmail]/Sent Mail", role: .sent, label: .sent),
            folder("Deleted Items", path: "[Gmail]/Trash", role: .trash, label: .trash),
            folder("Junk Email", path: "[Gmail]/Spam", role: .junk, label: .spam),
            folder("Important", path: "[Gmail]/Important", role: .important, label: .important),
            folder("Starred", path: "[Gmail]/Starred", role: .flagged, label: .starred)
        ]
        var entries = GmailLabelID.fixedSlots.map {
            GmailLabelEntry(id: $0, name: $0.value, kind: .system, isShown: true, folderID: UUID())
        }
        for (name, id) in userLabels.sorted(by: { $0.key < $1.key }) {
            list.append(folder(name, path: name, role: .other, label: id))
            entries.append(GmailLabelEntry(id: id, name: name, kind: .user, isShown: true, folderID: UUID()))
        }
        try await store.saveLabelTable(entries)
        host.folderList = list
        folders = Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
    }

    func view(_ name: String, filters: Set<ListFilter> = []) -> ListView {
        ListView(scope: .folder(folders[name]!.id), filters: filters)
    }

    func label(_ name: String) -> GmailLabelID { userLabels[name]! }

    /// Adds a message to Gmail and places it in the index at the top, as the engine would.
    @discardableResult
    func add(_ subject: String = "Hello", labels: Set<GmailLabelID> = [.inbox, .unread], thread: GmailThreadID? = nil,
             from: String = "Ana <ana@example.com>", messageID: String? = nil, date: Date? = nil) async throws -> GmailRef {
        let ref = gmail.add(subject: subject, from: from, labels: labels, date: date ?? clock.now, thread: thread, messageID: messageID)
        let top = await topOrder()
        try await store.commit(GmailJournalBatch(changes: [.place(ref, order: top + GmailIndexRecord.orderStep, labels: labels, attributes: [])],
                                                 cursor: gmail.historyID))
        host.cursor = gmail.historyID
        return ref
    }

    private func topOrder() async -> UInt32 {
        let index = await store.index()
        return index.byOrder.last.map { index.records[Int($0)].order } ?? 0
    }

    func key(_ ref: GmailRef) -> RowKey { .gmail(account: accountID, id: ref.id) }

    func request(_ verb: MailActionRequest.Verb, _ refs: [GmailRef], in folder: String, automatic: Bool = false) -> MailActionRequest {
        MailActionRequest(verb: verb, targets: .items(refs.map { .message(key($0)) }), context: view(folder), isAutomatic: automatic)
    }

    @discardableResult
    func perform(_ verb: MailActionRequest.Verb, _ refs: [GmailRef], in folder: String) async throws -> ActionReceipt {
        try await actions.perform(request(verb, refs, in: folder))
    }

    /// What Gmail holds for a message now.
    func gmailLabels(_ ref: GmailRef) -> Set<GmailLabelID>? { gmail.message(ref.id)?.labels }
    /// What the index shows for a message now.
    func shown(_ ref: GmailRef) async -> Set<GmailLabelID>? { await store.labels(of: ref.id) }

    func flush(_ seconds: TimeInterval = 5) async -> Bool { await actions.flushPending(within: seconds) }

    /// Waits, for real, until `condition` holds or `seconds` pass.
    func eventually(_ seconds: TimeInterval = 3, _ condition: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    var pendingFile: URL { store.files.pendingOps }

    func cleanUp() async {
        await actions.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

/// Stands between the actions and the in-memory Gmail, to count calls by kind of work, to time
/// them by the test clock, and to stand in for `batchModify` on a mailbox too large to keep.
final class RecordingTransport: GmailTransport, @unchecked Sendable {
    let inner: MemoryGmailTransport
    let clock: ActionClock
    private let lock = NSLock()
    private var _bulkCalls: [(at: Date, method: GmailMethod, ids: Int, work: WorkClass)] = []
    /// When set, `batchModify` only records, as for 200,000 messages the in-memory Gmail does not hold.
    let recordOnly: Bool
    private var _modifyCalls = 0
    /// The `modify` calls, counted from 1, that fail as a busy Gmail would.
    var failingModifyCalls: Set<Int> = []

    init(_ inner: MemoryGmailTransport, clock: ActionClock, recordOnly: Bool = false) {
        self.inner = inner
        self.clock = clock
        self.recordOnly = recordOnly
    }

    var accountID: UUID { inner.accountID }
    var bulkCalls: [(at: Date, method: GmailMethod, ids: Int, work: WorkClass)] { lock.withLock { _bulkCalls } }

    func profile(work: WorkClass) async throws -> GmailProfile { try await inner.profile(work: work) }
    func labels(work: WorkClass) async throws -> [GmailLabel] { try await inner.labels(work: work) }
    func label(_ id: GmailLabelID, work: WorkClass) async throws -> GmailLabel { try await inner.label(id, work: work) }
    func createLabel(named name: String, work: WorkClass) async throws -> GmailLabel { try await inner.createLabel(named: name, work: work) }
    func sendAs(work: WorkClass) async throws -> [GmailSendAs] { try await inner.sendAs(work: work) }
    func list(_ query: GmailListQuery, work: WorkClass) async throws -> GmailListPage { try await inner.list(query, work: work) }
    func history(since start: HistoryID, types: Set<GmailHistoryType>, label: GmailLabelID?, pageToken: String?,
                 work: WorkClass) async throws -> GmailHistoryPage {
        try await inner.history(since: start, types: types, label: label, pageToken: pageToken, work: work)
    }
    func message(_ id: GmailMessageID, format: GmailFormat, work: WorkClass) async throws -> GmailMessage {
        try await inner.message(id, format: format, work: work)
    }
    func thread(_ id: GmailThreadID, format: GmailFormat, work: WorkClass) async throws -> GmailThread {
        try await inner.thread(id, format: format, work: work)
    }
    func batch(_ parts: [GmailBatchPart], work: WorkClass) async throws -> [GmailBatchPart: Result<GmailBatchAnswer, GoogleAPIError>] {
        try await inner.batch(parts, work: work)
    }
    func attachment(_ attachmentID: String, of message: GmailMessageID, work: WorkClass) async throws -> Data {
        try await inner.attachment(attachmentID, of: message, work: work)
    }
    func modify(_ id: GmailMessageID, adding: Set<GmailLabelID>, removing: Set<GmailLabelID>, work: WorkClass) async throws -> GmailMessage {
        let call = lock.withLock { () -> Int in
            _bulkCalls.append((clock.now, .messagesModify, 1, work))
            _modifyCalls += 1
            return _modifyCalls
        }
        if failingModifyCalls.contains(call) {
            throw GoogleAPIError(kind: .temporary, httpStatus: 503, reason: "backendError")
        }
        return try await inner.modify(id, adding: adding, removing: removing, work: work)
    }
    func batchModify(_ ids: [GmailMessageID], adding: Set<GmailLabelID>, removing: Set<GmailLabelID>, work: WorkClass) async throws {
        lock.withLock { _bulkCalls.append((clock.now, .messagesBatchModify, ids.count, work)) }
        if recordOnly {
            XCTAssertLessThanOrEqual(ids.count, 1_000)
            return
        }
        try await inner.batchModify(ids, adding: adding, removing: removing, work: work)
    }
    func batchDelete(_ ids: [GmailMessageID], work: WorkClass) async throws {
        lock.withLock { _bulkCalls.append((clock.now, .messagesBatchDelete, ids.count, work)) }
        try await inner.batchDelete(ids, work: work)
    }
    func trash(_ id: GmailMessageID, work: WorkClass) async throws -> GmailMessage { try await inner.trash(id, work: work) }
    func untrash(_ id: GmailMessageID, work: WorkClass) async throws -> GmailMessage { try await inner.untrash(id, work: work) }
    func send(_ raw: Data, threadID: GmailThreadID?, work: WorkClass) async throws -> GmailMessage {
        try await inner.send(raw, threadID: threadID, work: work)
    }
    func importMessage(_ raw: Data, labels: Set<GmailLabelID>, options: GmailImportOptions, work: WorkClass) async throws -> GmailMessage {
        try await inner.importMessage(raw, labels: labels, options: options, work: work)
    }
    func createDraft(_ raw: Data, threadID: GmailThreadID?, work: WorkClass) async throws -> GmailDraft {
        try await inner.createDraft(raw, threadID: threadID, work: work)
    }
    func updateDraft(_ draftID: String, raw: Data, threadID: GmailThreadID?, work: WorkClass) async throws -> GmailDraft {
        try await inner.updateDraft(draftID, raw: raw, threadID: threadID, work: work)
    }
    func deleteDraft(_ draftID: String, work: WorkClass) async throws { try await inner.deleteDraft(draftID, work: work) }
    func drafts(pageToken: String?, work: WorkClass) async throws -> GmailDraftList { try await inner.drafts(pageToken: pageToken, work: work) }
    func setFloodMode(_ on: Bool) async { await inner.setFloodMode(on) }
    func noteOwnerActivity(at date: Date) async { await inner.noteOwnerActivity(at: date) }
    func pause() async -> GmailPause? { await inner.pause() }
    func usage() async -> GmailUsage { await inner.usage() }
}
