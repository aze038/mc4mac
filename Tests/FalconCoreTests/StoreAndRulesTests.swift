import XCTest
@testable import FalconCore

final class StoreAndRulesTests: XCTestCase {
    func summary(uid: UInt32, subject: String, from: String, messageID: String, refs: [String] = []) -> MessageSummary {
        MessageSummary(accountID: UUID(), folderID: UUID(), uid: uid, messageID: messageID, inReplyTo: refs.last ?? "", references: refs,
                       subject: subject, from: EmailAddress(address: from), to: [], cc: [], date: Date(), flags: [], size: 1, hasAttachments: false)
    }

    func testFolderStoreJournalAndSnapshot() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let accountID = UUID(), folderID = UUID()
        let store = FolderStore(accountID: accountID, folderID: folderID, directory: tmp)
        try await store.load()
        var m = summary(uid: 1, subject: "One", from: "a@b", messageID: "<1@b>")
        m.accountID = accountID; m.folderID = folderID
        try await store.upsert([m])
        _ = try await store.setFlags([(uid: 1, flags: [.seen, .flagged])])
        try await store.storeBody(uid: 1, raw: Data("raw".utf8), snippet: "snip", hasAttachments: true)

        let reopened = FolderStore(accountID: accountID, folderID: folderID, directory: tmp)
        try await reopened.load()
        let loaded = await reopened.message(uid: 1)
        XCTAssertEqual(loaded?.isRead, true)
        XCTAssertEqual(loaded?.isFlagged, true)
        XCTAssertEqual(loaded?.snippet, "snip")
        XCTAssertEqual(loaded?.hasBody, true)
        let body = await reopened.body(uid: 1)
        XCTAssertEqual(body, Data("raw".utf8))
        let uid = await reopened.uid(forMessageID: "<1@b>")
        XCTAssertEqual(uid, 1)

        try await reopened.flush()
        try await reopened.remove(uids: [1])
        let again = FolderStore(accountID: accountID, folderID: folderID, directory: tmp)
        try await again.load()
        let count = await again.count
        XCTAssertEqual(count, 0)
    }

    func testThreading() {
        var known: [String: String] = [:]
        let root = ConversationThreader.threadKey(messageID: "<a@x>", inReplyTo: "", references: [], subject: "Hello") { known[$0] }
        XCTAssertEqual(root, "<a@x>")
        known["<a@x>"] = root
        let reply = ConversationThreader.threadKey(messageID: "<b@x>", inReplyTo: "<a@x>", references: ["<a@x>"], subject: "Re: Hello") { known[$0] }
        XCTAssertEqual(reply, "<a@x>")
        XCTAssertEqual(ConversationThreader.normalizedSubject("RE: Fwd: AW:  Hello   world"), "hello world")
        let orphan = ConversationThreader.threadKey(messageID: "", inReplyTo: "", references: [], subject: "Re: Topic") { _ in nil }
        XCTAssertEqual(orphan, "subject:topic")
    }

    func testRules() {
        let rule = RuleDefinition(name: "Newsletters", matchAll: false,
                                  conditions: [RuleCondition(field: .from, op: .contains, value: "newsletter"), RuleCondition(field: .subject, op: .startsWith, value: "[promo]")],
                                  actions: [RuleAction(kind: .markRead), RuleAction(kind: .moveToFolder, value: "Newsletters")])
        let m = summary(uid: 1, subject: "[PROMO] Sale", from: "shop@example.com", messageID: "<x>")
        let actions = RuleEngine.actions(for: [rule], accountID: m.accountID, subject: RuleSubject(summary: m))
        XCTAssertEqual(actions.map { $0.kind }, [.markRead, .moveToFolder])
        let other = summary(uid: 2, subject: "Hi", from: "friend@example.com", messageID: "<y>")
        XCTAssertTrue(RuleEngine.actions(for: [rule], accountID: other.accountID, subject: RuleSubject(summary: other)).isEmpty)
    }

    func testMboxReader() {
        let mbox = "From a@b Mon Jan 1 00:00:00 2024\nFrom: a@b\nSubject: One\nStatus: RO\n\nHello\n>From here\n\nFrom c@d Mon Jan 1 00:00:00 2024\nFrom: c@d\nSubject: Two\n\nWorld\n"
        let messages = MboxReader.messages(in: Data(mbox.utf8))
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages[0].flags.contains(.seen))
        XCTAssertTrue(messages[0].raw.utf8Lossy.contains("\r\nFrom here"))
        XCTAssertTrue(messages[1].raw.utf8Lossy.hasPrefix("From: c@d"))
    }

    func testMuteMatching() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = MuteStore(layout: FileLayout(root: tmp))
        let accountID = UUID()
        let record = MutedThread(accountID: accountID, threadKey: "<root@x>", messageIDs: ["<root@x>"],
                                 normalizedSubject: ConversationThreader.normalizedSubject("Lunch plans"),
                                 subject: "Lunch plans")
        await store.mute(record)

        let byKey = await store.match(accountID: accountID, threadKey: "<root@x>", messageID: "<later@x>",
                                      references: [], inReplyTo: "")
        XCTAssertEqual(byKey?.threadKey, "<root@x>")

        let byReference = await store.match(accountID: accountID, threadKey: "<orphan@x>", messageID: "<reply@x>",
                                            references: ["<root@x>"], inReplyTo: "<root@x>")
        XCTAssertEqual(byReference?.threadKey, "<root@x>")

        await store.remember(messageID: "<reply@x>", accountID: accountID, threadKey: "<root@x>")
        let byChain = await store.match(accountID: accountID, threadKey: "<orphan@x>", messageID: "<third@x>",
                                        references: ["<reply@x>"], inReplyTo: "<reply@x>")
        XCTAssertEqual(byChain?.threadKey, "<root@x>")

        let sameSubject = await store.match(accountID: accountID, threadKey: "<fresh@x>", messageID: "<fresh@x>",
                                            references: [], inReplyTo: "")
        XCTAssertNil(sameSubject)

        let otherAccount = await store.match(accountID: UUID(), threadKey: "<root@x>", messageID: "<root@x>",
                                             references: [], inReplyTo: "")
        XCTAssertNil(otherAccount)

        await store.unmute(accountID: accountID, threadKey: "<root@x>")
        let afterUnmute = await store.all()
        XCTAssertTrue(afterUnmute.isEmpty)
    }

    func testSMTPDotStuffing() {
        XCTAssertEqual(SMTPClient.dotStuffed(Data("a\r\n.b\r\n..".utf8)), Data("a\r\n..b\r\n...".utf8))
    }
}

