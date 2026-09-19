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

    func testSMTPDotStuffing() {
        XCTAssertEqual(SMTPClient.dotStuffed(Data("a\r\n.b\r\n..".utf8)), Data("a\r\n..b\r\n...".utf8))
    }
}
