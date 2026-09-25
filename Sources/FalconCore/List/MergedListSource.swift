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

    private struct Watch {
        var diffs: [UUID: AsyncStream<ListDiff>.Continuation] = [:]
        var footers: [UUID: AsyncStream<[ListFooter]>.Continuation] = [:]
        var last: ListSnapshot?
        var hidden = 0
        var loading: [UUID: String] = [:]
        var sent: [ListFooter] = []
        var tasks: [Task<Void, Never>] = []
    }
    private var watches: [ListView: Watch] = [:]
    private var listening: Task<Void, Never>?

    /// `others` are the sources of accounts that are not Google, whose stored Inbox rows they have
    /// given the index with `setStoredInboxRows`.
    public init(index: ListIndex, gmail: [GmailListSource], others: [UUID: any ListSource] = [:]) {
        self.index = index
        self.gmail = Dictionary(gmail.map { ($0.accountID, $0) }) { a, _ in a }
        self.others = others
        let sources: [any ListSource] = gmail + Array(others.values)
        let out = rowsOut
        forwarding = sources.map { source in
            let stream = source.rows
            return Task { for await rows in stream { out.send(rows) } }
        }
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
        return build
    }

    public nonisolated func changes(of view: ListView) -> AsyncStream<ListDiff> {
        let (stream, continuation) = AsyncStream.makeStream(of: ListDiff.self)
        let id = UUID()
        continuation.onTermination = { [weak self] _ in Task { await self?.unwatch(view, id: id) } }
        Task { await self.watch(view, id: id, diffs: continuation) }
        return stream
    }

    public nonisolated func footers(of view: ListView) -> AsyncStream<[ListFooter]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [ListFooter].self)
        let id = UUID()
        continuation.onTermination = { [weak self] _ in Task { await self?.unwatch(view, id: id) } }
        Task { await self.watch(view, id: id, footers: continuation) }
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

    public func setExpanded(_ keys: Set<RowKey>, in view: ListView) async {
        await index.setExpanded(keys, in: view.scope)
    }

    // MARK: Watching

    private func watch(_ view: ListView, id: UUID, diffs: AsyncStream<ListDiff>.Continuation? = nil,
                       footers: AsyncStream<[ListFooter]>.Continuation? = nil) async {
        if watches[view] == nil {
            var watch = Watch()
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
            watches[view]?.last = await build(view).snapshot
        }
        if let diffs { watches[view]?.diffs[id] = diffs }
        if let footers {
            watches[view]?.footers[id] = footers
            let lines = footerLines(view)
            watches[view]?.sent = lines
            footers.yield(lines)
        }
        startListening()
    }

    private func unwatch(_ view: ListView, id: UUID) {
        watches[view]?.diffs[id] = nil
        watches[view]?.footers[id] = nil
        if let watch = watches[view], watch.diffs.isEmpty, watch.footers.isEmpty {
            for task in watch.tasks { task.cancel() }
            watches[view] = nil
        }
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
        for view in watches.keys {
            let built = await index.build(view)
            for source in gmail.values { await source.adopt(built, for: view) }
            guard let old = watches[view]?.last else { continue }
            watches[view]?.last = built.snapshot
            watches[view]?.hidden = built.hiddenMessages
            let diff = ListDiffer.diff(from: old, to: built.snapshot)
            if !diff.inserted.isEmpty || !diff.removed.isEmpty || !diff.reloaded.isEmpty || old.itemCount != built.snapshot.itemCount {
                for continuation in watches[view]?.diffs.values ?? [:].values { continuation.yield(diff) }
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
        guard let watch = watches[view], !watch.footers.isEmpty else { return }
        let lines = footerLines(view)
        guard lines != watch.sent else { return }
        watches[view]?.sent = lines
        for continuation in watch.footers.values { continuation.yield(lines) }
    }
}
