import XCTest
import AppKit
@testable import FalconCore

final class FormattingMarksTests: XCTestCase {
    private let marks = [FormattingMarks.paragraph, FormattingMarks.space, FormattingMarks.tab]
    /// How the marks could reach a message other than as themselves: named and numbered HTML
    /// entities, and quoted-printable UTF-8.
    private let encodedMarks = ["&para;", "&#182;", "&#xB6;", "&middot;", "&#183;", "&#xB7;", "&rarr;", "&#8594;", "&#x2192;",
                                "=C2=B6", "=C2=B7", "=E2=86=92"]

    func testParagraphEndsSpacesAndTabsAreMarked() {
        let text = "Dear Sam,\n\tNorth 1\u{2029}end" as NSString
        let found = FormattingMarks.marks(in: text, range: NSRange(location: 0, length: text.length))
        XCTAssertEqual(found, [
            .init(character: 4, symbol: "·"), .init(character: 9, symbol: "¶"), .init(character: 10, symbol: "→"),
            .init(character: 16, symbol: "·"), .init(character: 18, symbol: "¶"),
            .init(character: 21, symbol: "¶", after: true),
        ])
    }

    /// Word marks the end of the last paragraph too, which has no line break of its own; one
    /// that ends in a line break is marked by it, and only once.
    func testTheLastParagraphIsMarkedOnceWhereverItEnds() {
        for (text, last) in [("a b", FormattingMarks.Mark(character: 2, symbol: "¶", after: true)),
                             ("a\n", FormattingMarks.Mark(character: 1, symbol: "¶")),
                             ("a\u{2029}", FormattingMarks.Mark(character: 1, symbol: "¶"))] {
            let string = text as NSString
            let found = FormattingMarks.marks(in: string, range: NSRange(location: 0, length: string.length))
            XCTAssertEqual(found.last, last, text)
            XCTAssertEqual(found.filter { $0.symbol == "¶" }.count, 1, text)
        }
        XCTAssertEqual(FormattingMarks.marks(in: "", range: NSRange(location: 0, length: 0)), [])
    }

    /// Text drawn a line at a time ends its last paragraph only when the line drawn is the last.
    func testOnlyTheRangeThatReachesTheEndMarksTheLastParagraph() {
        let text = "one two\nthree" as NSString
        XCTAssertEqual(FormattingMarks.marks(in: text, range: NSRange(location: 0, length: 8)),
                       [.init(character: 3, symbol: "·"), .init(character: 7, symbol: "¶")])
        XCTAssertEqual(FormattingMarks.marks(in: text, range: NSRange(location: 8, length: 5)),
                       [.init(character: 12, symbol: "¶", after: true)])
    }

