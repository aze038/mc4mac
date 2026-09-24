import XCTest
@testable import FalconCore

/// A message that was going out when FalconMail stopped may already have been delivered, so
/// after a relaunch it waits for the owner instead of going out a second time.
final class OutboxCrashTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("falcon-outbox-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Log.start(in: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func itemFile(_ id: UUID) -> URL {
        FileLayout(root: root).outboxDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    func testCrashDuringSendIsHeldAndNeverResent() async throws {
        let layout = FileLayout(root: root)
        let stuck = RecordingSender(hangs: true)
        let first = Outbox(layout: layout, sender: stuck, undoWindow: 0)
        let item = try await first.enqueue(accountID: UUID(), from: "owner@example.com", message: SendTests.outgoing(), sendAt: Date())
        await assertEventually { stuck.calls == 1 }

        // What a crash at this moment leaves on disk.
        let onDisk = AtomicFile.readJSON(OutboxItem.self, from: itemFile(item.id))
        XCTAssertEqual(onDisk?.status, .sending, "the attempt is recorded before anything is sent")

        let counting = RecordingSender(hangs: false)
        let relaunched = Outbox(layout: layout, sender: counting, undoWindow: 0)
        await relaunched.startPump()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(counting.calls, 0, "never sent again by itself")
        let items = await relaunched.snapshot()
        let held = try XCTUnwrap(items.first)
        XCTAssertTrue(held.isHeld)
        XCTAssertEqual(held.error, Outbox.interruptedText)

        // Sending again is the owner's decision, and then it goes once.
        try await relaunched.retry(held.id)
        await assertEventually { counting.calls == 1 }
        await assertEventually { await relaunched.snapshot().first?.status == .sent }
        XCTAssertEqual(counting.calls, 1)
    }

    func testAHeldItemIsReadByThePreviousReleaseAsFailedAndNotSent() async throws {
        let layout = FileLayout(root: root)
        let stuck = RecordingSender(hangs: true)
        let first = Outbox(layout: layout, sender: stuck, undoWindow: 0)
        let item = try await first.enqueue(accountID: UUID(), from: "owner@example.com", message: SendTests.outgoing(), sendAt: Date())
        await assertEventually { stuck.calls == 1 }
        _ = Outbox(layout: layout, sender: RecordingSender(hangs: false), undoWindow: 0)

        let data = try Data(contentsOf: itemFile(item.id))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let previous = try decoder.decode(PreviousReleaseOutboxItem.self, from: data)
        XCTAssertEqual(previous.status, .failed, "the previous release offers Retry and never sends it by itself")
        XCTAssertEqual(previous.error, Outbox.interruptedText)
    }

    func testAnItemFromThePreviousReleaseStillLoads() async throws {
        let layout = FileLayout(root: root)
        try FileManager.default.createDirectory(at: layout.outboxDirectory, withIntermediateDirectories: true)
        let id = UUID()
        // Written by f591fae: no heldBack field.
        let fixture = """
            {"accountID":"\(UUID().uuidString)","attempts":2,"createdAt":"2026-09-20T10:00:00Z","error":"Network error: offline",\
            "id":"\(id.uuidString)","recipients":["ana@example.com"],"sendAt":"2026-09-20T10:05:00Z","sender":"owner@example.com",\
            "status":"failed","subject":"Quarterly report","undoUntil":"2026-09-20T10:00:10Z"}
            """
        try Data(fixture.utf8).write(to: itemFile(id))
        let outbox = Outbox(layout: layout, sender: RecordingSender(hangs: false), undoWindow: 0)
        let items = await outbox.snapshot()
        XCTAssertEqual(items.map(\.id), [id])
        XCTAssertEqual(items.first?.status, .failed)
        XCTAssertFalse(items.first?.isHeld ?? true)
    }

    func testDailySendingLimitHoldsTheMessage() async throws {
        let layout = FileLayout(root: root)
        let limited = RecordingSender(hangs: false, failure: SMTPServerError(stage: .message, code: 550, text: "5.4.5 Daily user sending limit exceeded."))
        let outbox = Outbox(layout: layout, sender: limited, undoWindow: 0)
        _ = try await outbox.enqueue(accountID: UUID(), from: "owner@example.com", message: SendTests.outgoing(), sendAt: Date())
        await assertEventually { await outbox.snapshot().first?.isHeld == true }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(limited.calls, 1)
        let text = await outbox.snapshot().first?.error ?? ""
        XCTAssertTrue(text.contains("daily sending limit"), text)
    }
}

/// OutboxItem as the previous release (f591fae) declares it.
private struct PreviousReleaseOutboxItem: Codable {
    enum Status: String, Codable { case queued, sending, sent, failed, cancelled }
    var id: UUID
    var accountID: UUID
    var subject: String
    var recipients: [String]
    var sender: String
    var sendAt: Date
    var createdAt: Date
    var status: Status
    var error: String?
    var undoUntil: Date
    var attempts: Int?
}

private final class RecordingSender: MessageSender, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let hangs: Bool
    private let failure: Error?

    init(hangs: Bool, failure: Error? = nil) {
        self.hangs = hangs
        self.failure = failure
    }

    var calls: Int { lock.withLock { count } }

    func send(accountID: UUID, from: String, recipients: [String], message: Data) async throws {
        lock.withLock { count += 1 }
        if hangs { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
        if let failure { throw failure }
    }
}
