import AppKit

/// A message's HTML as the reader's web view shows it.
///
/// The message keeps its own fonts, sizes, colours and layout, as Outlook shows it. Around it go
/// the reader's ground and margins, a policy that loads nothing from outside the message unless
/// its pictures from the web are allowed, and, in dark appearance, Outlook-style recolouring: the
/// page is laid out in its own light colours and then inverted, pictures inverted back, so black
/// text on white becomes light grey on dark and a message that hard-codes its colours stays
/// readable. The sun switch (`ownColours`) shows it as it was written, on white.
///
/// Office's own fonts come with Office, not with macOS, so text Outlook shows in Calibri or Aptos
/// would fall back to Helvetica here, about a tenth wider and taller than in Outlook, and lines,
/// tables and signatures would no longer wrap where their writer saw them wrap. Each Office font
/// a message names that this Mac lacks is therefore stood in for by the macOS font nearest it in
/// shape, scaled so a line of text takes the width it takes in Outlook (see `standIns`).
public enum ReadingHTML {
    /// The page for `body`, the message's HTML or, for a plain message, `<pre>` holding its
    /// text, `plain` then being true. `inStack` for a card of the conversation stack, which
    /// leaves less room above and below the text.
    public static func page(body: String, plain: Bool = false, parts: [MIMEAttachment], allowRemote: Bool, dark: Bool,
                            ownColours: Bool, inStack: Bool = false,
                            installedFamilies: Set<String> = ReadingHTML.installedFamilies()) -> String {
        let csp = allowRemote
            ? "default-src 'none'; img-src * data: cid: blob:; style-src 'unsafe-inline' *; font-src *;"
            : "default-src 'none'; img-src data:; style-src 'unsafe-inline';"
        let inverted = dark && !ownColours
        let inversion = inverted
            ? " html{filter:invert(0.885) hue-rotate(180deg);} img,video,canvas,svg,picture{filter:invert(1) hue-rotate(180deg);}"
            : ""
        // Words break only where a line has no room for them, as Outlook breaks them, so a
        // signature's table keeps an address whole instead of splitting it letter by letter.
        let style = "<style>:root{color-scheme:light;} html,body{background:#ffffff;margin:0;}\(inversion) "
            + "body{font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:15px;line-height:1.2;color:#1d1d1f;"
            + "padding:\(inStack ? "6px 29px 10px 29px" : "12px 29px 30px 29px");overflow-wrap:break-word;} "
            + "p{margin:0 0 16px;} pre{white-space:pre-wrap;font-family:inherit;} "
            + "img{max-width:100%;height:auto;} table{max-width:100%;} "
            + "blockquote{border-left:1px solid #333333;margin:0 0 0 4px;padding-left:6px;color:#1d1d1f;} a{color:#0a66c2;}"
            + (plain ? "" : standIns(for: body, installed: installedFamilies)) + "</style>"
        let head = "<meta charset=\"utf-8\"><meta name=\"color-scheme\" content=\"light\">"
            + "<meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">\(style)"
        var html = body
        if !plain {
            html = InlinePictures.resolvingCIDs(in: html, with: parts)
            html = html.replacingOccurrences(of: "(?is)<script[^>]*>.*?</script>", with: "", options: .regularExpression)
        }
        if let range = html.range(of: "<head>", options: .caseInsensitive) {
            html.insert(contentsOf: head, at: range.upperBound)
            return html
        }
        return "<html><head>\(head)</head><body>\(html)</body></html>"
    }

    /// An Office font and the macOS font standing in for it, at the size that gives a line of
    /// text the width it has in the Office font, measured on Office's own files.
    public struct StandIn: Sendable {
        public var family: String
        /// PostScript names of the stand-in's regular, bold, italic and bold italic.
        public var faces: (regular: String, bold: String, italic: String, boldItalic: String)
        public var scale: Double
    }

    /// Calibri and Aptos, the fonts nearly every Outlook message is written in, and Office's
    /// other common body fonts. The scales come from the width of a line of English text in each
    /// Office font, as Outlook for Mac ships it, against the stand-in, which then matches it in
    /// x-height too: Aptos, a grotesque in the Swiss manner, is Helvetica at 95%; Calibri, a
    /// humanist sans, is Seravek at 96%; Charter stands in for Cambria and Constantia, Menlo for
    /// Consolas and Avenir Next for Century Gothic.
    public static let standIns: [StandIn] = {
        let seravek = ("Seravek", "Seravek-Bold", "Seravek-Italic", "Seravek-BoldItalic")
        let seravekLight = ("Seravek-Light", "Seravek-Medium", "Seravek-LightItalic", "Seravek-MediumItalic")
        let helvetica = ("Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique")
        let helveticaLight = ("Helvetica-Light", "Helvetica", "Helvetica-LightOblique", "Helvetica-Oblique")
        let charter = ("Charter-Roman", "Charter-Bold", "Charter-Italic", "Charter-BoldItalic")
        return [
            StandIn(family: "Calibri", faces: seravek, scale: 0.96),
            StandIn(family: "Calibri Light", faces: seravekLight, scale: 0.95),
            StandIn(family: "Aptos", faces: helvetica, scale: 0.95),
            StandIn(family: "Aptos Display", faces: helvetica, scale: 0.95),
            StandIn(family: "Aptos Light", faces: helveticaLight, scale: 0.93),
            StandIn(family: "Corbel", faces: seravek, scale: 0.97),
            StandIn(family: "Cambria", faces: charter, scale: 0.96),
            StandIn(family: "Constantia", faces: charter, scale: 0.965),
            StandIn(family: "Consolas", faces: ("Menlo-Regular", "Menlo-Bold", "Menlo-Italic", "Menlo-BoldItalic"), scale: 0.91),
            StandIn(family: "Century Gothic", faces: ("AvenirNext-Regular", "AvenirNext-Bold", "AvenirNext-Italic", "AvenirNext-BoldItalic"),
                    scale: 1.06),
        ]
    }()

    /// The `@font-face` rules standing in for each Office font `html` names that is not among
    /// `installed`; none for a font the Mac has, which is then shown as itself.
    public static func standIns(for html: String, installed: Set<String>) -> String {
        let lower = html.lowercased()
        var rules = ""
        for standIn in standIns where !installed.contains(standIn.family) {
            let name = standIn.family.lowercased()
            guard lower.contains(name + "\"") || lower.contains(name + "'") || lower.contains(name + ",") || lower.contains(name + ";")
                    || lower.contains(name + "&quot;") || lower.contains("font-family:" + name) || lower.contains("face=\"" + name) else { continue }
            let scale = String(format: "%.1f%%", standIn.scale * 100)
            for (face, weight, italic) in [(standIn.faces.regular, "normal", false), (standIn.faces.bold, "bold", false),
                                           (standIn.faces.italic, "normal", true), (standIn.faces.boldItalic, "bold", true)] {
                rules += " @font-face{font-family:\"\(standIn.family)\";src:local(\"\(face)\");font-weight:\(weight);"
                    + "font-style:\(italic ? "italic" : "normal");size-adjust:\(scale);}"
            }
        }
        return rules
    }

    /// The font families installed on this Mac, which the reader's web view shows as themselves,
    /// read once.
    public static func installedFamilies() -> Set<String> { installed }

    private static let installed: Set<String> = {
        let names = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        return Set(names)
    }()
}
