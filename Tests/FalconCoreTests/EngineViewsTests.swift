import XCTest
@testable import FalconCore

/// What the mailbox window's views make of a Google account on the Gmail API: its folders in the
/// order and with the names of the owner's Legacy Outlook, what a selection in the table shows in
/// the reading pane, where the selection goes when its rows leave the list, which messages of a
/// conversation a folder holds, and when every folder has been listed.
@MainActor
final class EngineViewsTests: XCTestCase {
    private let account = UUID()

    // MARK: - The sidebar

    /// The folders the engine gives for an account with two labels, one nested, in the order the
    /// engine lists them.
    private func engineFolders(group: String = "[Gmail]", labels: [(id: String, name: String)] = [("Label_1", "Clients/Acme"),
                                                                                                   ("Label_2", "Accounts")]) -> [FolderInfo] {
        var entries: [GmailLabelEntry] = GmailLabelID.fixedSlots.map {
            GmailLabelEntry(id: $0, name: $0.value, kind: .system, isShown: GmailSystemFolder(label: $0) != nil,
                            folderID: GmailLabelTable.folderID(account: account, label: $0), isComplete: true)
        }
        for label in labels {
            entries.append(GmailLabelEntry(id: GmailLabelID(label.id), name: label.name, kind: .user, isShown: true,
                                           folderID: GmailLabelTable.folderID(account: account, label: GmailLabelID(label.id)),
                                           isComplete: true))
        }
        let hints = [FolderInfo(accountID: account, path: "\(group)/Sent Mail", name: "Sent Mail", delimiter: "/", role: .sent,
                                attributes: [], isSelectable: true)]
        let index = ListFixtures.index([ListFixtures.Message(labels: [.draft], thread: 1),
                                        ListFixtures.Message(labels: [.draft], thread: 2),
                                        ListFixtures.Message(labels: [.inbox, .unread], thread: 3)])
        let tally = GmailLabelTally(snapshot: index, forFolders: true, rule: GmailCountRule())
        return GmailLabelMapping.folders(entries: entries, accountID: account, hints: hints, tally: tally, counts: [:],
                                         allMailComplete: true)
    }

    func testAGoogleAccountsFoldersReadAsLegacyOutlooksWithGmailsOwnGroupedAndLabelsAfter() {
        let nodes = OutlookFolderTree.gmail(engineFolders().shuffled(), accountID: account)
        XCTAssertEqual(nodes.map(\.folder.name),
                       ["Inbox", "[Gmail]", "Drafts", "Archive", "Sent", "Deleted Items", "Junk Email", "Important", "Starred",
                        "Accounts", "Clients", "Acme"])
        XCTAssertEqual(nodes.map(\.depth), [0, 0, 1, 1, 1, 1, 1, 1, 1, 0, 0, 1])
        let group = nodes[1]
        XCTAssertTrue(group.isGroup)
        XCTAssertTrue(group.hasChildren)
        XCTAssertFalse(group.folder.isSelectable, "the [Gmail] group holds no mail and is never selected")
        let clients = nodes[10]
        XCTAssertTrue(clients.isGroup, "a parent that is not a label of its own is a group")
        XCTAssertFalse(clients.folder.isSelectable)
        XCTAssertTrue(nodes.filter { !$0.isGroup }.allSatisfy(\.folder.isSelectable))
    }

    func testDraftsCountsItsDraftsAndTheInboxItsUnreadMail() {
        let nodes = OutlookFolderTree.gmail(engineFolders(), accountID: account)
        XCTAssertEqual(nodes.first { $0.folder.role == .drafts }?.folder.unreadCount, 2, "Drafts shows the number of drafts, as Outlook")
        XCTAssertEqual(nodes.first { $0.folder.role == .inbox }?.folder.unreadCount, 1)
    }

    func testTheGroupKeepsTheNameTheAccountUsedAndTheSameIDEveryTime() {
        let first = OutlookFolderTree.gmail(engineFolders(group: "[Google Mail]"), accountID: account)
        let again = OutlookFolderTree.gmail(engineFolders(group: "[Google Mail]"), accountID: account)
        XCTAssertEqual(first[1].folder.name, "[Google Mail]")
        XCTAssertEqual(first[1].id, again[1].id)
        XCTAssertEqual(first.first { $0.folder.name == "Clients" }?.id, again.first { $0.folder.name == "Clients" }?.id)
        XCTAssertNotEqual(first[1].id, OutlookFolderTree.gmail(engineFolders(), accountID: UUID())[1].id,
                          "another account's group is another row")
    }

