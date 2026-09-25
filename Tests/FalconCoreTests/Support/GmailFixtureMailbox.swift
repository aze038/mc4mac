import Foundation
@testable import FalconCore

/// A large Gmail mailbox in memory behind `GmailTransport`, fast enough for the design's fixtures:
/// 55,000 messages, 200,000, and 200,000 migrated from Outlook with 150 labels (§14.5). It keeps
/// the rules the engine depends on as `MemoryGmailTransport` does, at Google's prices, but lists
/// from lists kept sorted, so listing 200,000 messages takes seconds, not hours. Page tokens are
/// offsets, as they may be at Google, so mail that comes or goes above the page being read shifts
/// the next page, and a listing can repeat or skip a message. A second client can import into it,
/// as olm2cloud or another Mac would.
final class GmailFixtureMailbox: GmailTransport, @unchecked Sendable {
    struct Message {
        var ref: GmailRef
        var date: Date
        var labels: Set<UInt16>
        var size: Int
        var sender: Int
        var historyID: HistoryID
    }

    struct Spec {
        var total: Int
        var inbox: Int
        var sent: Int
        var unread: Int
        var important: Int
        var starred: Int
        var drafts: Int
        var spam: Int
        var trash: Int
        var userLabels: Int
        var labelled: Int
        var otherCategories: Int
        var years: Int = 8

        /// §3's listing table: 55,000 messages, Inbox 20k, Sent 6k, Unread 3k, Important 10k,
        /// 20 labels with 10k, 12k Inbox in other categories.
        static let typical = Spec(total: 55_000, inbox: 20_000, sent: 6_000, unread: 3_000, important: 10_000, starred: 400,
                                  drafts: 30, spam: 300, trash: 700, userLabels: 20, labelled: 10_000, otherCategories: 12_000)
        /// 200,000: Inbox 80k, Sent 20k, Unread 30k, Important 40k, 40 labels with 60k, 50k Inbox
        /// in other categories.
        static let large = Spec(total: 200_000, inbox: 80_000, sent: 20_000, unread: 30_000, important: 40_000, starred: 1_000,
                                drafts: 50, spam: 500, trash: 1_500, userLabels: 40, labelled: 60_000, otherCategories: 50_000)
        /// 200,000 migrated from Outlook: Inbox 20k, Sent 30k, Unread 10k, Important 60k, 150
        /// labels with 140k, 10k Inbox in other categories.
        static let migrated = Spec(total: 200_000, inbox: 20_000, sent: 30_000, unread: 10_000, important: 60_000, starred: 1_000,
                                   drafts: 50, spam: 500, trash: 1_500, userLabels: 150, labelled: 140_000, otherCategories: 10_000)
    }

    let accountID: UUID
    let email: String
    let now: Date
    private let lock = NSLock()
    private var store: [UInt64: Message] = [:]
    private var threads: [UInt64: [UInt64]] = [:]
    private var labelIDs: [GmailLabelID] = []
    private var labelIndex: [GmailLabelID: UInt16] = [:]
    private var userNames: [GmailLabelID: String] = [:]
    private var sortedCache: [String: [UInt64]] = [:]
    private var countsCache: [UInt16: (total: Int, unread: Int)]?
    private var labelLists: [UInt16: [UInt64]]?
    private var allSorted: [UInt64]?
    private var log: [GmailHistoryRecord] = []
    private var current = HistoryID(raw: 90_000)
    private var floor = HistoryID(raw: 90_000)
    private var nextID: UInt64 = 0x1800_0000_0000_0000
    private var _units: [GmailMethod: Int] = [:]
    private var _calls: [GmailMethod: Int] = [:]
    private var _floodMode = false
    private var faults: [(method: GmailMethod, error: GoogleAPIError)] = []

    init(email: String = "owner@example.com", accountID: UUID = UUID(), now: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
        self.email = email
        self.accountID = accountID
        self.now = now
        for label in GmailLabelID.fixedSlots { _ = index(of: label) }
    }

    // MARK: - Building a fixture

