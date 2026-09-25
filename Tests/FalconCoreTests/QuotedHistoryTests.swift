import XCTest
@testable import FalconCore

/// The quoted history a reply carries of the earlier messages of its conversation, which the
/// conversation stack hides behind ••• when it is sure of it, and shows whole when it is not.
/// Every message here is made up, written as each mail program writes its replies.
final class QuotedHistoryTests: XCTestCase {
    /// What the stack knows of the earlier message: its opening words, as the list shows them.
    private let earlier = ["Hello Alex, the pallets for Tuesday are counted and the paperwork is on its way to the depot."]

    private let earlierText = """
        Hello Alex, the pallets for Tuesday are counted and the paperwork is on its way to the depot.
        Regards, Sam
        """

    // MARK: HTML

    func testGmailsQuoteIsHiddenWithItsAttribution() throws {
        let html = """
            <div dir="ltr">Thanks Sam, that is all I needed.<div>Alex</div></div><br>\
            <div class="gmail_quote gmail_quote_container"><div dir="ltr" class="gmail_attr">On Thu, 24 Sept 2026 at 16:02, \
            Sam Taylor &lt;sam@example.com&gt; wrote:<br></div><blockquote class="gmail_quote" style="margin:0px 0px 0px 0.8ex">\
            <div dir="ltr">\(earlierText)</div></blockquote></div>
            """
        let split = try XCTUnwrap(QuotedHistory.split(html: html, repeating: earlier))
        XCTAssertEqual(HTMLText.plainText(from: split.own), "Thanks Sam, that is all I needed. Alex")
        XCTAssertTrue(split.quoted.hasPrefix("<div class=\"gmail_quote"))
        // The empty line Gmail leaves above its quote goes with it.
        XCTAssertTrue(split.own.hasSuffix("<div>Alex</div></div>"))
        XCTAssertTrue(html.hasPrefix(split.own) && html.hasSuffix(split.quoted))
    }

    func testOutlooksQuoteIsHiddenFromItsRuleToTheEndWhateverLanguageItsHeadingIsIn() throws {
        let html = """
            <html><head><style>p{margin:0}</style></head><body><div>Dear Sam,</div><div>Received, thank you.</div>\
            <div id="appendonsend"></div><hr style="display:inline-block;width:98%" tabindex="-1">\
            <div id="divRplyFwdMsg" dir="ltr"><b>Van:</b> Sam Taylor &lt;sam@example.com&gt;<br><b>Verzonden:</b> \
            donderdag 24 september 2026 16:02<br><b>Onderwerp:</b> Pallet count</div><div>\(earlierText)</div></body></html>
            """
        let split = try XCTUnwrap(QuotedHistory.split(html: html, repeating: earlier))
        XCTAssertTrue(split.own.hasSuffix("<div>Received, thank you.</div>"))
        XCTAssertTrue(split.quoted.hasPrefix("<div id=\"appendonsend\">"))
    }

    func testOutlookForWindowsQuoteIsHiddenWithTheRuleAboveIt() throws {
        let html = """
            <div class="WordSection1"><p class="MsoNormal">Noted, we will collect on Tuesday.</p><p class="MsoNormal">&nbsp;</p>\
            <div style="border:none;border-top:solid #E1E1E1 1.0pt;padding:3.0pt 0in 0in 0in"><p class="MsoNormal"><b>From:</b> \
            Sam Taylor<br><b>Sent:</b> Thursday, September 24, 2026 4:02 PM</p></div><p class="MsoNormal">\(earlierText)</p></div>
            """
        let split = try XCTUnwrap(QuotedHistory.split(html: html, repeating: earlier))
        XCTAssertTrue(split.own.hasSuffix("<p class=\"MsoNormal\">Noted, we will collect on Tuesday.</p>"))
        XCTAssertFalse(HTMLText.plainText(from: split.own).contains("From:"))
    }

