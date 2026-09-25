import XCTest
@testable import FalconCore

final class ListIndexTests: XCTestCase {
    typealias M = ListFixtures.Message

    /// The design's timings are for the optimised build. `swift test` builds for debugging,
    /// where the same passes run about ten times slower, so the bounds there are looser; the
    /// optimised run (`swift test -c release -Xswiftc -enable-testing`) holds the design's own.
    #if DEBUG
    static let slack = 3.0
    #else
    static let slack = 1.0
    #endif

    private func milliseconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func build(_ account: ListIndexAccount, _ view: ListView, facts: [UInt64: ListRowFacts] = [:],
                       now: Date = Date()) async -> ListBuild {
        let index = ListIndex(clock: { now })
        await index.setAccount(account)
        await index.addFacts(facts, account: account.accountID)
        return await index.build(view)
    }

    private func keys(_ snapshot: ListSnapshot) -> [Int] {
        snapshot.rows.compactMap { $0.displayKind == .header ? nil : Int(($0.key - ListFixtures.baseID) / 16) }
    }

    private func folder(_ label: GmailLabelID) -> UUID { ListFixtures.folderIDs[label]! }

    // MARK: - Size and speed

    func testADisplayRecordIsTwentyFourBytes() {
        XCTAssertEqual(MemoryLayout<DisplayRecord>.stride, 24)
    }

    func testAViewOf200000MessagesIsBuiltInUnderFiveMilliseconds() {
        let account = ListFixtures.account(ListFixtures.index(ListFixtures.large()))
        let view = ListView(scope: .folder(account.archiveFolderID!), conversations: false)
        var best = Double.infinity
        var rows = 0
        // The best of up to twenty: the Mac may be busy with other work, which is no measure of this.
        for _ in 0..<20 where best >= 5 * Self.slack {
            var builder = ListBuilder(view: view, settings: .init(), groups: ListDateGroups(now: Date()))
            best = min(best, milliseconds {
                builder.add(account, target: .folder(.archive), facts: [:], offline: false, expanded: [])
                rows = builder.finish(order: [account.accountID], names: [:], frozen: [:]).snapshot.rows.count
            })
        }
        // Everything but Junk Email and Deleted Items.
        XCTAssertEqual(rows, 196_000)
        XCTAssertLessThan(best, 5 * Self.slack, "a 200,000-row view took \(best) ms")
    }

    func testGrouping200000MessagesIntoConversationsTakesUnderFiftyMilliseconds() {
        let account = ListFixtures.account(ListFixtures.index(ListFixtures.large()))
        let view = ListView(scope: .folder(account.archiveFolderID!), conversations: true)
        var best = Double.infinity
        var snapshot: ListSnapshot?
        for _ in 0..<20 where best >= 50 * Self.slack {
            var builder = ListBuilder(view: view, settings: .init(), groups: ListDateGroups(now: Date()))
            best = min(best, milliseconds {
                builder.add(account, target: .folder(.archive), facts: [:], offline: false, expanded: [])
                snapshot = builder.finish(order: [account.accountID], names: [:], frozen: [:]).snapshot
            })
        }
        XCTAssertLessThan(best, 50 * Self.slack, "grouping 200,000 took \(best) ms")
        let rows = snapshot!.rows
        XCTAssertEqual(rows.reduce(0) { $0 + Int($1.members) }, 196_000, "every message is in one row")
        XCTAssertEqual(snapshot!.itemCount, 196_000, "Items counts messages in Conversations view, as Outlook does")
        XCTAssertTrue(rows.contains { $0.displayKind == .conversation })
        XCTAssertLessThan(rows.count, 196_000)
    }

    // MARK: - Folders

