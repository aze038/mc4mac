import Foundation
@testable import FalconCore

/// Made-up business chains with the structures real ones have: Word's HTML as Outlook for
/// Windows and for Mac send it, their reply headings (Outlook for Mac's From/Date block, Outlook
/// for Windows' From/Sent block, Outlook on the web's in Dutch), a Gmail reply quoted in its
/// blockquote, and a reply from FalconMail 1.10 with its grey heading. Every name, address and
/// word is invented.
enum OutlookChainFixtures {
    /// Word's head as Outlook sends it: namespaces, VML's hidden style, the style sheet with its
    /// comments, and the shape defaults in conditional comments.
    static func wordDocument(body: String, font: String = "Aptos", size: String = "12.0pt") -> String {
        """
        <html xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office" \
        xmlns:w="urn:schemas-microsoft-com:office:word" xmlns:m="http://schemas.microsoft.com/office/2004/12/omml" \
        xmlns="http://www.w3.org/TR/REC-html40"><head>
        <meta http-equiv="Content-Type" content="text/html; charset=utf-8">
        <meta name="Generator" content="Microsoft Word 15 (filtered medium)">
        <!--[if !mso]><style>v\\:* {behavior:url(#default#VML);}
        o\\:* {behavior:url(#default#VML);}
        w\\:* {behavior:url(#default#VML);}
        .shape {behavior:url(#default#VML);}
        </style><![endif]--><style><!--
        /* Font Definitions */
        @font-face
        \t{font-family:"Cambria Math";
        \tpanose-1:2 4 5 3 5 4 6 3 2 4;}
        @font-face
        \t{font-family:\(font);}
        /* Style Definitions */
        p.MsoNormal, li.MsoNormal, div.MsoNormal
        \t{margin:0cm;
        \tfont-size:\(size);
        \tfont-family:"\(font)",sans-serif;
        \tmso-ligatures:standardcontextual;}
        a:link, span.MsoHyperlink
        \t{mso-style-priority:99;
        \tcolor:#467886;
        \ttext-decoration:underline;}
        span.EmailStyle19
        \t{mso-style-type:personal-reply;
        \tfont-family:"\(font)",sans-serif;
        \tcolor:windowtext;}
        .MsoChpDefault
        \t{mso-style-type:export-only;
        \tfont-size:10.0pt;}
        @page WordSection1
        \t{size:612.0pt 792.0pt;
        \tmargin:72.0pt 72.0pt 72.0pt 72.0pt;}
        div.WordSection1
        \t{page:WordSection1;}
        --></style><!--[if gte mso 9]><xml>
        <o:shapedefaults v:ext="edit" spidmax="1026" />
        </xml><![endif]--><!--[if gte mso 9]><xml>
        <o:shapelayout v:ext="edit">
        <o:idmap v:ext="edit" data="1" />
        </o:shapelayout></xml><![endif]-->
        </head>
        <body lang="EN-GB" link="#467886" vlink="#96607D" style="word-wrap:break-word">
        <div class="WordSection1">
        \(body)
        </div>
        </body>
        </html>
        """
    }

    static func paragraph(_ text: String) -> String {
        "<p class=\"MsoNormal\"><span style=\"font-size:11.0pt\">\(text)<o:p></o:p></span></p>\n"
    }

    static let emptyParagraph = "<p class=\"MsoNormal\"><span style=\"font-size:11.0pt\"><o:p>&nbsp;</o:p></span></p>\n"

