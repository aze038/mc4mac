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

extension MigrationTests {
    private static func residentBytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    func testStreamingALargeArchiveKeepsMemoryFlat() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = LocalFolderStorage(root: dir)
        let session = try await storage.beginUpload(name: "big.olm", parentID: dir.path, mimeType: "application/zip")
        let writer = ZipChunkWriter(session: session, name: "big.olm")
        let filler = String(repeating: "Lorem ipsum dolor sit amet. ", count: 4000)
        let attachment = Data(repeating: 0x41, count: 200_000)
        let count = 400
        for i in 0..<count {
            let xml = MigrationTests.sampleXML
                .replacingOccurrences(of: "abc123", with: "msg\(i)")
                .replacingOccurrences(of: "Hi, see attached.", with: filler)
                .replacingOccurrences(of: "1F2E/report.pdf", with: "A\(i)/report.pdf")
            _ = try await writer.add(name: "Accounts/Work/com.microsoft.__Messages/Inbox/message_\(i).xml", data: Data(xml.utf8), modified: Date())
            _ = try await writer.add(name: "Accounts/Work/com.microsoft.__Attachments/A\(i)/report.pdf", data: attachment, modified: Date())
        }
        _ = try await writer.close()
        let url = dir.appendingPathComponent("big.olm")
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 100_000_000)

        let archive = try OLMArchive(url: url)
        let inbox = archive.folders.first { $0.path == "Inbox" }!
        let messages = try archive.messages(in: inbox)
        XCTAssertEqual(messages.count, count)
        let baseline = MigrationTests.residentBytes()
        var peak = baseline
        var bytes = 0
        for light in messages {
            let m = try light.prepared()
            bytes += try m.load().count
            peak = max(peak, MigrationTests.residentBytes())
        }
        XCTAssertGreaterThan(bytes, size / 2)
        XCTAssertLessThan(peak - baseline, 80_000_000, "memory grew by \((peak - baseline) / 1_000_000) MB while streaming \(size / 1_000_000) MB")
    }

    func testJournalUnmarksMissingMessagesForReupload() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let key = MigrationState.key("Inbox", "<a@example.com>")
        let other = MigrationState.key("Inbox", "<b@example.com>")
        MigrationState.append([.init(d: key), .init(d: other), .init(a: MigrationAppended(folder: "INBOX", messageID: "<a@example.com>"))], to: url)
        XCTAssertEqual(MigrationState.load(url).done, [key, other])
        MigrationState.append([.init(u: key)], to: url)
        let state = MigrationState.load(url)
        XCTAssertEqual(state.done, [other])
        XCTAssertEqual(state.appended.count, 1)
    }

    func testGmailImportMultipartBody() throws {
        let metadata = Data("{\"labelIds\":[\"INBOX\"]}".utf8)
        let raw = Data("Subject: hi\r\n\r\nbody\r\n".utf8)
        let body = String(decoding: GmailImporter.multipart(metadata: metadata, raw: raw, boundary: "B"), as: UTF8.self)
        XCTAssertTrue(body.hasPrefix("--B\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n{\"labelIds\":[\"INBOX\"]}\r\n--B\r\nContent-Type: message/rfc822\r\n\r\nSubject: hi"))
        XCTAssertTrue(body.hasSuffix("\r\n--B--\r\n"))
        XCTAssertTrue(GmailImporter.isRateLimited(FalconError.http(429, "")))
        XCTAssertTrue(GmailImporter.isRateLimited(FalconError.http(403, "userRateLimitExceeded")))
        XCTAssertFalse(GmailImporter.isRateLimited(FalconError.http(403, "insufficientPermissions")))
        XCTAssertFalse(GmailImporter.isRateLimited(FalconError.http(400, "bad request")))
    }
}
