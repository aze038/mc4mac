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
    private func sent(_ editor: NSTextView, history: String? = nil) throws -> String {
        let storage = try XCTUnwrap(editor.textStorage)
        return ComposedHTML.document(rtf: try rtf(storage), plain: storage.string, historyPlain: history ?? historyPlain,
                                     historyHTML: historyHTML)
    }

    private func rtf(_ text: NSAttributedString) throws -> Data {
        try XCTUnwrap(text.rtf(from: NSRange(location: 0, length: text.length),
                               documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]))
    }

    /// The draft opened again, as the composer loads one from its store: from its RTF, with the
    /// caret at the top.
    private func reopened(_ editor: NSTextView) throws -> NSTextView {
        let stored = try rtf(try XCTUnwrap(editor.textStorage))
        let body = try NSAttributedString(data: stored, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                          documentAttributes: nil)
        let reopened = NSTextView(frame: editor.frame)
        reopened.textStorage?.setAttributedString(body)
        reopened.setSelectedRange(NSRange(location: 0, length: 0))
        return reopened
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

    // MARK: - originals that RTF rewrites

    private let ownText = "Great work 👍👍\n\n-- \nAlex Example\nExample Ltd\n\n"

    private func quoted(from: String = "Sam Sender", subject: String = "Figures", text: String) -> String {
        "\n________________________________\nFrom: \(from) <sam@example.com>\nSubject: \(subject)\n\n\(text)\n"
    }

    /// Originals quoted with characters that RTF does not give back as they were.
    private var rewrittenOriginals: [(name: String, history: String)] {
        [("bidi embeddings", quoted(from: "\u{202B}Sam Sender\u{202C}", subject: "\u{202A}Q3\u{202C} \u{202D}figures\u{202C} \u{202E}v2\u{202C}",
                                    text: "The numbers are in 📈.")),
         ("a decomposed accent", quoted(from: "Rene\u{0301} Sender", subject: "Cafe\u{0301} figures", text: "Re\u{0301}sume\u{0301} 📈.")),
         ("a paragraph separator", quoted(text: "First paragraph.\u{2029}Second paragraph.")),
         ("a lone carriage return", quoted(text: "Line one\rLine two")),
         ("an object character", quoted(text: "See the chart \u{FFFC} below.")),
         ("a NUL", quoted(text: "Totals\u{0000} to follow."))]
    }

    /// The original goes out once as its own HTML, after the user's text and the whole signature,
    /// and nothing of its plain copy goes with it.
    private func assertSendsTheOriginalsHTML(_ html: String, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(occurrences(of: historyHTML, in: html), 1, name, file: file, line: line)
        XCTAssertTrue(html.contains("👍👍") || html.contains("&#128077;&#128077;"), name, file: file, line: line)
        XCTAssertFalse(html.contains("sam@example.com"), name, file: file, line: line)
        guard let signed = html.range(of: "Example Ltd"), let original = html.range(of: historyHTML) else {
            return XCTFail("\(name): signature cut short\n\(html)", file: file, line: line)
        }
        XCTAssertLessThan(signed.upperBound, original.lowerBound, name, file: file, line: line)
    }

    func testAnOriginalThatRTFRewritesStillGoesOutAsItsHTML() throws {
        for (name, history) in rewrittenOriginals {
            // Compared in UTF-16, since Swift's own equality takes an accent composed or not as the same.
            XCTAssertFalse(ComposedBody.throughRTF(history).utf16.elementsEqual(history.utf16), "\(name) is not rewritten")
            let fresh = editor(ownText + history)
            assertSendsTheOriginalsHTML(try sent(fresh, history: history), name)
            assertSendsTheOriginalsHTML(try sent(try reopened(fresh), history: history), "\(name), reopened")
            let plain = ComposedHTML.document(rtf: nil, plain: ComposedBody.throughRTF(ownText + history),
                                              historyPlain: history, historyHTML: historyHTML)
            assertSendsTheOriginalsHTML(plain, "\(name), plain")
        }
    }

    func testAnOriginalRTFSetsDownOtherwiseInTheBodyStillGoesOutAsItsHTML() throws {
        // A NUL cuts short the run of formatting it is in, so a word made bold after it comes
        // back from the body's RTF but not from the original's on its own: only the plain body
        // still shows where the user's text ends.
        let history = quoted(text: "Totals\u{0000} to follow, see attached.")
        let body = NSMutableAttributedString(string: ownText + history, attributes: [.font: font])
        body.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: (body.string as NSString).range(of: "attached"))
        let stored = try rtf(body)
        let rich = try NSAttributedString(data: stored, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        XCTAssertNil(ComposedBody.historyStart(in: rich.string, history: history))
        let html = ComposedHTML.document(rtf: stored, plain: body.string, historyPlain: history, historyHTML: historyHTML)
        assertSendsTheOriginalsHTML(html, "run cut short")
        XCTAssertFalse(html.contains("Totals"), html)
    }

    func testInsertionsInADraftReopenedFromItsRTFStillGoAboveTheOriginal() throws {
        for (name, history) in rewrittenOriginals {
            let draft = try reopened(editor("Thanks,\n" + history))
            let original = ComposedBody.throughRTF(history)
            XCTAssertEqual(draft.string, "Thanks,\n" + original, name)
            // The user has clicked into the original.
            draft.setSelectedRange(NSRange(location: ("Thanks,\n" as NSString).length + (original as NSString).length / 2, length: 0))
            ComposedBody.insertSignature(signature, into: draft, before: history)
            XCTAssertEqual(draft.string, "Thanks,\n" + signature + original, name)

            draft.setSelectedRange(NSRange(location: (draft.string as NSString).length, length: 0))
            ComposedBody.insertTable(rows: 1, columns: 2, into: draft, before: history, font: font, lines: .labelColor)
            XCTAssertEqual(draft.string, "Thanks,\n" + signature + "\n\n" + original, name)
            let html = try sent(draft, history: history)
            XCTAssertEqual(occurrences(of: historyHTML, in: html), 1, name)
            XCTAssertEqual(occurrences(of: "<td", in: html), 2, name)
            XCTAssertTrue(html.contains("Example Ltd"), name)
        }
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

    /// Kana with a separate voicing mark and Hangul written as jamo, as file names made on a Mac
    /// are, may come back composed after the draft's trip through RTF and an edit: the original is
    /// still recognised, sent as its own HTML, and kept free of insertions.
    func testAnOriginalWithDecomposedKanaOrHangulIsStillFoundWhenItComesBackComposed() throws {
        let decomposed = "\n________________________________\nFrom: Sam Sender <sam@example.com>\nSubject: \u{30C6}\u{3099}\u{30FC}\u{30BF}.pdf \u{1112}\u{1161}\u{11AB}\n\nSee the file.\n"
        let composed = decomposed.precomposedStringWithCanonicalMapping
        XCTAssertNotEqual(Array(decomposed.utf16), Array(composed.utf16))
        let body = editor("Thanks, will do.\n\n" + signature + composed)
        let html = try sent(body, history: decomposed)
        XCTAssertEqual(occurrences(of: historyHTML, in: html), 1, html)
        XCTAssertTrue(html.contains("Example Ltd"), html)
        XCTAssertFalse(html.contains("See the file"), "the original went out flattened: \(html)")
        let storage = try XCTUnwrap(body.textStorage)
        let point = ComposedBody.insertionPoint(for: storage.length - 3, in: storage.string, history: decomposed)
        XCTAssertEqual(point, (storage.string as NSString).length - (composed as NSString).length)
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
        let width = ComposedTable.width(room: 30, body: 600, columns: 3)
        let cell = (width / 3 - 2 * ComposedTable.cellPadding - ComposedTable.lineWidth).rounded(.down)
        XCTAssertGreaterThanOrEqual(cell, 7)
    }

    /// What each column needs to keep its padding, its line and some text.
    private let columnNeeds = 2 * ComposedTable.cellPadding + ComposedTable.lineWidth + ComposedTable.leastCellText

    func testATableIsNeverWiderThanTheBody() {
        for body in [120, 320, 467, 600, 900, 1400] as [CGFloat] {
            for columns in 1...63 {
                let width = ComposedTable.width(room: body, body: body, columns: columns)
                XCTAssertLessThanOrEqual(width, body - ComposedTable.lineWidth, "\(columns) columns in \(body)")
                XCTAssertLessThanOrEqual(width, max(ComposedTable.pageWidth - ComposedTable.lineWidth, CGFloat(columns) * columnNeeds),
                                         "\(columns) columns in \(body)")
            }
        }
    }

    func testColumnsThatNeedMoreThanThePageTakeItUpToTheBody() {
        let page = ComposedTable.pageWidth - ComposedTable.lineWidth
        // Twenty-three columns fit Outlook's page; twenty-four need more, and a wide body gives it.
        XCTAssertEqual(ComposedTable.width(room: 1400, body: 1400, columns: 23), page, accuracy: 0.01)
        XCTAssertEqual(ComposedTable.width(room: 1400, body: 1400, columns: 24), 24 * columnNeeds, accuracy: 0.01)
        XCTAssertEqual(ComposedTable.width(room: 1400, body: 1400, columns: 63), 63 * columnNeeds, accuracy: 0.01)
        // Forty would need 792 points; a 600 point body is all they get.
        XCTAssertEqual(ComposedTable.width(room: 600, body: 600, columns: 40), 599, accuracy: 0.01)
        XCTAssertEqual(ComposedTable.width(room: 600, body: 600, columns: 63), 599, accuracy: 0.01)
    }

    func testAManyColumnTableInsertedInABodyIsNoWiderThanIt() throws {
        let editor = editor("Figures:\n", width: 610)
        editor.setSelectedRange(NSRange(location: 9, length: 0))
        ComposedBody.insertTable(rows: 1, columns: 40, into: editor, before: "", font: font, lines: .labelColor)
        let table = try XCTUnwrap(tables(in: editor).first)
        let container = try XCTUnwrap(editor.textContainer)
        XCTAssertEqual(table.contentWidth, container.size.width - 2 * container.lineFragmentPadding - ComposedTable.lineWidth, accuracy: 0.01)
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
