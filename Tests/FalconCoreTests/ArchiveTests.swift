import XCTest
@testable import FalconCore

final class ArchiveTests: XCTestCase {
    func sampleMessage(_ n: Int, subject: String) -> Data {
        Data("From: sender\(n)@example.com\r\nTo: me@example.com\r\nSubject: \(subject)\r\nDate: Tue, 2 Apr 2024 09:14:0\(n % 10) +0000\r\nMessage-ID: <m\(n)@example.com>\r\n\r\nBody number \(n) about quarterly numbers.\r\n".utf8)
    }

    func testZipRoundTripAndRangeRead() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let storage = LocalFolderStorage(root: tmp)
        let writer = ArchiveWriter(storage: storage, parentID: nil, name: "Test", account: nil)
        try await writer.begin()
        for i in 0..<5 {
            try await writer.add(ArchiveInput(folderPath: "INBOX", uid: UInt32(i + 1), raw: sampleMessage(i, subject: "Report \(i)"), flags: [.seen]))
        }
        let manifest = try await writer.finish()
        XCTAssertEqual(manifest.messageCount, 5)
        XCTAssertEqual(manifest.chunks.count, 1)

        let root = tmp.appendingPathComponent("Test.fmarchive").path
        let reader = ArchiveReader(storage: storage, rootID: root)
        try await reader.loadIndex()
        let entries = await reader.entries
        XCTAssertEqual(entries.count, 5)
        let all = await reader.search("report")
        XCTAssertEqual(all.count, 5)
        let hit = await reader.search("sender3")
        XCTAssertEqual(hit.count, 1)
        let raw = try await reader.message(hit[0])
        XCTAssertEqual(raw, sampleMessage(3, subject: "Report 3"))

        let zipData = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("chunks/chunk-00001.zip"))
        XCTAssertEqual(zipData.readLE32(at: 0), 0x04034b50)
        let eocd = zipData.count - 22
        XCTAssertEqual(zipData.readLE32(at: eocd), 0x06054b50)
        XCTAssertEqual(zipData.readLE16(at: eocd + 10), 5)
    }

    func testEncryptedArchive() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let storage = LocalFolderStorage(root: tmp)
        let writer = ArchiveWriter(storage: storage, parentID: nil, name: "Secret", account: nil, options: ArchiveOptions(password: "hunter2"))
        try await writer.begin()
        try await writer.add(ArchiveInput(folderPath: "INBOX", uid: 1, raw: sampleMessage(1, subject: "Private"), flags: []))
        let manifest = try await writer.finish()
        XCTAssertTrue(manifest.isEncrypted)
        let root = tmp.appendingPathComponent("Secret.fmarchive").path

        let wrong = ArchiveReader(storage: storage, rootID: root, password: "nope")
        do { _ = try await wrong.open(); XCTFail("wrong password accepted") } catch {}

        let locked = ArchiveReader(storage: storage, rootID: root)
        _ = try await locked.open()
        do { try await locked.loadIndex(); XCTFail("index readable without password") } catch {}

        let reader = ArchiveReader(storage: storage, rootID: root, password: "hunter2")
        try await reader.loadIndex()
        let entries = await reader.entries
        XCTAssertEqual(entries.first?.subject, "Private")
        let raw = try await reader.message(entries[0])
        XCTAssertEqual(raw, sampleMessage(1, subject: "Private"))
    }

    func testCRC32() {
        XCTAssertEqual(CRC32.checksum(Data("The quick brown fox jumps over the lazy dog".utf8)), 0x414FA339)
    }

    func testTerms() {
        let t = ArchiveTerms.tokenize("Re: Q3 numbers from ana.smith@example.com")
        XCTAssertTrue(t.contains("q3"))
        XCTAssertTrue(t.contains("ana.smith@example.com"))
        XCTAssertTrue(t.contains("smith"))
        XCTAssertTrue(t.contains("example"))
    }
}
