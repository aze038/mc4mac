import XCTest
import AppKit
@testable import FalconCore

/// Files dragged onto a compose window are attached, as Outlook attaches them, and never go into
/// the message as their path or a file:// link.
final class DroppedFilesTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("DroppedFilesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func file(_ name: String, _ contents: String = "contents") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// An attachment dragged out of a message window comes as a file URL, and is a file drag.
    func testAFileURLDragIsTakenAsFiles() {
        XCTAssertTrue(DroppedFiles.carriesFiles(["public.file-url", "public.utf8-plain-text"]))
        XCTAssertTrue(DroppedFiles.carriesFiles(["NSFilenamesPboardType"]))
    }

    /// Mail, Outlook, Safari's downloads and a message not yet downloaded promise their files.
    func testAFilePromiseIsTakenAsFiles() {
        XCTAssertTrue(DroppedFiles.carriesFiles(["com.apple.NSFilePromiseItemMetaData"]))
        XCTAssertTrue(DroppedFiles.carriesFiles(["com.apple.pasteboard.promised-file-url"]))
    }

    /// Words, rich text and web links dragged in are left to the text they land on.
    func testTextAndWebLinksAreNotFiles() {
        XCTAssertFalse(DroppedFiles.carriesFiles(["public.utf8-plain-text"]))
        XCTAssertFalse(DroppedFiles.carriesFiles(["public.rtf", "public.html", "public.utf8-plain-text"]))
        XCTAssertFalse(DroppedFiles.carriesFiles(["public.url", "public.utf8-plain-text"]))
    }

    func testFileURLsAreReadOffPasteboardItems() throws {
        let invoice = try file("Invoice 42.pdf")
        let photo = try file("photo.jpg")
        let first = NSPasteboardItem()
        first.setString(invoice.absoluteString, forType: NSPasteboard.PasteboardType("public.file-url"))
        first.setString(invoice.absoluteString, forType: .string)
        let second = NSPasteboardItem()
        second.setString(photo.absoluteString, forType: NSPasteboard.PasteboardType("public.file-url"))
        let urls = DroppedFiles.fileURLs(in: [first, second])
        XCTAssertEqual(urls.map(\.lastPathComponent), ["Invoice 42.pdf", "photo.jpg"])
    }

    /// A web address is not a file: it is never attached.
    func testAWebAddressIsNotAFile() {
        let item = NSPasteboardItem()
        item.setString("https://example.com/report.pdf", forType: NSPasteboard.PasteboardType("public.file-url"))
        XCTAssertTrue(DroppedFiles.fileURLs(in: [item]).isEmpty)
    }

    /// The old list of paths some apps still give is read too, and a file named both ways once.
    func testOldPathListsAreReadAndEachFileTakenOnce() throws {
        let report = try file("report.xlsx")
        let item = NSPasteboardItem()
        item.setString(report.absoluteString, forType: NSPasteboard.PasteboardType("public.file-url"))
        item.setPropertyList([report.path], forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        XCTAssertEqual(DroppedFiles.fileURLs(in: [item]), [report])
    }

    /// Each dropped file becomes an attachment with its own name, bytes and type, pictures
    /// included, as Outlook attaches a picture file dropped onto a message.
    func testDroppedFilesBecomeAttachments() throws {
        let pdf = try file("Invoice 42.pdf", "%PDF")
        let picture = try file("photo.png", "PNG")
        let unknown = try file("notes", "plain")
        let made = DroppedFiles.attachments(from: [pdf, picture, unknown, pdf])
        XCTAssertEqual(made.map(\.filename), ["Invoice 42.pdf", "photo.png", "notes"])
        XCTAssertEqual(made.map(\.mimeType), ["application/pdf", "image/png", "application/octet-stream"])
        XCTAssertEqual(made.map { String(decoding: $0.data, as: UTF8.self) }, ["%PDF", "PNG", "plain"])
        XCTAssertTrue(made.allSatisfy { $0.contentID == nil }, "a dropped file is an attachment, not a picture in the text")
    }

    /// A folder, or a file gone by the time it is read, is passed over rather than attached empty.
    func testFoldersAndMissingFilesAreSkipped() throws {
        let sub = folder.appendingPathComponent("Sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let gone = folder.appendingPathComponent("gone.txt")
        let kept = try file("kept.txt")
        XCTAssertEqual(DroppedFiles.attachments(from: [sub, gone, kept]).map(\.filename), ["kept.txt"])
    }

    /// The whole path is never what goes in: the drop is its file, named as the file is.
    func testNoAttachmentIsNamedByItsPath() throws {
        let url = try file("contract.docx")
        let made = try XCTUnwrap(DroppedFiles.attachments(from: [url]).first)
        XCTAssertFalse(made.filename.contains("/"))
        XCTAssertFalse(made.filename.hasPrefix("file:"))
        XCTAssertEqual(made.mimeType, "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
    }
}
