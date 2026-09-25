import XCTest
import AppKit
@testable import FalconCore

/// Pictures in a message, from the composer to the wire and back: signature logos, pictures
/// inserted or pasted, and the pictures of an original a reply or forward keeps all go out as
/// Outlook sends them, and come back into a draft that is opened again.
final class InlinePictureTests: XCTestCase {
    private let font = NSFont.systemFont(ofSize: 14)
    private var body: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: NSColor.labelColor] }
    private let me = EmailAddress(name: "Alex Example", address: "alex@example.com")
    private let sam = EmailAddress(name: "Sam", address: "sam@example.com")

    // MARK: - stand-in pictures

    /// A bitmap `width` × `height` pixels, drawn at `scale` pixels a point, as a Retina
    /// screenshot or a logo made for one is.
    private func bitmap(_ width: Int, _ height: Int, colour: NSColor, scale: CGFloat = 1) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        colour.setFill()
        NSRect(x: 0, y: 0, width: rep.size.width, height: rep.size.height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func png(_ width: Int = 192, _ height: Int = 56, colour: NSColor = .systemTeal, scale: CGFloat = 1) throws -> Data {
        try XCTUnwrap(bitmap(width, height, colour: colour, scale: scale).representation(using: .png, properties: [:]))
    }

    private func jpeg(_ width: Int = 120, _ height: Int = 40) throws -> Data {
        try XCTUnwrap(bitmap(width, height, colour: .systemOrange).representation(using: .jpeg, properties: [.compressionFactor: 0.8]))
    }

    /// A picture as the signature editor's Picture button and the composer's Pictures button put
    /// one in.
    private func picture(_ data: Data, named name: String) throws -> NSAttributedString {
        NSAttributedString(attachment: try XCTUnwrap(InlinePictures.attachment(for: data, named: name)))
    }

    private func signature(with logo: Data, named name: String) throws -> Signature {
        let text = NSMutableAttributedString(string: "Alex Example\nOperations\n", attributes: body)
        text.append(try picture(logo, named: name))
        var signature = Signature(name: "Formal")
        signature.setText(text)
        return signature
    }

    // MARK: - the app's path

    /// The body as the draft keeps it, then what Send and saving to Drafts build from it
    /// (ComposeDraft.outgoing, MIMEBuilder).
    private func sent(_ rich: NSAttributedString?, plain: String? = nil, historyPlain: String = "", historyHTML: String = "",
                      attachments: [OutgoingAttachment] = [], date: Date = Date()) -> Data {
        let stored = rich.map(ComposedBody.stored)
        let content = ComposedHTML.content(rtf: stored?.rtf, rtfd: stored?.rtfd, plain: plain ?? rich?.string ?? "",
                                           historyPlain: historyPlain, historyHTML: historyHTML, date: date)
        let message = OutgoingMessage(from: me, to: [sam], subject: "Pictures", textBody: content.plain, htmlBody: content.html,
                                      attachments: attachments + content.pictures.map(\.attachment), date: date)
        return MIMEBuilder.build(message)
    }

    /// The HTML ComposeDraft.history keeps for the original a reply or forward quotes.
    private func historyHTML(of parsed: MIMEMessage) -> String {
        var inner = InlinePictures.resolvingCIDs(in: parsed.textHTML ?? "", with: parsed.attachments)
        inner = inner.replacingOccurrences(of: "(?is)<(/?)(html|head|body)[^>]*>", with: "", options: .regularExpression)
        return "<hr><div>\(inner)</div>"
    }

    private func original(with logo: Data) -> Data {
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
        The figures [cid:image001.png@01DB0F8A.5C6D7E80]\r
        --alt\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <html><body><p>The figures</p><img width="64" height="64" src="cid:image001.png@01DB0F8A.5C6D7E80"></body></html>\r
        --alt--\r
        --rel\r
        Content-Type: image/png; name="image001.png"\r
        Content-Disposition: inline; filename="image001.png"\r
        Content-ID: <image001.png@01DB0F8A.5C6D7E80>\r
        Content-Transfer-Encoding: base64\r
        \r
        \(logo.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]))\r
        --rel--\r
        """
        return Data(raw.utf8)
    }

    // MARK: - reading what went out

    /// Every `cid:` the HTML shows a picture by, in order.
    private func cids(in html: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "src=\"cid:([^\"]+)\"")
        return pattern.matches(in: html, range: NSRange(html.startIndex..., in: html)).map {
            String(html[Range($0.range(at: 1), in: html)!])
        }
    }

    private func leaves(of part: MIMEPart) -> [MIMEPart] {
        part.children.isEmpty ? [part] : part.children.flatMap(leaves)
    }

    private func attachments(in text: NSAttributedString) -> [NSTextAttachment] {
        InlinePictures.attachmentLocations(in: text).map(\.1)
    }

    /// The HTML shows each picture by `cid:`, a part inside multipart/related carries it inline
    /// under that Content-ID with exactly its bytes, named as Outlook names it, and the plain
    /// text holds none of its bytes; where each of the first `marked` pictures, those in the
    /// writer's own text, stood, it says `[cid:…]`. An original's plain text is quoted as it
    /// came.
    @discardableResult
    private func assertSentInline(_ raw: Data, pictures: [Data], marked: Int? = nil,
                                  file: StaticString = #filePath, line: UInt = #line) throws -> MIMEMessage {
        let parsed = MIMEParser.parse(raw)
        let html = try XCTUnwrap(parsed.textHTML, file: file, line: line)
        XCTAssertFalse(html.contains("data:image"), "a picture went out as a data: URI", file: file, line: line)
        let referenced = Array(NSOrderedSet(array: cids(in: html))) as! [String]
        XCTAssertEqual(referenced.count, pictures.count, "cid references in the HTML: \(referenced)", file: file, line: line)
        let related = parsed.root.contentType.subtype == "related" ? parsed.root
            : parsed.root.children.first { $0.contentType.subtype == "related" }
        XCTAssertNotNil(related, "no multipart/related; the message is \(parsed.root.contentType.mimeType)", file: file, line: line)
        XCTAssertEqual(related?.contentType.params["type"], "multipart/alternative", file: file, line: line)
        XCTAssertEqual(related?.children.first?.contentType.mimeType, "multipart/alternative", file: file, line: line)
        let parts = (related?.children.dropFirst() ?? []).filter { $0.contentID != nil }
        XCTAssertEqual(parts.count, pictures.count, file: file, line: line)
        for (index, (cid, data)) in zip(referenced, pictures).enumerated() {
            let part = parts.first { $0.contentID == cid }
            XCTAssertNotNil(part, "no part with Content-ID <\(cid)>", file: file, line: line)
            XCTAssertEqual(part?.decodedData, data, file: file, line: line)
            XCTAssertEqual(part?.disposition, "inline", file: file, line: line)
            let format = try XCTUnwrap(InlinePictures.format(of: data), file: file, line: line)
            let name = String(format: "image%03d.%@", index + 1, format.fileExtension)
            XCTAssertEqual(part?.filename, name, file: file, line: line)
            XCTAssertEqual(part?.contentType.mimeType, format.mimeType, file: file, line: line)
            XCTAssertTrue(cid.hasPrefix(name + "@"), cid, file: file, line: line)
            if index < marked ?? pictures.count {
                XCTAssertTrue(parsed.textPlain?.contains("[cid:\(cid)]") ?? false, parsed.textPlain ?? "", file: file, line: line)
            }
        }
        let plain = parsed.textPlain ?? ""
        XCTAssertFalse(plain.contains("\u{FFFC}"), "the plain text carries object characters", file: file, line: line)
        for data in pictures {
            XCTAssertFalse(plain.contains(data.base64EncodedString().prefix(40)), "the plain text carries a picture", file: file, line: line)
        }
        return parsed
    }

    // MARK: - sending

    func testASignatureLogoIsSentInlineAtTheSizeItIsShown() throws {
        // A PNG logo made for Retina, 192 × 56 pixels shown at 96 × 28 points, and a JPEG.
        for (logo, name, size) in [(try png(scale: 2), "logo.png", "96\" height=\"28\""), (try jpeg(), "logo.jpeg", "120\" height=\"40\"")] {
            let opened = ComposedBody.opening(lead: "\n\n", signature: try signature(with: logo, named: name), tail: "", attributes: body)
            let rich = try XCTUnwrap(opened.rich)
            let parsed = try assertSentInline(sent(rich, plain: opened.plain), pictures: [logo])
            XCTAssertEqual(parsed.root.contentType.mimeType, "multipart/related", "with nothing attached, no multipart/mixed")
            XCTAssertTrue(parsed.textHTML?.contains("<img width=\"\(size)") ?? false, parsed.textHTML ?? "")
            XCTAssertTrue(parsed.textHTML?.contains("Alex Example") ?? false)
        }
    }

    func testAPictureInsertedWithThePicturesButtonIsSentAsItIs() throws {
        let photo = try jpeg(800, 600)
        let text = NSMutableAttributedString(string: "The site today:\n", attributes: body)
        text.append(try picture(photo, named: "IMG_0042.jpeg"))
        text.append(NSAttributedString(string: "\nThanks\n", attributes: body))
        let parsed = try assertSentInline(sent(text), pictures: [photo])
        XCTAssertEqual(parsed.textPlain, "The site today:\n[cid:\(cids(in: parsed.textHTML ?? "")[0])]\nThanks\n")
    }

    @MainActor
    func testAScreenshotPastedFromTheClipboardIsSentAsAPNG() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("FalconMailTests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        // A screenshot is copied as TIFF, which Gmail and Outlook do not show in a message.
        let shot = try bitmap(300, 200, colour: .systemPurple, scale: 2)
        board.clearContents()
        board.setData(try XCTUnwrap(shot.tiffRepresentation), forType: .tiff)
        let pasted = try XCTUnwrap(InlinePictures.pasted(from: board))
        let attachment = try XCTUnwrap(attachments(in: pasted).first)
        let data = try XCTUnwrap(attachment.fileWrapper?.regularFileContents)
        XCTAssertEqual(InlinePictures.format(of: data), .png)
        XCTAssertEqual(attachment.fileWrapper?.preferredFilename, "image.png")
        let converted = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual([converted.pixelsWide, converted.pixelsHigh], [300, 200], "no pixel lost")
        XCTAssertEqual(converted.size, NSSize(width: 150, height: 100), "shown at the size it was")

        let text = NSMutableAttributedString(string: "Here is the screen:\n", attributes: body)
        text.append(pasted)
        let parsed = try assertSentInline(sent(text), pictures: [data])
        XCTAssertTrue(parsed.textHTML?.contains("<img width=\"150\" height=\"100\"") ?? false, parsed.textHTML ?? "")
    }

    @MainActor
    func testRichTextPastedWithAPictureKeepsThePicture() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("FalconMailTests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let logo = try png()
        let copied = NSMutableAttributedString(string: "Copied ", attributes: body)
        let file = FileWrapper(regularFileWithContents: logo)
        file.preferredFilename = "Pasted Graphic.png"
        copied.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: file)))
        board.clearContents()
        board.setData(copied.rtfd(from: NSRange(location: 0, length: copied.length), documentAttributes: [:]), forType: .rtfd)
        let pasted = try XCTUnwrap(InlinePictures.pasted(from: board))
        XCTAssertEqual(pasted.string, "Copied \u{FFFC}")
        XCTAssertEqual(attachments(in: pasted).first?.fileWrapper?.regularFileContents, logo)
        try assertSentInline(sent(pasted), pictures: [logo])
    }

    func testTheSamePictureShownTwiceIsSentOnce() throws {
        let logo = try png()
        let opened = ComposedBody.opening(lead: "Logo: ", signature: try signature(with: logo, named: "logo.png"), tail: "", attributes: body)
        let text = NSMutableAttributedString(attributedString: try XCTUnwrap(opened.rich))
        text.insert(try picture(logo, named: "again.png"), at: 6)
        let parsed = try assertSentInline(sent(text), pictures: [logo])
        let html = try XCTUnwrap(parsed.textHTML)
        XCTAssertEqual(cids(in: html).count, 2, "both places show it")
        XCTAssertEqual(Set(cids(in: html)).count, 1)
    }

    func testPicturesAreSentAsTheyAreHoweverLarge() throws {
        // About 5 MB: kept exactly, never scaled or compressed again.
        let large = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1_500, pixelsHigh: 1_000, bitsPerSample: 8,
                                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        // Noise, which PNG cannot make any smaller.
        var state: UInt64 = 42
        if let pixels = large.bitmapData {
            for i in 0..<(large.bytesPerRow * large.pixelsHigh) {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                pixels[i] = UInt8(truncatingIfNeeded: state >> 56)
            }
        }
        let data = try XCTUnwrap(large.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 4_000_000)
        XCTAssertEqual(InlinePictures.sendable(data)?.data, data)
        let text = NSMutableAttributedString(string: "Plan:\n", attributes: body)
        text.append(try picture(data, named: "plan.png"))
        try assertSentInline(sent(text), pictures: [data])
    }

    func testAForwardKeepsTheOriginalsPicturesAsCIDParts() throws {
        let theirs = try png(64, 64, colour: .systemRed)
        let parsed = MIMEParser.parse(original(with: theirs))
        let historyPlain = "\n________________________________\nThe figures\n"
        let own = NSMutableAttributedString(string: "See below\n", attributes: body)
        own.append(NSAttributedString(string: historyPlain, attributes: body))
        let sentMessage = try assertSentInline(sent(own, historyPlain: historyPlain, historyHTML: historyHTML(of: parsed)),
                                               pictures: [theirs], marked: 0)
        XCTAssertTrue(sentMessage.textHTML?.contains("<img width=\"64\" height=\"64\" src=\"cid:image001.png@") ?? false)
    }

    func testAReplyWithASignatureLogoSendsItsOwnPictureFirstThenTheOriginals() throws {
        let logo = try png(scale: 2)
        let theirs = try png(64, 64, colour: .systemRed)
        let parsed = MIMEParser.parse(original(with: theirs))
        let historyPlain = "\n________________________________\nThe figures\n"
        let opened = ComposedBody.opening(lead: "Yes.\n\n", signature: try signature(with: logo, named: "logo.png"), tail: historyPlain,
                                          attributes: body)
        let rich = try XCTUnwrap(opened.rich)
        try assertSentInline(sent(rich, plain: opened.plain, historyPlain: historyPlain, historyHTML: historyHTML(of: parsed)),
                             pictures: [logo, theirs], marked: 1)
    }

    func testFilesAttachedGoBesideThePicturesInMultipartMixed() throws {
        let logo = try png()
        let text = NSMutableAttributedString(string: "Report attached.\n", attributes: body)
        text.append(try picture(logo, named: "logo.png"))
        let pdf = OutgoingAttachment(filename: "report.pdf", mimeType: "application/pdf", data: Data("%PDF-1.4".utf8))
        let parsed = try assertSentInline(sent(text, attachments: [pdf]), pictures: [logo])
        let root = parsed.root
        XCTAssertEqual(root.contentType.mimeType, "multipart/mixed")
        XCTAssertEqual(root.children.map(\.contentType.mimeType), ["multipart/related", "application/pdf"])
        XCTAssertEqual(root.children.first?.children.map(\.contentType.mimeType), ["multipart/alternative", "image/png"])
        XCTAssertEqual(root.children.first?.children.first?.children.map(\.contentType.mimeType), ["text/plain", "text/html"])
        XCTAssertEqual(root.children.last?.disposition, "attachment")
        XCTAssertEqual(parsed.attachments.filter { !$0.isInline }.map(\.filename), ["report.pdf"])
    }

    func testAMessageWithoutPicturesIsLaidOutAsBefore() throws {
        let text = NSAttributedString(string: "Just words\n", attributes: body)
        let parsed = MIMEParser.parse(sent(text))
        XCTAssertEqual(parsed.root.contentType.mimeType, "multipart/alternative")
        XCTAssertEqual(parsed.textPlain, "Just words\n")
        XCTAssertNil(ComposedBody.stored(text).rtfd, "a body without pictures is kept as an earlier build kept it")
    }

    func testAPhotoInHEICGoesAsAJPEGAndAGIFAsItIs() throws {
        let rep = try bitmap(64, 48, colour: .systemGreen)
        let gif = try XCTUnwrap(rep.representation(using: .gif, properties: [:]))
        XCTAssertEqual(InlinePictures.sendable(gif)?.data, gif)
        XCTAssertEqual(InlinePictures.sendable(gif)?.format, .gif)
        XCTAssertNil(InlinePictures.sendable(Data("not a picture".utf8)))

        let heic = NSMutableData()
        guard let cgImage = rep.cgImage,
              let destination = CGImageDestinationCreateWithData(heic, "public.heic" as CFString, 1, nil) else {
            throw XCTSkip("this Mac cannot write HEIC")
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("this Mac cannot write HEIC") }
        let sent = try XCTUnwrap(InlinePictures.sendable(heic as Data))
        XCTAssertEqual(sent.format, .jpeg)
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: sent.data))
        XCTAssertEqual([decoded.pixelsWide, decoded.pixelsHigh], [64, 48])
        XCTAssertEqual(InlinePictures.attachment(for: heic as Data, named: "IMG_0001.HEIC")?.fileWrapper?.preferredFilename, "IMG_0001.jpg")
    }

    func testTheContentIDCarriesTheTimeAsOutlookWritesIt() {
        let newYear = Date(timeIntervalSince1970: 1_704_067_200)
        XCTAssertEqual(InlinePictures.stamp(for: newYear), "01DA3C45.7689C000")
        var collector = InlinePictures.Collector(date: newYear)
        XCTAssertEqual(collector.add(Data([1]), .png).contentID, "image001.png@01DA3C45.7689C000")
        XCTAssertEqual(collector.add(Data([2]), .jpeg).contentID, "image002.jpg@01DA3C45.7689C000")
        XCTAssertEqual(collector.add(Data([1]), .png).filename, "image001.png")
    }

    // MARK: - drafts

    func testADraftKeepsItsPicturesAndAnEarlierBuildStillOpensItsText() throws {
        let logo = try png()
        let text = NSMutableAttributedString(string: "Draft\n", attributes: body)
        text.append(try picture(logo, named: "logo.png"))
        text.append(NSAttributedString(string: "\nMore", attributes: body))
        let stored = ComposedBody.stored(text)
        let reopened = try XCTUnwrap(ComposedBody.text(rtf: stored.rtf, rtfd: stored.rtfd))
        XCTAssertEqual(reopened.string, text.string)
        XCTAssertEqual(attachments(in: reopened).first?.fileWrapper?.regularFileContents, logo)
        // v1.10.0 reads bodyRTF alone, which still holds every word.
        let rtfOnly = try NSAttributedString(data: try XCTUnwrap(stored.rtf),
                                             options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        XCTAssertEqual(rtfOnly.string, "Draft\n\nMore")
        // A draft v1.10.0 kept, with RTF alone, opens as it did.
        XCTAssertEqual(ComposedBody.text(rtf: stored.rtf, rtfd: nil)?.string, "Draft\n\nMore")
    }

    @MainActor
    func testADraftReopenedFromTheServerShowsItsPicturesAgain() throws {
        let logo = try png(scale: 2)
        let photo = try jpeg()
        let opened = ComposedBody.opening(lead: "Hello\n\n", signature: try signature(with: logo, named: "logo.png"), tail: "",
                                          attributes: body)
        let text = NSMutableAttributedString(attributedString: try XCTUnwrap(opened.rich))
        text.insert(try picture(photo, named: "photo.jpeg"), at: 5)
        let parsed = MIMEParser.parse(sent(text))

        let reopened = try XCTUnwrap(InlinePictures.text(fromHTML: try XCTUnwrap(parsed.textHTML), parts: parsed.attachments,
                                                         attributes: body))
        let pictures = attachments(in: reopened)
        XCTAssertEqual(pictures.map { $0.fileWrapper?.regularFileContents }, [photo, logo])
        XCTAssertEqual(pictures.map { $0.fileWrapper?.preferredFilename }, ["image001.jpg", "image002.png"])
        XCTAssertTrue(reopened.string.contains("Alex Example"))
        XCTAssertTrue(reopened.string.hasPrefix("Hello\u{FFFC}"), reopened.string.debugDescription)
        let colour = reopened.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(colour, .labelColor, "text sent in the automatic colour opens in it, readable in dark")
        // And it goes out again as it came.
        try assertSentInline(sent(reopened), pictures: [photo, logo])
    }

    @MainActor
    func testADraftAnEarlierBuildSavedKeepsTheOriginalsPicturesWhenReopened() throws {
        // v1.10.0 sent and saved a quoted original's pictures as data: URIs.
        let theirs = try png(64, 64, colour: .systemRed)
        let html = "<html><body><p>Mine</p><hr><div><p>The figures</p><img src=\"data:image/png;base64,\(theirs.base64EncodedString())\"></div></body></html>"
        let reopened = try XCTUnwrap(InlinePictures.text(fromHTML: html, parts: [], attributes: body))
        XCTAssertEqual(attachments(in: reopened).map { $0.fileWrapper?.regularFileContents }, [theirs])
        try assertSentInline(sent(reopened), pictures: [theirs])
    }

    @MainActor
    func testAPictureTheDraftWouldFetchFromTheWebIsLeftOut() throws {
        let html = "<html><body><p>Hi</p><img src=\"https://example.invalid/track.png\"><p>Bye</p></body></html>"
        let reopened = try XCTUnwrap(InlinePictures.text(fromHTML: html, parts: [], attributes: body))
        XCTAssertTrue(attachments(in: reopened).isEmpty)
        XCTAssertEqual(reopened.string.trimmed, "Hi\nBye")
    }

    // MARK: - reading

    func testAMessageFalconMailSendsShowsItsPicturesInFalconMail() throws {
        let logo = try png()
        let opened = ComposedBody.opening(lead: "\n\n", signature: try signature(with: logo, named: "logo.png"), tail: "", attributes: body)
        let parsed = MIMEParser.parse(sent(try XCTUnwrap(opened.rich), plain: opened.plain))
        XCTAssertEqual(parsed.attachments.map(\.isInline), [true], "listed as a picture in the text, not as an attachment")
        // MessageRenderer shows each cid: from the message's own parts.
        let shown = InlinePictures.resolvingCIDs(in: try XCTUnwrap(parsed.textHTML), with: parsed.attachments)
        XCTAssertTrue(shown.contains("src=\"data:image/png;base64,\(logo.base64EncodedString())\""), shown)
        XCTAssertFalse(shown.contains("cid:"))
    }

    func testAForwardCarriesEveryPartItsTextDoesNotShow() {
        // An iPhone's photo in a plain message is inline but shown by no HTML.
        let photo = MIMEAttachment(id: "1", filename: "IMG_0001.jpeg", mimeType: "image/jpeg", contentID: nil, isInline: true, data: Data([1]))
        let logo = MIMEAttachment(id: "2", filename: "image001.png", mimeType: "image/png", contentID: "image001.png@x",
                                  isInline: true, data: Data([2]))
        let spare = MIMEAttachment(id: "3", filename: "spare.png", mimeType: "image/png", contentID: "spare@x", isInline: true, data: Data([3]))
        let html = "<p>Hi</p><img src=\"cid:IMAGE001.png@x\">"
        XCTAssertEqual([photo, logo, spare].map { InlinePictures.isShownInText($0, html: html) }, [false, true, false])
        XCTAssertFalse(InlinePictures.isShownInText(logo, html: nil))
    }

    func testTheReaderMatchesEachCIDWholeAndInAnyCase() {
        let parts = [MIMEAttachment(id: "1", filename: "a.png", mimeType: "image/png", contentID: "Logo@X", isInline: true, data: Data([1])),
                     MIMEAttachment(id: "2", filename: "b.png", mimeType: "image/png", contentID: "logo@x2", isInline: true, data: Data([2]))]
        let html = "<img src=\"cid:logo@x\"><img src='CID:logo@x2'><div style=\"background:url(cid:Logo@X)\"></div><img src=\"cid:missing@x\">"
        let shown = InlinePictures.resolvingCIDs(in: html, with: parts)
        XCTAssertEqual(shown, "<img src=\"data:image/png;base64,AQ==\"><img src='data:image/png;base64,Ag=='>"
                       + "<div style=\"background:url(data:image/png;base64,AQ==)\"></div><img src=\"cid:missing@x\">")
    }

    func testATagsSourceIsItsSrcAlone() {
        XCTAssertEqual(InlinePictures.attribute("src", in: "<img data-src=\"lazy.png\" src=\"cid:logo@x\">"), "cid:logo@x")
        XCTAssertEqual(InlinePictures.attribute("width", in: "<img style=\"width:5px\" width=96 src='a'>"), "96")
        XCTAssertNil(InlinePictures.attribute("height", in: "<img src=\"a\">"))
    }
}
