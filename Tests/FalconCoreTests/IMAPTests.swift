import XCTest
@testable import FalconCore

final class IMAPTests: XCTestCase {
    func testTokenizerWithLiteralAndBrackets() throws {
        let parts: [IMAPRawPart] = [
            .text("* 12 FETCH (UID 345 FLAGS (\\Seen \\Flagged) RFC822.SIZE 1234 BODY[HEADER.FIELDS (From Subject)] {19}"),
            .literal(Data("From: a@b\r\nSubject:".utf8)),
            .text(")")
        ]
        let response = try IMAPResponseParser.parse(parts)
        guard case .fetch(let item) = response else { return XCTFail("expected fetch") }
        XCTAssertEqual(item.sequence, 12)
        XCTAssertEqual(item.uid, 345)
        XCTAssertEqual(item.flags, ["\\Seen", "\\Flagged"])
        XCTAssertEqual(item.size, 1234)
        XCTAssertEqual(item.headerSection, Data("From: a@b\r\nSubject:".utf8))
    }

    func testListResponse() throws {
        let r = try IMAPResponseParser.parse([.text("* LIST (\\HasNoChildren \\Sent) \"/\" \"[Gmail]/Sent Mail\"")])
        guard case .list(let f) = r else { return XCTFail("expected list") }
        XCTAssertEqual(f.path, "[Gmail]/Sent Mail")
        XCTAssertEqual(f.displayName, "Sent Mail")
        XCTAssertEqual(f.role, .sent)
        XCTAssertTrue(f.isSelectable)
    }

    func testStatusResponses() throws {
        let r = try IMAPResponseParser.parse([.text("* OK [UIDVALIDITY 1234] UIDs valid")])
        guard case .untaggedStatus(let status, let code, let text) = r else { return XCTFail() }
        XCTAssertEqual(status, .ok)
        XCTAssertEqual(code, "UIDVALIDITY 1234")
        XCTAssertEqual(text, "UIDs valid")
        let tagged = try IMAPResponseParser.parse([.text("F0001 NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)")])
        guard case .tagged(let tag, let s2, _, _) = tagged else { return XCTFail() }
        XCTAssertEqual(tag, "F0001")
        XCTAssertEqual(s2, .no)
    }

    func testSearchAndExists() throws {
        if case .search(let uids) = try IMAPResponseParser.parse([.text("* SEARCH 4 5 99")]) { XCTAssertEqual(uids, [4, 5, 99]) } else { XCTFail() }
        if case .exists(let n) = try IMAPResponseParser.parse([.text("* 23 EXISTS")]) { XCTAssertEqual(n, 23) } else { XCTFail() }
    }

    func testSequenceSet() {
        XCTAssertEqual(IMAPClient.sequenceSet([1, 2, 3, 7, 9, 10]), "1:3,7,9:10")
        XCTAssertEqual(IMAPClient.sequenceSet([5]), "5")
    }

    func testTrailingLiteral() {
        XCTAssertEqual(IMAPClient.trailingLiteralSize("* 1 FETCH (BODY[] {4321}"), 4321)
        XCTAssertEqual(IMAPClient.trailingLiteralSize("F1 APPEND {12+}"), 12)
        XCTAssertNil(IMAPClient.trailingLiteralSize("* OK done"))
    }

    func testModifiedUTF7() {
        XCTAssertEqual(ModifiedUTF7.decode("&AOk-l&AOk-ments"), "éléments")
        XCTAssertEqual(ModifiedUTF7.encode("éléments"), "&AOk-l&AOk-ments")
        XCTAssertEqual(ModifiedUTF7.decode("Tom &- Jerry"), "Tom & Jerry")
    }

    func testGoogleThrottleIsRecognisedSoSyncWaitsInsteadOfHammering() {
        func kind(_ e: Error) -> MailServiceError.Kind { MailServiceError.classify(e, email: "owner@example.com", isGoogle: true).kind }
        XCTAssertEqual(kind(IMAPBye(code: nil, text: "Account exceeded command or bandwidth limits.")), .throttled)
        XCTAssertEqual(kind(IMAPServerError(status: .no, code: "THROTTLED", text: "Slow down (Failure)", command: "UID FETCH")), .throttled)
        XCTAssertEqual(kind(IMAPServerError(status: .no, code: "ALERT", text: "Too many simultaneous connections. (Failure)", command: "AUTHENTICATE")),
                       .tooManyConnections)
        XCTAssertEqual(kind(FalconError.network("connection closed by peer")), .connectionDropped)
        XCTAssertEqual(kind(FalconError.notAuthenticated), .needsSignIn)
    }
}
