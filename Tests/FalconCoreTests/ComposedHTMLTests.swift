import XCTest
import AppKit
@testable import FalconCore

final class ComposedHTMLTests: XCTestCase {
    private let font = NSFont.systemFont(ofSize: 14)

    /// A draft with a table as the composer inserts it, its lines and text in `lines` and `ink`.
    private func table(columns: Int, rows: Int, text: (Int, Int) -> String,
                       lines: NSColor = .labelColor, ink: NSColor = .labelColor) -> NSMutableAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let body = NSMutableAttributedString(string: "Figures:\n", attributes: attributes)
        let grid = NSMutableAttributedString(attributedString: ComposedTable.grid(rows: rows, columns: columns, width: 600,
                                                                                  lines: lines, attributes: attributes))
        // Every cell is an empty paragraph, so cell n starts at n; fill from the last.
        for cell in (0..<(rows * columns)).reversed() {
            let cellAttributes = grid.attributes(at: cell, effectiveRange: nil)
            grid.insert(NSAttributedString(string: text(cell / columns, cell % columns), attributes: cellAttributes), at: cell)
        }
        body.append(grid)
        body.append(NSAttributedString(string: "\n", attributes: attributes))
        return body
    }

    /// What is sent is built from the draft's RTF, so every test goes through it as the app does.
    private func sent(_ text: NSAttributedString) throws -> String {
        let rtf = try XCTUnwrap(text.rtf(from: NSRange(location: 0, length: text.length),
                                         documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]))
        let stored = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        return try XCTUnwrap(ComposedHTML.html(from: stored))
    }

    private func cells(in html: String) -> [String] {
        html.components(separatedBy: "<td").dropFirst().map { String($0.prefix { $0 != ">" }) }
    }

    func testTableLinesAreSentAsOnePixelSolidBlack() throws {
        let html = try sent(table(columns: 3, rows: 2) { "r\($0)c\($1)" })
        let cells = cells(in: html)
        XCTAssertEqual(cells.count, 6)
        for (index, cell) in cells.enumerated() {
            // As Outlook writes Table Grid: right and bottom everywhere, top on the first row,
            // left on the first column (CSS order: top, right, bottom, left).
            let top = index < 3, left = index % 3 == 0
            let width = { (drawn: Bool) in drawn ? "1.0px" : "0.0px" }
            let colour = { (drawn: Bool) in drawn ? "#000000" : "transparent" }
            XCTAssertTrue(cell.contains("border-style: solid"), cell)
            XCTAssertTrue(cell.contains("border-width: \(width(top)) 1.0px 1.0px \(width(left))"), cell)
            XCTAssertTrue(cell.contains("border-color: \(colour(top)) #000000 #000000 \(colour(left))"), cell)
            XCTAssertTrue(cell.contains("padding: 0.0px 5.4px 0.0px 5.4px"), cell)
        }
        XCTAssertTrue(html.contains("border-collapse: collapse"))
        XCTAssertTrue(html.contains("r1c2"))
    }

    func testTheGridKeepsItsWidthsThroughTheDraftsRTF() throws {
        let text = table(columns: 4, rows: 1) { _, _ in "x" }
        let rtf = try XCTUnwrap(text.rtf(from: NSRange(location: 0, length: text.length),
                                         documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]))
        let stored = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        let at = (stored.string as NSString).range(of: "x").location
        let style = try XCTUnwrap(stored.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle)
        let block = try XCTUnwrap(style.textBlocks.first as? NSTextTableBlock)
        XCTAssertEqual(block.table.contentWidth, 600, accuracy: 0.5)
        XCTAssertEqual(block.table.contentWidthValueType, .absoluteValueType)
        XCTAssertEqual(block.valueType(for: .width), .absoluteValueType)
        XCTAssertEqual(block.value(for: .width), 600 / 4 - 2 * 5.4 - 1, accuracy: 1)
        XCTAssertEqual(block.borderColor(for: .maxX), .labelColor)
    }

    func testAutomaticTextIsSentWithoutAColour() throws {
        let html = try sent(table(columns: 2, rows: 1) { _, column in column == 0 ? "Region" : "Total" })
        XCTAssertFalse(html.contains("rgba"), html)
        XCTAssertFalse(html.contains("color=\""), html)
        XCTAssertFalse(html.contains("; color:"), html)
        XCTAssertFalse(html.contains("\"color:"), html)
    }

    func testDarkAppearanceIsNotBakedIn() throws {
        var drawn: String?
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            drawn = try? sent(table(columns: 2, rows: 2) { "\($0)\($1)" })
        }
        let html = try XCTUnwrap(drawn)
        XCTAssertFalse(html.lowercased().contains("#ffffff"), html)
        XCTAssertFalse(html.contains("255, 255, 255"), html)
        XCTAssertEqual(cells(in: html).filter { $0.contains("#000000 #000000") }.count, 4)
    }

    func testColoursChosenByHandAreKept() throws {
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let html = try sent(table(columns: 1, rows: 1, text: { _, _ in "Alert" }, lines: red, ink: red))
        let cell = try XCTUnwrap(cells(in: html).first)
        // RTF stores the red a shade off pure; what matters is that it is still red, not black.
        let found = try XCTUnwrap(cell.range(of: "border-color: #[0-9a-f]{6}", options: .regularExpression))
        let hex = String(cell[found].suffix(7))
        XCTAssertTrue(hex.hasPrefix("#f"), cell)
        XCTAssertTrue(html.contains("color: \(hex)\">Alert"), html)
    }

    func testAParagraphBreakInsideACellKeepsItOneCell() throws {
        let text = table(columns: 2, rows: 1) { _, column in column == 0 ? "North" : "South" }
        // A second paragraph in the first cell shares that cell's block.
        let first = (text.string as NSString).range(of: "North\n")
        let attributes = text.attributes(at: first.location, effectiveRange: nil)
        text.insert(NSAttributedString(string: "East\n", attributes: attributes), at: NSMaxRange(first))
        let html = try sent(text)
        XCTAssertEqual(cells(in: html).count, 2, html)
        let firstCell = try XCTUnwrap(html.components(separatedBy: "</td>").first)
        XCTAssertTrue(firstCell.contains("North") && firstCell.contains("East"), html)
    }

    func testTheDraftItselfIsLeftAlone() throws {
        let text = table(columns: 1, rows: 1) { _, _ in "Cell" }
        _ = ComposedHTML.html(from: text)
        let at = (text.string as NSString).range(of: "Cell").location
        let style = try XCTUnwrap(text.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle)
        let block = try XCTUnwrap(style.textBlocks.first)
        XCTAssertEqual(block.borderColor(for: .minX), .labelColor)
        XCTAssertEqual(text.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor, .labelColor)
    }
}