    func testAFolderIsEveryMessageWithItsLabelLessJunkDeletedAndChats() async {
        let messages = [M(labels: [.inbox], thread: 0), M(labels: [.inbox, .trash], thread: 1), M(labels: [.inbox, .spam], thread: 2),
                        M(labels: [.inbox, .chat], thread: 3), M(labels: [.sent], thread: 4), M(labels: [.trash], thread: 5),
                        M(labels: [.spam], thread: 6), M(labels: [], thread: 7)]
        let account = ListFixtures.account(ListFixtures.index(messages))
        func rows(_ scope: ListView.Scope) async -> [Int] { keys(await build(account, ListView(scope: scope, conversations: false)).snapshot) }
        let inbox = await rows(.folder(folder(.inbox)))
        XCTAssertEqual(inbox, [0])
        let deleted = await rows(.folder(folder(.trash)))
        XCTAssertEqual(deleted, [1, 5], "Deleted Items shows its own")
        let junk = await rows(.folder(folder(.spam)))
        XCTAssertEqual(junk, [2, 6])
        let archive = await rows(.folder(account.archiveFolderID!))
        XCTAssertEqual(archive, [0, 4, 7], "Archive is All Mail: everything but those three")
        let sent = await rows(.folder(folder(.sent)))
        XCTAssertEqual(sent, [4])
    }

    func testAUserLabelIsReadFromItsBitOrItsOverflowList() async {
        let acme = GmailLabelID("Label_1")
        let old = GmailLabelID("Label_2")
        let messages = (0..<6).map { M(labels: $0 % 2 == 0 ? [acme] : [], thread: $0) }
        let index = ListFixtures.index(messages, userSlots: [acme: 16], overflow: [old: [1, 3, 5]])
        let acmeFolder = UUID(), oldFolder = UUID()
        let labels = ListFixtures.systemLabels() + [
            GmailLabelEntry(id: acme, name: "Clients/Acme", kind: .user, isShown: true, folderID: acmeFolder, slot: 16, isComplete: true),
            GmailLabelEntry(id: old, name: "Archive 2019", kind: .user, isShown: true, folderID: oldFolder, isComplete: true)
        ]
        let account = ListFixtures.account(index, labels: labels)
        let byBit = keys(await build(account, ListView(scope: .folder(acmeFolder), conversations: false)).snapshot)
        let byList = keys(await build(account, ListView(scope: .folder(oldFolder), conversations: false)).snapshot)
        XCTAssertEqual(byBit, [0, 2, 4])
        XCTAssertEqual(byList, [1, 3, 5], "a label past the 48 bits is read from its overflow list")
    }

    func testAFolderOfAnotherAccountIsEmptyHere() async {
        let account = ListFixtures.account(ListFixtures.index([M(labels: [.inbox], thread: 0)]))
        let snapshot = await build(account, ListView(scope: .folder(UUID()))).snapshot
        XCTAssertTrue(snapshot.rows.isEmpty)
    }

    // MARK: - Filters

    func testUnreadFlaggedAndAttachmentFiltersUseTheBitsSoTheyCoverEveryMessage() async {
        let messages = [M(labels: [.inbox, .unread], thread: 0), M(labels: [.inbox, .starred], thread: 1),
                        M(labels: [.inbox], thread: 2, attributes: [.attachmentKnown, .hasAttachment]),
                        M(labels: [.inbox, .unread, .starred], thread: 3)]
        let account = ListFixtures.account(ListFixtures.index(messages))
        let inbox = folder(.inbox)
        let unread = keys(await build(account, ListView(scope: .folder(inbox), filters: [.unread], conversations: false)).snapshot)
        let flagged = keys(await build(account, ListView(scope: .folder(inbox), filters: [.flagged], conversations: false)).snapshot)
        let both = keys(await build(account, ListView(scope: .folder(inbox), filters: [.unread, .flagged], conversations: false)).snapshot)
        let clip = keys(await build(account, ListView(scope: .folder(inbox), filters: [.attachments], conversations: false)).snapshot)
        XCTAssertEqual(unread, [0, 3])
        XCTAssertEqual(flagged, [1, 3])
        XCTAssertEqual(both, [3])
        XCTAssertEqual(clip, [2])
    }

