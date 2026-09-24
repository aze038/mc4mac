import XCTest
@testable import FalconCore

final class DiagnosticsCenterTests: XCTestCase {
    private var directory: URL!
    private var crashes: URL!
    private var centers: [DiagnosticsCenter] = []

    override func setUp() {
        directory = DiagnosticsFixtures.temporaryDirectory("center")
        crashes = DiagnosticsFixtures.temporaryDirectory("reports")
        // Warnings and errors also go to the local log file, which tests must not write.
        Log.isEnabled = false
        FakeDiagnosticsServer.reset()
    }

    override func tearDown() {
        centers.forEach { $0.stop() }
        centers = []
        Log.observer = nil
        Log.isEnabled = true
        FakeDiagnosticsServer.reset()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: crashes)
    }

    private func makeCenter(gate: DiagnosticsGate = DiagnosticsFixtures.gate(), clock: DiagnosticsClock = ManualClock(),
                            in folder: URL? = nil) -> DiagnosticsCenter {
        let center = DiagnosticsCenter(directory: folder ?? directory, gate: gate, environment: DiagnosticsFixtures.environment(),
                                       crashReportsDirectory: crashes, session: FakeDiagnosticsServer.session(), clock: clock,
                                       random: { 0.5 })
        centers.append(center)
        return center
    }

    private func throttled(_ account: AccountInfo? = nil) {
        let error = FalconError.network("server closed session: Account exceeded command or bandwidth limits.")
        Log.error("IMAP", "ana@workspace.example: \(error.localizedDescription)", error: error, account: account)
    }

    // MARK: Capture

    func testWarningsAndErrorsBecomeRedactedEventsAndInfoStaysLocal() throws {
        let center = makeCenter()
        center.start()
        let account = AccountInfo.google(email: "ana@workspace.example", displayName: "Ana Lima")
        Log.info("sync", "ana@workspace.example: 12 new messages")
        throttled(account)
        Log.warning("Alert", #"Could not save "Lunch with Ana" to Drafts"#)
        center.waitUntilIdle()

        let events = center.pendingRecords.map(\.event)
        XCTAssertEqual(events.map(\.kind), [.launch, .error, .warning], "the info line is not an event")
        let imap = events[1]
        XCTAssertTrue(imap.signature.hasPrefix("IMAP.throttled@DiagnosticsCenterTests.swift:"), imap.signature)
        XCTAssertEqual(imap.title, "The mail server paused the connection: too many requests")
        XCTAssertEqual(imap.area, "IMAP")
        XCTAssertEqual(imap.account?.provider, "google")
        XCTAssertEqual(imap.account?.kind, "workspace")
        XCTAssertEqual(imap.account?.host, "imap.gmail.com")
        XCTAssertEqual(imap.account?.ref.count, 8)
        XCTAssertEqual(imap.context["errorType"], .string("FalconError"))
        XCTAssertTrue(imap.message.contains("<addr:\(imap.account!.ref)>"), "the message's reference matches the account's")
        XCTAssertTrue(events[2].title.hasPrefix("FalconMail showed an error"))

        let everything = center.pendingDescription()
        XCTAssertFalse(everything.contains("ana@"))
        XCTAssertFalse(everything.contains("Ana"))
        XCTAssertFalse(everything.contains("Lunch"))
        XCTAssertFalse(everything.contains("ingest-key"))
        XCTAssertTrue(everything.contains(center.installID))
    }

    func testRepeatedErrorsFoldIntoOneEvent() {
        let center = makeCenter()
        center.start()
        for _ in 0..<5 { throttled() }
        center.waitUntilIdle()
        let imap = center.pendingRecords.map(\.event).filter { $0.area == "IMAP" }
        XCTAssertEqual(imap.count, 1)
        XCTAssertEqual(imap.first?.count, 5)
    }

    // MARK: Gating

    func testBuildsThatMayNotSendNeverCaptureOrUpload() async {
        FakeDiagnosticsServer.respond { _, _ in DiagnosticsFixtures.okReply }
        let gates: [(String, DiagnosticsGate)] = [
            ("Debug", DiagnosticsFixtures.gate(release: false)),
            ("snapshot", DiagnosticsFixtures.gate(bundle: "com.falconmail.app.snapshot")),
            ("tests", DiagnosticsFixtures.gate(bundle: nil)),
            ("no URL", DiagnosticsFixtures.gate(endpoint: nil)),
            ("no key", DiagnosticsFixtures.gate(key: " ")),
            ("plain http", DiagnosticsFixtures.gate(endpoint: URL(string: "http://script.example.invalid/exec")!)),
            ("switched off", DiagnosticsFixtures.gate(enabled: false)),
        ]
        for (name, gate) in gates {
            let folder = DiagnosticsFixtures.temporaryDirectory("gate")
            defer { try? FileManager.default.removeItem(at: folder) }
            let center = makeCenter(gate: gate, in: folder)
            center.start()
            throttled()
            center.ingestMetricKit(Data(MetricKitDiagnosticsTests.payload.utf8))
            center.waitUntilIdle()
            let outcome = await center.uploadNow()
            XCTAssertEqual(outcome, .notAllowed, name)
            XCTAssertEqual(center.pendingCount, 0, name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("queue.jsonl").path), name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("session.marker").path), name)
            center.stop()
        }
        XCTAssertTrue(FakeDiagnosticsServer.requests.isEmpty)
    }

    func testSwitchingOffDeletesTheQueueAndStopsUploads() async {
        FakeDiagnosticsServer.respond { _, _ in DiagnosticsFixtures.okReply }
        let center = makeCenter()
        center.start()
        throttled()
        center.waitUntilIdle()
        let queueFile = directory.appendingPathComponent("queue.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: queueFile.path))

        center.setEnabled(false)
        center.waitUntilIdle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: queueFile.path))
        XCTAssertEqual(center.pendingCount, 0)
        throttled()
        center.waitUntilIdle()
        let outcome = await center.uploadNow()
        XCTAssertEqual(outcome, .notAllowed)
        XCTAssertEqual(center.pendingCount, 0)
        XCTAssertTrue(FakeDiagnosticsServer.requests.isEmpty)

        center.setEnabled(true)
        throttled()
        center.waitUntilIdle()
        XCTAssertEqual(center.pendingCount, 1, "capturing again from when it was switched back on")
    }

    func testLaunchingSwitchedOffDeletesWhatWasLeft() {
        let leftover = DiagnosticsQueue(url: directory.appendingPathComponent("queue.jsonl"))
        leftover.add(DiagnosticsFixtures.record(DiagnosticsFixtures.event()))
        let center = makeCenter(gate: DiagnosticsFixtures.gate(enabled: false))
        center.start()
        center.waitUntilIdle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("queue.jsonl").path))
    }

    // MARK: Uploading

    func testEventsLeaveTheQueueOnlyAfterSuccess() async {
        let clock = ManualClock()
        let center = makeCenter(clock: clock)
        center.start()
        throttled()
        center.waitUntilIdle()
        let waiting = center.pendingRecords.map(\.event.id)

        FakeDiagnosticsServer.respond { _, _ in .json(#"{"ok":false,"error":"sheet is full"}"#) }
        let failed = await center.uploadNow()
        XCTAssertEqual(failed, .failed(.refused("sheet is full")))
        XCTAssertEqual(center.pendingRecords.map(\.event.id), waiting)
        XCTAssertTrue(center.pendingRecords.allSatisfy(\.sealed))
        XCTAssertEqual(center.nextUploadDate, clock.now().addingTimeInterval(120), "first backoff, jitter in the middle")

        FakeDiagnosticsServer.respond { _, _ in .json(#"{"ok":true}"#, status: 503) }
        _ = await center.uploadNow()
        XCTAssertEqual(center.nextUploadDate, clock.now().addingTimeInterval(240), "twice as long")
        XCTAssertEqual(center.pendingCount, waiting.count)

        FakeDiagnosticsServer.respond { _, _ in DiagnosticsFixtures.okReply }
        let sent = await center.uploadNow()
        XCTAssertEqual(sent, .sent(events: waiting.count, duplicates: 0))
        XCTAssertEqual(center.pendingCount, 0)
        XCTAssertEqual(center.nextUploadDate, clock.now().addingTimeInterval(3_600))
        let nothing = await center.uploadNow()
        XCTAssertEqual(nothing, .nothingToSend)
    }

    func testResendAfterALostReplyIsDuplicateSafe() async throws {
        let center = makeCenter()
        center.start()
        throttled()
        center.waitUntilIdle()

        let stored = Locked<Set<String>>([])
        let attempts = Locked<[[String]]>([])
        FakeDiagnosticsServer.respond { _, body in
            let ids = DiagnosticsFixtures.uploadedEvents(body).compactMap { $0["id"] as? String }
            let duplicates = stored.mutate { set in
                let d = ids.filter(set.contains).count
                set.formUnion(ids)
                return d
            }
            let attempt = attempts.mutate { list -> Int in
                list.append(ids)
                return list.count
            }
            // The first time the server stores the rows but the reply never arrives.
            return attempt == 1 ? .json("", status: 502) : .json(#"{"ok":true,"accepted":\#(ids.count - duplicates),"duplicates":\#(duplicates)}"#)
        }
        _ = await center.uploadNow()
        throttled()
        center.waitUntilIdle()
        XCTAssertEqual(center.pendingCount, 3, "a new occurrence is not folded into what was already sent")

        let outcome = await center.uploadNow()
        XCTAssertEqual(outcome, .sent(events: 3, duplicates: 2))
        let sent = attempts.value
        XCTAssertEqual(Array(sent[1].prefix(2)), sent[0], "the same events go again under the same IDs")
        XCTAssertEqual(center.pendingCount, 0)
    }

    func testOfflineTriesAgainSoonWithoutBackingOff() async {
        let clock = ManualClock()
        let center = makeCenter(clock: clock)
        center.start()
        FakeDiagnosticsServer.respond { _, _ in nil }
        let outcome = await center.uploadNow()
        XCTAssertEqual(outcome, .failed(.offline))
        XCTAssertEqual(center.nextUploadDate, clock.now().addingTimeInterval(600))
        XCTAssertEqual(center.pendingCount, 1)
    }

    func testLargeQueuesGoInBatchesAndAFailureKeepsTheRest() async {
        let center = makeCenter()
        center.start()
        for i in 0..<450 { Log.error("Area\(String(repeating: "x", count: i % 50))", "failure", file: "F.swift", line: i) }
        center.waitUntilIdle()
        let total = center.pendingCount
        XCTAssertEqual(total, 451)

        let posts = Locked(0)
        FakeDiagnosticsServer.respond { _, _ in
            posts.mutate { $0 += 1; return $0 } == 2 ? .json("", status: 500) : DiagnosticsFixtures.okReply
        }
        let outcome = await center.uploadNow()
        XCTAssertEqual(outcome, .failed(.http(500)))
        XCTAssertEqual(center.pendingCount, total - 200, "the confirmed batch is gone, the rest wait")
        XCTAssertEqual(DiagnosticsFixtures.uploadedEvents(FakeDiagnosticsServer.requests[0].body).count, 200)

        let retry = await center.uploadNow()
        XCTAssertEqual(retry, .sent(events: total - 200, duplicates: 0))
        XCTAssertEqual(center.pendingCount, 0)
    }

    func testTheLoopUploadsAMinuteAfterLaunchThenHourly() {
        FakeDiagnosticsServer.respond { _, _ in DiagnosticsFixtures.okReply }
        let clock = ManualClock()
        let center = makeCenter(clock: clock)
        center.start()
        waitUntil { clock.sleepsRequested.count == 1 }
        XCTAssertEqual(clock.sleepsRequested.first, 60)
        XCTAssertTrue(FakeDiagnosticsServer.requests.isEmpty)

        clock.advance(by: 60)
        waitUntil { clock.sleepsRequested.count == 2 }
        XCTAssertEqual(FakeDiagnosticsServer.requests.count, 1)
        XCTAssertEqual(clock.sleepsRequested.last, 3_600)
        XCTAssertEqual(center.pendingCount, 0)
    }

    // MARK: Launches and health

    func testLaunchMarkerTellsCleanFromUncleanExits() {
        func lastLaunch(_ center: DiagnosticsCenter) -> DiagnosticsEvent? {
            center.pendingRecords.map(\.event).last { $0.kind == .launch }
        }
        let first = makeCenter()
        first.start()
        XCTAssertEqual(lastLaunch(first)?.signature, "Launch.first@FalconMail")
        first.endSession()
        first.stop()

        let second = makeCenter()
        second.start()
        XCTAssertEqual(lastLaunch(second)?.signature, "Launch.clean@FalconMail")
        second.stop()

        let third = makeCenter()
        third.start()
        let unclean = lastLaunch(third)
        XCTAssertEqual(unclean?.signature, "Launch.unclean@FalconMail")
        XCTAssertEqual(unclean?.title, "FalconMail started again after it quit unexpectedly")
        XCTAssertEqual(unclean?.context["previousVersion"], .string("1.10.0"))
    }

    func testDailyHealthReport() async throws {
        let clock = ManualClock()
        let center = makeCenter(clock: clock)
        let accounts = [
            DiagnosticsHealthInput.Account(info: AccountInfo.google(email: "ana@workspace.example", displayName: "Ana"),
                                           folders: 12, messages: 3_400, bytesDownToday: 5_000_000),
            DiagnosticsHealthInput.Account(info: AccountInfo.custom(email: "bob@example.org", displayName: "Bob", imapHost: "mail.your-server.de",
                                                                    imapPort: 993, smtpHost: "mail.your-server.de", smtpPort: 465, username: "bob"),
                                           folders: 5, messages: 800, bytesDownToday: 0),
        ]
        center.start { DiagnosticsHealthInput(accounts: accounts, storeBytes: 1_200_000_000, launchSeconds: 2.34) }
        center.noteSyncPass()
        center.noteSyncPass()
        throttled()
        center.waitUntilIdle()

        await center.recordHealthIfDue()
        let health = try XCTUnwrap(center.pendingRecords.map(\.event).first { $0.kind == .health })
        XCTAssertEqual(health.signature, "Health.daily@FalconMail")
        XCTAssertEqual(health.title, "Daily health report")
        XCTAssertEqual(health.context["syncPasses"], .int(2))
        XCTAssertEqual(health.context["throttles"], .int(1))
        XCTAssertEqual(health.context["errors"], .int(1))
        XCTAssertEqual(health.context["storeBytes"], .int(1_200_000_000))
        XCTAssertEqual(health.context["launchSeconds"], .double(2.3))
        XCTAssertEqual(health.context["accounts"]?["byKind"], .object(["workspace": .int(1), "other": .int(1)]))
        let perAccount = try XCTUnwrap(health.context["perAccount"]?.arrayValue)
        XCTAssertEqual(perAccount.map { $0["messages"] }, [.int(3_400), .int(800)])
        XCTAssertEqual(perAccount[1]["host"], .string("mail.your-server.de"))
        XCTAssertNotNil(health.context["memoryBytes"]?.intValue)
        XCTAssertFalse(String(decoding: health.context.serialised, as: UTF8.self).contains("@"))

        await center.recordHealthIfDue()
        XCTAssertEqual(center.pendingRecords.filter { $0.event.kind == .health }.count, 1, "once a day")
        clock.advance(by: 24 * 3_600)
        await center.recordHealthIfDue()
        let reports = center.pendingRecords.filter { $0.event.kind == .health }
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports.last?.event.context["syncPasses"], .int(0), "counts start again after each report")
    }
}

/// A value shared with the fake server's handler, which runs on the loading thread.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }

    @discardableResult
    func mutate<T>(_ change: (inout Value) -> T) -> T {
        lock.withLock { change(&stored) }
    }
}
