import XCTest
@testable import FalconCore

final class LogTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("falcon-log-\(UUID().uuidString)", isDirectory: true)
        Log.start(in: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testAFullLogIsKeptAsTheOlderFileInsteadOfDeleted() throws {
        let current = root.appendingPathComponent("falconmail.log")
        let older = root.appendingPathComponent("falconmail.1.log")
        try Data("an even older log\n".utf8).write(to: older)
        let full = Data(("the lead-up to a problem\n" + String(repeating: "x", count: Log.maxFileBytes)).utf8)
        try full.write(to: current)

        Log.info("test", "after the turn")
        Log.flush()
        XCTAssertEqual(try Data(contentsOf: older), full, "the full log is kept whole as the older one")
        let now = try String(contentsOf: current, encoding: .utf8)
        XCTAssertTrue(now.hasSuffix("[test] after the turn\n"))
        XCTAssertLessThan(now.utf8.count, 200)
    }

    func testOnlyTheAccountsOwnAddressReachesTheLog() {
        let text = "550 5.1.1 <ana@example.com>: Recipient address rejected; sent as Owner@Example.com to bo.smith+x@mail.example.org"
        XCTAssertEqual(Log.redacted(text, keeping: "owner@example.com"),
                       "550 5.1.1 <<address>>: Recipient address rejected; sent as Owner@Example.com to <address>")
    }
}
