import XCTest
import AppKit
@testable import FalconCore

/// Where the rules for messages not yet sent meet the pictures drafts now keep: a message with a
/// picture that is closed, kept on this Mac across a quit, saved to Drafts and opened again from
/// there, or discarded and brought back by Undo, still has its picture, and it goes to Drafts as
/// an inline part, as a sent message's pictures go.
final class UnsentPictureTests: XCTestCase {
    private let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor]

    /// A message being written, as ComposeDraft keeps it: its words, its body as RTF and, while it
    /// holds pictures, as RTFD, and the copy in Drafts it is linked to.
    private struct Written: Codable, Sendable, Identifiable, Equatable {
        var id = UUID()
        var plain: String
        var rtf: Data?
        var rtfd: Data?
        var copy: String?

        init(_ text: NSAttributedString, copy: String? = nil) {
            let stored = ComposedBody.stored(text)
            plain = text.string
            rtf = stored.rtf
            rtfd = stored.rtfd
            self.copy = copy
        }

        var text: NSAttributedString? { ComposedBody.text(rtf: rtf, rtfd: rtfd) }

        /// What saving it to Drafts puts there, as ComposeDraft.outgoing and MIMEBuilder build it.
        var raw: Data {
            let date = Date(timeIntervalSince1970: 1_790_000_000)
            let content = ComposedHTML.content(rtf: rtf, rtfd: rtfd, plain: plain, historyPlain: "", historyHTML: "", date: date)
            let message = OutgoingMessage(from: EmailAddress(name: "Alex", address: "alex@example.com"),
                                          to: [EmailAddress(name: "Sam", address: "sam@example.com")], subject: "Site visit",
                                          textBody: content.plain, htmlBody: content.html,
                                          attachments: content.pictures.map(\.attachment), date: date)
            return MIMEBuilder.build(message)
        }
    }

    /// The server's Drafts folder: each copy as it was saved, by its id.
    @MainActor
    private final class DraftsFolder {
        var copies: [String: Data] = [:]
        var saves = 0

        /// A save adds a copy in place of the one the message is linked to.
        func save(_ message: Written) {
            saves += 1
            if let copy = message.copy { copies[copy] = nil }
            copies["saved-\(saves)"] = message.raw
        }

        func delete(_ copy: String) { copies[copy] = nil }
    }

    private struct Offline: Error {}

    private func dataDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("UnsentPictures-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// One launch of FalconMail over the files kept in `directory`.
    @MainActor
    private func launch(_ directory: URL, _ folder: DraftsFolder) -> UnsentDrafts<Written, String> {
        let unsent = UnsentDrafts<Written, String>(directory: directory)
        unsent.deleteCopy = { folder.delete($0) }
        return unsent
    }

    private func photo() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 40, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 120, height: 40).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// Words with a picture between them, as Pictures in the ribbon puts one in.
    private func withPicture(_ picture: Data, _ words: String = "The site today:") throws -> NSAttributedString {
        let text = NSMutableAttributedString(string: words + "\n", attributes: body)
        text.append(NSAttributedString(attachment: try XCTUnwrap(InlinePictures.attachment(for: picture, named: "site.png"))))
        text.append(NSAttributedString(string: "\nThanks\n", attributes: body))
        return text
    }

    private func pictures(in text: NSAttributedString?) -> [Data?] {
        guard let text else { return [] }
        return InlinePictures.attachmentLocations(in: text).map { $0.1.fileWrapper?.regularFileContents }
    }

    /// The pictures of a copy in Drafts: the inline parts its HTML shows by cid:, and the
    /// pictures of the draft that copy opens as again.
    @MainActor
    private func pictures(inCopy raw: Data?, file: StaticString = #filePath, line: UInt = #line) throws -> (parts: [Data], reopened: [Data?]) {
        let parsed = MIMEParser.parse(try XCTUnwrap(raw, file: file, line: line))
        let html = try XCTUnwrap(parsed.textHTML, file: file, line: line)
        XCTAssertFalse(html.contains("data:image"), "a picture went to Drafts as a data: URI", file: file, line: line)
        let shown = parsed.attachments.filter { InlinePictures.isShownInText($0, html: html) }
        let reopened = InlinePictures.text(fromHTML: html, parts: parsed.attachments, attributes: body, remote: [:], fitting: false)
        return (shown.map(\.data), pictures(in: reopened))
    }

    @MainActor
    func testAMessageWithAPictureClosedWhileDraftsCannotBeReachedKeepsItThroughAQuitIntoDrafts() async throws {
        let directory = dataDirectory()
        let folder = DraftsFolder()
        let picture = try photo()
        let message = Written(try withPicture(picture))
        XCTAssertNotNil(message.rtfd, "a body with a picture is kept as RTFD too")

        // Closed while Drafts cannot be reached, as AppModel.saveDraftToServer closes one: the save
        // starts, the window lets go of the message, and the save fails, so it stays on this Mac.
        let first = launch(directory, folder)
        let saving = first.save(message) { _ in throw Offline() }
        first.forget(message.id)
        let failure = await saving.value
        XCTAssertTrue(failure is Offline)
        _ = await first.finish(within: 1)

        let second = launch(directory, folder)
        let left = second.leftovers()
        XCTAssertEqual(left, [message], "the next launch finds it as it was written")
        XCTAssertEqual(pictures(in: left.first?.text), [picture], "with its picture")
        let saved = await second.save(left[0]) { folder.save($0) }.value
        XCTAssertNil(saved)
        XCTAssertEqual(Array(folder.copies.keys), ["saved-1"], "saved once")

        let copy = try pictures(inCopy: folder.copies["saved-1"])
        XCTAssertEqual(copy.parts, [picture], "the picture goes to Drafts as an inline part, exactly its bytes")
        XCTAssertEqual(copy.reopened, [picture], "and a draft opened again from Drafts shows it")
        XCTAssertEqual(launch(directory, folder).leftovers(), [], "nothing is left to save again")
    }

    @MainActor
    func testADiscardedMessageWithAPictureComesBackWithItOnUndoAndClosingItAgainReplacesItsCopy() async throws {
        let directory = dataDirectory()
        let folder = DraftsFolder()
        let picture = try photo()
        // Reopened from Drafts, where an earlier version is kept, and changed.
        folder.copies["draft-41"] = Written(try withPicture(picture, "Site visit, first notes")).raw
        let message = Written(try withPicture(picture), copy: "draft-41")
        let unsent = launch(directory, folder)
        unsent.keep(message)

        // Discard, then Undo three seconds later, as AppModel.discardCompose and undoDiscard do.
        let now = Date()
        var discarded = DiscardedMessage<Written>()
        unsent.discard(message.id, copy: message.copy, at: now)
        discarded.discard(message, now: now)
        let back = try XCTUnwrap(discarded.undo(at: now.addingTimeInterval(3)))
        unsent.undoDiscard(back)
        unsent.undoEnded(back.id)

        XCTAssertEqual(back, message)
        XCTAssertEqual(pictures(in: back.text), [picture], "Undo brings the message back with its picture")
        XCTAssertEqual(pictures(in: launch(directory, folder).leftovers().first?.text), [picture],
                       "and it is kept on this Mac again with its picture")
        let finished = await unsent.finish(within: 5)
        XCTAssertTrue(finished)
        XCTAssertNotNil(folder.copies["draft-41"], "its copy in Drafts is no longer deleted")

        // Closed again, it takes that copy's place, picture and all.
        let failure = await unsent.save(back) { folder.save($0) }.value
        XCTAssertNil(failure)
        XCTAssertEqual(Array(folder.copies.keys), ["saved-1"])
        let copy = try pictures(inCopy: folder.copies["saved-1"])
        XCTAssertEqual(copy.parts, [picture])
        XCTAssertEqual(copy.reopened, [picture])
    }
}
