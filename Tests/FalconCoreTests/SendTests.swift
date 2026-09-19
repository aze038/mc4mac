import XCTest
@testable import FalconCore

final class SendTests: XCTestCase {
    private let keywords = AttachmentReminder.keywords(from: "attached, attachment, attachments, enclosed, see attached, please find, anbei, вложении, ekte, əlavə edirəm")

    private let history = "\n" + AttachmentReminder.separatorLine + """

        From: Ana <ana@example.com>
        Sent: Monday, 5 May 2025 at 09:14
        To: kamran@example.com
        Subject: Quarterly report

        The report is attached.

        """

    private let signature = "-- \nKamran\nEnclosed Systems Ltd\n\n"

    func testKeywordsFromList() {
        let parsed = AttachmentReminder.keywords(from: " Attached , ,enclosed,\nsee attached ,ATTACHED ")
        XCTAssertEqual(parsed, ["attached", "enclosed", "see attached"])
        XCTAssertTrue(AttachmentReminder.keywords(from: "  ,  ").isEmpty)
    }

    func testQuotedHistoryAloneDoesNotFire() {
        let body = "\n\nThanks, I will read it tonight.\n" + signature + history
        XCTAssertFalse(AttachmentReminder.mentionsAttachment(subject: "Re: Quarterly report", body: body,
                                                            historyPlain: history, keywords: keywords))
    }

    func testTypingAboveTheHistoryFires() {
        let body = "\n\nMy notes are attached.\n" + signature + history
        XCTAssertTrue(AttachmentReminder.mentionsAttachment(subject: "Re: Quarterly report", body: body,
                                                           historyPlain: history, keywords: keywords))
    }

    func testSignatureAloneDoesNotFire() {
        let body = "\n\nThanks, I will read it tonight.\n" + signature
        XCTAssertFalse(AttachmentReminder.mentionsAttachment(subject: "Re: Quarterly report", body: body,
                                                            historyPlain: "", keywords: keywords))
    }

    func testKeywordInsideLongerWordDoesNotFire() {
        let body = "\n\nThe rider stayed unattached to any team this season.\n"
        XCTAssertFalse(AttachmentReminder.mentionsAttachment(subject: "Cycling", body: body,
                                                            historyPlain: "", keywords: keywords))
    }

    func testSubjectIsChecked() {
        XCTAssertTrue(AttachmentReminder.mentionsAttachment(subject: "Invoice enclosed", body: "\n\nHello\n",
                                                           historyPlain: "", keywords: keywords))
    }

    func testPhraseMatchesAcrossALineBreak() {
        XCTAssertTrue(AttachmentReminder.mentionsAttachment(subject: "Numbers", body: "\n\nPlease\nfind the numbers below.\n",
                                                           historyPlain: "", keywords: keywords))
    }

    func testOtherLanguagesFire() {
        for body in ["\n\nDen Bericht findest du anbei.\n", "\n\nОтчёт во вложении.\n", "\n\nRapor ekte.\n", "\n\nHesabatı əlavə edirəm.\n"] {
            XCTAssertTrue(AttachmentReminder.mentionsAttachment(subject: "", body: body, historyPlain: "", keywords: keywords), body)
        }
    }

    func testEmptyKeywordListNeverFires() {
        XCTAssertFalse(AttachmentReminder.mentionsAttachment(subject: "attached", body: "attached", historyPlain: "", keywords: []))
    }

    func testUserTextStopsAtTheSeparatorWhenHistoryIsNotASuffix() {
        let body = "\n\nMine.\n" + signature + history + "\nA stray line below the quote.\n"
        XCTAssertEqual(AttachmentReminder.userText(body: body, historyPlain: history), "\n\nMine.")
    }

    func testUserTextStopsAtAReplyAttributionAndAtQuoteMarkers() {
        let attribution = "\n\nOK.\n\nOn Monday, Ana <ana@example.com> wrote:\n> it is attached\n"
        XCTAssertEqual(AttachmentReminder.userText(body: attribution, historyPlain: ""), "\n\nOK.\n")
        let quoted = "\n\nOK.\n> it is attached\n"
        XCTAssertEqual(AttachmentReminder.userText(body: quoted, historyPlain: ""), "\n\nOK.")
    }

    func testCancelReportsWhetherItCancelled() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let outbox = Outbox(layout: FileLayout(root: tmp), sender: SilentSender())
        let item = try await outbox.enqueue(accountID: UUID(), from: "me@example.com", message: SendTests.outgoing(),
                                            sendAt: Date().addingTimeInterval(3600))
        let first = try await outbox.cancel(item.id)
        let second = try await outbox.cancel(item.id)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }

    func testRemoveDeletesTheDraftSidecar() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let layout = FileLayout(root: tmp)
        let outbox = Outbox(layout: layout, sender: SilentSender())
        let item = try await outbox.enqueue(accountID: UUID(), from: "me@example.com", message: SendTests.outgoing(),
                                            sendAt: Date().addingTimeInterval(3600))
        let sidecar = Outbox.draftSidecarURL(directory: layout.outboxDirectory, id: item.id)
        try Data("{}".utf8).write(to: sidecar)
        let raw = await outbox.rawMessage(for: item.id)
        XCTAssertNotNil(raw)
        await outbox.remove(item.id)
        let remaining = await outbox.snapshot()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
    }

    func testScheduledMessageIsNotSendingSoon() {
        var item = OutboxItem(accountID: UUID(), subject: "Tomorrow", recipients: ["ana@example.com"],
                              sender: "me@example.com", sendAt: Date().addingTimeInterval(86_400), undoWindow: 10)
        XCTAssertTrue(item.canUndo)
        XCTAssertFalse(item.isSendingSoon(within: 10))
        item.sendAt = Date().addingTimeInterval(5)
        XCTAssertTrue(item.isSendingSoon(within: 10))
        item.status = .sending
        XCTAssertFalse(item.isSendingSoon(within: 10))
    }

    static func outgoing() -> OutgoingMessage {
        OutgoingMessage(from: EmailAddress(name: "Me", address: "me@example.com"),
                        to: [EmailAddress(name: "Ana", address: "ana@example.com")],
                        subject: "Quarterly report", textBody: "The numbers are attached.")
    }
}

private struct SilentSender: MessageSender {
    func send(accountID: UUID, from: String, recipients: [String], message: Data) async throws {
        throw FalconError.protocolError("no delivery in tests")
    }
}
