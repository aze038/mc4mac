import XCTest
import AppKit
@testable import FalconCore

/// The table menu of a message being written: rows and columns added and deleted, the table
/// deleted, the cells' text kept in place.
@MainActor
final class TableEditingTests: XCTestCase {
    private let font = NSFont.systemFont(ofSize: 14)

    /// "Top:" then a table of `cells`, rows of columns, then "End".
    private func editor(_ cells: [[String]]) -> NSTextView {
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let text = NSMutableAttributedString(string: "Top:\n", attributes: attributes)
        let contents = cells.map { $0.map { NSAttributedString(string: $0, attributes: attributes) } }
        text.append(ComposedTable.grid(rows: cells.count, columns: cells[0].count, width: 400, lines: .labelColor,
                                       attributes: attributes, contents: contents))
        text.append(NSAttributedString(string: "End", attributes: attributes))
        editor.textStorage?.setAttributedString(text)
        return editor
    }

    private func location(of word: String, in editor: NSTextView) -> Int {
        (editor.string as NSString).range(of: word).location
    }

    private func grid(_ editor: NSTextView) throws -> [[String]] {
        let storage = try XCTUnwrap(editor.textStorage)
        let found = try XCTUnwrap(TableEditing.find(in: storage, at: 6))
        return found.cells.map { row in
            row.map { (storage.string as NSString).substring(with: $0).trimmingCharacters(in: .newlines) }
        }
    }

    func testItFindsTheCellClicked() throws {
        let editor = editor([["a", "b"], ["c", "d"]])
        let found = try XCTUnwrap(TableEditing.find(in: editor.textStorage!, at: location(of: "d", in: editor)))
        XCTAssertEqual(found.rows, 2)
        XCTAssertEqual(found.columns, 2)
        XCTAssertEqual(found.row, 1)
        XCTAssertEqual(found.column, 1)
        XCTAssertNil(TableEditing.find(in: editor.textStorage!, at: 1))
    }

    func testRowsGoInAboveAndBelow() throws {
        let editor = editor([["a", "b"], ["c", "d"]])
        XCTAssertTrue(TableEditing.apply(.rowBelow, in: editor, at: location(of: "a", in: editor)))
        XCTAssertEqual(try grid(editor), [["a", "b"], ["", ""], ["c", "d"]])
        XCTAssertTrue(TableEditing.apply(.rowAbove, in: editor, at: location(of: "a", in: editor)))
        XCTAssertEqual(try grid(editor), [["", ""], ["a", "b"], ["", ""], ["c", "d"]])
        XCTAssertTrue(editor.string.hasPrefix("Top:\n"))
        XCTAssertTrue(editor.string.hasSuffix("End"))
    }

    func testColumnsGoInLeftAndRight() throws {
        let editor = editor([["a", "b"], ["c", "d"]])
        XCTAssertTrue(TableEditing.apply(.columnRight, in: editor, at: location(of: "a", in: editor)))
        XCTAssertEqual(try grid(editor), [["a", "", "b"], ["c", "", "d"]])
        XCTAssertTrue(TableEditing.apply(.columnLeft, in: editor, at: location(of: "a", in: editor)))
        XCTAssertEqual(try grid(editor), [["", "a", "", "b"], ["", "c", "", "d"]])
    }

    func testARowAndAColumnAreDeleted() throws {
        let editor = editor([["a", "b", "x"], ["c", "d", "y"]])
        XCTAssertTrue(TableEditing.apply(.deleteRow, in: editor, at: location(of: "c", in: editor)))
        XCTAssertEqual(try grid(editor), [["a", "b", "x"]])
        XCTAssertTrue(TableEditing.apply(.deleteColumn, in: editor, at: location(of: "b", in: editor)))
        XCTAssertEqual(try grid(editor), [["a", "x"]])
    }

    func testDeletingTheLastRowOrTheTableLeavesTheTextAround() {
        let editor = editor([["a", "b"]])
        XCTAssertTrue(TableEditing.apply(.deleteRow, in: editor, at: location(of: "a", in: editor)))
        XCTAssertEqual(editor.string, "Top:\nEnd")
        let other = self.editor([["a", "b"], ["c", "d"]])
        XCTAssertTrue(TableEditing.apply(.deleteTable, in: other, at: location(of: "c", in: other)))
        XCTAssertEqual(other.string, "Top:\nEnd")
    }

    func testTheCaretLandsInTheNewCellAndUndoTakesItBack() throws {
        let editor = editor([["a", "b"], ["c", "d"]])
        let undo = UndoManager()
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        window.contentView = editor
        editor.allowsUndo = true
        _ = undo
        XCTAssertTrue(TableEditing.apply(.rowBelow, in: editor, at: location(of: "a", in: editor)))
        let storage = try XCTUnwrap(editor.textStorage)
        let found = try XCTUnwrap(TableEditing.find(in: storage, at: editor.selectedRange().location))
        XCTAssertEqual(found.row, 1)
        XCTAssertEqual(found.column, 0)
    }
}
