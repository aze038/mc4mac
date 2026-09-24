import XCTest
@testable import FalconCore

final class MailSoundGateTests: XCTestCase {
    private let alex = UUID()
    private let office = UUID()
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func gate(off: Set<MailSoundEvent> = []) -> MailSoundGate {
        MailSoundGate { !off.contains($0) }
    }

    private func outlookDefaults() -> MailSoundGate {
        MailSoundGate { $0.isOnByDefault }
    }

    // MARK: - enabled flags

    func testEverySoundButWelcomeIsOnByDefault() {
        var gate = outlookDefaults()
        XCTAssertNil(gate.launched())
        XCTAssertEqual(gate.newMailArrived(), .newMessage)
        XCTAssertEqual(gate.messageSent(), .messageSent)
        XCTAssertEqual(MailSoundEvent.allCases.filter(\.isOnByDefault), [.newMessage, .messageSent, .reminder, .syncError, .noNewMessages])
    }

    func testASoundTurnedOffNeverPlays() {
        var gate = gate(off: Set(MailSoundEvent.allCases))
        XCTAssertNil(gate.launched())
        XCTAssertNil(gate.newMailArrived())
        XCTAssertNil(gate.messageSent())
        XCTAssertEqual(retries(alex, from: 0, on: &gate), [nil, nil, nil, nil])
        gate.manualCheckStarted(accounts: [alex], at: start)
        XCTAssertNil(gate.checkFinished(alex, foundNewMail: false, at: start))
    }

    func testTurningASoundOnAgainTakesEffectAtOnce() {
        var off: Set<MailSoundEvent> = [.messageSent]
        var gate = MailSoundGate { !off.contains($0) }
        XCTAssertNil(gate.messageSent())
        off = []
        gate.isEnabled = { !off.contains($0) }
        XCTAssertEqual(gate.messageSent(), .messageSent)
    }

    func testWelcomePlaysOncePerLaunch() {
        var gate = gate()
        XCTAssertEqual(gate.launched(), .welcome)
        XCTAssertNil(gate.launched(), "a mailbox window opened again is no new launch")
    }

    // MARK: - one sync error sound per lasting failure

    /// The syncer's retries after a failure: ten, thirty and seventy seconds on.
    private func retries(_ account: UUID, from start: TimeInterval, on gate: inout MailSoundGate) -> [MailSoundEvent?] {
        [0, 10, 30, 70].map { gate.syncFailed(account, uptime: start + $0) }
    }

    func testAFailureSoundsOnlyOnceARetryAMinuteLaterFailsToo() {
        var gate = gate()
        XCTAssertEqual(retries(alex, from: 1000, on: &gate), [nil, nil, nil, .syncError])
        XCTAssertNil(gate.syncFailed(alex, uptime: 1150), "a retry that fails again is the same episode")
        XCTAssertNil(gate.syncFailed(alex, uptime: 1460))
    }

    func testAConnectionDroppedEveryFewMinutesAndRestoredAtOnceNeverSounds() {
        var gate = gate()
        // As the owner's accounts do all day: the idle connection closed about every 285
        // seconds, the reconnect ten seconds later finishing a pass.
        var played: [MailSoundEvent] = []
        for drop in stride(from: 0.0, to: 24 * 3600, by: 285) {
            if let sound = gate.syncFailed(alex, uptime: drop) { played.append(sound) }
            gate.syncSucceeded(alex)
        }
        XCTAssertEqual(played, [])
    }

    func testARetryThatConnectsBeforeTheMinuteKeepsItQuiet() {
        var gate = gate()
        XCTAssertNil(gate.syncFailed(alex, uptime: 0))
        XCTAssertNil(gate.syncFailed(alex, uptime: 10), "the network is not back yet after waking")
        gate.syncSucceeded(alex)
        XCTAssertNil(gate.syncFailed(alex, uptime: 65), "a finished sync ends the episode, so this failure starts a new one")
    }

