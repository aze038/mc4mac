import XCTest
@testable import FalconCore

final class EngineContractsTests: XCTestCase {
    // MARK: - Layouts

    func testADisplayRecordIsTwentyFourBytes() {
        XCTAssertEqual(MemoryLayout<DisplayRecord>.stride, 24)
        XCTAssertEqual(MemoryLayout<DisplayRecord>.size, 24, "the account byte fills what was padding")
        XCTAssertEqual(MemoryLayout<DisplayRecord>.alignment, 8)
        // A view of 200,000 rows, the owner's largest folder, stays under 5 MB.
        XCTAssertLessThanOrEqual(MemoryLayout<DisplayRecord>.stride * 200_000, 4_800_000)
    }

    func testAnIndexRecordIsThirtyTwoBytes() {
        XCTAssertEqual(MemoryLayout<GmailIndexRecord>.stride, 32)
        XCTAssertEqual(MemoryLayout<GmailIndexRecord>.size, 32)
        XCTAssertEqual(MemoryLayout<GmailRecordAttributes>.size, 2)
    }

    func testDisplayRecordReadsBackWhatItWasGiven() {
        var bits: DisplayBits = [.unread, .flagged, .sizeKnown]
        bits.sizeBand = .large
        let record = DisplayRecord(key: 0x18a0_0000_0000_00ff, slot: 12, bits: bits, members: 3, unread: 2, group: 4,
                                   kind: .conversation, source: 1)
        XCTAssertEqual(record.displayKind, .conversation)
        XCTAssertEqual(record.displayBits, bits)
        XCTAssertEqual(record.displayBits.sizeBand, .large)
        XCTAssertTrue(record.displayBits.contains(.unread))
        XCTAssertFalse(record.displayBits.contains(.hasAttachment))
        XCTAssertEqual(record.members, 3)
        XCTAssertEqual(record.unread, 2)
        XCTAssertEqual(record.group, 4)
        XCTAssertEqual(record.source, 1)

        let header = DisplayRecord.header(group: 7)
        XCTAssertEqual(header.displayKind, .header)
        XCTAssertEqual(header.slot, -1)
        XCTAssertEqual(header.members, 0)
    }

    func testSizeBandsKeepTheListsOwnLimitsAndLeaveOtherBitsAlone() {
        XCTAssertEqual(SizeBand(bytes: 0), .tiny)
        XCTAssertEqual(SizeBand(bytes: 24_999), .tiny)
        XCTAssertEqual(SizeBand(bytes: 25_000), .small)
        XCTAssertEqual(SizeBand(bytes: 99_999), .small)
        XCTAssertEqual(SizeBand(bytes: 100_000), .medium)
        XCTAssertEqual(SizeBand(bytes: 999_999), .medium)
        XCTAssertEqual(SizeBand(bytes: 1_000_000), .large)
        XCTAssertEqual(SizeBand(bytes: 4_999_999), .large)
        XCTAssertEqual(SizeBand(bytes: 5_000_000), .huge)
        XCTAssertLessThan(SizeBand.tiny, SizeBand.huge)

        for band in SizeBand.allCases {
            var bits: DisplayBits = [.unread, .inJunkEmail, DisplayBits(rawValue: 1 << 20)]
            bits.sizeBand = .huge
            bits.sizeBand = band
            XCTAssertEqual(bits.sizeBand, band)
            XCTAssertTrue(bits.isSuperset(of: [.unread, .inJunkEmail, DisplayBits(rawValue: 1 << 20)]))
            XCTAssertTrue(DisplayBits.allSizeBands.isDisjoint(with: [.unread, .inJunkEmail, .sizeKnown]))

            var attributes: GmailRecordAttributes = [.cached, .sizeKnown, .hasAttachment]
            attributes.sizeBand = .huge
            attributes.sizeBand = band
            XCTAssertEqual(attributes.sizeBand, band)
            XCTAssertTrue(attributes.isSuperset(of: [.cached, .sizeKnown, .hasAttachment]))
            XCTAssertTrue(GmailRecordAttributes.allSizeBands.isDisjoint(with: [.tombstone, .cached, .sizeKnown]))
        }
    }

    // MARK: - Snapshots and diffs