    /// A mailbox shaped by `spec`, built without history, as if it had always been there. Dates run
    /// back evenly over `spec.years`; about 40% of messages are in conversations of two to four.
    static func fixture(_ spec: Spec, email: String = "owner@example.com", now: Date = Date(timeIntervalSince1970: 1_790_000_000))
        -> GmailFixtureMailbox {
        let box = GmailFixtureMailbox(email: email, now: now)
        box.lock.withLock { box.build(spec) }
        return box
    }

    private func build(_ spec: Spec) {
        var rng = SeededRandom(seed: UInt64(spec.total) &* 2_654_435_761)
        let span = Double(spec.years) * 365 * 86_400
        let n = spec.total
        var ids: [UInt64] = []
        ids.reserveCapacity(n)
        var threadOf: [UInt64] = []
        threadOf.reserveCapacity(n)
        var i = 0
        while i < n {
            // Newest first: i = 0 is the newest.
            let size = rng.next(100) < 40 ? 2 + rng.next(3) : 1
            var thread: UInt64 = 0
            for k in 0..<min(size, n - i) {
                nextID += 0x10
                if k == 0 { thread = nextID }
                ids.append(nextID)
                threadOf.append(thread)
            }
            i += size
        }
        var labels = [Set<UInt16>](repeating: [], count: n)
        // Mail in Junk Email and Deleted Items, the rest is ordinary mail.
        var pool = Array(0..<n)
        pool.shuffle(using: &rng)
        var cursor = 0
        func take(_ count: Int) -> ArraySlice<Int> {
            let slice = pool[cursor..<min(pool.count, cursor + count)]
            cursor += slice.count
            return slice
        }
        let spam = index(of: .spam), trash = index(of: .trash), sent = index(of: .sent), inbox = index(of: .inbox)
        for j in take(spec.spam) { labels[j].insert(spam) }
        for j in take(spec.trash) { labels[j].insert(trash) }
        for j in take(spec.drafts) { labels[j].insert(index(of: .draft)) }
        for j in take(spec.sent) { labels[j].insert(sent) }
        let inboxMembers = Array(take(spec.inbox))
        for j in inboxMembers { labels[j].insert(inbox) }
        let others: [GmailLabelID] = [.categorySocial, .categoryPromotions, .categoryUpdates, .categoryForums]
        for (k, j) in inboxMembers.enumerated() {
            if k < spec.otherCategories { labels[j].insert(index(of: others[k % 4])) } else { labels[j].insert(index(of: .categoryPersonal)) }
        }
        let ordinary = Array(pool[(spec.spam + spec.trash)...])
        for j in inboxMembers.prefix(spec.unread) { labels[j].insert(index(of: .unread)) }
        var extraUnread = spec.unread - min(spec.unread, inboxMembers.count)
        for j in ordinary where extraUnread > 0 && !labels[j].contains(index(of: .unread)) {
            labels[j].insert(index(of: .unread))
            extraUnread -= 1
        }
        for k in 0..<spec.important { labels[ordinary[(k * 7) % ordinary.count]].insert(index(of: .important)) }
        for k in 0..<spec.starred { labels[ordinary[(k * 13 + 5) % ordinary.count]].insert(index(of: .starred)) }
        // User labels, the largest first, as a migrated mailbox's folders are: a few big ones and
        // a long tail.
        var weights = (0..<spec.userLabels).map { 1.0 / Double($0 + 1) }
        let sum = weights.reduce(0, +)
        weights = weights.map { $0 / sum }
        var assigned = 0
        for label in 0..<spec.userLabels {
            let id = GmailLabelID("Label_\(label + 1)")
            userNames[id] = label % 5 == 4 ? "Clients/Client \(label + 1)" : "Folder \(label + 1)"
            let slot = index(of: id)
            let count = label == spec.userLabels - 1 ? spec.labelled - assigned : max(1, Int(Double(spec.labelled) * weights[label]))
            for k in 0..<count { labels[ordinary[(assigned + k) * 31 % ordinary.count]].insert(slot) }
            assigned += count
        }
        for j in 0..<n {
            let date = now.addingTimeInterval(-(Double(j) + 0.5) / Double(n) * span)
            let ref = GmailRef(id: GmailMessageID(raw: ids[j]), threadID: GmailThreadID(raw: threadOf[j]))
            store[ids[j]] = Message(ref: ref, date: date, labels: labels[j], size: 2_000 + rng.next(60_000), sender: rng.next(400),
                                    historyID: current)
            threads[threadOf[j], default: []].append(ids[j])
        }
    }

