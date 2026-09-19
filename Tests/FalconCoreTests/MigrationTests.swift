import XCTest
@testable import FalconCore

final class MigrationTests: XCTestCase {
    func testOLMFoldersAndMessageRoundTrip() async throws {
        let url = try await makeOLMAsync()
        let archive = try OLMArchive(url: url)
        let kinds = Dictionary(uniqueKeysWithValues: archive.folders.map { ($0.path, $0.kind) })
        XCTAssertEqual(kinds["Inbox"], .inbox)
        XCTAssertEqual(kinds["Sent Items"], .sent)
        XCTAssertEqual(kinds["Projects/Alpha"], .other)
        let inbox = archive.folders.first { $0.path == "Inbox" }!
        let messages = try archive.messages(in: inbox)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].messageID, "")
        let m = try messages[0].prepared()
        XCTAssertEqual(m.messageID, "<abc123@example.com>")
        XCTAssertTrue(m.isRead)
        XCTAssertTrue(m.isFlagged)
        XCTAssertEqual(m.date, ISO8601DateFormatter().date(from: "2022-05-23T10:33:05Z"))
        let mime = MIMEParser.parse(try m.load())
        XCTAssertEqual(mime.subject, "Quarterly report")
        XCTAssertEqual(mime.from.address, "ana@example.com")
        XCTAssertEqual(mime.from.name, "Ana Smith")
        XCTAssertEqual(mime.to.first?.address, "me@example.com")
        XCTAssertEqual(mime.messageID, "<abc123@example.com>")
        XCTAssertEqual(mime.textPlain?.trimmed, "Hi, see attached.")
        XCTAssertTrue(mime.textHTML?.contains("<b>attached</b>") ?? false)
        XCTAssertEqual(mime.attachments.first?.filename, "report.pdf")
        XCTAssertEqual(mime.attachments.first?.data, Data("%PDF-1.4 test".utf8))
        XCTAssertNotNil(mime.date)
    }

    private func makeOLMAsync() async throws -> URL { try await makeOLMTask() }

    private func makeOLMTask() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storage = LocalFolderStorage(root: dir)
        let session = try await storage.beginUpload(name: "test.olm", parentID: dir.path, mimeType: "application/zip")
        let writer = ZipChunkWriter(session: session, name: "test.olm")
        let xml = MigrationTests.sampleXML
        _ = try await writer.add(name: "Accounts/Work/com.microsoft.__Messages/Inbox/message_00001.xml", data: Data(xml.utf8), modified: Date())
        _ = try await writer.add(name: "Accounts/Work/com.microsoft.__Messages/Sent Items/message_00002.xml", data: Data(xml.replacingOccurrences(of: "abc123", with: "def456").utf8), modified: Date())
        _ = try await writer.add(name: "Accounts/Work/com.microsoft.__Messages/Projects/Alpha/message_00003.xml", data: Data(xml.replacingOccurrences(of: "abc123", with: "ghi789").utf8), modified: Date())
        _ = try await writer.add(name: "Accounts/Work/com.microsoft.__Attachments/1F2E/report.pdf", data: Data("%PDF-1.4 test".utf8), modified: Date())
        _ = try await writer.close()
        return dir.appendingPathComponent("test.olm")
    }

    static let sampleXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <email version="1.0">
      <OPFMessageCopyMessageID>&lt;abc123@example.com&gt;</OPFMessageCopyMessageID>
      <OPFMessageCopySubject>Quarterly report</OPFMessageCopySubject>
      <OPFMessageCopySentTime>2022-05-23T10:32:00</OPFMessageCopySentTime>
      <OPFMessageCopyReceivedTime>2022-05-23T10:33:05</OPFMessageCopyReceivedTime>
      <OPFMessageCopyFromAddresses><emailAddress OPFContactEmailAddressAddress="ana@example.com" OPFContactEmailAddressName="Ana Smith" OPFContactEmailAddressType="SMTP"/></OPFMessageCopyFromAddresses>
      <OPFMessageCopyToAddresses><emailAddress OPFContactEmailAddressAddress="me@example.com" OPFContactEmailAddressName="Me"/></OPFMessageCopyToAddresses>
      <OPFMessageCopyBody>Hi, see attached.</OPFMessageCopyBody>
      <OPFMessageCopyHTMLBody>&lt;html&gt;&lt;body&gt;&lt;p&gt;Hi, see &lt;b&gt;attached&lt;/b&gt;.&lt;/p&gt;&lt;/body&gt;&lt;/html&gt;</OPFMessageCopyHTMLBody>
      <OPFMessageIsRead>1</OPFMessageIsRead>
      <OPFMessageCopyFlagStatus>2</OPFMessageCopyFlagStatus>
      <OPFMessageCopyAttachmentList>
        <messageAttachment OPFAttachmentContentType="application/pdf" OPFAttachmentName="report.pdf" OPFAttachmentURL="Accounts/Work/com.microsoft.__Attachments/1F2E/report.pdf"/>
      </OPFMessageCopyAttachmentList>
    </email>
    """

    func testOutlookSourceHeaderStrippingAndLineEndings() throws {
        let raw = Data([0xD0, 0x0D, 0, 0, 1, 0, 0, 0]) + Data(repeating: 0x11, count: 24) + Data("crSM".utf8) + Data([1, 2, 3, 4])
            + Data("From: a@b\rSubject: Hi\r\rBody line\r".utf8)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".olk15MsgSource")
        try raw.write(to: dir)
        let mime = try OutlookProfile.mime(at: dir)
        XCTAssertEqual(mime, Data("From: a@b\r\nSubject: Hi\r\n\r\nBody line\r\n".utf8))
        XCTAssertEqual(OutlookProfile.uuidString("0300000057319CC0D1F043DC95032177B9E6BD51"), "57319CC0-D1F0-43DC-9503-2177B9E6BD51")
        XCTAssertNil(OutlookProfile.validDate(978_307_200))
        XCTAssertNotNil(OutlookProfile.validDate(1_700_000_000))
    }
}
