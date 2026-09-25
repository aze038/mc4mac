import Foundation

// One Google account's list: every message of every folder from the index, with rows' text from
// the newest 1,000 kept on the Mac, the conversation summaries, the rows fetched this session,
// and otherwise from Gmail a landing at a time. The engine owns the store and the transport and
// tells the source when the index has changed; the source never writes to either.

/// What a list source may offer beyond `ListSource`: conversations opened out, and the lines under
/// its rows. The table asks for these when its source has them.
public protocol ListSourceExtras: ListSource {
    /// Conversations opened out in a view, named by their rows' keys. The source sends the view
    /// again with their messages under them, on `changes(of:)`.
    func setExpanded(_ keys: Set<RowKey>, in view: ListView) async
    /// The lines under the view's rows, each time they change.
    func footers(of view: ListView) -> AsyncStream<[ListFooter]>
    /// The rows now on screen, whatever their text, each time they change.
    func showing(_ keys: [RowKey], in view: ListView) async
}

extension ListSourceExtras {
    public func showing(_ keys: [RowKey], in view: ListView) async {}
}

/// Where the source stands with Gmail, as the engine sees it.
public enum ListReachability: Hashable, Sendable {
    case online
    case offline
}

/// What the engine knows of its listings, which decides whether a view's Items is the index's
/// count or Gmail's.
public struct ListListingState: Hashable, Sendable {
    public var allMailComplete: Bool
    public var allMailTotal: Int?
    public var attachmentsKnown: Bool
    public var sizesKnown: Bool

    public init(allMailComplete: Bool = true, allMailTotal: Int? = nil, attachmentsKnown: Bool = false, sizesKnown: Bool = false) {
        self.allMailComplete = allMailComplete
        self.allMailTotal = allMailTotal
        self.attachmentsKnown = attachmentsKnown
        self.sizesKnown = sizesKnown
    }
}

