import XCTest
@testable import FalconCore

/// G1's probe, run here only against the fake Gmail: it finds what it is meant to find, refuses
/// any account but the test account, writes nothing without approval, and leaves nothing behind.
final class GmailProbeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Log.isEnabled = false
    }

    override func tearDown() {
        Log.isEnabled = true
        super.tearDown()
    }

    private let testAccount = "probe-test@example.com"

    /// A small mailbox with what each question needs: attachments, inline pictures, a labelled
    /// message in Deleted Items, a chat, and mail over some hours.
    private func mailbox() -> FakeGmailMailbox {
        let mailbox = FakeGmailMailbox(email: testAccount)
        let label = mailbox.addUserLabel(named: "Clients")
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        for i in 0..<30 {
            let pictures = (0..<(i % 3)).map { FakeGmailMailbox.Attachment(filename: "logo\($0).png", mimeType: "image/png",
                                                                             data: Data(repeating: 1, count: 100), contentID: "logo\($0)") }
            let files = i % 7 == 0 ? [FakeGmailMailbox.Attachment(filename: "quote.pdf", mimeType: "application/pdf", data: Data(count: 500))] : []
            mailbox.add(subject: "Message \(i)", labels: i % 4 == 0 ? ["INBOX", label] : ["INBOX"],
                        date: base.addingTimeInterval(TimeInterval(-i * 97)), attachments: pictures + files)
        }
        mailbox.add(subject: "Deleted", labels: ["TRASH", label], date: base.addingTimeInterval(-10_000))
        mailbox.add(subject: "Chat", labels: ["CHAT"], date: base.addingTimeInterval(-20_000))
        return mailbox
    }

    func testTheReadOnlyPartFindsWhatItLooksForAndChangesNothing() async throws {
        let mailbox = mailbox()
        let before = mailbox.messages.map { ($0.id, $0.labels) }
        let transport = GmailTestKit.transport(mailbox)
        let report = try await GmailProbe(transport: transport, testAccount: testAccount).run()
        XCTAssertEqual(report.snippetWithMetadata, true)
        XCTAssertEqual(report.snippetWithThreads, true)
        XCTAssertEqual(report.listNewestFirst, true)
        XCTAssertEqual(report.listNewestFirstWithLabel, true)
        XCTAssertEqual(report.beforeEpochMatchesInternalDate, true)
        XCTAssertEqual(report.messageAddedCarriesLabels, true)
        XCTAssertEqual(report.attachmentIDsStable, true)
        XCTAssertEqual(report.earlierAttachmentIDWorks, true)
        XCTAssertNotNil(report.attachmentIDAgeSeconds)
        XCTAssertEqual(report.batchAddress.map { URL(string: $0)?.path }, "/batch/gmail/v1")
        XCTAssertEqual(report.batchAddressesRefused, [])
        XCTAssertEqual(report.labelTotalsCountJunkAndDeleted, true)
        XCTAssertEqual(report.profileTotalCountsJunkAndDeleted, true)
        XCTAssertEqual(report.listReturnsChats, false)
        XCTAssertEqual(report.inlinePictures, [0: 10, 1: 10, 2: 10])
        XCTAssertEqual(report.listPage?.samples, 5)
        XCTAssertEqual(report.metadataBatchOf25?.samples, 4)
        XCTAssertEqual(report.fullMessage?.samples, 10)
        XCTAssertEqual(report.historyPage?.samples, 5)
        XCTAssertFalse(report.writesRan)
        XCTAssertNil(report.cleanedUp)
        XCTAssertGreaterThan(report.units, 0)
        XCTAssertLessThan(report.units, 6_000, "the probe keeps its cost to about two minutes of one account's budget")
        let after = mailbox.messages.map { ($0.id, $0.labels) }
        XCTAssertEqual(after.map(\.0), before.map(\.0))
        XCTAssertEqual(after.map(\.1), before.map(\.1))
        for method in GmailMethod.allCases where method.direction != .download {
            XCTAssertNil(mailbox.attempts[method], "the read-only part made no \(method.rawValue) call")
        }
    }

    func testWhatItFindsFollowsWhatGmailDoes() async throws {
        let mailbox = mailbox()
        mailbox.historyAddedCarriesLabels = false
        mailbox.labelCountsIncludeSpamTrash = false
        mailbox.profileCountsSpamTrash = false
        mailbox.listReturnsChats = true
        mailbox.snippetInMetadata = false
        mailbox.acceptedBatchPaths = ["/batch"]
        let transport = GmailTestKit.transport(mailbox)
        let report = try await GmailProbe(transport: transport, testAccount: testAccount).run()
        XCTAssertEqual(report.messageAddedCarriesLabels, false)
        XCTAssertEqual(report.labelTotalsCountJunkAndDeleted, false)
        XCTAssertEqual(report.profileTotalCountsJunkAndDeleted, false)
        XCTAssertEqual(report.listReturnsChats, true)
        XCTAssertEqual(report.snippetWithMetadata, false)
        XCTAssertEqual(report.batchAddress.map { URL(string: $0)?.path }, "/batch")
        XCTAssertEqual(report.batchAddressesRefused.map { URL(string: $0)?.path }, ["/batch/gmail/v1"])
    }

    func testItRefusesAnyAccountButTheTestAccount() async throws {
        let mailbox = FakeGmailMailbox(email: "someone.else@example.com")
        mailbox.add(subject: "Not the probe's")
        let transport = GmailTestKit.transport(mailbox)
        do {
            _ = try await GmailProbe(transport: transport, testAccount: testAccount, writesApproved: true).run()
            XCTFail("another account")
        } catch let refusal as GmailProbe.Refusal {
            XCTAssertEqual(refusal, .notTheTestAccount)
        }
        XCTAssertEqual(mailbox.attempts, [.profile: 1], "nothing else was asked of it")
    }

    func testTheWritePartRunsOnlyWithApprovalOnItsOwnMessagesAndCleansUp() async throws {
        let mailbox = mailbox()
        mailbox.replacesMessageIDOnSend = true
        let before = mailbox.messages.map { ($0.id, $0.labels) }
        let labelsBefore = mailbox.userLabels
        let transport = GmailTestKit.transport(mailbox)
        let report = try await GmailProbe(transport: transport, testAccount: testAccount, writesApproved: true).run()
        XCTAssertTrue(report.writesRan)
        XCTAssertEqual(report.batchModifyTrashMatchesTrash, true)
        XCTAssertEqual(report.sendKeepsMessageID, false, "the fake replaced it, as some reports say Gmail does")
        XCTAssertEqual(report.sendKeepsAttemptHeader, true)
        XCTAssertEqual(report.draftKeepsMessageID, true)
        XCTAssertEqual(report.draftKeepsDraftHeader, true)
        XCTAssertEqual(report.cleanedUp, true)
        let after = mailbox.messages.map { ($0.id, $0.labels) }
        XCTAssertEqual(after.map(\.0), before.map(\.0), "everything it made is gone, and nothing else")
        XCTAssertEqual(after.map(\.1), before.map(\.1), "no existing message was touched")
        XCTAssertEqual(mailbox.userLabels, labelsBefore, "its label is gone too")
        XCTAssertTrue(mailbox.draftIDs.isEmpty)
        XCTAssertEqual(mailbox.calls[.messagesSend], 1)
        XCTAssertEqual(mailbox.sentUploads.first.map { MIMEParser.parse($0).to.map(\.address) }, [testAccount], "sent to itself only")
    }

    func testTheInlinePictureCountReadsNestedParts() {
        func part(_ type: String, cid: Bool = false, _ children: [GmailPart] = []) -> GmailPart {
            GmailPart(partId: nil, mimeType: type, filename: nil,
                      headers: cid ? [GmailHeader(name: "Content-ID", value: "<a>")] : [], body: nil, parts: children)
        }
        let message = part("multipart/mixed", [part("multipart/related", [part("text/html"), part("image/png", cid: true),
                                                                          part("image/gif", cid: true)]),
                                               part("image/jpeg")])
        XCTAssertEqual(GmailProbe.inlinePictureCount(message), 2, "an attached picture without a Content-ID is not inline")
    }
}
