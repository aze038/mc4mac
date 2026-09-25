import XCTest
@testable import FalconCore

@MainActor
final class ListControllerTests: XCTestCase {
    private let account = UUID()
    private var clock: TimeInterval = 100

    private func key(_ raw: UInt64) -> RowKey { .gmail(account: account, id: GmailMessageID(raw: raw)) }

    private func controller() -> ListController {
        ListController(uptime: { [unowned self] in self.clock })
    }

    /// Lets the controller's tasks run until `condition` holds, or a second passes.
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testShowingAViewReloadsTheTableAndPublishesItsItems() async {
        let source = ScriptedListSource(ListSnapshots.rows(Array(1...50), account: account, itemCount: 200_000))
        let list = controller()
        var changes: [ListControllerChange] = []
        list.onChange = { changes.append($0) }
        await list.show(ListView(scope: .allInboxes), from: source)
        XCTAssertEqual(list.rowCount, 50)
        XCTAssertEqual(list.itemCount, 200_000)
        XCTAssertEqual(ListStatusText.items(list.itemCount, locale: Locale(identifier: "en_GB")), "Items: 200,000")
        guard case .reload? = changes.first else { return XCTFail("a new view reloads the table") }
    }

    func testTheFirstScreenIsAskedForAtOnceAndNothingDuringAFling() async {
        let source = ScriptedListSource(ListSnapshots.rows(Array(1...5_000), account: account))
        let list = controller()
        await list.show(ListView(scope: .allInboxes), from: source)
        list.scrolled(visible: 0..<25)
        XCTAssertEqual(source.requests.last?.keys.count, 25)
        XCTAssertEqual(source.requests.last?.priority, .visible)
        source.clearRequests()
        for step in 1...10 {
            clock += 0.016
            list.scrolled(visible: (step * 40)..<(step * 40 + 25))
        }
        XCTAssertTrue(source.requests.isEmpty, "nothing is asked for during a fling")
        clock += 0.2
        list.settled()
        XCTAssertEqual(source.requests.map(\.priority), [.visible, .ahead])
        XCTAssertEqual(source.requests[0].keys, (401...425).map { key(UInt64($0)) })
        XCTAssertEqual(source.requests[1].keys, (426...450).map { key(UInt64($0)) })
    }

    func testRowsWhoseTextIsHeldAreNotAskedForAgain() async {
        let source = ScriptedListSource(ListSnapshots.rows(Array(1...30), account: account))
        let list = controller()
        await list.show(ListView(scope: .allInboxes), from: source)
        source.send(rows: [key(1): ListSnapshots.content(key(1)), key(2): ListSnapshots.content(key(2))])
        await until { list.content.count == 2 }
        XCTAssertEqual(list.rowContent(at: 0)?.from.name, "Ana")
        XCTAssertNil(list.rowContent(at: 5), "a row not fetched yet is nil at once, never waited for")
        list.scrolled(visible: 0..<10)
        XCTAssertEqual(source.requests.last?.keys, (3...10).map { key(UInt64($0)) })
    }

    func testTextArrivingIsPassedToTheTableForTheRowsOnScreen() async {
        let source = ScriptedListSource(ListSnapshots.rows([1, 2, 3], account: account))
        let list = controller()
        var arrived: Set<RowKey> = []
        list.onChange = { change in if case .content(let keys) = change { arrived.formUnion(keys) } }
        await list.show(ListView(scope: .allInboxes), from: source)
        source.send(rows: [key(2): ListSnapshots.content(key(2))])
        await until { !arrived.isEmpty }
        XCTAssertEqual(arrived, [key(2)])
    }

    func testADiffMovesTheSelectionWithItsRowsAndOneThatDoesNotFitReloads() async {
        let first = ListSnapshots.rows([10, 20, 30, 40], account: account)
        let source = ScriptedListSource(first)
        let list = controller()
        var changes: [ListControllerChange] = []
        list.onChange = { changes.append($0) }
        await list.show(ListView(scope: .allInboxes), from: source)
        list.setSelection(ListSelection(rows: [1, 3]))
        // A new message at the top, and the second row gone.
        let next = ListSnapshots.rows([5, 10, 30, 40], account: account)
        source.send(ListDiffer.diff(from: first, to: next))
        await until { list.rowCount == 4 && list.snapshot.rows[0].key == 5 }
        XCTAssertEqual(list.selection, ListSelection(rows: [3]), "20 went; 40 moved down with the new row")
        guard case .diff? = changes.last else { return XCTFail("a small change animates") }

        // Worked out against another snapshot: the table reloads rather than going wrong.
        let stale = ListDiff(inserted: [0, 1, 2, 3, 4, 5], removed: [0], snapshot: ListSnapshots.rows([1, 2, 3], account: account))
        source.send(stale)
        await until { list.rowCount == 3 }
        guard case .reload? = changes.last else { return XCTFail("expected a reload") }
        XCTAssertTrue(list.selection.isEmpty, "40 is not in the new view")
    }

