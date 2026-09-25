import XCTest
import AppKit
@testable import FalconCore

/// Legacy Outlook for Mac's signatures come into FalconMail as Outlook shows them: their names,
/// Word's HTML read with its fonts, sizes, colours and links, and their pictures in place, which
/// are then sent embedded. Everything here is read from made-up profiles written in Outlook's
/// own layout (see OutlookFixture); nothing of anyone's Outlook is read, and Outlook's folders
/// are only ever read.
final class OutlookSignatureImportTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("OutlookImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // A folder made unreadable for a test is made readable again so it can go.
        if let walker = FileManager.default.enumerator(at: home, includingPropertiesForKeys: nil) {
            for case let url as URL in walker { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: home.appendingPathComponent(OutlookSignatureImport.profilesPath).path)
        try? FileManager.default.removeItem(at: home)
    }

    private let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor]

    private func picture(_ data: Data = OutlookFixture.jpeg()) -> OutlookFixture.Picture {
        OutlookFixture.Picture(contentID: OutlookFixture.contentID, data: data)
    }

    private func testSignature(named name: String = "Test Signature", withPicture: Bool = true) -> OutlookFixture.SignatureSpec {
        OutlookFixture.SignatureSpec(name: name, html: OutlookFixture.wordHTML(pictureID: withPicture ? OutlookFixture.contentID : nil),
                                     pictures: withPicture ? [picture()] : [])
    }

    /// A profile with the signatures and accounts given, listed in its database.
    @discardableResult
    private func profile(_ signatures: [OutlookFixture.SignatureSpec], accounts: [(String, String)] = [],
                         named name: String = "Main Profile") throws -> URL {
        let data = try OutlookFixture.profile(in: home, named: name)
        let paths = try OutlookFixture.write(signatures, into: data)
        let database = try OutlookFixture.Database(data.appendingPathComponent("Outlook.sqlite"))
        for path in paths { try database.add(signature: path) }
        for (email, accountName) in accounts { try database.add(account: email, name: accountName) }
        return data
    }

    // MARK: - The files

    func testASignatureFileGivesItsNameItsHTMLAndItsPictures() throws {
        let spec = testSignature()
        let parsed = try XCTUnwrap(OutlookSignatureFile.parse(OutlookFixture.signatureFile(spec)))
        XCTAssertEqual(parsed.name, "Test Signature")
        XCTAssertEqual(parsed.html, spec.html)
        XCTAssertEqual(parsed.pictures, [.init(contentID: OutlookFixture.contentID, mimeType: "image/jpeg", filename: "image001.jpg",
                                               file: spec.pictures[0].file)])
    }

    func testANameInAnyScriptAndAnHTMLWithoutPicturesAreReadWhole() throws {
        for name in ["Подпись – Ålex", "署名 ✉︎ Test", "Test Signature"] {
            let parsed = try XCTUnwrap(OutlookSignatureFile.parse(OutlookFixture.signatureFile(testSignature(named: name, withPicture: false))))
            XCTAssertEqual(parsed.name, name)
            XCTAssertTrue(parsed.pictures.isEmpty)
            XCTAssertTrue(parsed.html.hasPrefix("<html xmlns:v="))
        }
    }

    func testAPictureFileGivesThePictureWithItsTypeNameAndContentID() throws {
        let made = picture()
        let parsed = try XCTUnwrap(OutlookSignaturePicture.parse(OutlookFixture.attachmentFile(made)))
        XCTAssertEqual(parsed.data, made.data)
        XCTAssertEqual(parsed.mimeType, "image/jpeg")
        XCTAssertEqual(parsed.contentID, OutlookFixture.contentID)
        XCTAssertEqual(parsed.filename, "image001.jpg")
        XCTAssertTrue(parsed.isInline)
    }

    func testDamagedOrForeignFilesGiveNothingAndNeverCrash() {
        let signature = [UInt8](OutlookFixture.signatureFile(testSignature()))
        let attachment = [UInt8](OutlookFixture.attachmentFile(picture()))
        // Cut short anywhere in the header, the table or the name, a signature is not read.
        for length in stride(from: 0, to: 0x6C + 40, by: 1) {
            XCTAssertNil(OutlookSignatureFile.parse(Data(signature.prefix(length))), "cut at \(length)")
        }
        // Cut anywhere else, it never crashes.
        for length in stride(from: 0x6C + 40, to: signature.count, by: 97) { _ = OutlookSignatureFile.parse(Data(signature.prefix(length))) }
        for length in stride(from: 0, to: 0x30, by: 1) { XCTAssertNil(OutlookSignaturePicture.parse(Data(attachment.prefix(length)))) }
        for length in stride(from: 0x30, to: attachment.count, by: 211) { _ = OutlookSignaturePicture.parse(Data(attachment.prefix(length))) }
        // A property that claims more than the file holds, or a count past all reason.
        var lying = signature
        lying.replaceSubrange((0x34 + 8 * 3 + 4)..<(0x34 + 8 * 3 + 8), with: OutlookFixture.u32(0x7FFF_FFFF))
        XCTAssertNil(OutlookSignatureFile.parse(Data(lying)))
        var counted = signature
        counted.replaceSubrange(0x28..<0x2C, with: OutlookFixture.u32(0x1000_0000))
        XCTAssertNil(OutlookSignatureFile.parse(Data(counted)))
        XCTAssertNil(OutlookSignatureFile.parse(Data("not an Outlook file at all".utf8)))
        XCTAssertNil(OutlookSignaturePicture.parse(OutlookFixture.signatureFile(testSignature())))
        var random = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let noise = (0..<Int.random(in: 0...600, using: &random)).map { _ in UInt8.random(in: 0...255, using: &random) }
            _ = OutlookSignatureFile.parse(Data(Array(signature.prefix(0x24)) + noise))
            _ = OutlookSignaturePicture.parse(Data(Array(attachment.prefix(0x24)) + noise))
        }
    }

    // MARK: - A profile

    func testAProfileGivesEverySignatureInOutlooksOrderWithItsPicturesAndItsAccounts() throws {
        try profile([testSignature(), testSignature(named: "Short", withPicture: false)],
                    accounts: [("alex@example.com", "Alex Example"), ("office@example.org", "Example Office")])
        let read = try OutlookSignatureImport.read(home: home)
        XCTAssertEqual(read.count, 1)
        let profile = try XCTUnwrap(read.first)
        XCTAssertEqual(profile.profile.name, "Main Profile")
        XCTAssertTrue(profile.fromDatabase)
        XCTAssertEqual(profile.signatures.map(\.name), ["Test Signature", "Short"])
        XCTAssertEqual(profile.signatures[0].pictures.map(\.data), [picture().data])
        XCTAssertEqual(profile.signatures[0].pictures.first?.contentID, OutlookFixture.contentID)
        XCTAssertEqual(profile.signatures[0].missingPictures, [])
        XCTAssertTrue(profile.signatures[1].pictures.isEmpty)
        XCTAssertEqual(profile.accounts, [OutlookAccount(name: "Alex Example", email: "alex@example.com"),
                                          OutlookAccount(name: "Example Office", email: "office@example.org")])
    }

    func testTheDatabasesOrderIsKeptAndASignatureItNoLongerListsIsLeftOut() throws {
        let data = try OutlookFixture.profile(in: home)
        let paths = try OutlookFixture.write([testSignature(named: "First"), testSignature(named: "Second"),
                                              testSignature(named: "Deleted in Outlook")], into: data)
        let database = try OutlookFixture.Database(data.appendingPathComponent("Outlook.sqlite"))
        try database.add(signature: paths[1], id: 3)
        try database.add(signature: paths[0], id: 7)
        let read = try OutlookSignatureImport.read(home: home)
        XCTAssertEqual(read.first?.signatures.map(\.name), ["Second", "First"])
    }

    func testASignatureOutlookHasOnlyInItsWriteAheadLogIsFoundAndOutlooksFilesAreLeftAsTheyWere() throws {
        let data = try OutlookFixture.profile(in: home)
        let paths = try OutlookFixture.write([testSignature()], into: data)
        // Outlook is running: its database is open, and the signature is still in its log.
        let database = try OutlookFixture.Database(data.appendingPathComponent("Outlook.sqlite"), wal: true)
        try database.add(signature: paths[0])
        try database.add(account: "alex@example.com", name: "Alex Example")
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appendingPathComponent("Outlook.sqlite-wal").path))
        let before = DiskSnapshot.of(data)
        let copies = temporaryCopies()
        let read = try OutlookSignatureImport.read(home: home)
        XCTAssertEqual(read.first?.signatures.map(\.name), ["Test Signature"])
        XCTAssertEqual(read.first?.accounts.map(\.email), ["alex@example.com"])
        XCTAssertEqual(DiskSnapshot.of(data), before, "the import wrote into Outlook's folder")
        XCTAssertEqual(temporaryCopies(), copies, "the copy of Outlook's database was left behind")
        withExtendedLifetime(database) {}
    }

    private func temporaryCopies() -> Set<String> {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return Set(entries.filter { $0.hasPrefix("FalconMail-Outlook-") })
    }

    func testWithoutADatabaseEverySignatureFileIsTaken() throws {
        let data = try OutlookFixture.profile(in: home)
        try OutlookFixture.write([testSignature(named: "One"), testSignature(named: "Two", withPicture: false)], into: data)
        let read = try XCTUnwrap(OutlookSignatureImport.read(home: home).first)
        XCTAssertFalse(read.fromDatabase)
        XCTAssertEqual(Set(read.signatures.map(\.name)), ["One", "Two"])
        XCTAssertEqual(read.signatures.first { $0.name == "One" }?.pictures.count, 1)
        XCTAssertTrue(read.accounts.isEmpty)
    }

    func testAPictureWhoseFileIsGoneIsLeftOutAndCounted() throws {
        let data = try OutlookFixture.profile(in: home)
        let paths = try OutlookFixture.write([testSignature()], into: data, writingPictures: false)
        try OutlookFixture.Database(data.appendingPathComponent("Outlook.sqlite")).add(signature: paths[0])
        let signature = try XCTUnwrap(OutlookSignatureImport.read(home: home).first?.signatures.first)
        XCTAssertTrue(signature.pictures.isEmpty)
        XCTAssertEqual(signature.missingPictures, [OutlookFixture.contentID])
    }

    func testEveryProfileIsReadMainProfileFirst() throws {
        try profile([testSignature(named: "Work")], named: "Work Profile")
        try profile([testSignature(named: "Main")])
        let read = try OutlookSignatureImport.read(home: home)
        XCTAssertEqual(read.map(\.profile.name), ["Main Profile", "Work Profile"])
        XCTAssertEqual(read.map { $0.signatures.map(\.name) }, [["Main"], ["Work"]])
    }

    func testWithoutOutlookItSaysSo() throws {
        XCTAssertThrowsError(try OutlookSignatureImport.read(home: home)) {
            XCTAssertEqual($0 as? OutlookSignatureImport.Problem, .noOutlook)
        }
        // The folder is there, but no profile is in it.
        try FileManager.default.createDirectory(at: home.appendingPathComponent(OutlookSignatureImport.profilesPath).appendingPathComponent("Empty"),
                                                withIntermediateDirectories: true)
        XCTAssertThrowsError(try OutlookSignatureImport.read(home: home)) {
            XCTAssertEqual($0 as? OutlookSignatureImport.Problem, .noOutlook)
        }
    }

    func testAFolderMacOSWillNotLetFalconMailReadSaysSo() throws {
        try profile([testSignature()])
        let profiles = home.appendingPathComponent(OutlookSignatureImport.profilesPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: profiles.path)
        XCTAssertThrowsError(try OutlookSignatureImport.read(home: home)) {
            XCTAssertEqual($0 as? OutlookSignatureImport.Problem, .notAllowed)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: profiles.path)
        // Only the signatures themselves refused.
        let signatures = home.appendingPathComponent(OutlookSignatureImport.profilesPath).appendingPathComponent("Main Profile/Data/Signatures")
        for folder in try FileManager.default.contentsOfDirectory(at: signatures, includingPropertiesForKeys: nil) {
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        }
        XCTAssertThrowsError(try OutlookSignatureImport.read(home: home)) {
            XCTAssertEqual($0 as? OutlookSignatureImport.Problem, .notAllowed)
        }
    }

    func testOutlooksDataMacOSWillNotLetFalconMailLookIntoSaysSoRatherThanThatThereIsNoOutlook() throws {
        // macOS keeps another app's data closed until the owner allows it: FalconMail cannot even
        // look at what is inside, so the profiles seem not to be there.
        try profile([testSignature()])
        let container = home.appendingPathComponent("Library/Group Containers/UBF8T346G9.Office")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: container.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: container.path) }
        XCTAssertThrowsError(try OutlookSignatureImport.read(home: home)) {
            XCTAssertEqual($0 as? OutlookSignatureImport.Problem, .notAllowed)
        }
        // Only the profile's own folder closed.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: container.path)
        let profile = home.appendingPathComponent(OutlookSignatureImport.profilesPath).appendingPathComponent("Main Profile")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: profile.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: profile.path) }
        XCTAssertThrowsError(try OutlookSignatureImport.read(home: home)) {
            XCTAssertEqual($0 as? OutlookSignatureImport.Problem, .notAllowed)
        }
    }

    func testASignatureWithTwoPicturesAndALongNameInAnyScriptKeepsBothPictures() throws {
        let name = String(repeating: "Test Signature with a long name – ", count: 8) + "Ünïcødé 署名 ✉︎"
        let logo = OutlookFixture.Picture(contentID: "image001.jpg@01DD0000.00000000", data: OutlookFixture.jpeg(192, 58))
        var badge = OutlookFixture.Picture(contentID: "image002.png@01DD0000.00000000", data: Self.png(64, 64))
        badge.mimeType = "image/png"
        badge.filename = "image002.png"
        try profile([OutlookFixture.SignatureSpec(name: name, html: Self.twoPictureHTML(logo: logo.contentID, badge: badge.contentID),
                                                  pictures: [logo, badge])])
        let read = try XCTUnwrap(OutlookSignatureImport.read(home: home).first?.signatures.first)
        XCTAssertEqual(read.name, name)
        XCTAssertEqual(read.pictures.map(\.contentID), [logo.contentID, badge.contentID])
        XCTAssertEqual(read.pictures.map(\.data), [logo.data, badge.data])
        XCTAssertEqual(read.pictures.map(\.mimeType), ["image/jpeg", "image/png"])
        XCTAssertEqual(read.pictures.map(\.filename), ["image001.jpg", "image002.png"])
        XCTAssertEqual(read.missingPictures, [])
    }

    @MainActor
    func testTwoPicturesComeInAtTheirSizesAndAreSentAsTwoEmbeddedParts() throws {
        let logo = OutlookFixture.Picture(contentID: "image001.jpg@01DD0000.00000000", data: OutlookFixture.jpeg(192, 58))
        var badge = OutlookFixture.Picture(contentID: "image002.png@01DD0000.00000000", data: Self.png(64, 64))
        badge.mimeType = "image/png"
        badge.filename = "image002.png"
        try profile([OutlookFixture.SignatureSpec(name: "Test Signature", html: Self.twoPictureHTML(logo: logo.contentID, badge: badge.contentID),
                                                  pictures: [logo, badge])])
        let read = try XCTUnwrap(OutlookSignatureImport.read(home: home).first)
        let signature = try XCTUnwrap(SignatureCandidate.outlook(read).first?.signature(attributes: body))
        let kept = try JSONDecoder().decode(Signature.self, from: JSONEncoder().encode(signature))
        let shown = InlinePictures.attachmentLocations(in: kept.text).compactMap { InlinePictures.contents(of: $0.1) }
        XCTAssertEqual(shown.map { NSImage(data: $0)?.size }, [NSSize(width: 96, height: 29), NSSize(width: 32, height: 32)])
        let opened = ComposedBody.opening(lead: "\n\n", signature: kept, tail: "", attributes: body)
        let content = ComposedHTML.content(rich: opened.rich, plain: opened.plain, historyPlain: "", historyHTML: "")
        XCTAssertEqual(content.pictures.map(\.mimeType), ["image/jpeg", "image/png"])
        XCTAssertTrue(content.html.contains("<img width=\"96\" height=\"29\""), content.html)
        XCTAssertTrue(content.html.contains("<img width=\"32\" height=\"32\""), content.html)
        for picture in content.pictures { XCTAssertTrue(content.html.contains("src=\"cid:\(picture.contentID)\""), content.html) }
        XCTAssertFalse(content.html.contains("data:image"))
    }

    /// The made-up Word signature with a second picture, a badge, on a line of its own under the logo.
    private static func twoPictureHTML(logo: String, badge: String) -> String {
        OutlookFixture.wordHTML(pictureID: logo).replacingOccurrences(
            of: "<p class=MsoNormal><o:p>&nbsp;</o:p></p></div>",
            with: "<p class=MsoNormal><span style='font-size:10.0pt'><img width=32 height=32 style='width:.333in;height:.333in' "
                + "src=\"cid:\(badge)\"></span></p><p class=MsoNormal><o:p>&nbsp;</o:p></p></div>")
    }

    /// A PNG `width` × `height` pixels in one colour.
    private static func png(_ width: Int, _ height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    // MARK: - As FalconMail's signature

    @MainActor
    func testWordsHTMLComesOutAsOutlookShowsItWithThePictureInPlace() throws {
        try profile([testSignature()])
        let read = try XCTUnwrap(OutlookSignatureImport.read(home: home).first)
        let candidate = try XCTUnwrap(SignatureCandidate.outlook(read).first)
        let signature = try XCTUnwrap(candidate.signature(attributes: body))
        XCTAssertEqual(signature.name, "Test Signature")
        XCTAssertNotNil(signature.rich)
        let text = signature.text
        let string = text.string
        XCTAssertTrue(string.hasPrefix("Alex Example\nOperations Lead | Example Freight Ltd\nTel: +44 20 7946 0000 | example.com\n"), string)
        for leak in ["[if", "endif", "v:shape", "@font-face", "MsoNormal", "behavior", "o:p", "WordSection"] {
            XCTAssertFalse(string.contains(leak), "“\(leak)” came out as text: \(string)")
        }
        XCTAssertFalse(string.hasSuffix("\n"), "the blank paragraph Word ends with is kept")

        func font(at word: String) -> NSFont? {
            text.attribute(.font, at: (string as NSString).range(of: word).location, effectiveRange: nil) as? NSFont
        }
        func colour(at word: String) -> NSColor? {
            (text.attribute(.foregroundColor, at: (string as NSString).range(of: word).location, effectiveRange: nil) as? NSColor)?
                .usingColorSpace(.sRGB)
        }
        // Word's points are CSS points: 10pt and 9pt are 13⅓ and 12 of the composer's points.
        let name = try XCTUnwrap(font(at: "Alex"))
        XCTAssertEqual(name.familyName, "Helvetica Neue")
        XCTAssertTrue(name.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(name.pointSize, 13.33, accuracy: 0.01)
        XCTAssertEqual(font(at: "Operations")?.familyName, "Helvetica Neue")
        XCTAssertEqual(try XCTUnwrap(font(at: "Operations")).pointSize, 12, accuracy: 0.01)
        XCTAssertEqual(font(at: "Tel")?.familyName, "Helvetica")
        let navy = try XCTUnwrap(colour(at: "Alex"))
        XCTAssertEqual(navy.redComponent * 255, 0x1F, accuracy: 1.5)
        XCTAssertEqual(navy.blueComponent * 255, 0x64, accuracy: 1.5)
        XCTAssertEqual(try XCTUnwrap(colour(at: "Operations")).redComponent * 255, 0x44, accuracy: 1.5)
        let link = text.attribute(.link, at: (string as NSString).range(of: "example.com", options: .backwards).location, effectiveRange: nil)
        XCTAssertEqual((link as? URL)?.absoluteString ?? link as? String, "https://example.com/")
        // No space between Word's paragraphs, as MsoNormal sets none.
        let style = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.paragraphSpacing ?? 0, 0, accuracy: 0.5)

        // The picture, once, at the size Word gives it.
        let pictures = InlinePictures.attachmentLocations(in: text)
        XCTAssertEqual(pictures.count, 1)
        let shown = try XCTUnwrap(pictures.first?.1)
        let data = try XCTUnwrap(InlinePictures.contents(of: shown))
        XCTAssertEqual(InlinePictures.format(of: data), .jpeg)
        XCTAssertEqual(NSImage(data: data)?.size, NSSize(width: 96, height: 29))
        XCTAssertEqual(NSBitmapImageRep(data: data)?.pixelsWide, 192, "the picture was scaled")
    }

    @MainActor
    func testTheImportedSignatureSendsItsPictureEmbeddedAsOutlookDoes() throws {
        try profile([testSignature()])
        let read = try XCTUnwrap(OutlookSignatureImport.read(home: home).first)
        let signature = try XCTUnwrap(SignatureCandidate.outlook(read).first?.signature(attributes: body))
        // Kept, as the signatures file keeps it, and read back.
        let kept = try JSONDecoder().decode(Signature.self, from: JSONEncoder().encode(signature))
        let opened = ComposedBody.opening(lead: "\n\n", signature: kept, tail: "", attributes: body)
        let rich = try XCTUnwrap(opened.rich)
        let stored = ComposedBody.stored(rich)
        let content = ComposedHTML.content(rtf: stored.rtf, rtfd: stored.rtfd, plain: opened.plain, historyPlain: "", historyHTML: "")
        let message = OutgoingMessage(from: EmailAddress(name: "Alex Example", address: "alex@example.com"),
                                      to: [EmailAddress(name: "Sam", address: "sam@example.com")], subject: "Hello",
                                      textBody: content.plain, htmlBody: content.html, attachments: content.pictures.map(\.attachment))
        let parsed = MIMEParser.parse(MIMEBuilder.build(message))
        let html = try XCTUnwrap(parsed.textHTML)
        XCTAssertEqual(parsed.root.contentType.mimeType, "multipart/related")
        XCTAssertEqual(content.pictures.count, 1)
        let sent = try XCTUnwrap(content.pictures.first)
        XCTAssertEqual(sent.mimeType, "image/jpeg")
        XCTAssertTrue(sent.contentID.hasPrefix("image001.jpg@"), sent.contentID)
        XCTAssertTrue(html.contains("<img width=\"96\" height=\"29\""), html)
        XCTAssertTrue(html.contains("src=\"cid:\(sent.contentID)\""), html)
        XCTAssertFalse(html.contains("data:image"))
        let part = try XCTUnwrap(parsed.attachments.first { $0.contentID == sent.contentID })
        XCTAssertEqual(part.mimeType, "image/jpeg")
        XCTAssertEqual(NSBitmapImageRep(data: part.data)?.pixelsWide, 192)
        XCTAssertTrue(parsed.textPlain?.contains("[cid:\(sent.contentID)]") ?? false)
        XCTAssertTrue(html.contains("Alex Example"))
        XCTAssertTrue(html.contains("https://example.com/"))
    }

    @MainActor
    func testAPictureWhoseResolutionWordStatesInExifStillShowsAtTheSizeWordGivesIt() throws {
        // Word keeps a logo of 480 × 150 pixels at 72 dots an inch, in its JFIF header and again
        // in an Exif block, which macOS reads first, and shows it at 96 × 29.
        for resolution in [OutlookFixture.Resolution.jfif, .exif(littleEndian: true), .exif(littleEndian: false)] {
            let logo = OutlookFixture.jpeg(480, 150, resolution: resolution)
            XCTAssertEqual(NSImage(data: logo)?.size, NSSize(width: 480, height: 150))
            let candidate = SignatureCandidate(name: "Test Signature", origin: .outlook(profile: "Main Profile"),
                                               html: OutlookFixture.wordHTML(),
                                               pictures: [MIMEAttachment(picture: logo, filename: "image001.jpg", mimeType: "image/jpeg",
                                                                         contentID: OutlookFixture.contentID)])
            // As the signatures file keeps it, which holds no size for a picture but its file's own.
            let signature = try XCTUnwrap(candidate.signature(attributes: body))
            let kept = try JSONDecoder().decode(Signature.self, from: JSONEncoder().encode(signature))
            let shown = try XCTUnwrap(InlinePictures.attachmentLocations(in: kept.text).first?.1)
            let data = try XCTUnwrap(InlinePictures.contents(of: shown))
            XCTAssertEqual(NSImage(data: data)?.size, NSSize(width: 96, height: 29), "\(resolution)")
            XCTAssertEqual(NSBitmapImageRep(data: data)?.pixelsWide, 480, "\(resolution): the picture was scaled")
            let opened = ComposedBody.opening(lead: "\n\n", signature: kept, tail: "", attributes: body)
            let content = ComposedHTML.content(rich: opened.rich, plain: opened.plain, historyPlain: "", historyHTML: "")
            XCTAssertTrue(content.html.contains("<img width=\"96\" height=\"29\""), "\(resolution): \(content.html)")
        }
    }

    // MARK: - Which accounts use it

    func testAProfilesOnlySignatureIsSuggestedForEveryAccountItHas() throws {
        try profile([testSignature()], accounts: [("alex@example.com", "Alex"), ("Office@Example.org", "Office")])
        let candidates = SignatureCandidate.outlook(try XCTUnwrap(OutlookSignatureImport.read(home: home).first))
        XCTAssertEqual(candidates.map(\.defaultAddresses), [["alex@example.com", "Office@Example.org"]])
        XCTAssertEqual(candidates.map(\.defaultsKnown), [false])
        let alex = AccountInfo(email: "Alex@Example.com", displayName: "Alex Example")
        let office = AccountInfo(email: "office@example.org", displayName: "Office", provider: "imap")
        let other = AccountInfo(email: "someone@example.net", displayName: "Other")
        XCTAssertEqual(candidates[0].defaultAccounts(in: [other, office, alex]), [office.id, alex.id])
    }

    func testWithSeveralSignaturesOnlyOneNamedForAnAccountIsSuggestedForIt() throws {
        try profile([testSignature(named: "Formal"), testSignature(named: "alex@example.com short", withPicture: false)],
                    accounts: [("alex@example.com", "Alex"), ("office@example.org", "Office")])
        let candidates = SignatureCandidate.outlook(try XCTUnwrap(OutlookSignatureImport.read(home: home).first))
        XCTAssertEqual(candidates.map(\.defaultAddresses), [[], ["alex@example.com"]])
    }
}