    // MARK: - Changing it, as other devices and apps do

    @discardableResult
    func add(date: Date, labels: Set<GmailLabelID> = [.inbox, .unread], thread: GmailThreadID? = nil, size: Int = 5_000,
             recordHistory: Bool = true) -> GmailRef {
        lock.withLock {
            nextID += 0x10
            let ref = GmailRef(id: GmailMessageID(raw: nextID), threadID: thread ?? GmailThreadID(raw: nextID))
            let slots = Set(labels.map { index(of: $0) })
            let history = recordHistory ? bump() : current
            let message = Message(ref: ref, date: date, labels: slots, size: size, sender: Int(nextID % 400), historyID: history)
            store[ref.id.raw] = message
            threads[ref.threadID.raw, default: []].append(ref.id.raw)
            // Kept in order rather than sorted again, so a long import stays quick to list.
            if var all = allSorted {
                allSorted = nil
                let at = lowerBound(all) { other in
                    let o = self.store[other]!
                    return (o.date, o.ref.id) < (message.date, message.ref.id)
                }
                all.insert(ref.id.raw, at: at)
                allSorted = all
            }
            sortedCache = [:]
            countsCache = nil
            labelLists = nil
            if recordHistory {
                log.append(GmailHistoryRecord(id: history, messagesAdded: [GmailHistoryMessage(ref: ref, labels: labels.sorted())]))
            }
            return ref
        }
    }

    /// Another app, such as olm2cloud, imports `count` messages dated between `from` and `to`.
    @discardableResult
    func importFromOtherApp(count: Int, datedFrom from: Date, to: Date, labels: Set<GmailLabelID>) -> [GmailRef] {
        (0..<count).map { k in
            let date = from.addingTimeInterval(to.timeIntervalSince(from) * Double(k) / Double(max(1, count)))
            return add(date: date, labels: labels)
        }
    }

    func delete(_ id: GmailMessageID) {
        lock.withLock {
            guard let m = store.removeValue(forKey: id.raw) else { return }
            threads[m.ref.threadID.raw]?.removeAll { $0 == id.raw }
            invalidate()
            log.append(GmailHistoryRecord(id: bump(), messagesDeleted: [GmailHistoryMessage(ref: m.ref, labels: labelNames(m.labels))]))
        }
    }

    func relabel(_ id: GmailMessageID, adding: Set<GmailLabelID> = [], removing: Set<GmailLabelID> = []) {
        lock.withLock {
            guard var m = store[id.raw] else { return }
            let add = Set(adding.map { index(of: $0) }).subtracting(m.labels)
            let remove = Set(removing.map { index(of: $0) }).intersection(m.labels).subtracting(add)
            guard !add.isEmpty || !remove.isEmpty else { return }
            m.labels.formUnion(add)
            m.labels.subtract(remove)
            m.historyID = bump()
            store[id.raw] = m
            invalidate()
            let message = GmailHistoryMessage(ref: m.ref, labels: labelNames(m.labels))
            log.append(GmailHistoryRecord(id: m.historyID,
                                          labelsAdded: add.isEmpty ? [] : [GmailLabelChange(message: message, labels: labelNames(add))],
                                          labelsRemoved: remove.isEmpty ? [] : [GmailLabelChange(message: message, labels: labelNames(remove))]))
        }
    }

    @discardableResult
    func addUserLabel(named name: String) -> GmailLabelID {
        lock.withLock {
            let id = GmailLabelID("Label_\(userNames.count + 1_000)")
            userNames[id] = name
            _ = index(of: id)
            return id
        }
    }

