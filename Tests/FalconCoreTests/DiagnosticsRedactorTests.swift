import XCTest
@testable import FalconCore

final class DiagnosticsRedactorTests: XCTestCase {
    private let salt = Data((0..<32).map { UInt8($0) })
    private lazy var redactor = DiagnosticsRedactor(salt: salt, homePath: "/Users/kmuradoff",
                                                    serverHosts: ["mail.your-server.de", "192.168.1.10"])

    private func assertClean(_ input: String, lacks secrets: [String], keeps kept: [String] = [],
                             file: StaticString = #filePath, line: UInt = #line) {
        let out = redactor.redact(input)
        for secret in secrets {
            XCTAssertFalse(out.localizedCaseInsensitiveContains(secret), "“\(secret)” survived in: \(out)", file: file, line: line)
        }
        for k in kept {
            XCTAssertTrue(out.contains(k), "“\(k)” was lost from: \(out)", file: file, line: line)
        }
    }

    // MARK: References

    func testReferencesAreStableShortAndSalted() {
        let ref = redactor.ref("Ana.Lima@Example.com")
        XCTAssertEqual(ref.count, 8)
        XCTAssertTrue(ref.allSatisfy(\.isHexDigit))
        XCTAssertEqual(ref, redactor.ref("ana.lima@example.com"), "lower-cased before hashing")
        let other = DiagnosticsRedactor(salt: Data(repeating: 7, count: 32))
        XCTAssertNotEqual(ref, other.ref("ana.lima@example.com"), "another install cannot match it")
    }

    // MARK: Addresses and names

