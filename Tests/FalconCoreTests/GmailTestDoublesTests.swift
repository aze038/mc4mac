import XCTest
@testable import FalconCore

/// The in-memory transport and store stand in for Gmail and the disk while the engine is built,
/// so they have to behave as the design says Gmail and the store do. These tests hold them to it.
final class MemoryGmailTransportTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func raw(_ headers: [String: String], body: String = "Hello") -> Data {
        let lines = headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        return Data((lines.joined(separator: "\r\n") + "\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n" + body).utf8)
    }

    // MARK: - History

    func testHistoryComesInTheOrderChangesWereMade() async throws {
        let gmail = MemoryGmailTransport()
        let from = gmail.historyID
        let first = gmail.add(subject: "First", date: start)
        gmail.relabel(first.id, removing: [.unread])
        let second = gmail.add(subject: "Draft autosave", labels: [.draft], date: start)
        gmail.delete(second.id)
        gmail.relabel(first.id, adding: [.inbox])

        let page = try await gmail.history(since: from, types: Set(GmailHistoryType.allCases), label: nil, pageToken: nil, work: .checks)
        XCTAssertEqual(page.records.count, 4, "adding a label a message already has writes nothing")
        XCTAssertEqual(page.records.map(\.id), page.records.map(\.id).sorted())
        XCTAssertEqual(page.records[0].messagesAdded.map(\.ref), [first])
        XCTAssertEqual(page.records[0].messagesAdded.first?.labels, [.inbox, .unread])
        XCTAssertEqual(page.records[1].labelsRemoved.first?.labels, [.unread])
        XCTAssertEqual(page.records[1].labelsRemoved.first?.message.ref, first)
        XCTAssertEqual(page.records[2].messagesAdded.map(\.ref), [second], "an add and a delete of one message in one page")
        XCTAssertEqual(page.records[3].messagesDeleted.map(\.ref), [second])
        XCTAssertEqual(page.historyID, gmail.historyID)
        XCTAssertNil(page.nextPageToken)

        let added = try await gmail.history(since: from, types: [.messageAdded], label: nil, pageToken: nil, work: .checks)
        XCTAssertEqual(added.records.flatMap(\.messagesAdded).map(\.ref), [first, second])
        let later = try await gmail.history(since: page.records[1].id, types: [], label: nil, pageToken: nil, work: .checks)
        XCTAssertEqual(later.records.count, 2, "only what came after the start point")
        XCTAssertEqual(gmail.units[.historyList], 6)
    }

    func testHistoryBelowWhatGmailKeepsHasExpired() async throws {
        let gmail = MemoryGmailTransport()
        let old = gmail.historyID
        gmail.add(subject: "Before")
        gmail.expireHistory()
        do {
            _ = try await gmail.history(since: old, types: [], label: nil, pageToken: nil, work: .checks)
            XCTFail("history from before the floor is gone")
        } catch let error as GoogleAPIError {
            XCTAssertEqual(error.kind, .historyExpired)
            XCTAssertEqual(error.httpStatus, 404)
        }
        let now = try await gmail.history(since: gmail.historyID, types: [], label: nil, pageToken: nil, work: .checks)
        XCTAssertTrue(now.records.isEmpty)
        XCTAssertEqual(gmail.attempts[.historyList], 2)
        XCTAssertEqual(gmail.calls[.historyList], 1, "a refusal is not charged")
    }

    func testHistoryPagesAndKeepsToOneLabel() async throws {
        let gmail = MemoryGmailTransport()
        gmail.historyPageSize = 2
        let from = gmail.historyID
        for i in 0..<5 { gmail.add(subject: "Mail \(i)", labels: i == 3 ? [.sent] : [.inbox]) }
        var token: String?
        var refs: [GmailRef] = []
        var pages = 0
        repeat {
            let page = try await gmail.history(since: from, types: [.messageAdded], label: nil, pageToken: token, work: .checks)
            refs += page.records.flatMap(\.messagesAdded).map(\.ref)
            token = page.nextPageToken
            pages += 1
        } while token != nil
        XCTAssertEqual(pages, 3)
        XCTAssertEqual(refs.count, 5)
        let sent = try await gmail.history(since: from, types: [.messageAdded], label: .sent, pageToken: nil, work: .checks)
        XCTAssertEqual(sent.records.flatMap(\.messagesAdded).map(\.ref), [refs[3]])
    }

    // MARK: - Lists and reads

    func testListsAreNewestFirstPagedAndLeaveJunkAndDeletedOut() async throws {
        let gmail = MemoryGmailTransport()
        let refs = (0..<5).map { gmail.add(subject: "Mail \($0)", labels: [.inbox], date: start.addingTimeInterval(Double($0) * day)) }
        let junk = gmail.add(subject: "Junk", labels: [.spam], date: start.addingTimeInterval(10 * day))
        let deleted = gmail.add(subject: "Gone", labels: [.inbox, .trash], date: start.addingTimeInterval(11 * day))

        let first = try await gmail.list(GmailListQuery(maxResults: 2), work: .interactive)
        XCTAssertEqual(first.refs, [refs[4], refs[3]])
        XCTAssertEqual(first.resultSizeEstimate, 5)
        let second = try await gmail.list(GmailListQuery(maxResults: 2, pageToken: first.nextPageToken), work: .interactive)
        XCTAssertEqual(second.refs, [refs[2], refs[1]])
        let last = try await gmail.list(GmailListQuery(maxResults: 2, pageToken: second.nextPageToken), work: .interactive)
        XCTAssertEqual(last.refs, [refs[0]])
        XCTAssertNil(last.nextPageToken)

        let all = try await gmail.list(GmailListQuery(includeSpamTrash: true), work: .background(.index))
        XCTAssertEqual(all.refs.first, deleted)
        XCTAssertEqual(all.refs.count, 7)
        let spam = try await gmail.list(GmailListQuery(labels: [.spam]), work: .interactive)
        XCTAssertEqual(spam.refs, [junk], "asking for Junk Email by its label lists it")
        let inboxTrash = try await gmail.list(GmailListQuery(labels: [.inbox, .trash]), work: .interactive)
        XCTAssertEqual(inboxTrash.refs, [deleted], "labels combined mean a message must have all of them")

        let seconds = Int(start.addingTimeInterval(2 * day).timeIntervalSince1970)
        let older = try await gmail.list(GmailListQuery(query: "before:\(seconds)", includeSpamTrash: true, maxResults: 1),
                                         work: .background(.index))
        XCTAssertEqual(older.refs, [refs[1]], "the newest message older than a boundary, as date anchors ask")
        let since = try await gmail.list(GmailListQuery(query: "after:\(seconds)"), work: .interactive)
        XCTAssertEqual(since.refs, [refs[4], refs[3], refs[2]])
        XCTAssertEqual(gmail.units[.messagesList], 40)
    }

    func testSearchTermsTheEngineUses() async throws {
        let gmail = MemoryGmailTransport()
        let invoice = gmail.add(subject: "Freight invoice", from: "Billing <billing@carrier.example>", messageID: "<inv-1@carrier.example>",
                                hasAttachment: true, size: 2_000_000)
        let note = gmail.add(subject: "Lunch", text: "See you at noon", size: 30_000)
        let label = gmail.addUserLabel(named: "Clients/Acme")
        gmail.relabel(note.id, adding: [label, .starred])

        func hits(_ q: String) async throws -> [GmailRef] { try await gmail.list(GmailListQuery(query: q), work: .interactive).refs }
        let byMessageID = try await hits("rfc822msgid:<inv-1@carrier.example>")
        XCTAssertEqual(byMessageID, [invoice])
        let withoutBrackets = try await hits("rfc822msgid:INV-1@carrier.example")
        XCTAssertEqual(withoutBrackets, [invoice])
        let attachments = try await hits("has:attachment")
        XCTAssertEqual(attachments, [invoice])
        let large = try await hits("larger:1M")
        XCTAssertEqual(large, [invoice])
        let small = try await hits("larger:25K")
        XCTAssertEqual(Set(small), [invoice, note])
        let from = try await hits("from:BILLING@carrier.example")
        XCTAssertEqual(from, [invoice])
        let starred = try await hits("is:starred")
        XCTAssertEqual(starred, [note])
        let labelled = try await hits("label:clients/acme")
        XCTAssertEqual(labelled, [note])
        let words = try await hits("noon")
        XCTAssertEqual(words, [note])
    }

    func testEachFormatGivesWhatGmailGives() async throws {
        let gmail = MemoryGmailTransport()
        let ref = gmail.add(subject: "Report", from: "Ana <ana@example.com>", text: "The figures are attached", date: start,
                            hasAttachment: true)

        let minimal = try await gmail.message(ref.id, format: .minimal, work: .checks)
        XCTAssertNil(minimal.payload)
        XCTAssertEqual(minimal.gmailID, ref.id)
        XCTAssertEqual(minimal.gmailThreadID, ref.threadID)
        XCTAssertEqual(minimal.receivedDate, start)
        XCTAssertEqual(minimal.labels, [.inbox, .unread])
        XCTAssertNotNil(minimal.history)

        let metadata = try await gmail.message(ref.id, format: .metadata(headers: ["Subject", "from"]), work: .interactive)
        XCTAssertEqual(metadata.payload?.headers?.map(\.name).sorted(), ["From", "Subject"])
        XCTAssertEqual(metadata.snippet, "The figures are attached")
        let row = GmailServerRow.summary(for: try await gmail.message(ref.id, format: .row, work: .interactive), accountID: gmail.accountID)
        XCTAssertEqual(row.subject, "Report")
        XCTAssertEqual(row.from.address, "ana@example.com")

        let full = try await gmail.message(ref.id, format: .full, work: .interactive)
        let opened = GmailMessageContent.textStage(full)
        XCTAssertEqual(opened.message.textPlain, "The figures are attached")
        let stub = try XCTUnwrap(opened.listedAttachments.first)
        XCTAssertEqual(stub.filename, "attachment.pdf")
        let bytes = try await gmail.attachment(try XCTUnwrap(stub.attachmentID), of: ref.id, work: .interactive)
        XCTAssertEqual(bytes, MemoryGmailTransport.attachmentBytes(ref.id))

        let raw = try await gmail.message(ref.id, format: .raw, work: .interactive)
        let whole = MIMEParser.parse(try XCTUnwrap(raw.rawData))
        XCTAssertEqual(whole.headers.first("Subject"), "Report")
        XCTAssertEqual(whole.textPlain, "The figures are attached")

        do {
            _ = try await gmail.message(GmailMessageID(raw: 1), format: .minimal, work: .interactive)
            XCTFail("a message Gmail does not have")
        } catch let error as GoogleAPIError {
            XCTAssertEqual(error.kind, .notFound)
        }
        XCTAssertEqual(gmail.units[.messagesGet], 100)
        XCTAssertEqual(gmail.units[.attachmentsGet], 20)
    }

    func testAThreadListsItsMessagesOldestFirst() async throws {
        let gmail = MemoryGmailTransport()
        let first = gmail.add(subject: "Quote", date: start)
        let reply = gmail.add(subject: "Re: Quote", labels: [.sent], date: start.addingTimeInterval(60), thread: first.threadID)
        gmail.add(subject: "Elsewhere")
        let thread = try await gmail.thread(first.threadID, format: .row, work: .interactive)
        XCTAssertEqual(thread.threadID, first.threadID)
        XCTAssertEqual(thread.messages?.compactMap(\.gmailID), [first.id, reply.id])
        XCTAssertEqual(gmail.units[.threadsGet], 40)
    }

    func testABatchAnswersEachPartOnItsOwn() async throws {
        let gmail = MemoryGmailTransport()
        let ref = gmail.add(subject: "Kept")
        let missing = GmailMessageID(raw: 0x1234)
        let parts: [GmailBatchPart] = [.message(ref.id, .row), .message(missing, .row), .thread(ref.threadID, .minimal), .label(.inbox)]
        let answers = try await gmail.batch(parts, work: .interactive)
        XCTAssertEqual(answers.count, 4)
        XCTAssertEqual(try answers[parts[0]]?.get().message?.gmailID, ref.id)
        guard case .failure(let refusal)? = answers[parts[1]] else { return XCTFail("the missing message fails alone") }
        XCTAssertEqual(refusal.kind, .notFound)
        XCTAssertEqual(try answers[parts[2]]?.get().thread?.messages?.count, 1)
        XCTAssertEqual(try answers[parts[3]]?.get().label?.messagesTotal, 1)
        XCTAssertEqual(gmail.units, [.messagesGet: 20, .threadsGet: 40, .labelsGet: 1], "a refused part is not charged")

        gmail.fail(nil, with: GoogleAPIError(kind: .temporary, httpStatus: 503))
        do {
            _ = try await gmail.batch(parts, work: .interactive)
            XCTFail("the whole batch failed")
        } catch let error as GoogleAPIError {
            XCTAssertEqual(error.kind, .temporary)
        }
        gmail.fail(.threadsGet, with: GoogleAPIError(kind: .rateLimited, httpStatus: 429, retryAfter: 5))
        let partly = try await gmail.batch(parts, work: .interactive)
        XCTAssertEqual(try partly[parts[0]]?.get().message?.gmailID, ref.id)
        guard case .failure(let limited)? = partly[parts[2]] else { return XCTFail("only the thread part was refused") }
        XCTAssertEqual(limited.kind, .rateLimited)
    }

    // MARK: - Changes

    func testModifyReportsOnlyWhatReallyChangedAndRefusesWhatGmailRefuses() async throws {
        let gmail = MemoryGmailTransport()
        let ref = gmail.add(subject: "Read me")
        let from = gmail.historyID
        let modified = try await gmail.modify(ref.id, adding: [.starred], removing: [.unread, .spam], work: .interactive)
        XCTAssertEqual(modified.labels, [.inbox, .starred])
        _ = try await gmail.modify(ref.id, adding: [.starred], removing: [.unread], work: .interactive)
        let page = try await gmail.history(since: from, types: [], label: nil, pageToken: nil, work: .checks)
        XCTAssertEqual(page.records.count, 1, "the echo of a change that changes nothing is nothing")
        XCTAssertEqual(page.records[0].labelsAdded.first?.labels, [.starred])
        XCTAssertEqual(page.records[0].labelsRemoved.first?.labels, [.unread])

        for fixed in [GmailLabelID.sent, .draft] {
            do {
                _ = try await gmail.modify(ref.id, adding: [fixed], removing: [], work: .interactive)
                XCTFail("Gmail refuses \(fixed)")
            } catch let error as GoogleAPIError {
                XCTAssertEqual(error.httpStatus, 400)
            }
        }
        do {
            _ = try await gmail.modify(ref.id, adding: ["Label_404"], removing: [.inbox], work: .interactive)
            XCTFail("a label that no longer exists")
        } catch let error as GoogleAPIError {
            XCTAssertEqual(error.kind, .notFound)
        }
        XCTAssertEqual(gmail.message(ref.id)?.labels, [.inbox, .starred], "a refused change changes nothing")
        XCTAssertEqual(gmail.units[.messagesModify], 10)
    }

    func testBulkCallsTakeAtMostAThousandIds() async throws {
        let gmail = MemoryGmailTransport()
        let refs = (0..<3).map { gmail.add(subject: "Bulk \($0)", recordHistory: false) }
        let tooMany = (0..<1_001).map { GmailMessageID(raw: UInt64($0)) }
        do {
            try await gmail.batchModify(tooMany, adding: [], removing: [.inbox], work: .bulk)
            XCTFail("1,001 ids")
        } catch let error as GoogleAPIError {
            XCTAssertEqual(error.httpStatus, 400)
        }
        try await gmail.batchModify(refs.map(\.id) + [GmailMessageID(raw: 9)], adding: [.trash], removing: [], work: .bulk)
        XCTAssertTrue(gmail.messages.allSatisfy { $0.labels == [.inbox, .unread, .trash] }, "a delete keeps the other labels")
        let from = gmail.historyID
        try await gmail.batchDelete([refs[0].id, refs[1].id], work: .interactive)
        XCTAssertEqual(gmail.messages.map(\.ref), [refs[2]])
        let page = try await gmail.history(since: from, types: [.messageDeleted], label: nil, pageToken: nil, work: .checks)
        XCTAssertEqual(page.records.flatMap(\.messagesDeleted).map(\.ref), [refs[0], refs[1]])
        XCTAssertEqual(gmail.units, [.messagesBatchModify: 50, .messagesBatchDelete: 50, .historyList: 2])
    }

    func testTrashKeepsTheOtherLabelsAndUntrashGivesThemBack() async throws {
        let gmail = MemoryGmailTransport()
        let ref = gmail.add(subject: "Oops", labels: [.inbox, .starred])
        let trashed = try await gmail.trash(ref.id, work: .interactive)
        XCTAssertEqual(trashed.labels, [.inbox, .starred, .trash])
        let back = try await gmail.untrash(ref.id, work: .interactive)
        XCTAssertEqual(back.labels, [.inbox, .starred])
        XCTAssertEqual(gmail.units, [.messagesTrash: 20, .messagesUntrash: 5])
    }

    // MARK: - Uploads

    func testASentMessageIsFiledInSentWithItsHeaders() async throws {
        let gmail = MemoryGmailTransport()
        let original = gmail.add(subject: "Quote", date: start)
        let from = gmail.historyID
        let message = raw(["From": "owner@example.com", "To": "ana@example.com", "Bcc": "boss@example.com", "Subject": "Re: Quote",
                           "Message-ID": "<attempt-1@falconmail>", "X-FalconMail-Attempt": "A1"])
        let sent = try await gmail.send(message, threadID: original.threadID, work: .interactive)
        XCTAssertEqual(sent.labels, [.sent])
        XCTAssertEqual(sent.gmailThreadID, original.threadID)
        let headers = try await gmail.message(try XCTUnwrap(sent.gmailID), format: .metadata(headers: ["Message-ID", "X-FalconMail-Attempt", "Bcc"]),
                                              work: .interactive)
        XCTAssertEqual(headers.header("Message-ID"), "<attempt-1@falconmail>")
        XCTAssertEqual(headers.header("X-FalconMail-Attempt"), "A1")
        XCTAssertEqual(headers.header("Bcc"), "boss@example.com", "the sender's copy keeps Bcc")
        let echo = try await gmail.history(since: from, types: [.messageAdded], label: .sent, pageToken: nil, work: .checks)
        XCTAssertEqual(echo.records.flatMap(\.messagesAdded).map(\.ref.id), [try XCTUnwrap(sent.gmailID)])
        XCTAssertEqual(gmail.units[.messagesSend], 100)
        let usage = await gmail.usage()
        XCTAssertEqual(usage.bytesUp, message.count)

        gmail.replacesMessageIDOnSend = true
        let second = try await gmail.send(raw(["To": "owner@example.com", "Subject": "To myself", "Message-ID": "<attempt-2@falconmail>"]),
                                          threadID: nil, work: .interactive)
        XCTAssertEqual(second.labels, [.sent, .inbox, .unread], "a message to oneself arrives in the Inbox too")
        let replaced = try await gmail.message(try XCTUnwrap(second.gmailID), format: .metadata(headers: []), work: .interactive)
        XCTAssertNotEqual(replaced.header("Message-ID"), "<attempt-2@falconmail>")
        XCTAssertEqual(replaced.header("X-Google-Original-Message-ID"), "<attempt-2@falconmail>")
        XCTAssertEqual(second.gmailThreadID?.raw, second.gmailID?.raw, "a new conversation")
    }

    func testAnImportIsDatedByItsOwnHeader() async throws {
        let gmail = MemoryGmailTransport()
        let label = gmail.addUserLabel(named: "Imported")
        let future = raw(["Subject": "From the future", "Date": "Thu, 01 Jan 2037 09:00:00 +0000", "Message-ID": "<old@x>"])
        let imported = try await gmail.importMessage(future, labels: [label], options: GmailImportOptions(), work: .background(.transfer))
        XCTAssertEqual(imported.labels, [label])
        XCTAssertEqual(imported.receivedDate, RFC5322Date.parse("Thu, 01 Jan 2037 09:00:00 +0000"))
        let now = try await gmail.importMessage(future, labels: [.inbox], options: GmailImportOptions(internalDateSource: .receivedTime),
                                                work: .background(.transfer))
        XCTAssertLessThan(try XCTUnwrap(now.receivedDate), Date().addingTimeInterval(60))
        XCTAssertEqual(GmailImportOptions().internalDateSource, .dateHeader)
        XCTAssertTrue(GmailImportOptions().neverMarkSpam)
        XCTAssertEqual(gmail.units[.messagesImport], 50)
    }

    func testEveryDraftSaveIsANewMessage() async throws {
        let gmail = MemoryGmailTransport()
        let from = gmail.historyID
        let created = try await gmail.createDraft(raw(["Subject": "Draft", "X-FalconMail-Draft": "D1"]), threadID: nil, work: .interactive)
        let firstID = try XCTUnwrap(created.message?.gmailID)
        XCTAssertEqual(created.message?.labels, [.draft])
        let updated = try await gmail.updateDraft(created.id, raw: raw(["Subject": "Draft, longer"]), threadID: nil, work: .interactive)
        let secondID = try XCTUnwrap(updated.message?.gmailID)
        XCTAssertEqual(updated.id, created.id)
        XCTAssertNotEqual(secondID, firstID)
        XCTAssertNil(gmail.message(firstID))
        XCTAssertEqual(gmail.draftIDs, [created.id: secondID])

        let list = try await gmail.drafts(pageToken: nil, work: .interactive)
        XCTAssertEqual(list.drafts?.map(\.id), [created.id])
        XCTAssertEqual(list.drafts?.first?.message?.gmailID, secondID)

        let echo = try await gmail.history(since: from, types: [], label: nil, pageToken: nil, work: .checks)
        XCTAssertEqual(echo.records.flatMap(\.messagesAdded).map(\.ref.id), [firstID, secondID])
        XCTAssertEqual(echo.records.flatMap(\.messagesDeleted).map(\.ref.id), [firstID], "a save is a delete and an add")

        try await gmail.deleteDraft(created.id, work: .interactive)
        XCTAssertTrue(gmail.messages.isEmpty, "deleting a draft keeps nothing in Deleted Items")
        do {
            _ = try await gmail.updateDraft(created.id, raw: raw(["Subject": "Again"]), threadID: nil, work: .interactive)
            XCTFail("the draft is gone")
        } catch let error as GoogleAPIError {
            XCTAssertEqual(error.kind, .notFound)
        }
        XCTAssertEqual(gmail.units, [.draftsCreate: 10, .draftsUpdate: 15, .draftsDelete: 10, .draftsList: 5, .historyList: 2])
    }

    // MARK: - Labels, the account and the budget

    func testLabelsCarryTheirCounts() async throws {
        let gmail = MemoryGmailTransport()
        let label = gmail.addUserLabel(named: "Clients", visibility: "labelShowIfUnread")
        let a = gmail.add(subject: "A", labels: [.inbox, .unread, label])
        gmail.add(subject: "B", labels: [.inbox, label], thread: a.threadID)
        gmail.add(subject: "C", labels: [.inbox])

        let labels = try await gmail.labels(work: .interactive)
        XCTAssertEqual(labels.filter(\.isUserLabel).map(\.labelID), [label])
        XCTAssertEqual(labels.first { $0.labelID == label }?.labelListVisibility, "labelShowIfUnread")
        XCTAssertTrue(labels.contains { $0.labelID == .inbox && !$0.isUserLabel })

        let counted = try await gmail.label(label, work: .interactive)
        XCTAssertEqual(counted.messagesTotal, 2)
        XCTAssertEqual(counted.messagesUnread, 1)
        XCTAssertEqual(counted.threadsTotal, 1)
        let inbox = try await gmail.label(.inbox, work: .interactive)
        XCTAssertEqual(inbox.messagesTotal, 3)

        let created = try await gmail.createLabel(named: "Carriers", work: .interactive)
        XCTAssertTrue(created.isUserLabel)
        do {
            _ = try await gmail.createLabel(named: "carriers", work: .interactive)
            XCTFail("a label of that name exists")
        } catch let error as GoogleAPIError {
            XCTAssertEqual(error.httpStatus, 409)
        }
        let profile = try await gmail.profile(work: .checks)
        XCTAssertEqual(profile.emailAddress, "owner@example.com")
        XCTAssertEqual(profile.messagesTotal, 3)
        XCTAssertEqual(profile.historyID, gmail.historyID)
        let sendAs = try await gmail.sendAs(work: .background(.index))
        XCTAssertEqual(sendAs.map(\.sendAsEmail), ["owner@example.com"])
        XCTAssertEqual(gmail.units, [.labelsList: 1, .labelsGet: 2, .labelsCreate: 5, .profile: 1, .sendAsList: 1])
    }

    func testRefusalsAndTheBudgetAreUnderTheTestsControl() async throws {
        let gmail = MemoryGmailTransport()
        gmail.fail(.profile, with: GoogleAPIError(kind: .rateLimited, httpStatus: 429, retryAfter: 30), times: 2)
        for _ in 0..<2 {
            do {
                _ = try await gmail.profile(work: .checks)
                XCTFail("refused")
            } catch let error as GoogleAPIError {
                XCTAssertEqual(error.kind, .rateLimited)
                XCTAssertEqual(error.retryAfter, 30)
            }
        }
        _ = try await gmail.profile(work: .checks)
        XCTAssertEqual(gmail.attempts[.profile], 3)
        XCTAssertEqual(gmail.calls[.profile], 1)

        gmail.failAlways(.messagesSend, with: GoogleAPIError(kind: .uploadLimit, httpStatus: 429, retryAfter: 3_600))
        for _ in 0..<2 {
            do {
                _ = try await gmail.send(raw(["Subject": "Held"]), threadID: nil, work: .interactive)
                XCTFail("uploads are paused")
            } catch let error as GoogleAPIError {
                XCTAssertEqual(error.kind, .uploadLimit)
            }
        }
        gmail.failAlways(.messagesSend, with: nil)
        _ = try await gmail.send(raw(["Subject": "Sent"]), threadID: nil, work: .interactive)

        await gmail.setFloodMode(true)
        XCTAssertTrue(gmail.isFloodMode)
        let moment = Date()
        await gmail.noteOwnerActivity(at: moment)
        XCTAssertEqual(gmail.ownerActivity, [moment])
        let noPause = await gmail.pause()
        XCTAssertNil(noPause)
        gmail.setPause(GmailPause(until: moment.addingTimeInterval(90), refusal: GoogleAPIError(kind: .rateLimited)))
        let pause = await gmail.pause()
        XCTAssertEqual(pause?.until, moment.addingTimeInterval(90))
        let usage = await gmail.usage()
        XCTAssertEqual(usage.totalUnits, 101)
        XCTAssertEqual(usage.calls[.messagesSend], 1)
    }
}