    func testAnAccountWithOnlyAnInboxHasNoEmptyGroup() {
        let inbox = FolderInfo(accountID: account, path: "INBOX", name: "Inbox", delimiter: "/", role: .inbox, attributes: [],
                               isSelectable: true)
        XCTAssertEqual(OutlookFolderTree.gmail([inbox], accountID: account).map(\.folder.name), ["Inbox"])
    }

    // MARK: - What the selection shows

    private func key(_ i: UInt64) -> RowKey { .gmail(account: account, id: GmailMessageID(raw: i)) }

    private func snapshot(_ records: [DisplayRecord]) -> ListSnapshot {
        ListSnapshot(view: ListView(scope: .allInboxes), rows: ContiguousArray(records), headers: [0: "Today"], complete: true,
                     itemCount: records.count, sources: [account])
    }

    private var opened: ListSnapshot {
        snapshot([.header(group: 0),
                  DisplayRecord(key: 10, slot: 0, bits: [.expanded], members: 2, kind: .conversation),
                  DisplayRecord(key: 10, slot: 0, kind: .child),
                  DisplayRecord(key: 11, slot: 1, kind: .child),
                  DisplayRecord(key: 20, slot: 2),
                  DisplayRecord(key: 30, slot: 3)])
    }

    func testAMessageLineOfAnOpenedConversationNamesItsConversationsRow() {
        let rows = opened.selectedRows(ListSelection(rows: [1, 3, 4]))
        XCTAssertEqual(rows, [SelectedListRow(row: 1, key: key(10), kind: .conversation),
                              SelectedListRow(row: 3, key: key(11), kind: .member(parent: key(10))),
                              SelectedListRow(row: 4, key: key(20), kind: .message)])
        XCTAssertEqual(opened.parentRow(of: 2), 1)
        XCTAssertNil(opened.parentRow(of: 4))
    }

    func testMoreThanAThousandSelectedRowsAreNeverHandedOnAsAPart() {
        let many = snapshot((0..<1_001).map { DisplayRecord(key: UInt64($0 + 1), slot: Int32($0)) })
        XCTAssertNil(many.selectedRows(.all()))
        XCTAssertEqual(many.selectedRows(ListSelection(rows: IndexSet(integersIn: 0..<1_000)))?.count, 1_000)
    }

    // MARK: - Where the selection goes

    func testDeletingTheSelectedRowSelectsTheOneAfterOrBeforeAsSettingsSay() {
        let after = snapshot([.header(group: 0), DisplayRecord(key: 10, slot: 0), DisplayRecord(key: 30, slot: 1)])
        // Row 2 (key 20) of [header, 10, 20, 30] went.
        XCTAssertEqual(ListAdvance.row(selected: [2], removed: [2], in: after, forward: true), 2, "the row that followed")
        XCTAssertEqual(ListAdvance.row(selected: [2], removed: [2], in: after, forward: false), 1, "the row before")
        // The first message went: going back finds only the header, so it goes forward.
        let first = snapshot([.header(group: 0), DisplayRecord(key: 20, slot: 0)])
        XCTAssertEqual(ListAdvance.row(selected: [1], removed: [1], in: first, forward: false), 1)
        // The last went: forward finds nothing, so it goes back.
        let last = snapshot([.header(group: 0), DisplayRecord(key: 10, slot: 0)])
        XCTAssertEqual(ListAdvance.row(selected: [2], removed: [2], in: last, forward: true), 1)
    }

    func testTheSelectionStaysPutWhenSomeOfItStayed() {
        let after = snapshot([DisplayRecord(key: 10, slot: 0)])
        XCTAssertNil(ListAdvance.row(selected: [0, 1], removed: [1], in: after, forward: true))
        XCTAssertNil(ListAdvance.row(selected: [], removed: [1], in: after, forward: true))
        XCTAssertNil(ListAdvance.row(selected: [0], removed: [0], in: snapshot([]), forward: true))
    }

    // MARK: - A conversation's messages in a folder

    func testAConversationInTheInboxHoldsItsInboxMessagesNeverTheOwnersRepliesInSent() {
        let index = ListFixtures.index([
            ListFixtures.Message(labels: [.inbox, .unread], thread: 7),
            ListFixtures.Message(labels: [.sent], thread: 7),
            ListFixtures.Message(labels: [.inbox, .trash], thread: 7),
            ListFixtures.Message(labels: [.inbox], thread: 8),
            ListFixtures.Message(labels: [.inbox], thread: 7)
        ])
        let thread = ListFixtures.baseID + 7 * 16 + 1
        XCTAssertEqual(index.conversationMembers(thread: thread, label: .inbox), [ListFixtures.id(0), ListFixtures.id(4)],
                       "newest first; the reply in Sent and the one in Deleted Items are left out")
        XCTAssertEqual(index.conversationMembers(thread: thread, label: nil), [ListFixtures.id(0), ListFixtures.id(1), ListFixtures.id(4)],
                       "Archive holds every message but those in Deleted Items")
        XCTAssertEqual(index.conversationMembers(thread: thread, label: .trash), [ListFixtures.id(2)])
        XCTAssertEqual(index.conversationMembers(thread: thread, label: .inbox, limit: 1), [ListFixtures.id(0)])
    }

