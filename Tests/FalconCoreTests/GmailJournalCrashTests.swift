import XCTest
@testable import FalconCore

/// A crash at any moment loses nothing: the store is stopped before each of its writes, and before
/// half of each append, in a run of backfill, checks, a resync, compaction and the cache, and what
/// was on disk at that moment is launched again and brought up to date against the mailbox. Every
/// time, the index ends up as the mailbox is, with no deletion and no label change missing.
final class GmailJournalCrashTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    private func temporaryDirectory(_ name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        directories.append(directory)
        return directory
    }

    private static let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func ref(_ n: UInt64) -> GmailRef {
        GmailRef(id: GmailMessageID(raw: 0x18a0_0000_0000_0000 + n), threadID: GmailThreadID(raw: 0x18a0_0000_0000_0000 + n))
    }

    private func place(_ n: UInt64) -> GmailChange {
        .place(ref(n), order: UInt32(n) * 16, labels: [.inbox], attributes: [])
    }

    private func reopen(_ store: GmailFileStore) -> GmailFileStore {
        GmailFileStore(accountID: store.accountID, files: store.files)
    }

    // MARK: - Cut at any byte

    func testChangeRecordsCountOnlyUpToTheirCommitAndPagesCountOnTheirOwn() async throws {
        let files = GmailFiles(directory: temporaryDirectory("GmailJournalCrashTests").appendingPathComponent("Gmail"))
        let store = GmailFileStore(accountID: UUID(), files: files)
        try await store.commit(GmailJournalBatch(changes: [place(1), place(2)], cursor: HistoryID(raw: 10)))
        let afterFirst = try Data(contentsOf: files.indexJournal).count
        try await store.appendListingPage(GmailListingPage(chain: .label(.starred), refs: [ref(1)], labels: [.starred]))
        let afterPage = try Data(contentsOf: files.indexJournal).count
        try await store.commit(GmailJournalBatch(changes: [place(3), .tombstone(ref(2).id)], cursor: HistoryID(raw: 12)))
        let whole = try Data(contentsOf: files.indexJournal)

        // Cut the last batch just before its commit record: none of it counts, and the page before
        // it still does.
        let commitRecord = GmailJournalCodec.frame(.commit, { var w = GmailBinaryWriter(); w.optional(HistoryID(raw: 12)) { $0.u64($1.raw) }; return w.data }())
        let cut = whole.prefix(whole.count - commitRecord.count)
        try cut.write(to: files.indexJournal)
        var load = try await reopen(store).load()
        XCTAssertEqual(load.cursor, HistoryID(raw: 10))
        XCTAssertEqual(load.messageCount, 2, "the half-written check is dropped whole")
        var labels = await reopen(store).labels(of: ref(1).id)
        XCTAssertEqual(labels, [.inbox, .starred], "a page counts without a cursor")
        XCTAssertEqual(try Data(contentsOf: files.indexJournal).count, afterPage, "what a crash left is cut off at launch")

        // Every cut inside the page loses the page and nothing before it.
        for length in stride(from: afterFirst + 1, to: afterPage, by: 7) {
            try whole.prefix(length).write(to: files.indexJournal)
            let reopened = reopen(store)
            load = try await reopened.load()
            XCTAssertEqual(load.cursor, HistoryID(raw: 10), "cut at \(length)")
            labels = await reopened.labels(of: ref(1).id)
            XCTAssertEqual(labels, [.inbox], "cut at \(length)")
            XCTAssertEqual(try Data(contentsOf: files.indexJournal).count, afterFirst)
        }

        // Appending after a cut follows the last whole unit.
        try whole.prefix(afterPage + 5).write(to: files.indexJournal)
        let resumed = reopen(store)
        _ = try await resumed.load()
        try await resumed.commit(GmailJournalBatch(changes: [place(4)], cursor: HistoryID(raw: 13)))
        load = try await reopen(store).load()
        XCTAssertEqual(load.cursor, HistoryID(raw: 13))
        XCTAssertEqual(load.messageCount, 3)
    }

    // MARK: - Stopped before any write

    /// Backfill, checks with new mail, reads, stars, deletions and draft autosaves, a compaction,
    /// and the cache filling and letting go, with no history expiring: recovery rests on the
    /// cursor and the journal alone.
    func testKilledBetweenAnyTwoWritesOfChecksListingsAndCompactionItConverges() async throws {
        try await runScenario(expiring: false)
    }

    /// The same, with Gmail's history expiring once: the resync's own writes are stopped at too.
    func testKilledBetweenAnyTwoWritesOfAResyncItConverges() async throws {
        try await runScenario(expiring: true)
    }

    private func runScenario(expiring: Bool) async throws {
        continueAfterFailure = false
        let gmail = MemoryGmailTransport()
        let clients = gmail.addUserLabel(named: "Clients")
        let customs = gmail.addUserLabel(named: "Clients/Customs")
        var generator = GmailStoreRandom(seed: expiring ? 7 : 3)
        let choices: [Set<GmailLabelID>] = [[.inbox, .unread], [.inbox], [.inbox, .starred], [.sent], [clients], [clients, customs, .unread],
                                             [.spam], [.trash, clients], [.inbox, .categoryPromotions], [], [.draft]]
        for n in 0..<90 {
            let date = GmailJournalCrashTests.start.addingTimeInterval(-Double(90 - n) * 60)
            let thread = n % 3 == 2 ? gmail.messages.last?.ref.threadID : nil
            gmail.add(subject: "Mail \(n)", labels: choices.randomElement(using: &generator)!, date: date, thread: thread, recordHistory: false)
        }

        let root = temporaryDirectory("GmailJournalCrashTests")
        let files = GmailFiles(directory: root.appendingPathComponent("live/Gmail", isDirectory: true))
        let recorder = CrashRecorder(files: files, root: root.appendingPathComponent("crashes", isDirectory: true))
        let io = GmailDiskIO()
        io.beforeWrite = { recorder.capture($0) }
        var limits = GmailFileStore.Limits()
        limits.cacheLimit = 8
        limits.cacheCeiling = 10
        let store = GmailFileStore(accountID: gmail.accountID, files: files, limits: limits, io: io)
        let driver = StoreDriver(store: store, gmail: gmail, userLabels: [clients, customs])

        // The first load and the first check.
        try await driver.converge()
        try await assertMatches(store, gmail, "after the backfill")

        var minute = 0.0
        func arrive(_ labels: Set<GmailLabelID>) -> GmailRef {
            minute += 1
            return gmail.add(subject: "New \(minute)", labels: labels, date: GmailJournalCrashTests.start.addingTimeInterval(minute * 60))
        }
        func someone(_ label: GmailLabelID? = nil) -> GmailMessageID {
            let candidates = gmail.messages.filter { label.map($0.labels.contains) ?? true }
            return (candidates.isEmpty ? gmail.messages : candidates).randomElement(using: &generator)!.ref.id
        }

        // Keep a few messages, with bodies, and a summary.
        for id in await store.messagesToCache(limit: 6) {
            try await store.cache(driver.cachedRow(id), body: GmailReducedBody(textPlain: "Body of \(id)", textHTML: nil))
        }

        // New mail, reading, starring, a deletion, and draft autosaves that come and go.
        _ = arrive([.inbox, .unread])
        _ = arrive([.inbox, .unread, clients])
        gmail.relabel(someone(.unread), removing: [.unread])
        gmail.relabel(someone(.inbox), adding: [.starred])
        gmail.relabel(someone(clients), adding: [customs], removing: [clients])
        gmail.delete(someone(.inbox))
        let draft = arrive([.draft])
        gmail.delete(draft.id)
        _ = arrive([.draft])
        try await driver.converge()
        try await assertMatches(store, gmail, "after the first check")

        try await store.compact()
        for id in await store.messagesToCache(limit: 10) {
            try await store.cache(driver.cachedRow(id), body: nil)
        }
        try await store.noteImported([someone()], at: GmailJournalCrashTests.start)

        if expiring { gmail.expireHistory() }
        _ = arrive([.inbox])
        gmail.relabel(someone(.inbox), removing: [.inbox])
        gmail.relabel(someone(), adding: [.trash])
        gmail.delete(someone(.sent))
        let cachedGone = await store.cachedIDs().first
        if let cachedGone { gmail.delete(cachedGone) }
        _ = arrive([.inbox, .categoryPromotions, .unread])
        try await driver.converge()
        try await assertMatches(store, gmail, "after the second check")

        _ = arrive([.inbox, .unread])
        gmail.relabel(someone(.unread), removing: [.unread])
        gmail.relabel(someone(customs), removing: [customs])
        try await driver.converge()
        try await store.uncache(Array(await store.cachedIDs().prefix(2)))
        try await assertMatches(store, gmail, "at the end")

        // Every moment the store could have been stopped at.
        let states = recorder.states
        XCTAssertGreaterThan(states.count, expiring ? 60 : 50, "stopped before every write")
        print("GmailJournalCrashTests: \(states.count) moments to stop at, \(recorder.writes) writes")
        for (i, state) in states.enumerated() {
            let recovered = GmailFileStore(accountID: gmail.accountID, files: GmailFiles(directory: state.directory), limits: limits)
            let recovery = StoreDriver(store: recovered, gmail: gmail, userLabels: [clients, customs])
            do {
                try await recovery.converge()
            } catch {
                XCTFail("could not recover from moment \(i), \(state.what): \(error)")
                return
            }
            try await assertMatches(recovered, gmail, "recovered from moment \(i), \(state.what)")
            // And what the recovery saved reads back as it left it.
            let again = GmailFileStore(accountID: gmail.accountID, files: GmailFiles(directory: state.directory), limits: limits)
            try await assertMatches(again, gmail, "relaunched after recovering from moment \(i), \(state.what)")
        }
    }

    // MARK: - Checking

    private func assertMatches(_ store: GmailFileStore, _ gmail: MemoryGmailTransport, _ when: String,
                               file: StaticString = #filePath, line: UInt = #line) async throws {
        let load = try await store.load()
        XCTAssertNil(load.resyncBegan, "\(when): no resync left open", file: file, line: line)
        XCTAssertEqual(load.cursor, gmail.historyID, "\(when): the cursor is Gmail's", file: file, line: line)
        let index = await store.index()
        let tracked = Set(index.labelSlots.keys).union(index.overflow.keys)
        let mailbox = gmail.messages.sorted { ($0.date, $0.ref.id) < ($1.date, $1.ref.id) }
        let ordered = index.byOrder.map { index.records[Int($0)].gmailID }
        XCTAssertEqual(ordered, mailbox.map(\.ref.id), "\(when): every message, and none gone, in Gmail's order", file: file, line: line)
        XCTAssertEqual(load.messageCount, mailbox.count, file: file, line: line)
        for message in mailbox {
            let labels = await store.labels(of: message.ref.id)
            XCTAssertEqual(labels, message.labels.intersection(tracked), "\(when): labels of \(message.ref.id)", file: file, line: line)
            XCTAssertEqual(index.record(for: message.ref.id)?.threadID, message.ref.threadID.raw, file: file, line: line)
        }
        // The cache holds only live messages, the index knows which, and summaries go with them.
        let cached = await store.cachedIDs()
        XCTAssertTrue(cached.allSatisfy { gmail.message($0) != nil }, "\(when): nothing deleted is kept", file: file, line: line)
        for record in index.records where !record.attributes.contains(.tombstone) {
            XCTAssertEqual(record.attributes.contains(.cached), cached.contains(record.gmailID), "\(when): cached bit", file: file, line: line)
        }
        let bodies = (try? FileManager.default.contentsOfDirectory(atPath: store.files.bodiesDirectory.path)) ?? []
        for name in bodies {
            let id = GmailMessageID(hex: String(name.dropLast(6)))
            XCTAssertTrue(id.map(cached.contains) ?? false, "\(when): no body without its row", file: file, line: line)
        }
        let threads = Array(Set(index.records.map(\.gmailThreadID)))
        let summaries = await store.threadSummaries(threads)
        let keptThreads = Set(await store.cachedMessages(Array(cached)).values.map(\.threadID))
        XCTAssertTrue(Set(summaries.keys).isSubset(of: keptThreads), "\(when): summaries only for kept conversations", file: file, line: line)
    }
}