    func testFalconMailsOwnQuoteIsHidden() throws {
        let html = """
            <html><body><div style="white-space:pre-wrap">Thanks, Tuesday it is.</div>\
            <hr style="border:none;border-top:1px solid #b5b5b5;margin:18px 0 10px 0"><div style="font-size:13px;color:#555">\
            <b>From:</b> Sam Taylor &lt;sam@example.com&gt;<br><b>Subject:</b> Pallet count</div><div>\(earlierText)</div></body></html>
            """
        let split = try XCTUnwrap(QuotedHistory.split(html: html, repeating: earlier))
        XCTAssertTrue(split.quoted.hasPrefix("<hr"))
        XCTAssertEqual(HTMLText.plainText(from: split.own), "Thanks, Tuesday it is.")
    }

    func testAppleMailsQuoteGoesWithTheLineNamingItsWriter() throws {
        let html = """
            <html><body><div>See you then.</div><div><br><div>On 24 Sep 2026, at 16:02, Sam Taylor &lt;sam@example.com&gt; \
            wrote:</div><br><blockquote type="cite"><div>\(earlierText)</div></blockquote></div></body></html>
            """
        let split = try XCTUnwrap(QuotedHistory.split(html: html, repeating: earlier))
        XCTAssertEqual(HTMLText.plainText(from: split.own), "See you then.")
        XCTAssertTrue(split.quoted.hasPrefix("<div>On 24 Sep 2026"))
    }

    func testThunderbirdsQuoteStartsAtTheLineNamingItsWriter() throws {
        let html = """
            <html><body><p>Agreed.</p><div class="moz-cite-prefix">On 24/09/2026 16:02, Sam Taylor wrote:<br></div>\
            <blockquote type="cite" cite="mid:1@example.com">\(earlierText)</blockquote></body></html>
            """
        let split = try XCTUnwrap(QuotedHistory.split(html: html, repeating: earlier))
        XCTAssertTrue(split.quoted.hasPrefix("<div class=\"moz-cite-prefix\">"))
    }

    func testAnAnswerWrittenUnderTheQuoteIsNeverHidden() {
        let html = """
            <div>Answers below.</div><blockquote type="cite"><div>\(earlierText)</div></blockquote>\
            <div>Yes, Tuesday suits us, and the depot opens at six.</div>
            """
        XCTAssertNil(QuotedHistory.split(html: html, repeating: earlier))
        let thunderbird = """
            <p>Answers below.</p><div class="moz-cite-prefix">On 24/09/2026, Sam wrote:</div>\
            <blockquote type="cite">\(earlierText)</blockquote><p>Yes, Tuesday suits us.</p>
            """
        XCTAssertNil(QuotedHistory.split(html: thunderbird, repeating: earlier))
    }

    func testAnswersWrittenBetweenTheQuotedPartsOfAGmailQuoteAreNeverHidden() {
        // Gmail splits its quote where an answer is typed into it; the answer stays in its quote.
        let html = """
            <div dir="ltr">Answers inline.</div><br><div class="gmail_quote"><div dir="ltr" class="gmail_attr">On Thu, \
            24 Sept 2026 at 16:02, Sam Taylor &lt;sam@example.com&gt; wrote:<br></div><blockquote class="gmail_quote">\
            Hello Alex, the pallets for Tuesday are counted and the paperwork</blockquote><div>Twelve pallets, all \
            wrapped.</div><blockquote class="gmail_quote">is on its way to the depot. Regards, Sam</blockquote></div>
            """
        XCTAssertNil(QuotedHistory.split(html: html, repeating: earlier))
        // A forward is not in a blockquote, and what it forwards is shown.
        let forward = """
            <div dir="ltr">For the depot.</div><br><div class="gmail_quote"><div dir="ltr" class="gmail_attr">---------- \
            Forwarded message ---------<br>From: Sam Taylor<br></div><br><br><div dir="ltr">\(earlierText)</div></div>
            """
        XCTAssertNil(QuotedHistory.split(html: forward, repeating: earlier))
    }

