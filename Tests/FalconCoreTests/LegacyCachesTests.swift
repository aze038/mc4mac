import XCTest
@testable import FalconCore

/// What earlier builds' web and HTTP caches left under ~/Library/Caches goes, and nothing else.
final class LegacyCachesTests: XCTestCase {
    private var caches: URL!

    override func setUp() {
        caches = FileManager.default.temporaryDirectory.appendingPathComponent("falcon-caches-\(UUID().uuidString)", isDirectory: true)
        Log.start(in: caches)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: caches)
    }

    private func make(_ path: String) throws {
        let url = caches.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: caches.appendingPathComponent(path).path)
    }

    func testOnlyWhatTheCachesWroteInFalconMailsOwnFolderGoes() throws {
        for path in ["com.falconmail.app/Cache.db", "com.falconmail.app/Cache.db-wal", "com.falconmail.app/Cache.db-shm",
                     "com.falconmail.app/fsCachedData/A1B2", "com.falconmail.app/WebKit/NetworkCache/x",
                     "com.falconmail.app/com.apple.metal/cache", "com.falconmail.app.snapshot/Cache.db", "com.other.app/Cache.db"] {
            try make(path)
        }
        let removed = LegacyCaches.remove(from: caches, runningAs: "com.falconmail.app")
        XCTAssertEqual(Set(removed), ["Cache.db", "Cache.db-wal", "Cache.db-shm", "fsCachedData", "WebKit"])
        XCTAssertFalse(exists("com.falconmail.app/Cache.db"))
        XCTAssertFalse(exists("com.falconmail.app/WebKit"))
        XCTAssertTrue(exists("com.falconmail.app/com.apple.metal/cache"), "a file FalconMail did not write is left alone")
        XCTAssertTrue(exists("com.falconmail.app.snapshot/Cache.db"))
        XCTAssertTrue(exists("com.other.app/Cache.db"))
        XCTAssertTrue(LegacyCaches.remove(from: caches, runningAs: "com.falconmail.app").isEmpty, "nothing left to remove")
    }

    func testAnotherBuildRemovesNothing() throws {
        try make("com.falconmail.app/Cache.db")
        try make("com.falconmail.app.snapshot/Cache.db")
        XCTAssertTrue(LegacyCaches.remove(from: caches, runningAs: "com.falconmail.app.snapshot").isEmpty)
        XCTAssertTrue(LegacyCaches.remove(from: caches, runningAs: nil).isEmpty)
        XCTAssertTrue(exists("com.falconmail.app/Cache.db"))
        XCTAssertTrue(exists("com.falconmail.app.snapshot/Cache.db"))
    }
}
