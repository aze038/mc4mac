import XCTest
import AppKit
@testable import FalconCore

/// A signature made in Gmail or on a web page, laid out with tables, goes out exactly as its
/// owner made it: its own HTML, byte for byte, only each picture's src made the cid: of the
/// picture sent with the message, whichever way it came in (imported from Gmail, or pasted into
/// the signature editor) and after the draft is kept and opened again. The composer shows it as
/// the HTML lays it out: tables only as wide as what they hold, a table's max-width kept, and
/// each picture at the size the HTML gives it, not its own pixel size. Everything here is made
/// up; nothing is fetched.
final class SignatureSourceTests: XCTestCase {
    private let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor]
    private static let logoAddress = "https://example.com/email/logo-mark.png"

    /// The made-up signature, laid out as the real template is: nested presentation tables with
    /// no width of their own, a spacer cell, a logo declared 48 by 49 CSS pixels, a disclaimer
    /// table capped at 460 pixels, and styled text.
    static let fragment = """
    <table cellpadding="0" cellspacing="0" border="0" role="presentation" style="border-collapse:collapse;font-family:'Helvetica Neue',Helvetica,Arial,sans-serif;"><tr>
    <td valign="top" style="padding:3px 16px 0 0;vertical-align:top;"><img src="\(logoAddress)" width="48" height="49" alt="Example Freight" style="display:block;border:0;outline:none;width:48px;height:49px;"></td>
    <td valign="top">
    <p style="margin:0;font-family:'Helvetica Neue',Helvetica,Arial,sans-serif;font-size:15px;line-height:20px;color:#111827;font-weight:bold;">Alex Example</p>
    <p style="margin:0;font-family:'Helvetica Neue',Helvetica,Arial,sans-serif;font-size:12px;line-height:18px;color:#6B7280;letter-spacing:0.2px;">Operations, <span style='color:#111827;text-transform:uppercase;'>Example Freight</span></p>
    <table cellpadding="0" cellspacing="0" border="0" role="presentation" style="border-collapse:collapse;"><tr><td height="8" style="height:8px;font-size:1px;line-height:1px;">&nbsp;</td></tr></table>
    <p style="margin:0;font-family:'Helvetica Neue',Helvetica,Arial,sans-serif;font-size:12px;line-height:19px;color:#111827;"><a href="tel:+15550100" style="color:#111827;text-decoration:none;white-space:nowrap;"><span style="color:#111827;">+1 555 0100</span></a></p><p style="margin:0;font-family:'Helvetica Neue',Helvetica,Arial,sans-serif;font-size:12px;line-height:19px;color:#111827;"><a href="mailto:alex@example.com" style="color:#111827;text-decoration:none;white-space:nowrap;"><span style="color:#111827;">alex@example.com</span></a></p><p style="margin:0;font-family:'Helvetica Neue',Helvetica,Arial,sans-serif;font-size:12px;line-height:19px;color:#111827;"><a href="https://example.com" style="color:#1C5D99;text-decoration:none;white-space:nowrap;"><span style="color:#1C5D99;">example.com</span></a></p>
    <p style="margin:0;font-family:'Helvetica Neue',Helvetica,Arial,sans-serif;font-size:11px;line-height:17px;color:#9CA3AF;padding-top:6px;"><span style='white-space:nowrap;'>Northland · Southland</span> &nbsp; <span style='white-space:nowrap;'>ISO 9001:2015</span></p>
    </td></tr></table>
    <table cellpadding="0" cellspacing="0" border="0" role="presentation" style="border-collapse:collapse;max-width:460px;"><tr><td style="padding-top:16px;font-family:'Helvetica Neue',Helvetica,Arial,sans-serif;font-size:9px;line-height:13px;color:#B0B6BE;">This made-up message is confidential and meant for the recipient named in it only. If it reached you by mistake, please tell the sender and delete it.</td></tr></table>
    """

    /// The same as a browser puts it on the pasteboard, or a page holds it.
    static let document = "<!doctype html><html><head><meta charset=\"utf-8\"></head><body>\n\(fragment)\n</body></html>"

    /// The logo at three times the size it is shown at, as a sharp logo is made.
    static let logo: Data = {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 144, pixelsHigh: 147, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 144, height: 147).fill()
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: 48, height: 147).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }()

    private var fetched: [String: Data] { [Self.logoAddress: Self.logo] }

    @MainActor
    private func imported(remote: [String: Data]? = nil) throws -> Signature {
        let candidate = SignatureCandidate(name: "Gmail – alex@example.com", origin: .gmail(account: "alex@example.com"),
                                           html: Self.fragment, defaultAddresses: ["alex@example.com"], defaultsKnown: true)
        return try XCTUnwrap(candidate.signature(remote: remote ?? fetched, attributes: body))
    }

    /// What is sent for a body, from the draft it is kept as, as the app sends it.
    private func sent(_ rich: NSAttributedString, signatures: [SignatureSource]) -> ComposedHTML.Content {
        let stored = ComposedBody.stored(rich)
        return ComposedHTML.content(rtf: stored.rtf, rtfd: stored.rtfd, plain: rich.string, historyPlain: "", historyHTML: "",
                                    signatures: signatures)
    }

    private func pixels(of data: Data) -> [Int] {
        guard let rep = NSBitmapImageRep(data: data) else { return [] }
        return [rep.pixelsWide, rep.pixelsHigh]
    }

    private func tableTags(in html: String) -> [String] {
        html.components(separatedBy: "<table").dropFirst().map { "<table" + String($0.prefix { $0 != ">" }) + ">" }
    }

    // MARK: - What is sent

    @MainActor
    func testAnImportedGmailSignatureIsSentByteForByteOnlyItsPicturesSrcMadeTheirCid() throws {
        var book = SignatureBook()
        book.importing([SignatureImportItem(signature: try imported())])
        // Kept as the signatures file keeps it, then read back as the app reads it at launch.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("signatures-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try SignatureStore(file: file).save(book)
        let signature = try XCTUnwrap(SignatureStore(file: file).open().book.signatures.first)
        XCTAssertEqual(signature.html, Self.fragment)
        let source = try XCTUnwrap(signature.source)

        let opened = ComposedBody.opening(lead: "Hello Sam,\n\nThe figures are attached.\n\n", signature: signature, tail: "", attributes: body)
        let content = sent(try XCTUnwrap(opened.rich), signatures: [source])
        XCTAssertEqual(content.pictures.count, 1)
        let logo = try XCTUnwrap(content.pictures.first)
        XCTAssertEqual(pixels(of: logo.data), [144, 147], "the logo goes with every pixel it came with")
        XCTAssertEqual(logo.mimeType, "image/png")
        let expected = Self.fragment.replacingOccurrences(of: "src=\"\(Self.logoAddress)\"", with: "src=\"cid:\(logo.contentID)\"")
        XCTAssertTrue(content.html.contains("<div>\(expected)</div>"), content.html)
        XCTAssertFalse(content.html.contains(Self.logoAddress))
        XCTAssertFalse(content.html.contains("FalconMailSignature"), content.html)
        // After the user's own text, as Gmail puts it.
        let words = try XCTUnwrap(content.html.range(of: "The figures are attached."))
        let placed = try XCTUnwrap(content.html.range(of: expected))
        XCTAssertLessThan(words.lowerBound, placed.lowerBound)
        // Every style it gives is there as given: no table given a width, no colour turned.
        for kept in ["max-width:460px;", "padding:3px 16px 0 0;vertical-align:top;", "width=\"48\" height=\"49\"",
                     "display:block;border:0;outline:none;width:48px;height:49px;", "font-size:15px;line-height:20px;color:#111827;font-weight:bold;",
                     "letter-spacing:0.2px;", "text-transform:uppercase;", "height=\"8\" style=\"height:8px;font-size:1px;line-height:1px;\"",
                     "color:#1C5D99;text-decoration:none;white-space:nowrap;", "font-family:'Helvetica Neue',Helvetica,Arial,sans-serif;"] {
            XCTAssertTrue(content.html.contains(kept), kept)
        }
        for tag in tableTags(in: content.html) {
            XCTAssertFalse(tag.contains("100%"), tag)
            XCTAssertFalse(tag.contains(" width="), tag)
        }

        // The plain text part is the signature's words, a line to each, the logo by its cid.
        XCTAssertTrue(content.plain.contains("Hello Sam,"), content.plain)
        for line in ["-- ", "Alex Example", "Operations, Example Freight", "+1 555 0100", "alex@example.com", "example.com",
                     "[cid:\(logo.contentID)]"] {
            XCTAssertTrue(content.plain.localizedCaseInsensitiveContains(line), "\(line) in \(content.plain)")
        }
        XCTAssertFalse(content.plain.contains("<"), content.plain)
        XCTAssertFalse(content.plain.contains("\u{FFFC}"))

        // As it goes out, and read back as a recipient's reader reads it.
        let message = OutgoingMessage(from: EmailAddress(name: "Alex", address: "alex@example.com"),
                                      to: [EmailAddress(name: "Sam", address: "sam@example.com")], subject: "Figures",
                                      textBody: content.plain, htmlBody: content.html, attachments: content.pictures.map(\.attachment))
        let parsed = MIMEParser.parse(MIMEBuilder.build(message))
        XCTAssertTrue(parsed.textHTML?.contains(expected) ?? false)
        XCTAssertEqual(pixels(of: parsed.attachments.first { $0.contentID == logo.contentID }?.data ?? Data()), [144, 147])
    }

    @MainActor
    func testTheSignatureIsStillSentExactlyAfterTheDraftIsKeptAndOpenedAgain() throws {
        let signature = try imported()
        let source = try XCTUnwrap(signature.source)
        let opened = ComposedBody.opening(lead: "\n\n", signature: signature, tail: "", attributes: body)
        // Kept as a draft keeps its body, twice over, then sent.
        var stored = ComposedBody.stored(try XCTUnwrap(opened.rich))
        let reopened = try XCTUnwrap(ComposedBody.text(rtf: stored.rtf, rtfd: stored.rtfd))
        stored = ComposedBody.stored(reopened)
        let again = try XCTUnwrap(ComposedBody.text(rtf: stored.rtf, rtfd: stored.rtfd))
        // The logo is shown at the size the HTML gives it, not its 144 by 147 pixels.
        let shown = try XCTUnwrap(InlinePictures.attachmentLocations(in: again).first.flatMap { InlinePictures.picture(in: $0.1) })
        XCTAssertEqual(shown.size.width, 48, accuracy: 0.5)
        XCTAssertEqual(shown.size.height, 49, accuracy: 0.5)
        let content = ComposedHTML.content(rtf: stored.rtf, rtfd: stored.rtfd, plain: again.string, historyPlain: "", historyHTML: "",
                                           signatures: [source])
        let cid = try XCTUnwrap(content.pictures.first?.contentID)
        let expected = Self.fragment.replacingOccurrences(of: "src=\"\(Self.logoAddress)\"", with: "src=\"cid:\(cid)\"")
        XCTAssertTrue(content.html.contains("<div>\(expected)</div>"), content.html)
        XCTAssertEqual(pixels(of: content.pictures.first?.data ?? Data()), [144, 147])
    }

    @MainActor
    func testALogoThatCouldNotBeFetchedKeepsItsAddressAndEverythingElse() throws {
        let signature = try imported(remote: [:])
        let opened = ComposedBody.opening(lead: "\n\n", signature: signature, tail: "", attributes: body)
        let content = sent(try XCTUnwrap(opened.rich), signatures: [try XCTUnwrap(signature.source)])
        XCTAssertTrue(content.pictures.isEmpty)
        XCTAssertTrue(content.html.contains("<div>\(Self.fragment)</div>"), content.html)
    }

    // MARK: - Paste is import

    @MainActor
    func testPastingTheSignaturesHTMLGivesWhatImportingItGives() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("FalconMailTests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString(Self.document, forType: .html)
        let pasted = try XCTUnwrap(Signature.pasted(from: board, attributes: body))
        XCTAssertEqual(pasted.html, Self.fragment, "the page's wrapping is left behind, nothing inside it changed")
        let imported = try imported(remote: [:])
        // A signature kept as RTFD ends its last table's paragraph with a line break of its own.
        XCTAssertEqual(pasted.text.string.trimmingCharacters(in: .newlines), imported.text.string.trimmingCharacters(in: .newlines))
        XCTAssertEqual(InlinePictures.attachmentLocations(in: pasted.text).count, 1)

        // As the editor keeps what was pasted: the pasted HTML is what the signature sends.
        var book = SignatureBook()
        let id = book.add().id
        let source = SignatureSource(html: pasted.html, text: pasted.text)
        book.setEditedText(pasted.text, of: id, plainIn: body, pasted: source)
        let signature = try XCTUnwrap(book.signature(id))
        XCTAssertEqual(signature.html, Self.fragment)
        let opened = ComposedBody.opening(lead: "\n\n", signature: signature, tail: "", attributes: body)
        let fromPaste = sent(try XCTUnwrap(opened.rich), signatures: [try XCTUnwrap(signature.source)])
        let fromImport = sent(try XCTUnwrap(ComposedBody.opening(lead: "\n\n", signature: imported, tail: "", attributes: body).rich),
                              signatures: [try XCTUnwrap(imported.source)])
        XCTAssertEqual(fromPaste.html, fromImport.html)
        XCTAssertTrue(fromPaste.html.contains("<div>\(Self.fragment)</div>"), fromPaste.html)
    }

    func testWordsHTMLIsNotTakenAsASignatureToSendAsItIs() {
        XCTAssertNil(SignatureSource.sendable(OutlookFixture.wordHTML()))
        XCTAssertNil(SignatureSource.sendable("<div>Alex</div><script>alert(1)</script>"))
        XCTAssertNil(SignatureSource.sendable("<html><head><style>p{color:red}</style></head><body><p>Alex</p></body></html>"))
        XCTAssertEqual(SignatureSource.sendable("<html><body><!--StartFragment--><div>Alex</div><!--EndFragment--></body></html>"),
                       "<div>Alex</div>")
    }

    // MARK: - As the composer shows it

    @MainActor
    func testTheTablesAreLaidOutAsTheHTMLLaysThemOut() throws {
        let signature = try imported()
        let tables = SignatureTables.textTables(in: signature.text)
        XCTAssertEqual(tables.count, 3, "the signature's table, its spacer and its disclaimer")
        guard tables.count == 3 else { return }
        for (table, _) in tables {
            XCTAssertEqual(table.layoutAlgorithm, .automaticLayoutAlgorithm)
            XCTAssertEqual(table.contentWidth, 0, "no width the HTML does not give")
        }
        XCTAssertEqual(tables[2].table.value(for: .maximumWidth), 460, accuracy: 0.5)
        XCTAssertEqual(tables[2].table.valueType(for: .maximumWidth), .absoluteValueType)
        // The logo's cell keeps its padding.
        let logoCell = try XCTUnwrap(tables[0].cells.first)
        XCTAssertEqual(logoCell.width(for: .padding, edge: .minY), 3, accuracy: 0.5)
        XCTAssertEqual(logoCell.width(for: .padding, edge: .maxX), 16, accuracy: 0.5)
        XCTAssertEqual(logoCell.width(for: .padding, edge: .minX), 0, accuracy: 0.5)
        let picture = try XCTUnwrap(InlinePictures.attachmentLocations(in: signature.text).first.flatMap { InlinePictures.picture(in: $0.1) })
        XCTAssertEqual(picture.size, NSSize(width: 48, height: 49))
    }

    // MARK: - Kept by every build

    func testASignatureKeptByAnEarlierBuildStillOpens() throws {
        let id = UUID()
        let json = """
        {"version":1,"signatures":[{"id":"\(id.uuidString)","name":"Main","plain":"Alex Example"}],"defaults":[],"adopted":[]}
        """
        let book = try JSONDecoder().decode(SignatureBook.self, from: Data(json.utf8))
        XCTAssertEqual(book.signature(id)?.plain, "Alex Example")
        XCTAssertNil(book.signature(id)?.html)
    }

    /// Signature as v1.10 decodes it.
    private struct EarlierSignature: Decodable {
        var id: UUID
        var name: String
        var plain: String
        var rich: Data?
    }

    private struct EarlierBook: Decodable {
        var version: Int
        var signatures: [EarlierSignature]
    }

    @MainActor
    func testAnEarlierBuildReadsASignatureKeptWithItsHTML() throws {
        let signature = try imported()
        let data = try JSONEncoder().encode(SignatureBook(signatures: [signature]))
        let earlier = try JSONDecoder().decode(EarlierBook.self, from: data)
        XCTAssertEqual(earlier.version, SignatureBook.currentVersion)
        XCTAssertEqual(earlier.signatures.first?.rich, signature.rich)
        XCTAssertEqual(earlier.signatures.first?.plain, signature.plain)
    }

    // MARK: - Edited

    @MainActor
    func testAnEditedSignatureIsSentAsTheEditorShowsItWithSaneWidths() throws {
        var book = SignatureBook()
        book.importing([SignatureImportItem(signature: try imported())])
        let id = try XCTUnwrap(book.signatures.first?.id)
        let edited = NSMutableAttributedString(attributedString: try XCTUnwrap(book.signature(id)).text)
        let name = (edited.string as NSString).range(of: "Alex Example")
        edited.replaceCharacters(in: NSRange(location: NSMaxRange(name), length: 0), with: " Jr")
        book.setEditedText(edited, of: id, plainIn: body)
        let signature = try XCTUnwrap(book.signature(id))
        XCTAssertNil(signature.html, "changed words are no longer the HTML's")
        let opened = ComposedBody.opening(lead: "\n\n", signature: signature, tail: "", attributes: body)
        let content = sent(try XCTUnwrap(opened.rich), signatures: SignatureSources.all + [try XCTUnwrap(try imported().source)])
        XCTAssertTrue(content.html.contains("Alex Example Jr"), content.html)
        XCTAssertFalse(content.html.contains("role=\"presentation\""), "the original HTML is not sent for changed words")
        XCTAssertFalse(content.html.contains("FalconMailSignature"))
        let tables = tableTags(in: content.html)
        XCTAssertFalse(tables.isEmpty, content.html)
        for tag in tables {
            XCTAssertFalse(tag.contains("100%"), "\(tag) in \(content.html)")
        }
        XCTAssertTrue(content.html.contains("width=\"48\" height=\"49\""), content.html)
    }

    @MainActor
    func testTheSameWordsTypedInAMessageAreNotTakenForTheSignature() throws {
        let signature = try imported()
        let source = try XCTUnwrap(signature.source)
        let typed = NSMutableAttributedString(string: "Alex Example\n", attributes: body)
        typed.append(NSAttributedString(string: signature.text.string, attributes: body))
        let content = sent(typed, signatures: [source])
        XCTAssertFalse(content.html.contains("role=\"presentation\""), content.html)
    }
}