    /// A signature as Word writes one: a table with the logo drawn in VML for Word and as an
    /// image for everyone else, and a disclaimer in 5.5 point.
    static func signature(_ name: String, company: String) -> String {
        """
        <table class="MsoNormalTable" border="0" cellspacing="0" cellpadding="0" style="border-collapse:collapse"><tr>\
        <td width="161" valign="top" style="width:120.75pt;padding:0cm 5.4pt 0cm 5.4pt"><p class="MsoNormal">\
        <!--[if gte vml 1]><v:shape id="Picture_x0020_1" o:spid="_x0000_i1025" type="#_x0000_t75" style='width:90pt;height:27pt'>\
        <v:imagedata src="cid:image001.png@01DC2E5A.3F1B7C40" o:title=""/></v:shape><![endif]--><![if !vml]>\
        <img width="120" height="36" style="width:1.25in;height:.375in" src="cid:image001.png@01DC2E5A.3F1B7C40" \
        v:shapes="Picture_x0020_1"><![endif]><o:p></o:p></p></td>\
        <td width="376" valign="top" style="width:281.95pt;padding:0cm 5.4pt 0cm 5.4pt"><p class="MsoNormal"><b>\
        <span style="font-size:9.0pt;font-family:&quot;Arial&quot;,sans-serif;color:black">\(name) / \(company)<o:p></o:p></span></b></p>\
        <p class="MsoNormal"><span style="font-size:9.0pt;font-family:&quot;Arial&quot;,sans-serif;color:#595959">\
        A: 12 Harbour Road, Portsmouth<o:p></o:p></span></p></td></tr></table>
        <p class="MsoNormal"><span style="font-size:5.5pt;font-family:&quot;Helvetica Neue&quot;,serif;color:#595959">\
        Disclaimer: this message is for the named recipient only. If it reached you by mistake, please tell the sender \
        and delete it.<o:p></o:p></span></p>

        """
    }

    /// Outlook for Mac's heading as Word keeps it once the chain has passed through Outlook for
    /// Windows.
    static func macHeading(from: String, date: String, to: String, cc: String?, subject: String) -> String {
        """
        <div style="border:none;border-top:solid #B5C4DF 1.0pt;padding:3.0pt 0cm 0cm 0cm"><p class="MsoNormal">\
        <b><span style="color:black">From: </span></b><span style="color:black">\(from)<br><b>Date: </b>\(date)<br>\
        <b>To: </b>\(to)<br>\(cc.map { "<b>Cc: </b>\($0)<br>" } ?? "")<b>Subject: </b>\(subject)<o:p></o:p></span></p></div>
        \(emptyParagraph)
        """
    }

    /// Outlook for Windows' heading.
    static func windowsHeading(from: String, sent: String, to: String, subject: String) -> String {
        """
        <div style="border:none;border-top:solid #E1E1E1 1.0pt;padding:3.0pt 0cm 0cm 0cm"><p class="MsoNormal"><b>\
        <span lang="EN-US" style="font-size:11.0pt;font-family:&quot;Calibri&quot;,sans-serif">From:</span></b>\
        <span lang="EN-US" style="font-size:11.0pt;font-family:&quot;Calibri&quot;,sans-serif"> \(from)<br><b>Sent:</b> \(sent)<br>\
        <b>To:</b> \(to)<br><b>Subject:</b> \(subject)<o:p></o:p></span></p></div>
        \(emptyParagraph)
        """
    }

    /// Outlook on the web's heading, in Dutch.
    static func dutchHeading(from: String, sent: String, to: String, subject: String) -> String {
        """
        <hr style="display:inline-block;width:98%" tabindex="-1"><div id="divRplyFwdMsg" dir="ltr">\
        <font face="Calibri, sans-serif" style="font-size:11pt" color="#000000"><b>Van:</b> \(from)<br><b>Verzonden:</b> \(sent)<br>\
        <b>Aan:</b> \(to)<br><b>Onderwerp:</b> \(subject)</font><div>&nbsp;</div></div>

        """
    }

    /// A Gmail reply, its original in Gmail's blockquote.
    static func gmailReply(text: String, attribution: String, quoted: String) -> String {
        """
        <div dir="ltr"><div>\(text)</div><div><br></div></div><br><div class="gmail_quote gmail_quote_container">\
        <div dir="ltr" class="gmail_attr">\(attribution)<br></div><blockquote class="gmail_quote" \
        style="margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex">\(quoted)</blockquote></div>
        """
    }

