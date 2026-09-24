import XCTest
@testable import FalconCore

/// Why an account is not syncing stays on show until it syncs again, whatever else the
/// engine reports meanwhile.
final class AccountStatusTests: XCTestCase {
    private let paused = UUID()
    private let other = UUID()
    private var harness: EngineHarness?

    override func tearDown() async throws {
        await harness?.finish()
    }

    func testAPausedAccountsSentenceOutlastsOtherAccountsPasses() {
        var board = AccountStatusBoard()
        board.apply(.health(accountID: paused, .imapPaused(until: Date().addingTimeInterval(1800))))
        board.apply(.error(accountID: paused, message: "Gmail asked FalconMail to slow down for a@example.com."))
        board.apply(.started(accountID: other))
        board.apply(.progress(accountID: other, text: "Checking INBOX"))
        board.apply(.finished(accountID: other))
        board.apply(.error(accountID: other, message: "A rule could not run."))
        XCTAssertEqual(board.problems[paused], "Gmail asked FalconMail to slow down for a@example.com.")
        XCTAssertNil(board.problems[other], "an error while reachable is about one pass, not the account")
        XCTAssertFalse(board.allReachable([paused, other]))
        XCTAssertTrue(board.allReachable([other]))

        board.apply(.health(accountID: paused, .online))
        XCTAssertNil(board.problems[paused])
        XCTAssertTrue(board.allReachable([paused, other]))
    }

    func testABlockedAccountCarriesItsReason() {
        var board = AccountStatusBoard()
        board.apply(.health(accountID: other, .blocked(reason: "Google wants you to sign in in a web browser first.")))
        XCTAssertEqual(board.problems[other], "Google wants you to sign in in a web browser first.")
    }

    func testTheEnginesThrottleStaysOnTheBoard() async throws {
        let server = try EngineHarness.gmailServer()
        server.add(FakeIMAPServer.message("first"), to: "INBOX")
        let h = try await EngineHarness(server: server)
        harness = h
        await h.syncer.start()
        await assertEventually { server.idlingCount == 1 }
        server.sendToIdling("* BYE Account exceeded command or bandwidth limits.", close: false)
        await assertEventually { await h.events.healths.contains { if case .imapPaused = $0 { return true }; return false } }
        await assertEventually { await !h.events.errors.isEmpty }
        var board = AccountStatusBoard()
        for event in await h.events.all { board.apply(event) }
        board.apply(.finished(accountID: other))
        let shown = try XCTUnwrap(board.problems[h.account.id])
        XCTAssertTrue(shown.hasPrefix("Gmail asked FalconMail to slow down for owner@example.com. Mail on this Mac stays available; downloads resume at "), shown)
        XCTAssertFalse(board.allReachable([h.account.id]))
    }
}
