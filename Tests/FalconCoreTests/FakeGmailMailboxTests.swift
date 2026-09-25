import XCTest
@testable import FalconCore

/// The fake Gmail every Gmail engine test runs against keeps Google's rules, and its fixtures
/// have the shape the design's figures were worked out for.
final class FakeGmailMailboxTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Log.isEnabled = false
    }

    override func tearDown() {
        Log.isEnabled = true
        super.tearDown()
    }

    private func allIDs(_ transport: GmailHTTPTransport, _ query: GmailListQuery) async throws -> [GmailMessageID] {
        var query = query
        var out: [GmailMessageID] = []
        repeat {
            let page = try await transport.list(query, work: .background(.index))
            out += page.refs.map(\.id)
            query.pageToken = page.nextPageToken
        } while query.pageToken != nil
        return out
    }

    // MARK: Fixtures

    func testTheFixturesHaveTheirCountsExactly() async throws {
        for (spec, name) in [(FakeGmailMailbox.FixtureSpec.typical55k, "55k"), (.large200k, "200k"), (.migrated200k, "migrated")] {
            let started = Date()
            let mailbox = FakeGmailMailbox.fixture(spec)
            XCTAssertLessThan(Date().timeIntervalSince(started), 20, "\(name) is quick to make")
            XCTAssertEqual(mailbox.messageCount, spec.total, name)
            let transport = GmailTestKit.transport(mailbox)
            let labels = try await transport.labels(work: .interactive)
            XCTAssertEqual(labels.filter(\.isUserLabel).count, spec.userLabels, name)
            let parts: [GmailBatchPart] = [.label(.inbox), .label(.sent), .label(.unread), .label(.important), .label(.spam),
                                           .label(.trash), .label(.starred), .label(.draft)]
            let answers = try await transport.batch(parts, work: .interactive)
            func total(_ id: GmailLabelID) -> Int? { try? answers[.label(id)]?.get().label?.messagesTotal }
            XCTAssertEqual(total(.inbox), spec.inbox, name)
            XCTAssertEqual(total(.sent), spec.sent, name)
            XCTAssertEqual(total(.unread), spec.unread, name)
            XCTAssertEqual(total(.important), spec.important, name)
            XCTAssertEqual(total(.spam), spec.spam, name)
            XCTAssertEqual(total(.trash), spec.trash, name)
            XCTAssertEqual(total(.starred), spec.starred, name)
            XCTAssertEqual(total(.draft), spec.drafts, name)
            var memberships = 0
            for label in labels where label.isUserLabel {
                memberships += try await transport.label(label.labelID, work: .interactive).messagesTotal ?? 0
            }
            XCTAssertEqual(memberships, spec.userMemberships, name)
            let profile = try await transport.profile(work: .interactive)
            XCTAssertEqual(profile.messagesTotal, spec.total)
            XCTAssertLessThan(profile.threadsTotal ?? 0, spec.total, "some messages are conversations")
            XCTAssertGreaterThan(profile.threadsTotal ?? 0, spec.total / 2)
        }
        let migrated = FakeGmailMailbox.migrated200k()
        XCTAssertTrue(migrated.userLabels.values.allSatisfy { $0.hasPrefix("Folders/") }, "olm2cloud's labels are Outlook folder paths")
    }

    func testListingAFixtureInFullIsNewestFirstAndCostsWhatTheDesignSays() async throws {
        let mailbox = FakeGmailMailbox.fixture(FakeGmailMailbox.FixtureSpec.typical55k.scaled(to: 11_000))
        let transport = GmailTestKit.transport(mailbox, policy: GmailBudgetPolicy(capacity: 1_000_000, refillPerMinute: 10_000_000))
        let all = try await allIDs(transport, GmailListQuery(includeSpamTrash: true))
        XCTAssertEqual(all.count, 11_000)
        XCTAssertEqual(all, all.sorted(by: >), "newest first, and Gmail's ids grow with time")
        XCTAssertEqual(mailbox.units[.messagesList], 22 * 5, "500 a page")
        let inbox = try await allIDs(transport, GmailListQuery(labels: [.inbox]))
        XCTAssertEqual(inbox.count, 4_000)
        let withoutJunk = try await allIDs(transport, GmailListQuery())
        XCTAssertEqual(withoutJunk.count, 11_000 - 60 - 140, "Junk Email and Deleted Items are left out unless asked for")
        let slice = try await allIDs(transport, GmailListQuery(query: "after:1600000000 before:1700000000", includeSpamTrash: true))
        XCTAssertGreaterThan(slice.count, 3_000, "a year slice of epoch seconds")
        XCTAssertLessThan(slice.count, 4_000)
    }

    func testAnImportedMessageDated2037SitsAtTheTopForGood() async throws {
        let mailbox = FakeGmailMailbox.fixture(FakeGmailMailbox.FixtureSpec.typical55k.scaled(to: 1_000))
        let future = mailbox.addImported()
        let fresh = mailbox.deliver(subject: "Arrived now")
        let transport = GmailTestKit.transport(mailbox)
        let page = try await transport.list(GmailListQuery(labels: [.inbox], maxResults: 2), work: .checks)
        XCTAssertEqual(page.refs.map(\.id.hex), [future.id, fresh.id])
        XCTAssertTrue(mailbox.wasImportedElsewhere(future.id))
        XCTAssertEqual(mailbox.message(future.id)?.date, FakeGmailMailbox.year2037)
    }

    // MARK: Google's rules

    func testAPageCanRepeatOrSkipAMessageThatMovesWhileTheListIsRead() async throws {
        let mailbox = FakeGmailMailbox()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let messages = (0..<6).map { mailbox.add(subject: "M\($0)", date: base.addingTimeInterval(TimeInterval(-$0 * 60))) }
        let transport = GmailTestKit.transport(mailbox)
        let first = try await transport.list(GmailListQuery(maxResults: 3), work: .background(.index))
        XCTAssertEqual(first.refs.map(\.id.hex), messages.prefix(3).map(\.id))
        // A message above the cursor goes: the next page starts one further on, and M3 is skipped.
        mailbox.delete(messages[0].id)
        let second = try await transport.list(GmailListQuery(maxResults: 3, pageToken: first.nextPageToken), work: .background(.index))
        XCTAssertEqual(second.refs.map(\.id.hex), [messages[4].id, messages[5].id])

        // A message arriving at the top between pages brings one back again.
        let again = try await transport.list(GmailListQuery(maxResults: 2), work: .background(.index))
        mailbox.add(subject: "New", date: Date())
        let repeated = try await transport.list(GmailListQuery(maxResults: 2, pageToken: again.nextPageToken), work: .background(.index))
        XCTAssertEqual(repeated.refs.first?.id, again.refs.last?.id)
    }

    func testHistoryKeepsGmailsOrderAndItsFloor() async throws {
        let mailbox = FakeGmailMailbox()
        let transport = GmailTestKit.transport(mailbox)
        let start = HistoryID(raw: mailbox.historyID)
        let draft = mailbox.add(subject: "Autosave", labels: ["DRAFT"])
        mailbox.delete(draft.id)
        let mail = mailbox.deliver(subject: "Hello")
        mailbox.relabel(mail.id, adding: ["STARRED"], removing: ["UNREAD"])
        let page = try await transport.history(since: start, types: [.messageAdded, .messageDeleted], label: nil, pageToken: nil,
                                               work: .checks)
        XCTAssertEqual(page.records.count, 3, "label changes were not asked for")
        XCTAssertEqual(page.records.map { $0.messagesAdded.first?.ref.id.hex ?? $0.messagesDeleted.first?.ref.id.hex ?? "" },
                       [draft.id, draft.id, mail.id])
        XCTAssertEqual(page.historyID.raw, mailbox.historyID, "the cursor may move past the kinds not asked for")
        let inbox = try await transport.history(since: start, types: Set(GmailHistoryType.allCases), label: .inbox, pageToken: nil,
                                                work: .checks)
        XCTAssertEqual(inbox.records.count, 2, "the Inbox message's arrival and its change, not the draft")
        let starred = inbox.records.last
        XCTAssertEqual(starred?.labelsAdded.first?.labels, [.starred])
        XCTAssertEqual(starred?.labelsRemoved.first?.labels, [.unread])

        mailbox.historyAddedCarriesLabels = false
        let bare = try await transport.history(since: start, types: [.messageAdded], label: nil, pageToken: nil, work: .checks)
        XCTAssertTrue(bare.records.allSatisfy { $0.messagesAdded.allSatisfy { $0.labels == nil } })

        mailbox.keepHistory(from: start.raw + 2)
        do {
            _ = try await transport.history(since: start, types: [.messageAdded], label: nil, pageToken: nil, work: .checks)
            XCTFail("below the floor")
        } catch let refusal as GoogleAPIError {
            XCTAssertEqual(refusal.kind, .historyExpired)
        }
        let kept = try await transport.history(since: HistoryID(raw: start.raw + 2), types: [.messageAdded], label: nil, pageToken: nil,
                                               work: .checks)
        XCTAssertEqual(kept.records.count, 1)
    }

    func testCountsFollowEveryChangeAndCanLeaveJunkAndDeletedOut() async throws {
        let mailbox = FakeGmailMailbox()
        let label = mailbox.addUserLabel(named: "Clients")
        let a = mailbox.add(subject: "A", labels: ["INBOX", "UNREAD", label])
        mailbox.add(subject: "B", labels: [label, "TRASH"])
        let transport = GmailTestKit.transport(mailbox)
        var counts = try await transport.label(GmailLabelID(label), work: .interactive)
        XCTAssertEqual(counts.messagesTotal, 2)
        XCTAssertEqual(counts.messagesUnread, 1)
        XCTAssertEqual(counts.threadsTotal, 2)
        mailbox.labelCountsIncludeSpamTrash = false
        counts = try await transport.label(GmailLabelID(label), work: .interactive)
        XCTAssertEqual(counts.messagesTotal, 1)
        _ = try await transport.modify(GmailMessageID(hex: a.id)!, adding: [], removing: [.unread], work: .interactive)
        counts = try await transport.label(GmailLabelID(label), work: .interactive)
        XCTAssertEqual(counts.messagesUnread, 0)
        mailbox.profileCountsSpamTrash = false
        let profile = try await transport.profile(work: .interactive)
        XCTAssertEqual(profile.messagesTotal, 1)
    }

    func testASendCanKeepOrReplaceTheMessageIDAndADraftSaveIsANewMessage() async throws {
        let mailbox = FakeGmailMailbox()
        let transport = GmailTestKit.transport(mailbox)
        func message(_ id: String, extra: String = "") -> Data {
            Data("From: owner@example.com\r\nTo: owner@example.com\r\nSubject: S\r\nMessage-ID: \(id)\r\n\(extra)Content-Type: text/plain\r\n\r\nText\r\n".utf8)
        }
        let kept = try await transport.send(message("<a@x>", extra: "X-FalconMail-Attempt: 1\r\n"), threadID: nil, work: .interactive)
        let read = try await transport.message(kept.gmailID!, format: .metadata(headers: ["Message-ID", "X-FalconMail-Attempt"]), work: .interactive)
        XCTAssertEqual(read.header("Message-ID"), "<a@x>")
        XCTAssertEqual(read.header("X-FalconMail-Attempt"), "1")
        XCTAssertEqual(kept.labels, [.sent, .inbox, .unread], "sent to itself, it arrives too")
        mailbox.replacesMessageIDOnSend = true
        let replaced = try await transport.send(message("<b@x>"), threadID: nil, work: .interactive)
        let other = try await transport.message(replaced.gmailID!, format: .metadata(headers: ["Message-ID", "X-Google-Original-Message-ID"]),
                                                work: .interactive)
        XCTAssertNotEqual(other.header("Message-ID"), "<b@x>")
        XCTAssertEqual(other.header("X-Google-Original-Message-ID"), "<b@x>")
        let found = try await transport.list(GmailListQuery(query: "rfc822msgid:<a@x> in:sent"), work: .interactive)
        XCTAssertEqual(found.refs.map(\.id), [kept.gmailID!])

        let draft = try await transport.createDraft(message("<d@x>"), threadID: nil, work: .interactive)
        let start = HistoryID(raw: mailbox.historyID)
        let saved = try await transport.updateDraft(draft.id, raw: message("<d@x>"), threadID: nil, work: .interactive)
        XCTAssertNotEqual(saved.message?.id, draft.message?.id)
        let history = try await transport.history(since: start, types: Set(GmailHistoryType.allCases), label: nil, pageToken: nil,
                                                  work: .checks)
        XCTAssertEqual(history.records.flatMap(\.messagesDeleted).map(\.ref.id.hex), [draft.message?.id])
        XCTAssertEqual(history.records.flatMap(\.messagesAdded).map(\.ref.id.hex), [saved.message?.id])
        do {
            _ = try await transport.updateDraft("r999", raw: message("<d@x>"), threadID: nil, work: .interactive)
            XCTFail("a draft sent or deleted elsewhere")
        } catch let refusal as GoogleAPIError {
            XCTAssertEqual(refusal.kind, .notFound)
        }
    }

    func testAReplyJoinsItsConversationByReferences() async throws {
        let mailbox = FakeGmailMailbox.fixture(FakeGmailMailbox.FixtureSpec.typical55k.scaled(to: 200))
        let transport = GmailTestKit.transport(mailbox)
        let page = try await transport.list(GmailListQuery(maxResults: 1), work: .interactive)
        let original = try XCTUnwrap(page.refs.first)
        let reference = "<\(original.id.hex)@fixture.example>"
        let raw = Data("From: owner@example.com\r\nTo: a@example.com\r\nSubject: Re: x\r\nMessage-ID: <r@x>\r\nIn-Reply-To: \(reference)\r\nReferences: \(reference)\r\nContent-Type: text/plain\r\n\r\nYes\r\n".utf8)
        let sent = try await transport.send(raw, threadID: nil, work: .interactive)
        XCTAssertEqual(sent.gmailThreadID, original.threadID)
    }

    // MARK: Limits and faults

    func testASecondClientSharesThePerUserBudget() throws {
        let clock = VirtualClock()
        let mailbox = FakeGmailMailbox(now: { clock.now })
        mailbox.userUnitsPerMinute = 6_000
        let url = FakeGmailURLProtocol.register(mailbox, client: "second-mac")
        var request = URLRequest(url: url.appendingPathComponent("messages"))
        request.httpMethod = "GET"
        for _ in 0..<1_200 { _ = mailbox.handle(request, client: "second-mac") }
        XCTAssertEqual(mailbox.units(for: "second-mac"), 6_000)
        guard case .success(let (refused, body)) = mailbox.handle(request, client: FakeGmailMailbox.falconMail) else { return XCTFail() }
        XCTAssertEqual(refused.statusCode, 429, "the owner's own FalconMail finds the minute spent")
        let error = GoogleErrorParser.parse(status: 429, body: body, retryAfter: refused.value(forHTTPHeaderField: "Retry-After"),
                                            method: .messagesList)
        XCTAssertEqual(error.kind, .rateLimited)
        XCTAssertGreaterThan(error.retryAfter ?? 0, 0)
        clock.advance(61)
        guard case .success(let (ok, _)) = mailbox.handle(request) else { return XCTFail() }
        XCTAssertEqual(ok.statusCode, 200)
        XCTAssertEqual(mailbox.peakUnitsInAnyMinute(), 6_000)
    }

    func testTheAllowancesRefuseWithGooglesWordsOnceUsedUp() throws {
        let mailbox = FakeGmailMailbox()
        let message = mailbox.add(subject: "x", text: String(repeating: "y", count: 5_000))
        mailbox.downloadAllowance = 8_000
        let base = FakeGmailURLProtocol.register(mailbox)
        let request = URLRequest(url: base.appendingPathComponent("messages/\(message.id)"))
        guard case .success(let (first, _)) = mailbox.handle(request) else { return XCTFail() }
        XCTAssertEqual(first.statusCode, 200)
        guard case .success(let (second, _)) = mailbox.handle(request) else { return XCTFail() }
        XCTAssertEqual(second.statusCode, 200)
        guard case .success(let (third, body)) = mailbox.handle(request) else { return XCTFail() }
        XCTAssertEqual(third.statusCode, 429)
        let error = GoogleErrorParser.parse(status: 429, body: body, retryAfter: third.value(forHTTPHeaderField: "Retry-After"),
                                            method: .messagesGet)
        XCTAssertEqual(error.kind, .downloadLimit)
    }

    func testDelaysHoldRequestsInFlightAndThePeaksAreCounted() async throws {
        let mailbox = FakeGmailMailbox()
        let messages = (0..<8).map { mailbox.add(subject: "Row \($0)") }
        mailbox.setDelay(0.15, for: .messagesGet)
        let transport = GmailTestKit.transport(mailbox)
        let started = Date()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for m in messages {
                group.addTask { _ = try await transport.message(GmailMessageID(hex: m.id)!, format: .minimal, work: .interactive) }
            }
            try await group.waitForAll()
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.3, "eight at four at a time take at least two rounds")
        XCTAssertEqual(mailbox.peakRequestsInFlight, 4)
        XCTAssertEqual(mailbox.peakInFlightByMethod[.messagesGet], 4)
        XCTAssertEqual(mailbox.peakPartsInFlightByMethod[.messagesGet], 4)
        XCTAssertEqual(mailbox.requestsInFlight, 0)

        mailbox.batchDelay = 0.15
        async let rows = transport.batch(messages.map { .message(GmailMessageID(hex: $0.id)!, .row) }, work: .interactive)
        async let threads = transport.batch(messages.prefix(3).map { .thread(GmailThreadID(hex: $0.threadID)!, .minimal) }, work: .interactive)
        _ = try await (rows, threads)
        XCTAssertEqual(mailbox.peakPartsInFlightByMethod[.threadsGet], 3)
        XCTAssertEqual(mailbox.peakPartsInFlight, 11, "a batch's parts count, whatever they are")

        mailbox.useAcceptanceDelays(scale: 0.1)
        let arrival = mailbox.arrive(URLRequest(url: FakeGmailURLProtocol.register(mailbox).appendingPathComponent("history")), client: "x")
        XCTAssertEqual(mailbox.delay(for: arrival), 0.015, accuracy: 0.0001)
        mailbox.depart(arrival)
    }

    func testFaultsCanComeAfterGmailHasActed() throws {
        let mailbox = FakeGmailMailbox()
        mailbox.inject(.acceptedThenTimeout, for: .messagesSend)
        let base = FakeGmailURLProtocol.register(mailbox)
        var request = URLRequest(url: URL(string: base.absoluteString.replacingOccurrences(of: "/gmail/v1", with: "/upload/gmail/v1") + "/messages/send?uploadType=multipart")!)
        request.httpMethod = "POST"
        let (body, type) = GmailUpload.body(metadata: Data("{}".utf8), message: Data("Subject: x\r\nMessage-ID: <x@y>\r\n\r\nz\r\n".utf8))
        request.httpBody = body
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        guard case .failure(let error) = mailbox.handle(request) else { return XCTFail("the answer is lost") }
        XCTAssertEqual(error.code, .timedOut)
        XCTAssertEqual(mailbox.messages.count, 1, "and yet Gmail sent it")
        XCTAssertEqual(mailbox.sentUploads.count, 1)
    }
}
