import XCTest
@testable import FalconCore

/// Gmail's HTTP batches: how reads are grouped, how a batch goes over the wire, and how its
/// answers, in any order and each on its own, come back to what was asked.
final class GmailBatchTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Log.isEnabled = false
    }

    override func tearDown() {
        Log.isEnabled = true
        super.tearDown()
    }

    private func ids(_ n: Int, from start: UInt64 = 0x1000) -> [GmailMessageID] {
        (0..<n).map { GmailMessageID(raw: start + UInt64($0) * 0x10) }
    }

    // MARK: Planning

    func testAScreenOfRowsIsOneBatchAndWholeMessagesAndBackgroundGoTenAtATime() {
        let rows = ids(60).map { GmailBatchPart.message($0, .row) }
        let screens = GmailBatchPlan.split(rows, work: .interactive, maxParts: 25, maxUnits: 1_000)
        XCTAssertEqual(screens.map(\.count), [25, 25, 10])

        let full = ids(25).map { GmailBatchPart.message($0, .full) }
        XCTAssertEqual(GmailBatchPlan.split(full, work: .interactive, maxParts: 25, maxUnits: 1_000).map(\.count), [10, 10, 5])
        let raw = ids(12).map { GmailBatchPart.message($0, .raw) }
        XCTAssertEqual(GmailBatchPlan.split(raw, work: .interactive, maxParts: 25, maxUnits: 1_000).map(\.count), [10, 2])

        let background = GmailBatchPlan.split(rows, work: .background(.readAhead), maxParts: 10, maxUnits: 500)
        XCTAssertTrue(background.allSatisfy { $0.count <= 10 })
        XCTAssertEqual(background.flatMap { $0 }, rows, "nothing is lost or reordered")

        // Rows, then a whole message: the batch closes at ten once a whole message is in it.
        let mixed = ids(15).map { GmailBatchPart.message($0, .row) } + [GmailBatchPart.message(GmailMessageID(raw: 1), .full)]
        XCTAssertEqual(GmailBatchPlan.split(mixed, work: .interactive, maxParts: 25, maxUnits: 1_000).map(\.count), [15, 1])
    }

    func testABatchFitsTheUnitsTheBucketCanGiveAndTheHalvedParts() {
        let conversations = ids(25).map { GmailBatchPart.thread(GmailThreadID(raw: $0.raw), .row) }
        // During a flood the bucket holds 500: a landing of 25 conversations goes as batches of 12, 12 and 1.
        let flood = GmailBatchPlan.split(conversations, work: .interactive, maxParts: 25, maxUnits: 500)
        XCTAssertTrue(flood.allSatisfy { $0.reduce(0) { $0 + $1.method.units } <= 500 })
        XCTAssertEqual(flood.map(\.count), [12, 12, 1])
        // After a concurrency refusal, 12 parts at most.
        let cut = GmailBatchPlan.split(ids(25).map { .message($0, .row) }, work: .interactive, maxParts: 12, maxUnits: 1_000)
        XCTAssertEqual(cut.map(\.count), [12, 12, 1])
        // A label's counts cost 1 each, so 25 of them are one batch.
        let labels = (0..<25).map { GmailBatchPart.label(GmailLabelID("Label_\($0)")) }
        XCTAssertEqual(GmailBatchPlan.split(labels, work: .checks, maxParts: 25, maxUnits: 1_000).count, 1)
    }

    // MARK: On the wire

    func testABatchIsMultipartWithOneNestedRequestPerPartByPathOnly() {
        let id = GmailMessageID(raw: 0x18a0f)
        let request = GmailBatchRequest(parts: [.message(id, .metadata(headers: ["From", "Message-ID"])),
                                                .thread(GmailThreadID(raw: 0x18a00), .minimal), .label("Label_7")],
                                        basePath: "/gmail/v1/users/me")
        let text = request.body.utf8Lossy
        XCTAssertTrue(request.contentType.hasPrefix("multipart/mixed; boundary=batch_"))
        XCTAssertTrue(text.contains("Content-Type: application/http\r\nContent-ID: <p1>\r\n\r\nGET /gmail/v1/users/me/messages/18a0f?format=metadata&metadataHeaders=From&metadataHeaders=Message-ID HTTP/1.1\r\n"), text)
        XCTAssertTrue(text.contains("GET /gmail/v1/users/me/threads/18a00?format=minimal HTTP/1.1"))
        XCTAssertTrue(text.contains("GET /gmail/v1/users/me/labels/Label_7 HTTP/1.1"))
        XCTAssertFalse(text.contains("https://"), "only the path goes in a batch")
        XCTAssertTrue(text.hasSuffix("--\(request.boundary)--\r\n"))
        XCTAssertEqual(request.parts.map(\.contentID), ["p1", "p2", "p3"])
    }

    func testAnswersAreReadInGooglesOwnFormAndInAnyOrder() throws {
        // Google's example leaves out a colon and writes bare newlines; both are read.
        let reply = """
        --batch_foobarbaz
        Content-Type: application/http
        Content-ID: <response-p2>

        HTTP/1.1 404 Not Found
        Content-Type application/json

        {"error":{"code":404,"message":"Requested entity was not found.","errors":[{"reason":"notFound"}]}}
        --batch_foobarbaz
        Content-Type: application/http
        Content-ID: <response-p1>

        HTTP/1.1 200 OK
        Content-Type: application/json; charset=UTF-8
        ETag: "etag/pony"

        {"id":"18a0f","threadId":"18a0f"}
        --batch_foobarbaz--

        """
        let answers = try GmailBatchResponse.parse(Data(reply.utf8), contentType: "multipart/mixed; boundary=batch_foobarbaz")
        XCTAssertEqual(answers["p1"]?.status, 200)
        XCTAssertEqual(answers["p1"]?.body.utf8Lossy, #"{"id":"18a0f","threadId":"18a0f"}"#)
        XCTAssertEqual(answers["p1"]?.headers["etag"], "\"etag/pony\"")
        XCTAssertEqual(answers["p2"]?.status, 404)
        XCTAssertThrowsError(try GmailBatchResponse.parse(Data(reply.utf8), contentType: "application/json"))
    }

    // MARK: Against the fake

    func testEachPartIsAnsweredOnItsOwnAndMatchedWhateverTheOrder() async throws {
        for order in [FakeGmailMailbox.AnswerOrder.reversed, .shuffled, .asked] {
            let mailbox = FakeGmailMailbox()
            mailbox.answerOrder = order
            let messages = (0..<20).map { mailbox.add(subject: "Row \($0)", threadID: nil) }
            let transport = GmailTestKit.transport(mailbox)
            let gone = GmailMessageID(raw: 0xdead0)
            var parts = messages.map { GmailBatchPart.message(GmailMessageID(hex: $0.id)!, .row) }
            parts.insert(.message(gone, .row), at: 7)
            parts.append(.thread(GmailThreadID(hex: messages[3].threadID)!, .minimal))
            parts.append(.label(.inbox))
            let answers = try await transport.batch(parts, work: .interactive)
            XCTAssertEqual(answers.count, parts.count)
            for (i, message) in messages.enumerated() {
                let answer = try answers[.message(GmailMessageID(hex: message.id)!, .row)]?.get()
                XCTAssertEqual(answer?.message?.id, message.id, "\(order) row \(i)")
                XCTAssertEqual(answer?.message?.header("Subject"), "Row \(i)")
            }
            guard case .failure(let refusal)? = answers[.message(gone, .row)] else { return XCTFail("the missing one fails on its own") }
            XCTAssertEqual(refusal.kind, .notFound)
            XCTAssertEqual(try answers[.label(.inbox)]?.get().label?.messagesTotal, 20)
            XCTAssertEqual(try answers[.thread(GmailThreadID(hex: messages[3].threadID)!, .minimal)]?.get().thread?.messages?.count, 1)
            XCTAssertEqual(mailbox.batchSizes, [23], "one HTTP batch")
            XCTAssertEqual(mailbox.units[.messagesGet], 20 * 20, "each answered part is priced as its own call")
            XCTAssertEqual(mailbox.units[.threadsGet], 40)
            XCTAssertEqual(mailbox.units[.labelsGet], 1)
            let usage = await transport.usage()
            XCTAssertEqual(usage.units[.messagesGet], 21 * 20, "refused parts are not refunded")
        }
    }

    func testRefusedPartsAreTriedAgainAndOneBurstHalvesTheBudgetOnce() async throws {
        let mailbox = FakeGmailMailbox()
        let messages = (0..<25).map { mailbox.add(subject: "Row \($0)") }
        mailbox.inject(.rateLimited(retryAfter: "2"), for: .messagesGet, times: 5)
        mailbox.inject(.serverError, for: .messagesGet, times: 2)
        let clock = VirtualClock()
        let transport = GmailTestKit.transport(mailbox, clock: clock)
        let parts = messages.map { GmailBatchPart.message(GmailMessageID(hex: $0.id)!, .row) }
        let answers = try await transport.batch(parts, work: .interactive)
        XCTAssertTrue(answers.values.allSatisfy { (try? $0.get()) != nil }, "every part arrived in the end")
        XCTAssertEqual(mailbox.batchSizes, [25, 7])
        XCTAssertGreaterThanOrEqual(clock.slept, 2, "the retry waited out Retry-After")
        let counts = await transport.budget.refusalCounts()
        XCTAssertEqual(counts["429 ratelimitexceeded"], 5)
        // One halving for the five refusals of one burst: the budget refills at 1,000 a minute and
        // a little more each second since, so 500 units take just under 30 seconds. Halved five
        // times it would be a quarter, and take a minute.
        let drain = try await transport.budget.admit(GmailBooking(work: .interactive, calls: [.threadsGet: 25], direction: .download))
        await transport.budget.finish(drain)
        let start = clock.now
        let next = try await transport.budget.admit(GmailBooking(work: .interactive, calls: [.messagesGet: 25], direction: .download))
        await transport.budget.finish(next)
        XCTAssertGreaterThan(clock.now.timeIntervalSince(start), 24)
        XCTAssertLessThan(clock.now.timeIntervalSince(start), 30.5)
    }

    func testAConcurrencyRefusalCountedByPartsHalvesThePartsInFlight() async throws {
        let mailbox = FakeGmailMailbox()
        let messages = (0..<75).map { mailbox.add(subject: "Row \($0)") }
        // Other clients of the user hold some of Google's concurrent requests: only 20 are left.
        mailbox.concurrencyLimit = 20
        mailbox.batchDelay = 0.1
        let transport = GmailTestKit.transport(mailbox, policy: GmailBudgetPolicy(capacity: 100_000, refillPerMinute: 1_000_000))
        let parts = messages.map { GmailBatchPart.message(GmailMessageID(hex: $0.id)!, .row) }
        async let first = transport.batch(Array(parts[0..<25]), work: .interactive)
        async let second = transport.batch(Array(parts[25..<50]), work: .interactive)
        async let third = transport.batch(Array(parts[50..<75]), work: .interactive)
        let all = try await [first, second, third].flatMap { $0 }
        XCTAssertEqual(all.count, 75)
        XCTAssertTrue(all.allSatisfy { (try? $0.value.get()) != nil })
        let limits = await transport.budget.batchLimits(for: .interactive)
        XCTAssertEqual(limits.parts, 12, "the parts in flight are halved for ten minutes")
        XCTAssertGreaterThan(mailbox.batchSizes.count, 3, "the refused parts went again in smaller batches")
        XCTAssertTrue(mailbox.batchSizes.dropFirst(3).allSatisfy { $0 <= 12 })
        let peak = await transport.budget.peak
        XCTAssertLessThanOrEqual(peak.foregroundParts, 25)
    }

    func testTheOtherBatchAddressIsTriedAndKept() async throws {
        let mailbox = FakeGmailMailbox()
        let message = mailbox.add(subject: "x")
        mailbox.acceptedBatchPaths = ["/batch"]
        let transport = GmailTestKit.transport(mailbox)
        XCTAssertTrue(transport.batchURL.path.hasSuffix("/batch/gmail/v1"))
        let id = GmailMessageID(hex: message.id)!
        let answers = try await transport.batch([.message(id, .minimal)], work: .interactive)
        XCTAssertEqual(try answers[.message(id, .minimal)]?.get().message?.id, message.id)
        XCTAssertEqual(transport.batchURL.path, "/batch")
        _ = try await transport.batch([.label(.inbox)], work: .interactive)
        XCTAssertEqual(mailbox.batchSizes, [1, 1], "the second batch went straight to the address that answers")

        mailbox.acceptedBatchPaths = []
        do {
            _ = try await transport.batch([.label(.inbox)], work: .interactive)
            XCTFail("no batch address answers")
        } catch let refusal as GoogleAPIError {
            XCTAssertEqual(refusal.kind, .notFound)
        }
    }

    func testAWholeBatchThatFailsStandsForEveryPart() async throws {
        let mailbox = FakeGmailMailbox()
        let message = mailbox.add(subject: "x")
        mailbox.injectBatch(.serverError, times: 5)
        let clock = VirtualClock()
        let transport = GmailTestKit.transport(mailbox, clock: clock)
        do {
            _ = try await transport.batch([.message(GmailMessageID(hex: message.id)!, .row)], work: .interactive)
            XCTFail("five server errors")
        } catch let refusal as GoogleAPIError {
            XCTAssertEqual(refusal.kind, .temporary)
        }
        XCTAssertEqual(clock.slept, 1 + 2 + 4 + 8, accuracy: 0.01)
        mailbox.injectBatch(.status(401, reason: "authError"))
        mailbox.acceptedTokens = ["token-1"]
        let answers = try await transport.batch([.message(GmailMessageID(hex: message.id)!, .row)], work: .interactive)
        XCTAssertEqual(answers.count, 1)
    }

    func testAPartRefusedForItsTokenIsAskedAgainWithAFreshOne() async throws {
        let mailbox = FakeGmailMailbox()
        let messages = (0..<3).map { mailbox.add(subject: "Row \($0)") }
        let tokens = FakeTokenSource(current: "token-1", afterRefresh: "token-2")
        let transport = GmailTestKit.transport(mailbox, tokens: tokens)
        mailbox.acceptedTokens = ["token-2"]
        let answers = try await transport.batch(messages.map { .message(GmailMessageID(hex: $0.id)!, .row) }, work: .interactive)
        XCTAssertTrue(answers.values.allSatisfy { (try? $0.get()) != nil })
        let refreshes = await tokens.refreshes
        XCTAssertEqual(refreshes, 1)
    }

    func testTheSamePartAskedTwiceIsFetchedOnce() async throws {
        let mailbox = FakeGmailMailbox()
        let message = mailbox.add(subject: "x")
        let transport = GmailTestKit.transport(mailbox)
        let part = GmailBatchPart.message(GmailMessageID(hex: message.id)!, .row)
        let answers = try await transport.batch([part, part, part], work: .interactive)
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(mailbox.units[.messagesGet], 20)
        let none = try await transport.batch([], work: .interactive)
        XCTAssertTrue(none.isEmpty)
    }
}
