import XCTest
@testable import FalconCore

/// Importing .eml and .mbox files into a switched Google account with `messages.import`: each
/// message shows in its folder at once, among the mail of its own day, is known as FalconMail's
/// own so its echo is never new mail, and the import keeps to its pace in units and in bytes.
final class GmailImportTests: XCTestCase {
    private var root: URL!
    private let owner = "owner@example.com"

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("falcon-gmail-import-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Log.start(in: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private struct Rig {
        let mailbox: FakeGmail
        let transport: ScriptedGmailTransport
        let store: any GmailStore
        let importer: GmailImporter
    }

    private func rig(transport: ScriptedGmailTransport? = nil, store: (any GmailStore)? = nil, allowance: (any GmailImportAllowance)? = nil,
                     jobFile: URL? = nil, clock: TestClock? = nil, sleeps: SleepLog? = nil) -> Rig {
        let transport = transport ?? ScriptedGmailTransport(FakeGmail(email: owner))
        let store = store ?? GmailTestPlacer.store(accountID: transport.mailbox.accountID, root: root)
        let now: @Sendable () -> Date = clock?.reading ?? { @Sendable in Date() }
        let gmailClock = transport.mailbox.clock
        let sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
            sleeps?.append(seconds)
            clock?.advance(seconds)
            // The transport's budget waits out Gmail's pauses by the same time.
            gmailClock.advance(seconds)
        }
        let importer = GmailImporter(accountID: transport.mailbox.accountID, email: owner, transport: transport, store: store,
                                     placer: GmailTestPlacer.engine(transport: transport, store: store, now: now),
                                     allowance: allowance ?? RollingImportAllowance(now: now), jobFile: jobFile, now: now, sleep: sleep)
        return Rig(mailbox: transport.mailbox, transport: transport, store: store, importer: importer)
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private func eml(_ subject: String, date: Date, messageID: String? = nil, extra: String = "", body: String = "Hello") -> Data {
        let id = messageID ?? "<\(UUID().uuidString.lowercased())@old.example.com>"
        let text = "From: Ana <ana@example.com>\r\nTo: owner@example.com\r\nSubject: \(subject)\r\nDate: \(RFC5322Date.format(date))\r\n"
            + "Message-ID: \(id)\r\n\(extra)Content-Type: text/plain; charset=utf-8\r\n\r\n\(body)\r\n"
        return Data(text.utf8)
    }

    private func imported(_ raw: Data, read: Bool = true, flagged: Bool = false) -> ImportedMessage {
        var flags: MessageFlags = read ? [.seen] : []
        if flagged { flags.insert(.flagged) }
        return ImportedMessage(raw: raw, flags: flags, date: MIMEParser.parseHeaders(raw).first("Date").flatMap(RFC5322Date.parse))
    }

    /// Puts the mailbox's messages into the index in date order, as the first listing would.
    private func indexEverything(_ r: Rig) async throws {
        let ordered = r.mailbox.messages.sorted { $0.date < $1.date }
        let changes = ordered.enumerated().map { i, m in
            GmailChange.place(m.ref, order: UInt32(i + 1) * GmailIndexRecord.orderStep, labels: m.labels, attributes: [])
        }
        try await r.store.commit(GmailJournalBatch(changes: changes, cursor: r.mailbox.historyID))
    }

    private func order(_ r: Rig, _ id: GmailMessageID) async -> UInt32? {
        await r.store.record(for: id)?.order
    }

    // MARK: - Placing and logging

