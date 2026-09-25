import XCTest
@testable import FalconCore

final class ListSelectionTests: XCTestCase {
    private let account = UUID()

    private func snapshot(_ count: Int, conversationsEvery: Int = 3) -> ListSnapshot {
        var rows = ContiguousArray<DisplayRecord>()
        rows.append(.header(group: 0))
        for i in 0..<count {
            rows.append(DisplayRecord(key: 0x1000 + UInt64(i), slot: Int32(i), members: i % conversationsEvery == 0 ? 2 : 1,
                                      kind: i % conversationsEvery == 0 ? .conversation : .message))
        }
        return ListSnapshot(view: ListView(scope: .allInboxes), rows: rows, headers: [0: "Today"], complete: true,
                            itemCount: count, sources: [account])
    }

    /// Every command, given 1,001 selected rows, either acts on the whole view or refuses; none
    /// acts on the first thousand and leaves the rest.
    func testOneThousandAndOneSelectedRowsNeverActOnAThousand() {
        let whole = snapshot(1_001)
        let part = snapshot(5_000)
        let selections: [(ListSelection, ListSnapshot)] = [
            (.all(), whole),
            (ListSelection(rows: IndexSet(integersIn: 1...1_001)), whole),
            (ListSelection(rows: IndexSet(integersIn: 1...1_001)), part),
            (.all(except: IndexSet(integersIn: 1_002...5_000)), part)
        ]
        for (selection, snapshot) in selections {
            XCTAssertEqual(selection.count(in: snapshot), 1_001)
            XCTAssertNil(selection.rowKeys(in: snapshot), "code that passes ids is never handed a part")
            for command in ListCommand.allCases {
                let targets = selection.targets(for: command, in: snapshot)
                switch targets {
                case .items(let items):
                    XCTFail("\(command) would act on \(items.count) of 1,001")
                case .wholeView(let except):
                    XCTAssertTrue(command.actsOnWholeView)
                    XCTAssertLessThanOrEqual(except.count, ActionTargets.largestItemList)
                case .refused(let sentence):
                    XCTAssertEqual(sentence, "Select 1,000 messages or fewer for this command.")
                }
            }
        }
    }

    func testMoveArchiveDeleteReadFlagJunkAndCategoriseHandOverToTheWholeView() {
        let whole = snapshot(3_000)
        let selection = ListSelection.all(except: [5, 9])
        for command in [ListCommand.move, .archive, .delete, .markRead, .markUnread, .flag, .unflag, .junk, .notJunk, .categorise] {
            guard case .wholeView(let except) = selection.targets(for: command, in: whole) else {
                return XCTFail("\(command) should act on the whole view")
            }
            XCTAssertEqual(except.map(\.key), [whole.rowKey(at: 5)!, whole.rowKey(at: 9)!])
        }
        for command in [ListCommand.reply, .forward, .open, .mute, .copy, .deleteForever] {
            XCTAssertEqual(selection.targets(for: command, in: whole), .refused(ListStatusText.tooManySelected))
        }
        // A range of 1,001 in a much larger folder is not the whole view less a few, so even
        // Archive refuses rather than archiving everything.
        let range = ListSelection(rows: IndexSet(integersIn: 1...1_001))
        XCTAssertEqual(range.targets(for: .archive, in: snapshot(10_000)), .refused(ListStatusText.tooManySelected))
    }

    func testAThousandRowsOrFewerAreNamedOneByOneWithConversationsAsSuch() {
        let s = snapshot(1_500)
        let selection = ListSelection(rows: IndexSet(integersIn: 0...1_000))
        guard case .items(let items) = selection.targets(for: .reply, in: s) else { return XCTFail("expected items") }
        XCTAssertEqual(items.count, 1_000, "the header row is not a message")
        XCTAssertEqual(items[0], .conversation(s.rowKey(at: 1)!))
        XCTAssertEqual(items[1], .message(s.rowKey(at: 2)!))
        XCTAssertEqual(selection.rowKeys(in: s)?.count, 1_000)
        XCTAssertEqual(ListSelection.none.targets(for: .archive, in: s), .refused(ListStatusText.nothingSelected))
        XCTAssertEqual(ListCommand(.move(to: UUID())), .move)
    }
}