    func expireHistory() { lock.withLock { floor = current } }
    func fail(_ method: GmailMethod, with error: GoogleAPIError, times: Int = 1) {
        lock.withLock { for _ in 0..<times { faults.append((method, error)) } }
    }

    // MARK: - Looking at it

    var historyID: HistoryID { lock.withLock { current } }
    var units: [GmailMethod: Int] { lock.withLock { _units } }
    var calls: [GmailMethod: Int] { lock.withLock { _calls } }
    var totalUnits: Int { units.values.reduce(0, +) }
    var count: Int { lock.withLock { store.count } }
    var isFloodMode: Bool { lock.withLock { _floodMode } }
    func labels(of id: GmailMessageID) -> Set<GmailLabelID>? { lock.withLock { store[id.raw].map { Set(labelNames($0.labels)) } } }
    var ids: Set<UInt64> { lock.withLock { Set(store.keys) } }
    func members(of label: GmailLabelID) -> Set<UInt64> {
        lock.withLock {
            guard let slot = labelIndex[label] else { return [] }
            return Set(store.values.filter { $0.labels.contains(slot) }.map(\.ref.id.raw))
        }
    }
    var userLabelIDs: [GmailLabelID] { lock.withLock { userNames.keys.sorted() } }
    /// Every message, newest first, as Gmail lists All Mail.
    var newestFirst: [GmailRef] { lock.withLock { sortedAll().map { store[$0]!.ref } } }

    // MARK: - GmailTransport

    func profile(work: WorkClass) async throws -> GmailProfile {
        try lock.withLock {
            try begin(.profile)
            return GmailProfile(emailAddress: email, messagesTotal: store.count, threadsTotal: threads.values.filter { !$0.isEmpty }.count,
                                historyId: current.description)
        }
    }

    func labels(work: WorkClass) async throws -> [GmailLabel] {
        try lock.withLock {
            try begin(.labelsList)
            let system = GmailLabelID.fixedSlots.map { GmailLabel(id: $0.value, name: $0.value, type: "system") }
            let user = userNames.sorted { $0.key < $1.key }.map {
                GmailLabel(id: $0.key.value, name: $0.value, type: "user", labelListVisibility: "labelShow", messageListVisibility: "show")
            }
            return system + user
        }
    }

    func label(_ id: GmailLabelID, work: WorkClass) async throws -> GmailLabel {
        try lock.withLock {
            try begin(.labelsGet)
            return try labelAnswer(id)
        }
    }

    func createLabel(named name: String, work: WorkClass) async throws -> GmailLabel {
        throw GoogleAPIError(kind: .other, httpStatus: 400, detail: "not in this fixture")
    }

    func sendAs(work: WorkClass) async throws -> [GmailSendAs] {
        try lock.withLock {
            try begin(.sendAsList)
            return [GmailSendAs(sendAsEmail: email, isPrimary: true)]
        }
    }

