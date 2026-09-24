import XCTest
@testable import FalconCore

/// Every IMAP byte an account moves is counted over a rolling 24 hours, and what would go past
/// an allowance waits instead.
final class TrafficTests: XCTestCase {
    private let megabyte = 1024 * 1024
    private var root: URL!
    private var harness: EngineHarness?

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("falcon-traffic-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Log.start(in: root)
        _ = StoredFileNotices.take()
    }

    override func tearDown() async throws {
        await harness?.finish()
        try? FileManager.default.removeItem(at: root)
    }

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private var countFile: URL { root.appendingPathComponent("bandwidth.json") }

    // MARK: The count

    func testAFullAllowanceAcrossMidnightIsRefused() {
        let clock = TestClock(date("2026-09-21T23:30:00Z"))
        let meter = TrafficMeter(layout: FileLayout(root: root), now: clock.reading)
        let account = UUID()
        meter.record(down: 1_000 * megabyte, for: account)
        clock.set(date("2026-09-22T00:20:00Z"))
        // A count that began again at midnight would allow 1.8 GB here on top of the 1 GB before it.
        XCTAssertTrue(meter.allows(.download, adding: 800 * megabyte, for: account))
        XCTAssertFalse(meter.allows(.download, adding: 800 * megabyte + 1, for: account))
        meter.record(down: 800 * megabyte, for: account)
        XCTAssertEqual(meter.used(.download, by: account), 1_800 * megabyte)
        XCTAssertFalse(meter.allows(.download, adding: 1, for: account))
        XCTAssertEqual(meter.whenAllows(.download, adding: 1, for: account), date("2026-09-22T23:00:00Z"),
                       "the hour from 23:00 leaves the window 24 hours later")

        clock.set(date("2026-09-22T23:00:01Z"))
        XCTAssertEqual(meter.used(.download, by: account), 800 * megabyte)
        XCTAssertTrue(meter.allows(.download, adding: 1_000 * megabyte, for: account))
    }

    func testEachAccountHasItsOwnCountAndItSurvivesARelaunch() {
        let clock = TestClock(date("2026-09-24T10:15:00Z"))
        let meter = TrafficMeter(layout: FileLayout(root: root), limits: TrafficLimits(background: 1_000, download: 5_000, upload: 2_000),
                                 now: clock.reading)
        let account = UUID()
        let other = UUID()
        meter.record(down: 600, up: 50, background: 600, for: account)
        XCTAssertTrue(meter.allows(.background, adding: 400, for: account))
        XCTAssertFalse(meter.allows(.background, adding: 401, for: account))
        XCTAssertTrue(meter.allows(.background, adding: 1_000, for: other), "one account's use never holds up another")
        XCTAssertTrue(meter.allows(.upload, adding: 50_000, for: other), "something bigger than the allowance goes when nothing else has")

        meter.persist()
        let reopened = TrafficMeter(layout: FileLayout(root: root), limits: TrafficLimits(background: 1_000, download: 5_000, upload: 2_000),
                                    now: clock.reading)
        XCTAssertEqual(reopened.used(.download, by: account), 600)
        XCTAssertEqual(reopened.used(.background, by: account), 600)
        XCTAssertEqual(reopened.used(.upload, by: account), 50)
        XCTAssertEqual(reopened.used(.download, by: other), 0)
    }

    /// What the previous release reads of bandwidth.json.
    private struct EarlierUsage: Codable {
        var day: String
        var bytes: Int
    }

    func testTheEarlierReleaseStillReadsTheCount() throws {
        let clock = TestClock(date("2026-09-23T23:50:00Z"))
        let meter = TrafficMeter(layout: FileLayout(root: root), now: clock.reading)
        let account = UUID()
        meter.record(down: 3_000, for: account)
        clock.set(date("2026-09-24T01:10:00Z"))
        meter.record(down: 7_000, for: account)
        clock.set(date("2026-09-24T01:20:00Z"))
        meter.persist()

        let decoder = JSONDecoder()
        let earlier = try decoder.decode([String: EarlierUsage].self, from: Data(contentsOf: countFile))
        XCTAssertEqual(earlier[account.uuidString]?.day, "2026-09-24")
        XCTAssertEqual(earlier[account.uuidString]?.bytes, 7_000, "today's download since midnight UTC, as it counted")

        // The earlier release writes back only what it knows, and the hours kept beside it are
        // untouched: nothing is lost and nothing counted twice.
        try JSONEncoder().encode(earlier).write(to: countFile)
        let after = TrafficMeter(layout: FileLayout(root: root), now: clock.reading)
        XCTAssertEqual(after.used(.download, by: account), 10_000)
    }

