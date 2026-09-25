import XCTest
import AppKit
@testable import FalconCore

/// A reply or forward never shows a picture's code or address as words, even when it cannot
/// quote its original as rich text. An original this Mac holds only the headers of is
/// downloaded before the reply opens, so it is quoted with its pictures; one that has no HTML,
/// or whose HTML cannot be read, is quoted as its words, taken from its HTML where it has any
/// and otherwise from its plain text without the stand-ins its sender's mail program wrote.
///
/// The app's steps are modelled here as AppModel.originalForQuoting, ComposeDraft.history and
/// ComposeDraft.outgoing take them. The server is a fake on this Mac; nothing reaches the network.
@MainActor
final class QuoteFallbackTests: XCTestCase {
    private var harness: EngineHarness?
    private let font = NSFont.systemFont(ofSize: 14)
    private var body: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: NSColor.labelColor] }
    private let cid = "image001.png@01DC2E5A.3F1B7C40"
    private let heading = "\n________________________________\nFrom: Sam <sam@example.com>\nSent: Thursday, 24 September 2026 at 16:05\nTo: Alex <alex@example.com>\nSubject: Figures\n\n"

    override func tearDown() async throws {
        await harness?.finish()
        harness = nil
    }

    // MARK: - stand-ins

    private func png(_ width: Int = 120, _ height: Int = 36) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemIndigo.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// As Outlook for Windows sends a message: HTML with its head, its conditional comments,
    /// lines wrapped in the middle of a sentence, empty paragraphs, and a signature whose logo
    /// is an inline part shown by cid: inside a link; beside it, plain text that writes
    /// [cid:…]<address> where the logo stands and report<address> after a link.
    private func outlookRaw(logo: Data, html: String? = nil) -> Data {
        let page = html ?? """
        <html xmlns:o="urn:schemas-microsoft-com:office:office"><head><meta http-equiv=Content-Type content="text/html; charset=utf-8">\r
        <style><!--\r
        p.MsoNormal {margin:0cm; font-size:11.0pt; font-family:"Calibri",sans-serif;}\r
        --></style><!--[if gte mso 9]><xml>\r
        <o:shapedefaults v:ext="edit" spidmax="1026" />\r
        </xml><![endif]--></head><body lang=EN-GB link="#0563C1"><div class=WordSection1>\r
        <p class=MsoNormal>Hi Alex,<o:p></o:p></p><p class=MsoNormal><o:p>&nbsp;</o:p></p>\r
        <p class=MsoNormal>The figures are in the <a href="https://example.com/report">report</a>, and the rates\r
        are on our site: <a href="https://northwind.example/rates">https://northwind.example/rates</a>.<o:p></o:p></p>\r
        <p class=MsoNormal><o:p>&nbsp;</o:p></p><p class=MsoNormal>Kind regards,<o:p></o:p></p>\r
        <table class=MsoNormalTable border=0><tr><td><p class=MsoNormal><a href="https://northwind.example/"><span style='text-decoration:none'><img border=0 width=120 height=36 style='width:1.25in;height:.375in' id="Picture_x0020_1" src="cid:\(cid)" alt="Northwind &amp; Co"></span></a><o:p></o:p></p></td>\r
        <td><p class=MsoNormal><b>Sam Carter</b><o:p></o:p></p><p class=MsoNormal>Northwind &amp; Co &#8211; Operations<o:p></o:p></p></td></tr></table>\r
        </div></body></html>
        """
        let raw = """
        From: Sam <sam@example.com>\r
        To: Alex <alex@example.com>\r
        Subject: Figures\r
        Date: Thu, 24 Sep 2026 16:05:00 +0100\r
        Message-ID: <figures@example.com>\r
        MIME-Version: 1.0\r
        Content-Type: multipart/related; boundary="rel"; type="multipart/alternative"\r
        \r
        --rel\r
        Content-Type: multipart/alternative; boundary="alt"\r
        \r
        --alt\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        Hi Alex,\r
        \r
        The figures are in the report<https://example.com/report>, and the rates are on our site: https://northwind.example/rates.\r
        \r
        Kind regards,\r
        [cid:\(cid)]<https://northwind.example/>\r
        Sam Carter\r
        Northwind & Co – Operations\r
        --alt\r
        Content-Type: text/html; charset=utf-8\r
        \r
        \(page)\r
        --alt--\r
        --rel\r
        Content-Type: image/png; name="image001.png"\r
        Content-Disposition: inline; filename="image001.png"\r
        Content-ID: <\(cid)>\r
        Content-Transfer-Encoding: base64\r
        \r
        \(logo.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]))\r
        --rel--\r
        """
        return Data(raw.utf8)
    }

    /// As a Gmail user's message reaches a program that asked for plain text alone: the
    /// signature's logo written as [image: …] <address>.
    private func gmailPlainOnly() -> MIMEMessage {
        let raw = """
        From: Jordan <jordan@example.net>\r
        To: Alex <alex@example.com>\r
        Subject: Delivery\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        Booked for Friday. The tracking page is https://track.example.net/ABC123 and the terms\r
        are at <https://northwind.example/terms>.\r
        \r
        --\r
        Jordan Lee\r
        [image: Northwind] <https://northwind.example/>\r
        [image: Facebook] <https://facebook.example/northwind>  [image: LinkedIn] <https://linkedin.example/northwind>\r
        Northwind Logistics\r
        """
        return MIMEParser.parse(Data(raw.utf8))
    }

    private func assertNoStandIns(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        for words in ["cid:", "[cid", "image001", "[image", "<https://northwind.example/>", "facebook.example", "linkedin.example",
                      "&nbsp;", "\u{FFFC}", "data:image", "mso", "<o:p>", "shapedefaults"] {
            XCTAssertFalse(text.contains(words), "the quote shows \(words): \(text.debugDescription)", file: file, line: line)
        }
    }

    /// The history ComposeDraft.history builds for an original quoted as its words, and what
    /// ComposeDraft.outgoing sends for a reply whose body is `body`.
    private func sent(body: String, history: String, historyHTML: String) -> ComposedHTML.Content {
        ComposedHTML.content(rich: nil, plain: body, historyPlain: history, historyHTML: historyHTML)
    }

    // MARK: - An original not yet downloaded

    func testAnOutlookOriginalNotYetDownloadedIsDownloadedAndQuotedWithItsLogo() async throws {
        let logo = try png()
        let server = try EngineHarness.gmailServer()
        server.add(outlookRaw(logo: logo), to: "INBOX")
        let h = try await EngineHarness(server: server)
        harness = h
        try await h.syncOnce()
        let message = try await h.message(uid: 1, in: "INBOX")
        let folderStore = try await h.store.folderStore(try await h.folder("INBOX"))
        let held = await folderStore.body(uid: 1)
        XCTAssertNil(held, "only the headers are on this Mac")

        // Before the download, the quote could only be the few words the list shows, and even
        // those never show the logo's code: as the list shows an Outlook message once stored...
        let listed = MIMEParser.parse(outlookRaw(logo: logo)).snippet
        XCTAssertTrue(listed.contains("[cid:"), "Outlook's plain text leads the list's few words")
        let early = QuotedText.of(nil, snippet: listed)
        assertNoStandIns(early)
        XCTAssertTrue(early.contains("Kind regards,"))
        // ...and as it shows one cut off in the middle of the code.
        XCTAssertEqual(QuotedText.of(nil, snippet: "Kind regards, [cid:image001.png@01DC2E"), "Kind regards,")
        XCTAssertEqual(QuotedText.of(nil, snippet: message.snippet), message.snippet, "nothing else is touched")

        // Reply downloads the whole message first (AppModel.originalForQuoting), and the quote
        // is then the original as rich text with its logo as a picture.
        let parsed = try await h.syncer.parsedMessage(for: message)
        let stored = await folderStore.body(uid: 1)
        XCTAssertNotNil(stored, "kept for next time")
        let quote = try XCTUnwrap(ComposedBody.quote(heading: heading, html: try XCTUnwrap(parsed.textHTML),
                                                     parts: parsed.attachments, attributes: body))
        let pictures = InlinePictures.attachmentLocations(in: quote).map(\.1)
        XCTAssertEqual(pictures.count, 1)
        XCTAssertEqual(pictures.first?.fileWrapper?.regularFileContents, logo)
        XCTAssertTrue(quote.string.contains("The figures are in the report"), quote.string.debugDescription)
        XCTAssertFalse(quote.string.contains("cid:"))
        XCTAssertFalse(quote.string.contains("<https://"))
    }

    // MARK: - HTML that cannot be quoted as rich text

    func testAnOriginalWhoseHTMLCannotBeReadIsQuotedAsItsWordsWithoutStandIns() throws {
        let parsed = MIMEParser.parse(outlookRaw(logo: try png()))
        XCTAssertTrue(parsed.bestText.contains("[cid:\(cid)]<https://northwind.example/>"), "the sender's own plain text")
        let words = QuotedText.of(parsed, snippet: "")
        assertNoStandIns(words)
        XCTAssertEqual(words, """
            Hi Alex,

            The figures are in the report, and the rates are on our site: https://northwind.example/rates.

            Kind regards,
            Sam Carter
            Northwind & Co – Operations
            """)

        // What the reply shows and sends: the quote untouched, then edited inside.
        let history = heading + words + "\n"
        let historyHTML = "<div style=\"white-space:pre-wrap\">\(HTMLText.escape(words))</div>"
        let untouched = sent(body: "\n\nThanks.\n" + history, history: history, historyHTML: historyHTML)
        assertNoStandIns(untouched.plain)
        XCTAssertTrue(untouched.plain.contains("Sam Carter"))
        let edited = sent(body: "\n\nThanks.\n" + history.replacingOccurrences(of: "Kind regards,", with: "Kind regards, EDITED"),
                          history: history, historyHTML: historyHTML)
        assertNoStandIns(edited.plain)
        assertNoStandIns(edited.html)
        XCTAssertTrue(edited.html.contains("EDITED"))
    }

    func testTheWordsOfHTMLKeepItsLinesAndLinkWordsButNoPicture() {
        XCTAssertEqual(QuotedText.fromHTML("""
            <div dir="ltr"><div>Booked for <b>Friday</b>.</div><div><br></div><div>See the <a href="https://example.com/terms">terms</a>.</div>
            <div class="gmail_signature"><a href="https://northwind.example/"><img src="https://lh3.example.invalid/logo.png" alt="Northwind" width="96"></a></div>
            <img src="https://tracker.example.invalid/open.gif" width="1" height="1"><span style="display:none">preheader</span></div>
            """), "Booked for Friday.\n\nSee the terms.")
        // Paragraphs other than Outlook's leave a blank line; lists keep their items.
        XCTAssertEqual(QuotedText.fromHTML("<p>One</p><p>Two</p><ul><li>a</li><li>b</li></ul><ol><li>c</li><li>d</li></ol>"),
                       "One\n\nTwo\n\n• a\n• b\n1. c\n2. d")
        // Text that keeps its spacing, as FalconMail's own plain messages go, keeps its lines.
        XCTAssertEqual(QuotedText.fromHTML("<div style=\"white-space:pre-wrap\">Line one\nLine  two\n\nLine &lt;three&gt;</div>"),
                       "Line one\nLine  two\n\nLine <three>")
        // Characters written as references, each read once.
        XCTAssertEqual(QuotedText.fromHTML("Caf&eacute; &amp;lt; &#8217;s &#x2014; a&nbsp;b &bogus; x < y"),
                       "Café &lt; ’s — a b &bogus; x < y")
    }

    // MARK: - Plain text alone

    func testAPlainOnlyGmailOriginalIsQuotedWithoutItsImageStandIns() {
        // Trimmed, as ComposeDraft.history quotes it.
        let words = QuotedText.of(gmailPlainOnly(), snippet: "").trimmed
        assertNoStandIns(words)
        XCTAssertEqual(words, """
            Booked for Friday. The tracking page is https://track.example.net/ABC123 and the terms
            are at <https://northwind.example/terms>.

            --
            Jordan Lee
            Northwind Logistics
            """)
    }

    func testLinksTheSenderTypedStay() {
        let typed = """
            See https://example.com/a and the report<https://example.com/report>, or <https://example.com/b>.
            Mail me at sam@example.com<mailto:sam@example.com>.
            [text in brackets] and [images of the site] stay too.
            """
        XCTAssertEqual(QuotedText.withoutPictureStandIns(typed), typed, "nothing there stands in for a picture")
        XCTAssertEqual(QuotedText.withoutPictureStandIns("Call me [image: phone] on 0161 496 0000 or see https://example.com/c."),
                       "Call me on 0161 496 0000 or see https://example.com/c.")
    }

    func testEveryKindOfPictureStandInGoes() {
        let text = """
            Regards,

            [cid:image002.jpg@01DC2E5A.3F1B7C40]
            [https://northwind.example/sig/logo.png]<https://northwind.example/>
            [A picture containing text, logo  Description automatically generated]
            [signature_1234567890]
            [image]

            Sam Carter [image: Northwind]
            """
        XCTAssertEqual(QuotedText.withoutPictureStandIns(text), "Regards,\n\nSam Carter")
    }
}
