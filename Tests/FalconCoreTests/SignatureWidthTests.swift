import AppKit
import XCTest
@testable import FalconCore

/// A signature is measured at its own size: its widest line, picture or table, never the
/// window's width.
final class SignatureWidthTests: XCTestCase {
    private let font = NSFont.systemFont(ofSize: 13)

    func testAnEmptySignatureHasNoWidth() {
        XCTAssertEqual(SignatureWidth.natural(of: NSAttributedString()), 0)
    }

    func testALongLineIsMeasuredOnOneLine() {
        let short = NSAttributedString(string: "Kamal", attributes: [.font: font])
        let long = NSAttributedString(string: String(repeating: "Freight Masters LLC ", count: 20), attributes: [.font: font])
        let longWidth = SignatureWidth.natural(of: long)
        XCTAssertGreaterThan(longWidth, SignatureWidth.natural(of: short) * 10)
        XCTAssertGreaterThan(longWidth, 1000, "twenty repeats of the name on one line are wider than any window's box")
    }

    func testTheWidestParagraphSetsTheWidth() {
        let wide = String(repeating: "W", count: 60)
        let text = NSAttributedString(string: "Hi\n\(wide)\nBye", attributes: [.font: font])
        let alone = SignatureWidth.natural(of: NSAttributedString(string: wide, attributes: [.font: font]))
        XCTAssertEqual(SignatureWidth.natural(of: text), alone, accuracy: 1)
    }

    func testAPictureIsAsWideAsItsOwnSize() {
        let attachment = NSTextAttachment()
        attachment.bounds = NSRect(x: 0, y: 0, width: 900, height: 120)
        let text = NSAttributedString(attachment: attachment)
        XCTAssertGreaterThanOrEqual(SignatureWidth.natural(of: text), 900)
    }

    func testATableGivenAWidthInPointsIsThatWide() {
        let table = NSTextTable()
        table.numberOfColumns = 2
        table.setContentWidth(720, type: .absoluteValueType)
        let text = row(in: table, cells: ["Shahin", "Director"])
        XCTAssertGreaterThanOrEqual(SignatureWidth.natural(of: text), 720)
        XCTAssertLessThan(SignatureWidth.natural(of: text), 760)
    }

    func testATableWithoutAWidthIsAsWideAsItsColumns() {
        let table = NSTextTable()
        table.numberOfColumns = 2
        let left = String(repeating: "L", count: 50)
        let right = String(repeating: "R", count: 50)
        let text = row(in: table, cells: [left, right])
        let both = SignatureWidth.natural(of: NSAttributedString(string: left, attributes: [.font: font]))
            + SignatureWidth.natural(of: NSAttributedString(string: right, attributes: [.font: font]))
        XCTAssertGreaterThanOrEqual(SignatureWidth.natural(of: text), both - 2, "columns side by side, not wrapped")
    }

    func testATableAsAShareOfThePageIsMeasuredByWhatItHolds() {
        let table = NSTextTable()
        table.numberOfColumns = 1
        table.setContentWidth(100, type: .percentageValueType)
        let words = String(repeating: "Freight ", count: 30)
        let text = row(in: table, cells: [words])
        let alone = SignatureWidth.natural(of: NSAttributedString(string: words, attributes: [.font: font]))
        XCTAssertGreaterThanOrEqual(SignatureWidth.natural(of: text), alone - 2)
        XCTAssertEqual(table.contentWidthValueType, .percentageValueType, "the table's own size is left as it was")
    }

    /// One row of `table`, a cell for each string, as AppKit reads an HTML table.
    private func row(in table: NSTextTable, cells: [String]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for (column, string) in cells.enumerated() {
            let cell = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: column, columnSpan: 1)
            let style = NSMutableParagraphStyle()
            style.textBlocks = [cell]
            text.append(NSAttributedString(string: string + "\n", attributes: [.font: font, .paragraphStyle: style]))
        }
        return text
    }
}