    // MARK: - Up to date

    func testEveryFolderIsListedOnlyOnceAllMailEveryShownFolderAndTheReadStateAre() {
        let folder = UUID()
        var labels = [GmailLabelEntry(id: .inbox, name: "INBOX", kind: .system, isShown: true, folderID: folder, isComplete: true),
                      GmailLabelEntry(id: .unread, name: "UNREAD", kind: .system, isShown: false, folderID: folder, isComplete: false),
                      GmailLabelEntry(id: "Label_9", name: "Hidden", kind: .user, isShown: false, folderID: folder, isComplete: false)]
        XCTAssertFalse(ListStatusText.everyFolderListed(allMailComplete: true, labels: labels), "the read state is still being listed")
        labels[1].isComplete = true
        XCTAssertTrue(ListStatusText.everyFolderListed(allMailComplete: true, labels: labels), "a hidden label is never listed")
        XCTAssertFalse(ListStatusText.everyFolderListed(allMailComplete: false, labels: labels))
    }

    // MARK: - The controller

    func testTheAppCanChooseTheSelectionAndTheTableIsToldToShowIt() async {
        let source = ScriptedListSource(ListSnapshots.rows([1, 2, 3], account: account))
        let list = ListController()
        var changes: [String] = []
        var before: [ListSelection] = []
        list.onChange = { if case .selection = $0 { changes.append("selection") } }
        list.onApplied = { change, selected in
            if case .selection = change { before.append(selected) }
        }
        await list.show(ListView(scope: .allInboxes), from: source)
        list.setSelection(ListSelection(rows: [0]))
        list.select(rows: [2])
        XCTAssertEqual(list.selection, ListSelection(rows: [2]))
        XCTAssertEqual(list.selectionCount, 1)
        XCTAssertEqual(changes, ["selection"])
        XCTAssertEqual(before, [ListSelection(rows: [0])])
    }

    func testSortingTheSameFolderAnotherWayKeepsTheSelectionAndAnotherFolderStartsWithNone() async {
        let folder = UUID()
        let byDate = ListView(scope: .folder(folder))
        let source = ScriptedListSource(ListSnapshots.rows([1, 2, 3], account: account, view: byDate))
        let list = ListController()
        var reloadSelections: [ListSelection] = []
        list.onChange = { if case .reload = $0 { reloadSelections.append(list.selection) } }
        await list.show(byDate, from: source)
        list.setSelection(ListSelection(rows: [1]))
        var oldestFirst = byDate
        oldestFirst.sort = ListSortSpec(key: .date, ascending: true)
        let reversed = ScriptedListSource(ListSnapshots.rows([3, 2, 1], account: account, view: oldestFirst))
        await list.show(oldestFirst, from: reversed)
        XCTAssertEqual(list.selectedKeys, [key(2)], "the same message stays selected")
        XCTAssertEqual(reloadSelections.last, list.selection, "the table reloads with the selection already carried")
        await list.show(ListView(scope: .folder(UUID())), from: reversed)
        XCTAssertTrue(list.selection.isEmpty)
        XCTAssertEqual(reloadSelections.last, ListSelection.none, "another folder reloads with nothing selected")
    }

    func testRowsThatLeaveTheListAreReportedWithTheSelectionBeforeThem() async {
        let first = ListSnapshots.rows([10, 20, 30], account: account)
        let source = ScriptedListSource(first)
        let list = ListController()
        var seen: [(ListControllerChange, ListSelection)] = []
        list.onApplied = { seen.append(($0, $1)) }
        await list.show(ListView(scope: .allInboxes), from: source)
        list.setSelection(ListSelection(rows: [1]))
        let after = ListSnapshots.rows([10, 30], account: account)
        source.send(ListDiff(removed: [1], snapshot: after))
        for _ in 0..<200 where seen.count < 2 { try? await Task.sleep(nanoseconds: 5_000_000) }
        guard let last = seen.last, case .diff(let diff) = last.0 else { return XCTFail("the diff is reported") }
        XCTAssertEqual(diff.removed, [1])
        XCTAssertEqual(last.1, ListSelection(rows: [1]), "with what was selected before")
        XCTAssertTrue(list.selection.isEmpty)
        XCTAssertEqual(ListAdvance.row(selected: [1], removed: diff.removed, in: list.snapshot, forward: true), 1)
    }
}
