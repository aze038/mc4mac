import XCTest
import AppKit
import WebKit
@testable import FalconCore

/// Replies, replies to all and forwards go out as Legacy Outlook for Mac writes them, so a chain
/// that passes between Outlook, Gmail and FalconMail stacks the same way at every step: Outlook's
/// heading in English, the new text as compact paragraphs in Outlook's font, the original whole
/// below it with its rules kept to itself, and little of FalconMail's own on top.
final class OutlookReplyTests: XCTestCase {
    private let sam = EmailAddress(name: "Sam Sender", address: "sam@example.com")
    private let alex = EmailAddress(name: "Alex Example", address: "alex@example.com")
    private let jo = EmailAddress(name: "Jo Park", address: "jo@example.com")
    /// Wednesday 23 September 2026, 10:21 UTC: 14:21 in Baku, 11:21 in London.
    private let instant = Date(timeIntervalSince1970: 1_790_158_860)
    private let baku = TimeZone(identifier: "Asia/Baku")!

    private func original(from: EmailAddress? = nil, to: [EmailAddress]? = nil, cc: [EmailAddress] = [],
                          subject: String = "Figures") -> ReplyHeader.Original {
        ReplyHeader.Original(from: from ?? sam, date: instant, to: to ?? [alex], cc: cc, subject: subject)
    }

    // MARK: - the heading

    func testTheDateIsWrittenAsOutlookForMacWritesItInEnglish() {
        XCTAssertEqual(ReplyHeader.date(instant, timeZone: baku), "Wednesday, 23 September 2026 at 14:21")
        XCTAssertEqual(ReplyHeader.date(instant, timeZone: TimeZone(identifier: "Europe/London")!),
                       "Wednesday, 23 September 2026 at 11:21")
        let morning = Date(timeIntervalSince1970: 1_790_060_700) // 08:05 in Baku on the Tuesday
        XCTAssertEqual(ReplyHeader.date(morning, timeZone: baku), "Tuesday, 22 September 2026 at 11:05")
    }

    func testTheHeadingIsOutlookForMacsBlockInHTMLAndText() throws {
        let heading = original(to: [alex, jo], cc: [EmailAddress(name: "'Desk'", address: "desk@example.com")])
        let date = ReplyHeader.date(instant)
        XCTAssertEqual(ReplyHeader.plain(heading, attribution: .outlook), """

            From: Sam Sender <sam@example.com>
            Date: \(date)
            To: Alex Example <alex@example.com>, Jo Park <jo@example.com>
            Cc: 'Desk' <desk@example.com>
            Subject: Figures


            """)
        XCTAssertEqual(ReplyHeader.html(heading, attribution: .outlook, font: .outlook),
                       "<div style=\"font-family:Aptos,Calibri,Helvetica,Arial,sans-serif;font-size:12pt;color:black\">"
                       + "<div style=\"border:none;border-top:solid #B5C4DF 1.0pt;padding:3.0pt 0in 0in 0in\"><p style=\"margin:0\">"
                       + "<b>From: </b>Sam Sender &lt;sam@example.com&gt;<br><b>Date: </b>\(date)<br>"
                       + "<b>To: </b>Alex Example &lt;alex@example.com&gt;, Jo Park &lt;jo@example.com&gt;<br>"
                       + "<b>Cc: </b>'Desk' &lt;desk@example.com&gt;<br><b>Subject: </b>Figures</p></div>"
                       + "<p style=\"margin:0\">&nbsp;</p></div>")
    }

    func testWithoutCcTheLineIsLeftOutAndASenderWithoutANameIsTheAddressAlone() {
        let heading = original(from: EmailAddress(address: "desk@example.com"))
        let plain = ReplyHeader.plain(heading, attribution: .outlook)
        XCTAssertFalse(plain.contains("Cc:"), plain)
        XCTAssertTrue(plain.contains("From: <desk@example.com>\n"), plain)
        XCTAssertFalse(ReplyHeader.html(heading, attribution: .outlook, font: .outlook).contains("Cc:"))
    }

    func testNamesWithQuotesCommasAndAccentsAreWrittenAsTheyCameAndEscaped() {
        let heading = original(from: EmailAddress(name: "O'Brien, Seán", address: "sean@example.ie"),
                               to: [EmailAddress(name: "Team \"Ops\" <North>", address: "ops@example.com"),
                                    EmailAddress(name: "Gülnar Əliyeva", address: "gulnar@example.az")],
                               subject: "Re: Q3 & Q4 <draft>")
        let plain = ReplyHeader.plain(heading, attribution: .outlook)
        XCTAssertTrue(plain.contains("From: O'Brien, Seán <sean@example.ie>\n"), plain)
        XCTAssertTrue(plain.contains("To: Team \"Ops\" <North> <ops@example.com>, Gülnar Əliyeva <gulnar@example.az>\n"), plain)
        XCTAssertTrue(plain.contains("Subject: Re: Q3 & Q4 <draft>\n"), plain)
        let html = ReplyHeader.html(heading, attribution: .outlook, font: .outlook)
        XCTAssertTrue(html.contains("<b>From: </b>O'Brien, Seán &lt;sean@example.ie&gt;<br>"), html)
        XCTAssertTrue(html.contains("<b>To: </b>Team &quot;Ops&quot; &lt;North&gt; &lt;ops@example.com&gt;, Gülnar Əliyeva &lt;gulnar@example.az&gt;<br>"),
                      html)
        XCTAssertTrue(html.contains("<b>Subject: </b>Re: Q3 &amp; Q4 &lt;draft&gt;</p>"), html)
    }

