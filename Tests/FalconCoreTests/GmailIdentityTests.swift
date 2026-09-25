import XCTest
@testable import FalconCore

final class GmailIdentityTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    // MARK: - Gmail's ids

    func testGmailIdsAreTakenOnlyAsGmailWritesThem() {
        XCTAssertEqual(GmailMessageID(hex: "18a0000000000001")?.raw, 0x18a0_0000_0000_0001)
        XCTAssertEqual(GmailMessageID(hex: "ffffffffffffffff")?.raw, UInt64.max)
        // Mail from Gmail's first years has 15 digits, and has to round-trip as such.
        XCTAssertEqual(GmailMessageID(hex: "fb0a1b2c3d4e5f6")?.hex, "fb0a1b2c3d4e5f6")
        XCTAssertEqual(GmailMessageID(hex: "0")?.raw, 0)

        for refused in ["", "18A0000000000001", "018a000000000001", "18a00000000000011", "18a0-00000000001", "g8a0000000000001",
                        " 18a0000000000001", "+18a000000000001", "0x18a00000000000"] {
            XCTAssertNil(GmailMessageID(hex: refused), refused)
            XCTAssertNil(GmailThreadID(hex: refused), refused)
        }
    }

    func testAnIdGmailSendsThatDoesNotParseIsLoggedWithoutItsText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gmail-ids-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let wasEnabled = Log.isEnabled
        Log.isEnabled = true
        defer { Log.isEnabled = wasEnabled }
        Log.start(in: root)

        XCTAssertNotNil(GmailMessageID.fromGmail("18a0000000000001", in: "history"))
        XCTAssertNil(GmailMessageID.fromGmail("not-an-id-secret", in: "history"))
        XCTAssertNil(GmailThreadID.fromGmail("ZZ", in: "a list page"))
        Log.flush()
        let logged = try String(contentsOf: root.appendingPathComponent("falconmail.log"), encoding: .utf8)
            .split(separator: "\n").filter { $0.contains("[gmail]") }
        XCTAssertEqual(logged.count, 2, "\(logged)")
        XCTAssertTrue(logged[0].contains("refused a message id of 16 characters in history"), String(logged[0]))
        XCTAssertTrue(logged[1].contains("refused a thread id of 2 characters in a list page"), String(logged[1]))
        XCTAssertFalse(logged.joined().contains("secret"), "the id itself stays out of the log")
    }

    func testIdsAreWrittenAsGmailWritesThem() throws {
        let id = GmailMessageID(raw: 0x18a0_0000_0000_00ab)
        let thread = GmailThreadID(raw: 0x18a0_0000_0000_0001)
        XCTAssertEqual(String(decoding: try JSONEncoder().encode([id]), as: UTF8.self), "[\"18a00000000000ab\"]")
        XCTAssertEqual(try JSONDecoder().decode([GmailMessageID].self, from: Data("[\"18a00000000000ab\"]".utf8)), [id])
        XCTAssertEqual(try JSONDecoder().decode([GmailThreadID].self, from: try JSONEncoder().encode([thread])), [thread])
        XCTAssertThrowsError(try JSONDecoder().decode([GmailMessageID].self, from: Data("[\"18A00000000000AB\"]".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode([GmailThreadID].self, from: Data("[42]".utf8)))
        XCTAssertLessThan(GmailMessageID(raw: 1), GmailMessageID(raw: 2))
        XCTAssertEqual(id.description, "18a00000000000ab")
    }

    func testThreadKeysMatchTheOnesServerSearchRowsUse() {
        let thread = GmailThreadID(raw: 0x18a0_0000_0000_0042)
        XCTAssertEqual(thread.threadKey, "gm:18a0000000000042")
        XCTAssertEqual(GmailThreadID(threadKey: thread.threadKey), thread)
        XCTAssertNil(GmailThreadID(threadKey: "18a0000000000042"))
        XCTAssertNil(GmailThreadID(threadKey: "gm:"))
        let serverRow = GmailServerRow.summary(for: GmailMessage(id: "18a0000000000099", threadId: thread.hex), accountID: UUID())
        XCTAssertEqual(serverRow.threadKey, thread.threadKey)
    }

    func testHistoryIdsAreDigitsAndOrdered() throws {
        XCTAssertEqual(HistoryID("123456")?.raw, 123_456)
        XCTAssertEqual(HistoryID("18446744073709551615")?.raw, UInt64.max)
        for refused in ["", "-1", "12a", " 12", "18446744073709551616", "+5"] { XCTAssertNil(HistoryID(refused), refused) }
        XCTAssertLessThan(HistoryID(raw: 9), HistoryID(raw: 10))
        XCTAssertEqual(String(decoding: try JSONEncoder().encode([HistoryID(raw: 77)]), as: UTF8.self), "[\"77\"]")
        XCTAssertEqual(try JSONDecoder().decode([HistoryID].self, from: Data("[\"77\", 78]".utf8)), [HistoryID(raw: 77), HistoryID(raw: 78)])
        XCTAssertThrowsError(try JSONDecoder().decode([HistoryID].self, from: Data("[\"7x\"]".utf8)))
    }

    // MARK: - Labels and folders

    func testSystemLabelsHoldTheirFixedSlots() {
        let expected: [GmailLabelID: Int] = [.inbox: 0, .sent: 1, .draft: 2, .spam: 3, .trash: 4, .unread: 5, .starred: 6,
                                             .important: 7, .categoryPersonal: 8, .categorySocial: 9, .categoryPromotions: 10,
                                             .categoryUpdates: 11, .categoryForums: 12, .chat: 13]
        for (label, slot) in expected { XCTAssertEqual(label.fixedSlot, slot, label.value) }
        XCTAssertEqual(GmailLabelID.fixedSlots.count, 14)
        XCTAssertEqual(GmailLabelID.firstUserSlot, 16, "14 and 15 are spare")
        XCTAssertEqual(GmailLabelID.slotCount - GmailLabelID.firstUserSlot, 48)
        XCTAssertNil(GmailLabelID("Label_12").fixedSlot)
        XCTAssertTrue(GmailLabelID("Label_12").isUserLabel)
        XCTAssertFalse(GmailLabelID.inbox.isUserLabel)
        XCTAssertEqual(GmailLabelID.categories.count, 5)
        XCTAssertEqual(GmailLabelID.otherCategories, [.categoryPromotions, .categorySocial, .categoryForums],
                       "Updates stays in Focused: order confirmations, shipping notices and bills")
        XCTAssertEqual(GmailLabelID.fixedByGmail, [.sent, .draft])
        XCTAssertEqual(String(decoding: try! JSONEncoder().encode([GmailLabelID.inbox]), as: UTF8.self), "[\"INBOX\"]")
    }

    func testSystemFoldersUseOutlooksNamesAndOrder() {
        let group = GmailSystemFolder.allCases.filter(\.isInGmailGroup)
        let fixed = group.filter { $0.fixedPlace != nil }.sorted { $0.fixedPlace! < $1.fixedPlace! }.map(\.outlookName)
        XCTAssertEqual(fixed, ["Drafts", "Archive", "Sent", "Deleted Items", "Junk Email"])
        XCTAssertEqual(group.filter { $0.fixedPlace == nil }.map(\.outlookName).sorted(), ["Important", "Starred"])
        XCTAssertEqual(GmailSystemFolder.inbox.outlookName, "Inbox")
        XCTAssertFalse(GmailSystemFolder.inbox.isInGmailGroup)

        let roles = Dictionary(uniqueKeysWithValues: GmailSystemFolder.allCases.map { ($0.outlookName, $0.role) })
        XCTAssertEqual(roles, ["Inbox": .inbox, "Drafts": .drafts, "Archive": .all, "Sent": .sent, "Deleted Items": .trash,
                               "Junk Email": .junk, "Important": .important, "Starred": .flagged])
        XCTAssertNil(GmailSystemFolder.archive.label, "Archive is All Mail, which has no label")
        XCTAssertEqual(GmailSystemFolder(label: .trash), .deletedItems)
        XCTAssertEqual(GmailSystemFolder(label: .spam), .junkEmail)
        XCTAssertEqual(GmailSystemFolder(label: nil), .archive)
        XCTAssertNil(GmailSystemFolder(label: .unread), "UNREAD is the read state, not a folder")
        XCTAssertNil(GmailSystemFolder(label: "Label_3"))
    }

    // MARK: - Row keys

    func testAGoogleRowKeyRoundTripsThroughItsString() throws {
        let account = UUID()
        let key = RowKey.gmail(account: account, id: GmailMessageID(raw: 0x18a0_0000_0000_0abc))
        XCTAssertEqual(key.stringValue, "\(account.uuidString):gm:18a0000000000abc")
        XCTAssertEqual(RowKey(string: key.stringValue), key)
        XCTAssertEqual(key.accountID, account)
        XCTAssertEqual(key.gmailID, GmailMessageID(raw: 0x18a0_0000_0000_0abc))
        XCTAssertTrue(key.isGmail)

        let stored = "\(account.uuidString):\(UUID().uuidString):42"
        XCTAssertEqual(RowKey(string: stored), .stored(stored))
        XCTAssertEqual(RowKey.stored(stored).accountID, account)
        XCTAssertNil(RowKey.stored(stored).gmailID)
        XCTAssertEqual(RowKey(string: "gmail/\(account.uuidString)/18a0"), .stored("gmail/\(account.uuidString)/18a0"),
                       "the old server-only search rows are left as they are")
        XCTAssertNil(RowKey.stored("gmail/x/1").accountID)

        XCTAssertNil(RowKey(string: ""))
        XCTAssertNil(RowKey(string: "\(account.uuidString):gm:ZZ"), "a broken Google key is refused, never taken as a stored one")
        XCTAssertNil(RowKey(string: "not-a-uuid:gm:18a0000000000abc"))
        XCTAssertNil(RowKey(string: "\(account.uuidString):gm:"))

        let data = try JSONEncoder().encode([key, .stored(stored)])
        XCTAssertEqual(try JSONDecoder().decode([RowKey].self, from: data), [key, .stored(stored)])
        XCTAssertThrowsError(try JSONDecoder().decode([RowKey].self, from: Data("[\"\"]".utf8)))
    }

    func testTheStoreNeverResolvesAGoogleRowKey() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rowkey-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let store = MailStore(layout: FileLayout(root: root))
        try await store.load()
        let account = AccountInfo.google(email: "owner@example.com", displayName: "Owner")
        try await store.saveAccount(account)
        let folders = try await store.reconcileFolders(accountID: account.id,
                                                       listed: [IMAPFolderInfo(path: "INBOX", displayName: "Inbox", delimiter: "/", attributes: [])])
        let inbox = try XCTUnwrap(folders.first)
        let stored = MessageSummary(accountID: account.id, folderID: inbox.id, uid: 1, messageID: "<a@x>", inReplyTo: "", references: [],
                                    subject: "Stored", from: EmailAddress(address: "ana@example.com"), to: [], cc: [], date: Date(),
                                    flags: [], size: 10, hasAttachments: false)
        try await store.folderStore(inbox).upsert([stored])

        let resolved = try await store.message(id: stored.id)
        XCTAssertEqual(resolved?.id, stored.id)
        XCTAssertEqual(stored.rowKey, .stored(stored.id))
        for raw: UInt64 in [1, 0x18a0_0000_0000_0001, UInt64.max] {
            let key = RowKey.gmail(account: account.id, id: GmailMessageID(raw: raw))
            let found = try await store.message(id: key.stringValue)
            XCTAssertNil(found, key.stringValue)
        }

        var google = stored
        google.id = RowKey.gmail(account: account.id, id: GmailMessageID(raw: 7)).stringValue
        XCTAssertEqual(google.rowKey, .gmail(account: account.id, id: GmailMessageID(raw: 7)))
    }

    // MARK: - Files an earlier build wrote, and reads

    /// The keys v1.10.0 writes for a summary, in its JSON journal and binary plist snapshots.
    private static let v1_10SummaryKeys: Set<String> = [
        "id", "accountID", "folderID", "uid", "messageID", "inReplyTo", "references", "subject", "from", "to", "cc", "date",
        "isRead", "isFlagged", "isAnswered", "isDraft", "size", "snippet", "hasAttachments", "hasBody", "threadKey"
    ]

    private static let v1_10Summary = """
    {"accountID":"8C1F5A7E-6D55-4C71-9D0E-2B7C1A9F0E11","cc":[],"date":780000000,\
    "folderID":"0B9A6C3D-1E2F-4A5B-8C7D-9E0F1A2B3C4D","from":{"address":"ana@example.com","name":"Ana"},"hasAttachments":false,\
    "hasBody":true,"id":"8C1F5A7E-6D55-4C71-9D0E-2B7C1A9F0E11:0B9A6C3D-1E2F-4A5B-8C7D-9E0F1A2B3C4D:42","inReplyTo":"",\
    "isAnswered":false,"isDraft":false,"isFlagged":true,"isRead":false,"messageID":"<m1@example.com>","references":[],\
    "size":1234,"snippet":"Hello","subject":"Invoice","threadKey":"t1","to":[{"address":"owner@example.com","name":""}],"uid":42}
    """

    func testASummaryV1_10WroteReadsAndIsWrittenBackTheSame() throws {
        let decoded = try JSONDecoder().decode(MessageSummary.self, from: Data(Self.v1_10Summary.utf8))
        XCTAssertNil(decoded.gmailID)
        XCTAssertNil(decoded.gmailThreadID)
        XCTAssertNil(decoded.labelIDs)
        XCTAssertNil(decoded.internalDate)
        XCTAssertNil(decoded.bcc)
        XCTAssertNil(decoded.replyTo)
        XCTAssertEqual(decoded.uid, 42)
        XCTAssertTrue(decoded.isFlagged)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(String(decoding: try encoder.encode(decoded), as: UTF8.self), Self.v1_10Summary)

        let plist = try PropertyListEncoder().encode([decoded])
        XCTAssertEqual(try PropertyListDecoder().decode([MessageSummary].self, from: plist), [decoded])
        let keys = try XCTUnwrap((try PropertyListSerialization.propertyList(from: plist, format: nil) as? [[String: Any]])?.first?.keys)
        XCTAssertEqual(Set(keys), Self.v1_10SummaryKeys, "a summary without Gmail fields writes exactly what v1.10.0 wrote")
    }

    func testAGoogleSummaryStillReadsInAnEarlierBuild() throws {
        var summary = try JSONDecoder().decode(MessageSummary.self, from: Data(Self.v1_10Summary.utf8))
        summary.gmailID = GmailMessageID(raw: 0x18a0_0000_0000_0001)
        summary.gmailThreadID = GmailThreadID(raw: 0x18a0_0000_0000_0002)
        summary.labelIDs = [.inbox, "Label_7"]
        summary.internalDate = Date(timeIntervalSince1970: 1_790_000_000)
        summary.bcc = [EmailAddress(address: "hidden@example.com")]
        summary.replyTo = [EmailAddress(name: "Desk", address: "desk@example.com")]
        let data = try JSONEncoder().encode(summary)
        XCTAssertEqual(try JSONDecoder().decode(MessageSummary.self, from: data), summary)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["gmailID"] as? String, "18a0000000000001")
        XCTAssertEqual(object["labelIDs"] as? [String], ["INBOX", "Label_7"])

        // v1.10.0's decoder knows only its own keys and skips the rest.
        let earlier = try JSONDecoder().decode(EarlierSummary.self, from: data)
        XCTAssertEqual(earlier.id, summary.id)
        XCTAssertEqual(earlier.subject, "Invoice")
    }

    func testAFolderV1_10WroteReadsAndIsWrittenBackTheSame() throws {
        let folder = FolderInfo(accountID: UUID(), path: "[Gmail]/Sent Mail", name: "Sent Mail", delimiter: "/", role: .sent,
                                attributes: ["\\Sent"], isSelectable: true)
        let data = try JSONEncoder().encode(folder)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["id", "accountID", "path", "name", "delimiter", "role", "attributes", "isSelectable",
                                          "uidValidity", "uidNext", "lastSyncedUID", "oldestSyncedUID", "totalCount", "unreadCount"])
        XCTAssertNil(try JSONDecoder().decode(FolderInfo.self, from: data).gmailLabelID)

        var google = folder
        google.gmailLabelID = .sent
        let written = try JSONEncoder().encode(google)
        XCTAssertEqual(try JSONDecoder().decode(FolderInfo.self, from: written).gmailLabelID, .sent)
        XCTAssertEqual(try JSONDecoder().decode(EarlierFolder.self, from: written).path, "[Gmail]/Sent Mail")
    }
}

/// The summary fields v1.10.0 decodes, standing in for its own type.
private struct EarlierSummary: Decodable {
    var id: String
    var accountID: UUID
    var folderID: UUID
    var uid: UInt32
    var subject: String
    var from: EmailAddress
    var date: Date
    var isRead: Bool
    var threadKey: String
}

private struct EarlierFolder: Decodable {
    var id: UUID
    var path: String
    var role: FolderRole
    var uidValidity: UInt32
}
