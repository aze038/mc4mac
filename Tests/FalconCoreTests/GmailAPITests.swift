import XCTest
@testable import FalconCore

final class GmailAPITests: XCTestCase {
    override func setUp() {
        super.setUp()
        Log.isEnabled = false
    }

    // MARK: - Query encoding and the session

    func testPlusIsPercentEncodedInQueries() {
        let base = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        let url = GoogleAPI.url(base, queryItems: [URLQueryItem(name: "q", value: "from:a+b@x.com счёт & more")])
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
        XCTAssertTrue(query.contains("from%3Aa%2Bb%40x.com"), query)
        XCTAssertFalse(query.contains("+"), query)
        XCTAssertTrue(query.contains("%D1%81%D1%87%D1%91%D1%82"), "letters outside ASCII must be encoded too: \(query)")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "from:a+b@x.com счёт & more")
    }

    func testSearchSendsPlusAsPercent2B() async throws {
        let mailbox = FakeGmailMailbox()
        mailbox.add(subject: "Plus addressing", from: "a+b@x.com")
        mailbox.add(subject: "Someone else", from: "a b@x.com")
        let client = GmailTestKit.client(mailbox)
        let list = try await client.list(query: "from:a+b@x.com")
        XCTAssertEqual(list.messages?.count, 1)
        XCTAssertTrue(mailbox.rawQueries.last?.contains("q=from%3Aa%2Bb%40x.com") == true, mailbox.rawQueries.last ?? "")
        XCTAssertEqual(mailbox.queries.last, "from:a+b@x.com")
    }

    func testDictionaryQueriesOfExistingCallersAreEncodedTheSameWay() async throws {
        let mailbox = FakeGmailMailbox()
        mailbox.add(subject: "Plus", from: "a+b@x.com")
        let base = FakeGmailURLProtocol.register(mailbox)
        let api = GoogleAPI(tokenSource: FakeTokenSource(), accountID: UUID(), session: FakeGmailURLProtocol.session)
        let list = try await api.json(GmailMessageList.self, "GET", base.appendingPathComponent("messages"), query: ["q": "from:a+b@x.com"])
        XCTAssertEqual(list.messages?.count, 1)
        XCTAssertTrue(mailbox.rawQueries.last?.contains("%2B") == true)
    }

    func testDefaultSessionKeepsNothingOnDisk() {
        let configuration = GoogleAPI.ephemeralSession.configuration
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(GoogleAPI.ephemeralConfiguration().urlCache)
    }

    // MARK: - Units

    func testUnitsAreCountedPerCall() async throws {
        let mailbox = FakeGmailMailbox()
        let message = mailbox.add(subject: "Report", attachments: [.init(filename: "a.pdf", mimeType: "application/pdf", data: Data(repeating: 1, count: 10))])
        let client = GmailTestKit.client(mailbox)
        _ = try await client.profile()
        _ = try await client.labels()
        _ = try await client.list(query: "report")
        _ = try await client.metadata(id: message.id)
        let full = try await client.full(id: message.id)
        let attachmentID = try XCTUnwrap(full.payload?.parts?.last?.body?.attachmentId)
        _ = try await client.attachment(messageID: message.id, attachmentID: attachmentID)
        let expected: [GmailMethod: Int] = [.profile: 1, .labelsList: 1, .messagesList: 5, .messagesGet: 40, .attachmentsGet: 5]
        XCTAssertEqual(mailbox.units, expected)
        let spent = await client.limiter.spent
        XCTAssertEqual(spent, expected)
    }

    func testLimiterKeepsEveryMinuteWithinThreeThousandUnits() async throws {
        let clock = VirtualClock()
        let limiter = clock.limiter()
        var bookings: [(Date, Int)] = []
        for _ in 0..<400 {
            try await limiter.acquire(.messagesGet)
            bookings.append((clock.now, GmailMethod.messagesGet.units))
        }
        for (start, _) in bookings {
            let inWindow = bookings.filter { $0.0 >= start && $0.0.timeIntervalSince(start) < 60 }.reduce(0) { $0 + $1.1 }
            XCTAssertLessThanOrEqual(inWindow, 3_000)
        }
        // 8,000 units at 3,000 a minute cannot be booked in under two minutes.
        XCTAssertGreaterThanOrEqual(clock.slept, 120)
    }

    func testLimiterRefusesAWaitLongerThanTheCallerAllows() async throws {
        let clock = VirtualClock()
        let limiter = clock.limiter()
        for _ in 0..<150 { try await limiter.acquire(.messagesGet) }
        do {
            try await limiter.acquire(.messagesGet, maxWait: 5)
            XCTFail("the minute is full")
        } catch let error as GoogleAPIError {
            XCTAssertEqual(error.kind, .rateLimited)
            XCTAssertGreaterThan(error.retryAfter ?? 0, 5)
        }
        XCTAssertEqual(clock.slept, 0)
    }

    // MARK: - Refusals

    func testRateLimitHalvesTheBudgetAndHonoursRetryAfter() async throws {
        let mailbox = FakeGmailMailbox()
        let message = mailbox.add(subject: "Busy")
        mailbox.inject(.status(429, reason: "rateLimitExceeded", retryAfter: "3"), for: .messagesGet)
        let clock = VirtualClock()
        let client = GmailTestKit.client(mailbox, clock: clock)
        let fetched = try await client.metadata(id: message.id)
        XCTAssertEqual(fetched.id, message.id)
        XCTAssertEqual(mailbox.attempts[.messagesGet], 2)
        XCTAssertGreaterThanOrEqual(clock.slept, 3, "the retry waited for Retry-After")
        // Halved to 1,500, plus the tenth-a-minute recovery over the three seconds waited.
        let halved = await client.limiter.currentLimit
        XCTAssertEqual(halved, 1_515)
        clock.advance(5 * 60)
        let recovered = await client.limiter.currentLimit
        XCTAssertEqual(recovered, 3_000)
    }

    func testUserRateLimitOn403IsRetried() async throws {
        let mailbox = FakeGmailMailbox()
        mailbox.add(subject: "Busy")
        mailbox.inject(.status(403, reason: "userRateLimitExceeded"), for: .messagesList)
        let client = GmailTestKit.client(mailbox)
        let list = try await client.list(query: nil)
        XCTAssertEqual(list.messages?.count, 1)
        XCTAssertEqual(mailbox.attempts[.messagesList], 2)
    }

    func testRetryAfterLongerThanAnInteractiveWaitGivesUpAtOnce() async throws {
        let mailbox = FakeGmailMailbox()
        mailbox.always(.status(429, reason: "rateLimitExceeded", retryAfter: "120"), for: .messagesList)
        let clock = VirtualClock()
        let client = GmailTestKit.client(mailbox, clock: clock)
        do {
            _ = try await client.list(query: "x")
            XCTFail("expected a refusal")
        } catch let error as GoogleAPIError {
            XCTAssertEqual(error.kind, .rateLimited)
        }
        XCTAssertEqual(mailbox.attempts[.messagesList], 1, "nothing is sent while Retry-After runs")
        XCTAssertEqual(clock.slept, 0)
    }

    func testEachForbiddenReasonIsClassified() async throws {
        let cases: [(String, GoogleAPIError.Kind)] = [
            ("quotaExceeded", .quotaExhausted), ("dailyLimitExceeded", .quotaExhausted),
            ("accessNotConfigured", .apiDisabled), ("SERVICE_DISABLED", .apiDisabled),
            ("insufficientPermissions", .insufficientPermissions), ("forbidden", .other)
        ]
        for (reason, kind) in cases {
            let mailbox = FakeGmailMailbox()
            mailbox.always(.status(403, reason: reason), for: .messagesList)
            let client = GmailTestKit.client(mailbox)
            do {
                _ = try await client.list(query: "x")
                XCTFail("\(reason) should refuse")
            } catch let error as GoogleAPIError {
                XCTAssertEqual(error.kind, kind, reason)
                XCTAssertEqual(error.httpStatus, 403)
            }
            XCTAssertEqual(mailbox.attempts[.messagesList], 1, "\(reason) is not retried")
        }
    }

    func testClassificationNeverReadsTheMessageText() {
        func body(_ reason: String, _ message: String) -> Data {
            try! JSONSerialization.data(withJSONObject: ["error": ["code": 403, "message": message, "errors": [["reason": reason, "message": message]]]])
        }
        for reason in ["rateLimitExceeded", "quotaExceeded", "accessNotConfigured", "insufficientPermissions"] {
            let a = GoogleErrorParser.parse(status: 403, body: body(reason, "User Rate Limit Exceeded"))
            let b = GoogleErrorParser.parse(status: 403, body: body(reason, "Daily Limit Exceeded; Access Not Configured"))
            XCTAssertEqual(a.kind, b.kind, reason)
        }
        XCTAssertEqual(GoogleErrorParser.parse(status: 400, body: Data(#"{"error":"invalid_grant","error_description":"Bad Request"}"#.utf8)).kind, .needsSignIn)
        XCTAssertEqual(GoogleErrorParser.parse(status: 401, body: Data(#"{"error":"unauthorized_client"}"#.utf8)).kind, .clientRejected)
        XCTAssertEqual(GoogleErrorParser.parse(status: 503, body: Data("<html>".utf8)).kind, .temporary)
        XCTAssertEqual(GoogleErrorParser.parse(status: 404, body: Data()).kind, .notFound)
    }

    func testRetryAfterAcceptsSecondsAndDates() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(GoogleErrorParser.retryAfterSeconds("7", now: now), 7)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        XCTAssertEqual(GoogleErrorParser.retryAfterSeconds(formatter.string(from: now.addingTimeInterval(90)), now: now), 90)
        XCTAssertNil(GoogleErrorParser.retryAfterSeconds("soon", now: now))
    }

    func testUnauthorizedRefreshesTheTokenOnceAndRetries() async throws {
        let mailbox = FakeGmailMailbox()
        mailbox.acceptedTokens = ["token-2"]
        let tokens = FakeTokenSource(current: "token-1", afterRefresh: "token-2")
        let client = GmailTestKit.client(mailbox, tokens: tokens)
        let profile = try await client.profile()
        XCTAssertEqual(profile.emailAddress, mailbox.email)
        let refreshes = await tokens.refreshes
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(mailbox.attempts[.profile], 2)
    }

    func testUnauthorizedAfterARefreshNeedsSignIn() async throws {
        let mailbox = FakeGmailMailbox()
        mailbox.acceptedTokens = ["never"]
        let tokens = FakeTokenSource()
        let client = GmailTestKit.client(mailbox, tokens: tokens)
        do {
            _ = try await client.profile()
            XCTFail("expected a refusal")
        } catch let error as GoogleAPIError {
            XCTAssertEqual(error.kind, .needsSignIn)
        }
        let refreshes = await tokens.refreshes
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(mailbox.attempts[.profile], 2)
    }

    func testServerErrorsAreRetriedWithBackoffThenReported() async throws {
        let mailbox = FakeGmailMailbox()
        mailbox.add(subject: "x")
        mailbox.inject(.status(500, reason: "backendError"), for: .messagesList)
        let clock = VirtualClock()
        let client = GmailTestKit.client(mailbox, clock: clock)
        let list = try await client.list(query: nil)
        XCTAssertEqual(list.messages?.count, 1)
        XCTAssertGreaterThan(clock.slept, 0)

        mailbox.always(.status(500, reason: nil), for: .labelsList)
        do {
            _ = try await client.labels()
            XCTFail("expected a refusal")
        } catch let error as GoogleAPIError {
            XCTAssertEqual(error.kind, .temporary)
        }
        XCTAssertEqual(mailbox.attempts[.labelsList], 4)
    }

    func testTimeoutIsRetriedOnceAndOfflineIsNot() async throws {
        let mailbox = FakeGmailMailbox()
        mailbox.add(subject: "x")
        mailbox.inject(.timeout, for: .messagesList)
        let client = GmailTestKit.client(mailbox)
        let list = try await client.list(query: nil)
        XCTAssertEqual(list.messages?.count, 1)

        mailbox.always(.timeout, for: .profile)
        do {
            _ = try await client.profile()
            XCTFail("expected a timeout")
        } catch let error as GoogleAPIError {
            XCTAssertEqual(error.kind, .temporary)
        }
        XCTAssertEqual(mailbox.attempts[.profile], 2)

        mailbox.always(.offline, for: .labelsList)
        do {
            _ = try await client.labels()
            XCTFail("expected offline")
        } catch let error as GoogleAPIError {
            XCTAssertEqual(error.kind, .offline)
        }
        XCTAssertEqual(mailbox.attempts[.labelsList], 1)
    }
}
