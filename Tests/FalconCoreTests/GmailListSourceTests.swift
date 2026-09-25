import XCTest
@testable import FalconCore

/// A Google account's list over the in-memory store and mailbox. Nothing here reaches a network.
final class GmailListSourceTests: XCTestCase {
    struct Mailbox {
        let transport: MemoryGmailTransport
        let store: MemoryGmailStore
        let archive = UUID()
        /// Newest first, as the index orders them.
        var refs: [GmailRef] = []
        var labels: [GmailRef: Set<GmailLabelID>] = [:]

        var accountID: UUID { transport.accountID }
        func folder(_ label: GmailLabelID) -> UUID { ListFixtures.folderIDs[label]! }
        func key(_ i: Int) -> RowKey { .gmail(account: accountID, id: refs[i].id) }

        func source(budget: RowFetchBudget = TokenBucketEstimate(), index: ListIndex = ListIndex()) -> GmailListSource {
            GmailListSource(accountID: accountID, email: transport.email, store: store, transport: transport,
                            archiveFolderID: archive, index: index, budget: budget)
        }
    }

    /// `count` messages in the Inbox, newest first. The first `pairs` pairs share a thread, and
    /// the owner has replied in Sent to each of the first `replies` of them.
    private func mailbox(count: Int = 60, pairs: Int = 10, replies: Int = 3, cached: Int = 0,
                         email: String = "owner@example.com", spacing: TimeInterval = 600) async throws -> Mailbox {
        let transport = MemoryGmailTransport(email: email)
        var box = Mailbox(transport: transport, store: MemoryGmailStore(accountID: transport.accountID))
        let start = Date().addingTimeInterval(-60)
        var threadOf: [Int: GmailThreadID] = [:]
        var messages: [(ref: GmailRef, labels: Set<GmailLabelID>, date: Date)] = []
        // Oldest first into the mailbox, so each thread's id is its first message's.
        for i in (0..<count).reversed() {
            let date = start.addingTimeInterval(-Double(i) * spacing)
            let pair = i < pairs * 2 ? i / 2 : nil
            let labels: Set<GmailLabelID> = i % 4 == 0 ? [.inbox, .unread] : [.inbox]
            let ref = transport.add(subject: "Freight invoice \(i)", from: "Sender \(i) <s\(i)@example.com>",
                                    text: "Opening words of message \(i)", labels: labels, date: date,
                                    thread: pair.flatMap { threadOf[$0] })
            if let pair, threadOf[pair] == nil { threadOf[pair] = ref.threadID }
            messages.append((ref, labels, date))
        }
        for pair in 0..<replies {
            let date = start.addingTimeInterval(Double(pair) + 1)
            let ref = transport.add(subject: "Re: Freight invoice \(pair * 2)", from: "Owner <\(email)>", text: "Thanks",
                                    labels: [.sent], date: date, thread: threadOf[pair])
            messages.append((ref, [.sent], date))
        }
        messages.sort { $0.date > $1.date }
        _ = try await box.store.saveLabelTable(ListFixtures.systemLabels())
        let total = messages.count
        try await box.store.commit(GmailJournalBatch(changes: messages.enumerated().map { i, m in
            .place(m.ref, order: UInt32(total - i) * GmailIndexRecord.orderStep, labels: m.labels, attributes: [])
        }))
        box.refs = messages.filter { $0.labels.contains(.inbox) }.map(\.ref)
        for m in messages { box.labels[m.ref] = m.labels }
        // The newest `cached` of every folder are kept on the Mac, with their conversations' summaries.
        let keep = messages.prefix(cached)
        var summaries: [GmailThreadID: [(GmailRef, Date)]] = [:]
        for m in messages { summaries[m.ref.threadID, default: []].append((m.ref, m.date)) }
        var saved: [GmailThreadSummary] = []
        for m in keep {
            let stored = transport.message(m.ref.id)!
            let from = AddressParser.parse(stored.headers.first { $0.name == "From" }?.value).first!
            let subject = stored.headers.first { $0.name == "Subject" }!.value
            try await box.store.cache(GmailCachedMessage(id: m.ref.id, threadID: m.ref.threadID, from: from,
                                                         to: [EmailAddress(address: email)], subject: subject,
                                                         preview: stored.text, date: m.date, size: stored.size, hasAttachments: false,
                                                         messageID: "<\(m.ref.id.hex)@mail.example.com>", cachedAt: Date()),
                                      body: nil)
            if let members = summaries[m.ref.threadID], members.count > 1, !saved.contains(where: { $0.threadID == m.ref.threadID }) {
                let ordered = members.sorted { $0.1 < $1.1 }
                let senders = ordered.map { member in
                    AddressParser.parse(transport.message(member.0.id)!.headers.first { $0.name == "From" }?.value).first!
                }
                saved.append(GmailThreadSummary(threadID: m.ref.threadID, senders: senders, messageCount: members.count,
                                                newestDate: ordered.last!.1,
                                                members: zip(ordered, senders).map { GmailThreadMember(id: $0.0.0.id, from: $0.1, date: $0.0.1) }))
            }
        }
        try await box.store.saveThreadSummaries(saved)
        return box
    }

