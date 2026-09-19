import XCTest
@testable import FalconCore

final class MIMETests: XCTestCase {
    func testHeaderUnfoldingAndDecoding() {
        let raw = "Subject: =?UTF-8?B?SGVsbG8gV8O2cmxk?=\r\nFrom: \"Ana =?ISO-8859-1?Q?M=FCller?=\" <ana@example.com>\r\nX-Long: first\r\n second\r\n\r\n"
        let h = MIMEParser.parseHeaders(Data(raw.utf8))
        XCTAssertEqual(RFC2047.decode(h.first("Subject") ?? ""), "Hello Wörld")
        XCTAssertEqual(h.first("X-Long"), "first second")
        let from = AddressParser.parse(h.first("From")).first
        XCTAssertEqual(from?.address, "ana@example.com")
        XCTAssertEqual(from?.name, "Ana Müller")
    }

    func testAddressListParsing() {
        let list = AddressParser.parse("Bob <bob@x.com>, \"Smith, Jane\" <jane@y.org>, plain@z.net")
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list[1].name, "Smith, Jane")
        XCTAssertEqual(list[2].address, "plain@z.net")
    }

    func testMultipartAlternativeWithAttachment() {
        let raw = """
        From: a@b.c\r
        To: d@e.f\r
        Subject: Test\r
        Date: Tue, 2 Apr 2024 09:14:00 +0200\r
        Message-ID: <one@b.c>\r
        Content-Type: multipart/mixed; boundary="outer"\r
        \r
        --outer\r
        Content-Type: multipart/alternative; boundary="inner"\r
        \r
        --inner\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        Hello =C3=BCber=\r
        line\r
        --inner\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>Hello <b>über</b>line</p>\r
        --inner--\r
        --outer\r
        Content-Type: application/pdf; name="doc.pdf"\r
        Content-Disposition: attachment; filename="doc.pdf"\r
        Content-Transfer-Encoding: base64\r
        \r
        JVBERi0xLjQ=\r
        --outer--\r
        """
        let m = MIMEParser.parse(Data(raw.utf8))
        XCTAssertEqual(m.textPlain, "Hello überline")
        XCTAssertTrue(m.textHTML?.contains("<b>über</b>") ?? false)
        XCTAssertEqual(m.attachments.count, 1)
        XCTAssertEqual(m.attachments.first?.filename, "doc.pdf")
        XCTAssertEqual(m.attachments.first?.data, Data("%PDF-1.4".utf8))
        XCTAssertEqual(m.messageID, "<one@b.c>")
        XCTAssertNotNil(m.date)
        XCTAssertEqual(m.snippet, "Hello überline")
    }

    func testBuilderRoundTrip() {
        let out = OutgoingMessage(from: EmailAddress(name: "Zoë", address: "z@x.com"), to: [EmailAddress(address: "y@x.com")],
                                  subject: "Grüße", textBody: "Line one\nLine two = ok\n", htmlBody: "<p>hi</p>",
                                  attachments: [OutgoingAttachment(filename: "a.txt", mimeType: "text/plain", data: Data("abc".utf8))])
        let data = MIMEBuilder.build(out)
        let parsed = MIMEParser.parse(data)
        XCTAssertEqual(parsed.subject, "Grüße")
        XCTAssertEqual(parsed.from.name, "Zoë")
        XCTAssertEqual(parsed.textPlain, "Line one\nLine two = ok\n")
        XCTAssertEqual(parsed.textHTML, "<p>hi</p>")
        XCTAssertEqual(parsed.attachments.first?.data, Data("abc".utf8))
    }

    func testQuotedPrintableEncodeDecode() {
        let text = String(repeating: "ä", count: 60) + " end"
        let encoded = QuotedPrintable.encode(text)
        for line in encoded.split(separator: "\r\n") { XCTAssertLessThanOrEqual(line.count, 76) }
        let decoded = Charsets.decode(TransferDecoding.quotedPrintable(Data(encoded.utf8)), charset: "utf-8")
        XCTAssertEqual(decoded, text)
    }

    func testHTMLToText() {
        XCTAssertEqual(HTMLText.plainText(from: "<html><style>x{}</style><body>Hi<br>there &amp; you</body></html>"), "Hi\nthere & you")
    }

    func testDateParsing() {
        XCTAssertNotNil(RFC5322Date.parse("Tue, 2 Apr 2024 09:14:00 +0200"))
        XCTAssertNotNil(RFC5322Date.parse("2 Apr 2024 09:14 GMT"))
        XCTAssertNotNil(RFC5322Date.parse("Tue, 2 Apr 2024 09:14:00 +0200 (CEST)"))
    }
}