    func testACustomAttributionAndNoneStillWork() {
        let custom = ReplyHeader.Attribution.custom("On [DATE], \"[NAME]\" <[ADDRESS]> wrote:")
        let line = "On \(ReplyHeader.date(instant)), \"Sam Sender\" <sam@example.com> wrote:"
        XCTAssertEqual(ReplyHeader.plain(original(), attribution: custom), "\n\(line)\n\n")
        XCTAssertTrue(ReplyHeader.html(original(), attribution: custom, font: .outlook).contains(">\(HTMLText.escape(line))</p>"))
        XCTAssertEqual(ReplyHeader.plain(original(), attribution: .none), "")
        XCTAssertEqual(ReplyHeader.html(original(), attribution: .none, font: .outlook), "")
    }

    /// Reply, Reply All and Forward all quote the original through ComposeDraft.history, so each
    /// sends this: the heading in the plain part exactly as in the HTML part, Cc included.
    func testTheSentMessageCarriesTheHeadingInBothParts() throws {
        let parsed = OutlookChainFixtures.message(html: OutlookChainFixtures.wordDocument(body: OutlookChainFixtures.paragraph("The figures are in.")),
                                                  from: sam, to: [alex], cc: [jo], subject: "Figures")
        let sent = reply(to: parsed, saying: "Thanks, noted.")
        XCTAssertTrue(sent.plain.hasPrefix("""
            Thanks, noted.


            ________________________________
            From: Sam Sender <sam@example.com>
            Date: \(ReplyHeader.date(instant))
            To: Alex Example <alex@example.com>
            Cc: Jo Park <jo@example.com>
            Subject: Figures

            The figures are in.
            """), sent.plain)
        XCTAssertTrue(sent.html.contains("<b>From: </b>Sam Sender &lt;sam@example.com&gt;<br><b>Date: </b>\(ReplyHeader.date(instant))<br>"
                                         + "<b>To: </b>Alex Example &lt;alex@example.com&gt;<br><b>Cc: </b>Jo Park &lt;jo@example.com&gt;<br>"
                                         + "<b>Subject: </b>Figures</p>"), sent.html)
    }

    // MARK: - English whatever the Mac's language

    /// Runs in a process of its own set to another language and region, for
    /// `testTheDateIsEnglishWhateverTheMacsLanguage`.
    func testLocaleChild() throws {
        guard let locale = ProcessInfo.processInfo.environment["FALCONMAIL_LOCALE_CHILD"] else {
            throw XCTSkip("run by testTheDateIsEnglishWhateverTheMacsLanguage in a process set to another language")
        }
        XCTAssertTrue(Locale.current.identifier.hasPrefix(locale), Locale.current.identifier)
        let macs = DateFormatter()
        macs.dateStyle = .full
        macs.timeStyle = .short
        let history = QuotedHistory(original: original(), html: "<p>Hi</p>", text: "Hi", attribution: .outlook, indent: false, font: .outlook)
        print("FALCONMAIL-MAC=\(macs.string(from: instant))")
        print("FALCONMAIL-DATE=\(ReplyHeader.date(instant))")
        print("FALCONMAIL-HEADING=\(history.plain.components(separatedBy: "\n").first { $0.hasPrefix("Date:") } ?? "")")
    }