// MARK: - Stopping the world

/// Copies the account's folder as it is before each write, and for an append also as it would
/// be had the process died half-way through it.
final class CrashRecorder: @unchecked Sendable {
    struct State {
        var directory: URL
        var what: String
    }

    let files: GmailFiles
    let root: URL
    private(set) var states: [State] = []
    private(set) var writes = 0

    init(files: GmailFiles, root: URL) {
        self.files = files
        self.root = root
    }

    func capture(_ write: GmailDiskIO.Write) {
        writes += 1
        let n = writes
        switch write {
        case .append(let url, let data):
            copy(as: "\(n)", what: "before appending to \(url.lastPathComponent)")
            if data.count > 1, let torn = copy(as: "\(n)-torn", what: "half-way through appending to \(url.lastPathComponent)") {
                let target = torn.appendingPathComponent(relative(url))
                if let handle = try? FileHandle(forWritingTo: target) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data.prefix(data.count / 2))
                    try? handle.close()
                } else {
                    try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.prefix(data.count / 2).write(to: target)
                }
            }
        case .replace(let url, let data):
            if let copied = copy(as: "\(n)", what: "before replacing \(url.lastPathComponent)") {
                // The new file was written to its temporary name and not yet renamed.
                let target = copied.appendingPathComponent(relative(url))
                let stray = target.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).crash.tmp")
                try? FileManager.default.createDirectory(at: stray.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: stray)
            }
        case .remove(let url):
            copy(as: "\(n)", what: "before removing \(url.lastPathComponent)")
        case .truncate(let url, _):
            copy(as: "\(n)", what: "before cutting \(url.lastPathComponent)")
        }
    }

    private func relative(_ url: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(files.directory.standardizedFileURL.path.count + 1))
    }

    @discardableResult
    private func copy(as name: String, what: String) -> URL? {
        let destination = root.appendingPathComponent(name, isDirectory: true).appendingPathComponent("Gmail", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: files.directory.path) {
                try FileManager.default.copyItem(at: files.directory, to: destination)
            } else {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            }
        } catch {
            return nil
        }
        states.append(State(directory: destination, what: what))
        return destination
    }
}