extension StoreAndRulesTests {
    /// A mailbox with many messages must be able to answer "the newest page" without
    /// materialising or sorting the whole folder, which is what froze the interface at 100k.
    func testFolderStoreNewestPage() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let accountID = UUID(), folderID = UUID()
        let store = FolderStore(accountID: accountID, folderID: folderID, directory: tmp)
        try await store.load()

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var batch: [MessageSummary] = []
        for uid in 1...500 {
            var m = summary(uid: UInt32(uid), subject: "Message \(uid)", from: "a@b", messageID: "<\(uid)@b>")
            m.accountID = accountID
            m.folderID = folderID
            m.date = base.addingTimeInterval(Double(uid))
            var flags: MessageFlags = []
            if uid % 5 == 0 { flags.insert(.flagged) }
            if uid % 2 == 0 { flags.insert(.seen) }
            m.apply(flags: flags)
            batch.append(m)
        }
        try await store.upsert(batch)

        let page = await store.newest(10)
        XCTAssertEqual(page.count, 10)
        XCTAssertEqual(page.first?.uid, 500)
        XCTAssertEqual(page.last?.uid, 491)
        XCTAssertEqual(page.map(\.date), page.map(\.date).sorted(by: >))

        let flagged = await store.newest(4, scope: .flagged)
        XCTAssertEqual(flagged.count, 4)
        XCTAssertTrue(flagged.allSatisfy { $0.isFlagged })
        XCTAssertEqual(flagged.first?.uid, 500)

        let unread = await store.matchCount(.unread)
        XCTAssertEqual(unread, 250)
        let unreadTally = await store.unreadCount()
        XCTAssertEqual(unreadTally, 250)
        let allCount = await store.matchCount(.all)
        XCTAssertEqual(allCount, 500)
        let emptyPage = await store.newest(0)
        XCTAssertEqual(emptyPage.count, 0)
        let wholeFolder = await store.newest(10_000)
        XCTAssertEqual(wholeFolder.count, 500)
    }

    /// Grouping assumes its input is already newest-first; the sort it used to repeat
    /// doubled the cost of every list reload.
    func testThreaderKeepsIncomingOrder() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var a = summary(uid: 1, subject: "Root", from: "a@b", messageID: "<1@b>")
        a.threadKey = "t1"
        a.date = base.addingTimeInterval(300)
        var b = summary(uid: 2, subject: "Other", from: "c@d", messageID: "<2@d>")
        b.threadKey = "t2"
        b.date = base.addingTimeInterval(200)
        var c = summary(uid: 3, subject: "Re: Root", from: "a@b", messageID: "<3@b>")
        c.threadKey = "t1"
        c.date = base.addingTimeInterval(100)

        let grouped = ConversationThreader.group([a, b, c])
        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(grouped[0].map(\.uid), [1, 3])
        XCTAssertEqual(grouped[1].map(\.uid), [2])
        XCTAssertEqual(ConversationThreader.groupUnordered([c, a, b])[0].map(\.uid), [1, 3])
    }
}
