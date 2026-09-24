import XCTest
import AppKit
@testable import FalconCore

final class SignatureTests: XCTestCase {
    private let history = "\n________________________________\nFrom: Sam Sender <sam@example.com>\nSubject: Figures\n\nThe numbers.\n"
    private let font = NSFont.systemFont(ofSize: 14)

    private func account(_ name: String, _ email: String, signature: String) -> AccountInfo {
        AccountInfo(email: email, displayName: name, signature: signature)
    }

    private func bold(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)])
    }

    private func isBold(_ text: NSAttributedString, at location: Int) -> Bool {
        guard let font = text.attribute(.font, at: location, effectiveRange: nil) as? NSFont else { return false }
        return NSFontManager.shared.traits(of: font).contains(.boldFontMask)
    }

    private func picture() throws -> NSTextAttachment {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let wrapper = FileWrapper(regularFileWithContents: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])))
        wrapper.preferredFilename = "logo.png"
        return NSTextAttachment(fileWrapper: wrapper)
    }

    // MARK: - carrying over the accounts' own signatures

    func testEveryAccountSignatureIsKeptAsItsDefaultForNewMessagesAndReplies() throws {
        let kamal = account("Kamal Muradov", "kamal@example.com", signature: "Kamal Muradov\nFreight Masters")
        let bare = account("", "ops@example.com", signature: "Operations")
        var book = SignatureBook()
        XCTAssertTrue(book.adopt([kamal, bare]))

        XCTAssertEqual(book.signatures.map(\.name).sorted(), ["Kamal Muradov", "ops@example.com"])
        for account in [kamal, bare] {
            let new = try XCTUnwrap(book.signature(for: account.id, .newMessages))
            XCTAssertEqual(new.plain, account.signature)
            XCTAssertNil(new.rich)
            XCTAssertEqual(book.signature(for: account.id, .replies), new)
        }
    }

    func testAnAccountWithoutASignatureGetsNoneAndNothingIsCreated() {
        let empty = account("Empty", "empty@example.com", signature: "")
        let spaces = account("Spaces", "spaces@example.com", signature: "  \n\t")
        var book = SignatureBook()
        book.adopt([empty, spaces])

        XCTAssertTrue(book.signatures.isEmpty)
        for account in [empty, spaces] {
            XCTAssertNil(book.signature(for: account.id, .newMessages))
            XCTAssertNil(book.signature(for: account.id, .replies))
        }
        XCTAssertEqual(Set(book.adopted.map(\.accountID)), [empty.id, spaces.id])
        XCTAssertTrue(book.defaults.isEmpty)
    }

    func testCarriedOverSignaturesGetUniqueNamesAndNoneIsNameless() {
        let first = account("Kamal Muradov", "kamal@example.com", signature: "One")
        let second = account("Kamal Muradov", "kamal@work.example", signature: "Two")
        let third = account("kamal muradov", "kamal@work.example", signature: "Three")
        let blankName = account(" ", "solo@example.com", signature: "Four")
        var book = SignatureBook()
        book.adopt([first, second, third, blankName])

        let names = book.signatures.map(\.name)
        XCTAssertEqual(names, ["Kamal Muradov", "kamal@work.example", "kamal muradov 2", "solo@example.com"])
        XCTAssertFalse(names.contains { $0.trimmed.isEmpty })
        XCTAssertEqual(book.signature(for: third.id, .newMessages)?.plain, "Three")
    }

    func testEachAccountIsCarriedOverOnce() {
        let kamal = account("Kamal", "kamal@example.com", signature: "Kamal")
        var book = SignatureBook()
        book.adopt([kamal])
        XCTAssertFalse(book.adopt([kamal]))
        XCTAssertEqual(book.signatures.count, 1)

        // Deleted here, it stays deleted; an account added since is still picked up.
        book.remove(book.signatures[0].id)
        let later = account("Later", "later@example.com", signature: "Later")
        XCTAssertTrue(book.adopt([kamal, later]))
        XCTAssertEqual(book.signatures.map(\.name), ["Later"])
    }

    func testASignatureAnOlderBuildGivesAnAccountWithoutOneIsCarriedOverAsItsDefaults() throws {
        var kamal = account("Kamal Muradov", "kamal@example.com", signature: "")
        var book = SignatureBook()
        book.adopt([kamal])
        XCTAssertTrue(book.signatures.isEmpty)

        kamal.signature = "Kamal Muradov\nFreight Masters"
        XCTAssertTrue(book.adopt([kamal]))
        let carried = try XCTUnwrap(book.signature(for: kamal.id, .newMessages))
        XCTAssertEqual(carried.plain, kamal.signature)
        XCTAssertEqual(carried.name, "Kamal Muradov")
        XCTAssertEqual(book.signature(for: kamal.id, .replies), carried)
        XCTAssertFalse(book.adopt([kamal]))
        XCTAssertEqual(book.signatures.count, 1)
    }

    func testASignatureAnOlderBuildChangesIsKeptBesideTheFirstAndReplacesItOnlyWhereItIsStillTheDefault() throws {
        var kamal = account("Kamal Muradov", "kamal@example.com", signature: "Kamal")
        var book = SignatureBook()
        book.adopt([kamal])
        let first = try XCTUnwrap(book.signature(for: kamal.id, .newMessages))
        let chosen = book.add()
        book.setDefault(chosen.id, for: kamal.id, .replies)

        kamal.signature = "Kamal Muradov\nFreight Masters"
        XCTAssertTrue(book.adopt([kamal]))
        let second = try XCTUnwrap(book.signature(for: kamal.id, .newMessages))
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(second.plain, kamal.signature)
        XCTAssertEqual(second.name, "kamal@example.com")
        XCTAssertEqual(book.signature(first.id)?.plain, "Kamal")
        XCTAssertEqual(book.defaultID(for: kamal.id, .replies), chosen.id)

        // Only spaces changed: nothing new.
        kamal.signature += "\n"
        XCTAssertFalse(book.adopt([kamal]))
        XCTAssertEqual(book.signatures.count, 3)

        // Cleared by the older build, it no longer starts messages there, nor here where it
        // still would; the signature itself stays.
        kamal.signature = ""
        XCTAssertTrue(book.adopt([kamal]))
        XCTAssertNil(book.defaultID(for: kamal.id, .newMessages))
        XCTAssertEqual(book.defaultID(for: kamal.id, .replies), chosen.id)
        XCTAssertNotNil(book.signature(second.id))
    }

    func testACarriedOverSignatureOpensMessagesExactlyAsTheAccountsDid() throws {
        let kamal = account("Kamal", "kamal@example.com", signature: "Kamal Muradov\nFreight Masters")
        var book = SignatureBook()
        book.adopt([kamal])
        let before = "-- \n\(kamal.signature)\n\n"

        let new = ComposedBody.opening(lead: "\n\n", signature: book.signature(for: kamal.id, .newMessages), tail: "",
                                       attributes: [.font: font])
        XCTAssertEqual(new.plain, "\n\n" + before)
        XCTAssertNil(new.rich)
        let reply = ComposedBody.opening(lead: "\n\n", signature: book.signature(for: kamal.id, .replies), tail: history,
                                         attributes: [.font: font])
        XCTAssertEqual(reply.plain, "\n\n" + before + history)
        XCTAssertNil(reply.rich)
    }

    // MARK: - defaults

    func testComposePicksTheNewMessageDefaultForNewMessagesAndTheReplyDefaultForReplies() throws {
        let accountID = UUID()
        var book = SignatureBook()
        let long = book.add()
        book.rename(long.id, to: "Long")
        book.setText(NSAttributedString(string: "Kamal Muradov\nFreight Masters"), of: long.id)
        let short = book.add()
        book.rename(short.id, to: "Short")
        book.setText(NSAttributedString(string: "K."), of: short.id)
        book.setDefault(long.id, for: accountID, .newMessages)
        book.setDefault(short.id, for: accountID, .replies)

        XCTAssertEqual(book.signature(for: accountID, .newMessages)?.name, "Long")
        XCTAssertEqual(book.signature(for: accountID, .replies)?.name, "Short")
        XCTAssertNil(book.signature(for: UUID(), .newMessages))

        let reply = ComposedBody.opening(lead: "\n\n", signature: book.signature(for: accountID, .replies), tail: history,
                                         attributes: [.font: font])
        XCTAssertEqual(reply.plain, "\n\n-- \nK.\n\n" + history)

        book.setDefault(nil, for: accountID, .replies)
        let none = ComposedBody.opening(lead: "\n\n", signature: book.signature(for: accountID, .replies), tail: history,
                                        attributes: [.font: font])
        XCTAssertEqual(none.plain, "\n\n" + history)
        XCTAssertNil(none.rich)
    }

    func testDeletingASignatureSetsTheDefaultsThatUsedItToNone() {
        let first = UUID(), second = UUID()
        var book = SignatureBook()
        let gone = book.add()
        let kept = book.add()
        book.setDefault(gone.id, for: first, .newMessages)
        book.setDefault(gone.id, for: first, .replies)
        book.setDefault(kept.id, for: second, .newMessages)
        book.setDefault(gone.id, for: second, .replies)

        book.remove(gone.id)
        XCTAssertEqual(book.signatures.map(\.id), [kept.id])
        XCTAssertNil(book.defaultID(for: first, .newMessages))
        XCTAssertNil(book.defaultID(for: first, .replies))
        XCTAssertEqual(book.defaultID(for: second, .newMessages), kept.id)
        XCTAssertNil(book.defaultID(for: second, .replies))
    }

    // MARK: - names

    func testNewSignaturesAreUntitledThenNumberedAndListedByName() {
        var book = SignatureBook()
        let names = (0..<11).map { _ in book.add().name }
        XCTAssertEqual(Array(names.prefix(3)), ["Untitled", "Untitled 2", "Untitled 3"])
        XCTAssertEqual(book.sorted.map(\.name).suffix(2), ["Untitled 10", "Untitled 11"])
        XCTAssertEqual(book.sorted.first?.name, "Untitled")
    }

    func testRenamingTakesATrimmedNameAndNeverAnEmptyOne() {
        var book = SignatureBook()
        let signature = book.add()
        book.rename(signature.id, to: "  Work  ")
        XCTAssertEqual(book.signature(signature.id)?.name, "Work")
        book.rename(signature.id, to: " ")
        XCTAssertEqual(book.signature(signature.id)?.name, "Work")

        let other = book.add()
        book.rename(other.id, to: "Personal")
        XCTAssertEqual(book.sorted.map(\.name), ["Personal", "Work"])
        XCTAssertEqual(book.add().name, "Untitled")
    }

    // MARK: - storage

    func testTheBookComesBackFromItsFileWithFormattingAndPictures() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SignatureStore(layout: FileLayout(root: directory))
        XCTAssertEqual(store.file.lastPathComponent, "signatures.json")

        var book = SignatureBook()
        book.adopt([account("Kamal", "kamal@example.com", signature: "Kamal")])
        let rich = book.add()
        let text = NSMutableAttributedString(attributedString: bold("Kamal Muradov"))
        text.append(NSAttributedString(string: "\n"))
        text.append(NSAttributedString(attachment: try picture()))
        book.setText(text, of: rich.id)
        book.setDefault(rich.id, for: UUID(), .replies)
        try store.save(book)

        let opened = store.open()
        XCTAssertTrue(opened.writable)
        XCTAssertEqual(opened.book, book)
        let back = try XCTUnwrap(opened.book.signature(rich.id))
        XCTAssertEqual(back.plain, "Kamal Muradov\n")
        XCTAssertTrue(isBold(back.text, at: 0))
        let attachment = back.text.attribute(.attachment, at: back.text.length - 1, effectiveRange: nil) as? NSTextAttachment
        XCTAssertNotNil(attachment?.fileWrapper?.regularFileContents)
    }

    private func asideFiles(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("signatures-unreadable-") }
    }

    func testAMissingFileIsANewBookAndAnUndecodableOneIsSetAsideWhole() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SignatureStore(layout: FileLayout(root: directory))
        let fresh = store.open()
        XCTAssertEqual(fresh.book, SignatureBook())
        XCTAssertNil(fresh.problem)
        XCTAssertTrue(fresh.writable)

        for damaged in ["not json", #"{"version":1,"signatures":{"items":[]}}"#, #"{"signatures":[]}"#] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(damaged.utf8).write(to: store.file)
            let opened = store.open()
            XCTAssertEqual(opened.book, SignatureBook())
            XCTAssertTrue(opened.writable)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.file.path))
            let aside = try XCTUnwrap(try asideFiles(in: directory).first)
            XCTAssertEqual(opened.problem, .setAside(directory.appendingPathComponent(aside)))
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(aside)), Data(damaged.utf8))
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testABookFromANewerBuildIsReadButNotWrittenOver() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SignatureStore(layout: FileLayout(root: directory))
        var book = SignatureBook()
        book.add()
        book.version = SignatureBook.currentVersion + 1
        try store.save(book)

        let opened = store.open()
        XCTAssertEqual(opened.book.signatures.count, 1)
        XCTAssertEqual(opened.problem, .newer)
        XCTAssertFalse(opened.writable)
    }

    func testABookFromANewerBuildThisOneCannotDecodeIsLeftWhereItIs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SignatureStore(layout: FileLayout(root: directory))
        let newer = Data(#"{"version":2,"signatures":{"items":[{"name":"Formal"}]},"defaults":[],"adopted":[]}"#.utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try newer.write(to: store.file)

        let opened = store.open()
        XCTAssertEqual(opened.problem, .newer)
        XCTAssertFalse(opened.writable)
        XCTAssertTrue(opened.book.signatures.isEmpty)
        XCTAssertEqual(try Data(contentsOf: store.file), newer)
        XCTAssertTrue(try asideFiles(in: directory).isEmpty)
    }

    func testAFileThatCannotBeReadIsLeftWhereItIsAndNotWrittenOver() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SignatureStore(layout: FileLayout(root: directory))
        var book = SignatureBook()
        book.rename(book.add().id, to: "Mine")
        try store.save(book)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: store.file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.file.path) }

        let opened = store.open()
        XCTAssertEqual(opened.problem, .unreadable)
        XCTAssertFalse(opened.writable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.file.path))
        XCTAssertTrue(try asideFiles(in: directory).isEmpty)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.file.path)
        XCTAssertEqual(store.open().book.signatures.map(\.name), ["Mine"])
    }

    // MARK: - rich text in the composer

    func testAFormattedSignatureOpensAMessageInItsOwnFormatting() throws {
        var book = SignatureBook()
        let signature = book.add()
        book.setText(bold("Kamal"), of: signature.id)
        let opened = ComposedBody.opening(lead: "\n\n", signature: book.signature(signature.id), tail: history,
                                          attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let rich = try XCTUnwrap(opened.rich)
        XCTAssertEqual(opened.plain, "\n\n-- \nKamal\n\n" + history)
        XCTAssertEqual(rich.string, opened.plain)
        XCTAssertFalse(isBold(rich, at: 0))
        XCTAssertTrue(isBold(rich, at: ("\n\n-- \n" as NSString).length))
        XCTAssertEqual(rich.attribute(.foregroundColor, at: rich.length - 1, effectiveRange: nil) as? NSColor, .labelColor)
        XCTAssertEqual(ComposedBody.historyStart(in: rich.string, history: history), ("\n\n-- \nKamal\n\n" as NSString).length)
    }

    @MainActor
    func testAFormattedSignatureFromTheMenuKeepsItsFormattingAboveTheOriginal() throws {
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        editor.textStorage?.setAttributedString(NSAttributedString(string: "Thanks 📈\n" + history,
                                                                   attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        var signature = Signature(name: "Bold")
        signature.setText(bold("Kamal"))

        ComposedBody.insertSignature(signature.block, into: editor, before: history)
        let storage = try XCTUnwrap(editor.textStorage)
        XCTAssertEqual(editor.string, "Thanks 📈\n-- \nKamal\n\n" + history)
        XCTAssertTrue(isBold(storage, at: ("Thanks 📈\n-- \n" as NSString).length))
        XCTAssertFalse(isBold(storage, at: ("Thanks 📈\n" as NSString).length))
        XCTAssertEqual(editor.selectedRange().location, ("Thanks 📈\n-- \nKamal\n\n" as NSString).length)
    }

    // MARK: - text without formatting of its own

    private var composer: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: NSColor.labelColor] }

    @MainActor
    func testTextTypedInTheComposersOwnFormattingStaysPlain() throws {
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        editor.textStorage?.setAttributedString(NSAttributedString(string: "Kamal\r\nFreight Masters", attributes: composer))
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText(" Ltd, Bakı", replacementRange: editor.selectedRange())
        var signature = Signature(name: "Kamal")
        signature.setText(try XCTUnwrap(editor.textStorage), plainIn: composer)

        XCTAssertNil(signature.rich)
        XCTAssertEqual(signature.plain, "Kamal\r\nFreight Masters Ltd, Bakı")
        let opened = ComposedBody.opening(lead: "\n\n", signature: signature, tail: history, attributes: composer)
        XCTAssertNil(opened.rich)
        XCTAssertEqual(opened.plain, "\n\n-- \n\(signature.plain)\n\n" + history)
    }

    func testFormattingOrAPictureOrALinkKeepsTheSignatureRich() throws {
        let bolded = NSMutableAttributedString(string: "Kamal ", attributes: composer)
        bolded.append(bold("Muradov"))
        let linked = NSAttributedString(string: "example.com", attributes: composer.merging([.link: URL(string: "https://example.com")!]) { $1 })
        let coloured = NSAttributedString(string: "Kamal", attributes: composer.merging([.foregroundColor: NSColor.systemBlue]) { $1 })
        let pictured = NSMutableAttributedString(string: "Kamal", attributes: composer)
        pictured.append(NSAttributedString(attachment: try picture()))
        for text in [bolded, linked, coloured, pictured] {
            var signature = Signature(name: "Rich")
            signature.setText(text, plainIn: composer)
            XCTAssertNotNil(signature.rich, text.string)
        }
    }

    func testAPictureAloneIsASignatureButSpacesAreNot() throws {
        var picture = Signature(name: "Logo")
        picture.setText(NSAttributedString(attachment: try self.picture()))
        XCTAssertEqual(picture.plain, "")
        XCTAssertFalse(picture.isBlank)

        var spaces = Signature(name: "Spaces")
        spaces.setText(NSAttributedString(string: " \n "))
        XCTAssertTrue(spaces.isBlank)
        XCTAssertEqual(ComposedBody.opening(lead: "\n\n", signature: spaces, tail: "", attributes: [:]).plain, "\n\n")
    }
}