    func testAChangeTooLargeToAnimateKeepsTheSelectedMessagesSelected() async {
        let first = ListSnapshots.rows(Array(1...600), account: account)
        let source = ScriptedListSource(first)
        let list = controller()
        await list.show(ListView(scope: .allInboxes), from: source)
        list.setSelection(ListSelection(rows: [9, 99]))
        // Six hundred new messages at the top: too many to animate.
        let next = ListSnapshots.rows(Array(1_001...1_600) + Array(1...600), account: account)
        source.send(ListDiffer.diff(from: first, to: next))
        await until { list.rowCount == 1_200 }
        XCTAssertEqual(list.selection, ListSelection(rows: [609, 699]), "rows 10 and 100 are still the ones selected")
    }

    func testMailArrivingAfterSelectAllIsNotPartOfIt() {
        let shifted = ListController.shifted(.all(except: [2]), removed: [], inserted: [0])
        XCTAssertEqual(shifted, .all(except: [0, 3]))
    }

    func testOpeningAConversationAsksTheSourceAndItsMessagesReadFromItsMembers() async {
        let conversation = key(1)
        let members = [ConversationMember(key: key(7), from: EmailAddress(name: "Owner", address: "o@example.com"), date: Date(),
                                          folderName: "Sent"),
                       ConversationMember(key: key(1), from: EmailAddress(name: "Ana", address: "a@example.com"), date: Date())]
        let closed = ListSnapshots.rows([1, 2], account: account, kinds: [1: .conversation])
        let source = ScriptedListSource(closed)
        let list = controller()
        await list.show(ListView(scope: .allInboxes), from: source)
        source.send(rows: [conversation: ListSnapshots.content(conversation, members: members)])
        await until { list.content.count == 1 }
        await list.toggleExpanded(row: 0)
        XCTAssertEqual(source.expandedRequests.last, [conversation])

        var rows = closed.rows
        rows[0].displayBits.insert(.expanded)
        rows.insert(DisplayRecord(key: 7, slot: 7, kind: .child), at: 1)
        rows.insert(DisplayRecord(key: 1, slot: 1, kind: .child), at: 2)
        let open = ListSnapshot(view: closed.view, rows: rows, complete: true, itemCount: 3, sources: [account])
        source.send(ListDiffer.diff(from: closed, to: open))
        await until { list.rowCount == 4 }
        XCTAssertEqual(list.parentRow(of: 1), 0)
        XCTAssertEqual(list.rowContent(at: 1)?.from.name, "Owner")
        XCTAssertEqual(list.childFolderName(at: 1), "Sent")
        XCTAssertFalse(list.isLastChild(1))
        XCTAssertTrue(list.isLastChild(2))
        XCTAssertTrue(list.isExpanded(0))

        await list.toggleExpanded(row: 0)
        XCTAssertEqual(source.expandedRequests.last, [])
    }

    func testFootersFromTheSourceArePublished() async {
        let source = ScriptedListSource(ListSnapshots.rows([1], account: account))
        let list = controller()
        await list.show(ListView(scope: .allInboxes), from: source)
        source.send(footers: [.loading(email: "owner@example.com")])
        await until { !list.footers.isEmpty }
        XCTAssertEqual(list.footers, [.loading(email: "owner@example.com")])
    }

    func testCommandsOnMoreThanAThousandRowsGoToTheWholeViewOrRefuse() async {
        let source = ScriptedListSource(ListSnapshots.rows(Array(1...1_001), account: account))
        let list = controller()
        await list.show(ListView(scope: .allInboxes), from: source)
        list.selectAll()
        XCTAssertEqual(list.selectionCount, 1_001)
        XCTAssertNil(list.selectedKeys)
        XCTAssertEqual(list.targets(for: .archive), .wholeView(except: []))
        XCTAssertEqual(list.targets(for: .forward), .refused("Select 1,000 messages or fewer for this command."))
    }

    func testTheStatusBarSaysUpToDateOnlyOnceEveryFolderIsListedAndEveryAccountReachable() {
        let list = controller()
        XCTAssertNil(list.stateText(everyAccountReachable: true), "not while any folder is still being listed")
        list.everyFolderListed = true
        XCTAssertEqual(list.stateText(everyAccountReachable: true), "All folders are up to date.")
        XCTAssertNil(list.stateText(everyAccountReachable: false))
        list.syncProgress = ListSyncProgress(email: "owner@example.com", listed: 12_000, total: 55_000)
        XCTAssertEqual(ListStatusText.progress(list.syncProgress!, locale: Locale(identifier: "en_GB")),
                       "Syncing owner@example.com: 12,000 of 55,000 messages")
    }
}
