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
        XCTAssertTrue(cell.contains("border-color: #ff0000 #ff0000 #ff0000 #ff0000"), cell)
        XCTAssertTrue(html.contains("color: #ff0000\">Alert"), html)
    }

    // MARK: - exact colours

    /// Primaries, greys and Office's own colours, as text colours and as highlights.
    private let chosen = [0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0x00FFFF, 0xFF00FF, 0x000000, 0xFFFFFF,
                          0x808080, 0x7F7F7F, 0x595959, 0xD9D9D9, 0x1F4E79, 0xC00000, 0xFFC000, 0xE2EFDA,
                          0x92D050, 0x00B050, 0x0070C0, 0x002060, 0x7030A0, 0x010203, 0xFEFDFC]

    private func sRGB(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private func css(_ hex: Int) -> String { String(format: "#%06x", hex) }

    /// Each colour in a paragraph of its own, as the text's colour and then as its highlight.
    private func swatches(_ colours: [Int], colour: (Int) -> NSColor) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for hex in colours {
            text.append(NSAttributedString(string: "ink\(css(hex))", attributes: [.font: font, .foregroundColor: colour(hex)]))
            text.append(NSAttributedString(string: " and ", attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
            text.append(NSAttributedString(string: "marker\(css(hex))", attributes: [
                .font: font, .foregroundColor: NSColor.labelColor, .backgroundColor: colour(hex)]))
            text.append(NSAttributedString(string: "\n", attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        }
        return text
    }

    private func assertSentExactly(_ colours: [Int], in html: String, file: StaticString = #filePath, line: UInt = #line) {
        for hex in colours {
            XCTAssertTrue(html.contains("color: \(css(hex))\">ink\(css(hex))<"), "text in \(css(hex))\n\(html)", file: file, line: line)
            XCTAssertTrue(html.contains("background-color: \(css(hex))\">marker\(css(hex))<"),
                          "highlight in \(css(hex))\n\(html)", file: file, line: line)
        }
    }

    /// AppKit's writer puts every colour down in calibrated RGB, which would send sRGB's pure
    /// red as #fb0007 and its yellow as #ffff0b; what a reader is sent is the sRGB colour that
    /// was chosen, to the last step.
    func testTextColoursAndHighlightsAreSentAsExactlyTheSRGBChosen() throws {
        let html = try sent(swatches(chosen, colour: sRGB))
        assertSentExactly(chosen, in: html)
        for shifted in ["#fb0007", "#ffff0b", "#6d6d6d", "#193c66"] { XCTAssertFalse(html.contains(shifted), shifted) }
    }

    /// The ribbon's colours come from SwiftUI in extended sRGB, and the colour panel can give a
    /// colour in Display P3 or as a grey; each goes out as the sRGB it is.
    func testColoursFromOtherSpacesAreSentAsTheirSRGB() throws {
        let extended = { (hex: Int) -> NSColor in
            let colour = self.sRGB(hex)
            return NSColor(colorSpace: .extendedSRGB, components: [colour.redComponent, colour.greenComponent, colour.blueComponent, 1],
                           count: 4)
        }
        assertSentExactly(chosen, in: try sent(swatches(chosen, colour: extended)))
        let inP3 = [0x1F4E79, 0xC00000, 0xFFC000, 0xE2EFDA, 0x808080, 0xFF0000]
        assertSentExactly(inP3, in: try sent(swatches(inP3, colour: { self.sRGB($0).usingColorSpace(.displayP3) ?? .clear })))
        let greys = try sent(swatches([0x000000, 0xFFFFFF], colour: { $0 == 0 ? .black : .white }))
        assertSentExactly([0x000000, 0xFFFFFF], in: greys)
    }

    /// Every one of the 256 steps of a channel survives, so no chosen colour is ever a step off.
    func testEveryStepOfEveryChannelIsSentExactly() throws {
        let steps = (0...255).map { $0 << 16 | (255 - $0) << 8 | ($0 * 7) & 0xFF }
        assertSentExactly(steps, in: try sent(swatches(steps, colour: sRGB)))
    }

    /// A colour that follows the appearance goes out as it looks in light, on the white page
    /// a message is read on, whichever appearance the sender's app is in.
    func testASystemColourIsSentAsItLooksInLight() throws {
        let text = swatches([0], colour: { _ in NSColor.systemRed })
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        var lightRed: NSColor?
        light.performAsCurrentDrawingAppearance { lightRed = NSColor.systemRed.usingColorSpace(.sRGB) }
        let red = try XCTUnwrap(lightRed)
        let hex = Int((red.redComponent * 255).rounded()) << 16 | Int((red.greenComponent * 255).rounded()) << 8
            | Int((red.blueComponent * 255).rounded())
        var inDark: String?
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { inDark = try? self.sent(text) }
        let html = try sent(text)
        XCTAssertEqual(try XCTUnwrap(inDark), html)
        XCTAssertTrue(html.contains("color: \(css(hex))\">ink#000000<"), html)
    }

    /// Underline and strikethrough are drawn in the text's colour, which is exact; the writer
    /// sends no colour of their own.
    func testUnderlinedAndStruckTextKeepsItsExactColour() throws {
        let text = NSMutableAttributedString(string: "under", attributes: [
            .font: font, .foregroundColor: sRGB(0x1F4E79), .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: sRGB(0xC00000)])
        text.append(NSAttributedString(string: " struck", attributes: [
            .font: font, .foregroundColor: sRGB(0x7030A0), .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .strikethroughColor: sRGB(0xFFC000)]))
        let html = try sent(text)
        XCTAssertTrue(html.contains("color: #1f4e79\"><u>under</u>"), html)
        XCTAssertTrue(html.contains("color: #7030a0\"><s> struck</s>"), html)
        for shifted in ["#c00000", "#ffc000", "#b00004", "#fdb409"] { XCTAssertFalse(html.contains(shifted), shifted) }
    }

    /// A table the composer inserts in a colour, with shaded cells, and a table pasted with its
    /// own shading and outer lines: every cell's background and lines, and the table's own, go
    /// out exactly as chosen.
    func testTableShadingAndLinesAreSentExactly() throws {
        let body = table(columns: 2, rows: 2, text: { "r\($0)c\($1)" }, lines: sRGB(0x1F4E79))
        let shades = [0xE2EFDA, 0xFFC000, 0xC00000, 0x808080]
        var cell = 0
        body.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: body.length)) { value, _, _ in
            guard let block = (value as? NSParagraphStyle)?.textBlocks.first, block.backgroundColor == nil else { return }
            block.backgroundColor = self.sRGB(shades[cell])
            cell += 1
        }
        let cells = cells(in: try sent(body))
        XCTAssertEqual(cells.count, 4)
        for (index, cell) in cells.enumerated() {
            XCTAssertTrue(cell.contains("background-color: \(css(shades[index]))"), cell)
            XCTAssertTrue(cell.contains("#1f4e79 #1f4e79"), cell)
        }

        let pasted = """
            <table style="border: 2px solid #C00000; background-color: #E2EFDA; border-collapse: collapse"><tr>\
            <td style="background-color: #FFC000; border: 1px solid #1F4E79">a</td>\
            <td style="border: 1px solid #808080">b</td></tr></table>
            """
        let read = try NSAttributedString(data: Data(pasted.utf8), options: [
            .documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                                          documentAttributes: nil)
        let html = try sent(read)
        let table = try XCTUnwrap(html.components(separatedBy: "<table").dropFirst().first?.prefix { $0 != ">" })
        XCTAssertTrue(table.contains("background-color: #e2efda"), String(table))
        XCTAssertTrue(table.contains("border-color: #c00000 #c00000 #c00000 #c00000"), String(table))
        let sentCells = self.cells(in: html)
        XCTAssertEqual(sentCells.count, 2, html)
        XCTAssertTrue(sentCells[0].contains("background-color: #ffc000"), sentCells[0])
        XCTAssertTrue(sentCells[0].contains("border-color: #1f4e79 #1f4e79 #1f4e79 #1f4e79"), sentCells[0])
        XCTAssertTrue(sentCells[1].contains("border-color: #808080 #808080 #808080 #808080"), sentCells[1])
    }

    /// A signature keeps its colours as it is saved, as RTFD, and when it is put into a message.
    func testASignaturesColoursAreSentExactly() throws {
        let words = NSMutableAttributedString(string: "Alex Moreno", attributes: [.font: font, .foregroundColor: sRGB(0x1F4E79)])
        words.append(NSAttributedString(string: "\nFinance", attributes: [.font: font, .foregroundColor: sRGB(0xC00000),
                                                                          .backgroundColor: sRGB(0xFFFF00)]))
        var signature = Signature(name: "Work")
        signature.setText(words)
        let body = NSMutableAttributedString(string: "Thanks,\n", attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        body.append(signature.text)
        let html = try sent(body)
        XCTAssertTrue(html.contains("color: #1f4e79\">Alex Moreno<"), html)
        XCTAssertTrue(html.contains("color: #c00000\">Finance<"), html)
        XCTAssertTrue(html.contains("background-color: #ffff00"), html)
    }

    /// RTF as Word, Excel and Outlook put it on the pasteboard: a plain colour table, which
    /// AppKit reads as calibrated RGB, of #C00000, #1F4E79, #E2EFDA and #FFC000.
    private func pastedFromOffice(_ body: String) throws -> NSAttributedString {
        let rtf = #"{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\fswiss Calibri;}}"#
            + #"{\colortbl;\red192\green0\blue0;\red31\green78\blue121;\red226\green239\blue218;\red255\green192\blue0;}"#
            + body + "}"
        return try NSAttributedString(data: Data(rtf.utf8), options: [.documentType: NSAttributedString.DocumentType.rtf],
                                      documentAttributes: nil)
    }

    private let officeShifted = ["#ce1c00", "#27628c", "#e7f2e1", "#ffca00"]

    /// Text and a table pasted from Word or Excel, with its cells' shading and lines, go out in
    /// the colours they were given there, not shifted as if Office's values were calibrated RGB.
    func testColoursPastedFromOfficeAreSentAsTheyWereChosen() throws {
        let pasted = try pastedFromOffice(#"""
            \pard\f0\fs22{\cf2 Figures }{\cf1\cb4 as agreed}\par
            \trowd\trgaph108\trleft0
            \clbrdrt\brdrs\brdrw10\brdrcf2\clbrdrl\brdrs\brdrw10\brdrcf2\clbrdrb\brdrs\brdrw10\brdrcf2\clbrdrr\brdrs\brdrw10\brdrcf2\clcbpat3\cellx2000
            \clbrdrt\brdrs\brdrw10\brdrcf1\clbrdrl\brdrs\brdrw10\brdrcf1\clbrdrb\brdrs\brdrw10\brdrcf1\clbrdrr\brdrs\brdrw10\brdrcf1\clcbpat4\cellx4000
            \pard\intbl{\cf1 Alert}\cell{\cf2 Note}\cell\row
            \pard\par
            """#)
        let html = try sent(pasted)
        XCTAssertTrue(html.contains("color: #1f4e79\">Figures <"), html)
        XCTAssertTrue(html.contains("color: #c00000; background-color: #ffc000\">as agreed<"), html)
        let cells = cells(in: html)
        XCTAssertEqual(cells.count, 2, html)
        XCTAssertTrue(cells[0].contains("background-color: #e2efda"), cells[0])
        XCTAssertTrue(cells[0].contains("border-color: #1f4e79 #1f4e79 #1f4e79 #1f4e79"), cells[0])
        XCTAssertTrue(cells[1].contains("background-color: #ffc000"), cells[1])
        XCTAssertTrue(cells[1].contains("border-color: #c00000 #c00000 #c00000 #c00000"), cells[1])
        XCTAssertTrue(html.contains("color: #c00000\">Alert<"), html)
        XCTAssertTrue(html.contains("color: #1f4e79\">Note<"), html)
        for shifted in officeShifted { XCTAssertFalse(html.contains(shifted), shifted) }
    }

    /// A signature designed in Word and pasted into the signature editor, which keeps the source's
    /// formatting, goes out in Word's colours once it is saved and opens a message.
    func testASignaturePastedFromWordIsSentInWordsColours() throws {
        let pasted = try pastedFromOffice(#"\pard\f0\fs22{\cf2 Alex Moreno}\par{\cf1\cb3 Finance}\par{\cb4 Leeds office}"#)
        var signature = Signature(name: "Work")
        signature.setText(pasted)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let rich = try XCTUnwrap(ComposedBody.opening(lead: "Thanks,\n", signature: signature, tail: "", attributes: attributes).rich)
        let rtf = try XCTUnwrap(rich.rtf(from: NSRange(location: 0, length: rich.length),
                                         documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]))
        let html = ComposedHTML.document(rtf: rtf, plain: rich.string, historyPlain: "", historyHTML: "")
        XCTAssertTrue(html.contains("color: #1f4e79\">Alex Moreno<"), html)
        XCTAssertTrue(html.contains("color: #c00000; background-color: #e2efda\">Finance<"), html)
        XCTAssertTrue(html.contains("background-color: #ffc000\">Leeds office<"), html)
        for shifted in officeShifted { XCTAssertFalse(html.contains(shifted), shifted) }
    }

    /// A reply's own text is sent in its exact colours; the original after it is sent as its own
    /// HTML, not a character of it changed, whatever colours it holds.
    func testAReplyIsExactAndItsOriginalUntouched() throws {
        let history = "From: Sam\nThe figures"
        let historyHTML = "<div style=\"color: #fb0007; background-color: #6C6C6C\"><font color=\"#ffff0b\">The figures</font></div>"
        let own = NSMutableAttributedString(string: "See below", attributes: [.font: font, .foregroundColor: sRGB(0xFF0000)])
        own.append(NSAttributedString(string: "\n\n", attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        let body = NSMutableAttributedString(attributedString: own)
        body.append(NSAttributedString(string: history, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        let rtf = try XCTUnwrap(body.rtf(from: NSRange(location: 0, length: body.length),
                                         documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]))
        let html = ComposedHTML.document(rtf: rtf, plain: body.string, historyPlain: history, historyHTML: historyHTML)
        XCTAssertTrue(html.contains("color: #ff0000\">See below<"), html)
        XCTAssertTrue(html.hasSuffix(historyHTML + "</body></html>"), html)
        XCTAssertEqual(html.components(separatedBy: "#fb0007").count, 2, html)
        XCTAssertFalse(html.contains("From: Sam"), html)
    }

    /// A body with no rich text is sent as it always was: nothing in it is taken for a colour,
    /// in its own words or in the original of a reply.
    func testAPlainBodyIsSentAsItWas() {
        let style = "font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:14px"
        XCTAssertEqual(ComposedHTML.document(rtf: nil, plain: "Red is #fb0007 <b>", historyPlain: "", historyHTML: ""),
                       "<html><body style=\"\(style);white-space:pre-wrap\">Red is #fb0007 &lt;b&gt;</body></html>")
        let historyHTML = "<p style=\"color: #6c6c6c\">Earlier</p>"
        XCTAssertEqual(ComposedHTML.document(rtf: nil, plain: "Yes #ffff0b\n\nEarlier", historyPlain: "Earlier", historyHTML: historyHTML),
                       "<html><body style=\"\(style)\"><div style=\"white-space:pre-wrap\">Yes #ffff0b\n\n</div>\(historyHTML)</body></html>")
    }

    /// Only what is sent is recoloured: the draft keeps every colour and block it had, in the
    /// spaces they were chosen in.
    func testTheDraftsColoursAreLeftAlone() throws {
        let body = table(columns: 1, rows: 1, text: { _, _ in "Cell" }, lines: sRGB(0x1F4E79), ink: sRGB(0xC00000))
        let at = (body.string as NSString).range(of: "Cell").location
        let style = try XCTUnwrap(body.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle)
        let block = try XCTUnwrap(style.textBlocks.first as? NSTextTableBlock)
        block.backgroundColor = sRGB(0xE2EFDA)
        block.table.backgroundColor = sRGB(0xFFC000)
        body.addAttribute(.backgroundColor, value: sRGB(0xFFFF00), range: NSRange(location: at, length: 4))
        let before = NSAttributedString(attributedString: body)
        _ = ComposedHTML.html(from: body)
        XCTAssertEqual(body, before)
        XCTAssertTrue(style.textBlocks.first === block)
        XCTAssertEqual(block.backgroundColor, sRGB(0xE2EFDA))
        XCTAssertEqual(block.table.backgroundColor, sRGB(0xFFC000))
        XCTAssertEqual(block.borderColor(for: .maxX), sRGB(0x1F4E79))
        XCTAssertEqual(body.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor, sRGB(0xC00000))
        XCTAssertEqual(body.attribute(.backgroundColor, at: at, effectiveRange: nil) as? NSColor, sRGB(0xFFFF00))
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