    func testAGmailQuoteWhoseWriterIsNamedAsOlderGmailDidIsStillHidden() throws {
        let html = """
            <div>Thanks Sam.</div><div class="gmail_quote">On Thu, Sep 24, 2026 at 4:02 PM, Sam Taylor \
            &lt;sam@example.com&gt; wrote:<br><blockquote class="gmail_quote"><div class="gmail_quote">Deeper</div>\
            \(earlierText)</blockquote></div>
            """
        let split = try XCTUnwrap(QuotedHistory.split(html: html, repeating: earlier))
        XCTAssertEqual(HTMLText.plainText(from: split.own), "Thanks Sam.")
    }

    func testAnAnswerUnderAThunderbirdQuotesLineNamingItsWriterIsNeverHidden() {
        let html = """
            <p>Agreed.</p><div class="moz-cite-prefix">On 24/09/2026 16:02, Sam Taylor wrote:<br></div>\
            <p>Before I answer: the depot moved.</p><blockquote type="cite">\(earlierText)</blockquote>
            """
        XCTAssertNil(QuotedHistory.split(html: html, repeating: earlier))
    }

    func testTheEarlierMessagesAreReadOnlyAsFarAsTheFirstTheQuoteRepeats() throws {
        let html = "<div>Thanks.</div><div class=\"gmail_quote\"><blockquote class=\"gmail_quote\">\(earlierText)</blockquote></div>"
        var read = 0
        let texts = [earlier[0], "Never to be reached, being after the one quoted."].lazy.map { text -> String in
            read += 1
            return text
        }
        XCTAssertNotNil(QuotedHistory.split(html: html, repeating: texts))
        XCTAssertEqual(read, 1)
    }

    func testTheNewestOfFiftyRepliesEachQuotingAllBeforeItIsTrimmedQuickly() throws {
        var html = "<div>\(earlierText)</div>"
        var openings: [String] = [earlier[0]]
        for index in 2...50 {
            let own = "Update \(index): the carrier confirmed slot \(index) and the crew for shift \(index) is booked."
            html = "<div dir=\"ltr\">\(own)</div><br><div class=\"gmail_quote\"><div class=\"gmail_attr\">On Thu, Sam wrote:<br>"
                + "</div><blockquote class=\"gmail_quote\">\(html)</blockquote></div>"
            openings.insert(own, at: 0)
        }
        let started = Date()
        let split = try XCTUnwrap(QuotedHistory.split(html: html, repeating: openings.dropFirst()))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        XCTAssertEqual(HTMLText.plainText(from: split.own),
                       "Update 50: the carrier confirmed slot 50 and the crew for shift 50 is booked.")
    }

    func testAQuoteOfSomethingNotInTheConversationIsShown() {
        let html = """
            <div>Please see what the carrier said.</div><div class="gmail_quote"><blockquote class="gmail_quote">\
            Your container is due at the port on Friday morning, berth four.</blockquote></div>
            """
        XCTAssertNil(QuotedHistory.split(html: html, repeating: earlier))
    }

    func testAMessageWithNothingOfItsOwnAboveTheQuoteIsShownWhole() {
        let html = "<div class=\"gmail_quote\"><blockquote class=\"gmail_quote\">\(earlierText)</blockquote></div>"
        XCTAssertNil(QuotedHistory.split(html: html, repeating: earlier))
    }

    func testAMessageWithoutAQuoteIsShownWhole() {
        XCTAssertNil(QuotedHistory.split(html: "<div>\(earlierText)</div><blockquote>An indented paragraph.</blockquote>",
                                         repeating: earlier))
    }

    func testAnEarlierMessageTooShortToBeSureOfHidesNothing() {
        let html = """
            <div>Great.</div><div class="gmail_quote"><blockquote class="gmail_quote">Thanks, noted!</blockquote></div>
            """
        XCTAssertNil(QuotedHistory.split(html: html, repeating: ["Thanks, noted!"]))
        XCTAssertNil(QuotedHistory.split(html: html, repeating: []))
    }

    // MARK: Plain text

