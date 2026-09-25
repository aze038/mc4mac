import Foundation
import Observation

// The table's side of the list, on the main thread: the snapshot it draws, the rows' text it has,
// the selection, opened conversations and the lines under the rows. Everything the table asks of
// it is answered at once from what it holds; what it does not hold is asked of the source, and
// arrives later.

/// What changed, for the table to show.
public enum ListControllerChange {
    /// Every row: a new view, or a change too large to animate.
    case reload
    /// Rows inserted, removed and reloaded, to animate.
    case diff(ListDiff)
    /// Text arrived for these rows; the table redraws those on screen.
    case content(Set<RowKey>)
}

@MainActor
@Observable
public final class ListController {
    /// The view shown, nil before the first.
    public private(set) var view: ListView?
    /// The status bar's Items.
    public private(set) var itemCount = 0
    public private(set) var isComplete = true
    public private(set) var rowCount = 0
    public private(set) var footers: [ListFooter] = []
    public private(set) var selectionCount = 0
    /// A listing running for any account, which the status bar reports; the app sets it from
    /// the engines.
    public var syncProgress: ListSyncProgress?
    /// Every folder the sidebar shows has been listed in full; the app sets it from the engines.
    public var everyFolderListed = false

    @ObservationIgnored public private(set) var snapshot = ListSnapshot.empty(ListView(scope: .allInboxes))
    @ObservationIgnored public let content: RowContentStore
    @ObservationIgnored public private(set) var selection = ListSelection.none
    /// Called with each change, for the table.
    @ObservationIgnored public var onChange: ((ListControllerChange) -> Void)?

    @ObservationIgnored private var source: (any ListSource)?
    @ObservationIgnored private var sourceTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    @ObservationIgnored private var viewTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var planner = ScrollFetchPlanner()
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var expanded: Set<RowKey> = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var visible: Range<Int> = 0..<0
    @ObservationIgnored private let uptime: () -> TimeInterval

    public init(content: RowContentStore = RowContentStore(),
                uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.content = content
        self.uptime = uptime
    }

    // MARK: - Showing a view

    /// Shows `view` from `source`: the snapshot at once, then each change as it comes.
    public func show(_ view: ListView, from source: any ListSource) async {
        generation += 1
        let current = generation
        for task in viewTasks { task.cancel() }
        viewTasks = []
        settleTask?.cancel()
        if self.view?.scope != view.scope { expanded = [] }
        self.view = view
        self.source = source
        listen(to: source)
        let diffs = source.changes(of: view)
        let footerStream = (source as? any ListSourceExtras)?.footers(of: view)
        let snapshot = await source.snapshot(of: view)
        guard current == generation else { return }
        replace(with: snapshot)
        selection = .none
        selectionCount = 0
        footers = []
        viewTasks.append(Task { [weak self] in
            for await diff in diffs {
                guard let self, current == self.generation else { return }
                self.apply(diff)
            }
        })
        if let footerStream {
            viewTasks.append(Task { [weak self] in
                for await lines in footerStream {
                    guard let self, current == self.generation else { return }
                    if self.footers != lines { self.footers = lines }
                }
            })
        }
    }

    /// Reads each source's rows once, however often its views are shown.
    private func listen(to source: any ListSource) {
        let id = ObjectIdentifier(source)
        guard sourceTasks[id] == nil else { return }
        let stream = source.rows
        sourceTasks[id] = Task { [weak self] in
            for await rows in stream {
                guard let self else { return }
                self.arrived(rows)
            }
        }
    }

    public func stop() {
        for task in viewTasks { task.cancel() }
        for task in sourceTasks.values { task.cancel() }
        viewTasks = []
        sourceTasks = [:]
        settleTask?.cancel()
    }

    private func replace(with snapshot: ListSnapshot) {
        self.snapshot = snapshot
        publishCounts()
        planner.reset(rowCount: snapshot.rows.count)
        onChange?(.reload)
    }

    private func publishCounts() {
        if itemCount != snapshot.itemCount { itemCount = snapshot.itemCount }
        if isComplete != snapshot.complete { isComplete = snapshot.complete }
        if rowCount != snapshot.rows.count { rowCount = snapshot.rows.count }
    }

    /// Applies a change from the source. A change that does not fit what is shown, because it
    /// was worked out against another snapshot, becomes a reload rather than a wrong table.
    func apply(_ diff: ListDiff) {
        let old = snapshot.rows.count
        let fits = (diff.removed.last.map { $0 < old } ?? true)
            && old - diff.removed.count + diff.inserted.count == diff.snapshot.rows.count
            && (diff.inserted.last.map { $0 < diff.snapshot.rows.count } ?? true)
        snapshot = diff.snapshot
        publishCounts()
        planner.reset(rowCount: snapshot.rows.count)
        guard fits, !diff.reloadsTable else {
            selection = .none
            selectionCount = 0
            onChange?(.reload)
            return
        }
        selection = ListController.shifted(selection, removed: diff.removed, inserted: diff.inserted)
        selectionCount = selection.count(in: snapshot)
        onChange?(.diff(diff))
        // Rows that moved or arrived on screen may need their text.
        if !visible.isEmpty { request(visible, priority: .visible) }
    }

    static func shifted(_ selection: ListSelection, removed: IndexSet, inserted: IndexSet) -> ListSelection {
        func move(_ set: IndexSet, insertedAreIn: Bool) -> IndexSet {
            var set = set
            for row in removed.reversed() {
                set.remove(row)
                set.shift(startingAt: row + 1, by: -1)
            }
            for row in inserted {
                set.shift(startingAt: row, by: 1)
                if insertedAreIn { set.insert(row) }
            }
            return set
        }
        switch selection.form {
        case .rows(let rows):
            return ListSelection(rows: move(rows, insertedAreIn: false))
        case .allExcept(let except):
            // Mail that arrives after Select All is not part of it.
            return .all(except: move(except, insertedAreIn: true))
        }
    }

