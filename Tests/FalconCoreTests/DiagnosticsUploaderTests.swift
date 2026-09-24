import XCTest
@testable import FalconCore

final class DiagnosticsUploaderTests: XCTestCase {
    private let echo = "https://echo.example.invalid/macros/echo?user_content_key=k"

    override func tearDown() {
        FakeDiagnosticsServer.reset()
    }

    private func upload(_ events: [DiagnosticsEvent]) -> DiagnosticsUpload {
        DiagnosticsUpload(key: "ingest-key", install: "INSTALL", app: DiagnosticsFixtures.app, os: "macOS 26.6 (25G5023)",
                          hw: "MacBookPro18,3", locale: "en_GB", sentAt: Date(timeIntervalSince1970: 1_790_000_000), events: events)
    }

    private var uploader: DiagnosticsUploader {
        DiagnosticsUploader(endpoint: DiagnosticsEndpoint(url: DiagnosticsFixtures.endpoint, key: "ingest-key"),
                            session: FakeDiagnosticsServer.session())
    }

    // MARK: Batching

    func testBatchesHoldAtMostTwoHundredEvents() {
        let records = (0..<450).map { DiagnosticsFixtures.record(DiagnosticsFixtures.event("A.n@X.swift:\($0)")) }
        let batches = DiagnosticsUploader.batches(records) { app, os, events in
            DiagnosticsUpload(key: "k", install: "i", app: app, os: os, hw: "h", locale: "l", sentAt: Date(), events: events)
        }
        XCTAssertEqual(batches.map(\.events.count), [200, 200, 50])
        XCTAssertEqual(batches.flatMap(\.events).map(\.id), records.map(\.event.id), "oldest first, none lost")
    }

    func testBatchesStayUnderTheSizeLimit() throws {
        let bulk = JSONValue.object(["filler": .string(String(repeating: "x", count: 15_000))])
        let records = (0..<60).map { DiagnosticsFixtures.record(DiagnosticsFixtures.event("A.n@X.swift:\($0)", context: bulk)) }
        let batches = DiagnosticsUploader.batches(records) { app, os, events in
            DiagnosticsUpload(key: "k", install: "i", app: app, os: os, hw: "h", locale: "l", sentAt: Date(), events: events)
        }
        XCTAssertGreaterThan(batches.count, 1)
        for batch in batches {
            XCTAssertLessThanOrEqual(try DiagnosticsJSON.encoder.encode(batch).count, DiagnosticsUploader.maxBodyBytes)
        }
        XCTAssertEqual(batches.reduce(0) { $0 + $1.events.count }, 60)
    }

    func testEachBatchCarriesTheBuildItsEventsHappenedUnder() {
        let old = DiagnosticsApp(version: "1.9.0", build: "99", channel: "release")
        let records = [DiagnosticsFixtures.record(DiagnosticsFixtures.event("A.a@X.swift:1"), app: old),
                       DiagnosticsFixtures.record(DiagnosticsFixtures.event("A.b@X.swift:2")),
                       DiagnosticsFixtures.record(DiagnosticsFixtures.event("A.c@X.swift:3"), app: old)]
        let batches = DiagnosticsUploader.batches(records) { app, os, events in
            DiagnosticsUpload(key: "k", install: "i", app: app, os: os, hw: "h", locale: "l", sentAt: Date(), events: events)
        }
        XCTAssertEqual(batches.map(\.app.version), ["1.9.0", "1.10.0"])
        XCTAssertEqual(batches.map(\.events.count), [2, 1])
    }

    // MARK: The request