    /// A message written with ¶ on, typed and drawn as the composer types and draws it, goes out
    /// through the draft's RTF, the HTML and the MIME that are sent without a single mark, and
    /// the text itself is exactly what was typed.
    func testAMessageWrittenWithMarksShowingIsSentWithoutThem() throws {
        let (view, layout) = composer()
        layout.showsMarks = true
        let typed = "Hello Sam,\n\nThe figures for this week:\n\tNorth\t1,240\n\tSouth\t985\n\nBest wishes,\nAlex"
        view.insertText(typed, replacementRange: NSRange(location: NSNotFound, length: 0))
        let storage = try XCTUnwrap(view.textStorage)
        let before = NSAttributedString(attributedString: storage)
        let drawnWithMarks = inkedPixels(drawing: layout)
        layout.showsMarks = false
        XCTAssertGreaterThan(drawnWithMarks, inkedPixels(drawing: layout), "the marks are drawn")
        layout.showsMarks = true
        _ = inkedPixels(drawing: layout)
        XCTAssertEqual(storage.string, typed)
        XCTAssertEqual(NSAttributedString(attributedString: storage), before)

        let rtf = try XCTUnwrap(storage.rtf(from: NSRange(location: 0, length: storage.length),
                                            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]))
        let html = ComposedHTML.document(rtf: rtf, plain: storage.string, historyPlain: "", historyHTML: "")
        let message = OutgoingMessage(from: EmailAddress(name: "Alex", address: "alex@example.com"),
                                      to: [EmailAddress(address: "sam@example.com")], subject: "Figures",
                                      textBody: storage.string, htmlBody: html)
        let raw = String(decoding: MIMEBuilder.build(message), as: UTF8.self)
        let parsed = MIMEParser.parse(MIMEBuilder.build(message))
        let plain = try XCTUnwrap(parsed.textPlain)
        let sentHTML = try XCTUnwrap(parsed.textHTML)
        XCTAssertTrue(plain.contains("North\t1,240"), plain)
        XCTAssertTrue(sentHTML.contains("1,240"), sentHTML)
        for mark in marks {
            XCTAssertFalse(html.contains(mark), mark)
            XCTAssertFalse(plain.contains(mark), mark)
            XCTAssertFalse(sentHTML.contains(mark), mark)
            XCTAssertFalse(raw.contains(mark), mark)
        }
        for encoded in encodedMarks {
            XCTAssertFalse(html.contains(encoded), encoded)
            XCTAssertFalse(raw.contains(encoded), encoded)
        }
    }

    /// AppKit sets an empty paragraph's line break at the foot of its line; its ¶ still stands on
    /// the baseline the line's text would have, one line's pitch below the line before.
    func testAnEmptyParagraphsMarkStandsOnItsLinesBaseline() throws {
        for spacing: CGFloat in [0, 5] {
            let (view, layout) = composer()
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = spacing
            style.paragraphSpacing = spacing
            style.lineSpacing = spacing
            let storage = try XCTUnwrap(view.textStorage)
            storage.setAttributedString(NSAttributedString(string: "Hello\n\nThe end", attributes: [
                .font: NSFont.systemFont(ofSize: 14), .paragraphStyle: style]))
            layout.ensureLayout(for: try XCTUnwrap(layout.textContainers.first))
            let found = FormattingMarks.marks(in: storage.string as NSString, range: NSRange(location: 0, length: storage.length))
            let baseline = { (character: Int) in found.first { $0.character == character }.flatMap(layout.baselineStart)?.y }
            let first = try XCTUnwrap(baseline(5)), empty = try XCTUnwrap(baseline(6)), third = try XCTUnwrap(baseline(10))
            XCTAssertGreaterThan(empty, first)
            XCTAssertEqual(empty - first, third - empty, accuracy: 0.01, "spacing \(spacing)")
        }
    }

    /// Turning ¶ on or off is not an edit: nothing tells the draft to save or the text to change.
    func testShowingMarksIsNotAnEdit() throws {
        let (view, layout) = composer()
        view.insertText("a b\tc", replacementRange: NSRange(location: NSNotFound, length: 0))
        let storage = try XCTUnwrap(view.textStorage)
        var edits = 0
        let observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                                              object: storage, queue: nil) { _ in edits += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        layout.showsMarks = true
        _ = inkedPixels(drawing: layout)
        layout.showsMarks = false
        XCTAssertEqual(edits, 0)
        XCTAssertEqual(storage.string, "a b\tc")
    }

    /// A text view set up as the composer's body is: TextKit 1 with the marks' layout manager.
    private func composer() -> (NSTextView, FormattingMarksLayoutManager) {
        let storage = NSTextStorage()
        let layout = FormattingMarksLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        view.isRichText = true
        view.typingAttributes = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor]
        return (view, layout)
    }

    /// Draws all the text as the text view would and counts the pixels that took any ink.
    private func inkedPixels(drawing layout: NSLayoutManager) -> Int {
        let size = NSSize(width: 400, height: 300)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep),
              let container = layout.textContainers.first else { return 0 }
        // A text view's coordinates run down the page.
        context.cgContext.translateBy(x: 0, y: size.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: .zero)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return 0 }
        var inked = 0
        for pixel in 0..<(rep.pixelsWide * rep.pixelsHigh) where data[pixel * 4 + 3] > 0 { inked += 1 }
        return inked
    }
}
