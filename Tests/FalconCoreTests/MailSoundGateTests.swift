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
        XCTAssertNil(gate.syncFailed(alex))
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

    // MARK: - one sync error sound per failure episode

    func testOnlyTheFirstFailureOfAnEpisodeSounds() {
        var gate = gate()
        XCTAssertEqual(gate.syncFailed(alex), .syncError)
        XCTAssertNil(gate.syncFailed(alex), "a retry that fails again is the same episode")
        XCTAssertNil(gate.syncFailed(alex))
        gate.syncSucceeded(alex)
        XCTAssertEqual(gate.syncFailed(alex), .syncError, "a finished sync ends the episode")
    }

    func testEachAccountHasItsOwnEpisode() {
        var gate = gate()
        XCTAssertEqual(gate.syncFailed(alex), .syncError)
        XCTAssertEqual(gate.syncFailed(office), .syncError)
        gate.syncSucceeded(office)
        XCTAssertNil(gate.syncFailed(alex), "another account's recovery does not end this one's episode")
    }

    func testAFailureWhileTheSoundIsOffStillStartsTheEpisode() {
        var off: Set<MailSoundEvent> = [.syncError]
        var gate = MailSoundGate { !off.contains($0) }
        XCTAssertNil(gate.syncFailed(alex))
        off = []
        gate.isEnabled = { !off.contains($0) }
        XCTAssertNil(gate.syncFailed(alex), "turning the sound on mid-episode does not replay the episode's start")
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
        XCTAssertEqual(gate.syncFailed(alex), .syncError)
        XCTAssertNil(gate.checkFinished(office, foundNewMail: false, at: start + 1))
        XCTAssertNil(gate.checkFinished(alex, foundNewMail: false, at: start + 2), "the failed account's own answer comes too late")
    }

    func testTheOnlyAccountFailingEndsTheCheck() {
        var gate = gate()
        gate.manualCheckStarted(accounts: [alex], at: start)
        _ = gate.syncFailed(alex)
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
