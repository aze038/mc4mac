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
            .profile: 1, .labelsList: 1, .labelsGet: 1, .labelsCreate: 5, .labelsDelete: 5, .sendAsList: 1,
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

/// The Gmail engine's transport against the fake Gmail over HTTP: every call at its address and
/// its price, refusals sorted, retries only where they cannot do anything twice, and every byte
/// counted.
final class GmailHTTPTransportTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Log.isEnabled = false
    }

    override func tearDown() {
        Log.isEnabled = true
        super.tearDown()
    }

    private func raw(subject: String = "Hello", to: String = "someone@example.com", bcc: String? = nil,
                     messageID: String = "<m-\(UUID().uuidString)@falconmail.invalid>", date: Date = Date(),
                     extra: [String] = [], inReplyTo: String? = nil) -> Data {
        var lines = ["From: Owner <owner@example.com>", "To: \(to)", "Subject: \(subject)", "Date: \(RFC5322Date.format(date))",
                     "Message-ID: \(messageID)", "MIME-Version: 1.0"]
        if let bcc { lines.append("Bcc: \(bcc)") }
        if let inReplyTo { lines += ["In-Reply-To: \(inReplyTo)", "References: \(inReplyTo)"] }
        lines += extra
        lines.append("Content-Type: text/plain; charset=UTF-8")
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\nThe text of \(subject).\r\n").utf8)
    }

    // MARK: Every call

    func testEveryCallReachesItsEndpointAndCostsWhatGoogleCharges() async throws {
        let mailbox = FakeGmailMailbox()
        let first = mailbox.add(subject: "Invoice", labels: ["INBOX", "UNREAD"], attachments: [
            .init(filename: "a.pdf", mimeType: "application/pdf", data: Data(repeating: 3, count: 300))
        ])
        let second = mailbox.add(subject: "Reply", labels: ["INBOX"], threadID: first.threadID)
        let transport = GmailTestKit.transport(mailbox)
        let w = WorkClass.interactive
        let profile = try await transport.profile(work: w)
        XCTAssertEqual(profile.emailAddress, "owner@example.com")
        XCTAssertNotNil(profile.historyID)
        let labels = try await transport.labels(work: w)
        XCTAssertTrue(labels.contains { $0.id == "INBOX" })
        let inbox = try await transport.label(.inbox, work: w)
        XCTAssertEqual(inbox.messagesTotal, 2)
        XCTAssertEqual(inbox.messagesUnread, 1)
        let created = try await transport.createLabel(named: "Clients", work: w)
        XCTAssertTrue(created.isUserLabel)
        let sendAs = try await transport.sendAs(work: w)
        XCTAssertEqual(sendAs.map(\.sendAsEmail), ["owner@example.com"])
        let page = try await transport.list(GmailListQuery(labels: [.inbox]), work: w)
        XCTAssertEqual(page.refs.map(\.id.hex), [second.id, first.id])
        let firstID = try XCTUnwrap(GmailMessageID(hex: first.id))
        let message = try await transport.message(firstID, format: .full, work: w)
        let attachmentID = try XCTUnwrap(message.payload?.parts?.last?.body?.attachmentId)
        let bytes = try await transport.attachment(attachmentID, of: firstID, work: w)
        XCTAssertEqual(bytes, Data(repeating: 3, count: 300))
        let thread = try await transport.thread(try XCTUnwrap(GmailThreadID(hex: first.threadID)), format: .minimal, work: w)
        XCTAssertEqual(thread.messages?.map(\.id), [first.id, second.id], "a thread lists its messages oldest first")
        let start = try XCTUnwrap(profile.historyID)
        let modified = try await transport.modify(firstID, adding: [.starred], removing: [.unread], work: w)
        XCTAssertEqual(modified.labels, [.inbox, .starred])
        let history = try await transport.history(since: start, types: Set(GmailHistoryType.allCases), label: nil, pageToken: nil, work: w)
        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(history.records.first?.labelsAdded.first?.labels, [.starred])
        XCTAssertEqual(history.records.first?.labelsRemoved.first?.labels, [.unread])
        try await transport.batchModify([firstID], adding: [created.labelID], removing: [], work: w)
        _ = try await transport.trash(firstID, work: w)
        _ = try await transport.untrash(firstID, work: w)
        let sent = try await transport.send(raw(subject: "Out"), threadID: nil, work: w)
        XCTAssertEqual(sent.labels, [.sent])
        let imported = try await transport.importMessage(raw(subject: "Old", date: Date(timeIntervalSince1970: 1_500_000_000)),
                                                         labels: [created.labelID], options: GmailImportOptions(), work: .background(.transfer))
        XCTAssertEqual(imported.labels, [created.labelID])
        let inserted = try await transport.insertMessage(raw(subject: "Inserted"), labels: [.inbox], work: w)
        let draft = try await transport.createDraft(raw(subject: "Draft"), threadID: nil, work: w)
        let updated = try await transport.updateDraft(draft.id, raw: raw(subject: "Draft again"), threadID: nil, work: w)
        XCTAssertEqual(updated.id, draft.id)
        XCTAssertNotEqual(updated.message?.id, draft.message?.id, "Gmail gives a draft a new message at every save")
        let drafts = try await transport.drafts(pageToken: nil, work: w)
        XCTAssertEqual(drafts.drafts?.map(\.id), [draft.id])
        try await transport.deleteDraft(draft.id, work: w)
        try await transport.batchDelete([try XCTUnwrap(inserted.gmailID)], work: w)
        try await transport.deleteLabel(created.labelID, work: w)
        let answers = try await transport.batch([.message(firstID, .row), .label(.inbox)], work: w)
        XCTAssertEqual(answers.count, 2)

        let expected: [GmailMethod: Int] = [
            .profile: 1, .labelsList: 1, .labelsGet: 2, .labelsCreate: 5, .labelsDelete: 5, .sendAsList: 1, .messagesList: 5,
            .messagesGet: 40, .attachmentsGet: 20, .threadsGet: 40, .historyList: 2, .messagesModify: 5, .messagesBatchModify: 50,
            .messagesTrash: 20, .messagesUntrash: 5, .messagesSend: 100, .messagesImport: 25, .messagesInsert: 25,
            .draftsCreate: 10, .draftsUpdate: 15, .draftsList: 5, .draftsDelete: 10, .messagesBatchDelete: 50
        ]
        XCTAssertEqual(mailbox.units, expected, "Gmail's own count")
        let usage = await transport.usage()
        XCTAssertEqual(usage.units, expected, "the budget books exactly what Gmail charges")
        XCTAssertEqual(Set(expected.keys), Set(GmailMethod.allCases), "every call FalconMail makes was made")
    }

    func testPlusIsPercentEncodedInEveryQuery() async throws {
        let mailbox = FakeGmailMailbox()
        mailbox.add(subject: "Plus addressing", from: "a+b@x.com")
        mailbox.add(subject: "Someone else", from: "a b@x.com")
        let transport = GmailTestKit.transport(mailbox)
        let page = try await transport.list(GmailListQuery(query: "from:a+b@x.com"), work: .interactive)
        XCTAssertEqual(page.refs.count, 1)
        XCTAssertTrue(mailbox.rawQueries.last?.contains("q=from%3Aa%2Bb%40x.com") == true, mailbox.rawQueries.last ?? "")
    }

    func testIDsGmailSendsThatDoNotParseAreLeftOutAndCounted() {
        let reply = try! JSONDecoder().decode(GmailMessageList.self, from: Data(#"{"messages":[{"id":"18a0f","threadId":"18a0f"},{"id":"0x12","threadId":"1"},{"id":"18A0","threadId":"18a0"}],"resultSizeEstimate":3}"#.utf8))
        let page = GmailWire.listPage(reply)
        XCTAssertEqual(page.refs.map(\.id.hex), ["18a0f"])
        XCTAssertEqual(page.refusedIDs, 2)

        let history = try! JSONDecoder().decode(GmailHistoryReply.self, from: Data(#"{"history":[{"id":"12","messagesAdded":[{"message":{"id":"zz","threadId":"1"}},{"message":{"id":"1f","threadId":"1f","labelIds":["INBOX"]}}]},{"id":"x","messagesAdded":[{"message":{"id":"2f","threadId":"2f"}}]}],"historyId":"15"}"#.utf8))
        let converted = GmailWire.historyPage(history, since: HistoryID(raw: 10))
        XCTAssertEqual(converted.records.map(\.id.raw), [12])
        XCTAssertEqual(converted.records.first?.messagesAdded.map(\.ref.id.hex), ["1f"])
        XCTAssertEqual(converted.records.first?.messagesAdded.first?.labels, [.inbox])
        XCTAssertEqual(converted.historyID.raw, 15)
    }

    func testHistoryPagesInOrderAndA404MeansTheHistoryHasExpired() async throws {
        let mailbox = FakeGmailMailbox()
        let transport = GmailTestKit.transport(mailbox)
        let start = HistoryID(raw: mailbox.historyID)
        let a = mailbox.deliver(subject: "A")
        mailbox.delete(a.id)
        let b = mailbox.deliver(subject: "B")
        mailbox.relabel(b.id, adding: ["STARRED"])
        var records: [GmailHistoryRecord] = []
        var token: String?
        var pages = 0
        repeat {
            let page = try await transport.history(since: start, types: Set(GmailHistoryType.allCases), label: nil, pageToken: token,
                                                   work: .checks)
            records += page.records
            token = page.nextPageToken
            pages += 1
        } while token != nil
        XCTAssertEqual(records.count, 4)
        XCTAssertEqual(records.map(\.id), records.map(\.id).sorted())
        XCTAssertEqual(records[0].messagesAdded.first?.ref.id.hex, a.id)
        XCTAssertEqual(records[1].messagesDeleted.first?.ref.id.hex, a.id, "an add and a delete of one message in one page")
        XCTAssertEqual(records[3].labelsAdded.first?.labels, [.starred])

        mailbox.expireHistory()
        do {
            _ = try await transport.history(since: start, types: [.messageAdded], label: nil, pageToken: nil, work: .checks)
            XCTFail("history below the floor has expired")
        } catch let refusal as GoogleAPIError {
            XCTAssertEqual(refusal.kind, .historyExpired)
            XCTAssertFalse(refusal.waits)
        }
        XCTAssertEqual(mailbox.attempts[.historyList], pages + 1, "an expired history is not asked again")
    }

    // MARK: Refusals

    func testEachForbiddenReasonIsSortedAndOnlyRateReasonsAreTriedAgain() async throws {
        let cases: [(FakeGmailMailbox.Fault, GoogleAPIError.Kind, Bool)] = [
            (.forbidden("rateLimitExceeded"), .rateLimited, true),
            (.forbidden("userRateLimitExceeded"), .rateLimited, true),
            (.forbidden("dailyLimitExceeded"), .quotaExhausted, true),
            (.forbidden("quotaExceeded"), .quotaExhausted, true),
            (.forbidden("domainPolicy"), .domainPolicy, false),
            (.google(403, reason: "domainPolicy", message: "The domain administrators have disabled Gmail apps."), .domainPolicy, false),
            (.forbidden("insufficientPermissions"), .insufficientPermissions, false),
            (.forbidden("accessNotConfigured"), .apiDisabled, false),
            (.forbidden("SERVICE_DISABLED"), .apiDisabled, false),
            (.forbidden("forbidden"), .other, false),
            (.status(400, reason: "failedPrecondition"), .gmailNotEnabled, false),
            (.status(413, reason: nil), .tooLarge, false),
            (.status(400, reason: "invalidArgument"), .other, false)
        ]
        for (fault, kind, waits) in cases {
            let mailbox = FakeGmailMailbox()
            mailbox.add(subject: "x")
            // A rate refusal is tried again after a second; the fake refuses once and then answers.
            mailbox.inject(fault, for: .messagesList)
            let clock = VirtualClock()
            let transport = GmailTestKit.transport(mailbox, clock: clock)
            do {
                let page = try await transport.list(GmailListQuery(), work: .interactive)
                XCTAssertEqual(kind, .rateLimited, "only a rate refusal is tried again: \(fault)")
                XCTAssertEqual(page.refs.count, 1)
                XCTAssertEqual(mailbox.attempts[.messagesList], 2)
            } catch let refusal as GoogleAPIError {
                XCTAssertEqual(refusal.kind, kind, "\(fault)")
                XCTAssertEqual(refusal.waits, waits, "\(fault)")
                XCTAssertEqual(refusal.delivery, .answered)
                XCTAssertEqual(mailbox.attempts[.messagesList], 1, "\(fault) is not tried again")
            }
        }
    }

    func testUploadAndDownloadAllowancesAreToldApartFromTheRateLimit() async throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func refusal(_ fault: FakeGmailMailbox.Fault, on method: GmailMethod) async -> GoogleAPIError? {
            let mailbox = FakeGmailMailbox()
            let message = mailbox.add(subject: "x")
            mailbox.always(fault, for: method)
            let clock = VirtualClock(start: now)
            let transport = GmailTestKit.transport(mailbox, clock: clock)
            do {
                switch method {
                case .messagesGet: _ = try await transport.message(GmailMessageID(hex: message.id)!, format: .full, work: .interactive)
                case .messagesSend: _ = try await transport.send(raw(), threadID: nil, work: .interactive)
                case .draftsCreate: _ = try await transport.createDraft(raw(), threadID: nil, work: .interactive)
                case .messagesModify:
                    _ = try await transport.modify(GmailMessageID(hex: message.id)!, adding: [.starred], removing: [], work: .interactive)
                default: XCTFail("not asked")
                }
                return nil
            } catch let refusal as GoogleAPIError {
                return refusal
            } catch {
                return nil
            }
        }
        let download = await refusal(.bandwidth(retryAfter: 7_200), on: .messagesGet)
        XCTAssertEqual(download?.kind, .downloadLimit)
        XCTAssertEqual(download?.retryAfter, 7_200)
        let upload = await refusal(.bandwidth(retryAfter: 7_200), on: .messagesSend)
        XCTAssertEqual(upload?.kind, .uploadLimit)
        let draft = await refusal(.bandwidth(retryAfter: 7_200), on: .draftsCreate)
        XCTAssertEqual(draft?.kind, .uploadLimit)
        let sending = await refusal(.sendingLimit(until: now.addingTimeInterval(5 * 3_600)), on: .messagesSend)
        XCTAssertEqual(sending?.kind, .sendingLimit)
        XCTAssertEqual(sending?.retryAfter ?? 0, 5 * 3_600, accuracy: 1, "Gmail gives the retry time in its message")
        let change = await refusal(.bandwidth(retryAfter: 7_200), on: .messagesModify)
        XCTAssertEqual(change?.kind, .rateLimited, "a label change moves no bytes worth an allowance")
        for kind in [download, upload, sending].compactMap({ $0?.kind }) {
            XCTAssertTrue(GoogleAPIError(kind: kind).waits)
            XCTAssertNotEqual(DiagnosticsSignature.code(forRefusal: GoogleAPIError(kind: kind)), "throttled")
        }
    }

    func testTheWordsGoogleUsesOnlyChooseWhichWaitApplies() {
        func parse(_ message: String, retry: String? = nil, method: GmailMethod = .messagesSend) -> GoogleAPIError {
            let body = try! JSONSerialization.data(withJSONObject: ["error": ["code": 429, "message": message,
                                                                              "errors": [["reason": "rateLimitExceeded", "message": message]]]])
            return GoogleErrorParser.parse(status: 429, body: body, retryAfter: retry, method: method)
        }
        XCTAssertEqual(parse("User-rate limit exceeded (Mail sending)").kind, .sendingLimit)
        XCTAssertTrue(parse("Too many concurrent requests for user", method: .messagesGet).isConcurrencyLimit)
        XCTAssertEqual(parse("Too many concurrent requests for user", method: .messagesGet).kind, .rateLimited)
        // Reworded, each is still a wait, never a definite refusal.
        for reworded in ["Sending quota reached", "Too many parallel calls", "Slow down"] {
            let refusal = parse(reworded, retry: "30", method: .messagesGet)
            XCTAssertEqual(refusal.kind, .rateLimited, reworded)
            XCTAssertTrue(refusal.waits, reworded)
            XCTAssertFalse(refusal.isConcurrencyLimit, reworded)
        }
        // Without a method, as v1.10.0's search reads refusals, nothing changes.
        let legacy = GoogleErrorParser.parse(status: 429, body: Data(#"{"error":{"code":429,"message":"User-rate limit exceeded (Mail sending)","errors":[{"reason":"rateLimitExceeded"}]}}"#.utf8))
        XCTAssertEqual(legacy.kind, .rateLimited)
        XCTAssertEqual(GoogleErrorParser.parse(status: 403, body: Data(#"{"error":{"code":403,"errors":[{"reason":"domainPolicy"}]}}"#.utf8)).kind, .other)
    }

    func testRetryAfterIsWaitedOutAndALongerOneIsHandedBack() async throws {
        let mailbox = FakeGmailMailbox()
        let message = mailbox.add(subject: "Busy")
        mailbox.inject(.rateLimited(retryAfter: "3"), for: .messagesGet)
        let clock = VirtualClock()
        let transport = GmailTestKit.transport(mailbox, clock: clock)
        let id = try XCTUnwrap(GmailMessageID(hex: message.id))
        let fetched = try await transport.message(id, format: .row, work: .interactive)
        XCTAssertEqual(fetched.id, message.id)
        XCTAssertEqual(mailbox.attempts[.messagesGet], 2)
        XCTAssertGreaterThanOrEqual(clock.slept, 3, "the retry waited for Retry-After")

        mailbox.always(.rateLimited(retryAfter: "600"), for: .messagesList)
        let before = mailbox.attempts[.messagesList] ?? 0
        do {
            _ = try await transport.list(GmailListQuery(), work: .interactive)
            XCTFail("a ten-minute pause is handed back")
        } catch let refusal as GoogleAPIError {
            XCTAssertEqual(refusal.kind, .rateLimited)
            XCTAssertEqual(refusal.retryAfter ?? 0, 600, accuracy: 1)
        }
        XCTAssertEqual((mailbox.attempts[.messagesList] ?? 0) - before, 1, "nothing more is sent while Retry-After runs")
        let pause = await transport.pause()
        XCTAssertEqual(pause?.refusal.kind, .rateLimited)
        XCTAssertEqual(pause?.until.timeIntervalSince(clock.now) ?? 0, 600, accuracy: 1)
    }

    func testServerErrorsBackOffAsGoogleAdvisesAndGiveUpAfterFiveTries() async throws {
        let mailbox = FakeGmailMailbox()
        mailbox.add(subject: "x")
        mailbox.inject(.serverError, for: .messagesList, times: 3)
        let clock = VirtualClock()
        let transport = GmailTestKit.transport(mailbox, clock: clock)
        let page = try await transport.list(GmailListQuery(), work: .interactive)
        XCTAssertEqual(page.refs.count, 1)
        XCTAssertEqual(clock.slept, 1 + 2 + 4, accuracy: 0.01, "at least a second first, then doubling")

        mailbox.always(.serverError, for: .labelsList)
        let slept = clock.slept
        do {
            _ = try await transport.labels(work: .interactive)
            XCTFail("expected a refusal")
        } catch let refusal as GoogleAPIError {
            XCTAssertEqual(refusal.kind, .temporary)
            XCTAssertEqual(refusal.delivery, .unknown)
        }
        XCTAssertEqual(mailbox.attempts[.labelsList], 5)
        XCTAssertEqual(clock.slept - slept, 1 + 2 + 4 + 8, accuracy: 0.01)

        // Past 64 seconds the backoff stops growing.
        let budget = GmailBudget(accountID: UUID(), sleep: GmailWait.sleep, jitter: { 0.5 })
        XCTAssertEqual(budget.backoff(0), 1.5)
        XCTAssertEqual(budget.backoff(3), 8.5)
        XCTAssertEqual(budget.backoff(10), 64)
    }

    func testTimeoutsOfReadsAreTriedAgainAndOfflineIsNot() async throws {
        let mailbox = FakeGmailMailbox()
        mailbox.add(subject: "x")
        mailbox.inject(.timeout, for: .messagesList)
        let transport = GmailTestKit.transport(mailbox)
        let page = try await transport.list(GmailListQuery(), work: .interactive)
        XCTAssertEqual(page.refs.count, 1)
        XCTAssertEqual(mailbox.attempts[.messagesList], 2)

        mailbox.always(.offline, for: .labelsList)
        do {
            _ = try await transport.labels(work: .interactive)
            XCTFail("expected offline")
        } catch let refusal as GoogleAPIError {
            XCTAssertEqual(refusal.kind, .offline)
            XCTAssertEqual(refusal.delivery, .notSent)
        }
        XCTAssertEqual(mailbox.attempts[.labelsList], 1)
    }

    // MARK: Never twice

    func testASendThatMayHaveReachedGmailIsNeverSentAgain() async throws {
        for fault in [FakeGmailMailbox.Fault.acceptedThenTimeout, .acceptedThenDropped] {
            let mailbox = FakeGmailMailbox()
            let transport = GmailTestKit.transport(mailbox)
            mailbox.inject(fault, for: .messagesSend)
            do {
                _ = try await transport.send(raw(subject: "Quote"), threadID: nil, work: .interactive)
                XCTFail("the answer never came")
            } catch let refusal as GoogleAPIError {
                XCTAssertEqual(refusal.delivery, .unknown, "\(fault)")
            }
            XCTAssertEqual(mailbox.attempts[.messagesSend], 1, "\(fault)")
            XCTAssertEqual(mailbox.messages.filter { $0.labels.contains("SENT") }.count, 1, "Gmail sent it once, and only once")
        }

        let mailbox = FakeGmailMailbox()
        let transport = GmailTestKit.transport(mailbox)
        mailbox.inject(.serverError, for: .messagesSend)
        do {
            _ = try await transport.send(raw(), threadID: nil, work: .interactive)
            XCTFail("a server error leaves it unclear")
        } catch let refusal as GoogleAPIError {
            XCTAssertEqual(refusal.kind, .temporary)
            XCTAssertEqual(refusal.delivery, .unknown)
        }
        XCTAssertEqual(mailbox.attempts[.messagesSend], 1)

        // A rate refusal is Gmail saying no before doing anything, so it is tried again.
        mailbox.inject(.rateLimited(retryAfter: "1"), for: .messagesSend)
        _ = try await transport.send(raw(), threadID: nil, work: .interactive)
        XCTAssertEqual(mailbox.attempts[.messagesSend], 3)

        // The same holds for a new draft and an import; an update names its draft and may repeat.
        mailbox.inject(.acceptedThenTimeout, for: .draftsCreate)
        _ = try? await transport.createDraft(raw(), threadID: nil, work: .interactive)
        XCTAssertEqual(mailbox.attempts[.draftsCreate], 1)
        mailbox.inject(.acceptedThenTimeout, for: .messagesImport)
        _ = try? await transport.importMessage(raw(), labels: [.inbox], options: GmailImportOptions(), work: .background(.transfer))
        XCTAssertEqual(mailbox.attempts[.messagesImport], 1)
        let draft = try await transport.createDraft(raw(), threadID: nil, work: .interactive)
        mailbox.inject(.timeout, for: .draftsUpdate)
        _ = try await transport.updateDraft(draft.id, raw: raw(subject: "Again"), threadID: nil, work: .interactive)
        XCTAssertEqual(mailbox.attempts[.draftsUpdate], 2)
    }

    func testUploadsCarryTheMessageUnchangedWithItsBccAndThread() async throws {
        let mailbox = FakeGmailMailbox()
        let original = mailbox.add(subject: "Quote", messageID: "<quote@x>")
        let transport = GmailTestKit.transport(mailbox)
        let message = raw(subject: "Re: Quote", bcc: "Boss <boss@example.com>", inReplyTo: "<quote@x>")
        let sent = try await transport.send(message, threadID: GmailThreadID(hex: original.threadID), work: .interactive)
        XCTAssertEqual(mailbox.sentUploads, [message], "the upload is the message byte for byte")
        XCTAssertEqual(sent.threadId, original.threadID)
        XCTAssertTrue(message.utf8Lossy.contains("Bcc: Boss <boss@example.com>"))

        let big = Data(count: GmailUpload.maxMessageBytes + 1)
        do {
            _ = try await transport.send(big, threadID: nil, work: .interactive)
            XCTFail("too large")
        } catch let refusal as GoogleAPIError {
            XCTAssertEqual(refusal.kind, .tooLarge)
            XCTAssertEqual(refusal.delivery, .notSent)
        }
        XCTAssertEqual(mailbox.attempts[.messagesSend], 1, "a message over Gmail's limit costs nothing")

        let (body, contentType) = GmailUpload.body(metadata: Data(#"{"threadId":"1f"}"#.utf8), message: message)
        let parsed = try XCTUnwrap(GmailUpload.parse(body, contentType: contentType))
        XCTAssertEqual(parsed.message, message)
        XCTAssertEqual(parsed.metadata, Data(#"{"threadId":"1f"}"#.utf8))
        XCTAssertTrue(contentType.hasPrefix("multipart/related; boundary="))
    }

    func testAnImportIsFiledByItsOwnDateAndLabels() async throws {
        let mailbox = FakeGmailMailbox()
        mailbox.add(subject: "Newer")
        let transport = GmailTestKit.transport(mailbox)
        let label = try await transport.createLabel(named: "Archive 2017", work: .interactive)
        let date = Date(timeIntervalSince1970: 1_500_000_000)
        let imported = try await transport.importMessage(raw(subject: "From 2017", date: date), labels: [label.labelID],
                                                         options: GmailImportOptions(), work: .background(.transfer))
        XCTAssertEqual(imported.labels, [label.labelID])
        let full = try await transport.message(try XCTUnwrap(imported.gmailID), format: .minimal, work: .interactive)
        XCTAssertEqual(full.receivedDate?.timeIntervalSince1970 ?? 0, 1_500_000_000, accuracy: 1)
        let page = try await transport.list(GmailListQuery(), work: .interactive)
        XCTAssertEqual(page.refs.last?.id, imported.gmailID, "it sits among old mail, not at the top")
        XCTAssertTrue(mailbox.bookings.contains { $0.method == .messagesImport })
    }

    func testBulkCallsTakeAtMostAThousandIdsAndNothingIsSentForNone() async throws {
        let mailbox = FakeGmailMailbox()
        let transport = GmailTestKit.transport(mailbox)
        let ids = (1...1_001).map { GmailMessageID(raw: UInt64($0)) }
        do {
            try await transport.batchModify(ids, adding: [.starred], removing: [], work: .bulk)
            XCTFail("more than 1,000")
        } catch let refusal as GoogleAPIError {
            XCTAssertEqual(refusal.delivery, .notSent)
        }
        do {
            try await transport.batchDelete(ids, work: .bulk)
            XCTFail("more than 1,000")
        } catch {}
        try await transport.batchModify([], adding: [.starred], removing: [], work: .bulk)
        try await transport.batchModify(Array(ids.prefix(3)), adding: [], removing: [], work: .bulk)
        XCTAssertEqual(mailbox.attempts, [:])
    }

    func testModifyRefusesWhatGmailRefuses() async throws {
        let mailbox = FakeGmailMailbox()
        let message = mailbox.add(subject: "x")
        let transport = GmailTestKit.transport(mailbox)
        let id = try XCTUnwrap(GmailMessageID(hex: message.id))
        do {
            _ = try await transport.modify(id, adding: [.sent], removing: [], work: .interactive)
            XCTFail("SENT cannot be added")
        } catch let refusal as GoogleAPIError {
            XCTAssertEqual(refusal.httpStatus, 400)
            XCTAssertFalse(refusal.waits)
        }
        do {
            _ = try await transport.modify(id, adding: ["Label_99"], removing: [], work: .interactive)
            XCTFail("a label that is gone")
        } catch let refusal as GoogleAPIError {
            XCTAssertEqual(refusal.kind, .notFound)
        }
        do {
            _ = try await transport.modify(GmailMessageID(raw: 0xdead), adding: [.starred], removing: [], work: .interactive)
            XCTFail("a message that is gone")
        } catch let refusal as GoogleAPIError {
            XCTAssertEqual(refusal.kind, .notFound)
        }
    }

    func testAnUnauthorizedCallRefreshesTheTokenOnce() async throws {
        let mailbox = FakeGmailMailbox()
        mailbox.acceptedTokens = ["token-2"]
        let tokens = FakeTokenSource(current: "token-1", afterRefresh: "token-2")
        let transport = GmailTestKit.transport(mailbox, tokens: tokens)
        let profile = try await transport.profile(work: .checks)
        XCTAssertEqual(profile.emailAddress, mailbox.email)
        let refreshes = await tokens.refreshes
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(mailbox.attempts[.profile], 2)

        mailbox.acceptedTokens = ["never"]
        do {
            _ = try await transport.labels(work: .checks)
            XCTFail("needs signing in")
        } catch let refusal as GoogleAPIError {
            XCTAssertEqual(refusal.kind, .needsSignIn)
        }
        XCTAssertEqual(mailbox.attempts[.labelsList], 2)
    }

    // MARK: Bytes

    func testEveryByteIsMeteredAgainstTheAPIBudgets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("falcon-g1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = VirtualClock()
        let meter = TrafficMeter(layout: FileLayout(root: root), now: { clock.now })
        let account = UUID()
        let mailbox = FakeGmailMailbox()
        for i in 0..<5 { mailbox.add(subject: "Message \(i)", text: String(repeating: "x", count: 2_000)) }
        let transport = GmailTestKit.transport(mailbox, clock: clock, accountID: account, meter: meter)
        let page = try await transport.list(GmailListQuery(), work: .interactive)
        _ = try await transport.batch(page.refs.map { .message($0.id, .full) }, work: .background(.cacheFill))
        let message = raw(subject: "Imported")
        _ = try await transport.importMessage(message, labels: [.inbox], options: GmailImportOptions(), work: .background(.transfer))
        _ = try await transport.send(raw(subject: "Sent"), threadID: nil, work: .interactive)

        let usage = await transport.usage()
        XCTAssertGreaterThan(usage.bytesDown, 10_000)
        XCTAssertEqual(meter.usedAPI(.download, by: account), usage.bytesDown)
        XCTAssertEqual(meter.usedAPI(.upload, by: account), usage.bytesUp)
        XCTAssertGreaterThan(meter.usedAPI(.background, by: account), 10_000, "the batch was background work")
        XCTAssertLessThan(meter.usedAPI(.background, by: account), usage.bytesDown)
        XCTAssertGreaterThan(meter.usedAPI(.imports, by: account), message.count, "the whole upload counts, not only the message")
        XCTAssertLessThan(meter.usedAPI(.imports, by: account), usage.bytesUp)
        XCTAssertEqual(meter.used(.download, by: account), 0, "the API's bytes are not IMAP's")
        let served = mailbox.bytesServed.values.reduce(0, +)
        XCTAssertGreaterThan(usage.bytesDown, served, "a batch's framing counts as well as its answers")
        let received = mailbox.bytesReceived.values.reduce(0, +)
        XCTAssertGreaterThanOrEqual(usage.bytesUp, received)
    }

    // MARK: Opening through the engine's budget

    func testTheReadHelpersBookThroughTheTransportsBudget() async throws {
        let mailbox = FakeGmailMailbox()
        let message = mailbox.add(subject: "Freight invoice", attachments: [
            .init(filename: "invoice.pdf", mimeType: "application/pdf", data: Data(repeating: 7, count: 2_000))
        ])
        let transport = GmailTestKit.transport(mailbox)
        let client = transport.client(work: .interactive)
        let opened = try await client.openText(id: message.id)
        let stub = try XCTUnwrap(opened.listedAttachments.first)
        let data = try await client.attachmentData(messageID: message.id, stub: stub)
        XCTAssertEqual(data.count, 2_000)
        let usage = await transport.usage()
        XCTAssertEqual(usage.units[.messagesGet], 20)
        XCTAssertEqual(usage.units[.attachmentsGet], 20)
        XCTAssertGreaterThan(usage.bytesDown, 2_000)
        let legacy = await client.limiter.spent
        XCTAssertEqual(legacy, [:], "v1.10.0's limiter is not used")
    }

    // MARK: Many at once

    func testAtMostFourRequestsAndThirtyFivePartsAreInFlightWithTwoKeptForClicks() async throws {
        let mailbox = FakeGmailMailbox()
        var ids: [GmailMessageID] = []
        for i in 0..<120 { ids.append(GmailMessageID(hex: mailbox.add(subject: "Row \(i)").id)!) }
        mailbox.batchDelay = 0.2
        mailbox.setDelay(0.2, for: .messagesGet)
        let transport = GmailTestKit.transport(mailbox, policy: GmailBudgetPolicy(capacity: 100_000, refillPerMinute: 1_000_000,
                                                                                    backgroundReserve: 0, backgroundPerMinuteWhileActive: 1_000_000))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for chunk in stride(from: 0, to: 100, by: 10) {
                let slice = Array(ids[chunk..<chunk + 10])
                group.addTask { _ = try await transport.batch(slice.map { .message($0, .row) }, work: .background(.cacheFill)) }
            }
            for chunk in stride(from: 0, to: 100, by: 25) {
                let slice = Array(ids[chunk..<chunk + 25])
                group.addTask { _ = try await transport.batch(slice.map { .message($0, .row) }, work: .interactive) }
            }
            for id in ids.suffix(20) {
                group.addTask { _ = try await transport.message(id, format: .row, work: .interactive) }
            }
            try await group.waitForAll()
        }
        XCTAssertLessThanOrEqual(mailbox.peakRequestsInFlight, 4)
        XCTAssertGreaterThan(mailbox.peakRequestsInFlight, 1)
        XCTAssertLessThanOrEqual(mailbox.peakPartsInFlight, 35)
        let peak = await transport.budget.peak
        XCTAssertLessThanOrEqual(peak.deferrableRequests, 2)
        XCTAssertLessThanOrEqual(peak.foregroundParts, 25)
        XCTAssertLessThanOrEqual(peak.backgroundParts, 10)
        XCTAssertTrue(mailbox.batchSizes.allSatisfy { $0 <= 25 })
    }

    // MARK: Sharing Google's per-user budget

    func testFalconMailAndAnotherAppImportingNeverPassSixThousandUnitsInAMinute() async throws {
        let clock = VirtualClock()
        let mailbox = FakeGmailMailbox(now: { clock.now })
        mailbox.userUnitsPerMinute = 6_000
        var ids: [GmailMessageID] = []
        for i in 0..<25 { ids.append(GmailMessageID(hex: mailbox.add(subject: "Row \(i)").id)!) }
        let transport = GmailTestKit.transport(mailbox, clock: clock)
        // FalconMail has seen the import in its history and keeps to its flood budget.
        await transport.setFloodMode(true)
        let other = FakeGmailURLProtocol.register(mailbox, client: "olm2cloud")
        let importURL = URL(string: other.absoluteString.replacingOccurrences(of: "/gmail/v1", with: "/upload/gmail/v1") + "/messages/import?uploadType=multipart")!
        var nextImport = clock.now
        let end = clock.now.addingTimeInterval(5 * 60)
        var landings = 0
        var refusedImports = 0
        while clock.now < end {
            while nextImport <= clock.now {
                // olm2cloud at 150 imports a minute.
                var request = URLRequest(url: importURL)
                request.httpMethod = "POST"
                let (body, type) = GmailUpload.body(metadata: Data(#"{"labelIds":["INBOX"]}"#.utf8), message: raw(subject: "Imported"))
                request.httpBody = body
                request.setValue(type, forHTTPHeaderField: "Content-Type")
                if case .success(let (response, _)) = mailbox.handle(request, client: "olm2cloud"), response.statusCode != 200 { refusedImports += 1 }
                nextImport = nextImport.addingTimeInterval(0.4)
            }
            _ = try await transport.batch(ids.map { .message($0, .row) }, work: .interactive)
            landings += 1
            clock.advance(0.5)
        }
        XCTAssertLessThanOrEqual(mailbox.peakUnitsInAnyMinute(client: FakeGmailMailbox.falconMail), 2_000)
        XCTAssertGreaterThan(mailbox.peakUnitsInAnyMinute(client: "olm2cloud"), 3_500)
        XCTAssertLessThanOrEqual(mailbox.peakUnitsInAnyMinute(), 6_000)
        XCTAssertEqual(refusedImports, 0, "together they stay inside Google's per-user budget")
        XCTAssertGreaterThan(landings, 15)
    }
}