    /// Rows from `stream` until `done` says enough have come, or five seconds pass.
    private func collect(_ stream: AsyncStream<[RowKey: MessageRowContent]>, timeout: TimeInterval = 5,
                         until done: @escaping @Sendable ([RowKey: MessageRowContent]) -> Bool) async -> [RowKey: MessageRowContent] {
        await withTaskGroup(of: [RowKey: MessageRowContent]?.self) { group in
            group.addTask {
                var all: [RowKey: MessageRowContent] = [:]
                for await rows in stream {
                    all.merge(rows) { _, new in new }
                    if done(all) { return all }
                }
                return all
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                return nil
            }
            var result: [RowKey: MessageRowContent] = [:]
            for await value in group {
                if let value { result = value }
                group.cancelAll()
                break
            }
            return result
        }
    }

    private func firstScreen(_ snapshot: ListSnapshot, rows: Int = 25) -> [RowKey] {
        Array(snapshot.rows.indices.compactMap { snapshot.rowKey(at: $0) }.prefix(rows))
    }

    // MARK: - From the Mac

    func testTheFirstScreenFromDiskInConversationsViewCostsNothingOfflineToo() async throws {
        let box = try await mailbox(cached: 40)
        for offline in [false, true] {
            if offline { box.transport.fail(nil, with: GoogleAPIError(kind: .offline), times: 1_000) }
            let source = box.source()
            if offline { await source.setReachability(.offline) }
            let view = ListView(scope: .folder(box.folder(.inbox)))
            let snapshot = await source.snapshot(of: view)
            let keys = firstScreen(snapshot)
            XCTAssertEqual(keys.count, 25)
            let stream = source.rows
            source.requestRows(keys, priority: .visible)
            let rows = await collect(stream) { Set($0.keys).isSuperset(of: keys) }
            XCTAssertTrue(Set(rows.keys).isSuperset(of: keys), offline ? "offline" : "online")
            XCTAssertEqual(box.transport.totalUnits, 0, "nothing was asked of Gmail")
            XCTAssertEqual(box.transport.attempts.values.reduce(0, +), 0)
            // The conversations paint their senders from the summaries kept on the Mac.
            let conversationRows = snapshot.rows.enumerated().filter { $0.element.displayKind == .conversation }.map(\.offset)
            XCTAssertFalse(conversationRows.isEmpty)
            for row in conversationRows.prefix(3) {
                let content = rows[snapshot.rowKey(at: row)!]
                XCTAssertNotNil(content?.conversation, "row \(row)")
                XCTAssertGreaterThanOrEqual(content?.conversation?.senders.count ?? 0, 2)
            }
        }
    }

    // MARK: - From Gmail

    func testRowsNotOnTheMacComeInOneLandingOfAtMost25PricedAsMessagesAndConversations() async throws {
        let box = try await mailbox(cached: 0)
        let source = box.source()
        let view = ListView(scope: .folder(box.folder(.inbox)))
        let snapshot = await source.snapshot(of: view)
        let keys = firstScreen(snapshot)
        let conversations = snapshot.rows.prefix(25).filter { $0.displayKind == .conversation }.count
        let stream = source.rows
        source.requestRows(keys, priority: .visible)
        let rows = await collect(stream) { Set($0.keys).isSuperset(of: keys) }
        XCTAssertEqual(Set(rows.keys), Set(keys))
        XCTAssertEqual(box.transport.calls[.threadsGet] ?? 0, conversations)
        XCTAssertEqual(box.transport.calls[.messagesGet] ?? 0, 25 - conversations)
        XCTAssertEqual(box.transport.totalUnits, conversations * 40 + (25 - conversations) * 20)
        XCTAssertLessThanOrEqual(box.transport.totalUnits, 1_000)
        let conversation = rows.values.first { $0.conversation != nil }
        XCTAssertNotNil(conversation)
        XCTAssertEqual(conversation?.preview.hasPrefix("Opening words"), true)

        // Scrolling back costs nothing: the rows are kept for the session.
        let before = box.transport.totalUnits
        let again = source.rows
        source.requestRows(keys, priority: .visible)
        let second = await collect(again) { Set($0.keys).isSuperset(of: keys) }
        XCTAssertEqual(Set(second.keys), Set(keys))
        XCTAssertEqual(box.transport.totalUnits, before)
    }