final class MemoryGmailStoreTests: XCTestCase {
    private func ref(_ n: UInt64, thread: UInt64? = nil) -> GmailRef {
        GmailRef(id: GmailMessageID(raw: 0x18a0_0000_0000_0000 + n), threadID: GmailThreadID(raw: 0x18a0_0000_0000_0000 + (thread ?? n)))
    }

    private func place(_ n: UInt64, order: UInt32? = nil, labels: Set<GmailLabelID> = [.inbox]) -> GmailChange {
        .place(ref(n), order: order ?? UInt32(n) * 16, labels: labels, attributes: [])
    }

    private func entry(_ id: GmailLabelID, name: String, total: Int, shown: Bool = true) -> GmailLabelEntry {
        GmailLabelEntry(id: id, name: name, kind: id.isUserLabel ? .user : .system, isShown: shown, folderID: UUID(),
                        counts: GmailLabelCounts(messagesTotal: total, messagesUnread: 0, asOf: Date()))
    }

    func testChangesApplyAndTheCursorFollowsThem() async throws {
        let store = MemoryGmailStore()
        let empty = try await store.load()
        XCTAssertNil(empty.cursor)
        try await store.commit(GmailJournalBatch(changes: [place(1, labels: [.inbox, .unread]), place(2), place(3)], cursor: HistoryID(raw: 10)))
        try await store.commit(GmailJournalBatch(changes: [.relabel(ref(1).id, adding: [.starred], removing: [.unread]),
                                                           .tombstone(ref(2).id)], cursor: HistoryID(raw: 11)))
        try await store.commit(GmailJournalBatch(changes: [.awaitingPlacement(ref(9)), .awaitingPlacement(ref(3))]))
        let load = try await store.load()
        XCTAssertEqual(load.cursor, HistoryID(raw: 11), "a batch without a cursor leaves it where it was")
        XCTAssertEqual(load.messageCount, 2)
        XCTAssertEqual(load.awaitingPlacement, [ref(9)], "a message already placed does not wait")

        let labels = await store.labels(of: ref(1).id)
        XCTAssertEqual(labels, [.inbox, .starred])
        let index = await store.index()
        XCTAssertEqual(index.byOrder.map { index.records[Int($0)].gmailID }, [ref(1).id, ref(3).id], "oldest first, no tombstones")
        XCTAssertTrue(index.records[Int(index.slotByID[ref(2).id.raw]!)].attributes.contains(.tombstone))
        XCTAssertTrue(index.record(for: ref(1).id)?.hasSystemLabel(.starred) == true)
        XCTAssertEqual(index.labels(atSlot: index.slotByID[ref(1).id.raw]!), [.inbox, .starred])

        let before = await store.index().records
        let replay = await store.batches
        for batch in replay { try await store.commit(batch) }
        let after = await store.index().records
        XCTAssertEqual(after, before, "applying every batch again changes nothing")
    }