    func list(_ query: GmailListQuery, work: WorkClass) async throws -> GmailListPage {
        try lock.withLock {
            try begin(.messagesList)
            var after: TimeInterval?
            var before: TimeInterval?
            for term in (query.query ?? "").split(separator: " ") {
                if term.hasPrefix("after:") { after = TimeInterval(term.dropFirst(6)) }
                if term.hasPrefix("before:") { before = TimeInterval(term.dropFirst(7)) }
            }
            let spamTrash = query.includeSpamTrash || query.labels.contains(.spam) || query.labels.contains(.trash)
            let offset = Int(query.pageToken ?? "") ?? 0
            let limit = max(1, min(500, query.maxResults))
            var hits: [UInt64] = []
            var total = 0
            if query.labels.isEmpty {
                // Straight from the date order: a search by date needs no list of its own.
                let all = sortedAll()
                var start = 0
                if let before { start = lowerBound(all) { self.store[$0]!.date.timeIntervalSince1970 < before } }
                var skipped = 0
                var index = start
                if spamTrash {
                    // Nothing is left out, so the page begins exactly `offset` messages on.
                    index = min(all.count, start + offset)
                    skipped = offset
                }
                while index < all.count, hits.count < limit {
                    let m = store[all[index]]!
                    index += 1
                    if let after, m.date.timeIntervalSince1970 < after { break }
                    if !spamTrash, m.labels.contains(labelIndex[.spam]!) || m.labels.contains(labelIndex[.trash]!) { continue }
                    if skipped < offset { skipped += 1; continue }
                    hits.append(m.ref.id.raw)
                }
                let more = index < all.count && (after.map { store[all[index]]!.date.timeIntervalSince1970 >= $0 } ?? true)
                total = offset + hits.count + (more ? 1 : 0)
                let next = more && hits.count == limit ? String(offset + hits.count) : nil
                return GmailListPage(refs: hits.map { store[$0]!.ref }, nextPageToken: next, resultSizeEstimate: total)
            }
            let key = query.labels.map(\.value).sorted().joined(separator: "+") + (spamTrash ? "#st" : "") + "|\(after ?? -1)|\(before ?? -1)"
            let list: [UInt64]
            if let cached = sortedCache[key] {
                list = cached
            } else {
                let wanted = query.labels.map { labelIndex[$0] ?? UInt16.max }
                // Every label's members in one pass, newest first, so listing 150 labels of a
                // migrated mailbox does not go through all 200,000 messages 150 times.
                if labelLists == nil {
                    var lists: [UInt16: [UInt64]] = [:]
                    for raw in sortedAll() { for label in store[raw]!.labels { lists[label, default: []].append(raw) } }
                    labelLists = lists
                }
                let smallest = wanted.min { (labelLists?[$0]?.count ?? 0) < (labelLists?[$1]?.count ?? 0) } ?? UInt16.max
                list = (labelLists?[smallest] ?? []).filter { raw in
                    let m = store[raw]!
                    guard wanted.allSatisfy(m.labels.contains) else { return false }
                    if !spamTrash, m.labels.contains(labelIndex[.spam]!) || m.labels.contains(labelIndex[.trash]!) { return false }
                    if let after, m.date.timeIntervalSince1970 < after { return false }
                    if let before, m.date.timeIntervalSince1970 >= before { return false }
                    return true
                }
                sortedCache[key] = list
            }
            let page = list.dropFirst(offset).prefix(limit)
            let next = offset + page.count < list.count ? String(offset + page.count) : nil
            return GmailListPage(refs: page.map { store[$0]!.ref }, nextPageToken: next, resultSizeEstimate: list.count)
        }
    }

    func history(since start: HistoryID, types: Set<GmailHistoryType>, label: GmailLabelID?, pageToken: String?,
                 work: WorkClass) async throws -> GmailHistoryPage {
        try lock.withLock {
            try begin(.historyList)
            guard start >= floor else {
                throw GoogleAPIError(kind: .historyExpired, httpStatus: 404, reason: "notFound", detail: "Requested entity was not found.")
            }
            let from = lowerBound(log) { $0.id > start }
            let records = log[from...].filter { $0.id > start }
            let offset = Int(pageToken ?? "") ?? 0
            let page = Array(records.dropFirst(offset).prefix(500))
            let next = offset + page.count < records.count ? String(offset + page.count) : nil
            return GmailHistoryPage(records: page, nextPageToken: next, historyID: current)
        }
    }

    func message(_ id: GmailMessageID, format: GmailFormat, work: WorkClass) async throws -> GmailMessage {
        try lock.withLock {
            try begin(.messagesGet)
            guard let m = store[id.raw] else { throw MemoryGmailTransport.notFound }
            return answer(m, format)
        }
    }

    func thread(_ id: GmailThreadID, format: GmailFormat, work: WorkClass) async throws -> GmailThread {
        try lock.withLock {
            try begin(.threadsGet)
            return try threadAnswer(id, format)
        }
    }