    func testFocusedIsPrimaryUpdatesAndUncategorisedAndOtherIsPromotionsSocialAndForums() async {
        let messages = [M(labels: [.inbox, .categoryPersonal], thread: 0), M(labels: [.inbox, .categoryUpdates], thread: 1),
                        M(labels: [.inbox], thread: 2), M(labels: [.inbox, .categoryPromotions], thread: 3),
                        M(labels: [.inbox, .categorySocial], thread: 4), M(labels: [.inbox, .categoryForums], thread: 5)]
        let account = ListFixtures.account(ListFixtures.index(messages))
        let inbox = folder(.inbox)
        let focused = keys(await build(account, ListView(scope: .folder(inbox), filters: [.focused], conversations: false)).snapshot)
        let other = keys(await build(account, ListView(scope: .folder(inbox), filters: [.other], conversations: false)).snapshot)
        XCTAssertEqual(focused, [0, 1, 2], "order confirmations and bills arrive as Updates, and stay in Focused")
        XCTAssertEqual(other, [3, 4, 5])

        let index = ListIndex(settings: .init(updatesAreOther: true))
        await index.setAccount(account)
        let moved = keys(await index.build(ListView(scope: .folder(inbox), filters: [.other], conversations: false)).snapshot)
        XCTAssertEqual(moved, [1, 3, 4, 5], "the Reading setting moves Updates to Other")
    }

    func testAnAttachmentFilterBeforeTheListingAsksForItAndSaysTheViewIsIncomplete() async {
        var account = ListFixtures.account(ListFixtures.index([M(labels: [.inbox], thread: 0)]))
        account.attachmentsKnown = false
        let build = await build(account, ListView(scope: .folder(folder(.inbox)), filters: [.attachments]))
        XCTAssertTrue(build.needs.contains(.attachments(account.accountID)))
        XCTAssertFalse(build.snapshot.complete)
    }

    // MARK: - Conversations

    func testAConversationSitsWhereItsNewestMemberSitsAndCountsItsUnread() async {
        // Newest first: 0 and 3 share a thread, as do 1 and 4.
        let messages = [M(labels: [.inbox, .unread], thread: 10), M(labels: [.inbox], thread: 11), M(labels: [.inbox], thread: 12),
                        M(labels: [.inbox, .unread], thread: 10), M(labels: [.inbox, .starred], thread: 11)]
        let account = ListFixtures.account(ListFixtures.index(messages))
        let snapshot = await build(account, ListView(scope: .folder(folder(.inbox)))).snapshot
        XCTAssertEqual(keys(snapshot), [0, 1, 2])
        XCTAssertEqual(snapshot.rows.map(\.members), [2, 2, 1])
        XCTAssertEqual(snapshot.rows.map(\.unread), [2, 0, 0])
        XCTAssertEqual(snapshot.rows.map(\.displayKind), [.conversation, .conversation, .message])
        XCTAssertTrue(snapshot.rows[1].displayBits.contains(.flagged), "a flag anywhere in the conversation shows on its row")
        XCTAssertEqual(snapshot.itemCount, 5)
    }

    func testAMessageWhoseRepliesAreInSentIsAConversationThatOpensOutToThem() async {
        // 0 is the owner's reply in Sent to 1 in the Inbox; 2 is alone; 3 is a deleted reply.
        let messages = [M(labels: [.sent], thread: 20), M(labels: [.inbox], thread: 20), M(labels: [.inbox], thread: 21),
                        M(labels: [.trash], thread: 21)]
        let account = ListFixtures.account(ListFixtures.index(messages))
        let index = ListIndex()
        await index.setAccount(account)
        let view = ListView(scope: .folder(folder(.inbox)))
        let closed = await index.build(view).snapshot
        XCTAssertEqual(closed.rows.map(\.displayKind), [.conversation, .message],
                       "a reply in Sent makes a conversation; one in Deleted Items does not")

        await index.setExpanded([.gmail(account: account.accountID, id: ListFixtures.id(1))], in: view.scope)
        let open = await index.build(view).snapshot
        XCTAssertEqual(open.rows.map(\.displayKind), [.conversation, .child, .child, .message])
        XCTAssertEqual(keys(open), [1, 0, 1, 2], "its messages follow it newest first, the reply in Sent too")
        XCTAssertTrue(open.rows[0].displayBits.contains(.expanded))
    }

    // MARK: - Sorts

