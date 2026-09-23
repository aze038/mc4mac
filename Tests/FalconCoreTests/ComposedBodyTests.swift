import XCTest
import AppKit
@testable import FalconCore

@MainActor
final class ComposedBodyTests: XCTestCase {
    private let font = NSFont.systemFont(ofSize: 14)
    private let historyPlain = "\n________________________________\nFrom: Sam Sender <sam@example.com>\nSubject: Figures\n\nThe numbers are in 📈.\n"
    private let historyHTML = "<div id=\"original\"><p>The numbers are in 📈.</p></div>"
    private let signature = "-- \nAlex Example\nExample Ltd\n\n"

    /// A body as the composer shows a draft: the text set in one go, as a draft is loaded.
    private func editor(_ text: String, width: CGFloat = 700) -> NSTextView {
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        editor.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        return editor
    }

    /// What goes out, built as the draft stores the body: its RTF and its plain text.
    private func sent(_ editor: NSTextView) throws -> String {
        let storage = try XCTUnwrap(editor.textStorage)
        let rtf = storage.rtf(from: NSRange(location: 0, length: storage.length),
                              documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        return ComposedHTML.document(rtf: rtf, plain: storage.string, historyPlain: historyPlain, historyHTML: historyHTML)
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    func testASignatureInsertedBeforeTheBodyIsClickedGoesAboveTheOriginal() throws {
        let editor = editor("\n\n" + historyPlain)
        // Nobody has clicked the body: the caret is wherever the load left it, at worst the end.
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        ComposedBody.insertSignature(signature, into: editor, before: historyPlain)

        XCTAssertTrue(editor.string.hasSuffix(historyPlain))
        XCTAssertEqual(editor.string, "\n\n" + signature + historyPlain)
        let html = try sent(editor)
        XCTAssertEqual(occurrences(of: historyHTML, in: html), 1, html)
        let signed = try XCTUnwrap(html.range(of: "Example Ltd"))
        let original = try XCTUnwrap(html.range(of: historyHTML))
        XCTAssertLessThan(signed.upperBound, original.lowerBound)
        // The original goes out once, as its own HTML, and not flattened into the reply's text.
        XCTAssertFalse(html.contains("From: Sam Sender"), html)
        XCTAssertFalse(html.contains("________"), html)
    }

    func testASignatureAtACaretInTheOriginalGoesJustAboveIt() throws {
        let editor = editor("Thanks,\n" + historyPlain)
        let inOriginal = (editor.string as NSString).range(of: "numbers")
        editor.setSelectedRange(inOriginal)
        ComposedBody.insertSignature(signature, into: editor, before: historyPlain)
        XCTAssertEqual(editor.string, "Thanks,\n" + signature + historyPlain)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: ("Thanks,\n" + signature as NSString).length, length: 0))
    }

    func testASignatureStillGoesAtTheCaretInTheUsersOwnText() {
        let editor = editor("Hello,\n\nSee below.\n" + historyPlain)
        editor.setSelectedRange(NSRange(location: ("Hello,\n" as NSString).length, length: 0))
        ComposedBody.insertSignature(signature, into: editor, before: historyPlain)
        XCTAssertEqual(editor.string, "Hello,\n" + signature + "\nSee below.\n" + historyPlain)
    }