// MARK: - A small engine

/// Just enough of the engine to drive the store as the design describes, so the store can be
/// shown to converge after a crash: the first load, listings that resume where they stopped,
/// checks that apply the history since the cursor, and a resync when the history has expired.
/// It does no count check and never lists again unless the history has expired, so any change
/// the store lost would show.
///
/// Listings resume by the last message listed, not by Gmail's page token, which the in-memory
/// mailbox counts in messages: resumed against a mailbox that has changed since, a count would
/// skip messages, as Gmail's tokens can, and only the engine's count check repairs that.
final class StoreDriver {
    let store: GmailFileStore
    let gmail: MemoryGmailTransport
    let userLabels: [GmailLabelID]
    static let pageSize = 25
    /// All Mail's listing counts down from here, as it would for a mailbox of 1,000 messages;
    /// mail placed on top counts up from `topOrder`.
    static let listingTop: UInt32 = 1_000 * 16
    static let topOrder: UInt32 = 2_000 * 16

    init(store: GmailFileStore, gmail: MemoryGmailTransport, userLabels: [GmailLabelID]) {
        self.store = store
        self.gmail = gmail
        self.userLabels = userLabels
    }

    /// As the design lists them: All Mail, the system labels, the Inbox with each category that
    /// is not Primary, and the user labels.
    var chains: [GmailListingChain] {
        [.allMail(after: nil, before: nil)] + ([.inbox, .sent, .draft, .spam, .trash, .unread, .starred] + userLabels).map { .label($0) }
            + [GmailLabelID.categorySocial, .categoryPromotions, .categoryUpdates, .categoryForums].map { .labels([.inbox, $0]) }
    }