    func testFlagStatusAndAttachmentSortsPutTheirGroupFirstAndKeepDateOrderWithin() async {
        let messages = [M(labels: [.inbox], thread: 0), M(labels: [.inbox, .starred, .unread], thread: 1),
                        M(labels: [.inbox, .unread], thread: 2), M(labels: [.inbox, .starred], thread: 3),
                        M(labels: [.inbox], thread: 4, attributes: [.attachmentKnown, .hasAttachment])]
        let account = ListFixtures.account(ListFixtures.index(messages))
        func sorted(_ key: ListSortKey, ascending: Bool = false) async -> [Int] {
            keys(await build(account, ListView(scope: .folder(folder(.inbox)), sort: ListSortSpec(key: key, ascending: ascending),
                                               conversations: false)).snapshot)
        }
        let flag = await sorted(.flag)
        XCTAssertEqual(flag, [1, 3, 0, 2, 4])
        let status = await sorted(.status)
        XCTAssertEqual(status, [1, 2, 0, 3, 4])
        let clip = await sorted(.attachments)
        XCTAssertEqual(clip, [4, 0, 1, 2, 3])
        let oldest = await sorted(.date, ascending: true)
        XCTAssertEqual(oldest, [4, 3, 2, 1, 0])
    }

    func testSizeSortUsesTheBandsAndPutsUnknownSizesLast() async {
        func sized(_ band: SizeBand) -> GmailRecordAttributes {
            var a: GmailRecordAttributes = [.sizeKnown]
            a.sizeBand = band
            return a
        }
        let messages = [M(labels: [.inbox], thread: 0, attributes: sized(.small)), M(labels: [.inbox], thread: 1),
                        M(labels: [.inbox], thread: 2, attributes: sized(.huge)), M(labels: [.inbox], thread: 3, attributes: sized(.tiny))]
        let account = ListFixtures.account(ListFixtures.index(messages))
        let view = ListView(scope: .folder(folder(.inbox)), sort: ListSortSpec(key: .size, ascending: false), conversations: false,
                            dateGroups: true)
        let snapshot = await build(account, view).snapshot
        XCTAssertEqual(keys(snapshot), [2, 0, 3, 1])
        XCTAssertEqual(snapshot.headers.values.sorted(), ["Huge (5 MB and over)", "Size not known yet", "Small (under 100 KB)",
                                                          "Tiny (under 25 KB)"])
    }

    func testFolderSortPutsDeletedItemsAndJunkFirstThenTheSidebarsOrderAndArchiveForTheRest() async {
        let acme = GmailLabelID("Label_7")
        let messages = [M(labels: [acme], thread: 0), M(labels: [.inbox], thread: 1), M(labels: [], thread: 2),
                        M(labels: [.trash], thread: 3), M(labels: [.sent], thread: 4), M(labels: [.spam], thread: 5)]
        let index = ListFixtures.index(messages, userSlots: [acme: 16])
        let labels = ListFixtures.systemLabels() + [GmailLabelEntry(id: acme, name: "Acme", kind: .user, isShown: true,
                                                                    folderID: UUID(), slot: 16, isComplete: true)]
        let account = ListFixtures.account(index, labels: labels)
        let search = UUID()
        let list = ListIndex()
        await list.setAccount(account)
        await list.setSearchHits((0..<6).map(ListFixtures.id), search: search, account: account.accountID)
        let view = ListView(scope: .search(search), sort: ListSortSpec(key: .folder, ascending: false), conversations: false,
                            dateGroups: true)
        let snapshot = await list.build(view).snapshot
        XCTAssertEqual(keys(snapshot), [3, 5, 1, 2, 4, 0])
        let titles = snapshot.rows.filter { $0.displayKind == .header }.map { snapshot.headers[Int($0.group)]! }
        XCTAssertEqual(titles, ["Deleted Items", "Junk Email", "Inbox", "Archive", "Sent", "Acme"])
    }