    func batch(_ parts: [GmailBatchPart], work: WorkClass) async throws -> [GmailBatchPart: Result<GmailBatchAnswer, GoogleAPIError>] {
        lock.withLock {
            var out: [GmailBatchPart: Result<GmailBatchAnswer, GoogleAPIError>] = [:]
            for part in parts {
                do {
                    try begin(part.method)
                    switch part {
                    case .message(let id, let format):
                        guard let m = store[id.raw] else { throw MemoryGmailTransport.notFound }
                        out[part] = .success(.message(answer(m, format)))
                    case .thread(let id, let format):
                        out[part] = .success(.thread(try threadAnswer(id, format)))
                    case .label(let id):
                        out[part] = .success(.label(try labelAnswer(id)))
                    }
                } catch let error as GoogleAPIError {
                    out[part] = .failure(error)
                } catch {
                    out[part] = .failure(GoogleAPIError(kind: .other))
                }
            }
            return out
        }
    }

    func attachment(_ attachmentID: String, of message: GmailMessageID, work: WorkClass) async throws -> Data {
        try lock.withLock { try begin(.attachmentsGet) }
        return Data("picture".utf8)
    }

    func modify(_ id: GmailMessageID, adding: Set<GmailLabelID>, removing: Set<GmailLabelID>, work: WorkClass) async throws -> GmailMessage {
        relabel(id, adding: adding, removing: removing)
        return try await message(id, format: .minimal, work: work)
    }

    func batchModify(_ ids: [GmailMessageID], adding: Set<GmailLabelID>, removing: Set<GmailLabelID>, work: WorkClass) async throws {
        for id in ids { relabel(id, adding: adding, removing: removing) }
    }

    func batchDelete(_ ids: [GmailMessageID], work: WorkClass) async throws { for id in ids { delete(id) } }
    func trash(_ id: GmailMessageID, work: WorkClass) async throws -> GmailMessage { try await modify(id, adding: [.trash], removing: [], work: work) }
    func untrash(_ id: GmailMessageID, work: WorkClass) async throws -> GmailMessage { try await modify(id, adding: [], removing: [.trash], work: work) }
    func send(_ raw: Data, threadID: GmailThreadID?, work: WorkClass) async throws -> GmailMessage { throw GoogleAPIError(kind: .other) }
    func importMessage(_ raw: Data, labels: Set<GmailLabelID>, options: GmailImportOptions, work: WorkClass) async throws -> GmailMessage {
        throw GoogleAPIError(kind: .other)
    }
    func createDraft(_ raw: Data, threadID: GmailThreadID?, work: WorkClass) async throws -> GmailDraft { throw GoogleAPIError(kind: .other) }
    func updateDraft(_ draftID: String, raw: Data, threadID: GmailThreadID?, work: WorkClass) async throws -> GmailDraft {
        throw GoogleAPIError(kind: .other)
    }
    func deleteDraft(_ draftID: String, work: WorkClass) async throws { throw GoogleAPIError(kind: .other) }
    func drafts(pageToken: String?, work: WorkClass) async throws -> GmailDraftList { GmailDraftList() }

    func setFloodMode(_ on: Bool) async { lock.withLock { _floodMode = on } }
    func noteOwnerActivity(at date: Date) async {}
    func pause() async -> GmailPause? { nil }
    func usage() async -> GmailUsage { lock.withLock { GmailUsage(units: _units, calls: _calls) } }

    // MARK: - Inside the lock

    private func begin(_ method: GmailMethod) throws {
        if let i = faults.firstIndex(where: { $0.method == method }) { throw faults.remove(at: i).error }
        _units[method, default: 0] += method.units
        _calls[method, default: 0] += 1
    }

    private func index(of label: GmailLabelID) -> UInt16 {
        if let found = labelIndex[label] { return found }
        let next = UInt16(labelIDs.count)
        labelIDs.append(label)
        labelIndex[label] = next
        return next
    }

    private func labelNames(_ slots: Set<UInt16>) -> [GmailLabelID] { slots.map { labelIDs[Int($0)] }.sorted() }

    private func bump() -> HistoryID {
        current = HistoryID(raw: current.raw + 1)
        return current
    }