public actor GmailListSource: ListSourceExtras {
    public nonisolated let accountID: UUID
    public nonisolated let email: String
    /// Shared by every account, so All Inboxes and searches over several accounts are built in
    /// one place.
    public nonisolated let index: ListIndex
    /// A stream of its own for each reader, of rows' text as it arrives.
    public nonisolated var rows: AsyncStream<[RowKey: MessageRowContent]> { rowsOut.subscribe() }

    private let store: any GmailStore
    private let transport: any GmailTransport
    private let archiveFolderID: UUID
    private let ownAddresses: Set<String>
    private let uptime: @Sendable () -> TimeInterval
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void

    private nonisolated let rowsOut = RowBroadcast<[RowKey: MessageRowContent]>()
    /// Where a request for rows goes: on screen, the screen ahead, or wanted by a sort whatever
    /// the scroll does.
    enum Lane: Sendable { case visible, ahead, background }
    private nonisolated let requests: AsyncStream<(keys: [RowKey], lane: Lane)>.Continuation
    private var pump: Task<Void, Never>?
    private var wake: Task<Void, Never>?

    private let session = RowContentStore()
    private let scheduler: RowFetchScheduler
    private var labels: [GmailLabelEntry] = []
    private var snapshotOfIndex = GmailIndexSnapshot.empty
    private var cachedIDs: Set<GmailMessageID> = []
    private var listing = ListListingState()
    /// As the engine last said.
    private var reachability = ListReachability.online
    /// Gmail has asked FalconMail to wait more than a minute, which the list treats as offline.
    private var pausedLong = false
    /// Rows whose next fetch is their whole conversation, 40 units, rather than the message, 20.
    private var threadFetch: Set<GmailMessageID> = []
    /// The row whose text holds each conversation's messages, for its opened lines.
    private var conversationRow: [UInt64: RowKey] = [:]
    private var refreshed = false
    private var refreshing: Task<Void, Never>?
    private var rebuilding: Task<Void, Never>?
    private var anchorTask: Task<Void, Never>?
    /// When anchors were last asked for, so that failing to reach Gmail does not make every
    /// refresh ask again.
    private var anchorsAskedAt: TimeInterval?
    /// Asks Gmail for anchors and keeps them. On its own the list uses one over its store; the
    /// engine hands it its own.
    private var anchorFiller: GmailDateAnchorFiller
    private var needsTold: Set<ListNeed> = []
    /// How many rows each folder showed at once when last told to the engine.
    private var shownRows: [UUID: Int] = [:]
    private var textAsked: Set<ListView> = []

    private nonisolated let watchers: ListWatchers
    /// What each watched view's watchers were last sent, which the next change is worked out from.
    private var sent: [ListView: ListSnapshot] = [:]
    private var sentFooters: [ListView: [ListFooter]] = [:]
    private var builds: [ListView: ListBuild] = [:]
    /// Rows that stand for conversations in the views built last, whose text is a thread's.
    private var conversationKeys: [ListView: Set<UInt64>] = [:]

    /// Called with what a view needs the engine to list: attachments, sizes or anchors. The
    /// engine lists them in the background and calls `refresh()` when they are in.
    public var onNeed: (@Sendable (ListNeed) -> Void)?

    public init(accountID: UUID, email: String, store: any GmailStore, transport: any GmailTransport,
                archiveFolderID: UUID, index: ListIndex = ListIndex(), ownAddresses: Set<String> = [],
                budget: RowFetchBudget = TokenBucketEstimate(),
                uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async -> Void) {
        self.accountID = accountID
        self.email = email
        self.store = store
        self.transport = transport
        self.archiveFolderID = archiveFolderID
        self.index = index
        self.ownAddresses = Set(([email] + Array(ownAddresses)).map { $0.lowercased() })
        self.uptime = uptime
        self.now = now
        self.sleep = sleep
        scheduler = RowFetchScheduler(budget: budget)
        anchorFiller = GmailDateAnchorFiller(store: store, transport: transport, now: now)
        let forget = WeakBox<GmailListSource>()
        watchers = ListWatchers { view in Task { await forget.value?.forget(view) } }
        let (incoming, requests) = AsyncStream.makeStream(of: (keys: [RowKey], lane: Lane).self)
        self.requests = requests
        forget.value = self
        Task { await self.startPump(incoming) }
    }

    private func startPump(_ incoming: AsyncStream<(keys: [RowKey], lane: Lane)>) {
        pump = Task { [weak self] in
            for await request in incoming {
                guard let self else { return }
                await self.take(request.keys, lane: request.lane)
            }
        }
    }

    public func setOnNeed(_ handler: (@Sendable (ListNeed) -> Void)?) {
        onNeed = handler
    }

    /// Called when a folder is shown, with its label (nil for Archive) and how many rows the list
    /// shows at once, which the engine passes to the store's first-screen rule: the Inbox and the
    /// 12 folders used most recently keep that many rows, 20 to 30, on the Mac.
    public var onFolderShown: (@Sendable (GmailLabelID?, Int) -> Void)?

    public func setOnFolderShown(_ handler: (@Sendable (GmailLabelID?, Int) -> Void)?) {
        onFolderShown = handler
    }

    /// The rows on screen: for a folder of this account, how many there are at once.
    public func showing(_ keys: [RowKey], in view: ListView) async {
        guard case .folder(let folderID) = view.scope, !keys.isEmpty else { return }
        let target: GmailLabelID??
        if folderID == archiveFolderID {
            target = .some(nil)
        } else if let label = labels.first(where: { $0.folderID == folderID })?.id {
            target = .some(label)
        } else {
            target = nil
        }
        guard let label = target, shownRows[folderID] != keys.count else { return }
        shownRows[folderID] = keys.count
        onFolderShown?(label, keys.count)
    }

    deinit {
        rowsOut.finish()
        requests.finish()
        pump?.cancel()
        wake?.cancel()
        anchorTask?.cancel()
    }

    // MARK: - The engine's side

    /// Reads the index, labels, anchors and the messages kept on the Mac again, and sends every
    /// watched view that changed. The engine calls it after each change it commits.
    public func refresh() async {
        // One at a time: a refresh waits at the store, and a second one running meanwhile would
        // build views before the first had told the index which rows are on the Mac.
        let previous = refreshing
        let task = Task { [weak self] in
            await previous?.value
            await self?.readStore()
        }
        refreshing = task
        await task.value
    }

    private func ensureRefreshed() async {
        guard !refreshed else { return }
        if let running = refreshing { await running.value } else { await refresh() }
    }

    private func readStore() async {
        snapshotOfIndex = await store.index()
        labels = await store.labelTable()
        let anchors = await store.dateAnchors()
        let cached = await store.cachedIDs()
        let newlyCached = cached.subtracting(cachedIDs)
        let gone = cachedIDs.subtracting(cached)
        cachedIDs = cached
        if !newlyCached.isEmpty {
            let messages = await store.cachedMessages(Array(newlyCached))
            var facts: [UInt64: ListRowFacts] = [:]
            for (id, message) in messages { facts[id.raw] = ListRowFacts(content(message), ownAddresses: ownAddresses) }
            await index.addFacts(facts, account: accountID)
        }
        // A message that left the cache keeps its facts only while its text is in the session.
        let forget = gone.filter { !session.contains(.gmail(account: accountID, id: $0)) }.map(\.raw)
        if !forget.isEmpty { await index.forgetFacts(forget, account: accountID) }
        await index.setAccount(ListIndexAccount(
            accountID: accountID, email: email, index: snapshotOfIndex, labels: labels, archiveFolderID: archiveFolderID,
            allMailComplete: listing.allMailComplete, allMailTotal: listing.allMailTotal, anchors: anchors,
            attachmentsKnown: listing.attachmentsKnown, sizesKnown: listing.sizesKnown))
        refreshed = true
        await rebuildWatched()
    }

    /// Reads the store the first time the source is used.
    public func refreshIfNeeded() async {
        await ensureRefreshed()
    }

    public func setListingState(_ state: ListListingState) async {
        listing = state
        needsTold = []
        await refresh()
    }

    /// Offline, or Gmail has asked FalconMail to wait more than a minute: grey rows could not fill,
    /// so views show only rows whose text is on the Mac, and a line saying how many are not.
    public func setReachability(_ reachability: ListReachability) async {
        guard reachability != self.reachability else { return }
        self.reachability = reachability
        await reachabilityChanged()
    }

    private var isOffline: Bool { reachability == .offline || pausedLong }

    private func reachabilityChanged() async {
        await index.setOffline(isOffline, account: accountID)
        await rebuildWatched()
        if !isOffline { pumpLandings() }
    }

    /// A view as it would be built now, with what building it found out.
    public func build(_ view: ListView) async -> ListBuild {
        await ensureRefreshed()
        await checkPause()
        let build = await index.build(view)
        remember(build, for: view)
        return build
    }

    /// A view built elsewhere from the shared index, such as All Inboxes, whose rows this
    /// account's requests will name.
    public func adopt(_ build: ListBuild, for view: ListView) {
        remember(build, for: view)
    }

    // MARK: - ListSource

    public func snapshot(of view: ListView) async -> ListSnapshot {
        let snapshot = await build(view).snapshot
        // What the caller now shows is what the next change is worked out from.
        if watchers.isWatched(view) { sent[view] = snapshot }
        return snapshot
    }

    public nonisolated func changes(of view: ListView) -> AsyncStream<ListDiff> {
        watchers.diffStream(for: view)
    }

    public nonisolated func footers(of view: ListView) -> AsyncStream<[ListFooter]> {
        let stream = watchers.footerStream(for: view)
        Task { await self.footersWatched(view) }
        return stream
    }

    public nonisolated func requestRows(_ keys: [RowKey], priority: RowPriority) {
        requests.yield((keys, priority == .visible ? .visible : .ahead))
    }

    public func setExpanded(_ keys: Set<RowKey>, in view: ListView) async {
        await index.setExpanded(keys, in: view.scope)
        await rebuildWatched()
    }

    public func summary(for key: RowKey, in view: ListView) async -> RowAvailability {
        guard case .gmail(let account, let id) = key, account == accountID else {
            return .unavailable(reason: GoogleAPIError(kind: .notFound).errorDescription ?? "")
        }
        await ensureRefreshed()
        let labels = await store.labels(of: id)
        if let cached = await store.cachedMessages([id])[id] {
            return .available(summary(cached, labels: labels ?? [], view: view))
        }
        await checkPause()
        guard !isOffline else {
            return .unavailable(reason: GoogleAPIError(kind: .offline).errorDescription ?? "")
        }
        do {
            let message = try await transport.message(id, format: .row, work: .interactive)
            let content = GmailRows.content(message, key: key)
            if let content { remember([key: content]) }
            return .available(summary(message, view: view))
        } catch let error as GoogleAPIError where error.kind == .notFound {
            return .gone
        } catch let error as GoogleAPIError {
            return .unavailable(reason: error.errorDescription ?? "")
        } catch {
            return .unavailable(reason: GoogleAPIError(kind: .offline).errorDescription ?? "")
        }
    }

    // MARK: - Watching views

    /// A new footers watcher gets the lines as they stand.
    private func footersWatched(_ view: ListView) async {
        if builds[view] == nil { _ = await build(view) }
        let lines = footerLines(for: view)
        sentFooters[view] = lines
        watchers.send(lines, for: view)
    }

    private func forget(_ view: ListView) {
        guard !watchers.isWatched(view) else { return }
        sent[view] = nil
        sentFooters[view] = nil
        builds[view] = nil
        conversationKeys[view] = nil
        textAsked.remove(view)
    }

    /// Builds every watched view again and sends what changed. One at a time: two running at once
    /// would each work out their change from the same snapshot, and the second would not fit what
    /// the first had sent.
    private func rebuildWatched() async {
        let previous = rebuilding
        let task = Task { [weak self] in
            await previous?.value
            await self?.rebuildNow()
        }
        rebuilding = task
        await task.value
    }

    private func rebuildNow() async {
        // A view watched only for its footers, as All Inboxes watches each account's, is built by
        // whoever merges it.
        for view in watchers.diffViews {
            let old = sent[view] ?? builds[view]?.snapshot
            let build = await index.build(view)
            remember(build, for: view)
            sent[view] = build.snapshot
            if let old {
                let diff = ListDiffer.diff(from: old, to: build.snapshot)
                if !diff.inserted.isEmpty || !diff.removed.isEmpty || !diff.reloaded.isEmpty || old.itemCount != build.snapshot.itemCount
                    || old.complete != build.snapshot.complete {
                    watchers.send(diff, for: view)
                }
            }
            sendFooters(view)
        }
    }

    private func remember(_ build: ListBuild, for view: ListView) {
        builds[view] = build
        if view.conversations {
            var keys = Set<UInt64>()
            let sourceIndex = build.snapshot.sources.firstIndex(of: accountID).map(UInt8.init(truncatingIfNeeded:))
            for record in build.snapshot.rows where record.displayKind == .conversation && record.source == sourceIndex {
                keys.insert(record.key)
            }
            conversationKeys[view] = keys
        } else {
            conversationKeys[view] = nil
        }
        for need in build.needs {
            if case .anchors(let account) = need, account == accountID {
                askAnchors(daily: view.scope.mergesAccounts)
            } else if let onNeed, needsTold.insert(need).inserted {
                // Once: the engine lists it in the background, and says so with the listing state.
                // Until someone listens it is not counted as told, so a view built before the
                // engine is connected still asks.
                onNeed(need)
            }
        }
        if !build.textWanted.isEmpty, !textAsked.contains(view) {
            textAsked.insert(view)
            let mine = build.textWanted.filter { $0.accountID == accountID }
            if !mine.isEmpty { requests.yield((mine, .background)) }
        }
    }

    private func footerLines(for view: ListView) -> [ListFooter] {
        var lines: [ListFooter] = []
        if let build = builds[view] {
            if build.hiddenMessages > 0 { lines.append(.offline(hidden: build.hiddenMessages)) }
            if let before = build.listedByDateBefore { lines.append(.listedByDate(before: before, sort: view.sort.key)) }
        }
        if !isOffline, scheduler.isWaitingOnBudget(at: uptime()) { lines.insert(.loading(email: email), at: 0) }
        return lines
    }

    private func sendFooters(_ view: ListView) {
        guard watchers.isWatched(view) else { return }
        let lines = footerLines(for: view)
        guard lines != sentFooters[view] else { return }
        sentFooters[view] = lines
        watchers.send(lines, for: view)
    }

    private func sendAllFooters() {
        for view in watchers.views { sendFooters(view) }
    }

    // MARK: - Rows

    private func isConversation(_ id: GmailMessageID) -> Bool {
        conversationKeys.values.contains { $0.contains(id.raw) }
    }

    /// Rows asked for: those whose text is on the Mac go at once and cost nothing; the rest are
    /// scheduled, unless Gmail cannot be reached, when they stay grey.
    private func take(_ keys: [RowKey], lane: Lane) async {
        let mine = keys.compactMap { key -> GmailMessageID? in
            guard case .gmail(let account, let id) = key, account == accountID else { return nil }
            return id
        }
        if mine.isEmpty, lane == .visible {
            // Nothing of this account is on screen: what it had waiting has scrolled away.
            scheduler.request([], priority: .visible) { _ in 0 }
            pumpLandings()
            return
        }
        guard !mine.isEmpty else { return }
        await ensureRefreshed()
        var known: [RowKey: MessageRowContent] = [:]
        var missing: [GmailMessageID] = []
        var needThread: Set<GmailMessageID> = []

        let cached = await store.cachedMessages(mine.filter { cachedIDs.contains($0) })
        var threadsWanted: Set<GmailThreadID> = []
        for id in mine where isConversation(id) {
            if let record = snapshotOfIndex.record(for: id) { threadsWanted.insert(record.gmailThreadID) }
        }
        let summaries = await store.threadSummaries(Array(threadsWanted))

        for id in mine {
            let key = RowKey.gmail(account: accountID, id: id)
            let summary = snapshotOfIndex.record(for: id).flatMap { summaries[$0.gmailThreadID] }
            let conversation = isConversation(id)
            var row = session.content(for: key) ?? cached[id].map(content) ?? memberContent(id)
            if conversation, row?.conversation == nil {
                if let summary {
                    row?.conversation = self.conversation(summary)
                } else {
                    // A conversation whose message is known but whose senders are not paints
                    // now, and is fetched again whole.
                    needThread.insert(id)
                }
            }
            if let row { known[key] = row } else { missing.append(id) }
        }
        remember(known)

        guard !isOffline else { return }
        let fetch = missing + needThread.filter { known[.gmail(account: accountID, id: $0)] != nil }
        threadFetch.subtract(fetch)
        threadFetch.formUnion(needThread)
        let threadKeys = threadFetch
        let price: (RowKey) -> Int = { key in
            guard let id = key.gmailID else { return 0 }
            return threadKeys.contains(id) ? GmailMethod.threadsGet.units : GmailMethod.messagesGet.units
        }
        let wanted = fetch.map { RowKey.gmail(account: accountID, id: $0) }
        switch lane {
        case .visible: scheduler.request(wanted, priority: .visible, cost: price)
        case .ahead: if !wanted.isEmpty { scheduler.request(wanted, priority: .ahead, cost: price) }
        case .background: scheduler.requestInBackground(wanted, cost: price)
        }
        pumpLandings()
    }

    /// A child row's text from its opened conversation's members, when the conversation's is known.
    private func memberContent(_ id: GmailMessageID) -> MessageRowContent? {
        guard let thread = snapshotOfIndex.record(for: id)?.threadID, let parentKey = conversationRow[thread],
              let parent = session.peek(parentKey),
              let member = parent.conversation?.members.first(where: { $0.key.gmailID == id }) else { return nil }
        return MessageRowContent(key: .gmail(account: accountID, id: id), from: member.from, to: [], subject: parent.subject,
                                 preview: "", date: member.date)
    }

    /// Sends every landing the budget has room for, and wakes when the next one could go.
    private func pumpLandings() {
        let time = uptime()
        while let landing = scheduler.next(at: time) {
            let parts = landing.keys.compactMap { key -> GmailBatchPart? in
                guard let id = key.gmailID else { return nil }
                if threadFetch.contains(id), let thread = snapshotOfIndex.record(for: id)?.gmailThreadID {
                    return .thread(thread, .row)
                }
                return .message(id, .row)
            }
            let work: WorkClass = landing.priority == .visible ? .interactive : .background(.readAhead)
            Task { await self.send(landing, parts: parts, work: work) }
        }
        wake?.cancel()
        if let delay = scheduler.delay(at: time) {
            let sleep = self.sleep
            wake = Task { [weak self] in
                await sleep(max(delay, 0.05))
                guard !Task.isCancelled else { return }
                await self?.pumpLandings()
            }
        }
        sendAllFooters()
    }

    private func send(_ landing: RowLanding, parts: [GmailBatchPart], work: WorkClass) async {
        defer {
            scheduler.finished(landing.keys)
            sendAllFooters()
        }
        threadFetch.subtract(landing.keys.compactMap(\.gmailID))
        let answers: [GmailBatchPart: Result<GmailBatchAnswer, GoogleAPIError>]
        do {
            answers = try await transport.batch(parts, work: work)
        } catch let error as GoogleAPIError {
            if let wait = error.retryAfter { scheduler.pause(until: uptime() + wait) }
            if error.kind == .offline { await setReachability(.offline) }
            return
        } catch {
            return
        }
        var arrived: [RowKey: MessageRowContent] = [:]
        for key in landing.keys {
            guard let id = key.gmailID else { continue }
            let threadPart = snapshotOfIndex.record(for: id).map { GmailBatchPart.thread($0.gmailThreadID, .row) }
            if let threadPart, case .success(.thread(let thread))? = answers[threadPart] {
                if let row = GmailRows.content(thread, key: key, hidden: hiddenLabels(forKey: id), folderName: folderName) {
                    arrived[key] = row
                }
            } else if case .success(.message(let message))? = answers[.message(id, .row)] {
                if var row = GmailRows.content(message, key: key) {
                    if let thread = snapshotOfIndex.record(for: id)?.gmailThreadID,
                       let summary = await store.threadSummaries([thread])[thread] {
                        row.conversation = conversation(summary)
                    }
                    arrived[key] = row
                }
            }
        }
        remember(arrived)
        if arrived.count < landing.keys.count {
            let refused = answers.values.compactMap { result -> GoogleAPIError? in
                if case .failure(let error) = result { return error }
                return nil
            }
            if let wait = refused.compactMap(\.retryAfter).max() { scheduler.pause(until: uptime() + wait) }
        }
    }

    /// Keeps rows' text for the session, shows it, and tells the index what it now knows.
    private func remember(_ rows: [RowKey: MessageRowContent]) {
        guard !rows.isEmpty else { return }
        let evicted = session.insert(rows)
        for (key, row) in rows where row.conversation?.members.isEmpty == false {
            if let id = key.gmailID, let thread = snapshotOfIndex.record(for: id)?.threadID { conversationRow[thread] = key }
        }
        if conversationRow.count > RowContentStore.defaultCapacity * 2 {
            conversationRow = conversationRow.filter { session.contains($0.value) }
        }
        rowsOut.send(rows)
        var facts: [UInt64: ListRowFacts] = [:]
        for (key, row) in rows { if let id = key.gmailID { facts[id.raw] = ListRowFacts(row, ownAddresses: ownAddresses) } }
        let forget = evicted.compactMap(\.gmailID).filter { !cachedIDs.contains($0) }.map(\.raw)
        let index = self.index
        let account = accountID
        let needsRebuild = watchers.diffViews.contains { view in
            view.scope.mergesAccounts || view.sort.key.isTextual || view.dateGroups || view.filters.contains(.mentionsMe)
                || self.isOffline
        }
        Task {
            await index.addFacts(facts, account: account)
            if !forget.isEmpty { await index.forgetFacts(forget, account: account) }
            if needsRebuild { await self.rebuildWatched() }
        }
    }

    // MARK: - Pauses and anchors

    private func checkPause() async {
        let wait = await transport.pause().map { $0.until.timeIntervalSince(now()) } ?? 0
        if wait > 0 { scheduler.pause(until: uptime() + wait) }
        let long = wait > 60
        guard long != pausedLong else { return }
        pausedLong = long
        await index.setOffline(isOffline, account: accountID)
    }

    /// Date anchors for group headers and for placing rows among other accounts': one `before:`
    /// listing each, 5 units, asked only for boundaries not known yet, through the engine's
    /// filler, which is the only writer of anchors. The engine is told once that this account's
    /// views want them, so it keeps them up after midnight and after deep placements.
    private func askAnchors(daily: Bool) {
        let time = uptime()
        if let onNeed, needsTold.insert(.anchors(accountID)).inserted { onNeed(.anchors(accountID)) }
        guard anchorTask == nil, !isOffline, anchorsAskedAt.map({ time - $0 >= 60 }) ?? true else { return }
        anchorsAskedAt = time
        let filler = anchorFiller
        anchorTask = Task { [weak self] in
            let learnt = await filler.fill(daily: daily)
            await self?.anchorsDone(learnt: learnt)
        }
    }

    private func anchorsDone(learnt: Bool) async {
        anchorTask = nil
        if learnt { await refresh() }
    }

    /// Rows' text the engine fetched for its own reasons, such as new mail and the first screen,
    /// shown without asking Gmail again.
    public func engineRows(_ rows: [RowKey: MessageRowContent]) {
        remember(rows.filter { $0.key.accountID == accountID })
    }

    /// Every message of this account a view shows, conversations opened out, for a change on a
    /// whole view that the index cannot work out alone, such as a search. Nil while the view is
    /// not listed in full, when acting on what is known would silently leave the rest.
    public func messageIDs(in view: ListView) async -> [GmailMessageID]? {
        var flat = view
        flat.conversations = false
        flat.dateGroups = false
        let snapshot = await build(flat).snapshot
        guard snapshot.complete else { return nil }
        return snapshot.rows.indices.compactMap { i in
            guard case .gmail(let account, let id)? = snapshot.rowKey(at: i), account == accountID else { return nil }
            return id
        }
    }

    /// The engine's filler, so that its anchors and the list's are one set with one writer.
    public func setAnchorFiller(_ filler: GmailDateAnchorFiller) {
        anchorFiller = filler
    }

    // MARK: - Building rows and summaries

    private func content(_ message: GmailCachedMessage) -> MessageRowContent {
        MessageRowContent(key: .gmail(account: accountID, id: message.id), from: message.from, to: message.to,
                          subject: message.subject, preview: String(message.preview.prefix(100)), date: message.date,
                          size: message.size, hasAttachments: message.hasAttachments)
    }

    private func conversation(_ summary: GmailThreadSummary) -> ConversationContent {
        ConversationContent(senders: summary.senders, messageCount: summary.messageCount, newestDate: summary.newestDate,
                            members: summary.members.map { member in
                                ConversationMember(key: .gmail(account: accountID, id: member.id), from: member.from, date: member.date,
                                                   folderName: snapshotOfIndex.slotByID[member.id.raw].map { folderName(snapshotOfIndex.labels(atSlot: $0)) } ?? nil)
                            })
    }

    /// Junk Email and Deleted Items are left out of a conversation's messages, as in Outlook,
    /// unless the row itself is in one of them.
    private func hiddenLabels(forKey id: GmailMessageID) -> Set<GmailLabelID> {
        let own = snapshotOfIndex.slotByID[id.raw].map { snapshotOfIndex.labels(atSlot: $0) } ?? []
        var hidden: Set<GmailLabelID> = [.spam, .trash, .chat]
        hidden.subtract(own)
        return hidden
    }

    /// The sidebar name of the folder a conversation's message is filed in, as its line under an
    /// opened conversation shows it; nil for the Inbox, where most are.
    private nonisolated func folderName(_ labels: Set<GmailLabelID>) -> String? {
        if labels.contains(.inbox) { return nil }
        if labels.contains(.trash) { return GmailSystemFolder.deletedItems.outlookName }
        if labels.contains(.spam) { return GmailSystemFolder.junkEmail.outlookName }
        if labels.contains(.draft) { return GmailSystemFolder.drafts.outlookName }
        if labels.contains(.sent) { return GmailSystemFolder.sent.outlookName }
        return nil
    }

    private func folderID(for labels: Set<GmailLabelID>, view: ListView) -> UUID {
        switch view.scope {
        case .folder(let id):
            return id
        case .allInboxes:
            return self.labels.first { $0.id == .inbox }?.folderID ?? archiveFolderID
        case .search:
            for label in [GmailLabelID.inbox, .draft, .sent, .trash, .spam] where labels.contains(label) {
                if let folder = self.labels.first(where: { $0.id == label })?.folderID { return folder }
            }
            let user = self.labels.filter { $0.kind == .user && $0.isShown && labels.contains($0.id) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return user.first?.folderID ?? archiveFolderID
        }
    }

    private func summary(_ message: GmailCachedMessage, labels: Set<GmailLabelID>, view: ListView) -> MessageSummary {
        var summary = MessageSummary(
            accountID: accountID, folderID: folderID(for: labels, view: view), uid: 0, messageID: message.messageID,
            inReplyTo: message.inReplyTo, references: message.references, subject: message.subject, from: message.from,
            to: message.to, cc: message.cc, date: message.date, flags: GmailRows.flags(labels), size: message.size,
            snippet: message.preview, hasAttachments: message.hasAttachments, hasBody: true,
            threadKey: message.threadID.threadKey)
        summary.id = RowKey.gmail(account: accountID, id: message.id).stringValue
        summary.gmailID = message.id
        summary.gmailThreadID = message.threadID
        summary.labelIDs = labels.sorted()
        summary.internalDate = message.date
        summary.bcc = message.bcc.isEmpty ? nil : message.bcc
        summary.replyTo = message.replyTo.isEmpty ? nil : message.replyTo
        return summary
    }

    private func summary(_ message: GmailMessage, view: ListView) -> MessageSummary {
        var summary = GmailRows.summary(message, accountID: accountID)
        summary.folderID = folderID(for: message.labels, view: view)
        return summary
    }
}

/// A weak reference that can be filled in after it is captured, for a callback made before the
/// object it calls exists.
final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
}

