import XCTest
@testable import FalconCore

/// What the engine tells the app (§4.7), and what `MailSoundGate` then plays: every row of the
/// design's table, and a short wait Google asks for changing nothing at all.
final class GmailSoundEventTests: XCTestCase {
    private func listedRig(_ gmail: MemoryGmailTransport, clock: ManualGmailClock) async -> GmailEngineRig {
        let start = clock.now()
        for i in 0..<10 { gmail.add(subject: "Old \(i)", labels: [.inbox], date: start.addingTimeInterval(-Double(10 - i) * 86_400)) }
        let rig = GmailEngineRig(transport: gmail, clock: clock)
        await rig.engine.runBackfill()
        _ = await rig.engine.check(reason: .schedule)
        rig.events.clear()
        return rig
    }

    /// Feeds what the engine said to a sound gate, as the app does, with time since `start` as the
    /// uptime; returns what it played.
    private func sounds(_ events: [SyncEvent], gate: inout MailSoundGate, start: Date, clock: ManualGmailClock) -> [MailSoundEvent] {
        events.compactMap { gate.hear($0, uptime: clock.now().timeIntervalSince(start), now: clock.now()) }
    }

    private func gate() -> MailSoundGate { MailSoundGate(isEnabled: { _ in true }) }

    // MARK: - New mail and Send & Receive

