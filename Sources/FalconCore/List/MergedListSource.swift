import Foundation

/// All Inboxes, and a search over several accounts: every account's rows in one view, placed by
/// date. Google rows come from the shared index, with the exact date where their text is known and
/// a date between anchors where not; rows of other accounts come from their stored Inboxes, whose
/// dates are exact. Requests for rows go to each row's own account.
public actor MergedListSource: ListSourceExtras {
    public nonisolated let index: ListIndex
    private let gmail: [UUID: GmailListSource]
    private let others: [UUID: any ListSource]
    private nonisolated let rowsOut = RowBroadcast<[RowKey: MessageRowContent]>()
    private var forwarding: [Task<Void, Never>] = []

    /// What each watched view was last sent, and what its accounts say of their budgets.
    private struct Watch {
        var last: ListSnapshot?
        var hidden = 0
        var loading: [UUID: String] = [:]
        var sent: [ListFooter]?
        var tasks: [Task<Void, Never>] = []
    }
    private nonisolated let watchers: ListWatchers
    private var watches: [ListView: Watch] = [:]
    private var listening: Task<Void, Never>?

    /// `others` are the sources of accounts that are not Google, whose stored Inbox rows they have
    /// given the index with `setStoredInboxRows`.
    public init(index: ListIndex, gmail: [GmailListSource], others: [UUID: any ListSource] = [:]) {
        self.index = index
        self.gmail = Dictionary(gmail.map { ($0.accountID, $0) }) { a, _ in a }
        self.others = others
        let box = WeakBox<MergedListSource>()
        watchers = ListWatchers { view in Task { await box.value?.unwatch(view) } }
        let sources: [any ListSource] = gmail + Array(others.values)
        let out = rowsOut
        forwarding = sources.map { source in
            let stream = source.rows
            return Task { for await rows in stream { out.send(rows) } }
        }
        box.value = self
    }

    deinit {
        for task in forwarding { task.cancel() }
        listening?.cancel()
        rowsOut.finish()
    }

    public nonisolated var rows: AsyncStream<[RowKey: MessageRowContent]> { rowsOut.subscribe() }

    public func snapshot(of view: ListView) async -> ListSnapshot {
        await build(view).snapshot
    }

    private func build(_ view: ListView) async -> ListBuild {
        for source in gmail.values { await source.refreshIfNeeded() }
        let build = await index.build(view)
        for source in gmail.values { await source.adopt(build, for: view) }
        watches[view]?.hidden = build.hiddenMessages
        if watchers.isWatched(view) { watches[view, default: Watch()].last = build.snapshot }
        return build
    }

    public nonisolated func changes(of view: ListView) -> AsyncStream<ListDiff> {
        let stream = watchers.diffStream(for: view)
        Task { await self.watch(view) }
        return stream
    }

    public nonisolated func footers(of view: ListView) -> AsyncStream<[ListFooter]> {
        let stream = watchers.footerStream(for: view)
        Task { await self.watch(view, newFooters: true) }
        return stream
    }

    public nonisolated func requestRows(_ keys: [RowKey], priority: RowPriority) {
        var byAccount: [UUID: [RowKey]] = [:]
        for key in keys { if let account = key.accountID { byAccount[account, default: []].append(key) } }
        Task { await self.route(byAccount, priority: priority) }
    }

    private func route(_ byAccount: [UUID: [RowKey]], priority: RowPriority) {
        // Every account hears a visible request, even with none of its rows on screen, so that
        // what it had waiting and has scrolled away is dropped.
        for (id, source) in gmail where priority == .visible || byAccount[id] != nil {
            source.requestRows(byAccount[id] ?? [], priority: priority)
        }
        for (id, keys) in byAccount { others[id]?.requestRows(keys, priority: priority) }
    }

    public func summary(for key: RowKey, in view: ListView) async -> RowAvailability {
        guard let account = key.accountID else { return .gone }
        if let source = gmail[account] { return await source.summary(for: key, in: view) }
        if let source = others[account] { return await source.summary(for: key, in: view) }
        return .gone
    }

    /// What is on screen keeps the place its date gave it until it scrolls away, so a row never
    /// moves while the owner is looking at it; others settle into their exact places.
    public func showing(_ keys: [RowKey], in view: ListView) async {
        await index.freezeVisible(keys)
    }

    public func setExpanded(_ keys: Set<RowKey>, in view: ListView) async {
        await index.setExpanded(keys, in: view.scope)
    }

    // MARK: Watching

    private func watch(_ view: ListView, newFooters: Bool = false) async {
        if watches[view]?.tasks.isEmpty ?? true {
            var watch = watches[view] ?? Watch()
            // Each account says when its rows wait for its budget.
            for (account, source) in gmail {
                let stream = source.footers(of: view)
                let email = source.email
                watch.tasks.append(Task { [weak self] in
                    for await lines in stream {
                        let loading = lines.contains { if case .loading = $0 { return true } else { return false } }
                        await self?.noteLoading(loading ? email : nil, account: account, view: view)
                    }
                })
            }
            watches[view] = watch
            if watch.last == nil { _ = await build(view) }
        }
        if newFooters {
            let lines = footerLines(view)
            watches[view]?.sent = lines
            watchers.send(lines, for: view)
        }
        startListening()
    }

    private func unwatch(_ view: ListView) {
        guard !watchers.isWatched(view), let watch = watches[view] else { return }
        for task in watch.tasks { task.cancel() }
        watches[view] = nil
    }

    private func startListening() {
        guard listening == nil else { return }
        let signals = index.observe()
        listening = Task { [weak self] in
            for await _ in signals {
                guard let self else { return }
                await self.rebuild()
            }
        }
    }

    private func rebuild() async {
        for view in watchers.views {
            let old = watches[view]?.last
            let built = await index.build(view)
            for source in gmail.values { await source.adopt(built, for: view) }
            watches[view, default: Watch()].last = built.snapshot
            watches[view]?.hidden = built.hiddenMessages
            if let old {
                let diff = ListDiffer.diff(from: old, to: built.snapshot)
                if !diff.inserted.isEmpty || !diff.removed.isEmpty || !diff.reloaded.isEmpty || old.itemCount != built.snapshot.itemCount {
                    watchers.send(diff, for: view)
                }
            }
            sendFooters(view)
        }
    }

    private func noteLoading(_ email: String?, account: UUID, view: ListView) {
        watches[view]?.loading[account] = email
        sendFooters(view)
    }

    private func footerLines(_ view: ListView) -> [ListFooter] {
        guard let watch = watches[view] else { return [] }
        var lines: [ListFooter] = gmail.keys.sorted { $0.uuidString < $1.uuidString }.compactMap { account in
            watch.loading[account].map { ListFooter.loading(email: $0) }
        }
        if watch.hidden > 0 { lines.append(.offline(hidden: watch.hidden)) }
        return lines
    }

    private func sendFooters(_ view: ListView) {
        guard watchers.isWatched(view), watches[view] != nil else { return }
        let lines = footerLines(view)
        guard lines != watches[view]?.sent else { return }
        watches[view]?.sent = lines
        watchers.send(lines, for: view)
    }
}
