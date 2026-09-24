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

    /// Word marks the end of every paragraph once, the last too: after its text when it has no
    /// line break, and when the text ends in a line break, a paragraph's or Shift-Return's, on
    /// the empty line that follows, as on the one line of an empty text.
    func testEveryParagraphIsMarkedOnceWhereverTheTextEnds() {
        for (text, last, paragraphs) in [("a b", FormattingMarks.Mark(character: 2, symbol: "¶", after: true), 1),
                                         ("a\n", FormattingMarks.Mark(character: 2, symbol: "¶"), 2),
                                         ("a\u{2029}", FormattingMarks.Mark(character: 2, symbol: "¶"), 2),
                                         ("a\u{2028}", FormattingMarks.Mark(character: 2, symbol: "¶"), 1),
                                         ("a\u{2028}b", FormattingMarks.Mark(character: 2, symbol: "¶", after: true), 1),
                                         ("a\n\n", FormattingMarks.Mark(character: 3, symbol: "¶"), 3),
                                         ("", FormattingMarks.Mark(character: 0, symbol: "¶"), 1)] {
            let string = text as NSString
            let found = FormattingMarks.marks(in: string, range: NSRange(location: 0, length: string.length))
            XCTAssertEqual(found.last, last, text)
            XCTAssertEqual(found.filter { $0.symbol == "¶" }.count, paragraphs, text)
        }
    }

    /// Text drawn a line at a time ends its last paragraph only when the line drawn is the last.
    func testOnlyTheRangeThatReachesTheEndMarksTheLastParagraph() {
        let text = "one two\nthree" as NSString
        XCTAssertEqual(FormattingMarks.marks(in: text, range: NSRange(location: 0, length: 8)),
                       [.init(character: 3, symbol: "·"), .init(character: 7, symbol: "¶")])
        XCTAssertEqual(FormattingMarks.marks(in: text, range: NSRange(location: 8, length: 5)),
                       [.init(character: 12, symbol: "¶", after: true)])
        let ending = "one\ntwo\n" as NSString
        XCTAssertEqual(FormattingMarks.marks(in: ending, range: NSRange(location: 0, length: 4)), [.init(character: 3, symbol: "¶")])
        XCTAssertEqual(FormattingMarks.marks(in: ending, range: NSRange(location: 4, length: 4)),
                       [.init(character: 7, symbol: "¶"), .init(character: 8, symbol: "¶")])
    }

    /// A body that ends in a line break shows a ¶ on the empty line after it, where the caret
    /// stands, however much of the view is redrawn: the whole of it, or that line alone, as
    /// when the last character on it is deleted.
    func testTheEmptyLastLineShowsItsMark() throws {
        let (view, layout) = composer()
        view.drawsBackground = false
        view.insertText("Hello Sam,\nBest wishes\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        let container = try XCTUnwrap(layout.textContainers.first)
        layout.ensureLayout(for: container)
        let line = layout.extraLineFragmentRect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        XCTAssertGreaterThan(line.height, 0)
        XCTAssertEqual(inkedPixels(displaying: view, in: line), 0, "nothing is drawn there without the marks")
        layout.showsMarks = true
        XCTAssertGreaterThan(inkedPixels(displaying: view, in: line), 0, "the empty line's ¶, drawn with that line alone")
        XCTAssertGreaterThan(inkedPixels(displaying: view, in: view.bounds, within: line), 0, "and with the whole view")
        // Once the line holds text, its ¶ follows that text instead.
        view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        let text = view.string as NSString
        XCTAssertEqual(FormattingMarks.marks(in: text, range: NSRange(location: 0, length: text.length)).last,
                       .init(character: 23, symbol: "¶", after: true))
    }

    /// The empty last line's ¶ stands where the caret does, one line's pitch below the line
    /// before, whatever the spacing and alignment.
    func testTheEmptyLastLinesMarkStandsWhereTheCaretDoes() throws {
        for (spacing, alignment) in [(CGFloat(0), NSTextAlignment.natural), (5, .natural), (0, .center), (0, .right)] {
            let (view, layout) = composer()
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = spacing
            style.paragraphSpacing = spacing
            style.lineSpacing = spacing
            style.alignment = alignment
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .paragraphStyle: style]
            view.typingAttributes = attributes
            let storage = try XCTUnwrap(view.textStorage)
            storage.setAttributedString(NSAttributedString(string: "Hello\n\n", attributes: attributes))
            view.setSelectedRange(NSRange(location: storage.length, length: 0))
            let container = try XCTUnwrap(layout.textContainers.first)
            layout.ensureLayout(for: container)
            let found = FormattingMarks.marks(in: storage.string as NSString, range: NSRange(location: 0, length: storage.length))
            let start = { (character: Int) in found.first { $0.character == character }.flatMap(layout.baselineStart) }
            let first = try XCTUnwrap(start(5)), empty = try XCTUnwrap(start(6)), last = try XCTUnwrap(start(7))
            XCTAssertEqual(last.y - empty.y, empty.y - first.y, accuracy: 0.01, "spacing \(spacing)")
            var count = 0
            let caret = try XCTUnwrap(layout.rectArray(forCharacterRange: NSRange(location: 7, length: 0),
                                                       withinSelectedCharacterRange: NSRange(location: 7, length: 0),
                                                       in: container, rectCount: &count)?.pointee)
            XCTAssertEqual(last.x, caret.minX, accuracy: 0.5, "alignment \(alignment.rawValue)")
            XCTAssertTrue(caret.minY < last.y && last.y <= caret.maxY, "\(caret) \(last)")
        }
    }

    /// A body that ends in Shift-Return's line break shows its last ¶ on the empty line after
    /// it, where the caret stands, not at the far end of the line before.
    func testTheEmptyLineAfterShiftReturnShowsTheLastMark() throws {
        let (view, layout) = composer()
        view.drawsBackground = false
        view.insertText("Alex Moreno", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertLineBreak(nil)
        let storage = try XCTUnwrap(view.textStorage)
        XCTAssertEqual(storage.string, "Alex Moreno\u{2028}")
        let container = try XCTUnwrap(layout.textContainers.first)
        layout.ensureLayout(for: container)
        let found = FormattingMarks.marks(in: storage.string as NSString, range: NSRange(location: 0, length: storage.length))
        XCTAssertEqual(found.filter { $0.symbol == "¶" }, [.init(character: 12, symbol: "¶")])
        let start = try XCTUnwrap(found.last.flatMap(layout.baselineStart))
        var count = 0
        let caret = try XCTUnwrap(layout.rectArray(forCharacterRange: NSRange(location: 12, length: 0),
                                                   withinSelectedCharacterRange: NSRange(location: 12, length: 0),
                                                   in: container, rectCount: &count)?.pointee)
        XCTAssertEqual(start.x, caret.minX, accuracy: 0.5)
        XCTAssertTrue(caret.minY < start.y && start.y <= caret.maxY, "\(caret) \(start)")
        let line = layout.extraLineFragmentRect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        XCTAssertEqual(inkedPixels(displaying: view, in: line), 0, "nothing is drawn there without the marks")
        layout.showsMarks = true
        XCTAssertGreaterThan(inkedPixels(displaying: view, in: line), 0, "the empty line's ¶")
    }

    /// An empty body shows the ¶ of its one paragraph where the caret stands, drawn when its
    /// view asks, as it has no glyphs for the view to draw.
    func testAnEmptyTextShowsItsMark() throws {
        let (view, layout) = composer()
        view.drawsBackground = false
        XCTAssertEqual(inkedPixels(drawingMarksOfEmptyText: layout, origin: view.textContainerOrigin), 0)
        layout.showsMarks = true
        XCTAssertGreaterThan(inkedPixels(drawingMarksOfEmptyText: layout, origin: view.textContainerOrigin), 0)
        let start = try XCTUnwrap(layout.baselineStart(of: .init(character: 0, symbol: "¶")))
        XCTAssertEqual(start.x, try XCTUnwrap(layout.textContainers.first).lineFragmentPadding, accuracy: 0.01)
        XCTAssertEqual(start.y, layout.defaultBaselineOffset(for: NSFont.systemFont(ofSize: 14)), accuracy: 0.01)
        view.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(inkedPixels(drawingMarksOfEmptyText: layout, origin: view.textContainerOrigin), 0,
                       "a text with glyphs has its marks drawn with them")
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

    /// Has the view draw `rect` as it would on screen, and counts the pixels that took any ink,
    /// of all of them or of those `within` part of it.
    private func inkedPixels(displaying view: NSView, in rect: NSRect, within part: NSRect? = nil) -> Int {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return 0 }
        view.cacheDisplay(in: rect, to: rep)
        let scale = CGFloat(rep.pixelsWide) / rect.width
        let counted = (part ?? rect).offsetBy(dx: -rect.minX, dy: -rect.minY)
        var inked = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                // The rep's rows run down the view, as a flipped text view's do.
                let point = NSPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
                guard counted.contains(point), let colour = rep.colorAt(x: x, y: y), colour.alphaComponent > 0 else { continue }
                inked += 1
            }
        }
        return inked
    }

    /// The same for the marks of an empty text, drawn as its view asks for them.
    private func inkedPixels(drawingMarksOfEmptyText layout: FormattingMarksLayoutManager, origin: NSPoint) -> Int {
        draw(size: NSSize(width: 400, height: 300)) { layout.drawMarksOfEmptyText(at: origin) }
    }

    /// Draws all the text as the text view would and counts the pixels that took any ink.
    private func inkedPixels(drawing layout: NSLayoutManager) -> Int {
        guard let container = layout.textContainers.first else { return 0 }
        return draw(size: NSSize(width: 400, height: 300)) { layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: .zero) }
    }

    /// Runs `drawing` into a clear bitmap `size` points big and counts the pixels that took any
    /// ink.
    private func draw(size: NSSize, _ drawing: () -> Void) -> Int {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return 0 }
        // A text view's coordinates run down the page.
        context.cgContext.translateBy(x: 0, y: size.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        drawing()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return 0 }
        var inked = 0
        for pixel in 0..<(rep.pixelsWide * rep.pixelsHigh) where data[pixel * 4 + 3] > 0 { inked += 1 }
        return inked
    }
}
