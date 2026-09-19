import XCTest
@testable import FalconCore

final class SearchTests: XCTestCase {
    func testFolderTermIndex() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = FolderStore(accountID: UUID(), folderID: UUID(), directory: tmp)
        try await store.load()
        func make(_ uid: UInt32, _ subject: String, _ from: String) -> MessageSummary {
            MessageSummary(accountID: UUID(), folderID: UUID(), uid: uid, messageID: "<\(uid)@x>", inReplyTo: "", references: [],
                           subject: subject, from: EmailAddress(name: "", address: from), to: [], cc: [], date: Date(), flags: [], size: 1, hasAttachments: false)
        }
        try await store.upsert([make(1, "Quarterly numbers", "ana@example.com"), make(2, "Lunch plans", "bob@example.com")])
        try await store.storeBody(uid: 2, raw: Data("x".utf8), snippet: "", hasAttachments: false, searchText: "Pizza on Friday with the whole team")
        let a = await store.search(tokens: ["quarterly"])
        XCTAssertEqual(a, [1])
        let b = await store.search(tokens: ["pizza", "friday"])
        XCTAssertEqual(b, [2])
        let c = await store.search(tokens: ["exam"])
        XCTAssertEqual(Set(c), [1, 2])
        try await store.remove(uids: [1])
        let d = await store.search(tokens: ["quarterly"])
        XCTAssertEqual(d, [])
    }

    func testOutboxTransientErrors() {
        XCTAssertTrue(Outbox.isTransient(FalconError.network("offline")))
        XCTAssertTrue(Outbox.isTransient(URLError(.notConnectedToInternet)))
        XCTAssertFalse(Outbox.isTransient(FalconError.protocolError("Recipient rejected")))
    }
}