    func testListingPagesPlaceMessagesAndKeepLabelsForThoseNotPlacedYet() async throws {
        let store = MemoryGmailStore()
        try await store.appendListingPage(GmailListingPage(chain: .label(.starred), nextPageToken: "p2", refs: [ref(1), ref(2)],
                                                           labels: [.starred]))
        var waiting = await store.awaitingLabels()
        XCTAssertEqual(waiting, [ref(1).id: [.starred], ref(2).id: [.starred]])
        try await store.appendListingPage(GmailListingPage(chain: .label(.starred), pageToken: "p2", refs: [ref(3)], labels: [.starred]))

        try await store.appendListingPage(GmailListingPage(chain: .allMail(after: nil, before: nil), nextPageToken: "a2",
                                                           refs: [ref(3), ref(2), ref(1)], firstOrder: 1_000))
        waiting = await store.awaitingLabels()
        XCTAssertTrue(waiting.isEmpty)
        let index = await store.index()
        XCTAssertEqual(index.record(for: ref(3).id)?.order, 1_000)
        XCTAssertEqual(index.record(for: ref(2).id)?.order, 984)
        XCTAssertEqual(index.record(for: ref(1).id)?.order, 968)
        XCTAssertTrue(index.record(for: ref(1).id)?.hasSystemLabel(.starred) == true, "the label listed first is kept")

        try await store.appendListingPage(GmailListingPage(chain: .search("has:attachment"), refs: [ref(2)],
                                                           attributes: [.attachmentKnown, .hasAttachment]))
        let attachment = await store.record(for: ref(2).id)
        XCTAssertEqual(attachment?.attributes, [.attachmentKnown, .hasAttachment])

        let load = try await store.load()
        XCTAssertEqual(load.chains[.label(.starred)], GmailChainProgress(run: 0, nextPageToken: nil, isComplete: true, listed: 3))
        XCTAssertEqual(load.chains[.allMail(after: nil, before: nil)], GmailChainProgress(run: 0, nextPageToken: "a2", isComplete: false, listed: 3))
        XCTAssertNil(load.cursor, "listing pages never move the cursor")
    }