    func testImportedMailShowsAtOnceAmongItsOwnDayAndIsKnownAsFalconMailsOwn() async throws {
        let r = rig()
        let january = r.mailbox.add(subject: "January", date: date("2024-01-10T09:00:00Z"))
        let june = r.mailbox.add(subject: "June", date: date("2024-06-01T09:00:00Z"))
        let today = r.mailbox.add(subject: "Today", date: Date())
        try await indexEverything(r)

        let messages = [
            imported(eml("March, afternoon", date: date("2024-03-05T15:00:00Z"))),
            imported(eml("March, next day", date: date("2024-03-06T10:00:00Z"))),
            imported(eml("March, morning", date: date("2024-03-05T08:00:00Z"))),
        ]
        let outcome = try await r.importer.run(messages, into: .inbox)
        XCTAssertEqual(outcome.imported, 3)
        XCTAssertTrue(outcome.failures.isEmpty)

        let orderOfJanuary = await order(r, january.id)
        let orderOfJune = await order(r, june.id)
        let orderOfToday = await order(r, today.id)
        let low = try XCTUnwrap(orderOfJanuary)
        let high = try XCTUnwrap(orderOfJune)
        let top = try XCTUnwrap(orderOfToday)
        var orders: [UInt32] = []
        for id in outcome.ids {
            let record = await r.store.record(for: id)
            XCTAssertTrue(record?.hasSystemLabel(.inbox) ?? false, "shown in the Inbox straight away")
            XCTAssertFalse(record?.hasSystemLabel(.unread) ?? true, "imported as read")
            let wasImported = await r.store.wasImported(id)
            XCTAssertTrue(wasImported, "its echo is never new mail")
            orders.append(try XCTUnwrap(record?.order))
        }
        for o in orders { XCTAssertTrue(o > low && o < high && o < top, "among March's mail, never at the top: \(o)") }
        let byTime = zip(outcome.ids, orders).sorted { $0.1 < $1.1 }.map(\.0)
        XCTAssertEqual(byTime, [outcome.ids[2], outcome.ids[0], outcome.ids[1]], "morning, afternoon, next day")

        XCTAssertEqual(r.mailbox.units[.messagesImport], 75)
        XCTAssertEqual(r.mailbox.calls[.messagesList], 2, "one before: search for each day")
        XCTAssertNil(r.mailbox.calls[.messagesInsert])
        XCTAssertNil(r.mailbox.calls[.historyList], "no sync after each message")
    }

    func testAnImportIsUploadedWithGmailsImportOptions() async throws {
        let r = rig()
        let label = r.mailbox.addUserLabel(named: "Clients/ACME")
        _ = try await r.importer.run([imported(eml("Contract", date: date("2023-02-01T10:00:00Z")))], into: label)
        let message = try XCTUnwrap(r.mailbox.messages.first)
        XCTAssertEqual(message.labels, [label], "the folder's label only, and no INBOX")
        XCTAssertEqual(message.date, date("2023-02-01T10:00:00Z"), "dated by its own Date header")

        let archived = try await r.importer.run([imported(eml("Loose", date: date("2023-02-02T10:00:00Z")))], into: nil)
        let loose = try XCTUnwrap(r.mailbox.message(try XCTUnwrap(archived.ids.first)))
        XCTAssertTrue(loose.labels.isEmpty, "Archive is All Mail, which has no label")
    }

    func testReadStateFollowsTheMboxStatusHeaderAndFlagsAreStarred() throws {
        let mbox = """
            From ana@example.com Mon Jan  1 10:00:00 2024
            From: ana@example.com
            Subject: Read
            Status: RO

            One
            From ana@example.com Mon Jan  1 10:00:00 2024
            From: ana@example.com
            Subject: Unread
            Status: O

            Two
            From ana@example.com Mon Jan  1 10:00:00 2024
            From: ana@example.com
            Subject: No status

            Three
            From ana@example.com Mon Jan  1 10:00:00 2024
            From: ana@example.com
            Subject: Flagged
            Status: RO
            X-Status: F

            Four

            """
        let messages = MboxReader.messages(in: Data(mbox.utf8))
        XCTAssertEqual(messages.count, 4)
        let labels = messages.map { GmailImporter.labels(for: $0, into: .inbox) }
        XCTAssertEqual(labels[0], [.inbox])
        XCTAssertEqual(labels[1], [.inbox, .unread])
        XCTAssertEqual(labels[2], [.inbox], "no Status header means read")
        XCTAssertEqual(labels[3], [.inbox, .starred])
    }

    // MARK: - Pace

    func testImportsKeepToSixtyAMinute() async throws {
        let clock = TestClock(Date())
        let sleeps = SleepLog()
        let r = rig(clock: clock, sleeps: sleeps)
        let messages = (0..<61).map { imported(eml("Message \($0)", date: date("2022-05-01T10:00:00Z").addingTimeInterval(Double($0)))) }
        let outcome = try await r.importer.run(messages, into: .inbox)
        XCTAssertEqual(outcome.imported, 61)
        XCTAssertEqual(sleeps.all.count, 1, "the 61st waits for the minute")
        XCTAssertEqual(sleeps.all.first ?? 0, 60, accuracy: 1)
    }

