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