// MARK: - Gmail's answers as rows

enum GmailRows {
    static func flags(_ labels: Set<GmailLabelID>) -> MessageFlags {
        var flags = MessageFlags()
        if !labels.contains(.unread) { flags.insert(.seen) }
        if labels.contains(.starred) { flags.insert(.flagged) }
        if labels.contains(.draft) { flags.insert(.draft) }
        return flags
    }

    /// A row from a `format=metadata` answer.
    static func content(_ message: GmailMessage, key: RowKey) -> MessageRowContent? {
        guard message.gmailID != nil else { return nil }
        let type = message.header("Content-Type").map(ContentType.parse)
        return MessageRowContent(
            key: key, from: AddressParser.parse(message.header("From")).first ?? EmailAddress(address: ""),
            to: AddressParser.parse(message.header("To")),
            subject: RFC2047.decode(message.header("Subject") ?? ""),
            preview: String(GmailServerRow.decodeEntities(message.snippet ?? "").prefix(100)),
            date: message.receivedDate ?? message.header("Date").flatMap(RFC5322Date.parse) ?? .distantPast,
            size: message.sizeEstimate, hasAttachments: type.map { $0.mimeType == "multipart/mixed" })
    }

    /// A conversation row from a `threads.get format=metadata` answer: the row's own message, and
    /// every message of the thread in the folders that may show it, oldest first.
    static func content(_ thread: GmailThread, key: RowKey, hidden: Set<GmailLabelID>,
                        folderName: (Set<GmailLabelID>) -> String?) -> MessageRowContent? {
        let messages = (thread.messages ?? []).filter { $0.labels.isDisjoint(with: hidden) }
        guard let account = key.accountID,
              let own = messages.first(where: { $0.gmailID == key.gmailID }) ?? messages.last,
              var row = content(own, key: key) else { return nil }
        let members = messages.compactMap { message -> ConversationMember? in
            guard let id = message.gmailID else { return nil }
            return ConversationMember(key: .gmail(account: account, id: id),
                                      from: AddressParser.parse(message.header("From")).first ?? EmailAddress(address: ""),
                                      date: message.receivedDate ?? .distantPast, folderName: folderName(message.labels))
        }
        row.conversation = ConversationContent(senders: members.map(\.from), messageCount: members.count,
                                               newestDate: members.map(\.date).max() ?? row.date, members: members)
        return row
    }