    /// FalconMail 1.10 dated the heading the Mac's way, so a reply from a Mac set to Russian put
    /// a Russian date in an English chain. Run on a Mac set to Russian, Azerbaijani and Turkish,
    /// the heading's date is English, in the Mac's time zone.
    func testTheDateIsEnglishWhateverTheMacsLanguage() throws {
        let bundle = Bundle(for: Self.self).bundlePath
        guard bundle.hasSuffix(".xctest"), FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else {
            throw XCTSkip("needs the test bundle and xcrun")
        }
        for locale in ["ru_RU", "az_AZ", "tr_TR"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["xctest", "-XCTest", "FalconCoreTests.OutlookReplyTests/testLocaleChild",
                                 "-AppleLocale", locale, "-AppleLanguages", "(\(locale.prefix(2)))", bundle]
            var environment = ProcessInfo.processInfo.environment
            environment["FALCONMAIL_LOCALE_CHILD"] = locale
            environment["TZ"] = "Asia/Baku"
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "\(locale): \(output)")
            let lines = output.components(separatedBy: "\n")
            func value(_ key: String) -> String? {
                lines.first { $0.hasPrefix("FALCONMAIL-\(key)=") }.map { String($0.dropFirst("FALCONMAIL-\(key)=".count)) }
            }
            let macs = try XCTUnwrap(value("MAC"), output)
            XCTAssertFalse(macs.contains("September"), "\(locale) is really in effect: \(macs)")
            XCTAssertEqual(value("DATE"), "Wednesday, 23 September 2026 at 14:21", locale)
            XCTAssertEqual(value("HEADING"), "Date: Wednesday, 23 September 2026 at 14:21", locale)
        }
    }

    // MARK: - the original kept to itself

    /// The rules an original carries reach nothing above it: not the new text, not the heading.
    @MainActor
    func testHostileRulesInTheOriginalCannotReachTheNewText() throws {
        let hostile = """
            <html><head><style>
            * { font-style: italic }
            html, body { font-family: "Times New Roman", serif; font-size: 30px; color: #008000; background: #000000 }
            html body p, div > p { color: #ff0000 !important; margin: 5em }
            p { font-size: 40px }
            b { color: #0000ff }
            a { color: #ff00ff }
            @media screen { p { font-weight: bold } div { color: #ff0000 } }
            </style></head><body text="#008000" link="#ff00ff">
            <p>Their <a href="https://example.com/">words</a></p><style>div { font-size: 50px }</style></body></html>
            """
        let parsed = OutlookChainFixtures.message(html: hostile, from: sam, to: [alex], subject: "Loud")
        let sent = reply(to: parsed, saying: "Mine stays mine")
        let read = try NSAttributedString(data: Data(sent.html.utf8), options: [.documentType: NSAttributedString.DocumentType.html,
                                                                               .characterEncoding: String.Encoding.utf8.rawValue],
                                          documentAttributes: nil)
        func attribute<T>(_ key: NSAttributedString.Key, at words: String) throws -> T? {
            let at = (read.string as NSString).range(of: words)
            XCTAssertNotEqual(at.location, NSNotFound, words)
            return read.attribute(key, at: at.location, effectiveRange: nil) as? T
        }
        for words in ["Mine stays mine", "From:", "Sam Sender"] {
            // No colour of its own is the reader's black.
            let colour = ((try attribute(.foregroundColor, at: words) as NSColor?) ?? .black).usingColorSpace(.sRGB)
            XCTAssertEqual(colour?.redComponent ?? 1, 0, accuracy: 0.05, words)
            XCTAssertEqual(colour?.greenComponent ?? 1, 0, accuracy: 0.05, words)
            let font = try XCTUnwrap(attribute(.font, at: words) as NSFont?)
            XCTAssertEqual(font.pointSize, 16, accuracy: 0.5, "\(words): \(font)")
            XCTAssertFalse(font.familyName?.contains("Times") ?? true, "\(words): \(font)")
            XCTAssertFalse(NSFontManager.shared.traits(of: font).contains(.italicFontMask), words)
        }
        // The original still gets every one of its rules.
        let theirs = try XCTUnwrap(attribute(.foregroundColor, at: "Their") as NSColor?).usingColorSpace(.sRGB)
        XCTAssertEqual(theirs?.redComponent ?? 0, 1, accuracy: 0.05)
        XCTAssertEqual(theirs?.greenComponent ?? 1, 0, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(attribute(.font, at: "Their") as NSFont?).pointSize, 40, accuracy: 0.5)
        XCTAssertTrue(NSFontManager.shared.traits(of: try XCTUnwrap(attribute(.font, at: "Their") as NSFont?)).contains(.italicFontMask))
        // Every rule is scoped, the ones in the body moved to the head with the rest.
        let style = try XCTUnwrap(sent.html.range(of: "<style>").map { sent.html[$0.upperBound...] }?.prefix { $0 != "<" })
        for rule in style.components(separatedBy: "}") where rule.contains("{") && !rule.hasPrefix("@media") {
            XCTAssertTrue(rule.hasPrefix(".fm-q"), rule)
        }
        XCTAssertEqual(sent.html.components(separatedBy: "<style").count, 2, "one style sheet: \(sent.html)")
        XCTAssertTrue(sent.html.contains(".fm-q a:link{color:#ff00ff}"), sent.html)
        XCTAssertTrue(sent.html.contains("<div class=\"fm-q\" style=\"color:#008000\">"), sent.html)
    }

    func testSelectorsAreScopedAsTheOriginalMeantThem() {
        let css = """
            <!-- /* Style Definitions */
            p.MsoNormal, li.MsoNormal, div.MsoNormal {margin:0cm; font-family:"Aptos",sans-serif;}
            html{background:#fff} body.WordSection1 p{color:red} html > body{margin:0} :root{--x:1}
            a:link, span.MsoHyperlink {color:#467886;} * {box-sizing:border-box}
            @font-face {font-family:"Cambria Math"; panose-1:2 4 5 3 5 4 6 3 2 4;}
            @page WordSection1 {size:612.0pt 792.0pt;} @list l0:level1 {mso-level-tab-stop:none;}
            @media (max-width: 600px) { .wide, td { width: 100% !important } }
            @import url("https://example.com/tracker.css"); @charset "utf-8";
            div.a[title="x,y"], p::first-line {color:blue} -->
            """
        XCTAssertEqual(ScopedCSS.scope(css, to: ".fm-q"),
                       ".fm-q p.MsoNormal,.fm-q li.MsoNormal,.fm-q div.MsoNormal{margin:0cm;font-family:\"Aptos\",sans-serif;}"
                       + ".fm-q{background:#fff}.fm-q.WordSection1 p{color:red}.fm-q{margin:0}.fm-q{--x:1}"
                       + ".fm-q a:link,.fm-q span.MsoHyperlink{color:#467886;}.fm-q *{box-sizing:border-box}"
                       + "@font-face{font-family:\"Cambria Math\";panose-1:2 4 5 3 5 4 6 3 2 4;}"
                       + "@page WordSection1{size:612.0pt 792.0pt;}@list l0:level1{mso-level-tab-stop:none;}"
                       + "@media (max-width: 600px){.fm-q .wide,.fm-q td{width: 100% !important}}"
                       + ".fm-q div.a[title=\"x,y\"],.fm-q p::first-line{color:blue}")
    }

    /// Word's own structure goes through untouched: its MsoNormal paragraphs and classes, the
    /// VML and conditional comments in its body, the conditional blocks in its head, carried
    /// once, and the namespaces they need on the reply's own html element.
    func testWordsStructureAndVMLGoThroughUntouched() throws {
        let body = OutlookChainFixtures.paragraph("Dear Alex,") + OutlookChainFixtures.signature("Sam Sender", company: "Finance")
        let html = OutlookChainFixtures.wordDocument(body: body)
        let parsed = OutlookChainFixtures.message(html: html, from: sam, to: [alex], subject: "Figures")
        let sent = reply(to: parsed)
        XCTAssertTrue(sent.html.contains(body.trimmingCharacters(in: .whitespacesAndNewlines)), "the body as it came")
        XCTAssertTrue(sent.html.hasPrefix("<html xmlns:m=\"http://schemas.microsoft.com/office/2004/12/omml\" "
                                          + "xmlns:o=\"urn:schemas-microsoft-com:office:office\" xmlns:v=\"urn:schemas-microsoft-com:vml\" "
                                          + "xmlns:w=\"urn:schemas-microsoft-com:office:word\"><head>"), String(sent.html.prefix(300)))
        XCTAssertEqual(sent.html.components(separatedBy: "<o:shapedefaults").count, 2)
        XCTAssertEqual(sent.html.components(separatedBy: "<!--[if !mso]><style>v\\:*").count, 2, "VML's hidden style, still hidden")
        XCTAssertTrue(sent.html.contains("<div class=\"fm-q\" lang=\"EN-GB\" style=\"word-wrap:break-word\"><div class=\"WordSection1\">"),
                      sent.html)
        XCTAssertTrue(sent.html.contains(".fm-q a:visited{color:#96607D}"), sent.html)
        XCTAssertFalse(sent.html.contains("Font Definitions"), "comments go")
        XCTAssertFalse(sent.html.contains("<meta"), "the original's meta tags go")
    }

    // MARK: - chains

    /// A chain of every kind the evidence holds: a Gmail forward of a FalconMail 1.10 reply to a
    /// Gmail reply to an Outlook on the web message in Dutch, quoting Outlook for Windows and
    /// Outlook for Mac. Replying keeps every part of it, in order, exactly as it came.
    func testAMixedChainIsKeptWholeAndInOrder() throws {
        let fixtures = OutlookChainFixtures.self
        let deepest = fixtures.paragraph("Can you quote for two trucks?")
            + fixtures.macHeading(from: "Casey Morgan &lt;casey@example.com&gt;", date: "Tuesday, 15 September 2026 at 09:12",
                                  to: "Rowan Hale &lt;rowan@example.org&gt;", cc: "'Desk' &lt;desk@example.com&gt;, 'Pat Lee' &lt;pat@example.net&gt;",
                                  subject: "Pallets")
            + fixtures.paragraph("Pallets are ready.")
            + fixtures.windowsHeading(from: "Rowan Hale &lt;rowan@example.org&gt;", sent: "Monday, September 14, 2026 4:12 PM",
                                      to: "Casey Morgan &lt;casey@example.com&gt;", subject: "RE: Pallets")
        let dutch = "<div>Wij kijken ernaar.</div>" + fixtures.dutchHeading(from: "Casey Morgan &lt;casey@example.com&gt;",
                                                                         sent: "woensdag 16 september 2026 10:04",
                                                                         to: "info@example.nl", subject: "Pallets") + deepest
        let gmail = fixtures.gmailReply(text: "Any news?", attribution: "On Thu, 17 Sept 2026 at 08:30, Kim Ng &lt;kim@example.nl&gt; wrote:",
                                        quoted: dutch)
        let falcon = fixtures.falconMailOldReply(text: "We are checking.", from: "Kim Ng &lt;kim@example.nl&gt;",
                                                 sent: "среда, 16 сентября 2026 г. в 09:15", quoted: gmail, keptByGmail: true)
        let forward = "<div dir=\"ltr\"><br><div class=\"gmail_quote\"><div class=\"gmail_attr\">---------- Forwarded message ---------<br>"
            + "From: Rowan Hale &lt;rowan@example.org&gt;</div><br>" + falcon + "</div></div>"
        let parsed = OutlookChainFixtures.message(html: forward, from: sam, to: [alex], subject: "Fwd: Pallets")
        let sent = reply(to: parsed)
        let parts = ["Thanks, noted.", "border-top:solid #B5C4DF 1.0pt", "---------- Forwarded message", "We are checking.",
                     "среда, 16 сентября", "Any news?", "border-left:1px solid rgb(204,204,204)", "Wij kijken ernaar.", "<b>Verzonden:</b>",
                     "Can you quote for two trucks?", "<b>Date: </b>Tuesday, 15 September 2026 at 09:12", "Pallets are ready.", "<b>Sent:</b>"]
        var from = sent.html.startIndex
        for part in parts {
            let found = try XCTUnwrap(sent.html.range(of: part, range: from..<sent.html.endIndex), "\(part) in order")
            from = found.upperBound
        }
        XCTAssertTrue(sent.html.contains(forward), "the chain byte for byte")
    }

    // MARK: - the line across the message

    /// The heading's line is its block's top border, so it runs the whole width of the message
    /// in any reader however wide, as Outlook's does, never a rule of fixed width or a row of
    /// underscores; the plain text part has Outlook's line of underscores above the heading.
    @MainActor
    func testTheHeadingsLineRunsTheWholeWidthOfTheMessageAsSent() throws {
        let parsed = OutlookChainFixtures.message(html: OutlookChainFixtures.wordDocument(body: OutlookChainFixtures.paragraph("The figures are in.")),
                                                  from: sam, to: [alex], subject: "Figures")
        let sent = reply(to: parsed)
        XCTAssertFalse(sent.html.contains("<hr"), sent.html)
        XCTAssertFalse(sent.html.contains("____"), sent.html)
        XCTAssertEqual(sent.plain.components(separatedBy: ReplyHeader.plainLine).count, 2, sent.plain)
        XCTAssertTrue(sent.plain.contains("\n\n\(ReplyHeader.plainLine)\nFrom: Sam Sender <sam@example.com>\nDate: "), sent.plain)
        for width: CGFloat in [600, 1200] {
            let measured = try measure(sent.html, width: width, script: """
                (() => { const line = [...document.querySelectorAll('div')].find(d => getComputedStyle(d).borderTopStyle === 'solid');
                  const style = getComputedStyle(line);
                  return [line.getBoundingClientRect().width, document.body.getBoundingClientRect().width,
                          parseFloat(style.borderTopWidth), style.borderTopColor].join('|'); })()
                """).components(separatedBy: "|")
            XCTAssertEqual(measured.count, 4, measured.joined())
            XCTAssertEqual(Double(measured[0]), Double(measured[1]), "the whole width of the message at \(width): \(measured)")
            XCTAssertGreaterThan(Double(measured[0]) ?? 0, Double(width) - 40)
            // One point, which WebKit draws a whole pixel thick on a screen of one pixel to the point.
            XCTAssertTrue((1...(4.0 / 3 + 0.01)).contains(Double(measured[2]) ?? 0), "one point: \(measured)")
            XCTAssertEqual(measured[3], "rgb(181, 196, 223)")
        }
    }

    /// Where the original was edited in the composer, what is sent is the body as it now reads,
    /// but still under Outlook's heading, the same block as an untouched original has.
    func testAHeadingRebuiltFromItsLinesIsTheSameBlock() {
        let heading = original(from: EmailAddress(name: "O'Brien, Seán", address: "sean@example.ie"), to: [alex, jo],
                               cc: [EmailAddress(name: "'Desk'", address: "desk@example.com")], subject: "Re: Q3 & Q4 <draft>")
        let plain = ReplyHeader.plain(heading, attribution: .outlook)
        let lines = try? XCTUnwrap(ReplyHeader.headingLines(of: plain + "The figures are in.\n"))
        XCTAssertEqual(lines.map { ReplyHeader.html(headingLines: $0, font: .outlook) },
                       ReplyHeader.html(heading, attribution: .outlook, font: .outlook))
        XCTAssertNil(ReplyHeader.headingLines(of: ReplyHeader.plain(heading, attribution: .custom("On [DATE], [NAME] wrote:"))))
    }

    /// The composer draws Outlook's line above every heading in the chain it quotes, as Outlook
    /// for Mac's composer shows their borders: Outlook for Mac's, Outlook for Windows', Outlook
    /// on the web's in Dutch and FalconMail 1.10's, each with room between the line and its
    /// text; Gmail's attribution and its Forwarded message block have no line in any reader and
    /// get none. In the plain text part each line of a heading is a line of its own.
    @MainActor
    func testEveryHeadingInAQuotedChainHasOutlooksLineInTheComposer() throws {
        let fixtures = OutlookChainFixtures.self
        let chain = fixtures.paragraph("Pallets are ready.")
            + fixtures.macHeading(from: "Casey Morgan &lt;casey@example.com&gt;", date: "Tuesday, 15 September 2026 at 09:12",
                                  to: "Rowan Hale &lt;rowan@example.org&gt;", cc: nil, subject: "Pallets")
            + fixtures.paragraph("Can you quote?")
            + fixtures.windowsHeading(from: "Rowan Hale &lt;rowan@example.org&gt;", sent: "Monday, September 14, 2026 4:12 PM",
                                      to: "Casey Morgan &lt;casey@example.com&gt;", subject: "RE: Pallets")
            + "<div>Wij kijken ernaar.</div>" + fixtures.dutchHeading(from: "Casey Morgan &lt;casey@example.com&gt;",
                                                                     sent: "woensdag 16 september 2026 10:04", to: "info@example.nl",
                                                                     subject: "Pallets")
        let gmail = fixtures.gmailReply(text: "Any news?", attribution: "On Thu, 17 Sept 2026 at 08:30, Kim Ng &lt;kim@example.nl&gt; wrote:",
                                        quoted: chain)
        let falcon = fixtures.falconMailOldReply(text: "We are checking.", from: "Kim Ng &lt;kim@example.nl&gt;",
                                                 sent: "среда, 16 сентября 2026 г. в 09:15", quoted: gmail, keptByGmail: true)
        let forward = "<div dir=\"ltr\"><div class=\"gmail_attr\">---------- Forwarded message ---------<br>"
            + "From: Rowan Hale &lt;rowan@example.org&gt;<br>Date: Thu, 17 Sept 2026 at 09:00</div><br>" + falcon + "</div>"
        let attributes: [NSAttributedString.Key: Any] = [.font: ComposeFont.outlook.displayFont, .foregroundColor: NSColor.labelColor]
        let heading = ReplyHeader.plain(original(), attribution: .outlook)
        let quote = try XCTUnwrap(ComposedBody.quote(heading: heading, html: forward, parts: [], attributes: attributes))
        let text = quote.string as NSString
        let starts = ReplyHeader.headingStarts(in: text, from: 0)
        let expected = ["From: Sam Sender", "From: Kim Ng", "From: Casey Morgan", "From: Rowan Hale <rowan@example.org>\u{2028}Sent:", "Van: Casey"]
        XCTAssertEqual(starts, expected.map { text.range(of: $0).location }, "\(starts) in \(quote.string.debugDescription)")
        for start in starts.dropFirst() {
            let style = try XCTUnwrap(quote.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(style.paragraphSpacingBefore, 4, text.substring(with: NSRange(location: start, length: 12)))
        }
        let body = NSMutableAttributedString(string: "Thanks.\n\n", attributes: attributes)
        body.append(quote)
        let stored = ComposedBody.stored(body)
        let history = QuotedHistory(original: original(), html: forward, text: "", attribution: .outlook, indent: false, font: .outlook)
        let sent = ComposedHTML.content(rtf: stored.rtf, rtfd: stored.rtfd, plain: body.string, historyPlain: quote.string,
                                        historyHTML: history.html)
        XCTAssertFalse(sent.plain.contains("\u{2028}"), sent.plain.debugDescription)
        XCTAssertTrue(sent.plain.contains("From: Kim Ng <kim@example.nl>\nSent: среда"), sent.plain)
        XCTAssertTrue(sent.plain.hasPrefix("Thanks.\n\n\n\(ReplyHeader.plainLine)\nFrom: Sam Sender"), sent.plain)
        XCTAssertTrue(sent.html.contains(forward), "the chain as it came")
    }

    /// Gmail reads only the first 16 KB of a `<style>` element, and Word's sheet for a message
    /// with lists and many fonts is longer than that; the original's rules go out whole, in
    /// several elements each under the limit, in their order, split only between rules.
    func testALongStyleSheetGoesOutInPartsGmailReadsWhole() throws {
        var rules = "p.MsoNormal, li.MsoNormal, div.MsoNormal {margin:0cm; font-size:11.0pt; font-family:\"Calibri\",sans-serif;}\n"
        for list in 0..<40 {
            rules += "@list l\(list) {mso-list-id:\(1_000_000 + list); mso-list-type:hybrid; mso-list-template-ids:-1 67698689;}\n"
            for level in 1...9 {
                rules += "@list l\(list):level\(level) {mso-level-number-format:bullet; mso-level-text:\"\\F0B7\"; mso-level-tab-stop:none; "
                    + "mso-level-number-position:left; margin-left:\(18 * level).0pt; text-indent:-18.0pt; font-family:Symbol;}\n"
            }
        }
        rules += "a:link, span.MsoHyperlink {color:#0563C1; text-decoration:underline;}\n"
        let html = "<html><head><style><!--\n\(rules)--></style></head><body lang=EN-GB><div class=WordSection1>"
            + OutlookChainFixtures.paragraph("The figures are in.") + "</div></body></html>"
        XCTAssertGreaterThan(rules.utf8.count, 40_000)
        let sent = reply(to: OutlookChainFixtures.message(html: html, from: sam, to: [alex], subject: "Figures"))
        let head = try XCTUnwrap(sent.html.range(of: "</head>").map { String(sent.html[..<$0.lowerBound]) })
        let sheets = head.components(separatedBy: "<style>").dropFirst().map { $0.components(separatedBy: "</style>")[0] }
        XCTAssertGreaterThanOrEqual(sheets.count, 3, head)
        for sheet in sheets { XCTAssertLessThan(sheet.utf8.count, 16_000) }
        XCTAssertEqual(sheets.joined(), ScopedCSS.scope(rules, to: ".fm-q"), "every rule, in order, split only between rules")
        XCTAssertTrue(sheets[0].hasPrefix(".fm-q p.MsoNormal,.fm-q li.MsoNormal,.fm-q div.MsoNormal{margin:0cm;"), sheets[0])
        for sheet in sheets { XCTAssertTrue(sheet.hasSuffix("}"), String(sheet.suffix(40))) }
    }

    /// A reply to a reply from FalconMail 1.10 keeps that reply's body font to it.
    func testAReplyFromAnEarlierBuildKeepsItsFontToItself() {
        let old = OutlookChainFixtures.falconMailOldReply(text: "We are checking.", from: "Kim Ng &lt;kim@example.nl&gt;",
                                                         sent: "среда, 16 сентября 2026 г. в 09:15", quoted: "<p>Earlier</p>")
        let sent = reply(to: OutlookChainFixtures.message(html: old, from: sam, to: [alex], subject: "Re: Pallets"))
        XCTAssertTrue(sent.html.contains("<div style=\"font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:14px\">"
                                         + "<p style=\"margin: 0.0px 0.0px 0.0px 0.0px\"><font face=\"Helvetica Neue\""), sent.html)
        XCTAssertFalse(sent.html.contains("<body style"), sent.html)
    }

    /// Three replies from FalconMail deep, each quoting the one before: one head, one style
    /// sheet, each heading once, the Outlook original once at the bottom with its rules scoped
    /// under every quote it sits in, and each step adding only its own.
    func testAThreeDeepChainStacksCleanly() throws {
        let start = OutlookChainFixtures.wordDocument(body: OutlookChainFixtures.paragraph("Figures attached."))
        var message = OutlookChainFixtures.message(html: start, from: sam, to: [alex], subject: "Figures")
        var sizes = [start.utf8.count]
        let people = [alex, sam, jo, alex]
        for step in 1...3 {
            let sent = reply(to: message, saying: "Reply \(step).")
            sizes.append(sent.html.utf8.count)
            message = OutlookChainFixtures.message(html: sent.html, from: people[step], to: [people[step - 1]],
                                                   subject: "Re: Figures")
        }
        let html = try XCTUnwrap(message.textHTML)
        XCTAssertEqual(html.components(separatedBy: "<head>").count, 2, html)
        XCTAssertEqual(html.components(separatedBy: "<style>").count, 3, "one style sheet, and Word's hidden one for VML: \(html)")
        XCTAssertEqual(html.components(separatedBy: "Cambria Math").count, 2, "the original's rules once: \(html)")
        XCTAssertEqual(html.components(separatedBy: "<o:shapedefaults").count, 2, html)
        XCTAssertEqual(html.components(separatedBy: "border-top:solid #B5C4DF 1.0pt").count, 4)
        XCTAssertEqual(html.components(separatedBy: "Figures attached.").count, 2)
        for step in 1...3 { XCTAssertEqual(html.components(separatedBy: "Reply \(step).").count, 2) }
        let order = ["Reply 3.", "Reply 2.", "Reply 1.", "Figures attached."].map { html.range(of: $0)!.lowerBound }
        XCTAssertEqual(order, order.sorted())
        XCTAssertTrue(html.contains(".fm-q .fm-q .fm-q p.MsoNormal"), html)
        XCTAssertFalse(html.contains(".fm-q .fm-q .fm-q .fm-q"), html)
        for (before, after) in zip(sizes, sizes.dropFirst()) {
            XCTAssertLessThan(after - before, 1_500, "each step adds only its own: \(sizes)")
        }
    }

    // MARK: - size

    /// Gmail clips a message whose HTML passes about 102 KB. A reply to a long Outlook chain adds
    /// less than 3 KB of FalconMail's own on top of the chain.
    func testAReplyToALongChainAddsLittleOfItsOwn() throws {
        let chain = OutlookChainFixtures.longOutlookChain(bytes: 95_000)
        XCTAssertGreaterThan(chain.utf8.count, 92_000)
        let parsed = OutlookChainFixtures.message(html: chain, from: sam, to: [alex], cc: [jo], subject: "Re: Pallets")
        let sent = reply(to: parsed, saying: "Hello Sam,\n\nThanks, both trucks are booked for Tuesday.\n\nKind regards,\nAlex")
        XCTAssertLessThan(sent.html.utf8.count - chain.utf8.count, 3_000, "\(sent.html.utf8.count) for \(chain.utf8.count)")
        XCTAssertLessThan(sent.html.utf8.count, 102_000, "under Gmail's clipping")
    }

    // MARK: - the new text

    /// The new text is Outlook's paragraphs: no AppKit font tags, no 0.0px, empty lines as
    /// &nbsp;, text in the message's font carrying no font, and what the writer chose kept.
    func testTheNewTextIsCompactParagraphsInOutlooksFont() throws {
        let font = ComposeFont.outlook
        let base: [NSAttributedString.Key: Any] = [.font: font.displayFont, .foregroundColor: NSColor.labelColor]
        let text = NSMutableAttributedString(string: "Hello Sam,\n\nThe figures are ", attributes: base)
        text.append(NSAttributedString(string: "final", attributes: [.font: NSFontManager.shared.convert(font.displayFont, toHaveTrait: .boldFontMask)]))
        text.append(NSAttributedString(string: ", see ", attributes: base))
        text.append(NSAttributedString(string: "the report", attributes: base.merging([.link: URL(string: "https://example.com/r?a=1&b=2")!]) { $1 }))
        text.append(NSAttributedString(string: " and ", attributes: base))
        text.append(NSAttributedString(string: "this", attributes: [.font: font.displayFont,
                                                                    .foregroundColor: NSColor(srgbRed: 0.75, green: 0, blue: 0, alpha: 1)]))
        text.append(NSAttributedString(string: " in big", attributes: [.font: font.displayFont.withSize(24)]))
        text.append(NSAttributedString(string: " and Georgia", attributes: [.font: NSFont(name: "Georgia", size: 16) ?? font.displayFont]))
        text.append(NSAttributedString(string: ".\n\nKind regards,\nAlex", attributes: base))
        let sent = ComposedHTML.content(rich: text, plain: text.string, historyPlain: "", historyHTML: "", font: font)
        XCTAssertEqual(sent.html, "<html><body><div style=\"font-family:Aptos,Calibri,Helvetica,Arial,sans-serif;font-size:12pt\">"
                       + "<p style=\"margin:0\">Hello Sam,</p>\n<p style=\"margin:0\">&nbsp;</p>\n"
                       + "<p style=\"margin:0\">The figures are <b>final</b>, see <a href=\"https://example.com/r?a=1&amp;b=2\">the report</a>"
                       + " and <span style=\"color:#bf0000\">this</span><span style=\"font-size:18pt\"> in big</span>"
                       + "<span style=\"font-family:Georgia,serif\"> and Georgia</span>.</p>\n"
                       + "<p style=\"margin:0\">&nbsp;</p>\n<p style=\"margin:0\">Kind regards,</p>\n<p style=\"margin:0\">Alex</p>"
                       + "</div></body></html>")
    }

    /// A body written in the system's font, as every draft and signature before Outlook's font
    /// was the default, still goes out in it.
    func testTextInTheOldDefaultFontKeepsIt() {
        let text = NSAttributedString(string: "Old draft", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let sent = ComposedHTML.content(rich: text, plain: text.string, historyPlain: "", historyHTML: "", font: .outlook)
        XCTAssertTrue(sent.html.contains("<span style=\"font-family:'Helvetica Neue',sans-serif;font-size:10.5pt\">Old draft</span>"), sent.html)
    }

    func testOutlooksFontIsDeclaredAsItsListAtTwelvePoint() {
        let font = ComposeFont.outlook
        XCTAssertEqual(font.css, "font-family:Aptos,Calibri,Helvetica,Arial,sans-serif;font-size:12pt")
        XCTAssertTrue(ComposeFont.outlookFamilies.contains(font.displayFont.familyName ?? ""), font.displayFont.fontName)
        XCTAssertEqual(font.displayFont.pointSize, 16)
        XCTAssertEqual(ComposeFont(family: "Times New Roman", size: 14).css, "font-family:'Times New Roman',serif;font-size:10.5pt")
        XCTAssertEqual(ComposeFont(family: "System", size: 13).css, "font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:9.75pt")
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: "OutlookReplyTests-\(UUID().uuidString)"))
        XCTAssertEqual(ComposeFont.chosen(in: defaults), .outlook)
        defaults.set("Georgia", forKey: ComposeFont.familyKey)
        defaults.set(18.0, forKey: ComposeFont.sizeKey)
        XCTAssertEqual(ComposeFont.chosen(in: defaults), ComposeFont(family: "Georgia", size: 18))
    }

    /// A reply whose quote was edited no longer ends with it, and the reminder still finds where
    /// Outlook's heading starts.
    func testTheAttachmentReminderFindsOutlooksHeading() {
        let heading = ReplyHeader.plain(original(), attribution: .outlook)
        let body = "Thanks, will read it tonight.\n" + heading + "The report is attached, as promised (edited)."
        XCTAssertFalse(AttachmentReminder.mentionsAttachment(subject: "Re: Figures", body: body, historyPlain: heading + "The report",
                                                            keywords: ["attached"]))
        XCTAssertTrue(AttachmentReminder.mentionsAttachment(subject: "Re: Figures", body: "See attached.\n" + heading,
                                                           historyPlain: "", keywords: ["attached"]))
    }

    // MARK: - helpers

    /// What Send builds for a reply saying `words` above `parsed`, as ComposeDraft.reply and
    /// outgoing build it, the quote standing as its text.
    /// What `script` gives for `html` laid out by WebKit offscreen `width` points wide.
    @MainActor
    private func measure(_ html: String, width: CGFloat, script: String) throws -> String {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 600), configuration: configuration)
        let loaded = Loaded()
        view.navigationDelegate = loaded
        view.loadHTMLString(html, baseURL: nil)
        let deadline = Date(timeIntervalSinceNow: 30)
        while !loaded.done, Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) }
        guard loaded.done else { throw XCTSkip("WebKit did not load a page in time here") }
        var result: String?
        var finished = false
        view.evaluateJavaScript(script) { value, _ in
            result = value as? String
            finished = true
        }
        while !finished, Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) }
        return try XCTUnwrap(result)
    }

    private final class Loaded: NSObject, WKNavigationDelegate {
        var done = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
    }

    private func reply(to parsed: MIMEMessage, saying words: String = "Thanks, noted.",
                       font: ComposeFont = .outlook) -> ComposedHTML.Content {
        let heading = ReplyHeader.Original(from: parsed.from, date: parsed.date ?? instant, to: parsed.to, cc: parsed.cc,
                                           subject: parsed.subject)
        let history = QuotedHistory(original: heading, html: parsed.textHTML.map { InlinePictures.resolvingCIDs(in: $0, with: parsed.attachments) },
                                    text: parsed.bestText, attribution: .outlook, indent: false, font: font)
        let attributes: [NSAttributedString.Key: Any] = [.font: font.displayFont, .foregroundColor: NSColor.labelColor]
        let body = NSMutableAttributedString(string: words + "\n\n", attributes: attributes)
        body.append(NSAttributedString(string: history.plain, attributes: attributes))
        let stored = ComposedBody.stored(body)
        return ComposedHTML.content(rtf: stored.rtf, rtfd: stored.rtfd, plain: body.string, historyPlain: history.plain,
                                    historyHTML: history.html, font: font)
    }
}