    func testAFinishedSyncEndsTheEpisode() {
        var gate = gate()
        XCTAssertEqual(retries(alex, from: 0, on: &gate).last, .syncError)
        gate.syncSucceeded(alex)
        XCTAssertEqual(retries(alex, from: 500, on: &gate), [nil, nil, nil, .syncError], "a new episode sounds once it lasts")
    }

    func testASyncThatFinishesAfterAnErrorInsideItNeverSoundsTheError() {
        var gate = gate()
        // A rule that fails on each message it matches, in passes that go on and finish.
        var played: [MailSoundEvent] = []
        for pass in 0..<3 {
            if let sound = gate.syncFailed(alex, uptime: TimeInterval(pass) * 300) { played.append(sound) }
            if let sound = gate.newMailArrived() { played.append(sound) }
            gate.syncSucceeded(alex)
        }
        XCTAssertEqual(played, [.newMessage, .newMessage, .newMessage])
    }

    func testEachAccountHasItsOwnEpisode() {
        var gate = gate()
        XCTAssertNil(gate.syncFailed(alex, uptime: 0))
        XCTAssertNil(gate.syncFailed(office, uptime: 50))
        XCTAssertEqual(gate.syncFailed(alex, uptime: 60), .syncError)
        XCTAssertNil(gate.syncFailed(office, uptime: 100), "office's episode began at 50")
        gate.syncSucceeded(office)
        XCTAssertNil(gate.syncFailed(alex, uptime: 200), "another account's recovery does not end this one's episode")
        XCTAssertNil(gate.syncFailed(office, uptime: 200))
    }

    func testAPauseEndsAnEpisodeThatHasNotSounded() {
        var gate = gate()
        let now = start
        // A drop begins an episode quietly; the server then asks for a pause of ten minutes.
        XCTAssertNil(gate.hear(.health(accountID: alex, .online), uptime: 0, now: now))
        XCTAssertNil(gate.hear(.health(accountID: alex, .connecting), uptime: 10, now: now))
        XCTAssertNil(gate.hear(.health(accountID: alex, .imapPaused(until: now)), uptime: 20, now: now))
        // The first attempt after it fails: an episode of its own, not one begun at the drop.
        XCTAssertNil(gate.hear(.health(accountID: alex, .offline(since: now)), uptime: 620, now: now))
        XCTAssertNil(gate.hear(.error(accountID: alex, message: "Gmail had a temporary problem. Retrying."), uptime: 620, now: now))
        XCTAssertNil(gate.failureLasted(alex, uptime: 660))
        XCTAssertEqual(gate.failureLasted(alex, uptime: 681), .syncError, "once it has lasted a minute of its own")
    }

    func testAPauseInAnEpisodeThatHasSoundedSoundsNothingTwice() {
        var gate = gate()
        let now = start
        XCTAssertNil(gate.hear(.health(accountID: alex, .online), uptime: 0, now: now))
        XCTAssertNil(gate.hear(.health(accountID: alex, .offline(since: now)), uptime: 10, now: now))
        XCTAssertEqual(gate.failureLasted(alex, uptime: 71), .syncError)
        XCTAssertNil(gate.hear(.health(accountID: alex, .imapPaused(until: now)), uptime: 100, now: now))
        XCTAssertNil(gate.hear(.health(accountID: alex, .offline(since: now)), uptime: 700, now: now))
        XCTAssertNil(gate.failureLasted(alex, uptime: 761), "the same failure, heard of once")
        XCTAssertNil(gate.hear(.finished(accountID: alex), uptime: 800, now: now))
        XCTAssertNil(gate.hear(.health(accountID: alex, .offline(since: now)), uptime: 900, now: now))
        XCTAssertEqual(gate.failureLasted(alex, uptime: 961), .syncError, "a finished sync ended it; this is a new one")
    }

    func testAFailureThatLastsWhileTheSoundIsOffIsNotReplayedWhenItIsTurnedOn() {
        var off: Set<MailSoundEvent> = [.syncError]
        var gate = MailSoundGate { !off.contains($0) }
        XCTAssertEqual(retries(alex, from: 0, on: &gate), [nil, nil, nil, nil])
        off = []
        gate.isEnabled = { !off.contains($0) }
        XCTAssertNil(gate.syncFailed(alex, uptime: 150), "turning the sound on mid-episode does not replay it")
    }