    func testAResyncThatBeganAndDidNotEndIsFoundAtLaunch() async throws {
        let store = MemoryGmailStore()
        try await store.commit(GmailJournalBatch(changes: [.resyncBegan(HistoryID(raw: 500))]))
        var load = try await store.load()
        XCTAssertEqual(load.resyncBegan, HistoryID(raw: 500))
        try await store.commit(GmailJournalBatch(changes: [.resyncEnded(HistoryID(raw: 500))], cursor: HistoryID(raw: 500)))
        load = try await store.load()
        XCTAssertNil(load.resyncBegan)
        XCTAssertEqual(load.cursor, HistoryID(raw: 500))
    }

    func testTheLargestShownLabelsTakeTheSlotsAndTheRestOverflow() async throws {
        let store = MemoryGmailStore()
        var entries = [entry(.inbox, name: "INBOX", total: 900), entry(.starred, name: "STARRED", total: 3)]
        for n in 1...50 { entries.append(entry(GmailLabelID("Label_\(n)"), name: "Folder \(n)", total: n * 10)) }
        entries.append(entry("Label_hidden", name: "Hidden", total: 10_000, shown: false))
        let saved = try await store.saveLabelTable(entries)
        let slots = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0.slot) })
        XCTAssertEqual(slots[.inbox], 0)
        XCTAssertEqual(slots[.starred], 6)
        XCTAssertEqual(slots[GmailLabelID("Label_hidden")] ?? nil, nil, "a hidden label costs nothing")
        let slotted = saved.filter { $0.kind == .user && $0.slot != nil }
        XCTAssertEqual(slotted.count, 48)
        XCTAssertEqual(Set(slotted.compactMap(\.slot)), Set(16..<64))
        XCTAssertEqual(saved.filter { $0.kind == .user && $0.isShown && $0.slot == nil }.map(\.name).sorted(), ["Folder 1", "Folder 2"],
                       "the two smallest overflow")

        let small = GmailLabelID("Label_1")
        let large = GmailLabelID("Label_50")
        try await store.commit(GmailJournalBatch(changes: [place(1, labels: [.inbox, small, large, "Label_hidden"])], cursor: HistoryID(raw: 1)))
        var index = await store.index()
        let slot = index.slotByID[ref(1).id.raw]!
        XCTAssertTrue(index.record(atSlot: slot, has: small), "an overflow label is read from its list")
        XCTAssertTrue(index.record(atSlot: slot, has: large))
        XCTAssertEqual(index.labels(atSlot: slot), [.inbox, small, large])
        XCTAssertEqual(index.overflow[small], [slot])

        try await store.commit(GmailJournalBatch(changes: [.relabel(ref(1).id, adding: [], removing: [small])]))
        var labels = await store.labels(of: ref(1).id)
        XCTAssertEqual(labels, [.inbox, large])

        // Label_50 leaves the table: it leaves every record. Label_2 grows and takes the free slot.
        entries.removeAll { $0.id == large }
        entries[entries.firstIndex { $0.id == GmailLabelID("Label_2") }!].counts?.messagesTotal = 5_000
        try await store.commit(GmailJournalBatch(changes: [.relabel(ref(1).id, adding: ["Label_2"], removing: [])]))
        let resaved = try await store.saveLabelTable(entries)
        XCTAssertNotNil(resaved.first { $0.id == GmailLabelID("Label_2") }?.slot)
        XCTAssertEqual(resaved.first { $0.id == GmailLabelID("Label_49") }?.slot, slots[GmailLabelID("Label_49")] ?? nil,
                       "a label keeps its slot, so no record has to move")
        labels = await store.labels(of: ref(1).id)
        XCTAssertEqual(labels, [.inbox, "Label_2"], "moving from an overflow list to a bit keeps the members")
        index = await store.index()
        XCTAssertNil(index.labelSlots[large])
    }

    func testTheCacheGoesBackToAThousandAndKeepsWhatIsPinned() async throws {
        let store = MemoryGmailStore()
        try await store.commit(GmailJournalBatch(changes: (1...1_050).map { place(UInt64($0)) }, cursor: HistoryID(raw: 1)))
        let oldest = ref(1).id
        await store.setPinned([oldest])
        for n in 1...1_049 {
            try await store.cache(cachedMessage(UInt64(n)), body: nil)
        }
        var ids = await store.cachedIDs()
        XCTAssertEqual(ids.count, 1_049, "up to 1,050 before anything goes")
        let evicted = try await store.cache(cachedMessage(1_050), body: nil)
        XCTAssertEqual(evicted, (2...51).map { ref(UInt64($0)).id }, "the store says which left, oldest first")
        ids = await store.cachedIDs()
        XCTAssertEqual(ids.count, 1_000)
        XCTAssertTrue(ids.contains(oldest), "a pinned message stays however old")
        XCTAssertFalse(ids.contains(ref(2).id), "the oldest go first")
        XCTAssertTrue(ids.contains(ref(1_050).id))
        let second = await store.record(for: ref(2).id)
        XCTAssertFalse(second?.attributes.contains(.cached) ?? true)
        let kept = await store.record(for: ref(1_050).id)
        XCTAssertTrue(kept?.attributes.contains(.cached) ?? false)
    }

    func testBodiesPastTheCapGoButTheirRowsStay() async throws {
        let store = MemoryGmailStore(bodyBytesCap: 250)
        try await store.commit(GmailJournalBatch(changes: (1...3).map { place(UInt64($0)) }, cursor: HistoryID(raw: 1)))
        for n in 1...3 {
            try await store.cache(cachedMessage(UInt64(n)), body: GmailReducedBody(textPlain: String(repeating: "x", count: 100), textHTML: nil))
        }
        let rows = await store.cachedIDs()
        XCTAssertEqual(rows.count, 3)
        let oldest = try await store.body(of: ref(1).id)
        XCTAssertNil(oldest)
        let newest = try await store.body(of: ref(3).id)
        XCTAssertEqual(newest?.textPlain?.count, 100)
        try await store.uncache([ref(3).id])
        let gone = await store.cachedMessages([ref(3).id, ref(2).id])
        XCTAssertEqual(gone.keys.map { $0 }, [ref(2).id])
    }

    func testWhatToCacheFollowsTheFirstScreenRule() async throws {
        let store = MemoryGmailStore(cacheLimit: 60)
        let clients: GmailLabelID = "Label_1"
        try await store.saveLabelTable([entry(clients, name: "Clients", total: 5)])
        var changes: [GmailChange] = []
        for n in 1...100 { changes.append(place(UInt64(n), labels: n <= 5 ? [clients] : [.inbox])) }
        changes.append(place(200, labels: [.inbox, .spam]))
        changes.append(place(201, labels: [.inbox, .trash]))
        try await store.commit(GmailJournalBatch(changes: changes, cursor: HistoryID(raw: 1)))
        await store.setPinned([ref(50).id])
        await store.noteFolderShown(clients, rows: 25, at: Date())

        let wanted = await store.messagesToCache(limit: 1_000)
        XCTAssertEqual(wanted.count, 60)
        XCTAssertEqual(wanted.first, ref(50).id, "pinned messages first")
        XCTAssertFalse(wanted.contains(ref(200).id), "never Junk Email")
        XCTAssertFalse(wanted.contains(ref(201).id), "never Deleted Items")
        XCTAssertTrue(Set((1...5).map { ref(UInt64($0)).id }).isSubset(of: wanted), "the first screen of a folder in use, however old")
        XCTAssertTrue(wanted.contains(ref(100).id), "then the newest")
        let few = await store.messagesToCache(limit: 3)
        XCTAssertEqual(few.count, 3)

        try await store.cache(cachedMessage(50), body: nil)
        let after = await store.messagesToCache(limit: 1_000)
        XCTAssertFalse(after.contains(ref(50).id), "only what is not cached yet")
    }

    func testKeptMessagesCanBeSearchedOffline() async throws {
        let store = MemoryGmailStore()
        var invoice = cachedMessage(1)
        invoice.subject = "Freight invoice March"
        invoice.from = EmailAddress(name: "Carrier Billing", address: "billing@carrier.example")
        var later = cachedMessage(2)
        later.subject = "Invoice April"
        later.preview = "Freight charges attached"
        try await store.cache(invoice, body: nil)
        try await store.cache(later, body: nil)
        try await store.cache(cachedMessage(3), body: nil)
        let both = await store.searchCached("freight INVOICE", limit: 10)
        XCTAssertEqual(both, [ref(2).id, ref(1).id], "every word, in any field, newest first")
        let sender = await store.searchCached("carrier march", limit: 10)
        XCTAssertEqual(sender, [ref(1).id])
        let one = await store.searchCached("invoice", limit: 1)
        XCTAssertEqual(one, [ref(2).id])
        let none = await store.searchCached("  ", limit: 10)
        XCTAssertTrue(none.isEmpty)
    }

    func testSummariesAnchorsAndTheImportLogAreKept() async throws {
        let store = MemoryGmailStore()
        let thread = ref(1).threadID
        let summary = GmailThreadSummary(threadID: thread, senders: [EmailAddress(address: "ana@example.com")], messageCount: 2,
                                         newestDate: Date(timeIntervalSince1970: 1_790_000_000),
                                         members: [GmailThreadMember(id: ref(1).id, from: EmailAddress(address: "ana@example.com"),
                                                                     date: Date(timeIntervalSince1970: 1_789_000_000))])
        try await store.saveThreadSummaries([summary])
        var summaries = await store.threadSummaries([thread, ref(2).threadID])
        XCTAssertEqual(summaries, [thread: summary])
        try await store.removeThreadSummaries([thread])
        summaries = await store.threadSummaries([thread])
        XCTAssertTrue(summaries.isEmpty)

        let anchor = GmailDateAnchor(boundary: Date(timeIntervalSince1970: 1_789_000_000), id: ref(3).id, order: 48, askedAt: Date())
        try await store.saveDateAnchors([anchor])
        let anchors = await store.dateAnchors()
        XCTAssertEqual(anchors, [anchor])

        let now = Date(timeIntervalSince1970: 1_790_000_000)
        try await store.noteImported([ref(1).id], at: now)
        try await store.noteImported([ref(2).id], at: now.addingTimeInterval(8 * 86_400))
        let old = await store.wasImported(ref(1).id)
        let recent = await store.wasImported(ref(2).id)
        XCTAssertFalse(old, "kept for 7 days")
        XCTAssertTrue(recent)

        try await store.compact()
        let compactions = await store.compactions
        XCTAssertEqual(compactions, 1)
        XCTAssertEqual(store.files.indexJournal.lastPathComponent, "index.journal")
    }

    func testTheFilesSitBesideTheIMAPStore() {
        let account = UUID()
        let layout = FileLayout(root: URL(fileURLWithPath: "/tmp/falcon-layout"))
        let files = GmailFiles(layout: layout, accountID: account)
        XCTAssertEqual(files.directory.path, layout.accountDirectory(account).appendingPathComponent("Gmail").path)
        XCTAssertEqual(files.body(GmailMessageID(raw: 0x18a0_0000_0000_0001)).lastPathComponent, "18a0000000000001.lzfse")
        XCTAssertEqual(files.body(GmailMessageID(raw: 1)).deletingLastPathComponent(), files.bodiesDirectory)
        let names = [files.indexSnapshot, files.indexJournal, files.labels, files.dateAnchors, files.threadSummaries, files.terms,
                     files.importLog, files.pendingOps, files.drafts, files.state, files.migration].map(\.lastPathComponent)
        XCTAssertEqual(Set(names).count, names.count, "no two share a file")
        XCTAssertTrue([files.indexSnapshot, files.pendingOps, files.cacheDirectory].allSatisfy { $0.path.hasPrefix(files.directory.path) })
        XCTAssertFalse(names.contains("folders.json"), "never the IMAP store's folder list")
    }

    private func cachedMessage(_ n: UInt64) -> GmailCachedMessage {
        GmailCachedMessage(id: ref(n).id, threadID: ref(n).threadID, from: EmailAddress(address: "ana@example.com"), subject: "Mail \(n)",
                           preview: "Hello", date: Date(timeIntervalSince1970: 1_790_000_000 + Double(n)), size: 100,
                           hasAttachments: false, messageID: "<\(n)@x>", cachedAt: Date())
    }
}