    func testSortingBySenderGroupsTheKnownRowsAndListsTheRestByDateUnderTheirOwnHeader() async {
        let messages = (0..<300).map { M(labels: [.inbox], thread: $0) }
        let account = ListFixtures.account(ListFixtures.index(messages))
        let now = Date()
        var facts: [UInt64: ListRowFacts] = [:]
        facts[ListFixtures.id(5).raw] = ListRowFacts(date: now.addingTimeInterval(-50), from: "Zoe", to: "", subject: "b")
        facts[ListFixtures.id(9).raw] = ListRowFacts(date: now.addingTimeInterval(-90), from: "anna", to: "", subject: "a")
        facts[ListFixtures.id(2).raw] = ListRowFacts(date: now.addingTimeInterval(-20), from: "Anna", to: "", subject: "c")
        let view = ListView(scope: .folder(folder(.inbox)), sort: ListSortSpec(key: .from, ascending: false), conversations: false)
        let build = await build(account, view, facts: facts)
        let order = keys(build.snapshot)
        XCTAssertEqual(Array(order.prefix(3)), [2, 9, 5], "Anna's two, newest first, then Zoe")
        XCTAssertEqual(order.count, 300, "every row stays")
        XCTAssertEqual(Array(order[3..<6]), [0, 1, 3], "the rest by date")
        XCTAssertEqual(build.snapshot.headers.values.sorted(), [ListStatusText.olderByDate])
        XCTAssertEqual(build.textWanted.count, 200, "up to 200 more rows are fetched for each sort")
        XCTAssertEqual(build.textWanted.first, .gmail(account: account.accountID, id: ListFixtures.id(0)))
        XCTAssertEqual(build.listedByDateBefore, now.addingTimeInterval(-90))
        XCTAssertEqual(ListFooter.listedByDate(before: now, sort: .from).text.hasPrefix("Messages from before "), true)
    }

    // MARK: - Date groups