    func testAnOpenedConversationShowsTheOwnersReplyInSentWithItsFolder() async throws {
        let box = try await mailbox(cached: 0)
        let source = box.source()
        let view = ListView(scope: .folder(box.folder(.inbox)))
        let snapshot = await source.snapshot(of: view)
        let changes = source.changes(of: view)
        let first = snapshot.rowKey(at: 0)!
        XCTAssertEqual(snapshot.rows[0].displayKind, .conversation)
        await source.setExpanded([first], in: view)
        guard let diff = await firstValue(of: changes) else { return XCTFail("no change came") }
        XCTAssertEqual(diff.inserted.count, 3, "the pair and the owner's reply")
        XCTAssertEqual(diff.snapshot.rows[1].displayKind, .child)
        XCTAssertTrue(diff.snapshot.rows[0].displayBits.contains(.expanded))

        let stream = source.rows
        source.requestRows([first], priority: .visible)
        let rows = await collect(stream) { $0[first] != nil }
        let members = rows[first]?.conversation?.members ?? []
        XCTAssertEqual(members.count, 3)
        XCTAssertEqual(members.last?.folderName, "Sent", "the reply is named by Outlook's folder")
        XCTAssertNil(members.first?.folderName)
    }

    // MARK: - Summaries

    func testASummaryIsGoneOnlyWhenGmailSaysSoAndUnavailableOffline() async throws {
        let box = try await mailbox(count: 6, pairs: 0, replies: 0, cached: 2)
        let source = box.source()
        let view = ListView(scope: .folder(box.folder(.inbox)))
        guard case .available(let cached) = await source.summary(for: box.key(0), in: view) else { return XCTFail("cached") }
        XCTAssertEqual(cached.folderID, box.folder(.inbox), "the folder is the view's")
        XCTAssertEqual(cached.id, box.key(0).stringValue)
        XCTAssertEqual(cached.gmailID, box.refs[0].id)
        XCTAssertEqual(box.transport.totalUnits, 0)

        guard case .available(let fetched) = await source.summary(for: box.key(4), in: view) else { return XCTFail("fetched") }
        XCTAssertEqual(fetched.subject, "Freight invoice 4")
        XCTAssertEqual(fetched.threadKey, box.refs[4].threadID.threadKey)
        XCTAssertEqual(box.transport.totalUnits, 20)

        box.transport.delete(box.refs[5].id)
        guard case .gone = await source.summary(for: box.key(5), in: view) else { return XCTFail("a 404 is gone") }

        await source.setReachability(.offline)
        guard case .unavailable(let reason) = await source.summary(for: box.key(3), in: view) else {
            return XCTFail("offline is not gone")
        }
        XCTAssertEqual(reason, "You're offline, and this message is not kept on this Mac.")
        guard case .available = await source.summary(for: box.key(1), in: view) else { return XCTFail("cached offline") }
    }

    // MARK: - Offline and changes

    func testOfflineTheListShowsOnlyRowsWithTextAndSaysHowManyAreOnGmail() async throws {
        let box = try await mailbox(count: 40, pairs: 0, replies: 0, cached: 10)
        let source = box.source()
        await source.setReachability(.offline)
        let view = ListView(scope: .folder(box.folder(.inbox)), conversations: false)
        let footers = source.footers(of: view)
        let snapshot = await source.snapshot(of: view)
        XCTAssertEqual(snapshot.rows.count, 10)
        XCTAssertEqual(snapshot.itemCount, 40)
        let lines = await firstValue(of: footers)
        XCTAssertEqual(lines, [.offline(hidden: 30)])
    }

    func testANewMessageComesAsOneInsertAtTheTop() async throws {
        var box = try await mailbox(count: 10, pairs: 0, replies: 0)
        let source = box.source()
        let view = ListView(scope: .folder(box.folder(.inbox)), conversations: false)
        _ = await source.snapshot(of: view)
        let changes = source.changes(of: view)
        let ref = box.transport.add(subject: "New", labels: [.inbox, .unread])
        try await box.store.commit(GmailJournalBatch(changes: [.place(ref, order: 1_000_000, labels: [.inbox, .unread], attributes: [])]))
        box.refs.insert(ref, at: 0)
        await source.refresh()
        let diff = await firstValue(of: changes)
        XCTAssertEqual(diff?.inserted, [0])
        XCTAssertEqual(diff?.removed, [])
        XCTAssertEqual(diff?.snapshot.itemCount, 11)
        XCTAssertEqual(diff?.snapshot.rowKey(at: 0), box.key(0))
    }