    func testAddressInAngleBracketsWithQuotedName() {
        let out = redactor.redact(#"From: "Lima, Ana" <ana.lima@example.com>"#)
        XCTAssertEqual(out, "From: <addr:\(redactor.ref("ana.lima@example.com"))>")
    }

    func testUnquotedNameInHeaderAndList() {
        assertClean(#"To: Ana Lima <ana@example.com>, "Bob, Jr." <bob@example.org>, carol@example.net"#,
                    lacks: ["Ana", "Lima", "Bob", "Jr.", "carol", "example"], keeps: ["To:", "<addr:"])
    }

    func testNameBeforeAddressInASentenceKeepsTheSentence() {
        let out = redactor.redact("Could not reach Ana Lima <ana@example.com> today")
        XCTAssertEqual(out, "Could not reach <addr:\(redactor.ref("ana@example.com"))> today")
    }

    func testBareAddressesIncludingPlusTagsAndSubdomains() {
        assertClean("Recipient user+billing@sub.domain.co.uk rejected: 550 5.1.1 does not exist",
                    lacks: ["user+billing", "sub.domain"], keeps: ["550 5.1.1", "rejected", "<addr:"])
    }

    func testInternationalAddresses() {
        for address in ["josé@bücher.de", "用户@例子.广告", "почта@пример.рф", "ÄÖÜ@xn--bcher-kva.example", "δοκιμή@παράδειγμα.δοκιμή"] {
            let out = redactor.redact("Sending to \(address) failed")
            XCTAssertEqual(out, "Sending to \(redactor.addressRef(address)) failed", address)
        }
    }

    func testQuotedLocalPartAndSpacesInsideBrackets() {
        assertClean(#"bounce for "john doe"@example.com and < ana@example.com >"#, lacks: ["john doe", "ana@", "example.com"])
    }

    func testMailtoLinkLosesItsSubject() {
        assertClean("Opened mailto:ana@example.com?subject=Merger%20plans&body=Hi", lacks: ["ana@", "Merger", "body=Hi"],
                    keeps: ["mailto:<addr:"])
    }

    // MARK: Secrets

    func testAuthenticateXOAuth2Blob() {
        let blob = Data("user=ana@example.com\u{01}auth=Bearer ya29.a0AfH6SMBsecret\u{01}\u{01}".utf8).base64EncodedString()
        let out = redactor.redact("F0002 AUTHENTICATE XOAUTH2 \(blob)")
        XCTAssertEqual(out, "F0002 AUTHENTICATE XOAUTH2 <redacted>")
    }

    func testDecodedXOAuth2String() {
        let out = redactor.redact("user=ana@example.com\u{01}auth=Bearer ya29.a0AfH6SMBxxxYYYzzz\u{01}\u{01}")
        XCTAssertFalse(out.contains("ya29"))
        XCTAssertFalse(out.contains("ana@"))
        XCTAssertTrue(out.contains("auth=Bearer <token>"))
        XCTAssertTrue(out.contains("user=<addr:\(redactor.ref("ana@example.com"))>"))
        let username = redactor.redact("user=kmuradoff\u{01}auth=Bearer abc.def-ghi\u{01}\u{01}")
        XCTAssertFalse(username.contains("kmuradoff"))
    }

    func testLoginAndPlainAuthentication() {
        assertClean(#"F0003 LOGIN "ana@example.com" "hunter2 and more""#, lacks: ["hunter2", "ana@"], keeps: ["LOGIN <redacted>"])
        assertClean("F0003 LOGIN ana secret-pass", lacks: ["secret-pass"], keeps: ["LOGIN <redacted>"])
        assertClean("AUTH PLAIN AGFuYUBleGFtcGxlLmNvbQBodW50ZXIy", lacks: ["AGFuYUBl"], keeps: ["AUTH PLAIN <redacted>"])
    }

    func testBearerTokensJWTsAndGoogleSecrets() {
        assertClean("Authorization: Bearer ya29.a0AfH6SMBsecret", lacks: ["ya29", "a0AfH6"])
        assertClean("sent Bearer eyJhbGciOiJSUzI1NiIsImtpZCI6IjEifQ.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcDEF123_-",
                    lacks: ["eyJhbGci", "abcDEF123"], keeps: ["Bearer <token>"])
        assertClean("client GOCSPX-9x8y7zAbCdEf refused", lacks: ["GOCSPX", "9x8y7z"], keeps: ["<secret>"])
        assertClean("refresh 1//0gAbCdEfGhIjKlMnOpQr failed", lacks: ["1//0g", "AbCdEf"])
        assertClean("token ghp_abcdefghijklmnopqrstuvwxyz0123 used", lacks: ["ghp_abc"])
    }

    func testSecretsInJSONAndKeyValues() {
        let body = #"{"access_token": "ya29.xyz", "refresh_token":"1//abc", "error":"invalid_grant","error_description":"Token has been expired or revoked."}"#
        assertClean(body, lacks: ["ya29", "1//abc", "Token has been"], keeps: ["invalid_grant", "error_description"])
        assertClean("password=hunter2&user=x", lacks: ["hunter2"])
        assertClean("client_secret: GOCSPX-abc access_token=ya29.q", lacks: ["GOCSPX", "ya29"])
        assertClean(#"{"password": "hunter2"}"#, lacks: ["hunter2"])
    }

    func testLongBase64BlobsGoButSymbolsStay() {
        assertClean("payload dXNlcj1hbmFAZXhhbXBsZS5jb20BYXV0aD1CZWFyZXIgeWEy end", lacks: ["dXNlcj1h"], keeps: ["<base64>", "end"])
        let symbol = "$s10FalconMail8AppModelC9bootstrapyyYaFTY0_"
        XCTAssertEqual(redactor.redact(symbol), symbol)
        XCTAssertEqual(redactor.redact("-[NSApplication run]"), "-[NSApplication run]")
    }

    // MARK: URLs and paths

    func testURLsLoseQueryStringsAndCredentials() {
        let out = redactor.redact("POST https://oauth2.googleapis.com/token?code=4/0AX4XfWh&client_secret=GOCSPX-abc123&refresh_token=1//0gabc failed")
        XCTAssertEqual(out, "POST https://oauth2.googleapis.com/token failed")
        XCTAssertEqual(redactor.redact("https://user:pass@example.com/path?x=1#frag"), "https://example.com/path")
        XCTAssertEqual(redactor.redact("see https://support.google.com/mail/accounts/answer/78754 (Failure)"),
                       "see https://support.google.com/mail/accounts/answer/78754 (Failure)")
    }

    func testHomePathBecomesTilde() {
        XCTAssertEqual(redactor.redact("/Users/kmuradoff/Library/Application Support/FalconMail/queue.jsonl"),
                       "~/Library/Application Support/FalconMail/queue.jsonl")
        assertClean("file:///Users/kmuradoff/Downloads/report.pdf", lacks: ["kmuradoff"], keeps: ["~/Downloads"])
        assertClean("opened /Users/someone.else/Desktop/x", lacks: ["someone"], keeps: ["~/Desktop/x"])
        XCTAssertEqual(redactor.redact("/Users/Shared/FalconMail"), "/Users/Shared/FalconMail")
        XCTAssertFalse(redactor.redact("/Users/kmuradoffx/y").contains("kmuradoffx"))
    }

    // MARK: IMAP

    func testLiteralsAreStrippedWhateverTheyHold() {
        let out = redactor.redact("* 12 FETCH (UID 4711 BODY[TEXT] {15}\r\nsecret contents)")
        XCTAssertFalse(out.contains("secret contents"))
        XCTAssertTrue(out.contains("{15}<literal>"))
        XCTAssertTrue(out.contains("4711"), "numbers stay in messages")
    }

    func testSubjectsInFetchResponses() {
        assertClean("* 12 FETCH (UID 4711 BODY[HEADER.FIELDS (SUBJECT)] {28}\r\nSubject: Quarterly figures\r\n\r\n)",
                    lacks: ["Quarterly"])
        assertClean(#"* 3 FETCH (UID 99 ENVELOPE ("Mon, 1 Jan 2024" "Secret merger plans" (("Ana" NIL "ana" "example.com")) NIL))"#,
                    lacks: ["Secret merger", "Ana", "example.com"], keeps: ["FETCH", "ENVELOPE"])
        assertClean("Subject: =?UTF-8?B?0J/RgNC40LLQtdGC?=", lacks: ["0J/RgNC4"])
        assertClean("Thanks =?UTF-8?Q?Caf=C3=A9_menu?= was sent", lacks: ["Caf=C3"], keeps: ["<text>"])
    }

    func testSearchCriteria() {
        assertClean(#"F0010 UID SEARCH SUBJECT "board meeting" FROM ceo X-GM-RAW "has:attachment invoice""#,
                    lacks: ["board meeting", "ceo", "invoice"], keeps: ["SEARCH SUBJECT"])
        assertClean("F0011 UID SEARCH HEADER Message-ID <abc123@mail.example.com>", lacks: ["abc123", "mail.example"])
    }

    func testMailboxNames() {
        let out = redactor.redact(#"F0005 SELECT "Clients/ACME Corp""#)
        XCTAssertEqual(out, "F0005 SELECT \"\(redactor.label("Clients/ACME Corp"))\"")
        XCTAssertEqual(redactor.redact(#"F0005 SELECT "[Gmail]/All Mail""#), #"F0005 SELECT "[Gmail]/All Mail""#)
        XCTAssertEqual(redactor.redact("F0006 SELECT INBOX"), "F0006 SELECT INBOX")
        assertClean("F0007 UID MOVE 1:5 Projects", lacks: ["Projects"], keeps: ["<label:"])
        assertClean(#"* LIST (\HasNoChildren) "/" "Family Photos""#, lacks: ["Family"], keeps: [#""/""#])
        assertClean(#"F0008 APPEND "Clients" (\Seen) {1234}"#, lacks: ["Clients"])
        assertClean(#"* 1 FETCH (X-GM-LABELS (\Inbox Clients "Very Secret"))"#, lacks: ["Clients", "Very Secret"], keeps: ["\\Inbox"])
    }

    func testKnownFolderNamesInFreeText() {
        var r = redactor
        r.labels = ["Clients/ACME", "Projects", "Inbox", "ab"]
        let out = r.redact("[TRYCREATE] Mailbox Clients/ACME does not exist; Projects moved; Myprojects kept; Inbox kept")
        XCTAssertFalse(out.contains("ACME"))
        XCTAssertFalse(out.contains(" Projects"))
        XCTAssertTrue(out.contains("Myprojects"))
        XCTAssertTrue(out.contains("Inbox kept"))
    }

    // MARK: Quoted text, IP addresses, numbers

    func testQuotedTextAndFileNames() {
        assertClean("The file “Invoice ACME 2024.pdf” couldn’t be opened because it isn’t there",
                    lacks: ["Invoice", "ACME"], keeps: ["couldn’t be opened", "isn’t there"])
        assertClean(#"Could not save "Lunch with Ana" to Drafts"#, lacks: ["Lunch", "Ana"], keeps: ["Drafts"])
    }

    func testClientIPsGoServerAddressesStay() {
        assertClean("250-smtp.gmail.com at your service, [203.0.113.45]", lacks: ["203.0.113.45"], keeps: ["smtp.gmail.com", "<ip>"])
        assertClean("connecting to 192.168.1.10:993 (mail.your-server.de)", lacks: [], keeps: ["192.168.1.10", "mail.your-server.de"])
        assertClean("from 2001:db8::ff00:42:8329 denied", lacks: ["2001:db8"], keeps: ["<ip>"])
        XCTAssertEqual(redactor.redact("at 10:11:12 on 2026-09-24"), "at 10:11:12 on 2026-09-24")
        XCTAssertEqual(redactor.redact("Reply 550 5.1.1 after 3 attempts, 42 bytes"), "Reply 550 5.1.1 after 3 attempts, 42 bytes")
    }

    // MARK: Whole values

    func testRedactionIsIdempotent() {
        let inputs = [#"From: "Lima, Ana" <ana.lima@example.com>"#, "F0002 AUTHENTICATE XOAUTH2 dXNlcj1hbmFAZXhhbXBsZS5jb20BYXV0aD1CZWFyZXI=",
                      #"F0005 SELECT "Clients""#, "/Users/kmuradoff/x", "user@host.example.com"]
        for input in inputs {
            let once = redactor.redact(input)
            XCTAssertEqual(redactor.redact(once), once, input)
        }
    }

    func testJSONValuesAreRedactedThroughout() {
        let value = JSONValue.object([
            "procPath": .string("/Users/kmuradoff/Applications/FalconMail.app/Contents/MacOS/FalconMail"),
            "asi": .object(["libswiftCore.dylib": .array([.string("Fatal error: no account for ana@example.com")])]),
            "frames": .array([.object(["imageOffset": .int(123), "symbol": .string("AppModel.bootstrap()")])]),
            "ana@example.com": .bool(true),
        ])
        let text = String(decoding: redactor.redact(value).serialised, as: UTF8.self)
        XCTAssertFalse(text.contains("kmuradoff"))
        XCTAssertFalse(text.contains("ana@"))
        XCTAssertTrue(text.contains("AppModel.bootstrap()"))
        XCTAssertTrue(text.contains("\"imageOffset\":123"))
    }

    func testStandardMailboxes() {
        for name in ["INBOX", "Sent", "[Gmail]/Sent Mail", "[Gmail]/All Mail", "Junk", "Spam", "Trash", "Archive",
                     "Drafts", "Starred", "Important", "INBOX.Sent", "Deleted Items"] {
            XCTAssertTrue(DiagnosticsRedactor.isStandardMailbox(name), name)
        }
        for name in ["Clients", "[Gmail]/Clients", "Receipts 2024", "INBOX.Clients"] {
            XCTAssertFalse(DiagnosticsRedactor.isStandardMailbox(name), name)
        }
    }
}