    func testAnImportTakesAsLongAsItsBytesNeedWhenThatIsLonger() async throws {
        let estimate = GmailImporter.estimate(count: 10_000, bytes: 750 * 1024 * 1024)
        XCTAssertEqual(estimate.units, 250_000)
        XCTAssertEqual(estimate.byUnits / 3_600, 2.78, accuracy: 0.01)
        XCTAssertEqual(estimate.byBytes / 86_400, 2.5, accuracy: 0.01)
        XCTAssertTrue(estimate.isBoundByBytes)
        XCTAssertEqual(estimate.duration, estimate.byBytes)
        let perGB = GmailImporter.estimate(count: 1, bytes: 1_024 * 1024 * 1024).duration / 86_400
        XCTAssertEqual(perGB, 3.4, accuracy: 0.1, "about 3½ days per GB")

        let clock = TestClock(Date())
        let sleeps = SleepLog()
        let messages = (0..<4).map { imported(eml("Big \($0)", date: date("2022-05-01T10:00:00Z"), body: String(repeating: "x", count: 900))) }
        let size = messages[0].raw.count
        let allowance = RollingImportAllowance(limit: size * 3, now: clock.reading)
        let r = rig(allowance: allowance, clock: clock, sleeps: sleeps)
        let seen = ProgressLog()
        await r.importer.reportWaits { seen.append($0) }
        let started = clock.now
        let outcome = try await r.importer.run(messages, into: .inbox)
        XCTAssertEqual(outcome.imported, 4)
        let waits = seen.all.compactMap { if case .waiting(let until, .uploadAllowance) = $0 { return until } else { return nil } }
        XCTAssertEqual(waits.count, 1, "the fourth waits for the rolling day")
        XCTAssertEqual(waits.first?.timeIntervalSince(started) ?? 0, 86_400, accuracy: 5)
        XCTAssertEqual(sleeps.all.reduce(0, +), 86_400, accuracy: 5)
    }

    func testWithTheAppsTrafficMeterAnImportKeepsToItsOneLedger() async throws {
        let clock = TestClock(Date())
        let limits = TrafficLimits(background: 1_000_000, download: 1_000_000, upload: 1_000_000,
                                   api: APITrafficLimits(background: 8_000, download: 15_000, imports: 1_000, upload: 4_000))
        let meter = TrafficMeter(layout: FileLayout(root: root), limits: limits, now: clock.reading)
        let account = UUID()
        let allowance = TrafficMeterImportAllowance(meter: meter, accountID: account)
        let now = clock.reading()
        let first = await allowance.whenAllows(600)
        XCTAssertEqual(first, now)
        // What the transport's budget books as imported is what the importer reads.
        meter.recordAPI(up: 800, imported: 800, for: account)
        let later = await allowance.whenAllows(600)
        XCTAssertGreaterThan(later, now, "past the day's imports it waits for the oldest hour to leave")
        let other = await TrafficMeterImportAllowance(meter: meter, accountID: UUID()).whenAllows(600)
        XCTAssertEqual(other, now, "each account has its own")
    }

    func testTheDaysUploadsAreRememberedAcrossARelaunch() async throws {
        let clock = TestClock(Date())
        let file = root.appendingPathComponent("importBytes.json")
        let first = RollingImportAllowance(limit: 1_000, file: file, now: clock.reading)
        await first.record(800)
        let again = RollingImportAllowance(limit: 1_000, file: file, now: clock.reading)
        let used = await again.used()
        XCTAssertEqual(used, 800)
        let later = await again.whenAllows(300)
        XCTAssertEqual(later.timeIntervalSince(clock.now), 86_400, accuracy: 1)
        clock.advance(86_401)
        let now = await again.whenAllows(300)
        XCTAssertEqual(now, clock.now)
    }

    // MARK: - Failures and resuming

    func testARefusedMessageIsPassedOverAndTheRestGoIn() async throws {
        let r = rig()
        r.mailbox.fail(.messagesImport, with: GoogleAPIError(kind: .other, httpStatus: 400, reason: "invalidargument", detail: "Invalid message"))
        let messages = (0..<3).map { imported(eml("Message \($0)", date: date("2022-05-01T10:00:00Z"))) }
        let outcome = try await r.importer.run(messages, into: .inbox)
        XCTAssertEqual(outcome.imported, 2)
        XCTAssertEqual(outcome.failures, [GmailImportFailure(index: 0, sentence: "Gmail refused a message. Details are in the log.")])
    }

    func testAMessageWhosePlaceCannotBeFoundYetIsImportedAllTheSame() async throws {
        let r = rig()
        r.mailbox.fail(.messagesList, with: GoogleAPIError(kind: .offline, detail: "URLError -1009"))
        let outcome = try await r.importer.run([imported(eml("Placed later", date: date("2022-05-01T10:00:00Z")))], into: .inbox)
        XCTAssertEqual(outcome.imported, 1)
        XCTAssertTrue(outcome.failures.isEmpty)
        let id = try XCTUnwrap(outcome.ids.first)
        let wasImported = await r.store.wasImported(id)
        XCTAssertTrue(wasImported, "logged, so its echo is still never new mail")
    }

