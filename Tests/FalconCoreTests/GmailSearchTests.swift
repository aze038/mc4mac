import XCTest
@testable import FalconCore

final class GmailSearchTests: XCTestCase {
    private var roots: [URL] = []

    override func setUp() {
        super.setUp()
        Log.isEnabled = false
    }

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        // The log is the whole process's: the engine's tests read what it says after these run.
        Log.isEnabled = true
        super.tearDown()
    }

    private struct Fixture {
        let root: URL
        let store: MailStore
        let account: AccountInfo
        let folders: [String: FolderInfo]

        func folder(_ path: String) -> FolderInfo { folders[path]! }
    }

    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gmail-search-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let store = MailStore(layout: FileLayout(root: root))
        try await store.load()
        let account = AccountInfo.google(email: "owner@example.com", displayName: "Owner")
        try await store.saveAccount(account)
        let listed = [
            IMAPFolderInfo(path: "INBOX", displayName: "Inbox", delimiter: "/", attributes: []),
            IMAPFolderInfo(path: "[Gmail]/Trash", displayName: "Trash", delimiter: "/", attributes: ["\\HasNoChildren", "\\Trash"]),
            IMAPFolderInfo(path: "[Gmail]/Spam", displayName: "Spam", delimiter: "/", attributes: ["\\HasNoChildren", "\\Junk"]),
            IMAPFolderInfo(path: "[Gmail]/All Mail", displayName: "All Mail", delimiter: "/", attributes: ["\\HasNoChildren", "\\All"]),
            IMAPFolderInfo(path: "Work/Clients", displayName: "Clients", delimiter: "/", attributes: ["\\HasNoChildren"])
        ]
        let folders = try await store.reconcileFolders(accountID: account.id, listed: listed)
        // The running app has every folder loaded by the time anyone searches.
        for folder in folders { _ = try await store.folderStore(folder) }
        return Fixture(root: root, store: store, account: account, folders: Dictionary(uniqueKeysWithValues: folders.map { ($0.path, $0) }))
    }

    @discardableResult
    private func storeMessage(_ fixture: Fixture, in path: String, uid: UInt32, messageID: String, subject: String,
                              date: Date = Date()) async throws -> MessageSummary {
        let folder = fixture.folder(path)
        let message = MessageSummary(accountID: fixture.account.id, folderID: folder.id, uid: uid, messageID: messageID, inReplyTo: "",
                                     references: [], subject: subject, from: EmailAddress(name: "Ana", address: "ana@example.com"),
                                     to: [EmailAddress(address: "owner@example.com")], cc: [], date: date, flags: [.seen], size: 100,
                                     hasAttachments: false)
        try await fixture.store.folderStore(folder).upsert([message])
        return message
    }

    private func search(_ fixture: Fixture, _ client: GmailAPIClient, _ query: String, folder: FolderInfo? = nil,
                        includeSpamTrash: Bool = false, pageSize: Int = 25, listSize: Int = 100) -> GmailAccountSearch {
        GmailAccountSearch(client: client, store: fixture.store, scope: MailSearchScope(account: fixture.account, folder: folder),
                           query: query, includeSpamTrash: includeSpamTrash, pageSize: pageSize, listSize: listSize)
    }

    // MARK: - Scope

    func testFolderScopeAddsGmailsOwnTermsAndAllMailboxesAddsNothing() {
        let account = UUID()
        func folder(_ role: FolderRole, _ path: String) -> FolderInfo {
            FolderInfo(accountID: account, path: path, name: path, delimiter: "/", role: role, attributes: [], isSelectable: true)
        }
        typealias Target = GmailAccountSearch.Target
        XCTAssertEqual(GmailAccountSearch.target(query: "from:a+b@x.com", folder: nil, includeSpamTrash: true, labelID: nil),
                       Target(query: "from:a+b@x.com", labelIDs: [], includeSpamTrash: true))
        XCTAssertEqual(GmailAccountSearch.target(query: "invoice OR receipt", folder: folder(.inbox, "INBOX"), includeSpamTrash: true, labelID: nil),
                       Target(query: "in:inbox invoice OR receipt", labelIDs: [], includeSpamTrash: false))
        XCTAssertEqual(GmailAccountSearch.target(query: "x", folder: folder(.junk, "[Gmail]/Spam"), includeSpamTrash: false, labelID: nil),
                       Target(query: "in:spam x", labelIDs: [], includeSpamTrash: true))
        XCTAssertEqual(GmailAccountSearch.target(query: "x", folder: folder(.trash, "[Gmail]/Trash"), includeSpamTrash: false, labelID: nil).query, "in:trash x")
        XCTAssertEqual(GmailAccountSearch.target(query: "x", folder: folder(.all, "[Gmail]/All Mail"), includeSpamTrash: true, labelID: nil),
                       Target(query: "x", labelIDs: [], includeSpamTrash: false))
        XCTAssertEqual(GmailAccountSearch.target(query: "x", folder: folder(.other, "Work/Clients"), includeSpamTrash: false, labelID: "Label_7"),
                       Target(query: "x", labelIDs: ["Label_7"], includeSpamTrash: false))
        XCTAssertEqual(GmailAccountSearch.target(query: "x", folder: folder(.other, "Work/Big Clients"), includeSpamTrash: false, labelID: nil).query,
                       "label:work-big-clients x")
    }

    func testCurrentFolderScopeSearchesByLabelID() async throws {
        let fixture = try await makeFixture()
        let mailbox = FakeGmailMailbox()
        mailbox.userLabels = ["Label_7": "Work/Clients"]
        let stored = try await storeMessage(fixture, in: "Work/Clients", uid: 4, messageID: "<clients@x>", subject: "Invoice for clients")
        mailbox.add(subject: "Invoice for clients", labels: ["Label_7"], messageID: "<clients@x>")
        mailbox.add(subject: "Invoice elsewhere", labels: ["INBOX"])
        let client = GmailTestKit.client(mailbox, accountID: fixture.account.id)
        let page = await search(fixture, client, "invoice", folder: fixture.folder("Work/Clients")).nextPage()
        XCTAssertEqual(page.messages.map(\.id), [stored.id])
        XCTAssertTrue(mailbox.rawQueries.last?.contains("labelIds=Label_7") == true)
        XCTAssertEqual(mailbox.queries.last, "invoice")
    }

    // MARK: - Turning hits into rows

    func testHitsUseTheStoredRowByMessageIDOrBecomeReadOnlyServerRows() async throws {
        let fixture = try await makeFixture()
        let mailbox = FakeGmailMailbox()
        let now = Date()
        let stored = try await storeMessage(fixture, in: "INBOX", uid: 7, messageID: "<kept@x>", subject: "Invoice kept", date: now)
        mailbox.add(subject: "Invoice kept", labels: ["INBOX"], date: now, messageID: "<kept@x>")
        let old = mailbox.add(subject: "Invoice from 2019", from: "Bob Builder <bob@example.com>", to: "owner@example.com", cc: "Cy <cy@example.com>",
                              text: "Tom's quote & <estimate>", labels: ["UNREAD", "STARRED", "CATEGORY_UPDATES"],
                              date: now.addingTimeInterval(-86_400 * 2_000), messageID: "<old@x>", threadID: "thread-9")
        mailbox.add(subject: "Lunch", labels: ["INBOX"])
        let client = GmailTestKit.client(mailbox, accountID: fixture.account.id)
        let page = await search(fixture, client, "invoice").nextPage()

        XCTAssertNil(page.fallback)
        XCTAssertFalse(page.isLocal)
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.messages.count, 2)
        XCTAssertEqual(page.messages[0], stored, "a hit stored under its Message-ID is the row the reader already has")
        XCTAssertFalse(page.messages[0].isServerOnly)

        let server = page.messages[1]
        XCTAssertTrue(server.isServerOnly)
        XCTAssertEqual(server.id, GmailServerRow.id(accountID: fixture.account.id, gmailID: old.id))
        XCTAssertEqual(GmailServerRow.reference(from: server.id)?.gmailID, old.id)
        XCTAssertEqual(server.subject, "Invoice from 2019")
        XCTAssertEqual(server.from, EmailAddress(name: "Bob Builder", address: "bob@example.com"))
        XCTAssertEqual(server.to.map(\.address), ["owner@example.com"])
        XCTAssertEqual(server.cc.map(\.address), ["cy@example.com"])
        XCTAssertEqual(server.messageID, "<old@x>")
        XCTAssertEqual(server.snippet, "Tom's quote & <estimate>")
        XCTAssertFalse(server.isRead)
        XCTAssertTrue(server.isFlagged)
        XCTAssertEqual(server.threadKey, "gm:thread-9")
        XCTAssertEqual(server.date.timeIntervalSince1970, old.date.timeIntervalSince1970, accuracy: 0.01)
        let resolved = try await fixture.store.message(id: server.id)
        XCTAssertNil(resolved, "a server-only row never resolves to a stored message")
    }

    func testSpamAndTrashHitsUseACopyOnlyWhereGmailSaysTheMessageIs() async throws {
        let fixture = try await makeFixture()
        let mailbox = FakeGmailMailbox()
        let base = Date()
        let inTrash = try await storeMessage(fixture, in: "[Gmail]/Trash", uid: 3, messageID: "<trash@x>", subject: "Invoice binned")
        try await storeMessage(fixture, in: "INBOX", uid: 9, messageID: "<moved@x>", subject: "Invoice moved")
        mailbox.add(subject: "Invoice binned", labels: ["TRASH"], date: base, messageID: "<trash@x>")
        let spam = mailbox.add(subject: "Invoice spam", labels: ["SPAM"], date: base.addingTimeInterval(-60), messageID: "<spam@x>")
        let moved = mailbox.add(subject: "Invoice moved", labels: ["TRASH"], date: base.addingTimeInterval(-120), messageID: "<moved@x>")
        let client = GmailTestKit.client(mailbox, accountID: fixture.account.id)

        let page = await search(fixture, client, "invoice", includeSpamTrash: true).nextPage()
        XCTAssertEqual(page.messages.count, 3)
        XCTAssertEqual(page.messages[0], inTrash)
        XCTAssertEqual(page.messages[1].id, GmailServerRow.id(accountID: fixture.account.id, gmailID: spam.id))
        XCTAssertEqual(page.messages[2].id, GmailServerRow.id(accountID: fixture.account.id, gmailID: moved.id),
                       "the Inbox copy is stale once Gmail has it in the Trash, so it is not used")

        let without = await search(fixture, client, "invoice", includeSpamTrash: false).nextPage()
        XCTAssertTrue(without.messages.isEmpty)
        let spamOnly = await search(fixture, client, "invoice", folder: fixture.folder("[Gmail]/Spam")).nextPage()
        XCTAssertEqual(spamOnly.messages.map(\.subject), ["Invoice spam"])
    }

    func testAMessageDeletedBetweenListAndFetchIsLeftOut() async throws {
        let fixture = try await makeFixture()
        let mailbox = FakeGmailMailbox()
        mailbox.add(subject: "Report one", date: Date())
        mailbox.add(subject: "Report two", date: Date().addingTimeInterval(-10))
        mailbox.inject(.status(404, reason: "notFound"), for: .messagesGet)
        let client = GmailTestKit.client(mailbox, accountID: fixture.account.id)
        let page = await search(fixture, client, "report").nextPage()
        XCTAssertNil(page.fallback)
        XCTAssertEqual(page.messages.count, 1)
    }

    func testAnEmptyOrReusedMessageIDNeverShowsAnotherMessage() async throws {
        let fixture = try await makeFixture()
        let now = Date()
        try await storeMessage(fixture, in: "INBOX", uid: 1, messageID: "<>", subject: "Totally unrelated stored message", date: now)
        try await storeMessage(fixture, in: "INBOX", uid: 2, messageID: "<reused@mailer.example>", subject: "Holiday plans",
                               date: now.addingTimeInterval(-86_400 * 900))
        let imported = try await storeMessage(fixture, in: "INBOX", uid: 3, messageID: "<imported@x>", subject: "Invoice imported",
                                              date: now.addingTimeInterval(-86_400 * 5))
        let mailbox = FakeGmailMailbox()
        mailbox.add(subject: "Invoice from a broken mailer", labels: ["INBOX"], date: now, messageID: "<>")
        mailbox.add(subject: "Invoice for March", labels: ["INBOX"], date: now.addingTimeInterval(-60), messageID: "<reused@mailer.example>")
        mailbox.add(subject: "Invoice  imported", labels: ["INBOX"], date: now.addingTimeInterval(-120), messageID: "<imported@x>")
        let client = GmailTestKit.client(mailbox, accountID: fixture.account.id)

        let page = await search(fixture, client, "invoice").nextPage()
        XCTAssertEqual(page.messages.map(\.subject), ["Invoice from a broken mailer", "Invoice for March", "Invoice imported"])
        XCTAssertTrue(page.messages[0].isServerOnly, "an empty Message-ID names no message")
        XCTAssertTrue(page.messages[1].isServerOnly, "a reused Message-ID with another subject and date is another message")
        XCTAssertEqual(page.messages[2], imported, "the same subject is enough when Gmail dates the message differently")
    }

    // MARK: - Pages

    func testPagesResolveOnlyWhatIsShownAndFollowNextPageToken() async throws {
        let fixture = try await makeFixture()
        let mailbox = FakeGmailMailbox()
        let start = Date()
        for i in 0..<60 { mailbox.add(subject: "Statement \(i)", date: start.addingTimeInterval(TimeInterval(-i * 60))) }
        let client = GmailTestKit.client(mailbox, accountID: fixture.account.id)
        let search = search(fixture, client, "statement", pageSize: 25, listSize: 20)

        let first = await search.nextPage()
        XCTAssertEqual(first.messages.map(\.subject), (0..<25).map { "Statement \($0)" }, "newest first")
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(mailbox.calls[.messagesGet], 25, "only the page being shown is fetched")
        XCTAssertEqual(mailbox.calls[.messagesList], 2)
        XCTAssertTrue(mailbox.rawQueries.last?.contains("pageToken=20") == true)
        XCTAssertEqual(mailbox.units[.messagesList], 10)
        XCTAssertEqual(mailbox.units[.messagesGet], 500)

        let second = await search.nextPage()
        XCTAssertEqual(second.messages.map(\.subject), (25..<50).map { "Statement \($0)" })
        XCTAssertTrue(second.hasMore)
        let third = await search.nextPage()
        XCTAssertEqual(third.messages.map(\.subject), (50..<60).map { "Statement \($0)" })
        XCTAssertFalse(third.hasMore)
        XCTAssertEqual(mailbox.calls[.messagesGet], 60)
        XCTAssertEqual(mailbox.calls[.messagesList], 3)
        let fourth = await search.nextPage()
        XCTAssertTrue(fourth.messages.isEmpty)
        XCTAssertFalse(fourth.hasMore)
    }

    func testResultsFromSeveralAccountsMergeByDate() {
        func row(_ id: String, _ seconds: TimeInterval) -> MessageSummary {
            var m = MessageSummary(accountID: UUID(), folderID: GmailServerRow.folderID, uid: 0, messageID: "", inReplyTo: "", references: [],
                                   subject: id, from: EmailAddress(address: "a@x"), to: [], cc: [],
                                   date: Date(timeIntervalSince1970: seconds), flags: [], size: 0, hasAttachments: false)
            m.id = id
            return m
        }
        let first = MailSearchResults.merge([], [row("a1", 100), row("a2", 50)])
        let merged = MailSearchResults.merge(first, [row("b1", 80), row("a2", 50), row("b2", 10)])
        XCTAssertEqual(merged.map(\.id), ["a1", "b1", "a2", "b2"])
    }

    func testOverlappingRequestsForMoreTakeSuccessivePages() async throws {
        let fixture = try await makeFixture()
        let mailbox = FakeGmailMailbox()
        let start = Date()
        for i in 0..<40 { mailbox.add(subject: "Receipt \(i)", date: start.addingTimeInterval(TimeInterval(-i * 60))) }
        let client = GmailTestKit.client(mailbox, accountID: fixture.account.id)
        let search = search(fixture, client, "receipt")

        async let a = search.nextPage()
        async let b = search.nextPage()
        let pages = await [a, b]
        let subjects = pages.flatMap { $0.messages.map(\.subject) }
        XCTAssertEqual(Set(subjects), Set((0..<40).map { "Receipt \($0)" }), "every hit once, none skipped")
        XCTAssertEqual(subjects.count, 40)
        XCTAssertEqual(mailbox.calls[.messagesGet], 40, "no hit is fetched twice")
        XCTAssertEqual(pages.filter(\.hasMore).count, 1)
    }

    func testScrollingPastTheBudgetPausesInsteadOfLeavingGmail() async throws {
        let fixture = try await makeFixture()
        let mailbox = FakeGmailMailbox()
        let start = Date()
        for i in 0..<200 { mailbox.add(subject: "Order \(i)", date: start.addingTimeInterval(TimeInterval(-i * 60))) }
        let clock = VirtualClock()
        let client = GmailTestKit.client(mailbox, clock: clock, accountID: fixture.account.id)
        let search = search(fixture, client, "order")
        var shown: [String] = []

        for _ in 0..<5 {
            let page = await search.nextPage()
            XCTAssertEqual(page.messages.count, 25)
            shown += page.messages.map(\.subject)
        }
        // 2,510 units so far: the sixth page fits 24 fetches in the minute and stops short.
        let sixth = await search.nextPage()
        XCTAssertFalse(sixth.isLocal)
        XCTAssertNil(sixth.fallback)
        XCTAssertEqual(sixth.paused?.kind, .rateLimited)
        XCTAssertTrue(sixth.hasMore, "Show more stays")
        XCTAssertEqual(sixth.messages.count, 24, "the rows already fetched are shown")
        shown += sixth.messages.map(\.subject)
        let seventh = await search.nextPage()
        XCTAssertFalse(seventh.isLocal)
        XCTAssertTrue(seventh.hasMore)
        XCTAssertTrue(seventh.messages.isEmpty, "nothing is sent while the minute is full")

        clock.advance(61)
        while true {
            let page = await search.nextPage()
            XCTAssertFalse(page.isLocal)
            shown += page.messages.map(\.subject)
            if !page.hasMore { break }
            if page.paused != nil { clock.advance(61) }
        }
        XCTAssertEqual(shown.count, 200, "no result is shown twice")
        XCTAssertEqual(Set(shown), Set((0..<200).map { "Order \($0)" }), "every result is reachable")
    }

    func testOneRefusedFetchKeepsTheRowsAlreadyFetched() async throws {
        let fixture = try await makeFixture()
        let mailbox = FakeGmailMailbox()
        let start = Date()
        for i in 0..<25 { mailbox.add(subject: "Quote \(i)", date: start.addingTimeInterval(TimeInterval(-i * 60))) }
        mailbox.inject(.status(429, reason: "rateLimitExceeded", retryAfter: "20"), for: .messagesGet)
        let clock = VirtualClock()
        let client = GmailTestKit.client(mailbox, clock: clock, accountID: fixture.account.id)
        let search = search(fixture, client, "quote")

        let first = await search.nextPage()
        XCTAssertFalse(first.isLocal)
        XCTAssertNil(first.fallback)
        XCTAssertEqual(first.paused?.kind, .rateLimited)
        XCTAssertTrue(first.hasMore)
        XCTAssertFalse(first.messages.isEmpty, "the fetches Gmail answered are shown")
        XCTAssertEqual(first.messages.count, mailbox.calls[.messagesGet])

        clock.advance(25)
        let second = await search.nextPage()
        XCTAssertFalse(second.isLocal, "Gmail is asked again once its Retry-After has passed")
        XCTAssertNil(second.paused)
        XCTAssertFalse(second.hasMore)
        let all = (first.messages + second.messages).sorted { $0.date > $1.date }.map(\.subject)
        XCTAssertEqual(all, (0..<25).map { "Quote \($0)" })
        XCTAssertEqual(mailbox.calls[.messagesGet], 25, "nothing fetched is fetched again")
    }

    func testABurstOfRateRefusalsHalvesTheBudgetOnce() async throws {
        let fixture = try await makeFixture()
        let mailbox = FakeGmailMailbox()
        let start = Date()
        for i in 0..<25 { mailbox.add(subject: "Memo \(i)", date: start.addingTimeInterval(TimeInterval(-i * 60))) }
        // Gmail refuses all eight concurrent fetches of the first wave, as it does for too many
        // concurrent requests, without a Retry-After.
        mailbox.inject(.status(429, reason: "rateLimitExceeded"), for: .messagesGet, times: 8)
        let clock = VirtualClock()
        let client = GmailTestKit.client(mailbox, clock: clock, accountID: fixture.account.id)

        let page = await search(fixture, client, "memo").nextPage()
        XCTAssertNil(page.fallback)
        XCTAssertNil(page.paused)
        XCTAssertEqual(page.messages.count, 25, "the page finishes after the pause")
        XCTAssertEqual(mailbox.attempts[.messagesGet], 33)
        let limit = await client.limiter.currentLimit
        XCTAssertGreaterThanOrEqual(limit, 1_500, "one burst halves the budget once")
        XCTAssertLessThan(limit, 1_600)

        clock.advance(30)
        let next = await search(fixture, client, "memo").nextPage()
        XCTAssertFalse(next.isLocal, "a search half a minute later still goes to Gmail")
        XCTAssertEqual(next.messages.count, 25)
    }

    func testASearchIsRepeatedOnlyWhenSomethingChangedOrItFellBack() {
        let account = AccountInfo.google(email: "owner@example.com", displayName: "Owner")
        let inbox = FolderInfo(accountID: account.id, path: "INBOX", name: "Inbox", delimiter: "/", role: .inbox, attributes: [], isSelectable: true)
        let everywhere = [MailSearchScope(account: account)]
        var status = MailSearchStatus(query: "invoice", scopes: everywhere, viaGmail: [account.id])
        XCTAssertTrue(status.repeats(query: "invoice", scopes: everywhere, viaGmail: [account.id]),
                      "Return after the pause has already asked Gmail does not ask again, even while the first page loads")
        XCTAssertFalse(status.repeats(query: "invoices", scopes: everywhere, viaGmail: [account.id]))
        XCTAssertFalse(status.repeats(query: "invoice", scopes: [MailSearchScope(account: account, folder: inbox)], viaGmail: [account.id]))
        XCTAssertFalse(status.repeats(query: "invoice", scopes: everywhere, viaGmail: []), "working offline changes where it searches")

        status.record(MailSearchPage(accountID: account.id, messages: [], hasMore: true, isLocal: false,
                                     paused: GoogleAPIError(kind: .rateLimited)), email: account.email)
        XCTAssertTrue(status.repeats(query: "invoice", scopes: everywhere, viaGmail: [account.id]))
        XCTAssertEqual(status.notice, "Gmail is busy; Show more fetches the rest of the results for owner@example.com in a moment.")
        XCTAssertEqual(status.accountsWithMore, [account.id])
        status.record(MailSearchPage(accountID: account.id, messages: [], hasMore: false, isLocal: false), email: account.email)
        XCTAssertNil(status.notice, "the pause is over once the next page comes")
        XCTAssertFalse(status.anyMore)

        status.record(MailSearchPage(accountID: account.id, messages: [], hasMore: false, isLocal: true,
                                     fallback: GoogleAPIError(kind: .rateLimited)), email: account.email)
        XCTAssertFalse(status.repeats(query: "invoice", scopes: everywhere, viaGmail: [account.id]),
                       "Return tries Gmail again after the search fell back to this Mac")
        XCTAssertEqual(status.notice, "Gmail is busy; showing matches on this Mac for owner@example.com.")
    }

    // MARK: - Falling back to this Mac

    func testQuotaExceededFallsBackToTheMessagesOnThisMac() async throws {
        let fixture = try await makeFixture()
        let local = try await storeMessage(fixture, in: "INBOX", uid: 1, messageID: "<l@x>", subject: "Invoice 42")
        try await storeMessage(fixture, in: "INBOX", uid: 2, messageID: "<m@x>", subject: "Holiday photos")
        let mailbox = FakeGmailMailbox()
        mailbox.add(subject: "Invoice 42 on the server")
        mailbox.always(.status(403, reason: "quotaExceeded"), for: .messagesList)
        let client = GmailTestKit.client(mailbox, accountID: fixture.account.id)
        let search = search(fixture, client, "invoice")

        let page = await search.nextPage()
        XCTAssertTrue(page.isLocal)
        XCTAssertEqual(page.fallback?.kind, .quotaExhausted)
        XCTAssertEqual(page.messages, [local])
        XCTAssertFalse(page.hasMore)
        let notice = try XCTUnwrap(page.fallback?.searchNotice(email: fixture.account.email))
        XCTAssertTrue(notice.contains("owner@example.com") && notice.contains("on this Mac"), notice)
        XCTAssertFalse(notice.lowercased().contains("error"), notice)

        let next = await search.nextPage()
        XCTAssertTrue(next.messages.isEmpty)
        XCTAssertNil(next.fallback, "the notice is given once")
        XCTAssertEqual(mailbox.attempts[.messagesList], 1, "the API is not asked again during this search")
    }

    func testAUsedUpQuotaOrDisabledAPIIsNotAskedAgainUntilItCanHaveChanged() async throws {
        let cases: [(reason: String, kind: GoogleAPIError.Kind, wait: TimeInterval)] = [
            ("dailyLimitExceeded", .quotaExhausted, 25 * 3_600), ("accessNotConfigured", .apiDisabled, 11 * 60)
        ]
        for (reason, kind, wait) in cases {
            let fixture = try await makeFixture()
            let local = try await storeMessage(fixture, in: "INBOX", uid: 1, messageID: "<l@x>", subject: "Invoice 42")
            let mailbox = FakeGmailMailbox()
            mailbox.always(.status(403, reason: reason), for: .messagesList)
            let clock = VirtualClock()
            let client = GmailTestKit.client(mailbox, clock: clock, accountID: fixture.account.id)

            let first = await search(fixture, client, "invoice").nextPage()
            XCTAssertEqual(first.fallback?.kind, kind, reason)
            clock.advance(60)
            let again = await search(fixture, client, "invoice").nextPage()
            XCTAssertEqual(again.fallback?.kind, kind, reason)
            XCTAssertEqual(again.messages, [local])
            XCTAssertEqual(mailbox.attempts[.messagesList], 1, "\(reason): a new search does not ask Gmail again")

            clock.advance(wait)
            _ = await search(fixture, client, "invoice").nextPage()
            XCTAssertEqual(mailbox.attempts[.messagesList], 2, "\(reason): Gmail is asked again once it can have changed")
        }
    }

    func testDisabledAPIOfflineAndSignInAllFallBack() async throws {
        let faults: [(FakeGmailMailbox.Fault, GoogleAPIError.Kind)] = [
            (.status(403, reason: "accessNotConfigured"), .apiDisabled),
            (.offline, .offline),
            (.status(429, reason: "rateLimitExceeded", retryAfter: "300"), .rateLimited)
        ]
        for (fault, kind) in faults {
            let fixture = try await makeFixture()
            let local = try await storeMessage(fixture, in: "INBOX", uid: 1, messageID: "<l@x>", subject: "Invoice 42")
            let mailbox = FakeGmailMailbox()
            mailbox.always(fault, for: .messagesList)
            let client = GmailTestKit.client(mailbox, accountID: fixture.account.id)
            let page = await search(fixture, client, "invoice").nextPage()
            XCTAssertEqual(page.fallback?.kind, kind)
            XCTAssertEqual(page.messages, [local])
        }
        let fixture = try await makeFixture()
        let mailbox = FakeGmailMailbox()
        mailbox.acceptedTokens = []
        let client = GmailTestKit.client(mailbox, accountID: fixture.account.id)
        let page = await search(fixture, client, "invoice").nextPage()
        XCTAssertEqual(page.fallback?.kind, .needsSignIn)
    }

    // MARK: - Opening

    func testOpeningAnOldResultWritesNothingToDisk() async throws {
        let fixture = try await makeFixture()
        try await storeMessage(fixture, in: "INBOX", uid: 1, messageID: "<recent@x>", subject: "Contract recent")
        let mailbox = FakeGmailMailbox()
        mailbox.add(subject: "Contract recent", messageID: "<recent@x>")
        let old = mailbox.add(subject: "Contract 2015", text: "Signed copy attached.", html: "<p>Signed copy <img src=\"cid:logo\"></p>",
                              labels: [], date: Date(timeIntervalSince1970: 1_420_000_000),
                              attachments: [.init(filename: "logo.png", mimeType: "image/png", data: Data(repeating: 7, count: 2_000), contentID: "logo"),
                                            .init(filename: "contract.pdf", mimeType: "application/pdf", data: Data(repeating: 9, count: 300_000))])
        let client = GmailTestKit.client(mailbox, accountID: fixture.account.id)
        let caches = DiskSnapshot.processCaches
        let dataBefore = DiskSnapshot.of(fixture.root)
        let cachesBefore = DiskSnapshot.of(caches)

        let page = await search(fixture, client, "contract").nextPage()
        let hit = try XCTUnwrap(page.messages.first { $0.isServerOnly })
        let reference = try XCTUnwrap(GmailServerRow.reference(from: hit.id))
        XCTAssertEqual(reference.gmailID, old.id)
        var opened = try await client.openText(id: reference.gmailID)
        opened = try await client.withInlineImages(opened)
        let pdf = try XCTUnwrap(opened.attachments.first { $0.filename == "contract.pdf" })
        let bytes = try await client.attachmentData(messageID: reference.gmailID, stub: pdf)
        XCTAssertEqual(bytes.count, 300_000)
        XCTAssertEqual(opened.message.attachments.map(\.contentID), ["logo"])

        XCTAssertEqual(DiskSnapshot.of(fixture.root), dataBefore, "the data folder is untouched")
        XCTAssertEqual(DiskSnapshot.of(caches), cachesBefore, "nothing reaches the caches folder")
    }

    func testLargeMessageShowsItsTextBeforeAnyAttachment() async throws {
        let mailbox = FakeGmailMailbox()
        let big = Data(repeating: 0x25, count: 20 * 1024 * 1024)
        let message = mailbox.add(subject: "Scans", text: "The scans are attached.", html: "<p>The scans are <b>attached</b>.</p>",
                                  attachments: [.init(filename: "scans.pdf", mimeType: "application/pdf", data: big)])
        let client = GmailTestKit.client(mailbox)

        let opened = try await client.openText(id: message.id)
        XCTAssertEqual(opened.message.textPlain, "The scans are attached.")
        XCTAssertEqual(opened.message.textHTML, "<p>The scans are <b>attached</b>.</p>")
        XCTAssertEqual(opened.message.subject, "Scans")
        XCTAssertEqual(opened.attachments.map(\.filename), ["scans.pdf"])
        XCTAssertEqual(opened.attachments.first?.size, big.count)
        XCTAssertTrue(opened.message.attachments.isEmpty)
        XCTAssertTrue(opened.pendingInlineImages.isEmpty)
        XCTAssertNil(mailbox.calls[.attachmentsGet], "no attachment is fetched to show the text")
        XCTAssertLessThan(mailbox.bytesServed[.messagesGet] ?? .max, 10_000)

        let stub = try XCTUnwrap(opened.attachments.first)
        let data = try await client.attachmentData(messageID: message.id, stub: stub)
        XCTAssertEqual(data, big)
        XCTAssertEqual(mailbox.calls[.attachmentsGet], 1)
    }

    func testLongTextPartHeldBackByGmailIsFetchedWithTheText() async throws {
        let body = "Line of text\n"
        let encoded = Data(body.utf8).base64URL
        let json = """
        {"id":"abc","threadId":"abc","payload":{"mimeType":"multipart/mixed","headers":[{"name":"Subject","value":"Long"}],
         "parts":[{"partId":"0","mimeType":"text/plain","filename":"","headers":[{"name":"Content-Type","value":"text/plain; charset=UTF-8"}],
                   "body":{"attachmentId":"text-1","size":13}},
                  {"partId":"1","mimeType":"application/pdf","filename":"a.pdf","headers":[{"name":"Content-Disposition","value":"attachment"}],
                   "body":{"attachmentId":"pdf-1","size":5000000}}]}}
        """
        let message = try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
        XCTAssertEqual(GmailMessageContent.deferredTextParts(message), ["text-1"])
        let opened = GmailMessageContent.textStage(message, fetchedText: ["text-1": Data(base64URL: encoded)!])
        XCTAssertEqual(opened.message.textPlain, body)
        XCTAssertEqual(opened.attachments.map(\.filename), ["a.pdf"])
    }

    func testALargePictureTheTextShowsIsListedAndForwarded() async throws {
        let mailbox = FakeGmailMailbox()
        let message = mailbox.add(subject: "Screenshot", html: "<p>See <img src=\"cid:photo1\"> and <img src=\"cid:logo\"></p>",
                                  attachments: [.init(filename: "photo.jpg", mimeType: "image/jpeg", data: Data(repeating: 3, count: 300_000), contentID: "photo1"),
                                                .init(filename: "logo.png", mimeType: "image/png", data: Data(repeating: 7, count: 2_000), contentID: "logo"),
                                                .init(filename: "terms.pdf", mimeType: "application/pdf", data: Data(repeating: 9, count: 5_000))])
        let client = GmailTestKit.client(mailbox)

        var opened = try await client.openText(id: message.id)
        opened = try await client.withInlineImages(opened)
        XCTAssertEqual(opened.message.attachments.map(\.filename), ["logo.png"], "only the small picture comes with the text")
        XCTAssertEqual(opened.listedAttachments.map(\.filename), ["photo.jpg", "terms.pdf"],
                       "a picture too large to fetch with the text can still be opened and saved")

        XCTAssertEqual(opened.unfetchedAttachments.map(\.filename), ["photo.jpg", "terms.pdf"])
        for stub in opened.unfetchedAttachments {
            opened.add(try await client.attachmentData(messageID: message.id, stub: stub), for: stub)
        }
        XCTAssertTrue(opened.unfetchedAttachments.isEmpty)
        XCTAssertEqual(Set(opened.message.attachments.compactMap(\.contentID)), ["photo1", "logo"],
                       "a forward carries every picture its text refers to")
        XCTAssertEqual(opened.message.attachments.first { $0.contentID == "photo1" }?.data.count, 300_000)
    }

    func testATextFileGmailHeldBackWaitsToBeOpened() throws {
        let json = """
        {"id":"abc","threadId":"abc","payload":{"mimeType":"multipart/mixed","headers":[{"name":"Subject","value":"Export"}],
         "parts":[{"partId":"0","mimeType":"text/plain","filename":"","headers":[{"name":"Content-Type","value":"text/plain; charset=UTF-8"}],
                   "body":{"size":5,"data":"\(Data("Hello".utf8).base64URL)"}},
                  {"partId":"1","mimeType":"text/csv","filename":"export.csv",
                   "headers":[{"name":"Content-Type","value":"text/csv; name=export.csv"},{"name":"Content-Disposition","value":"inline; filename=export.csv"}],
                   "body":{"attachmentId":"csv-1","size":20000000}},
                  {"partId":"2","mimeType":"text/html","filename":"","headers":[{"name":"Content-Type","value":"text/html; charset=UTF-8"}],
                   "body":{"attachmentId":"html-1","size":6000000}}]}}
        """
        let message = try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
        XCTAssertEqual(GmailMessageContent.deferredTextParts(message), [], "nothing is downloaded before the text shows")
        let opened = GmailMessageContent.textStage(message)
        XCTAssertEqual(opened.message.textPlain, "Hello")
        XCTAssertEqual(opened.attachments.map(\.filename).first, "export.csv")
        XCTAssertEqual(opened.attachments.map(\.attachmentID), ["csv-1", "html-1"], "both can be opened or saved on demand")
    }

    func testMovingThroughResultsOpensOnlyTheRowTheReaderStaysOn() async throws {
        let mailbox = FakeGmailMailbox()
        let messages = (0..<40).map { mailbox.add(subject: "Result \($0)") }
        let client = GmailTestKit.client(mailbox)
        let opener = GmailOpener(client: client, settle: 0.3)

        for message in messages {
            let open = Task { try await opener.openText(id: message.id) }
            try await Task.sleep(nanoseconds: 2_000_000)
            open.cancel()
            _ = try? await open.value
        }
        XCTAssertNil(mailbox.attempts[.messagesGet], "a row passed over is never asked for")
        let spent = await client.limiter.spent
        XCTAssertTrue(spent.isEmpty, "and costs nothing")

        async let pane = opener.openText(id: messages[7].id)
        async let reply = opener.openText(id: messages[7].id)
        let (a, b) = try await (pane, reply)
        XCTAssertEqual(a.message.subject, "Result 7")
        XCTAssertEqual(b.message.subject, "Result 7")
        XCTAssertEqual(mailbox.attempts[.messagesGet], 1, "the pane and Reply share one fetch")
    }

    // MARK: - Read-only rows

    func testServerOnlyRowsOfferNoAction() async throws {
        let fixture = try await makeFixture()
        let stored = try await storeMessage(fixture, in: "INBOX", uid: 1, messageID: "<kept@x>", subject: "Invoice kept")
        let mailbox = FakeGmailMailbox()
        mailbox.add(subject: "Invoice kept", messageID: "<kept@x>")
        mailbox.add(subject: "Invoice old", labels: [])
        let client = GmailTestKit.client(mailbox, accountID: fixture.account.id)
        let page = await search(fixture, client, "invoice").nextPage()
        let server = try XCTUnwrap(page.messages.first { $0.isServerOnly })

        XCTAssertEqual(MessageActions.actionable(page.messages), [stored])
        XCTAssertTrue(MessageActions.allowsChanges([stored]))
        XCTAssertFalse(MessageActions.allowsChanges([server]))
        XCTAssertFalse(MessageActions.allowsChanges([stored, server]))
        XCTAssertFalse(MessageActions.allowsChanges([]))
        let folder = await fixture.store.folder(server.folderID)
        XCTAssertNil(folder, "no stored folder exists for a server-only row to act in")
        let resolved = try await fixture.store.message(id: server.id)
        XCTAssertNil(resolved)
    }
}