    func testNewMailInTheInboxGoesOutAsTheIMAPEngineSendsIt() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let rig = await listedRig(gmail, clock: clock)
        clock.advance(by: 30)
        let fresh = gmail.add(subject: "Quote for Friday", from: "Ana <ana@example.com>", labels: [.inbox, .unread], date: clock.now(),
                              thread: nil)
        _ = await rig.engine.check(reason: .schedule)
        XCTAssertEqual(rig.events.names, ["newMessages(1)", "finished"])
        guard case .newMessages(let account, let folder, let messages)? = rig.events.events.first else { return XCTFail("no new mail event") }
        let inbox = await rig.engine.folders().first { $0.role == .inbox }
        XCTAssertEqual(account, rig.account.id)
        XCTAssertEqual(folder, inbox?.id, "the Inbox's own folder id, so the per-account setting and the sound work unchanged")
        let summary = try XCTUnwrap(messages.first)
        XCTAssertEqual(summary.id, RowKey.gmail(account: rig.account.id, id: fresh.id).stringValue)
        XCTAssertEqual(summary.gmailID, fresh.id)
        XCTAssertEqual(summary.threadKey, fresh.threadID.threadKey)
        XCTAssertEqual(summary.subject, "Quote for Friday")
        XCTAssertEqual(summary.from.address, "ana@example.com")
        XCTAssertFalse(summary.isRead)
        XCTAssertEqual(summary.labelIDs, [.inbox, .unread])
        XCTAssertEqual(gate().newMailArrived(), .newMessage)
        await rig.finish()
    }

    func testMailFromTheOwnerOrOutsideTheInboxIsNotAnnounced() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let rig = await listedRig(gmail, clock: clock)
        clock.advance(by: 30)
        gmail.add(subject: "My own", from: "Owner <owner@example.com>", labels: [.inbox], date: clock.now())
        gmail.add(subject: "Spam", labels: [.spam, .unread], date: clock.now())
        gmail.add(subject: "Filed", labels: [.unread], date: clock.now())
        let muted = gmail.add(subject: "Muted thread", labels: [.inbox, .unread], date: clock.now())
        let mutedRig = GmailEngineRig(transport: gmail, store: rig.store, clock: clock,
                                      muted: { $0.gmailThreadID == muted.threadID }, directory: rig.directory)
        let report = await mutedRig.engine.check(reason: .schedule)
        XCTAssertEqual(report.arrivals.count, 4, "all four arrived now")
        XCTAssertTrue(mutedRig.events.announced.isEmpty, "none is announced: \(mutedRig.events.announcedSubjects)")
        await mutedRig.finish()
    }

    func testSendAndReceiveSaysWhetherItFoundNewMail() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let rig = await listedRig(gmail, clock: clock)
        let start = clock.now()
        var quiet = gate()
        quiet.manualCheckStarted(accounts: [rig.account.id], at: clock.now())
        _ = await rig.engine.check(reason: .sendAndReceive)
        XCTAssertEqual(rig.events.names, ["started", "finished", "checked(false)"])
        XCTAssertEqual(sounds(rig.events.events, gate: &quiet, start: start, clock: clock), [.noNewMessages])

        rig.events.clear()
        clock.advance(by: 30)
        gmail.add(subject: "Fresh", labels: [.inbox, .unread], date: clock.now())
        var busy = gate()
        busy.manualCheckStarted(accounts: [rig.account.id], at: clock.now())
        _ = await rig.engine.check(reason: .sendAndReceive)
        XCTAssertEqual(rig.events.names, ["started", "newMessages(1)", "finished", "checked(true)"])
        XCTAssertEqual(sounds(rig.events.events, gate: &busy, start: start, clock: clock), [], "no No new messages after new mail")
        await rig.finish()
    }

    func testOnlySendAndReceiveAndWakingSayTheyStarted() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let rig = await listedRig(gmail, clock: clock)
        for reason in [PokeReason.schedule, .networkChange, .changeCommitted] {
            _ = await rig.engine.check(reason: reason)
        }
        XCTAssertEqual(rig.events.names, [], "a check every half minute never makes the status line flicker")
        _ = await rig.engine.check(reason: .wake)
        XCTAssertEqual(rig.events.names, ["started", "finished"])
        await rig.finish()
    }

    func testProgressInTheStatusBarAlwaysEnds() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        for i in 0..<5 { gmail.add(subject: "Old \(i)", labels: [.inbox], date: clock.now().addingTimeInterval(-Double(5 - i) * 86_400)) }
        let rig = GmailEngineRig(transport: gmail, clock: clock)
        await rig.engine.runBackfill()
        func progressEnds(_ events: [SyncEvent]) -> Bool {
            guard let last = events.lastIndex(where: { if case .progress = $0 { return true } else { return false } }) else { return false }
            return events[(last + 1)...].contains { if case .finished = $0 { return true } else { return false } }
        }
        XCTAssertTrue(progressEnds(rig.events.events), "the first listing's progress ends with finished")
        rig.events.clear()
        gmail.relabel(try XCTUnwrap(gmail.messages.first?.ref.id), adding: [.starred])
        gmail.expireHistory()
        _ = await rig.engine.check(reason: .schedule)
        await rig.engine.relistTask?.value
        XCTAssertTrue(progressEnds(rig.events.events), "and so does a resync's")
        await rig.finish()
    }

    // MARK: - Failures

    func testAFailedCheckIsQuietThenOfflineAfterTwoMinutesThenRecovers() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let rig = await listedRig(gmail, clock: clock)
        let start = clock.now()
        var sounds = gate()
        // The gate has heard the account online.
        _ = sounds.hear(.health(accountID: rig.account.id, .online), uptime: 0, now: start)
        let failingSince = clock.now()
        gmail.failAlways(.historyList, with: GoogleAPIError(kind: .temporary, httpStatus: 503, reason: "backendError"))
        _ = await rig.engine.check(reason: .schedule)
        XCTAssertEqual(rig.events.names, ["health(connecting)"], "one failed check is quiet")
        XCTAssertEqual(self.sounds(rig.events.events, gate: &sounds, start: start, clock: clock), [])
        rig.events.clear()
        clock.advance(by: 60)
        _ = await rig.engine.check(reason: .schedule)
        XCTAssertEqual(rig.events.names, [], "still quiet within the two minutes")
        clock.advance(by: 60)
        _ = await rig.engine.check(reason: .schedule)
        XCTAssertEqual(rig.events.healths, [.offline(since: failingSince)])
        XCTAssertEqual(rig.events.errors, ["Reconnecting to owner@example.com…"])
        XCTAssertEqual(self.sounds(rig.events.events, gate: &sounds, start: start, clock: clock), [.syncError],
                       "Mailbox sync error, once the episode has lasted a minute")
        rig.events.clear()
        gmail.failAlways(.historyList, with: nil)
        clock.advance(by: 30)
        _ = await rig.engine.check(reason: .schedule)
        XCTAssertEqual(rig.events.names, ["health(online)", "finished"], "a check that recovers says so and ends the episode")
        XCTAssertEqual(self.sounds(rig.events.events, gate: &sounds, start: start, clock: clock), [])
        await rig.finish()
    }

    func testOfflineSaysTheMailOnThisMacStaysAvailable() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let rig = await listedRig(gmail, clock: clock)
        gmail.failAlways(.historyList, with: GoogleAPIError(kind: .offline, detail: "URLError -1009"))
        _ = await rig.engine.check(reason: .schedule)
        clock.advance(by: 125)
        _ = await rig.engine.check(reason: .schedule)
        XCTAssertEqual(rig.events.errors, ["Offline — showing the messages kept on this Mac."])
        let offline = await rig.engine.schedule.offline
        XCTAssertTrue(offline)
        let next = await rig.engine.schedule.nextCheck(after: clock.now())
        XCTAssertEqual(next, clock.now().addingTimeInterval(120), "offline checks cost nothing, so one runs now and then")
        await rig.finish()
    }

    func testASignInOrABlockSaysSoAtOnceAndStopsOrSlowsTheChecks() async throws {
        let cases: [(GoogleAPIError, AccountHealth, String, TimeInterval?)] = [
            (GoogleAPIError(kind: .needsSignIn, httpStatus: 401), .needsSignIn, "owner@example.com needs you to sign in again.", nil),
            (GoogleAPIError(kind: .insufficientPermissions, httpStatus: 403, reason: "insufficientPermissions"), .needsSignIn,
             "FalconMail needs permission to read and send mail for owner@example.com. Sign in again and leave every box ticked.", nil),
            (GoogleAPIError(kind: .domainPolicy, httpStatus: 403, reason: "domainPolicy"),
             .blocked(reason: "The Workspace administrator has turned off Gmail access for apps like FalconMail for owner@example.com."),
             "The Workspace administrator has turned off Gmail access for apps like FalconMail for owner@example.com.", 3_600),
            (GoogleAPIError(kind: .gmailNotEnabled, httpStatus: 400, reason: "failedPrecondition"),
             .blocked(reason: "Gmail isn't turned on for owner@example.com."), "Gmail isn't turned on for owner@example.com.", 3_600),
            (GoogleAPIError(kind: .apiDisabled, httpStatus: 403, reason: "accessNotConfigured"),
             .blocked(reason: "Gmail API is off for this build's Google project."), "Gmail API is off for this build's Google project.", 600),
            (GoogleAPIError(kind: .clientRejected, reason: "admin_policy_enforced"),
             .blocked(reason: "Google didn't accept FalconMail's sign-in for owner@example.com. Sign in again; if it keeps happening, the Workspace administrator may need to allow FalconMail."),
             "Google didn't accept FalconMail's sign-in for owner@example.com. Sign in again; if it keeps happening, the Workspace administrator may need to allow FalconMail.",
             3_600),
        ]
        for (error, health, sentence, recheck) in cases {
            let clock = ManualGmailClock()
            let gmail = MemoryGmailTransport()
            let rig = await listedRig(gmail, clock: clock)
            let start = clock.now()
            var sounds = gate()
            rig.transport.fail(.historyList, with: error)
            _ = await rig.engine.check(reason: .schedule)
            XCTAssertEqual(rig.events.healths, [health], "\(error.kind)")
            XCTAssertEqual(rig.events.errors, [sentence])
            let next = await rig.engine.schedule.nextCheck(after: clock.now())
            if let recheck {
                XCTAssertEqual(next, clock.now().addingTimeInterval(recheck), "\(error.kind) is looked at again later")
            } else {
                XCTAssertNil(next, "nothing is checked until the owner signs in again")
            }
            XCTAssertEqual(self.sounds(rig.events.events, gate: &sounds, start: start, clock: clock), [])
            clock.advance(by: 61)
            XCTAssertEqual(sounds.failureLasted(rig.account.id, uptime: clock.now().timeIntervalSince(start)), .syncError)
            await rig.finish()
        }
    }

    // MARK: - Pauses

    func testAThirtySecondRetryAfterChangesNoHealthState() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let rig = await listedRig(gmail, clock: clock)
        rig.transport.fail(.historyList, with: GoogleAPIError(kind: .rateLimited, httpStatus: 429, retryAfter: 30))
        let failed = await rig.engine.check(reason: .schedule)
        XCTAssertEqual(failed.failure?.kind, .rateLimited)
        XCTAssertEqual(rig.events.names, [], "a short wait says nothing: the account stays online")
        let next = await rig.engine.schedule.nextCheck(after: clock.now())
        XCTAssertEqual(next, clock.now().addingTimeInterval(30), "nothing is asked of Gmail before the time it gave")
        let asked = gmail.attempts[.historyList] ?? 0
        let early = await rig.engine.check(reason: .sendAndReceive)
        XCTAssertTrue(early.skipped)
        XCTAssertEqual(gmail.attempts[.historyList] ?? 0, asked, "not even for Send & Receive")
        clock.advance(by: 30)
        _ = await rig.engine.check(reason: .schedule)
        XCTAssertEqual(rig.events.names, [], "and nothing when it is over")
        await rig.finish()
    }

    func testAWaitOfMoreThanAMinuteIsAPauseNotAFailure() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let rig = await listedRig(gmail, clock: clock)
        let start = clock.now()
        var sounds = gate()
        _ = sounds.hear(.health(accountID: rig.account.id, .online), uptime: 0, now: start)
        sounds.manualCheckStarted(accounts: [rig.account.id], at: clock.now())
        rig.transport.fail(.historyList, with: GoogleAPIError(kind: .rateLimited, httpStatus: 429, retryAfter: 90))
        _ = await rig.engine.check(reason: .sendAndReceive)
        let until = clock.now().addingTimeInterval(90)
        XCTAssertEqual(rig.events.healths, [.apiPaused(until: until)])
        XCTAssertEqual(rig.events.errors, ["Waiting a moment before loading more of owner@example.com's messages."])
        XCTAssertEqual(self.sounds(rig.events.events, gate: &sounds, start: start, clock: clock), [],
                       "no sync error, and no No new messages for a check the pause cut short")
        XCTAssertFalse(AccountHealth.apiPaused(until: until).isFailing)
        XCTAssertTrue(AccountHealth.apiPaused(until: until).staysConnected)
        clock.advance(by: 91)
        rig.events.clear()
        _ = await rig.engine.check(reason: .schedule)
        XCTAssertEqual(rig.events.names, ["health(online)", "finished"])
        await rig.finish()
    }

    func testShortWaitsThatAddUpToMoreThanAMinuteArePaused() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let rig = await listedRig(gmail, clock: clock)
        for _ in 0..<3 {
            rig.transport.fail(.historyList, with: GoogleAPIError(kind: .rateLimited, httpStatus: 429, retryAfter: 25))
            _ = await rig.engine.check(reason: .schedule)
            clock.advance(by: 25)
        }
        XCTAssertEqual(rig.events.healths.count, 1)
        if case .apiPaused? = rig.events.healths.first {} else { XCTFail("paused once the waits have lasted a minute") }
        await rig.finish()
    }

    func testADailyCapAndABandwidthLimitSaySoInTheirOwnWords() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let rig = await listedRig(gmail, clock: clock)
        rig.transport.fail(.historyList, with: GoogleAPIError(kind: .quotaExhausted, httpStatus: 403, reason: "dailyLimitExceeded"))
        _ = await rig.engine.check(reason: .schedule)
        let midnight = GoogleAPIError.quotaReset(after: clock.now())
        XCTAssertEqual(rig.events.healths, [.apiPaused(until: midnight)])
        XCTAssertEqual(rig.events.errors,
                       ["Today's Gmail allowance for FalconMail is used up until \(GoogleAPIError.timeText(midnight)). Mail on this Mac stays available; changes you make are sent then."])
        let next = await rig.engine.schedule.nextCheck(after: clock.now())
        XCTAssertEqual(next, midnight, "held until midnight Pacific")

        let other = await listedRig(MemoryGmailTransport(), clock: clock)
        other.transport.fail(.historyList, with: GoogleAPIError(kind: .downloadLimit, httpStatus: 429, retryAfter: 3_600))
        _ = await other.engine.check(reason: .schedule)
        let until = clock.now().addingTimeInterval(3_600)
        XCTAssertEqual(other.events.errors,
                       ["FalconMail has paused downloading older mail for owner@example.com until \(GoogleAPIError.timeText(until)), to stay within Gmail's daily limit. New mail still arrives."])
        await rig.finish()
        await other.finish()
    }

    // MARK: - A message going out, and diagnostics

    func testAMessageGoingOutIsLookedForTwoAndTenSecondsLater() async throws {
        let clock = ManualGmailClock()
        let gmail = MemoryGmailTransport()
        let rig = await listedRig(gmail, clock: clock)
        let report = await rig.engine.check(reason: .messageSent)
        XCTAssertTrue(report.skipped, "not at once: Gmail files it a moment later")
        let first = await rig.engine.schedule.nextCheck(after: clock.now())
        XCTAssertEqual(first, clock.now().addingTimeInterval(2))
        clock.advance(by: 2)
        _ = await rig.engine.check(reason: .schedule)
        let second = await rig.engine.schedule.nextCheck(after: clock.now())
        XCTAssertEqual(second, clock.now().addingTimeInterval(8))
        await rig.finish()
    }

    func testDiagnosticsNameWhatTheEngineDidInPlainWords() {
        func title(_ code: String) -> String { DiagnosticsTitle.make(kind: .warning, area: "gmail", code: code) }
        XCTAssertEqual(title("historyExpired"), "Gmail's change list had expired, so FalconMail listed the mailbox again")
        XCTAssertEqual(title("rateLimited"), "Gmail asked FalconMail to slow down")
        XCTAssertEqual(title("imapBlocked"), "FalconMail tried to use IMAP for a Google account and was stopped")
        XCTAssertEqual(title("imapUsed"), "A Google account still uses IMAP")
        XCTAssertEqual(title("uploadPaused"), "Gmail paused uploads for an account")
        XCTAssertEqual(title("floodMode"), "Another app was importing into a Google account, so FalconMail used less of Gmail's budget")
        XCTAssertEqual(title("resync"), "FalconMail listed a Google account's mailbox again")
        for kind: GoogleAPIError.Kind in [.rateLimited, .quotaExhausted, .apiDisabled, .insufficientPermissions, .needsSignIn, .clientRejected,
                                          .notFound, .temporary, .offline, .historyExpired, .domainPolicy, .gmailNotEnabled, .sendingLimit,
                                          .downloadLimit, .uploadLimit, .tooLarge, .other] {
            XCTAssertFalse(title(kind.rawValue).hasPrefix("Checking for new mail failed: something unexpected"), "\(kind) has a title of its own")
        }
        XCTAssertEqual(AccountHealth.apiPaused(until: Date()).diagnosticsName, "apiPaused")
    }
}