    /// A reply from FalconMail 1.10: AppKit's text, a grey heading dated in the Mac's own
    /// language, and the original with only its html, head and body tags taken out; as Gmail
    /// keeps it in a chain, its body is a div.
    static func falconMailOldReply(text: String, from: String, sent: String, quoted: String, keptByGmail: Bool = false) -> String {
        let (open, close) = keptByGmail ? ("<div style=\"font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:14px\">", "</div>")
            : ("<html><body style=\"font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:14px\">", "</body></html>")
        return """
        \(open)<p style="margin: 0.0px 0.0px 0.0px 0.0px">\
        <font face="Helvetica Neue" size="4" style="font: 14.0px 'Helvetica Neue'">\(text)</font></p>
        <p style="margin: 0.0px 0.0px 0.0px 0.0px; font: 14.0px 'Helvetica Neue'; min-height: 16.0px"><br></p>
        <hr style="border:none;border-top:1px solid #b5b5b5;margin:18px 0 10px 0"><div style="font-size:13px;color:#555;margin-bottom:10px">\
        <b>From:</b> \(from)<br><b>Sent:</b> \(sent)<br><b>To:</b> Rowan Hale &lt;rowan@example.org&gt;<br><b>Subject:</b> Re: Pallets</div>\
        <div style="">\(quoted)</div>\(close)
        """
    }

    /// A long chain as Outlook for Windows sends it: `levels` replies, each with its own
    /// paragraphs, signature and heading, from Outlook for Mac and for Windows in turn, until the
    /// HTML is about `bytes` long.
    static func longOutlookChain(bytes: Int) -> String {
        var body = ""
        var level = 0
        while body.utf8.count < bytes - 3_000 {
            level += 1
            body += paragraph("Dear Rowan,") + emptyParagraph
            for line in 1...6 {
                body += paragraph("Point \(line) of reply \(level): the pallets for the second truck are ready for loading on Tuesday, "
                                  + "and the paperwork for customs will follow in the morning.")
            }
            body += emptyParagraph + paragraph("Kind regards,") + signature("Casey Morgan", company: "Operations")
            body += level.isMultiple(of: 2)
                ? macHeading(from: "Casey Morgan &lt;casey@example.com&gt;", date: "Tuesday, 15 September 2026 at 09:\(10 + level)",
                             to: "Rowan Hale &lt;rowan@example.org&gt;", cc: "'Desk' &lt;desk@example.com&gt;", subject: "Re: Pallets")
                : windowsHeading(from: "Rowan Hale &lt;rowan@example.org&gt;", sent: "Monday, September 14, 2026 4:\(10 + level) PM",
                                 to: "Casey Morgan &lt;casey@example.com&gt;", subject: "RE: Pallets")
        }
        return wordDocument(body: body)
    }

    /// A message with `html` as its HTML part and a plain part with its words.
    static func message(html: String, from: EmailAddress, to: [EmailAddress], cc: [EmailAddress] = [], subject: String,
                        date: String = "Wed, 23 Sep 2026 10:21:00 +0000") -> MIMEMessage {
        let raw = """
        From: \(from.rfc5322)\r
        To: \(to.map(\.rfc5322).joined(separator: ", "))\r
        \(cc.isEmpty ? "" : "Cc: \(cc.map(\.rfc5322).joined(separator: ", "))\r\n")Subject: \(subject)\r
        Date: \(date)\r
        MIME-Version: 1.0\r
        Content-Type: multipart/alternative; boundary="alt"\r
        \r
        --alt\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        \(HTMLText.plainText(from: html))\r
        --alt\r
        Content-Type: text/html; charset=utf-8\r
        Content-Transfer-Encoding: base64\r
        \r
        \(Data(html.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]))\r
        --alt--\r
        """
        return MIMEParser.parse(Data(raw.utf8))
    }
}