    func testRowsWaitingOnTheBudgetShowTheLoadingFooterAtOnce() async throws {
        let box = try await mailbox(count: 80, pairs: 0, replies: 0)
        let budget = TokenBucketEstimate(capacity: 1_000, refillPerMinute: 60)
        let source = box.source(budget: budget)
        let view = ListView(scope: .folder(box.folder(.inbox)), conversations: false)
        let snapshot = await source.snapshot(of: view)
        let footers = source.footers(of: view)
        let keys = snapshot.rows.indices.compactMap { snapshot.rowKey(at: $0) }
        // Two screens spend the thousand units; the third has to wait.
        for screen in 0..<3 {
            source.requestRows(Array(keys[(screen * 25)..<(screen * 25 + 25)]), priority: .visible)
        }
        let shown = await firstValue(of: footers) { $0.contains(.loading(email: "owner@example.com")) }
        XCTAssertEqual(shown?.first, .loading(email: "owner@example.com"))
        XCTAssertEqual(ListFooter.loading(email: "owner@example.com").text, "Loading more of owner@example.com's messages…")
    }

    func testDateGroupsAskForTheirAnchorsOnceAtFiveUnitsEachAndTheHeadersFollow() async throws {
        // A message every three days, back five weeks.
        let box = try await mailbox(count: 12, pairs: 0, replies: 0, spacing: 3 * 86_400)
        let source = box.source()
        let view = ListView(scope: .folder(box.folder(.inbox)), conversations: false, dateGroups: true)
        _ = await source.snapshot(of: view)
        var anchors: [GmailDateAnchor] = []
        for _ in 0..<100 {
            anchors = await box.store.dateAnchors()
            if !anchors.isEmpty { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(anchors.isEmpty)
        XCTAssertEqual(box.transport.units[.messagesList], anchors.count * 5, "one before: listing, 5 units, for each boundary")
        XCTAssertEqual(box.transport.calls[.messagesGet], 1, "and the oldest message's date, once")

        let snapshot = await source.snapshot(of: view)
        let titles = snapshot.rows.filter { $0.displayKind == .header }.map { snapshot.headers[Int($0.group)]! }
        let groups = ListDateGroups(now: Date())
        let expected = (0..<12).map { groups.title(for: Date().addingTimeInterval(-60 - Double($0) * 3 * 86_400)) }
        var distinct: [String] = []
        for title in expected where distinct.last != title { distinct.append(title) }
        XCTAssertEqual(titles, distinct, "each message falls in its own date's group, from the anchors alone")

        // Asked again, nothing more is asked of Gmail.
        let before = box.transport.totalUnits
        _ = await source.snapshot(of: view)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(box.transport.totalUnits, before)
    }

    // MARK: - All Inboxes

    func testAllInboxesRoutesEachRowToItsOwnAccount() async throws {
        let a = try await mailbox(count: 5, pairs: 0, replies: 0, cached: 5, email: "a@example.com")
        let b = try await mailbox(count: 5, pairs: 0, replies: 0, cached: 0, email: "b@example.com")
        // b's anchors are known, so its rows without dates are placed without asking for any.
        try await b.store.saveDateAnchors([GmailDateAnchor(boundary: Calendar.current.startOfDay(for: Date()).addingTimeInterval(-86_400 * 400),
                                                           id: nil, order: nil, askedAt: Date())])
        let index = ListIndex()
        let sourceA = a.source(index: index)
        let sourceB = b.source(index: index)
        let merged = MergedListSource(index: index, gmail: [sourceA, sourceB])
        let view = ListView(scope: .allInboxes, conversations: false)
        let snapshot = await merged.snapshot(of: view)
        XCTAssertEqual(snapshot.rows.count, 10)
        XCTAssertEqual(snapshot.itemCount, 10)
        let keys = snapshot.rows.indices.compactMap { snapshot.rowKey(at: $0) }
        let stream = merged.rows
        merged.requestRows(keys, priority: .visible)
        let rows = await collect(stream) { Set($0.keys).isSuperset(of: keys) }
        XCTAssertEqual(Set(rows.keys), Set(keys))
        XCTAssertEqual(a.transport.totalUnits, 0, "a's rows were on the Mac, and so were their dates")
        XCTAssertEqual(b.transport.units[.messagesGet], 100, "b's five came from b's Gmail")
        XCTAssertEqual(b.transport.units[.threadsGet] ?? 0, 0)
    }
}