    func testASnapshotNamesEachRowsMessage() {
        let a = UUID()
        let b = UUID()
        var stored = DisplayRecord(key: 0, slot: 1, bits: [.storedRow])
        stored.source = 0
        let rows: ContiguousArray<DisplayRecord> = [
            .header(group: 0),
            DisplayRecord(key: 0x18a0_0000_0000_0001, slot: 5, source: 0),
            DisplayRecord(key: 0x18a0_0000_0000_0002, slot: 9, kind: .conversation, source: 1),
            stored,
            DisplayRecord(key: 1, slot: 3, source: 7),
            DisplayRecord(key: 0, slot: 40, bits: [.storedRow])
        ]
        let snapshot = ListSnapshot(view: ListView(scope: .allInboxes), rows: rows, headers: [0: "Today"], complete: true,
                                    itemCount: 4, sources: [a, b], storedKeys: ["x:y:1", "\(a.uuidString):\(UUID().uuidString):42"])
        XCTAssertNil(snapshot.rowKey(at: 0), "a header names no message")
        XCTAssertEqual(snapshot.rowKey(at: 1), .gmail(account: a, id: GmailMessageID(raw: 0x18a0_0000_0000_0001)))
        XCTAssertEqual(snapshot.rowKey(at: 2), .gmail(account: b, id: GmailMessageID(raw: 0x18a0_0000_0000_0002)))
        XCTAssertEqual(snapshot.rowKey(at: 3), .stored(snapshot.storedKeys[1]))
        XCTAssertNil(snapshot.rowKey(at: 4), "a source the snapshot does not hold")
        XCTAssertNil(snapshot.rowKey(at: 5), "a stored slot out of range")
        XCTAssertNil(snapshot.rowKey(at: 6))
        XCTAssertNil(snapshot.rowKey(at: -1))
        XCTAssertEqual(snapshot.headers[Int(rows[0].group)], "Today")

        let empty = ListSnapshot.empty(ListView(scope: .folder(UUID())))
        XCTAssertTrue(empty.rows.isEmpty)
        XCTAssertEqual(empty.itemCount, 0)
        XCTAssertFalse(empty.complete)
    }

    func testLargeDiffsReloadTheTable() {
        let view = ListView(scope: .folder(UUID()))
        func snapshot(_ count: Int) -> ListSnapshot {
            ListSnapshot(view: view, rows: ContiguousArray((0..<count).map { DisplayRecord(key: UInt64($0), slot: Int32($0)) }),
                         complete: true, itemCount: count, sources: [UUID()])
        }
        let small = ListDiff(inserted: IndexSet(integersIn: 0..<300), removed: IndexSet(integersIn: 0..<200), snapshot: snapshot(10))
        XCTAssertFalse(small.reloadsTable, "500 rows still animate")
        let large = ListDiff(inserted: IndexSet(integersIn: 0..<300), removed: IndexSet(integersIn: 0..<200),
                             reloaded: IndexSet(integer: 3), snapshot: snapshot(10))
        XCTAssertTrue(large.reloadsTable)
        let replaced = ListDiff.replacing(snapshot(400), with: snapshot(150))
        XCTAssertEqual(replaced.removed, IndexSet(integersIn: 0..<400))
        XCTAssertEqual(replaced.inserted, IndexSet(integersIn: 0..<150))
        XCTAssertTrue(replaced.reloadsTable)
        XCTAssertEqual(replaced.snapshot.rows.count, 150)
    }

