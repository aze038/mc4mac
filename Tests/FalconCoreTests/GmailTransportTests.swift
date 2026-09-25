import XCTest
@testable import FalconCore

final class GmailTransportTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Log.isEnabled = false
    }

    override func tearDown() {
        Log.isEnabled = true
        super.tearDown()
    }

    /// Google's prices for projects created from 1 May 2026, from its quota page of 10 September
    /// 2026. A call priced too low lets FalconMail spend past its half of the user's budget.
    func testEveryCallIsPricedAsGoogleCharges() {
        let prices: [GmailMethod: Int] = [
            .profile: 1, .labelsList: 1, .labelsGet: 1, .labelsCreate: 5, .sendAsList: 1,
            .messagesList: 5, .messagesGet: 20, .attachmentsGet: 20, .threadsGet: 40, .historyList: 2,
            .messagesModify: 5, .messagesBatchModify: 50, .messagesBatchDelete: 50, .messagesTrash: 20, .messagesUntrash: 5,
            .messagesSend: 100, .messagesImport: 25, .messagesInsert: 25,
            .draftsCreate: 10, .draftsUpdate: 15, .draftsDelete: 10, .draftsList: 5
        ]
        XCTAssertEqual(Set(prices.keys), Set(GmailMethod.allCases), "every call FalconMail makes has a price")
        for method in GmailMethod.allCases {
            XCTAssertEqual(method.units, prices[method], method.rawValue)
        }
    }

    func testTheLimiterBooksTwentyUnitsForAnAttachment() async throws {
        let clock = VirtualClock()
        let limiter = clock.limiter()
        try await limiter.acquire(.attachmentsGet)
        let first = await limiter.spent[.attachmentsGet]
        XCTAssertEqual(first, 20)

        // 150 attachments at 20 units fill a minute of 3,000; at the old price of 5 they took a
        // quarter of it, and 600 could go in one minute.
        for _ in 1..<150 { try await limiter.acquire(.attachmentsGet) }
        XCTAssertEqual(clock.slept, 0)
        let spent = await limiter.spent[.attachmentsGet]
        XCTAssertEqual(spent, 3_000)
        try await limiter.acquire(.attachmentsGet)
        XCTAssertGreaterThan(clock.slept, 0, "the 151st waits for the minute to move on")
        let calls = await limiter.calls[.attachmentsGet]
        XCTAssertEqual(calls, 151)
    }

    func testOpeningAnAttachmentThroughTheClientCostsTwentyUnits() async throws {
        let mailbox = FakeGmailMailbox()
        let message = mailbox.add(subject: "Freight invoice", attachments: [
            .init(filename: "invoice.pdf", mimeType: "application/pdf", data: Data(repeating: 7, count: 2_000))
        ])
        let client = GmailTestKit.client(mailbox)
        let opened = try await client.openText(id: message.id)
        let stub = try XCTUnwrap(opened.listedAttachments.first)
        let data = try await client.attachmentData(messageID: message.id, stub: stub)
        XCTAssertEqual(data.count, 2_000)
        XCTAssertEqual(mailbox.units[.attachmentsGet], 20)
        let spent = await client.limiter.spent
        XCTAssertEqual(spent[.attachmentsGet], 20)
        XCTAssertEqual(spent[.messagesGet], 20)
    }

    func testABatchPartIsPricedAsTheCallItStandsFor() {
        XCTAssertEqual(GmailBatchPart.message(GmailMessageID(raw: 1), .row).method, .messagesGet)
        XCTAssertEqual(GmailBatchPart.thread(GmailThreadID(raw: 1), .row).method, .threadsGet)
        XCTAssertEqual(GmailBatchPart.label(.inbox).method, .labelsGet)
        // A landing of 25 rows, 40% of them conversations, as the design costs it.
        let landing = (0..<15).map { GmailBatchPart.message(GmailMessageID(raw: UInt64($0)), .row) }
            + (0..<10).map { GmailBatchPart.thread(GmailThreadID(raw: UInt64($0)), .row) }
        XCTAssertEqual(landing.reduce(0) { $0 + $1.method.units }, 700)
    }

    func testRefusalsTheEngineMustTellApartHaveTheirOwnKinds() {
        let kinds: [GoogleAPIError.Kind] = [.historyExpired, .domainPolicy, .gmailNotEnabled, .sendingLimit, .downloadLimit,
                                            .uploadLimit, .tooLarge]
        var codes: Set<String> = []
        for kind in kinds {
            let refusal = GoogleAPIError(kind: kind, httpStatus: 400)
            let sentence = refusal.errorDescription ?? ""
            XCTAssertFalse(sentence.isEmpty, kind.rawValue)
            XCTAssertFalse(sentence.localizedCaseInsensitiveContains("protocol"), sentence)
            XCTAssertTrue(refusal.searchNotice(email: "owner@example.com").contains("owner@example.com"), kind.rawValue)
            codes.insert(DiagnosticsSignature.code(forRefusal: refusal))
        }
        XCTAssertEqual(codes.count, kinds.count, "each has its own diagnostics code: \(codes.sorted())")
        XCTAssertEqual(DiagnosticsSignature.code(forRefusal: GoogleAPIError(kind: .uploadLimit)), "uploadPaused")
        XCTAssertEqual(GoogleAPIError(kind: .tooLarge).errorDescription,
                       "Gmail can't send more than 25 MB of attachments in one message. Remove some, or share them from Google Drive.")
    }
}