    // MARK: - No new messages only for a check the reader asked for

    func testAManualCheckThatFindsNothingSoundsOnceEveryAccountHasAnswered() {
        var gate = gate()
        gate.manualCheckStarted(accounts: [alex, office], at: start)
        XCTAssertNil(gate.checkFinished(alex, foundNewMail: false, at: start + 2))
        XCTAssertEqual(gate.checkFinished(office, foundNewMail: false, at: start + 3), .noNewMessages)
        XCTAssertNil(gate.checkFinished(office, foundNewMail: false, at: start + 4), "the check is answered only once")
    }

    func testNewMailInAnyAccountKeepsTheCheckQuiet() {
        var gate = gate()
        gate.manualCheckStarted(accounts: [alex, office], at: start)
        XCTAssertNil(gate.checkFinished(alex, foundNewMail: true, at: start + 1))
        XCTAssertNil(gate.checkFinished(office, foundNewMail: false, at: start + 2))
    }

    func testASyncTheAppRunsByItselfNeverSaysNoNewMessages() {
        var gate = gate()
        XCTAssertNil(gate.checkFinished(alex, foundNewMail: false, at: start))
        gate.manualCheckStarted(accounts: [alex], at: start)
        XCTAssertNil(gate.checkFinished(office, foundNewMail: false, at: start + 1), "an account the check did not ask")
        XCTAssertEqual(gate.checkFinished(alex, foundNewMail: false, at: start + 2), .noNewMessages, "still waiting for the one it did")
    }

    func testACheckWithNoAccountToAskIsNoCheck() {
        var gate = gate()
        gate.manualCheckStarted(accounts: [], at: start)
        XCTAssertNil(gate.checkFinished(alex, foundNewMail: false, at: start))
    }

    func testAnAccountThatFailsDuringTheCheckKeepsItQuiet() {
        var gate = gate()
        gate.manualCheckStarted(accounts: [alex, office], at: start)
        XCTAssertNil(gate.syncFailed(alex, uptime: 0))
        XCTAssertNil(gate.checkFinished(office, foundNewMail: false, at: start + 1))
        XCTAssertNil(gate.checkFinished(alex, foundNewMail: false, at: start + 2), "the failed account's own answer comes too late")
    }

    func testTheOnlyAccountFailingEndsTheCheck() {
        var gate = gate()
        gate.manualCheckStarted(accounts: [alex], at: start)
        _ = gate.syncFailed(alex, uptime: 0)
        XCTAssertNil(gate.checkFinished(alex, foundNewMail: false, at: start + 1))
    }

    func testACheckAnsweredTooLateStaysQuiet() {
        var gate = gate()
        gate.manualCheckStarted(accounts: [alex], at: start)
        XCTAssertNil(gate.checkFinished(alex, foundNewMail: false, at: start + MailSoundGate.checkTimeout + 1))
        XCTAssertNil(gate.checkFinished(alex, foundNewMail: false, at: start + MailSoundGate.checkTimeout + 2), "and it is over")
    }

    func testANewCheckReplacesOneStillWaiting() {
        var gate = gate()
        gate.manualCheckStarted(accounts: [alex, office], at: start)
        XCTAssertNil(gate.checkFinished(alex, foundNewMail: true, at: start + 1))
        gate.manualCheckStarted(accounts: [office], at: start + 2)
        XCTAssertEqual(gate.checkFinished(office, foundNewMail: false, at: start + 3), .noNewMessages)
    }

    func testNoNewMessagesTurnedOffKeepsACheckQuiet() {
        var gate = gate(off: [.noNewMessages])
        gate.manualCheckStarted(accounts: [alex], at: start)
        XCTAssertNil(gate.checkFinished(alex, foundNewMail: false, at: start + 1))
    }
}