    func testDateGroupsComeFromAnchorsWithoutAnyMessagesDate() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 15))!
        let groups = ListDateGroups(now: now, calendar: calendar)
        let boundaries = groups.boundaries(oldest: calendar.date(from: DateComponents(year: 2026, month: 6, day: 3)))
        // Twelve messages, newest first; the anchors say which is the newest older than each boundary.
        let messages = (0..<12).map { M(labels: [.inbox], thread: $0) }
        let index = ListFixtures.index(messages)
        let older = [2, 4, 6, 8, 9, 10, 11]  // today 0–1, yesterday 2–3, this week 4–5, this month 6–7, then months
        var anchors: [GmailDateAnchor] = []
        for (i, boundary) in boundaries.enumerated() {
            let slot = i < older.count ? older[i] : nil
            anchors.append(GmailDateAnchor(boundary: boundary, id: slot.map(ListFixtures.id),
                                           order: slot.map { index.records[$0].order }, askedAt: now))
        }
        let account = ListFixtures.account(index, anchors: anchors)
        let list = ListIndex(calendar: calendar, clock: { now })
        await list.setAccount(account)
        let view = ListView(scope: .folder(folder(.inbox)), conversations: false, dateGroups: true)
        let snapshot = await list.build(view).snapshot
        let titles = snapshot.rows.filter { $0.displayKind == .header }.map { snapshot.headers[Int($0.group)]! }
        XCTAssertEqual(Array(titles.prefix(4)), ["Today", "Yesterday", "Earlier this week", "Earlier this month"])
        XCTAssertEqual(titles.count, Set(titles).count, "each group once")
        XCTAssertEqual(keys(snapshot), Array(0..<12))
        XCTAssertTrue(titles.contains("August 2026"))
    }

    func testDateGroupsWithoutAnchorsAskForThem() async {
        let account = ListFixtures.account(ListFixtures.index([M(labels: [.inbox], thread: 0)]))
        let build = await build(account, ListView(scope: .folder(folder(.inbox)), dateGroups: true))
        XCTAssertTrue(build.needs.contains(.anchors(account.accountID)))
    }

    func testBoundariesFallAtMidnightsAndGoBackAMonthAtATime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 15, minute: 30))!
        let groups = ListDateGroups(now: now, calendar: calendar)
        let boundaries = groups.boundaries(oldest: calendar.date(from: DateComponents(year: 2026, month: 5, day: 10)))
        let parts = boundaries.map { calendar.dateComponents([.month, .day, .hour], from: $0) }
        XCTAssertEqual(parts.map(\.hour), parts.map { _ in 0 }, "every boundary is a midnight")
        XCTAssertEqual(parts.prefix(4).map(\.day), [25, 24, 19, 25])
        XCTAssertEqual(parts.dropFirst(4).map(\.month), [8, 7, 6, 5])
        XCTAssertEqual(groups.title(for: now), "Today")
        XCTAssertEqual(groups.title(for: boundaries[1]), "Yesterday")
        let daily = groups.boundaries(oldest: nil, daily: true)
        XCTAssertGreaterThan(daily.count, 30, "every midnight of the last month, to place other accounts' rows by the day")
    }

    // MARK: - Items

    func testItemsIsGmailsCountWhileTheFolderIsStillBeingListed() async {
        let messages = (0..<10).map { M(labels: [.inbox], thread: $0) }
        var labels = ListFixtures.systemLabels()
        let i = labels.firstIndex { $0.id == .inbox }!
        labels[i].isComplete = false
        labels[i].counts = GmailLabelCounts(messagesTotal: 55_000, messagesUnread: 12, asOf: Date())
        let account = ListFixtures.account(ListFixtures.index(messages), labels: labels)
        let build = await build(account, ListView(scope: .folder(folder(.inbox))))
        XCTAssertEqual(build.snapshot.itemCount, 55_000)
        XCTAssertFalse(build.snapshot.complete)

        let whole = ListFixtures.account(ListFixtures.index(messages), complete: false, total: 200_000)
        let archive = await self.build(whole, ListView(scope: .folder(whole.archiveFolderID!)))
        XCTAssertEqual(archive.snapshot.itemCount, 200_000)
    }

    func testTheStatusBarSaysItemsTwoHundredThousandForTheLargeMailbox() async {
        let messages = (0..<200_000).map { M(labels: $0 % 2 == 0 ? [.inbox] : [.sent], thread: $0 / 2) }
        let account = ListFixtures.account(ListFixtures.index(messages))
        let snapshot = await build(account, ListView(scope: .folder(account.archiveFolderID!))).snapshot
        XCTAssertEqual(snapshot.rows.count, 100_000, "conversations")
        XCTAssertEqual(ListStatusText.items(snapshot.itemCount, locale: Locale(identifier: "en_GB")), "Items: 200,000")
    }

    // MARK: - All Inboxes

    func testAllInboxesMergesAccountsByDateWithStoredRowsExactAndOthersBetweenAnchors() async {
        let now = Date()
        let a = ListFixtures.account(ListFixtures.index((0..<3).map { M(labels: [.inbox], thread: $0) }), email: "a@example.com")
        let b = ListFixtures.account(ListFixtures.index((0..<2).map { M(labels: [.inbox], thread: 100 + $0) }), email: "b@example.com")
        let index = ListIndex(clock: { now })
        await index.setAccount(a)
        await index.setAccount(b)
        await index.addFacts([ListFixtures.id(0).raw: ListRowFacts(date: now.addingTimeInterval(-10), from: "", to: "", subject: ""),
                              ListFixtures.id(1).raw: ListRowFacts(date: now.addingTimeInterval(-300), from: "", to: "", subject: ""),
                              ListFixtures.id(2).raw: ListRowFacts(date: now.addingTimeInterval(-900), from: "", to: "", subject: "")],
                             account: a.accountID)
        await index.addFacts([ListFixtures.id(0).raw: ListRowFacts(date: now.addingTimeInterval(-100), from: "", to: "", subject: ""),
                              ListFixtures.id(1).raw: ListRowFacts(date: now.addingTimeInterval(-600), from: "", to: "", subject: "")],
                             account: b.accountID)
        let imap = UUID()
        await index.setStoredInboxRows([ListStoredRow(key: "\(imap.uuidString):f:1", accountID: imap, date: now.addingTimeInterval(-200)),
                                        ListStoredRow(key: "\(imap.uuidString):f:2", accountID: imap, date: now.addingTimeInterval(-5_000))])
        let snapshot = await index.build(ListView(scope: .allInboxes, conversations: false)).snapshot
        let order = snapshot.rows.indices.map { snapshot.rowKey(at: $0)! }
        XCTAssertEqual(order, [.gmail(account: a.accountID, id: ListFixtures.id(0)), .gmail(account: b.accountID, id: ListFixtures.id(0)),
                               .stored("\(imap.uuidString):f:1"), .gmail(account: a.accountID, id: ListFixtures.id(1)),
                               .gmail(account: b.accountID, id: ListFixtures.id(1)), .gmail(account: a.accountID, id: ListFixtures.id(2)),
                               .stored("\(imap.uuidString):f:2")])
        XCTAssertEqual(snapshot.itemCount, 7)
    }

    func testARowOnScreenKeepsItsPlaceInAllInboxesWhenItsDateArrives() async {
        let now = Date()
        let a = ListFixtures.account(ListFixtures.index([M(labels: [.inbox], thread: 0)]))
        let b = ListFixtures.account(ListFixtures.index([M(labels: [.inbox], thread: 1)]))
        let index = ListIndex(clock: { now })
        await index.setAccount(a)
        await index.setAccount(b)
        let keyA = RowKey.gmail(account: a.accountID, id: ListFixtures.id(0))
        let keyB = RowKey.gmail(account: b.accountID, id: ListFixtures.id(0))
        await index.addFacts([ListFixtures.id(0).raw: ListRowFacts(date: now.addingTimeInterval(-50), from: "", to: "", subject: "")],
                             account: a.accountID)
        await index.addFacts([ListFixtures.id(0).raw: ListRowFacts(date: now.addingTimeInterval(-100), from: "", to: "", subject: "")],
                             account: b.accountID)
        let view = ListView(scope: .allInboxes, conversations: false)
        let first = await index.build(view).snapshot
        XCTAssertEqual(first.rowKey(at: 0), keyA)
        // On screen, A's row learns it is older than B's; it stays until it leaves the screen.
        await index.freeze([keyA, keyB], dates: [keyA: now.addingTimeInterval(-50), keyB: now.addingTimeInterval(-100)])
        await index.addFacts([ListFixtures.id(0).raw: ListRowFacts(date: now.addingTimeInterval(-500), from: "", to: "", subject: "")],
                             account: a.accountID)
        let held = await index.build(view).snapshot
        XCTAssertEqual(held.rowKey(at: 0), keyA)
        await index.freeze([], dates: [:])
        let settled = await index.build(view).snapshot
        XCTAssertEqual(settled.rowKey(at: 0), keyB)
    }

    func testRowsOnScreenAreFrozenAtTheDatesThatPlacedThem() async {
        let now = Date()
        let a = ListFixtures.account(ListFixtures.index([M(labels: [.inbox], thread: 0)]))
        let b = ListFixtures.account(ListFixtures.index([M(labels: [.inbox], thread: 1)]))
        let index = ListIndex(clock: { now })
        await index.setAccount(a)
        await index.setAccount(b)
        let keyA = RowKey.gmail(account: a.accountID, id: ListFixtures.id(0))
        let keyB = RowKey.gmail(account: b.accountID, id: ListFixtures.id(0))
        await index.addFacts([ListFixtures.id(0).raw: ListRowFacts(date: now.addingTimeInterval(-50), from: "", to: "", subject: "")],
                             account: a.accountID)
        await index.addFacts([ListFixtures.id(0).raw: ListRowFacts(date: now.addingTimeInterval(-100), from: "", to: "", subject: "")],
                             account: b.accountID)
        let view = ListView(scope: .allInboxes, conversations: false)
        await index.freezeVisible([keyA, keyB])
        await index.addFacts([ListFixtures.id(0).raw: ListRowFacts(date: now.addingTimeInterval(-500), from: "", to: "", subject: "")],
                             account: a.accountID)
        let held = await index.build(view).snapshot
        XCTAssertEqual(held.rowKey(at: 0), keyA, "held where it was while on screen")
        await index.freezeVisible([keyB])
        let moved = await index.build(view).snapshot
        XCTAssertEqual(moved.rowKey(at: 0), keyB, "once off screen it settles into its place")
    }

    // MARK: - Offline, search

    func testOfflineOnlyRowsWithTextOnTheMacAreShownAndTheRestAreCounted() async {
        let messages = (0..<10).map { M(labels: [.inbox], thread: $0 < 4 ? 0 : $0) }
        let account = ListFixtures.account(ListFixtures.index(messages))
        let index = ListIndex()
        await index.setAccount(account)
        await index.addFacts([ListFixtures.id(0).raw: ListRowFacts(date: Date(), from: "", to: "", subject: ""),
                              ListFixtures.id(5).raw: ListRowFacts(date: Date(), from: "", to: "", subject: "")],
                             account: account.accountID)
        await index.setOffline(true, account: account.accountID)
        let build = await index.build(ListView(scope: .folder(folder(.inbox))))
        XCTAssertEqual(keys(build.snapshot), [0, 5])
        XCTAssertEqual(build.hiddenMessages, 5, "four in the conversation of 0 are shown by it; five others are not")
        XCTAssertEqual(build.snapshot.itemCount, 10, "Items stays the folder's real total")
        XCTAssertEqual(ListStatusText.footer(.offline(hidden: 54_210), locale: Locale(identifier: "en_GB")),
                       "54,210 older messages are on Gmail. They'll show when you're back online.")
    }

    func testASearchsRowsAreItsHitsWithTheirFlagsFromTheIndex() async {
        let messages = [M(labels: [.inbox, .unread], thread: 0), M(labels: [.sent], thread: 1), M(labels: [.inbox, .starred], thread: 2)]
        let account = ListFixtures.account(ListFixtures.index(messages))
        let index = ListIndex()
        await index.setAccount(account)
        let search = UUID()
        await index.setSearchHits([ListFixtures.id(2), ListFixtures.id(0), GmailMessageID(raw: 99)], search: search, account: account.accountID)
        let snapshot = await index.build(ListView(scope: .search(search), conversations: false)).snapshot
        XCTAssertEqual(keys(snapshot), [2, 0], "a hit not in the index yet waits for its placing")
        XCTAssertTrue(snapshot.rows[0].displayBits.contains(.flagged))
        XCTAssertTrue(snapshot.rows[1].displayBits.contains(.unread))
    }

    // MARK: - Diffs

    func testANewMessageIsOneInsertAndAReadOneIsOneReload() {
        let account = UUID()
        func snapshot(_ ids: [UInt64], unread: Set<UInt64> = []) -> ListSnapshot {
            ListSnapshot(view: ListView(scope: .allInboxes), rows: ContiguousArray(ids.map {
                DisplayRecord(key: $0, slot: Int32($0), bits: unread.contains($0) ? [.unread] : [])
            }), complete: true, itemCount: ids.count, sources: [account])
        }
        let old = snapshot(Array(1...1_000), unread: [5])
        let arrived = ListDiffer.diff(from: old, to: snapshot([0] + Array(1...1_000), unread: [5]))
        XCTAssertEqual(arrived.inserted, [0])
        XCTAssertTrue(arrived.removed.isEmpty)
        XCTAssertTrue(arrived.reloaded.isEmpty)

        let read = ListDiffer.diff(from: old, to: snapshot(Array(1...1_000)))
        XCTAssertEqual(read.reloaded, [4])
        XCTAssertTrue(read.inserted.isEmpty && read.removed.isEmpty)

        let moved = ListDiffer.diff(from: snapshot([1, 2, 3, 4]), to: snapshot([3, 1, 2, 4]))
        XCTAssertEqual(moved.removed.count, moved.inserted.count)
        XCTAssertEqual(moved.removed.count, 1, "only the row that moved goes and comes back")

        let other = ListDiffer.diff(from: old, to: ListSnapshot(view: ListView(scope: .search(UUID())), rows: [], complete: true,
                                                               itemCount: 0, sources: []))
        XCTAssertEqual(other.removed.count, 1_000, "another view replaces every row")
    }
}