    func converge() async throws {
        var load = try await store.load()
        if load.cursor == nil, load.resyncBegan == nil {
            try await saveLabels()
            let profile = try await gmail.profile(work: .checks)
            try await store.commit(GmailJournalBatch(changes: [], cursor: profile.historyID))
            load = try await store.load()
        }
        if let began = load.resyncBegan {
            try await resync(at: began)
        } else {
            try await finishListings(load)
        }
        try await placeWaiting()
        try await check()
    }

    private func saveLabels() async throws {
        let labels = try await gmail.labels(work: .checks)
        try await store.saveLabelTable(labels.map { label in
            GmailLabelEntry(id: label.labelID, name: label.name, kind: label.isUserLabel ? .user : .system,
                            labelListVisibility: label.labelListVisibility, isShown: true,
                            folderID: GmailLabelTable.folderID(account: gmail.accountID, label: label.labelID))
        })
    }

    // MARK: Listing

    private func finishListings(_ load: GmailStoreLoad) async throws {
        for chain in chains {
            let progress = load.chains[chain]
            if progress?.isComplete == true { continue }
            _ = try await list(chain, run: progress?.run ?? 0, after: progress?.nextPageToken)
        }
    }

    /// Lists one chain from where it stopped, page by page, and returns every id it listed.
    private func list(_ chain: GmailListingChain, run: UInt32, after token: String?) async throws -> Set<GmailMessageID> {
        let everything = try await all(chain)
        var remaining = everything
        var order = StoreDriver.listingTop
        if let token {
            let (date, id, last) = StoreDriver.parse(token)
            remaining = everything.filter { m in
                let key = (gmail.message(m.id)?.date ?? .distantPast, m.id)
                return key < (date, id)
            }
            order = last - 16
        }
        var listed = Set<GmailMessageID>()
        var pageToken = token
        repeat {
            let refs = Array(remaining.prefix(StoreDriver.pageSize))
            remaining.removeFirst(refs.count)
            let isAllMail: Bool = { if case .allMail = chain { return true } else { return false } }()
            let lastOrder = order - UInt32(max(0, refs.count - 1)) * 16
            let next = remaining.isEmpty ? nil : refs.last.map { StoreDriver.token(gmail.message($0.id)!.date, $0.id, lastOrder) }
            var labels: Set<GmailLabelID> = []
            if case .label(let label) = chain { labels = [label] }
            if case .labels(let all) = chain { labels = Set(all) }
            try await store.appendListingPage(GmailListingPage(chain: chain, run: run, pageToken: pageToken, nextPageToken: next, refs: refs,
                                                               firstOrder: isAllMail ? order : nil, labels: labels))
            listed.formUnion(refs.map(\.id))
            order = lastOrder - 16
            pageToken = next
        } while pageToken != nil
        return listed
    }

