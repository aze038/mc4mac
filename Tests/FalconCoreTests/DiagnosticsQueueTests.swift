import XCTest
@testable import FalconCore

final class DiagnosticsQueueTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("queue.jsonl") }
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        directory = DiagnosticsFixtures.temporaryDirectory("queue")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testEventsSurviveReopeningWithoutAFlush() {
        let queue = DiagnosticsQueue(url: url)
        queue.add(DiagnosticsFixtures.record(DiagnosticsFixtures.event("A.one@X.swift:1")))
        queue.add(DiagnosticsFixtures.record(DiagnosticsFixtures.event("A.two@X.swift:2")))
        // No flush and no deinit, as after a crash: each new event is already a line on disk.
        let reopened = DiagnosticsQueue(url: url)
        XCTAssertEqual(reopened.records.map(\.event.signature), ["A.one@X.swift:1", "A.two@X.swift:2"])
    }

    func testRepeatsWithinAnHourFoldIntoACount() {
        let queue = DiagnosticsQueue(url: url)
        XCTAssertEqual(queue.add(DiagnosticsFixtures.record(DiagnosticsFixtures.event(at: start))), .added)
        XCTAssertEqual(queue.add(DiagnosticsFixtures.record(DiagnosticsFixtures.event(at: start.addingTimeInterval(600)))), .folded)
        XCTAssertEqual(queue.add(DiagnosticsFixtures.record(DiagnosticsFixtures.event(at: start.addingTimeInterval(3_000)))), .folded)
        XCTAssertEqual(queue.records.count, 1)
        XCTAssertEqual(queue.records[0].event.count, 3)
        XCTAssertEqual(queue.records[0].event.firstAt, start)
        XCTAssertEqual(queue.records[0].event.lastAt, start.addingTimeInterval(3_000))
        XCTAssertTrue(queue.needsFlush)
        queue.flush()
        XCTAssertEqual(DiagnosticsQueue(url: url).records.first?.event.count, 3)
    }

    func testFoldingKeepsDistinctThingsApart() {
        let queue = DiagnosticsQueue(url: url)
        queue.add(DiagnosticsFixtures.record(DiagnosticsFixtures.event(at: start)))
        queue.add(DiagnosticsFixtures.record(DiagnosticsFixtures.event(at: start.addingTimeInterval(3_700))))
        queue.add(DiagnosticsFixtures.record(DiagnosticsFixtures.event(kind: .warning, at: start)))
        queue.add(DiagnosticsFixtures.record(DiagnosticsFixtures.event(at: start, account: "0a1b2c3d")))
        queue.add(DiagnosticsFixtures.record(DiagnosticsFixtures.event(at: start), app: DiagnosticsApp(version: "1.9.0", build: "99", channel: "release")))
        queue.add(DiagnosticsFixtures.record(DiagnosticsFixtures.event("Crash.X@FalconMail", kind: .crash, at: start)))
        queue.add(DiagnosticsFixtures.record(DiagnosticsFixtures.event("Crash.X@FalconMail", kind: .crash, at: start)))
        XCTAssertEqual(queue.records.count, 7, "an hour apart, another kind, account or build, and crashes never fold")
    }

    func testSealedRecordsAreNeverFoldedInto() {
        let queue = DiagnosticsQueue(url: url)
        let first = DiagnosticsFixtures.event(at: start)
        queue.add(DiagnosticsFixtures.record(first))
        queue.seal([first.id])
        XCTAssertEqual(queue.add(DiagnosticsFixtures.record(DiagnosticsFixtures.event(at: start.addingTimeInterval(5)))), .added)
        XCTAssertEqual(queue.records.map(\.event.count), [1, 1])
        XCTAssertEqual(DiagnosticsQueue(url: url).records.map(\.sealed), [true, false])
    }

    func testCapDropsOldestNonCrashFirst() {
        let queue = DiagnosticsQueue(url: url)
        let bulk = JSONValue.object(["filler": .string(String(repeating: "x", count: 15_000))])
        queue.add(DiagnosticsFixtures.record(DiagnosticsFixtures.event("Crash.old@FalconMail", kind: .crash, at: start, context: bulk)))
        for i in 0..<120 {
            queue.add(DiagnosticsFixtures.record(DiagnosticsFixtures.event("A.n\(String(repeating: "x", count: i))@X.swift:1",
                                                                            at: start.addingTimeInterval(Double(i)), context: bulk)))
        }
        XCTAssertLessThanOrEqual(queue.totalBytes, DiagnosticsQueue.maxBytes)
        let onDisk = (try? Data(contentsOf: url))?.count ?? 0
        XCTAssertLessThanOrEqual(onDisk, DiagnosticsQueue.maxBytes)
        XCTAssertEqual(queue.records.first?.event.signature, "Crash.old@FalconMail", "the crash outlives newer errors")
        XCTAssertEqual(queue.records.last?.event.signature.hasPrefix("A.n" + String(repeating: "x", count: 119)), true, "the newest stays")
        XCTAssertLessThan(queue.records.count, 121)
    }

    func testAHalfWrittenLastLineIsDroppedQuietly() throws {
        let queue = DiagnosticsQueue(url: url)
        queue.add(DiagnosticsFixtures.record(DiagnosticsFixtures.event("A.one@X.swift:1")))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"event":{"id":"half"#.utf8))
        try handle.close()
        let reopened = DiagnosticsQueue(url: url)
        XCTAssertEqual(reopened.records.count, 1)
        XCTAssertNil(reopened.setAside)
        reopened.add(DiagnosticsFixtures.record(DiagnosticsFixtures.event("A.two@X.swift:2")))
        XCTAssertEqual(DiagnosticsQueue(url: url).records.count, 2, "the next line starts cleanly")
    }

    func testDamagedFileIsSetAsideAndGoodLinesKept() throws {
        let queue = DiagnosticsQueue(url: url)
        queue.add(DiagnosticsFixtures.record(DiagnosticsFixtures.event("A.one@X.swift:1")))
        var data = try Data(contentsOf: url)
        data.append(Data("not json at all\n\u{00}\u{FF}garbage\n".utf8))
        data.append(Data([0xFF, 0xFE, 0x0A]))
        try data.write(to: url)
        let reopened = DiagnosticsQueue(url: url)
        XCTAssertEqual(reopened.records.map(\.event.signature), ["A.one@X.swift:1"])
        let aside = try XCTUnwrap(reopened.setAside)
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside.path))
        XCTAssertEqual(DiagnosticsQueue(url: url).records.count, 1)
    }

    func testUnreadableFilesAreSetAsideNotCrashedOn() throws {
        try Data((0..<4096).map { UInt8($0 % 251) }).write(to: url)
        let binary = DiagnosticsQueue(url: url)
        XCTAssertTrue(binary.isEmpty)
        XCTAssertNotNil(binary.setAside)

        try Data(count: DiagnosticsQueue.unreadableSize + 1).write(to: url)
        let huge = DiagnosticsQueue(url: url)
        XCTAssertTrue(huge.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let folder = DiagnosticsQueue(url: url)
        XCTAssertTrue(folder.isEmpty)
    }

    func testRemoveAndClear() {
        let queue = DiagnosticsQueue(url: url)
        let a = DiagnosticsFixtures.event("A.one@X.swift:1")
        let b = DiagnosticsFixtures.event("A.two@X.swift:2")
        queue.add(DiagnosticsFixtures.record(a))
        queue.add(DiagnosticsFixtures.record(b))
        queue.remove([a.id])
        XCTAssertEqual(DiagnosticsQueue(url: url).records.map(\.event.id), [b.id])
        queue.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(DiagnosticsQueue(url: url).isEmpty)
    }
}