    func testPostFollowsAppsScriptRedirectToSuccess() async throws {
        FakeDiagnosticsServer.respond { [echo] request, _ in
            request.httpMethod == "POST" ? .redirect(to: echo) : .json(#"{"ok":true,"accepted":2,"duplicates":0}"#)
        }
        let receipt = try await uploader.send(upload([DiagnosticsFixtures.event("A.a@X.swift:1"), DiagnosticsFixtures.event("A.b@X.swift:2")]))
        XCTAssertEqual(receipt, DiagnosticsUploader.Receipt(accepted: 2, duplicates: 0))

        let requests = FakeDiagnosticsServer.requests
        XCTAssertEqual(requests.map { $0.request.httpMethod }, ["POST", "GET"])
        XCTAssertEqual(requests[0].request.url, DiagnosticsFixtures.endpoint)
        XCTAssertEqual(requests[0].request.value(forHTTPHeaderField: "Content-Type"), "text/plain;charset=utf-8")
        XCTAssertNil(requests[0].request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(requests[1].request.url?.absoluteString, echo)

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[0].body) as? [String: Any])
        XCTAssertEqual(body["schema"] as? Int, 1)
        XCTAssertEqual(body["key"] as? String, "ingest-key")
        XCTAssertEqual(body["install"] as? String, "INSTALL")
        XCTAssertEqual(body["os"] as? String, "macOS 26.6 (25G5023)")
        XCTAssertEqual(body["hw"] as? String, "MacBookPro18,3")
        XCTAssertEqual(body["locale"] as? String, "en_GB")
        XCTAssertEqual(body["sentAt"] as? String, DiagnosticsJSON.iso(Date(timeIntervalSince1970: 1_790_000_000)))
        XCTAssertEqual(body["app"] as? [String: String], ["version": "1.10.0", "build": "123", "channel": "release"])
        let event = try XCTUnwrap((body["events"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(event.keys), ["id", "kind", "signature", "title", "area", "count", "firstAt", "lastAt", "message", "context", "account"])
        XCTAssertTrue(event["account"] is NSNull)
        XCTAssertLessThanOrEqual(requests[0].body.count, DiagnosticsUploader.maxBodyBytes)
    }

    func testFailuresAreTold() async {
        let cases: [(FakeDiagnosticsServer.Reply?, DiagnosticsUploadError)] = [
            (.json(#"{"ok":false,"error":"bad key"}"#), .refused("bad key")),
            (FakeDiagnosticsServer.Reply(status: 200, body: Data("<html>Sign in</html>".utf8)), .badResponse),
            (.json(#"{"ok":true}"#, status: 500), .http(500)),
            (nil, .offline),
        ]
        for (reply, expected) in cases {
            FakeDiagnosticsServer.respond { _, _ in reply }
            do {
                _ = try await uploader.send(upload([DiagnosticsFixtures.event()]))
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? DiagnosticsUploadError, expected)
            }
        }
    }

    // MARK: Schedule

    func testScheduleFirstHourlyAndUrgent() {
        let launch = Date(timeIntervalSince1970: 1_790_000_000)
        var schedule = DiagnosticsSchedule(launchedAt: launch)
        XCTAssertEqual(schedule.nextAttempt, launch.addingTimeInterval(60))
        schedule.succeeded(at: launch.addingTimeInterval(60))
        XCTAssertEqual(schedule.nextAttempt, launch.addingTimeInterval(60 + 3_600))
        schedule.urgent(at: launch.addingTimeInterval(600))
        XCTAssertEqual(schedule.nextAttempt, launch.addingTimeInterval(660))
        schedule.urgent(at: launch.addingTimeInterval(630))
        XCTAssertEqual(schedule.nextAttempt, launch.addingTimeInterval(660), "never later than already due")
    }

    func testBackoffGrowsWithJitterAndStopsAtSixHours() {
        var previous: TimeInterval = 0
        for failures in 1...12 {
            let middle = DiagnosticsSchedule.backoff(failures: failures, jitter: 0.5)
            XCTAssertGreaterThanOrEqual(middle, previous)
            XCTAssertLessThanOrEqual(DiagnosticsSchedule.backoff(failures: failures, jitter: 0), middle)
            XCTAssertGreaterThanOrEqual(DiagnosticsSchedule.backoff(failures: failures, jitter: 0.999), middle)
            XCTAssertLessThanOrEqual(DiagnosticsSchedule.backoff(failures: failures, jitter: 0.999), 6 * 3_600)
            previous = middle
        }
        XCTAssertEqual(DiagnosticsSchedule.backoff(failures: 1, jitter: 0.5), 120)
        XCTAssertEqual(DiagnosticsSchedule.backoff(failures: 30, jitter: 1), 6 * 3_600)

        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var schedule = DiagnosticsSchedule(launchedAt: now)
        schedule.failed(at: now, jitter: 0.5)
        schedule.failed(at: now, jitter: 0.5)
        XCTAssertEqual(schedule.failures, 2)
        XCTAssertEqual(schedule.nextAttempt, now.addingTimeInterval(240))
        schedule.offline(at: now)
        XCTAssertEqual(schedule.failures, 2, "offline does not count against the server")
        XCTAssertEqual(schedule.nextAttempt, now.addingTimeInterval(600))
        schedule.succeeded(at: now)
        XCTAssertEqual(schedule.failures, 0)
    }
}