    /// The chain's messages newest first, as Gmail lists them.
    private func all(_ chain: GmailListingChain) async throws -> [GmailRef] {
        var labels: [GmailLabelID] = []
        if case .label(let label) = chain { labels = [label] }
        if case .labels(let all) = chain { labels = all }
        var out: [GmailRef] = []
        var token: String?
        repeat {
            let page = try await gmail.list(GmailListQuery(labels: labels, includeSpamTrash: true, maxResults: 500, pageToken: token), work: .checks)
            out += page.refs
            token = page.nextPageToken
        } while token != nil
        return out
    }

    private static func token(_ date: Date, _ id: GmailMessageID, _ order: UInt32) -> String {
        "\(date.timeIntervalSince1970):\(id.hex):\(order)"
    }

    private static func parse(_ token: String) -> (Date, GmailMessageID, UInt32) {
        let parts = token.split(separator: ":")
        return (Date(timeIntervalSince1970: Double(parts[0])!), GmailMessageID(hex: String(parts[1]))!, UInt32(parts[2])!)
    }

    // MARK: Checks

    private func topOrder(for id: GmailMessageID) -> UInt32 {
        let minutes = (gmail.message(id)?.date.timeIntervalSince(Date(timeIntervalSince1970: 1_790_000_000)) ?? 0) / 60
        return StoreDriver.topOrder + UInt32(max(0, minutes)) * 16
    }

    private func placeWaiting() async throws {
        let load = try await store.load()
        var changes: [GmailChange] = []
        for ref in load.awaitingPlacement {
            do {
                let answer = try await gmail.message(ref.id, format: .minimal, work: .checks)
                changes.append(.place(ref, order: topOrder(for: ref.id), labels: answer.labels, attributes: []))
            } catch let error as GoogleAPIError where error.kind == .notFound {
                changes.append(.tombstone(ref.id))
            }
        }
        if !changes.isEmpty { try await store.commit(GmailJournalBatch(changes: changes)) }
    }