    /// What reply, forward and a message window need, from a `format=metadata` answer with the
    /// reply headers.
    static func summary(_ message: GmailMessage, accountID: UUID) -> MessageSummary {
        let labels = message.labels
        let type = message.header("Content-Type").map(ContentType.parse)
        let date = message.receivedDate ?? message.header("Date").flatMap(RFC5322Date.parse) ?? .distantPast
        var summary = MessageSummary(
            accountID: accountID, folderID: GmailServerRow.folderID, uid: 0,
            messageID: AddressParser.messageIDs(message.header("Message-ID")).first ?? "",
            inReplyTo: AddressParser.messageIDs(message.header("In-Reply-To")).first ?? "",
            references: AddressParser.messageIDs(message.header("References")),
            subject: RFC2047.decode(message.header("Subject") ?? ""),
            from: AddressParser.parse(message.header("From")).first ?? EmailAddress(address: ""),
            to: AddressParser.parse(message.header("To")), cc: AddressParser.parse(message.header("Cc")),
            date: date, flags: flags(labels), size: message.sizeEstimate ?? 0,
            snippet: GmailServerRow.decodeEntities(message.snippet ?? ""),
            hasAttachments: type?.mimeType == "multipart/mixed", threadKey: "gm:" + message.threadId)
        if let id = message.gmailID { summary.id = RowKey.gmail(account: accountID, id: id).stringValue }
        summary.gmailID = message.gmailID
        summary.gmailThreadID = message.gmailThreadID
        summary.labelIDs = labels.sorted()
        summary.internalDate = message.receivedDate
        let replyTo = AddressParser.parse(message.header("Reply-To"))
        summary.replyTo = replyTo.isEmpty ? nil : replyTo
        return summary
    }
}