    func testTheDefaultViewIsConversationsWithoutGroupsNewestFirst() {
        let folder = UUID()
        let view = ListView(scope: .folder(folder))
        XCTAssertTrue(view.conversations)
        XCTAssertFalse(view.dateGroups)
        XCTAssertEqual(view.sort, .newestFirst)
        XCTAssertEqual(view.sort, ListSortSpec(key: .date, ascending: false))
        XCTAssertTrue(view.filters.isEmpty)
        // Views key the list's caches, so equal views must be one key.
        var unread = view
        unread.filters = [.unread]
        var cache: [ListView: Int] = [view: 1, unread: 2]
        cache[ListView(scope: .folder(folder))] = 3
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache[view], 3)
        XCTAssertNotEqual(ListView(scope: .search(UUID())), ListView(scope: .allInboxes))
    }

    func testSortKeysMatchTheAppsSortMenu() {
        // The raw values the app's ListSort saves, so a saved sort maps across without a table.
        XCTAssertEqual(ListSortKey.allCases.map(\.rawValue),
                       ["date", "from", "to", "subject", "size", "flag", "status", "attachments", "account", "folder"])
        XCTAssertEqual(ListFilter.allCases.map(\.rawValue), ["unread", "flagged", "attachments", "focused", "other", "mentionsMe"])
    }

    // MARK: - Work and checks

    func testChecksComeBeforeEverythingAndBackgroundWorkIsRanked() {
        let ordered: [WorkClass] = [.checks, .interactive, .bulk, .background(.readAhead), .background(.cacheFill),
                                    .background(.index), .background(.transfer)]
        XCTAssertEqual(ordered.shuffled().sorted(), ordered)
        XCTAssertEqual(BackgroundWork.allCases.map { WorkClass.background($0) }, Array(ordered.dropFirst(3)))
        XCTAssertTrue(WorkClass.background(.transfer).isBackground)
        XCTAssertFalse(WorkClass.checks.isBackground)
        XCTAssertFalse(WorkClass.bulk.isBackground)
    }

    func testOnlySendAndReceiveAndWakingSayACheckStartedAndFinished() {
        XCTAssertEqual(PokeReason.allCases.filter(\.reportsProgress), [.sendAndReceive, .wake])
        XCTAssertEqual(PokeReason.allCases.filter(\.reportsNewMail), [.sendAndReceive])
    }

    func testOnlyTheReadingPaneWaitsBeforeOpening() {
        XCTAssertTrue(OpenPurpose.readingPane.waitsToSettle)
        XCTAssertFalse(OpenPurpose.window.waitsToSettle)
        XCTAssertFalse(OpenPurpose.replyOrForward.waitsToSettle)
    }

    // MARK: - Actions and drafts

    func testAnActionCarriesTheViewItWasTakenIn() {
        let account = UUID()
        let label = UUID()
        let key = RowKey.gmail(account: account, id: GmailMessageID(raw: 0x18a0_0000_0000_0010))
        let request = MailActionRequest(verb: .archive, targets: .items([.conversation(key)]), context: ListView(scope: .folder(label)))
        XCTAssertEqual(request.context.scope, .folder(label))
        XCTAssertFalse(request.isAutomatic)
        XCTAssertEqual(ActionItem.conversation(key).key, key)
        XCTAssertNotEqual(ActionItem.conversation(key), ActionItem.message(key))
        XCTAssertEqual(ActionTargets.largestItemList, 1_000)

        let everything = MailActionRequest(verb: .markRead, targets: .wholeView(except: [.message(key)]),
                                           context: ListView(scope: .folder(label), filters: [.unread]))
        guard case .wholeView(let except) = everything.targets else { return XCTFail("a whole view") }
        XCTAssertEqual(except, [.message(key)])
        XCTAssertNotEqual(MailActionRequest.Verb.move(to: label), .copy(to: label))
    }

    func testADraftsLinkSurvivesBeingWrittenAndRead() throws {
        let draft = DraftRef(localID: UUID(), accountID: UUID(), gmailDraftID: "r-5834059393",
                             gmailMessageID: GmailMessageID(raw: 0x18a0_0000_0000_0abc), threadID: GmailThreadID(raw: 0x18a0_0000_0000_0001),
                             stableMessageID: "<draft-1@falconmail>")
        let data = try JSONEncoder().encode(draft)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"18a0000000000abc\""), "ids are written as Gmail writes them: \(text)")
        XCTAssertEqual(try JSONDecoder().decode(DraftRef.self, from: data), draft)

        let unsaved = DraftRef(localID: UUID(), accountID: UUID(), stableMessageID: "<draft-2@falconmail>")
        let unsavedText = String(decoding: try JSONEncoder().encode(unsaved), as: UTF8.self)
        XCTAssertFalse(unsavedText.contains("gmailDraftID"), "nothing is written for a draft Gmail does not have yet")
        XCTAssertEqual(try JSONDecoder().decode(DraftRef.self, from: Data(unsavedText.utf8)), unsaved)
    }

    // MARK: - The protocols can be served

    func testAnActorServesTheEngineAndAClassServesTheList() async throws {
        let account = UUID()
        let key = RowKey.gmail(account: account, id: GmailMessageID(raw: 0x18a0_0000_0000_0020))
        let source = StaticListSource(account: account, rows: [key])
        let engine: any MailAccountEngine = StubEngine(accountID: account, listSource: source)
        XCTAssertEqual(engine.accountID, account)

        let view = ListView(scope: .folder(UUID()))
        let snapshot = await engine.listSource.snapshot(of: view)
        XCTAssertEqual(snapshot.rowKey(at: 0), key)
        XCTAssertEqual(snapshot.itemCount, 1)
        guard case .gone = await engine.listSource.summary(for: .stored("a:b:1"), in: view) else { return XCTFail("unknown rows are gone") }

        let receipt = try await engine.perform(MailActionRequest(verb: .flag, targets: .items([.message(key)]), context: view))
        XCTAssertEqual(receipt.messageCount, 1)
        let undone = await engine.undo(receipt.id)
        XCTAssertTrue(undone)
        await engine.poke(reason: .sendAndReceive)
        let pokes = await (engine as! StubEngine).pokes
        XCTAssertEqual(pokes, [.sendAndReceive])

        var stages: [Bool] = []
        for try await opened in await engine.open(key, purpose: .window) { stages.append(opened.isComplete) }
        XCTAssertEqual(stages, [false, true], "the text first, then again with its pictures")
    }
}