    private func check() async throws {
        guard let cursor = try await store.load().cursor else { return }
        var records: [GmailHistoryRecord] = []
        var token: String?
        var latest = cursor
        do {
            repeat {
                let page = try await gmail.history(since: cursor, types: Set(GmailHistoryType.allCases), label: nil, pageToken: token, work: .checks)
                records += page.records
                token = page.nextPageToken
                latest = page.historyID
            } while token != nil
        } catch let error as GoogleAPIError where error.kind == .historyExpired {
            let profile = try await gmail.profile(work: .checks)
            try await store.commit(GmailJournalBatch(changes: [.resyncBegan(profile.historyID!)]))
            try await resync(at: profile.historyID!)
            try await check()
            return
        }
        let index = await store.index()
        let waiting = await store.pendingLabels()
        func known(_ id: GmailMessageID) -> Bool {
            (index.record(for: id).map { !$0.attributes.contains(.tombstone) } ?? false) || waiting[id] != nil
        }
        var changes: [GmailChange] = []
        var added: [GmailRef] = []
        for record in records {
            for m in record.messagesAdded where !known(m.ref.id) && !added.contains(m.ref) { added.append(m.ref) }
            for m in record.messagesDeleted {
                if let at = added.firstIndex(of: m.ref) { added.remove(at: at) } else { changes.append(.tombstone(m.ref.id)) }
            }
            for change in record.labelsAdded {
                if known(change.message.ref.id) {
                    changes.append(.relabel(change.message.ref.id, adding: Set(change.labels), removing: []))
                } else if !added.contains(change.message.ref), gmail.message(change.message.ref.id) != nil {
                    added.append(change.message.ref)
                }
            }
            for change in record.labelsRemoved {
                if known(change.message.ref.id) {
                    changes.append(.relabel(change.message.ref.id, adding: [], removing: Set(change.labels)))
                } else if !added.contains(change.message.ref), gmail.message(change.message.ref.id) != nil {
                    added.append(change.message.ref)
                }
            }
        }
        for ref in added {
            do {
                let answer = try await gmail.message(ref.id, format: .minimal, work: .checks)
                changes.append(.place(ref, order: topOrder(for: ref.id), labels: answer.labels, attributes: []))
            } catch let error as GoogleAPIError where error.kind == .notFound {
                changes.append(.tombstone(ref.id))
            }
        }
        try await store.commit(GmailJournalBatch(changes: changes, cursor: latest))
    }

    // MARK: Resync

    /// Lists everything again under new runs, removes only what Gmail confirms is gone, gives
    /// every label exactly its listing's members, and ends in one flush with the cursor at `began`.
    private func resync(at began: HistoryID) async throws {
        let load = try await store.load()
        var listed: [GmailListingChain: Set<GmailMessageID>] = [:]
        for chain in chains {
            listed[chain] = try await list(chain, run: (load.chains[chain]?.run ?? 0) + 1, after: nil)
        }
        let index = await store.index()
        var changes: [GmailChange] = []
        let all = listed[.allMail(after: nil, before: nil)] ?? []
        for slot in index.byOrder {
            let id = index.records[Int(slot)].gmailID
            guard !all.contains(id) else { continue }
            do {
                _ = try await gmail.message(id, format: .minimal, work: .checks)
            } catch let error as GoogleAPIError where error.kind == .notFound {
                changes.append(.tombstone(id))
            }
        }
        for chain in chains {
            guard case .label(let label) = chain, let members = listed[chain] else { continue }
            for slot in index.byOrder where index.record(atSlot: slot, has: label) {
                let id = index.records[Int(slot)].gmailID
                if !members.contains(id) { changes.append(.relabel(id, adding: [], removing: [label])) }
            }
        }
        // A category is listed only with the Inbox, so it leaves only messages still in it.
        for chain in chains {
            guard case .labels(let both) = chain, let category = both.last, let members = listed[chain] else { continue }
            for slot in index.byOrder where index.record(atSlot: slot, has: category) && index.record(atSlot: slot, has: .inbox) {
                let id = index.records[Int(slot)].gmailID
                if !members.contains(id) { changes.append(.relabel(id, adding: [], removing: [category])) }
            }
        }
        changes.append(.resyncEnded(began))
        try await store.commit(GmailJournalBatch(changes: changes, cursor: began))
    }

    // MARK: The cache

    func cachedRow(_ id: GmailMessageID) -> GmailCachedMessage {
        let m = gmail.message(id)!
        return GmailCachedMessage(id: id, threadID: m.ref.threadID, from: EmailAddress(address: "ana@example.com"),
                                  subject: m.headers.first { $0.name == "Subject" }?.value ?? "", preview: String(m.text.prefix(100)),
                                  date: m.date, size: m.size, hasAttachments: m.hasAttachment,
                                  messageID: m.headers.first { $0.name == "Message-ID" }?.value ?? "", cachedAt: m.date)
    }
}
