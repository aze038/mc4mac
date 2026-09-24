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

    func testSurnameFirstBracketedAndLongNames() {
        let ana = "<addr:\(redactor.ref("ana@example.com"))>"
        XCTAssertEqual(redactor.redact("To: Lima, Ana <ana@example.com>"), "To: \(ana)")
        XCTAssertEqual(redactor.redact("Could not reach Lima, Ana <ana@example.com>"), "Could not reach \(ana)")
        XCTAssertEqual(redactor.redact("To: de la Cruz, Ana <ana@example.com>, bob@example.org"),
                       "To: \(ana), <addr:\(redactor.ref("bob@example.org"))>")
        XCTAssertEqual(redactor.redact("Delivery to ana@example.com (Ana Lima) failed"), "Delivery to \(ana) failed")
        XCTAssertEqual(redactor.redact("Delivery to <ana@example.com> (Ana Maria de la Cruz) failed"), "Delivery to \(ana) failed")
        XCTAssertEqual(redactor.redact("Dr. Ana Maria de la Cruz Lima <ana@example.com> bounced"), "\(ana) bounced")
        XCTAssertEqual(redactor.redact("Could not reach Ana Maria de la Cruz Lima <ana@example.com> today"), "Could not reach \(ana) today")
        XCTAssertEqual(redactor.redact("Rejected ana@example.com (550 5.1.1 user unknown)"), "Rejected \(ana) (550 5.1.1 user unknown)",
                       "a server's reason in brackets is not a name")
        XCTAssertEqual(redactor.redact("Could not deliver, Ana <ana@example.com>"), "Could not deliver, \(ana)")
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

    /// IMAP ignores case, so a lower-case LOGIN is a command too where it can only be one.
    func testLowerCaseLoginCommands() {
        assertClean("a1 login ana@example.com hunter2", lacks: ["hunter2", "ana@"], keeps: ["a1 login <redacted>"])
        assertClean("a1 login ana hunter2", lacks: ["hunter2"], keeps: ["a1 login <redacted>"])
        assertClean(#"sent login "ana" "hunter 2""#, lacks: ["hunter"], keeps: ["login <redacted>"])
        XCTAssertEqual(redactor.redact("Gmail login failed: invalid credentials"), "Gmail login failed: invalid credentials",
                       "a sentence about logging in is left alone")
        XCTAssertEqual(redactor.redact("a1 login <redacted>"), "a1 login <redacted>")
    }

    func testPasswordsWithSpacesAndShortKeys() {
        assertClean("Password: hunter 2 with spaces", lacks: ["hunter", "2 with spaces"], keeps: ["Password=<redacted>"])
        assertClean("password=hunter 2; user=ana", lacks: ["hunter", " 2"], keeps: ["password=<redacted>; user=ana"])
        assertClean("pass=hunter2&user=x", lacks: ["hunter2"], keeps: ["pass=<redacted>&user=x"])
        assertClean(#"{"pass": "hunter2"}"#, lacks: ["hunter2"])
        XCTAssertEqual(redactor.redact("Sync pass: 3 new messages, 12 passes today"), "Sync pass: 3 new messages, 12 passes today")
    }

    func testRequestLinesLoseTheirQueryStrings() {
        XCTAssertEqual(redactor.redact("GET /?code=4/0AX4XfWh&scope=https://mail.google.com/ HTTP/1.1"), "GET / HTTP/1.1")
        XCTAssertEqual(redactor.redact("POST /oauth2callback?state=abc&code=xyz HTTP/1.1"), "POST /oauth2callback HTTP/1.1")
        XCTAssertEqual(redactor.redact("GET /favicon.ico HTTP/1.1"), "GET /favicon.ico HTTP/1.1")
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

    /// A name such as HR or 2024 would take ordinary words and numbers with it anywhere else,
    /// so it goes where a server or FalconMail names a folder with it.
    func testShortFolderNamesGoWhereAFolderIsNamed() {
        var r = redactor
        r.labels = ["HR", "IT", "2024", "Payroll"]
        for (input, name) in [("Could not move: Protocol error: [TRYCREATE] No folder HR (Failure)", "HR"),
                              ("[NONEXISTENT] Unknown Mailbox: IT (now in authenticated state) (Failure)", "IT"),
                              ("[TRYCREATE] Mailbox doesn't exist: 2024", "2024"),
                              (#"Mailbox doesn't exist: "2024""#, "2024"),
                              ("Could not move to HR", "HR"),
                              ("Moved 3 messages into IT", "IT")] {
            let out = r.redact(input)
            XCTAssertEqual(out.components(separatedBy: r.label(name)).count, 2, "\(input) → \(out)")
        }
        XCTAssertEqual(r.redact("IT said HR will reply in 2024 after 3 attempts"), "IT said HR will reply in 2024 after 3 attempts",
                       "elsewhere they are ordinary words and numbers")
        XCTAssertEqual(r.redact("No folder HRM"), "No folder HRM")
        XCTAssertEqual(r.redact(r.redact("No folder HR")), r.redact("No folder HR"))
    }

    // MARK: Quoted text, IP addresses, numbers

    func testQuotedTextAndFileNames() {
        assertClean("The file “Invoice ACME 2024.pdf” couldn’t be opened because it isn’t there",
                    lacks: ["Invoice", "ACME"], keeps: ["couldn’t be opened", "isn’t there"])
        assertClean(#"Could not save "Lunch with Ana" to Drafts"#, lacks: ["Lunch", "Ana"], keeps: ["Drafts"])
    }

    /// macOS writes its file errors in the Mac's own language, with that language's quotation marks.
    func testFileNamesInOtherLanguagesQuotationMarks() {
        assertClean("Die Datei „Kündigung Ana Lima.eml“ konnte nicht geöffnet werden, da sie nicht existiert.",
                    lacks: ["Kündigung", "Ana", "Lima"], keeps: ["Die Datei „…“ konnte nicht geöffnet werden"])
        assertClean("Die Datei ‚Kündigung.eml‘ fehlt", lacks: ["Kündigung"], keeps: ["‚…‘ fehlt"])
        assertClean("Impossible d’ouvrir le fichier « Facture ACME.pdf » car il n’existe pas.",
                    lacks: ["Facture", "ACME"], keeps: ["Impossible d’ouvrir le fichier «…» car il n’existe pas."])
        assertClean("Не удалось открыть файл «Зарплата Иванов.xlsx», так как он не существует.",
                    lacks: ["Зарплата", "Иванов"], keeps: ["Не удалось открыть файл «…»"])
        assertClean("Filen ”Lön Ana.pdf” kunde inte öppnas.", lacks: ["Lön", "Ana"], keeps: ["kunde inte öppnas"])
        assertClean("Filen »Løn Ana.pdf« kunne ikke åbnes, og ›Bilag.pdf‹ heller ikke.", lacks: ["Løn", "Bilag"], keeps: ["kunne ikke åbnes"])
        assertClean("Datei ‹Notiz.txt› fehlt", lacks: ["Notiz"])
        assertClean("ファイル「請求書ACME.pdf」を開けませんでした。『議事録』も同様です。", lacks: ["請求書", "ACME", "議事録"],
                    keeps: ["を開けませんでした"])
        assertClean("לא ניתן לפתוח את הקובץ ״חשבונית ACME.pdf״ מכיוון שהוא לא קיים.", lacks: ["חשבונית", "ACME"],
                    keeps: ["לא ניתן לפתוח את הקובץ ״…״ מכיוון שהוא לא קיים."])
    }

    /// Hebrew writes the same mark inside abbreviations, דו״ח (report) and בע״מ (Ltd), where it
    /// neither opens nor closes a quotation, so a file named with one goes whole.
    func testHebrewGershayimInsideAWordNeitherOpensNorClosesAQuotation() {
        assertClean("לא ניתן לפתוח את הקובץ ״דו״ח שנתי ACME.pdf״ מכיוון שהוא לא קיים.", lacks: ["דו״ח", "שנתי", "ACME"],
                    keeps: ["לא ניתן לפתוח את הקובץ ״…״ מכיוון שהוא לא קיים."])
        assertClean("הקובץ ״חוזה בע״מ.pdf״ והקובץ ״דו״ח.xlsx״ חסרים", lacks: ["חוזה", "pdf", "xlsx"],
                    keeps: ["הקובץ ״…״ והקובץ ״…״ חסרים"])
        XCTAssertEqual(redactor.redact("שגיאה בדו״ח של בע״מ"), "שגיאה בדו״ח של בע״מ", "no quotation, nothing taken out")
    }

    /// Hebrew joins a one-letter word to the front of the next, and a quotation too: ב״…״ (in
    /// "…"), ל״…״ (to "…"), ה״…״ (the "…"). Such a quotation went whole once an in-word gershayim
    /// no longer opened one; a letter or two of those, standing alone, may come before it again.
    func testAHebrewQuotationWithALetterJoinedToItsFrontGoesWhole() {
        assertClean("שגיאה ב״Kamal Secret.pdf״", lacks: ["Kamal", "Secret"], keeps: ["שגיאה ב״…״"])
        assertClean("העברה ל״תיקיית Kamal Secret״ נכשלה", lacks: ["Kamal", "תיקיית"], keeps: ["העברה ל״…״ נכשלה"])
        assertClean("לא ניתן לפתוח את ה״דוח שנתי ACME.pdf״ כעת", lacks: ["ACME", "שנתי"], keeps: ["לא ניתן לפתוח את ה״…״ כעת"])
        assertClean("שמירה וב״דו״ח ACME.pdf״ נכשלה", lacks: ["ACME"], keeps: ["שמירה וב״…״ נכשלה"])
        XCTAssertEqual(redactor.redact("שגיאה בדו״ח של בע״מ וצה״ל"), "שגיאה בדו״ח של בע״מ וצה״ל", "abbreviations are not quotations")
    }

    /// Hebrew joins up to four of those letters to the front of a word: ומה״…״ (and what "…"),
    /// שבה״…״ (that in the "…"), וכשה״…״ (and when the "…"). Only two were allowed, so a quotation
    /// after three or four stayed whole in the report.
    func testAHebrewQuotationWithUpToFourLettersJoinedToItsFrontGoesWhole() {
        assertClean("שגיאה ומה״Kamal Secret.pdf״ נכשלה", lacks: ["Kamal", "Secret"], keeps: ["שגיאה ומה״…״ נכשלה"])
        assertClean("הקובץ שבה״תיקיית Kamal Secret״ חסר", lacks: ["Kamal", "תיקיית"], keeps: ["הקובץ שבה״…״ חסר"])
        // A gershayim inside a word, as in דו״ח, still does not end the quotation.
        assertClean("העברה וכשה״דו״ח ACME Secret.pdf״ נכשלה", lacks: ["ACME", "Secret", "דו״ח"], keeps: ["העברה וכשה״…״ נכשלה"])
        XCTAssertEqual(redactor.redact("שגיאה בדו״ח של בע״מ וצה״ל"), "שגיאה בדו״ח של בע״מ וצה״ל", "abbreviations are not quotations")
    }

    func testSingleQuotesGoButApostrophesStay() {
        assertClean("The file ‘Invoice ACME.pdf’ couldn’t be opened.", lacks: ["Invoice", "ACME"], keeps: ["couldn’t be opened"])
        assertClean("The file ‘Ana’s notes.txt’ isn’t there", lacks: ["Ana", "notes"], keeps: ["isn’t there"])
        assertClean("Can't open 'Invoice ACME.zip' because it's gone", lacks: ["Invoice", "ACME"], keeps: ["Can't open", "it's gone"])
        assertClean("Can't open 'Bob's files' now", lacks: ["Bob", "files"], keeps: ["Can't open", "now"])
        XCTAssertEqual(redactor.redact("the users' folder isn't 'ready'"), "the users' folder isn't 'ready'",
                       "a quoted code stays, as between double quotes")
        assertClean(#"Could not open 'report.pdf' or "notes.txt""#, lacks: ["report", "notes"])
    }

    /// Crash reports name code between single quotes; that is what the triage needs.
    func testCodeBetweenSingleQuotesStays() {
        for text in ["*** Terminating app due to uncaught exception 'NSInvalidArgumentException', reason: '*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil'",
                     "Fatal error: 'try!' expression unexpectedly raised an error",
                     "Could not cast value of type 'NSTaggedPointerString' (0x1f0b3a8) to 'Swift.Optional<Swift.Int>' (0x1f0b400)."] {
            XCTAssertEqual(redactor.redact(text), text)
            XCTAssertEqual(redactor.redactCrashReport(text), text)
        }
        // An exception's reason is often plain English, and its name need not look like code.
        for text in ["*** Terminating app due to uncaught exception 'NSInternalInconsistencyException', reason: 'Invalid parameter not satisfying: row >= 0'",
                     "*** Terminating app due to uncaught exception 'NSGenericException', reason: 'The window has been marked as needing another Update Constraints in Window pass'",
                     "*** Terminating app due to uncaught exception 'Account Sync Failure', reason: 'Tried to save a message after its folder was deleted'"] {
            XCTAssertEqual(redactor.redactCrashReport(text), text)
        }
    }

    /// Kept between its quotes, a reason is still redacted like any other text.
    func testAnExceptionsReasonLosesAddressesPathsAndSecrets() {
        let text = "*** Terminating app due to uncaught exception 'NSInvalidArgumentException', reason: 'No account for "
            + "ana@example.com in /Users/kmuradoff/Library/Mail with Bearer c2VjcmV0LXRva2Vu'"
        let out = redactor.redactCrashReport(text)
        for secret in ["ana@example.com", "kmuradoff", "c2VjcmV0LXRva2Vu"] {
            XCTAssertFalse(out.contains(secret), "“\(secret)” survived in: \(out)")
        }
        XCTAssertTrue(out.contains("reason: 'No account for <addr:"), out)
        XCTAssertTrue(out.contains("in ~/Library/Mail with Bearer <token>'"), out)
        XCTAssertEqual(redactor.redactCrashReport(out), out, "redacting twice changes nothing")
        XCTAssertEqual(redactor.redact("The server's reason: 'Ana Lima left'"), "The server's reason: '…'",
                       "outside a crash report, quoted words still go")
    }

    func testSignatureShapeIgnoresEveryKindOfQuotedText() {
        let messages = ["Die Datei „Kündigung Ana Lima.eml“ konnte nicht geöffnet werden",
                        "Die Datei „Rechnung.pdf“ konnte nicht geöffnet werden"]
        XCTAssertEqual(Set(messages.map(DiagnosticsSignature.shape(of:))), ["dieDateiKonnteNichtGeffnet"])
        XCTAssertEqual(DiagnosticsSignature.shape(of: "Impossible d’ouvrir le fichier « Facture ACME.pdf » car"),
                       DiagnosticsSignature.shape(of: "Impossible d’ouvrir le fichier « Rapport.pdf » car"))
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

    // MARK: Names a record says its line holds

    /// The engine hands over the folder a line is about, so it goes wherever it stands, however
    /// short, in any case and in the modified UTF-7 a server writes it in, even when the app has
    /// not yet listed the account's folders for the redactor.
    func testNamesTheLineIsAboutGoWhereverTheyStand() {
        let names = ["HR", "Clients/ACME Contracts", "ACME Contracts", "Проекты", "2024"]
        let line = "owner@example.com: opening a message in HR failed: messageGone; hr is gone from Clients/ACME Contracts, "
            + "Mailbox \(ModifiedUTF7.encode("Проекты")) and Проекты missing, folder 2024 read-only, CHRIS and HRM stay"
        let out = redactor.redact(line, naming: names)
        for gone in ["HR ", "hr ", "ACME", "Clients", "Проекты", ModifiedUTF7.encode("Проекты"), " 2024", "owner@"] {
            XCTAssertFalse(out.contains(gone), "“\(gone)” survived in: \(out)")
        }
        XCTAssertTrue(out.contains("CHRIS and HRM stay"), "only whole words go: \(out)")
        XCTAssertTrue(out.contains("<label:\(redactor.ref("label:HR"))>"), out)
        XCTAssertTrue(out.contains("<label:\(redactor.ref("label:Проекты"))>"), "the wire form is the same folder: \(out)")
    }

    func testNamingKeepsStandardFoldersAndEveryReferenceWhole() {
        let out = redactor.redact("INBOX and [Gmail]/Sent Mail stay; label <label:0a1b2c3d> and <addr:0a1b2c3d> too",
                                  naming: ["INBOX", "[Gmail]/Sent Mail", "label", "addr", "0a1b2c3d"])
        XCTAssertTrue(out.hasPrefix("INBOX and [Gmail]/Sent Mail stay; "), out)
        XCTAssertTrue(out.hasSuffix("<label:0a1b2c3d> and <addr:0a1b2c3d> too"), out)
        XCTAssertEqual(redactor.redact(out, naming: ["label", "addr"]), out, "naming again changes nothing")
    }

    func testAnAddressHandedOverAsANameStaysAnAddressReference() {
        let out = redactor.redact("550 5.1.1 <bo.smith@example.org>: Recipient address rejected", naming: ["bo.smith@example.org"])
        XCTAssertEqual(out, "550 5.1.1 <addr:\(redactor.ref("bo.smith@example.org"))>: Recipient address rejected")
    }

    func testNamesAreTakenOutOfTheContextToo() {
        let context: JSONValue = .object(["health": .string("online"), "where": .string("HR, then Clients/ACME")])
        let out = redactor.redact(context, naming: ["HR", "Clients/ACME"])
        XCTAssertEqual(out["health"], .string("online"))
        XCTAssertEqual(out["where"], .string("<label:\(redactor.ref("label:HR"))>, then <label:\(redactor.ref("label:Clients/ACME"))>"))
    }
}