/// Serves fixed rows, to show a plain class can be a list source.
private final class StaticListSource: ListSource, @unchecked Sendable {
    let account: UUID
    let keys: [RowKey]
    let rows: AsyncStream<[RowKey: MessageRowContent]>

    init(account: UUID, rows keys: [RowKey]) {
        self.account = account
        self.keys = keys
        rows = AsyncStream { $0.finish() }
    }

    func snapshot(of view: ListView) async -> ListSnapshot {
        let records = keys.compactMap(\.gmailID).map { DisplayRecord(key: $0.raw, slot: 0) }
        return ListSnapshot(view: view, rows: ContiguousArray(records), complete: true, itemCount: records.count, sources: [account])
    }

    func changes(of view: ListView) -> AsyncStream<ListDiff> { AsyncStream { $0.finish() } }
    func requestRows(_ keys: [RowKey], priority: RowPriority) {}

    func summary(for key: RowKey, in view: ListView) async -> RowAvailability {
        keys.contains(key) ? .unavailable(reason: "not fetched") : .gone
    }
}

/// Answers every call of the engine contract, to show an actor can serve it.
private actor StubEngine: MailAccountEngine {
    nonisolated let accountID: UUID
    nonisolated let listSource: any ListSource
    private(set) var pokes: [PokeReason] = []
    private var receipts: Set<UUID> = []

    init(accountID: UUID, listSource: any ListSource) {
        self.accountID = accountID
        self.listSource = listSource
    }

    func start() async {}
    func stop() async {}
    func poke(reason: PokeReason) async { pokes.append(reason) }
    func noteOwnerActivity(_ activity: OwnerActivity) async {}
    func setUndoWindow(_ seconds: TimeInterval) async {}
    func folders() async -> [FolderInfo] { [] }
    func folderUpdates() async -> AsyncStream<[FolderInfo]> { AsyncStream { $0.finish() } }

    func createFolder(named name: String, parent: UUID?) async throws -> FolderInfo {
        FolderInfo(accountID: accountID, path: name, name: name, delimiter: "/", role: .other, attributes: [], isSelectable: true)
    }

    func perform(_ request: MailActionRequest) async throws -> ActionReceipt {
        receipts.insert(request.id)
        return ActionReceipt(id: request.id, accountID: accountID, verb: request.verb, messageCount: 1, isUndoable: true,
                             heldUntil: request.date.addingTimeInterval(5))
    }

    func undo(_ receiptID: UUID) async -> Bool { receipts.remove(receiptID) != nil }
    func hasPendingChanges() async -> Bool { !receipts.isEmpty }
    func flushPending(within seconds: TimeInterval) async -> Bool { receipts.removeAll(); return true }
    func runRulesOnInbox() async throws {}
    func search(_ query: String, id: UUID, fetchRows: Bool) async throws {}
    func endSearch(_ id: UUID) async {}

    func open(_ key: RowKey, purpose: OpenPurpose) async -> AsyncThrowingStream<OpenedMessage, Error> {
        let content = GmailOpenedMessage(gmailID: key.gmailID?.hex ?? "", message: MIMEParser.parse(Data("Subject: Hi\r\n\r\nHello".utf8)),
                                         attachments: [])
        return AsyncThrowingStream { continuation in
            continuation.yield(OpenedMessage(key: key, content: content, isComplete: false, fromCache: false))
            continuation.yield(OpenedMessage(key: key, content: content, isComplete: true, fromCache: false))
            continuation.finish()
        }
    }

    func attachmentData(_ attachment: GmailAttachmentStub, of key: RowKey) async throws -> Data { Data() }
    func rawMessage(_ key: RowKey) async throws -> Data { Data() }
    func saveDraft(_ raw: Data, as draft: DraftRef) async throws -> DraftRef { draft }
    func deleteDraft(_ draft: DraftRef) async throws {}
    func importMessages(_ messages: [ImportedMessage], into folderID: UUID, progress: @escaping @Sendable (Int) -> Void) async throws {}
}