    func testATableInsertedWithTheCaretAfterTheOriginalGoesAboveIt() throws {
        let editor = editor("Figures:" + historyPlain)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        ComposedBody.insertTable(rows: 2, columns: 2, into: editor, before: historyPlain, font: font, lines: .labelColor)
        XCTAssertTrue(editor.string.hasSuffix(historyPlain))
        XCTAssertEqual(editor.string, "Figures:\n" + String(repeating: "\n", count: 4) + historyPlain)
        let html = try sent(editor)
        XCTAssertEqual(occurrences(of: historyHTML, in: html), 1, html)
        XCTAssertEqual(occurrences(of: "<td", in: html), 4, html)
        // The caret is in the first cell, and the original is left out of the table.
        XCTAssertEqual(editor.selectedRange().location, ("Figures:\n" as NSString).length)
        let afterTable = ("Figures:\n" as NSString).length + 4
        let style = editor.textStorage?.attribute(.paragraphStyle, at: afterTable, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertTrue(style?.textBlocks.isEmpty ?? true)
    }

    func testASignatureMovedAboveTheOriginalStaysOutOfATableEndingTheUsersText() throws {
        let editor = editor("Figures:" + historyPlain)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        ComposedBody.insertTable(rows: 1, columns: 2, into: editor, before: historyPlain, font: font, lines: .labelColor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        ComposedBody.insertSignature(signature, into: editor, before: historyPlain)
        let storage = try XCTUnwrap(editor.textStorage)
        let signed = (storage.string as NSString).range(of: "Alex Example")
        let style = storage.attribute(.paragraphStyle, at: signed.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertTrue(style?.textBlocks.isEmpty ?? true)
        XCTAssertTrue(editor.string.hasSuffix(signature + historyPlain))
    }

    func testAnEmojiAboveTheSignatureCostsNothingOffTheEnd() {
        let body = "Great work 👍👍\n\n-- \nAlex Example" + historyPlain
        let html = document(body)
        XCTAssertTrue(html.contains("Alex Example"), html)
        XCTAssertEqual(occurrences(of: historyHTML, in: html), 1, html)
    }

    func testAnEmojiEndingTheUsersTextIsNotSplit() {
        let html = document("Thanks 👍" + historyPlain)
        XCTAssertTrue(html.contains("👍") || html.contains("&#128077;"), html)
        XCTAssertFalse(html.contains("\u{FFFD}"), html)
        XCTAssertFalse(html.contains("From: Sam"), html)
    }

    func testCarriageReturnsInTheUsersTextCostNothingOffTheEnd() {
        let html = document("Line one\r\nLine two 👍\r\n-- \nAlex Example" + historyPlain)
        XCTAssertTrue(html.contains("Alex Example"), html)
        XCTAssertEqual(occurrences(of: historyHTML, in: html), 1, html)
        XCTAssertFalse(html.contains("From: Sam"), html)
    }

    func testAPictureInTheUsersTextCostsNothingOffTheEnd() throws {
        let text = NSMutableAttributedString(string: "See ", attributes: [.font: font])
        let picture = NSTextAttachment()
        picture.image = NSImage(size: NSSize(width: 8, height: 8))
        text.append(NSAttributedString(attachment: picture))
        text.append(NSAttributedString(string: "\n-- \nAlex Example" + historyPlain, attributes: [.font: font]))
        let rtf = text.rtf(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let html = ComposedHTML.document(rtf: rtf, plain: text.string, historyPlain: historyPlain, historyHTML: historyHTML)
        XCTAssertTrue(html.contains("Alex Example"), html)
        XCTAssertEqual(occurrences(of: historyHTML, in: html), 1, html)
    }

    func testAReplyWhoseOriginalWasEditedGoesOutWhole() {
        let edited = historyPlain.replacingOccurrences(of: "numbers", with: "figures")
        let html = document("Hi" + edited)
        XCTAssertFalse(html.contains(historyHTML), html)
        XCTAssertTrue(html.contains("figures are in"), html)
    }

    func testAPlainReplySendsTheOriginalsHTML() {
        let html = ComposedHTML.document(rtf: nil, plain: "Great work 👍👍" + historyPlain, historyPlain: historyPlain, historyHTML: historyHTML)
        XCTAssertTrue(html.contains(">Great work 👍👍</div>"), html)
        XCTAssertEqual(occurrences(of: historyHTML, in: html), 1, html)
    }

    private func document(_ body: String) -> String {
        let text = NSAttributedString(string: body, attributes: [.font: font])
        let rtf = text.rtf(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        return ComposedHTML.document(rtf: rtf, plain: body, historyPlain: historyPlain, historyHTML: historyHTML)
    }

    // MARK: - tables

    private func tables(in editor: NSTextView) -> [NSTextTable] {
        var found: [NSTextTable] = []
        let storage = editor.textStorage!
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            for case let block as NSTextTableBlock in (value as? NSParagraphStyle)?.textBlocks ?? []
            where !found.contains(where: { $0 === block.table }) {
                found.append(block.table)
            }
        }
        return found
    }

    func testATableIsNoWiderThanOutlooksPage() throws {
        let editor = editor("Figures:\n", width: 1400)
        editor.setSelectedRange(NSRange(location: 9, length: 0))
        ComposedBody.insertTable(rows: 1, columns: 3, into: editor, before: "", font: font, lines: .labelColor)
        let table = try XCTUnwrap(tables(in: editor).first)
        XCTAssertEqual(table.contentWidth, ComposedTable.pageWidth - ComposedTable.lineWidth, accuracy: 0.01)
    }

    func testATableInANarrowBodyTakesTheBodysWidth() throws {
        let editor = editor("Figures:\n", width: 320)
        editor.setSelectedRange(NSRange(location: 9, length: 0))
        ComposedBody.insertTable(rows: 1, columns: 2, into: editor, before: "", font: font, lines: .labelColor)
        let table = try XCTUnwrap(tables(in: editor).first)
        let container = try XCTUnwrap(editor.textContainer)
        XCTAssertEqual(table.contentWidth, container.size.width - 2 * container.lineFragmentPadding - ComposedTable.lineWidth, accuracy: 0.01)
    }

    /// The cell's text area and its outer bounds, as laid out.
    private func laidOut(_ cell: NSTextBlock, in editor: NSTextView) throws -> (text: CGFloat, bounds: CGFloat) {
        let storage = try XCTUnwrap(editor.textStorage), layout = try XCTUnwrap(editor.layoutManager)
        var found = NSRange(location: NSNotFound, length: 0)
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if (value as? NSParagraphStyle)?.textBlocks.contains(where: { $0 === cell }) == true {
                found = storage.range(of: cell, at: range.location)
                stop.pointee = true
            }
        }
        let glyphs = layout.glyphRange(forCharacterRange: found, actualCharacterRange: nil)
        layout.ensureLayout(forGlyphRange: glyphs)
        return (layout.layoutRect(for: cell, glyphRange: glyphs).width, layout.boundsRect(for: cell, glyphRange: glyphs).width)
    }

    func testATableInsertedInACellStaysInsideIt() throws {
        let editor = editor("Figures:\n", width: 900)
        editor.setSelectedRange(NSRange(location: 9, length: 0))
        ComposedBody.insertTable(rows: 2, columns: 2, into: editor, before: "", font: font, lines: .labelColor)
        let outer = try XCTUnwrap(tables(in: editor).first)
        let firstCell = try XCTUnwrap((editor.textStorage?.attribute(.paragraphStyle, at: editor.selectedRange().location,
                                                                     effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.last)
        let before = try laidOut(firstCell, in: editor)

        ComposedBody.insertTable(rows: 1, columns: 2, into: editor, before: "", font: font, lines: .labelColor)
        let inner = try XCTUnwrap(tables(in: editor).first { $0 !== outer })
        let style = try XCTUnwrap(editor.textStorage?.attribute(.paragraphStyle, at: editor.selectedRange().location,
                                                                effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.textBlocks.count, 2)
        XCTAssertTrue(style.textBlocks.first === firstCell)
        // The inner table takes the cell's text width, and the cell, and so the outer table, keep theirs.
        XCTAssertEqual(inner.contentWidth, before.text - ComposedTable.lineWidth, accuracy: 0.01)
        let after = try laidOut(firstCell, in: editor)
        XCTAssertEqual(after.bounds, before.bounds, accuracy: 0.01)
        XCTAssertEqual(outer.contentWidth, ComposedTable.pageWidth - ComposedTable.lineWidth, accuracy: 0.01)
    }

    func testATableInATinyCellStillLeavesItsCellsRoomForText() {
        let width = ComposedTable.width(room: 30, columns: 3)
        let cell = (width / 3 - 2 * ComposedTable.cellPadding - ComposedTable.lineWidth).rounded(.down)
        XCTAssertGreaterThanOrEqual(cell, 7)
    }
}

final class PopupPlacementTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 25, width: 1512, height: 920)
    private let size = CGSize(width: 198, height: 212)

    func testItHangsUnderTheControlWhenThereIsRoom() {
        let control = CGRect(x: 400, y: 600, width: 50, height: 74)
        XCTAssertEqual(PopupPlacement.frame(size: size, below: control, overlap: 4, on: screen),
                       CGRect(x: 400, y: 600 + 4 - 212, width: 198, height: 212))
    }

    func testItMovesLeftToStayOnTheScreen() {
        let control = CGRect(x: 1400, y: 600, width: 50, height: 74)
        let frame = PopupPlacement.frame(size: size, below: control, overlap: 4, on: screen)
        XCTAssertEqual(frame.maxX, screen.maxX)
        XCTAssertEqual(frame.minY, 600 + 4 - 212)
    }

    func testItNeverGoesPastTheLeftEdge() {
        let narrow = CGRect(x: 0, y: 25, width: 150, height: 920)
        let control = CGRect(x: 100, y: 600, width: 50, height: 74)
        XCTAssertEqual(PopupPlacement.frame(size: size, below: control, overlap: 4, on: narrow).minX, 0)
    }

    func testItOpensAboveTheControlWhenThereIsNoRoomBelow() {
        let control = CGRect(x: 400, y: 100, width: 50, height: 74)
        let frame = PopupPlacement.frame(size: size, below: control, overlap: 4, on: screen)
        XCTAssertEqual(frame.minY, control.maxY)
        XCTAssertLessThanOrEqual(frame.maxY, screen.maxY)
    }

    func testItStaysOnAScreenTooShortForEither() {
        let short = CGRect(x: 0, y: 0, width: 1512, height: 250)
        let control = CGRect(x: 400, y: 100, width: 50, height: 74)
        let frame = PopupPlacement.frame(size: size, below: control, overlap: 4, on: short)
        XCTAssertGreaterThanOrEqual(frame.minY, short.minY)
        XCTAssertLessThanOrEqual(frame.maxY, short.maxY)
    }
}