    func testAPlainTextQuoteIsHiddenWithTheLineNamingItsWriterEvenWrappedOntoTwoLines() throws {
        let quoted = earlierText.split(separator: "\n").map { "> " + $0 }.joined(separator: "\n")
        let plain = "Thanks Sam.\n\nAlex\n\nOn Thu, 24 Sept 2026 at 16:02, Sam Taylor <\nsam@example.com> wrote:\n\n\(quoted)\n"
        let split = try XCTUnwrap(QuotedHistory.split(plain: plain, repeating: earlier))
        XCTAssertEqual(split.own, "Thanks Sam.\n\nAlex")
        XCTAssertTrue(split.quoted.hasPrefix("On Thu, 24 Sept 2026"))
    }

    func testAnOriginalMessageLineOrOutlooksUnderscoresStartAQuote() throws {
        let original = "Fine by me.\n\n-----Original Message-----\nFrom: Sam Taylor\n\n\(earlierText)"
        XCTAssertEqual(try XCTUnwrap(QuotedHistory.split(plain: original, repeating: earlier)).own, "Fine by me.")
        let outlook = "Fine by me.\r\n\r\n________________________________\r\nFrom: Sam Taylor <sam@example.com>\r\nSent: Thursday\r\n\r\n\(earlierText)"
        XCTAssertEqual(try XCTUnwrap(QuotedHistory.split(plain: outlook, repeating: earlier)).own, "Fine by me.")
    }

    func testPlainAnswersBetweenQuotedLinesAreNeverHidden() {
        let plain = "See below.\n\n> Hello Alex, the pallets for Tuesday are counted\nYes, twelve of them.\n> and the paperwork is on its way to the depot."
        XCTAssertNil(QuotedHistory.split(plain: plain, repeating: earlier))
    }

    func testUnderscoresWithoutAHeadingUnderThemAreNotAQuote() {
        let plain = "Totals\n____________\n\(earlierText)"
        XCTAssertNil(QuotedHistory.split(plain: plain, repeating: earlier))
    }

    // MARK: The message the reader shows

    func testTheHTMLIsTrimmedWhenThereIsSomeElseThePlainText() throws {
        let html = "<div>Thanks.</div><div class=\"gmail_quote\"><blockquote class=\"gmail_quote\">\(earlierText)</blockquote></div>"
        let plain = "Thanks.\n\n" + earlierText.split(separator: "\n").map { "> " + $0 }.joined(separator: "\n")
        let both = MIMEParser.parse(Data(multipart(plain: plain, html: html).utf8))
        let trimmed = try XCTUnwrap(QuotedHistory.trimmed(both, repeating: earlier))
        XCTAssertEqual(trimmed.textHTML, "<div>Thanks.</div>")
        XCTAssertEqual(trimmed.textPlain, both.textPlain)

        let onlyPlain = MIMEParser.parse(Data("Content-Type: text/plain; charset=utf-8\r\n\r\n\(plain)".utf8))
        XCTAssertEqual(try XCTUnwrap(QuotedHistory.trimmed(onlyPlain, repeating: earlier)).textPlain, "Thanks.")

        let unsure = MIMEParser.parse(Data("Content-Type: text/plain; charset=utf-8\r\n\r\nThanks.".utf8))
        XCTAssertNil(QuotedHistory.trimmed(unsure, repeating: earlier))
    }

    func testTheLineNamingAWriterIsKnownInSeveralLanguages() {
        XCTAssertTrue(QuotedHistory.isAttribution("On 24 Sep 2026, at 16:02, Sam wrote:"))
        XCTAssertTrue(QuotedHistory.isAttribution("Am 24.09.2026 um 16:02 schrieb Sam:"))
        XCTAssertTrue(QuotedHistory.isAttribution("Le 24 sept. 2026 à 16:02, Sam a écrit :"))
        XCTAssertFalse(QuotedHistory.isAttribution("The driver wrote the times down"))
        XCTAssertFalse(QuotedHistory.isAttribution("Please note:"))
    }

    private func multipart(plain: String, html: String) -> String {
        """
        MIME-Version: 1.0\r
        Content-Type: multipart/alternative; boundary="b1"\r
        \r
        --b1\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        \(plain)\r
        --b1\r
        Content-Type: text/html; charset=utf-8\r
        \r
        \(html)\r
        --b1--\r

        """
    }
}