    private func arrived(_ rows: [RowKey: MessageRowContent]) {
        content.insert(rows)
        onChange?(.content(Set(rows.keys)))
    }

    // MARK: - What the table reads

    public func record(at row: Int) -> DisplayRecord? {
        snapshot.rows.indices.contains(row) ? snapshot.rows[row] : nil
    }

    public func key(at row: Int) -> RowKey? { snapshot.rowKey(at: row) }

    public func header(at row: Int) -> String? {
        guard let record = record(at: row), record.displayKind == .header else { return nil }
        return snapshot.headers[Int(record.group)]
    }

    /// The row's text, or nil while it is on its way; never waits.
    public func rowContent(at row: Int) -> MessageRowContent? {
        guard let key = key(at: row) else { return nil }
        if let known = content.content(for: key) { return known }
        // A child row's text is its line in the opened conversation's members.
        guard record(at: row)?.displayKind == .child, let parent = parentRow(of: row), let parentKey = self.key(at: parent),
              let conversation = content.peek(parentKey), let member = conversation.conversation?.members.first(where: { $0.key == key })
        else { return nil }
        return MessageRowContent(key: key, from: member.from, to: [], subject: conversation.subject, preview: "", date: member.date)
    }

    /// The folder a child row's message is in, when it is not the view's.
    public func childFolderName(at row: Int) -> String? {
        guard let key = key(at: row), let parent = parentRow(of: row), let parentKey = self.key(at: parent) else { return nil }
        return content.peek(parentKey)?.conversation?.members.first { $0.key == key }?.folderName
    }

    /// The conversation row a child row belongs to.
    public func parentRow(of row: Int) -> Int? {
        guard record(at: row)?.displayKind == .child else { return nil }
        var i = row - 1
        while i >= 0 {
            if snapshot.rows[i].displayKind != .child { return snapshot.rows[i].displayKind == .header ? nil : i }
            i -= 1
        }
        return nil
    }

    /// Whether a child row is its conversation's last, whose line underneath closes it.
    public func isLastChild(_ row: Int) -> Bool {
        guard record(at: row)?.displayKind == .child else { return false }
        return record(at: row + 1)?.displayKind != .child
    }

    public func isExpanded(_ row: Int) -> Bool {
        record(at: row)?.displayBits.contains(.expanded) ?? false
    }

    // MARK: - Scrolling

    /// The rows on screen are now `range`: fetch what is missing once the scroll is slow enough
    /// to read, and one screen ahead once it rests.
    public func scrolled(visible range: Range<Int>) {
        visible = range
        handle(planner.scrolled(to: range, at: uptime()))
    }

    /// The scroll has rested; the table calls this when its own timer fires, or the controller's
    /// does.
    public func settled() {
        handle(planner.settled(at: uptime()))
    }

    private func handle(_ plan: ScrollPlan) {
        if let rows = plan.visible { request(rows, priority: .visible) }
        if let rows = plan.ahead { request(rows, priority: .ahead) }
        if let at = plan.settleAt {
            settleTask?.cancel()
            let delay = max(0, at - uptime())
            settleTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1e9) + 1_000_000)
                guard !Task.isCancelled else { return }
                self?.settled()
            }
        }
    }

    private func request(_ rows: Range<Int>, priority: RowPriority) {
        guard let source else { return }
        let keys = rows.compactMap { row -> RowKey? in
            guard let key = key(at: row), content.peek(key) == nil else { return nil }
            return key
        }
        // Asking with nothing missing still tells the source that what it had waiting has
        // scrolled away.
        if priority == .visible || !keys.isEmpty { source.requestRows(keys, priority: priority) }
    }

    // MARK: - Opening conversations out

    public func toggleExpanded(row: Int) async {
        guard let record = record(at: row), record.displayKind == .conversation, let key = key(at: row),
              let view, let extras = source as? any ListSourceExtras else { return }
        if record.displayBits.contains(.expanded) {
            // Its messages may carry other keys since it was opened; any that is in it closes it.
            expanded.remove(key)
            let members = Set(content.peek(key)?.conversation?.members.map(\.key) ?? [])
            expanded.subtract(members)
            var i = row + 1
            while let child = self.record(at: i), child.displayKind == .child {
                if let childKey = self.key(at: i) { expanded.remove(childKey) }
                i += 1
            }
        } else {
            expanded.insert(key)
        }
        await extras.setExpanded(expanded, in: view)
    }

    // MARK: - Selection

    /// What the table has selected, as its selected rows.
    public func setSelection(_ selection: ListSelection) {
        self.selection = selection
        let count = selection.count(in: snapshot)
        if selectionCount != count { selectionCount = count }
    }

    public func selectAll() {
        setSelection(.all())
    }

    /// What a command acts on: the rows named one by one up to 1,000, the whole view above that
    /// for the commands that can, and otherwise nothing, with the sentence to show.
    public func targets(for command: ListCommand) -> ListTargets {
        selection.targets(for: command, in: snapshot)
    }

    /// The selected rows' keys for code that passes ids, such as the reading pane; nil above
    /// 1,000.
    public var selectedKeys: [RowKey]? { selection.rowKeys(in: snapshot) }

    // MARK: - The status bar

    public var itemsText: String { ListStatusText.items(itemCount) }

    public func stateText(everyAccountReachable: Bool) -> String? {
        ListStatusText.state(everyFolderListed: everyFolderListed, everyAccountReachable: everyAccountReachable,
                             progress: syncProgress)
    }
}