    private func invalidate() {
        allSorted = nil
        sortedCache = [:]
        countsCache = nil
        labelLists = nil
    }

    private func sortedAll() -> [UInt64] {
        if let allSorted { return allSorted }
        let sorted = store.values.sorted { ($0.date, $0.ref.id) > ($1.date, $1.ref.id) }.map(\.ref.id.raw)
        allSorted = sorted
        return sorted
    }

    private func lowerBound<T>(_ array: [T], _ isBefore: (T) -> Bool) -> Int {
        var low = 0
        var high = array.count
        while low < high {
            let mid = (low + high) / 2
            if isBefore(array[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }

    private func labelAnswer(_ id: GmailLabelID) throws -> GmailLabel {
        guard let slot = labelIndex[id], id.fixedSlot != nil || userNames[id] != nil else { throw MemoryGmailTransport.notFound }
        if countsCache == nil {
            let unreadSlot = labelIndex[.unread]!
            var counts: [UInt16: (total: Int, unread: Int)] = [:]
            for m in store.values {
                let unread = m.labels.contains(unreadSlot)
                for label in m.labels { counts[label, default: (0, 0)].total += 1; if unread { counts[label, default: (0, 0)].unread += 1 } }
            }
            countsCache = counts
        }
        let total = countsCache?[slot]?.total ?? 0
        let unread = countsCache?[slot]?.unread ?? 0
        return GmailLabel(id: id.value, name: userNames[id] ?? id.value, type: userNames[id] == nil ? "system" : "user",
                          labelListVisibility: userNames[id] == nil ? nil : "labelShow", messageListVisibility: nil,
                          messagesTotal: total, messagesUnread: unread)
    }

    private func headers(_ m: Message) -> [GmailHeader] {
        [GmailHeader(name: "From", value: "Sender \(m.sender) <sender\(m.sender)@example.com>"),
         GmailHeader(name: "To", value: email),
         GmailHeader(name: "Subject", value: "Message \(m.ref.id.hex)"),
         GmailHeader(name: "Date", value: RFC5322Date.format(m.date)),
         GmailHeader(name: "Message-ID", value: "<\(m.ref.id.hex)@fixture.example>")]
    }

    private func answer(_ m: Message, _ format: GmailFormat) -> GmailMessage {
        var out = GmailMessage(id: m.ref.id.hex, threadId: m.ref.threadID.hex, labelIds: labelNames(m.labels).map(\.value),
                               historyId: m.historyID.description, internalDate: String(Int64(m.date.timeIntervalSince1970 * 1000)),
                               sizeEstimate: m.size)
        switch format {
        case .minimal:
            break
        case .metadata:
            out.snippet = "Text of \(m.ref.id.hex)"
            out.payload = GmailPart(partId: "", mimeType: "text/plain", filename: "", headers: headers(m))
        case .full:
            out.snippet = "Text of \(m.ref.id.hex)"
            let text = Data("Text of \(m.ref.id.hex)".utf8)
            out.payload = GmailPart(partId: "", mimeType: "text/plain", filename: "",
                                    headers: headers(m) + [GmailHeader(name: "Content-Type", value: "text/plain; charset=UTF-8")],
                                    body: GmailPartBody(size: text.count, data: text.base64URL))
        case .raw:
            let head = headers(m).map { "\($0.name): \($0.value)" }.joined(separator: "\r\n")
            out.raw = Data((head + "\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\nText").utf8).base64URL
        }
        return out
    }

    private func threadAnswer(_ id: GmailThreadID, _ format: GmailFormat) throws -> GmailThread {
        let members = (threads[id.raw] ?? []).compactMap { store[$0] }.sorted { ($0.date, $0.ref.id) < ($1.date, $1.ref.id) }
        guard let newest = members.last else { throw MemoryGmailTransport.notFound }
        return GmailThread(id: id.hex, historyId: newest.historyID.description, messages: members.map { answer($0, format) })
    }
}

/// A small, fast generator, so a fixture is the same on every run.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func next(_ bound: Int) -> Int { Int(next() % UInt64(max(1, bound))) }
}
