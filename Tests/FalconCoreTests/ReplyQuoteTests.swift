import XCTest
import AppKit
@testable import FalconCore

/// How a reply or forward quotes its original, as Legacy Outlook for Mac does: as rich text with
/// its formatting, links and pictures, never with a picture's stand-in or address as words;
/// pictures from the web as empty boxes until they are fetched; and how carried-over account
/// signatures written in HTML, and signatures pasted from a web page, keep their pictures.
///
/// The app's steps are modelled here as ComposeDraft, ComposeView and SignatureLibrary take
/// them; nothing reaches the network, as every picture from the web comes from a stand-in loader.
@MainActor
final class ReplyQuoteTests: XCTestCase {
    private let font = NSFont.systemFont(ofSize: 14)
    private var body: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: NSColor.labelColor] }
    private let me = EmailAddress(name: "Alex Example", address: "alex@example.com")
    private let sam = EmailAddress(name: "Sam", address: "sam@example.com")
    private let cid = "image001.png@01DC2E5A.3F1B7C40"
    private let remoteLogo = "https://lh3.example.invalid/mail-sig/AIorK4northwind=s96?a=1&b=2"

    // MARK: - stand-ins

    private func png(_ width: Int = 120, _ height: Int = 36, colour: NSColor = .systemIndigo) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        colour.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// As Outlook for Windows sends a message: its logo an inline part that its HTML shows by
    /// cid:, and its plain text saying [cid:…] where the logo stands and <address> after a link.
    private func outlookOriginal(logo: Data) -> MIMEMessage {
        let raw = """
        From: Sam <sam@example.com>\r
        To: Alex <alex@example.com>\r
        Subject: Figures\r
        Content-Type: multipart/related; boundary="rel"; type="multipart/alternative"\r
        \r
        --rel\r
        Content-Type: multipart/alternative; boundary="alt"\r
        \r
        --alt\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        The figures are in the report<https://example.com/report>.\r
        [cid:\(cid)]\r
        --alt\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <html><head><style>p.MsoNormal{margin:0;font-family:"Calibri",sans-serif}</style></head><body><p class=MsoNormal>The figures are in the <a href="https://example.com/report">report</a>.</p><p class=MsoNormal><span style="color:#111111">Sam</span></p><p class=MsoNormal><img width=120 height=36 style="width:1.25in;height:.375in" src="cid:\(cid)" alt="Sam &amp; Co"></p></body></html>\r
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
        return MIMEParser.parse(Data(raw.utf8))
    }

    /// As Gmail sends a message: its signature's logo fetched from the web, inside a link, and
    /// its plain text saying [image: …] <address>.
    private func gmailOriginal() -> MIMEMessage {
        let raw = """
        From: Jordan <jordan@example.net>\r
        To: Alex <alex@example.com>\r
        Subject: Delivery\r
        Content-Type: multipart/alternative; boundary="alt"\r
        \r
        --alt\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        Booked for Friday.\r
        [image: Northwind] <https://northwind.example/>\r
        --alt\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <div dir="ltr"><div>Booked for <b>Friday</b>.</div><div class="gmail_signature"><a href="https://northwind.example/"><img src="\(remoteLogo.replacingOccurrences(of: "&", with: "&amp;"))" alt="Northwind" width="96" height="30"></a></div><img src="https://tracker.example.invalid/open.gif" width="1" height="1"></div>\r
        --alt--\r
        """
        return MIMEParser.parse(Data(raw.utf8))
    }

    /// The original's heading and HTML as ComposeDraft.history quotes it (see QuotedHistory), the
    /// HTML sent in its place while it is untouched.
    private func history(of parsed: MIMEMessage) -> QuotedHistory {
        let original = ReplyHeader.Original(from: parsed.from, date: parsed.date ?? Date(timeIntervalSince1970: 1_790_262_300),
                                            to: parsed.to, cc: parsed.cc, subject: parsed.subject)
        return QuotedHistory(original: original, html: InlinePictures.resolvingCIDs(in: parsed.textHTML ?? "", with: parsed.attachments),
                             text: parsed.bestText, attribution: .outlook, indent: false, font: .outlook)
    }

    /// A reply's body as ComposeDraft.reply opens it, kept as a draft keeps it and read back as
    /// the composer reads it: its words, its rich text, and the quote's text (historyPlain).
    private struct Opened {
        var rich: NSAttributedString
        var plain: String
        var historyPlain: String
        var historyHTML: String
        var stored: (rtf: Data?, rtfd: Data?)
    }

    private func reply(to parsed: MIMEMessage, remote: [String: Data] = [:], signature: Signature? = nil) throws -> Opened {
        let history = history(of: parsed)
        let quote = try XCTUnwrap(ComposedBody.quote(heading: history.heading, html: try XCTUnwrap(parsed.textHTML), parts: parsed.attachments,
                                                     remote: remote, attributes: body))
        let opened = ComposedBody.opening(lead: "\n\n", signature: signature, quote: quote, attributes: body)
        let stored = ComposedBody.stored(opened.rich)
        let read = try XCTUnwrap(ComposedBody.text(rtf: stored.rtf, rtfd: stored.rtfd))
        return Opened(rich: read, plain: opened.plain, historyPlain: quote.string, historyHTML: history.html, stored: stored)
    }

    /// What Send builds from a body as the draft keeps it (ComposeDraft.outgoing, MIMEBuilder).
    private func sent(_ rich: NSAttributedString, historyPlain: String, historyHTML: String) -> MIMEMessage {
        let stored = ComposedBody.stored(rich)
        let content = ComposedHTML.content(rtf: stored.rtf, rtfd: stored.rtfd, plain: rich.string, historyPlain: historyPlain,
                                           historyHTML: historyHTML)
        let message = OutgoingMessage(from: me, to: [sam], subject: "Re: Figures", textBody: content.plain, htmlBody: content.html,
                                      attachments: content.pictures.map(\.attachment))
        return MIMEParser.parse(MIMEBuilder.build(message))
    }

    private func attachments(in text: NSAttributedString) -> [NSTextAttachment] {
        InlinePictures.attachmentLocations(in: text).map(\.1)
    }

    /// The size a picture is shown at: its own, or the one its file declares, as a draft's RTFD
    /// keeps nothing else.
    private func shown(_ attachment: NSTextAttachment?) -> NSSize? {
        guard let attachment else { return nil }
        if attachment.bounds.width > 0 { return attachment.bounds.size }
        return attachment.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:))?.size
    }

    /// Words a picture must never be shown as in the composer.
    private func assertNoStandIns(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        for words in ["cid:", "[cid", "image001", "[image:", "https://", "http://", "example.invalid", "<https", "data:image"] {
            XCTAssertFalse(text.contains(words), "the quote shows \(words): \(text.debugDescription)", file: file, line: line)
        }
    }

    /// The inline picture parts of a sent message, by Content-ID.
    private func inlineParts(of parsed: MIMEMessage) -> [String: Data] {
        var parts: [String: Data] = [:]
        for part in parsed.attachments where part.isInline {
            if let id = part.contentID { parts[id] = part.data }
        }
        return parts
    }

    // MARK: - the quote

    func testAReplyQuotesAnOutlookOriginalWithItsLogoAsAPicture() throws {
        let logo = try png()
        let opened = try reply(to: outlookOriginal(logo: logo))
        let text = opened.rich
        assertNoStandIns(text.string)
        XCTAssertTrue(text.string.contains("The figures are in the report."), text.string.debugDescription)
        XCTAssertTrue(text.string.contains("From: Sam <sam@example.com>"))
        let pictures = attachments(in: text)
        XCTAssertEqual(pictures.count, 1)
        XCTAssertEqual(pictures.first?.fileWrapper?.regularFileContents, logo)
        XCTAssertEqual(shown(pictures.first), NSSize(width: 120, height: 36), "the size its tag gives, inches in the style aside")
        // The link is a link, not an address in brackets.
        let report = (text.string as NSString).range(of: "report.")
        XCTAssertEqual((text.attribute(.link, at: report.location, effectiveRange: nil) as? URL)?.absoluteString
                       ?? text.attribute(.link, at: report.location, effectiveRange: nil) as? String, "https://example.com/report")
        // The heading's labels are bold, and near-black text reads in dark as the composer's own.
        let from = (text.string as NSString).range(of: "From:")
        let heading = try XCTUnwrap(text.attribute(.font, at: from.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: heading).contains(.boldFontMask))
        let date = try XCTUnwrap(text.attribute(.font, at: (text.string as NSString).range(of: "Date:").location,
                                                effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: date).contains(.boldFontMask))
        let samAt = (text.string as NSString).range(of: "Sam\n").location
        XCTAssertEqual(text.attribute(.foregroundColor, at: samAt, effectiveRange: nil) as? NSColor, .labelColor)
        // Text the original leaves unstyled is set as the composer sets its own.
        let unstyled = try XCTUnwrap(text.attribute(.font, at: report.location, effectiveRange: nil) as? NSFont)
        XCTAssertFalse(unstyled.familyName?.contains("Times") ?? true, unstyled.fontName)
    }

    func testALogoShownSmallerThanItsPixelsKeepsThatSizeThroughTheDraft() throws {
        // Outlook shows a logo made for Retina at half its pixels, by the size its tag gives.
        let logo = try png(240, 72)
        let picture = try XCTUnwrap(attachments(in: try reply(to: outlookOriginal(logo: logo)).rich).first)
        XCTAssertEqual(shown(picture), NSSize(width: 120, height: 36))
        let pixels = try XCTUnwrap(picture.fileWrapper?.regularFileContents.flatMap(NSBitmapImageRep.init(data:)))
        XCTAssertEqual([pixels.pixelsWide, pixels.pixelsHigh], [240, 72], "not a pixel lost")
        // A JPEG as well.
        let rep = try XCTUnwrap(NSBitmapImageRep(data: logo))
        let jpeg = try XCTUnwrap(rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]))
        let declared = try XCTUnwrap(InlinePictures.declaring(NSSize(width: 120, height: 36), in: jpeg))
        XCTAssertEqual(NSImage(data: declared)?.size, NSSize(width: 120, height: 36))
    }

    func testTheBodyStillEndsWithTheQuoteSoAnUntouchedOriginalGoesAsItsOwnHTML() throws {
        let logo = try png()
        let opened = try reply(to: outlookOriginal(logo: logo))
        XCTAssertNotNil(ComposedBody.historyStart(in: opened.rich.string, history: opened.historyPlain), "kept and read back")
        XCTAssertNotNil(ComposedBody.historyStart(in: opened.plain, history: opened.historyPlain))
        let typed = NSMutableAttributedString(attributedString: opened.rich)
        typed.insert(NSAttributedString(string: "Thanks.", attributes: body), at: 0)
        let message = sent(typed, historyPlain: opened.historyPlain, historyHTML: opened.historyHTML)
        let html = try XCTUnwrap(message.textHTML)
        XCTAssertTrue(html.contains("Thanks."))
        XCTAssertTrue(html.contains("border-top:solid #B5C4DF 1.0pt"), "Outlook's heading")
        XCTAssertTrue(html.contains("<p class=MsoNormal>The figures are in the <a href=\"https://example.com/report\">report</a>.</p>"),
                      "the original's own HTML")
        XCTAssertEqual(Array(inlineParts(of: message).values), [logo], "the logo goes once, as an inline part")
        XCTAssertFalse(html.contains("data:image"))
        // An earlier build reads the RTF alone, without the picture, and still finds the quote.
        let rtfOnly = try XCTUnwrap(ComposedBody.text(rtf: opened.stored.rtf, rtfd: nil))
        XCTAssertNotNil(ComposedBody.historyStart(in: rtfOnly.string, history: opened.historyPlain))
    }

    func testAGmailOriginalsLogoFromTheWebIsAnEmptyBoxOfItsSize() throws {
        let opened = try reply(to: gmailOriginal())
        let text = opened.rich
        assertNoStandIns(text.string)
        XCTAssertTrue(text.string.contains("Booked for Friday."))
        let pictures = attachments(in: text)
        XCTAssertEqual(pictures.count, 1, "the tracking pixel is left out")
        let box = try XCTUnwrap(pictures.first)
        XCTAssertEqual(RemotePictures.placeholder(of: box),
                       RemotePictures.Placeholder(address: remoteLogo, width: 96, height: 30), "kept through the draft's RTFD")
        XCTAssertEqual(shown(box), NSSize(width: 96, height: 30))
        let at = InlinePictures.attachmentLocations(in: text)[0].0
        XCTAssertNotNil(text.attribute(.link, at: at, effectiveRange: nil), "the link on the logo stays")
        XCTAssertEqual(RemotePictures.addresses(in: text), [remoteLogo])
    }

    func testAGmailOriginalsLogoIsThePictureOnceFetched() throws {
        let logo = try png(192, 60, colour: .systemOrange)
        // Fetched before the quote is made...
        let fetched = try reply(to: gmailOriginal(), remote: [remoteLogo: logo])
        let picture = try XCTUnwrap(attachments(in: fetched.rich).first)
        XCTAssertEqual(shown(picture), NSSize(width: 96, height: 30), "shown at the size the message gives it, through the draft")
        let pixels = try XCTUnwrap(picture.fileWrapper?.regularFileContents.flatMap(NSBitmapImageRep.init(data:)))
        XCTAssertEqual([pixels.pixelsWide, pixels.pixelsHigh], [192, 60], "not a pixel lost")
        // ...or, as the compose window does, put into its box once fetched: the text keeps its
        // length and the original is still untouched.
        let opened = try reply(to: gmailOriginal())
        let filled = NSMutableAttributedString(attributedString: opened.rich)
        XCTAssertTrue(RemotePictures.fill(filled, with: [remoteLogo: logo]))
        XCTAssertEqual(filled.string, opened.rich.string)
        XCTAssertEqual(attachments(in: filled).count, 1)
        XCTAssertEqual(shown(attachments(in: filled).first), NSSize(width: 96, height: 30))
        XCTAssertNotNil(filled.attribute(.link, at: InlinePictures.attachmentLocations(in: filled)[0].0, effectiveRange: nil))
        XCTAssertNotNil(ComposedBody.historyStart(in: filled.string, history: opened.historyPlain))
        XCTAssertFalse(RemotePictures.fill(filled, with: [remoteLogo: logo]), "nothing left to fill")
    }

    func testAnOriginalWithoutHTMLIsQuotedAsItsText() {
        XCTAssertNil(ComposedBody.quote(heading: "\nFrom: Sam <sam@example.com>\n\n", html: "  \n", parts: [], attributes: body))
    }

    // MARK: - editing inside the quote

    func testEditingInsideTheQuoteKeepsTheOriginalsPictures() throws {
        let logo = try png()
        let opened = try reply(to: outlookOriginal(logo: logo))
        let edited = NSMutableAttributedString(attributedString: opened.rich)
        let inside = (edited.string as NSString).range(of: "The figures").location
        edited.insert(NSAttributedString(string: "EDITED ", attributes: body), at: inside)
        XCTAssertNil(ComposedBody.historyStart(in: edited.string, history: opened.historyPlain))
        let message = sent(edited, historyPlain: opened.historyPlain, historyHTML: opened.historyHTML)
        let html = try XCTUnwrap(message.textHTML)
        XCTAssertTrue(html.contains("EDITED"))
        XCTAssertFalse(html.contains("#B5C4DF"), "the body as it now reads, not the original's HTML")
        let parts = inlineParts(of: message)
        XCTAssertEqual(Array(parts.values), [logo])
        let id = try XCTUnwrap(parts.keys.first)
        XCTAssertTrue(id.hasPrefix("image001.png@"))
        XCTAssertTrue(html.contains("<img width=\"120\" height=\"36\" style=\"width:120px;height:36px\" src=\"cid:\(id)\">"), html)
        XCTAssertTrue(message.textPlain?.contains("[cid:\(id)]") ?? false, message.textPlain ?? "")
        XCTAssertFalse(html.contains("data:image"))
    }

    /// A reply saved to the server's Drafts and opened again, as ComposeDraft.from opens it,
    /// still shows the original's picture from the web as its box, which goes out from its
    /// address as before; a picture of the writer's own keeps the size it was sent at.
    @MainActor
    func testADraftReopenedFromTheServerKeepsTheQuotesPictureFromTheWeb() throws {
        let wide = try png(1600, 100, colour: .systemTeal)
        let opened = try reply(to: gmailOriginal())
        let text = NSMutableAttributedString(attributedString: opened.rich)
        text.insert(NSAttributedString(attachment: try XCTUnwrap(InlinePictures.attachment(for: wide, named: "wide.png"))), at: 0)
        let saved = sent(text, historyPlain: opened.historyPlain, historyHTML: opened.historyHTML)
        let escaped = remoteLogo.replacingOccurrences(of: "&", with: "&amp;")
        XCTAssertTrue(saved.textHTML?.contains(escaped) ?? false)

        let reopened = try XCTUnwrap(InlinePictures.text(fromHTML: try XCTUnwrap(saved.textHTML), parts: saved.attachments,
                                                         attributes: body, remote: [:], fitting: false))
        XCTAssertEqual(RemotePictures.addresses(in: reopened), [remoteLogo], "the logo from the web is still a box")
        assertNoStandIns(reopened.string)
        let pictures = attachments(in: reopened)
        XCTAssertEqual(pictures.count, 2, "the tracking pixel stays out")
        XCTAssertEqual(shown(pictures.first), NSSize(width: 1600, height: 100), "the writer's own picture is not scaled down")

        let again = sent(reopened, historyPlain: "", historyHTML: "")
        let html = try XCTUnwrap(again.textHTML)
        XCTAssertTrue(html.contains("<img width=\"96\" height=\"30\" style=\"width:96px;height:30px\" src=\"\(escaped)\">"), html)
        XCTAssertTrue(html.contains("width=\"1600\" height=\"100\""), html)
        XCTAssertEqual(Array(inlineParts(of: again).values), [wide], "the box itself is never sent")
    }

    func testEditingInsideAQuoteWithAPictureFromTheWebSendsItFromItsAddress() throws {
        let opened = try reply(to: gmailOriginal())
        let edited = NSMutableAttributedString(attributedString: opened.rich)
        edited.insert(NSAttributedString(string: "EDITED ", attributes: body), at: (edited.string as NSString).range(of: "Booked").location)
        let message = sent(edited, historyPlain: opened.historyPlain, historyHTML: opened.historyHTML)
        let html = try XCTUnwrap(message.textHTML)
        XCTAssertTrue(html.contains("EDITED"))
        let escaped = remoteLogo.replacingOccurrences(of: "&", with: "&amp;")
        XCTAssertTrue(html.contains("<img width=\"96\" height=\"30\" style=\"width:96px;height:30px\" src=\"\(escaped)\">"), html)
        XCTAssertTrue(message.attachments.isEmpty, "the empty box is never sent")
        XCTAssertEqual(message.root.contentType.mimeType, "multipart/alternative")
        XCTAssertFalse(message.textPlain?.contains("\u{FFFC}") ?? true)

        // Fetched, it goes as an inline part like any other picture.
        let logo = try png(192, 60, colour: .systemOrange)
        RemotePictures.fill(edited, with: [remoteLogo: logo])
        let withLogo = sent(edited, historyPlain: opened.historyPlain, historyHTML: opened.historyHTML)
        let part = try XCTUnwrap(inlineParts(of: withLogo).values.first)
        XCTAssertEqual(inlineParts(of: withLogo).count, 1)
        XCTAssertEqual(NSBitmapImageRep(data: part)?.pixelsWide, 192, "every pixel fetched")
        XCTAssertTrue(withLogo.textHTML?.contains("<img width=\"96\" height=\"30\"") ?? false, withLogo.textHTML ?? "")
        XCTAssertFalse(withLogo.textHTML?.contains("example.invalid") ?? true)
    }

    // MARK: - fetching nothing while reading

    func testReadingTheOriginalFetchesNothingFromTheWeb() {
        let html = """
        <html><head><link rel="stylesheet" href="https://example.invalid/a.css"><style>@import url("https://example.invalid/b.css"); \
        .x{background:url(https://example.invalid/c.png)}</style><script>alert(1)</script></head>\
        <body background="https://example.invalid/d.png"><table background='https://example.invalid/e.png'><tr><td style="background-image:url('//example.invalid/f.png')">Cell</td></tr></table>\
        <iframe src="https://example.invalid/g"></iframe><video poster="https://example.invalid/h.png"><source src="https://example.invalid/i.mp4"></video>\
        <p>Words stay</p><a href="https://example.com/">links stay</a></body></html>
        """
        let cleaned = InlinePictures.withoutFetching(html)
        XCTAssertFalse(cleaned.contains("example.invalid"), cleaned)
        XCTAssertFalse(cleaned.contains("alert"))
        XCTAssertTrue(cleaned.contains("<p>Words stay</p>"))
        XCTAssertTrue(cleaned.contains("href=\"https://example.com/\""))
        let read = InlinePictures.text(fromHTML: html, parts: [], attributes: body, remote: [:])
        XCTAssertTrue(read?.string.contains("Words stay") ?? false)
        XCTAssertTrue(read?.string.contains("Cell") ?? false)
    }

    // MARK: - boxes and the loader

    func testABoxRemembersItsPictureThroughADraftAndCopyAndPaste() throws {
        let box = RemotePictures.placeholder(for: "https://example.invalid/a.png", width: 200, height: nil)
        XCTAssertEqual(shown(box), NSSize(width: 200, height: 200))
        let text = NSMutableAttributedString(string: "Logo ", attributes: body)
        text.append(NSAttributedString(attachment: box))
        let kept = ComposedBody.stored(text)
        XCTAssertNotNil(kept.rtfd)
        let read = try XCTUnwrap(ComposedBody.text(rtf: kept.rtf, rtfd: kept.rtfd))
        let mark = try XCTUnwrap(attachments(in: read).first.flatMap(RemotePictures.placeholder(of:)))
        XCTAssertEqual(mark, RemotePictures.Placeholder(address: "https://example.invalid/a.png", width: 200, height: nil))
        // Pasted within the composer, it is kept as it is.
        XCTAssertNotNil(attachments(in: InlinePictures.normalised(read)).first.flatMap(RemotePictures.placeholder(of:)))
        // A picture wider than the composer shows is scaled down, as is its box.
        XCTAssertEqual(RemotePictures.placeholder(for: "https://example.invalid/b.png", width: 1280, height: 400).bounds.size,
                       NSSize(width: 640, height: 200))
        // One side given keeps the fetched picture's proportions.
        let wide = try png(400, 100)
        let fitted = NSMutableAttributedString(attributedString: read)
        RemotePictures.fill(fitted, with: ["https://example.invalid/a.png": wide])
        XCTAssertEqual(shown(attachments(in: fitted).first), NSSize(width: 200, height: 50))
    }

    func testAddressesAreReadAsABrowserReadsThem() {
        XCTAssertEqual(RemotePictures.address(fromSource: "https://a.example/x.png?a=1&amp;b=2"), "https://a.example/x.png?a=1&b=2")
        XCTAssertEqual(RemotePictures.address(fromSource: "//a.example/x.png"), "https://a.example/x.png")
        XCTAssertNil(RemotePictures.address(fromSource: "cid:x@y"))
        XCTAssertNil(RemotePictures.address(fromSource: "file:///etc/hosts"))
        XCTAssertNil(RemotePictures.address(fromSource: "data:image/png;base64,AA=="))
        XCTAssertEqual(RemotePictures.addresses(inHTML: "<img src='https://a.example/1.png'><img src=\"https://a.example/1.png\">"
                                                + "<img width=1 height=1 src=\"https://t.example/p.gif\"><img style=\"display:none\" src=\"https://a.example/2.png\">"),
                       ["https://a.example/1.png"])
    }

    func testTheLoaderFetchesEachPictureOnceAndKeepsOnlyPictures() async throws {
        let logo = try png()
        let asked = Asked()
        let loader = RemotePictureLoader { url in
            await asked.add(url.absoluteString)
            switch url.lastPathComponent {
            case "logo.png": return logo
            case "page.html": return Data("<html>not a picture</html>".utf8)
            case "huge.png": return logo + Data(count: RemotePictureLoader.largest)
            default: throw URLError(.notConnectedToInternet)
            }
        }
        let fetched = await loader.fetch(["https://a.example/logo.png", "https://a.example/logo.png", "https://a.example/page.html",
                                          "https://a.example/huge.png", "https://a.example/gone.png", "file:///etc/hosts",
                                          "ftp://a.example/logo.png"])
        XCTAssertEqual(fetched, ["https://a.example/logo.png": logo])
        let requests = await asked.all
        XCTAssertEqual(requests.filter { $0 == "https://a.example/logo.png" }.count, 1)
        XCTAssertFalse(requests.contains { !$0.hasPrefix("https://") }, "only the web is asked")
    }

    private actor Asked {
        var all: [String] = []
        func add(_ address: String) { all.append(address) }
    }

    func testAPictureIsPutIntoATextViewWithoutMovingTheCaret() throws {
        let logo = try png()
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let text = NSMutableAttributedString(string: "Typed so far\n", attributes: body)
        text.append(NSAttributedString(attachment: RemotePictures.placeholder(for: "https://a.example/logo.png", width: 120, height: 36)))
        text.append(NSAttributedString(string: "\nMore", attributes: body))
        view.textStorage?.setAttributedString(text)
        view.setSelectedRange(NSRange(location: 5, length: 3))
        let changes = Changes()
        view.delegate = changes
        XCTAssertTrue(RemotePictures.fill(view, with: ["https://a.example/logo.png": logo]))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 5, length: 3))
        XCTAssertEqual(view.string, text.string)
        XCTAssertEqual(changes.count, 1, "reported as the view's own change, which the draft keeps")
        XCTAssertEqual(attachments(in: try XCTUnwrap(view.textStorage)).first?.fileWrapper?.regularFileContents, logo)
    }

    private final class Changes: NSObject, NSTextViewDelegate {
        var count = 0
        func textDidChange(_ notification: Notification) { count += 1 }
    }

    // MARK: - signatures

    func testASignatureCarriedOverAsHTMLBecomesTheSignatureItDescribesOnce() throws {
        let inline = try png(64, 20, colour: .systemRed)
        let remote = try png(96, 30, colour: .systemBlue)
        let html = """
        <div><b>Kamal Muradov</b><br><span style="color:#1f1f1f">Freight Masters</span><br>\
        <img src="data:image/png;base64,\(inline.base64EncodedString())" width="64" height="20">\
        <a href="https://example.com/"><img src="https://example.invalid/logo.png" width="96" height="30"></a></div>
        """
        let account = AccountInfo(email: "kamal@example.com", displayName: "Kamal", signature: html)
        var book = SignatureBook()
        book.adopt([account])
        let candidates = book.carriedOverHTML
        XCTAssertEqual(candidates.map(\.html), [html])
        let id = try XCTUnwrap(candidates.first?.id)
        XCTAssertEqual(RemotePictures.addresses(inHTML: html), ["https://example.invalid/logo.png"])

        // As SignatureLibrary does: the picture from the web fetched once, then read.
        let text = try XCTUnwrap(Signature.text(fromHTML: html, pictures: ["https://example.invalid/logo.png": remote], attributes: body))
        XCTAssertTrue(book.replaceCarriedOverHTML(id, source: html, with: text, plainIn: body))
        let signature = try XCTUnwrap(book.signature(id))
        XCTAssertNotNil(signature.rich)
        XCTAssertEqual(signature.plain, "Kamal Muradov\nFreight Masters\n")
        XCTAssertFalse(signature.text.string.contains("<"), "no HTML source is left")
        XCTAssertEqual(attachments(in: signature.text).map { $0.fileWrapper?.regularFileContents }, [inline, remote])
        XCTAssertTrue(book.carriedOverHTML.isEmpty, "done once")
        XCTAssertFalse(book.replaceCarriedOverHTML(id, source: html, with: text, plainIn: body))
        XCTAssertFalse(book.adopt([account]), "the account's own signature is not carried over again")

        // What it sends: both pictures inline, the name bold.
        let opened = ComposedBody.opening(lead: "\n\n", signature: signature, tail: "", attributes: body)
        let message = sent(try XCTUnwrap(opened.rich), historyPlain: "", historyHTML: "")
        XCTAssertEqual(Set(inlineParts(of: message).values), [inline, remote])
        XCTAssertFalse(message.textHTML?.contains("&lt;div") ?? true)

        // signatures.json still reads as every build reads it.
        let decoded = try JSONDecoder().decode(SignatureBook.self, from: try JSONEncoder().encode(book))
        XCTAssertEqual(decoded, book)
    }

    func testAPictureThatCannotBeFetchedStaysABoxSentFromItsAddress() throws {
        let html = "<div>Alex<br><img src=\"https://example.invalid/logo.png\" width=\"96\" height=\"30\"></div>"
        let text = try XCTUnwrap(Signature.text(fromHTML: html, pictures: [:], attributes: body))
        var signature = Signature(name: "Alex")
        signature.setText(text, plainIn: body)
        let opened = ComposedBody.opening(lead: "\n\n", signature: signature, tail: "", attributes: body)
        let html2 = try XCTUnwrap(sent(try XCTUnwrap(opened.rich), historyPlain: "", historyHTML: "").textHTML)
        XCTAssertTrue(html2.contains("src=\"https://example.invalid/logo.png\""), html2)
    }

    func testPlainAndChangedSignaturesAreLeftAlone() {
        let plain = AccountInfo(email: "a@example.com", displayName: "A", signature: "Best,\nAlex <alex@example.com>")
        let html = AccountInfo(email: "b@example.com", displayName: "B", signature: "<div>Bea<br>Example</div>")
        var book = SignatureBook()
        book.adopt([plain, html])
        XCTAssertFalse(Signature.looksLikeHTML(plain.signature), "an address in angle brackets is not HTML")
        XCTAssertEqual(book.carriedOverHTML.map(\.html), [html.signature], "a plain signature stays as it is")
        // The owner changes the one carried over as HTML: it is theirs now.
        let id = book.signature(for: html.id, .newMessages)!.id
        book.setText(NSAttributedString(string: "<div>Bea, Example</div>"), of: id)
        XCTAssertFalse(book.carriedOverHTML.contains { $0.id == id })
        XCTAssertFalse(book.replaceCarriedOverHTML(id, source: html.signature, with: NSAttributedString(string: "Bea"), plainIn: body))
        // A signature the owner wrote is never carried over.
        let own = book.add(startingWith: "<div>Mine</div>")
        XCTAssertFalse(book.carriedOverHTML.contains { $0.id == own.id })
    }

    // MARK: - the signature editor's Paste

    func testASignaturePastedFromAWebPageKeepsItsPictureFromTheWeb() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("FalconMailTests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        let html = "<meta charset=\"utf-8\"><div><b>Jordan Lee</b></div><div><img src=\"https://example.invalid/sig.png\" width=\"96\" height=\"30\"></div>"
        board.setString(html, forType: .html)
        board.setString("Jordan Lee", forType: .string)
        // Elsewhere, as before, the picture is left out.
        let composer = try XCTUnwrap(InlinePictures.pasted(from: board))
        XCTAssertTrue(attachments(in: composer).isEmpty)
        // The signature editor keeps a box, fetches the picture and puts it in.
        let pasted = try XCTUnwrap(InlinePictures.pasted(from: board, keepingRemotePictures: true))
        XCTAssertEqual(RemotePictures.addresses(in: pasted), ["https://example.invalid/sig.png"])
        assertNoStandIns(pasted.string)
        let logo = try png(96, 30)
        let filled = NSMutableAttributedString(attributedString: pasted)
        XCTAssertTrue(RemotePictures.fill(filled, with: ["https://example.invalid/sig.png": logo]))
        XCTAssertEqual(attachments(in: filled).map { $0.fileWrapper?.regularFileContents }, [logo])
        var signature = Signature(name: "Jordan")
        signature.setText(filled, plainIn: body)
        XCTAssertEqual(attachments(in: signature.text).map { $0.fileWrapper?.regularFileContents }, [logo])
    }
}