    func testARateRefusalWaitsAndImportsOnce() async throws {
        let clock = TestClock(Date())
        let sleeps = SleepLog()
        let r = rig(clock: clock, sleeps: sleeps)
        r.mailbox.fail(.messagesImport, with: GoogleAPIError(kind: .rateLimited, httpStatus: 429, retryAfter: 30))
        let outcome = try await r.importer.run([imported(eml("Once", date: date("2022-05-01T10:00:00Z")))], into: .inbox)
        XCTAssertEqual(outcome.imported, 1)
        XCTAssertEqual(r.mailbox.messages.count, 1)
        // A rate refusal only says Gmail did nothing, so the transport waits out its 30 seconds
        // and asks once more itself; the import never sees it.
        XCTAssertEqual(r.mailbox.attempts[.messagesImport], 2)
        XCTAssertGreaterThanOrEqual(r.mailbox.clock.slept, 30)
        XCTAssertEqual(sleeps.all, [])
    }

    func testAnImportGmailTookWithoutAnsweringIsNotImportedTwice() async throws {
        let r = rig()
        r.transport.failAfterAccepting(.messagesImport, with: GoogleAPIError(kind: .temporary, detail: "URLError -1001"))
        let outcome = try await r.importer.run([imported(eml("Once only", date: date("2022-05-01T10:00:00Z")))], into: .inbox)
        XCTAssertEqual(outcome.imported, 1)
        XCTAssertEqual(r.mailbox.messages.count, 1, "found by its Message-ID, not uploaded again")
        XCTAssertEqual(r.mailbox.attempts[.messagesImport], 1)
        let id = try XCTUnwrap(outcome.ids.first)
        let wasImported = await r.store.wasImported(id)
        XCTAssertTrue(wasImported)
    }

    func testAnImportCarriesOnWhereItStoppedAndNeverImportsTwice() async throws {
        let dates = (0..<5).map { date("2021-03-0\($0 + 1)T10:00:00Z") }
        let ids = (0..<5).map { "<resume-\($0)@old.example.com>" }
        let mbox = (0..<5).map { i -> String in
            "From ana@example.com Mon Mar  1 10:00:00 2021\n" + String(decoding: eml("Part \(i)", date: dates[i], messageID: ids[i]), as: UTF8.self)
        }.joined(separator: "\n")
        let file = root.appendingPathComponent("Old mail.mbox")
        try Data(mbox.utf8).write(to: file)
        let jobFile = root.appendingPathComponent("importJob.json")

        let first = rig(jobFile: jobFile)
        let mailbox = first.mailbox
        // After two messages the account needs signing in again, and the import stops there.
        first.transport.refuse(.messagesImport, with: GoogleAPIError(kind: .needsSignIn, httpStatus: 401), afterAllowing: 2)
        do {
            _ = try await first.importer.run(files: [file], into: .inbox)
            XCTFail("the import stops while the account needs signing in")
        } catch let refusal as GoogleAPIError {
            XCTAssertEqual(refusal.kind, .needsSignIn)
        }
        let job = try XCTUnwrap(first.importer.unfinishedJob())
        XCTAssertEqual(job.done, 2)
        XCTAssertEqual(mailbox.messages.count, 2)

        // Gmail took the third, but FalconMail stopped before its answer came.
        var stopped = job
        stopped.inFlight = GmailImportJob.InFlight(index: 2, messageID: ids[2])
        try AtomicFile.writeJSON(stopped, to: jobFile)
        _ = try await mailbox.importMessage(eml("Part 2", date: dates[2], messageID: ids[2]), labels: [.inbox],
                                            options: GmailImportOptions(), work: .background(.transfer))

        let second = rig(transport: ScriptedGmailTransport(mailbox), jobFile: jobFile)
        let resumed = try await second.importer.resume()
        XCTAssertEqual(resumed?.imported, 3, "the third found, the fourth and fifth imported")
        let messageIDs = mailbox.messages.compactMap { m in m.headers.first { $0.name == "Message-ID" }?.value }
        XCTAssertEqual(messageIDs.sorted(), ids.sorted(), "each exactly once")
        XCTAssertNil(second.importer.unfinishedJob(), "finished, so nothing is left to resume")
    }
}

final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var sleeps: [TimeInterval] = []

    func append(_ seconds: TimeInterval) { lock.withLock { sleeps.append(seconds) } }
    var all: [TimeInterval] { lock.withLock { sleeps } }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [GmailImportProgress] = []

    func append(_ event: GmailImportProgress) { lock.withLock { events.append(event) } }
    var all: [GmailImportProgress] { lock.withLock { events } }
}

