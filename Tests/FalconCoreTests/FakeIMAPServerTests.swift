import XCTest
@testable import FalconCore

/// The fake server's faults behave as the phases after this one rely on.
final class FakeIMAPServerTests: XCTestCase {
    private var server: FakeIMAPServer!
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("falcon-fake-\(UUID().uuidString)", isDirectory: true)
        Log.start(in: root)
        server = FakeIMAPServer()
        server.addMailbox("INBOX")
        server.add(FakeIMAPServer.message("one"), to: "INBOX")
        try server.start()
    }

    override func tearDown() {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    func testABlackHoleNeitherAnswersNorCloses() async throws {
        let client = try await server.client()
        server.blackHole()
        do {
            _ = try await within(0.5) { try await client.noop() }
            XCTFail("a black hole answers nothing")
        } catch is TimedOut {}
        XCTAssertEqual(server.openConnections, 1)
    }

    func testAQuietConnectionIsClosedAfterItsSilence() async throws {
        server.closeAfterSilence(0.2)
        let client = try await server.client()
        await assertEventually { self.server.openConnections == 0 }
        do {
            try await client.noop()
            XCTFail("the server closed the connection")
        } catch {
            let connected = await client.isConnected
            XCTAssertFalse(connected, "a connection that failed is never used again")
        }
    }

    func testAByeDuringIdleEndsItAsGmailsThrottleDoes() async throws {
        let client = try await server.client()
        _ = try await client.select("INBOX")
        server.byeWhenIdling("Account exceeded command or bandwidth limits.", close: false)
        do {
            _ = try await within(5) { try await client.idle(maxWait: 60) }
            XCTFail("the server said BYE")
        } catch let bye as IMAPBye {
            XCTAssertEqual(bye.text, "Account exceeded command or bandwidth limits.")
        }
        let connected = await client.isConnected
        XCTAssertFalse(connected, "a BYE ends the connection even when the server leaves it open")
    }

    func testAStalledCommandHoldsUpOnlyItsAnswer() async throws {
        let client = try await server.client()
        _ = try await client.select("INBOX")
        server.stallNext("UID FETCH", seconds: 0.3)
        let started = Date()
        let body = try await client.fetchMessage(uid: 1)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.3)
        XCTAssertEqual(body, FakeIMAPServer.message("one"))
        await client.logout()
    }

    func testCountersSeeEveryCommandAndByte() async throws {
        let client = try await server.client()
        _ = try await client.select("INBOX")
        _ = try await client.fetchMessage(uid: 1)
        await client.logout()
        let session = try XCTUnwrap(server.sessionCounts.first)
        XCTAssertEqual(session.commands, server.commands.count)
        XCTAssertGreaterThan(session.bytesOut, FakeIMAPServer.message("one").count)
        XCTAssertGreaterThan(session.bytesIn, 0)
        XCTAssertTrue(session.signedIn)
        XCTAssertEqual(server.peakConnections, 1)
    }
}
