import XCTest
@testable import FalconCore

final class RowContentStoreTests: XCTestCase {
    private let account = UUID()

    private func key(_ i: Int) -> RowKey { .gmail(account: account, id: GmailMessageID(raw: 0x100 + UInt64(i))) }

    private func row(_ i: Int) -> MessageRowContent {
        MessageRowContent(key: key(i), from: EmailAddress(name: "Sender \(i)", address: "s\(i)@example.com"), to: [],
                          subject: "Subject \(i)", preview: "", date: Date(timeIntervalSince1970: Double(i)))
    }

    func testItKeepsTheFiveThousandRowsUsedMostRecently() {
        let store = RowContentStore()
        XCTAssertEqual(store.capacity, 5_000)
        for i in 0..<5_000 { store.insert(row(i), for: key(i)) }
        XCTAssertEqual(store.count, 5_000)
        // Reading the oldest counts as using it, so the second oldest goes first.
        XCTAssertNotNil(store.content(for: key(0)))
        let evicted = store.insert(row(5_000), for: key(5_000))
        XCTAssertEqual(evicted, key(1))
        XCTAssertNotNil(store.peek(key(0)))
        XCTAssertNil(store.peek(key(1)))
        XCTAssertEqual(store.count, 5_000)
    }

    func testReplacingARowKeepsOneCopyAndPeekingDoesNotCountAsUse() {
        let store = RowContentStore(capacity: 2)
        store.insert(row(1), for: key(1))
        store.insert(row(2), for: key(2))
        var changed = row(1)
        changed.subject = "Changed"
        store.insert(changed, for: key(1))
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.peek(key(1))?.subject, "Changed")
        _ = store.peek(key(2))
        XCTAssertEqual(store.insert(row(3), for: key(3)), key(2), "peeking left 2 the least recently used")
        XCTAssertEqual(store.keysByUse, [key(3), key(1)])
        store.remove(key(1))
        XCTAssertEqual(store.keysByUse, [key(3)])
        store.insert(row(4), for: key(4))
        store.insert(row(5), for: key(5))
        XCTAssertEqual(store.keysByUse, [key(5), key(4)])
        store.removeAll()
        XCTAssertEqual(store.count, 0)
    }
}