    /// Writes bandwidth.json as the earlier release does, last written at `written`.
    private func writeEarlierCount(_ counts: [UUID: EarlierUsage], written: Date) throws {
        try JSONEncoder().encode(Dictionary(uniqueKeysWithValues: counts.map { ($0.key.uuidString, $0.value) })).write(to: countFile)
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: countFile.path)
    }

    func testACountFromTheEarlierReleaseStaysAFullDay() throws {
        let today = UUID()
        let yesterday = UUID()
        let stale = UUID()
        try writeEarlierCount([today: EarlierUsage(day: "2026-09-24", bytes: 3_998_127),
                               yesterday: EarlierUsage(day: "2026-09-23", bytes: 5_000),
                               stale: EarlierUsage(day: "2026-09-21", bytes: 9_000)],
                              written: date("2026-09-24T17:40:00Z"))
        let clock = TestClock(date("2026-09-24T18:00:00Z"))
        let meter = TrafficMeter(layout: FileLayout(root: root), now: clock.reading)
        XCTAssertEqual(meter.used(.download, by: today), 3_998_127)
        XCTAssertEqual(meter.used(.download, by: yesterday), 5_000, "downloaded by the end of yesterday, perhaps within the last 24 hours")
        XCTAssertEqual(meter.used(.download, by: stale), 0)
        clock.set(date("2026-09-25T00:30:00Z"))
        XCTAssertEqual(meter.used(.download, by: today), 3_998_127, "no longer gone at midnight, when it may be an hour old")
        XCTAssertEqual(meter.used(.download, by: yesterday), 0)
        clock.set(date("2026-09-25T17:00:01Z"))
        XCTAssertEqual(meter.used(.download, by: today), 0, "24 hours after the earlier release last wrote it")
    }

    func testTheHourlyCountOutlivesTheEarlierReleaseRewritingTheFile() throws {
        let clock = TestClock(date("2026-09-24T23:00:00Z"))
        let account = UUID()
        let meter = TrafficMeter(layout: FileLayout(root: root), now: clock.reading)
        meter.record(down: 1_700 * megabyte, for: account)
        meter.persist()

        // The earlier release runs for a moment, downloads a little and saves in its own shape.
        var earlier = try JSONDecoder().decode([String: EarlierUsage].self, from: Data(contentsOf: countFile))
        earlier[account.uuidString]?.bytes += 2 * megabyte
        try writeEarlierCount(Dictionary(uniqueKeysWithValues: earlier.map { (UUID(uuidString: $0.key)!, $0.value) }),
                              written: date("2026-09-24T23:20:00Z"))

        clock.set(date("2026-09-25T00:05:00Z"))
        let after = TrafficMeter(layout: FileLayout(root: root), now: clock.reading)
        XCTAssertEqual(after.used(.download, by: account), 1_702 * megabyte, "this build's hours and what the earlier release added")
        XCTAssertFalse(after.allows(.download, adding: 1_000 * megabyte, for: account), "midnight UTC frees nothing")
        clock.set(date("2026-09-25T23:00:01Z"))
        XCTAssertEqual(after.used(.download, by: account), 0)
    }

    func testAnUndecodableCountIsSetAsideNotWrittenOver() throws {
        let garbage = Data("{\"not\": what was written".utf8)
        try garbage.write(to: countFile)
        let meter = TrafficMeter(layout: FileLayout(root: root))
        meter.record(down: 10, for: UUID())
        meter.persist()
        let aside = AtomicFile.setAsideCopies(of: countFile)
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: aside[0]), garbage)
        XCTAssertTrue(StoredFileNotices.take().contains("the download count"))
    }

    func testAnUndecodableHourlyCountIsSetAsideAndTheDayTotalStillCounts() throws {
        let hoursFile = root.appendingPathComponent("traffic.json")
        let garbage = Data("[{\"hour\": oops".utf8)
        try garbage.write(to: hoursFile)
        let account = UUID()
        try writeEarlierCount([account: EarlierUsage(day: "2026-09-24", bytes: 70_000)], written: date("2026-09-24T09:30:00Z"))
        let clock = TestClock(date("2026-09-24T10:00:00Z"))
        let meter = TrafficMeter(layout: FileLayout(root: root), now: clock.reading)
        XCTAssertEqual(meter.used(.download, by: account), 70_000, "the day's total is counted from bandwidth.json")
        meter.persist()
        let aside = AtomicFile.setAsideCopies(of: hoursFile)
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: aside[0]), garbage)
        XCTAssertTrue(StoredFileNotices.take().contains("the hourly traffic count"))
        let reopened = TrafficMeter(layout: FileLayout(root: root), now: clock.reading)
        XCTAssertEqual(reopened.used(.download, by: account), 70_000, "counted once, not again from both files")
    }

    // MARK: Counting on the wire

    func testHeadersFlagsBodiesAndUploadsAreAllCounted() async throws {
        let server = try EngineHarness.gmailServer()
        for n in 1...8 { server.add(FakeIMAPServer.message("m\(n)"), to: "INBOX") }
        let h = try await EngineHarness(server: server, root: root)
        harness = h
        let id = h.account.id
        XCTAssertEqual(h.meter.used(.download, by: id), 0)

        try await h.syncOnce()
        let listed = server.exchanges
        let headers = listed.filter { $0.line.contains("HEADER.FIELDS") }.reduce(0) { $0 + $1.replyBytes }
        let flags = listed.filter { $0.line.contains("(UID FLAGS)") }.reduce(0) { $0 + $1.replyBytes }
        XCTAssertGreaterThan(headers, 0)
        XCTAssertGreaterThan(flags, 0)
        let afterSync = h.meter.used(.download, by: id)
        XCTAssertGreaterThanOrEqual(afterSync, headers + flags, "headers and flags are counted, not bodies alone")
        XCTAssertLessThanOrEqual(afterSync, server.bytesOut)

        let message = try await h.message(uid: 3, in: "INBOX")
        _ = try await h.syncer.body(for: message)
        let afterOpen = h.meter.used(.download, by: id)
        XCTAssertGreaterThanOrEqual(afterOpen - afterSync, FakeIMAPServer.message("m3").count)

        let upBefore = h.meter.used(.upload, by: id)
        let draft = FakeIMAPServer.message("draft", from: "owner@example.com")
        try await h.syncer.append(raw: draft, to: try await h.folder("INBOX"), flags: [.draft], date: nil)
        XCTAssertGreaterThanOrEqual(h.meter.used(.upload, by: id) - upBefore, draft.count)
    }

    private func archiveRequest(_ h: EngineHarness) throws -> (ArchiveRequest, LocalFolderStorage) {
        let archives = root.appendingPathComponent("Archives")
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
        let request = ArchiveRequest(accountID: h.account.id, folderPaths: ["INBOX"], olderThan: nil, name: "Old mail", password: nil,
                                     removeFromServer: false, parentID: nil)
        return (request, LocalFolderStorage(root: archives))
    }

    func testAnArchiveJobWaitsAtItsAllowanceAndCarriesOnOnANewConnection() async throws {
        let server = try EngineHarness.gmailServer()
        let longAgo = Date(timeIntervalSince1970: 1_600_000_000)
        for n in 1...10 { server.add(FakeIMAPServer.message("old-\(n)"), to: "INBOX", date: longAgo) }
        let clock = TestClock()
        var pacing = SyncPacing()
        pacing.budgetRecheck = 0.05
        let h = try await EngineHarness(server: server, root: root, pacing: pacing,
                                        limits: TrafficLimits(background: 7_000, download: 50_000_000, upload: 50_000_000), clock: clock.reading)
        harness = h
        // What Gmail, something on the way or the Mac's sleep does to a connection left quiet
        // for the hours an allowance can take to come back.
        server.closeAfterSilence(0.6)
        let (request, storage) = try archiveRequest(h)
        let source = h.syncer.archiveSource()
        let account = h.account
        let job = Task { try await ArchiveJob.run(request: request, account: account, source: source, storage: storage) { _ in } }
        func bodiesFetched() -> Int { server.commands.filter { $0.contains("BODY.PEEK[]") }.count }
        await assertEventually { await h.events.progress.contains { $0.contains("has used today's download allowance") } }
        let fetched = bodiesFetched()
        XCTAssertGreaterThan(fetched, 0)
        XCTAssertLessThan(fetched, 10)
        let logins = server.loginCount
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(bodiesFetched(), fetched, "nothing is downloaded while the allowance is spent")
        XCTAssertEqual(server.openConnections, 0, "the job's quiet connection was closed meanwhile")
        XCTAssertGreaterThan(h.meter.used(.background, by: h.account.id), 0, "the archive's connection counts as background")

        clock.advance(25 * 60 * 60)
        let outcome = try await within(10) { try await job.value }
        XCTAssertEqual(outcome.manifest.messageCount, 10, "it carries on where it stopped")
        XCTAssertEqual(bodiesFetched(), 10, "and fetches nothing twice")
        XCTAssertEqual(server.loginCount, logins + 1, "on one new connection")
        await assertEventually { server.openConnections == 0 }
    }

    func testAThrottleMetByAnArchiveJobPausesTheAccountAndTheJobCarriesOnAfterIt() async throws {
        let server = try EngineHarness.gmailServer()
        let longAgo = Date(timeIntervalSince1970: 1_600_000_000)
        for n in 1...10 { server.add(FakeIMAPServer.message("old-\(n)"), to: "INBOX", date: longAgo) }
        var pacing = SyncPacing()
        pacing.budgetRecheck = 0.05
        pacing.throttlePauses = [2, 4, 8, 16]
        let h = try await EngineHarness(server: server, root: root, pacing: pacing)
        harness = h
        let (request, storage) = try archiveRequest(h)
        server.refuseNext("UID FETCH", code: "THROTTLED", text: "Account exceeded command or bandwidth limits. (Failure)")
        let source = h.syncer.archiveSource()
        let account = h.account
        let job = Task { try await ArchiveJob.run(request: request, account: account, source: source, storage: storage) { _ in } }

        await assertEventually { await h.events.pauses.count == 1 }
        let logins = server.loginCount
        do {
            _ = try await h.syncer.openArchiveSourceClient()
            XCTFail("no connection is opened during the pause")
        } catch {
            XCTAssertEqual(MailServiceError.classify(error, account: account).kind, .throttled)
        }
        XCTAssertEqual(server.loginCount, logins, "nothing signs in while Gmail asked for quiet")
        let stored = try XCTUnwrap(AtomicFile.readJSON(SyncExtras.self, from: h.layout.syncExtrasFile(account.id)))
        XCTAssertEqual(stored.imapPauseLevel, 0, "the throttle counts towards the next, longer cool-down")
        XCTAssertNotNil(stored.lastThrottleAt)

        let outcome = try await within(15) { try await job.value }
        XCTAssertEqual(outcome.manifest.messageCount, 10, "the job carries on once the pause is over")
        XCTAssertEqual(server.loginCount, logins + 1)
        await h.settled()
        let pauses = await h.events.pauses
        XCTAssertEqual(pauses.count, 1)
    }

    func testAnImportWaitsForTheUploadAllowanceAndSyncsItsFolderSparingly() async throws {
        let server = try EngineHarness.gmailServer()
        server.addMailbox("Imported")
        server.add(FakeIMAPServer.message("first"), to: "INBOX")
        let clock = TestClock()
        var pacing = SyncPacing()
        pacing.budgetRecheck = 0.05
        pacing.appendSyncSpacing = 1.0
        pacing.fullSyncInterval = 3600
        let h = try await EngineHarness(server: server, root: root, pacing: pacing,
                                        limits: TrafficLimits(background: 50_000_000, download: 50_000_000, upload: 7_000), clock: clock.reading)
        harness = h
        await h.syncer.start()
        await assertEventually { server.idlingCount == 1 }
        let folder = try await h.folder("Imported")
        server.resetCounters()

        let syncer = h.syncer
        let messages = (1...8).map { ImportedMessage(raw: FakeIMAPServer.message("imported-\($0)"), flags: [.seen], date: nil) }
        let importing = Task {
            for m in messages { try await syncer.importMessage(m, into: folder) }
        }
        await assertEventually { await h.events.progress.contains { $0.contains("uploads resume") } }
        let uploaded = server.messages(in: "Imported").count
        XCTAssertGreaterThan(uploaded, 0)
        XCTAssertLessThan(uploaded, 8, "the import waits once the allowance is spent")
        clock.advance(25 * 60 * 60)
        try await within(10) { try await importing.value }
        XCTAssertEqual(server.messages(in: "Imported").count, 8)

        await assertEventually(within: 4) { ((try? await h.uids(in: "Imported")) ?? []).count == 8 }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let selects = server.exchanges.filter { $0.line.contains("SELECT \"Imported\"") }.map(\.at)
        XCTAssertFalse(selects.isEmpty)
        XCTAssertLessThan(selects.count, 8, "not one sync a message")
        for (earlier, later) in zip(selects, selects.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later.timeIntervalSince(earlier), 0.9, "at most one sync of the folder per spacing")
        }
        XCTAssertFalse(server.commands.contains { $0.contains(" LIST ") }, "no pass over the whole account")
    }

    /// An account with a folder "Imported", listed once, and the messages an import brings.
    private func importing(limits: TrafficLimits = .standard, pacing: SyncPacing, clock: TestClock = TestClock())
        async throws -> (EngineHarness, FolderInfo, [ImportedMessage]) {
        let server = try EngineHarness.gmailServer()
        server.addMailbox("Imported")
        let h = try await EngineHarness(server: server, root: root, pacing: pacing, limits: limits, clock: clock.reading)
        harness = h
        try await h.syncOnce()
        let messages = (1...8).map { ImportedMessage(raw: FakeIMAPServer.message("imported-\($0)"), flags: [.seen], date: nil) }
        return (h, try await h.folder("Imported"), messages)
    }

    private func importedIDs(_ server: FakeIMAPServer) -> [String] {
        server.messages(in: "Imported").compactMap { MIMEParser.parseHeaders($0.data).first("Message-ID") }
    }

    func testAnImportCarriesOnOnANewConnectionAfterWaitingForItsAllowance() async throws {
        let clock = TestClock()
        var pacing = SyncPacing()
        pacing.budgetRecheck = 0.05
        let (h, folder, messages) = try await importing(limits: TrafficLimits(background: 50_000_000, download: 50_000_000, upload: 7_000),
                                                        pacing: pacing, clock: clock)
        let server = h.server
        server.closeAfterSilence(0.6)
        let syncer = h.syncer
        let task = Task { for m in messages { try await syncer.importMessage(m, into: folder) } }
        await assertEventually { await h.events.progress.contains { $0.contains("uploads resume") } }
        let before = server.messages(in: "Imported").count
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(server.openConnections, 0, "the op connection was closed while the import waited")

        clock.advance(25 * 60 * 60)
        try await within(10) { try await task.value }
        let ids = importedIDs(server)
        XCTAssertGreaterThan(before, 0)
        XCTAssertEqual(ids.count, 8, "the rest of the file went in after the wait")
        XCTAssertEqual(Set(ids).count, 8, "and none twice")
    }

    func testAThrottleDuringAnImportWaitsOutItsPauseAndLosesNothing() async throws {
        var pacing = SyncPacing()
        pacing.budgetRecheck = 0.05
        pacing.throttlePauses = [1, 2, 4, 8]
        let (h, folder, messages) = try await importing(pacing: pacing)
        let server = h.server
        server.refuseNext("APPEND", code: "THROTTLED", text: "Account exceeded command or bandwidth limits. (Failure)")
        let syncer = h.syncer
        try await within(15) { for m in messages { try await syncer.importMessage(m, into: folder) } }
        let ids = importedIDs(server)
        XCTAssertEqual(ids.count, 8, "the refused message went in once the pause was over")
        XCTAssertEqual(Set(ids).count, 8)
        await h.settled()
        let pauses = await h.events.pauses
        XCTAssertEqual(pauses.count, 1, "the account paused, as for a throttle on any connection")
    }

    func testAnImportThatMeetsTheConnectionLimitWaitsForItAndLosesNothing() async throws {
        var pacing = SyncPacing()
        pacing.budgetRecheck = 0.05
        pacing.minimumReconnectInterval = 0.05
        pacing.connectionLimitWait = 0.8...0.8
        let (h, folder, messages) = try await importing(pacing: pacing)
        let server = h.server
        let logins = server.loginCount
        // The op connection is not open yet, and the server has none to spare.
        server.greetWithBye("Too many simultaneous connections. (Failure)")
        let refused = Date()
        let syncer = h.syncer
        try await within(15) { for m in messages { try await syncer.importMessage(m, into: folder) } }
        let ids = importedIDs(server)
        XCTAssertEqual(ids.count, 8, "every message went in once a connection could be opened")
        XCTAssertEqual(Set(ids).count, 8)
        let signIn = try XCTUnwrap(server.exchanges.last { $0.line.contains("AUTHENTICATE") || $0.line.contains(" LOGIN ") })
        XCTAssertGreaterThanOrEqual(signIn.at.timeIntervalSince(refused), 0.75, "no connection was opened before the limit passed")
        XCTAssertEqual(server.loginCount, logins + 1, "one connection, for them all")
    }

    func testAnArchiveJobThatMeetsTheConnectionLimitWaitsForItAndCarriesOn() async throws {
        let server = try EngineHarness.gmailServer()
        let longAgo = Date(timeIntervalSince1970: 1_600_000_000)
        for n in 1...10 { server.add(FakeIMAPServer.message("old-\(n)"), to: "INBOX", date: longAgo) }
        var pacing = SyncPacing()
        pacing.budgetRecheck = 0.05
        pacing.connectionLimitWait = 0.8...0.8
        let h = try await EngineHarness(server: server, root: root, pacing: pacing)
        harness = h
        let (request, storage) = try archiveRequest(h)
        server.greetWithBye("Too many simultaneous connections. (Failure)")
        let refused = Date()
        let source = h.syncer.archiveSource()
        let account = h.account
        let outcome = try await within(15) {
            try await ArchiveJob.run(request: request, account: account, source: source, storage: storage) { _ in }
        }
        XCTAssertEqual(outcome.manifest.messageCount, 10, "the job carries on once a connection can be opened")
        let signIn = try XCTUnwrap(server.exchanges.first { $0.line.contains("AUTHENTICATE") || $0.line.contains(" LOGIN ") })
        XCTAssertGreaterThanOrEqual(signIn.at.timeIntervalSince(refused), 0.75, "and not before the limit passed")
        XCTAssertEqual(server.loginCount, 1)
    }

    func testAnAppendWhoseAnswerNeverCameIsNotSentAgain() async throws {
        var pacing = SyncPacing()
        pacing.minimumReconnectInterval = 0.05
        let (h, folder, messages) = try await importing(pacing: pacing)
        let server = h.server
        // The connection drops once the message is on its way: the server may have stored it.
        server.loseNextAppendReply()
        do {
            try await h.syncer.importMessage(messages[0], into: folder)
            XCTFail("its fate is unknown, so it is not tried again")
        } catch {
            XCTAssertEqual(MailServiceError.classify(error, account: h.account).kind, .connectionDropped)
        }
        XCTAssertEqual(importedIDs(server).count, 1, "stored once, never twice")
    }
}
