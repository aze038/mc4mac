import Foundation

/// The words a reply or forward quotes its original with when it cannot quote it as rich text
/// (see ComposedBody.quote): the original has no HTML, its HTML cannot be read, or it could not
/// be downloaded at all. The quote never shows a picture's code or address as words.
///
/// A sender's own plain text stands something in for every picture: Outlook writes
/// "[cid:image001.png@01DC…]", or the picture's address in brackets, followed by
/// "<https://…>" when the picture is a link; Gmail writes "[image: Company] <https://…>". So
/// the words come from the original's HTML when it has any, where a picture leaves nothing, and
/// only otherwise from its plain text, with those stand-ins taken out. Links the sender typed
/// stay.
public enum QuotedText {
    /// The original's words: from its HTML when that has any, else from its plain text, each
    /// without the stand-ins for its pictures. With no original, as when it could not be
    /// downloaded, the few words the message list shows for it, cleaned the same way.
    public static func of(_ parsed: MIMEMessage?, snippet: String) -> String {
        guard let parsed else { return withoutPictureStandIns(snippet) }
        if let html = parsed.textHTML, !html.trimmed.isEmpty {
            let text = withoutPictureStandIns(fromHTML(html))
            if !text.trimmed.isEmpty { return text }
        }
        return withoutPictureStandIns(parsed.textPlain ?? "")
    }

    // MARK: - From HTML

    /// HTML as the words it shows: its line breaks, paragraphs, list items and table cells kept
    /// as lines and spaces, a link as its words without its address, and a picture as nothing,
    /// neither its description nor its address. Nothing a reader does not see is kept: no
    /// comment, style, script or head. Text set to keep its spacing, as in `<pre>` or
    /// `white-space:pre-wrap`, keeps its line breaks.
    public static func fromHTML(_ html: String) -> String {
        var source = html.replacingOccurrences(of: "\r\n", with: "\n")
        source = source.replacingOccurrences(of: "(?s)<!--.*?-->", with: "", options: .regularExpression)
        source = source.replacingOccurrences(of: "(?is)<(head|style|script|title|xml|noscript|template)\\b[^>]*>.*?</\\1\\s*>",
                                             with: "", options: .regularExpression)
        source = source.replacingOccurrences(of: "(?s)<!\\[CDATA\\[.*?\\]\\]>|<![^>]*>|<\\?[^>]*>", with: "", options: .regularExpression)

        var writer = Writer()
        let text = source as NSString
        var at = 0
        for match in tag.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            if match.range.location > at {
                writer.text(text.substring(with: NSRange(location: at, length: match.range.location - at)))
            }
            at = NSMaxRange(match.range)
            let closing = text.substring(with: match.range(at: 1)) == "/"
            let name = text.substring(with: match.range(at: 2)).lowercased()
            let attributes = text.substring(with: match.range(at: 3))
            if closing { writer.close(name) } else { writer.open(name, attributes: attributes) }
        }
        if at < text.length { writer.text(text.substring(from: at)) }
        return writer.finished
    }

    /// A start or end tag: its slash, its name and its attributes, which may hold a `>` inside
    /// quotes. A `<` that starts no tag, as in "a < b", is text.
    private static let tag = try! NSRegularExpression(pattern: "<(/?)([A-Za-z][A-Za-z0-9:_-]*)((?:[^>\"']|\"[^\"]*\"|'[^']*')*)>")

    /// Elements that end a line where they start and where they end.
    private static let blocks: Set<String> = [
        "address", "article", "aside", "blockquote", "caption", "center", "dd", "div", "dl", "dt", "fieldset", "figcaption",
        "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre",
        "section", "table", "tr", "ul",
    ]

    /// Elements that never have an end tag.
    private static let voids: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
    ]

    private struct Element {
        var name: String
        /// Set to keep its spacing, as `<pre>` is.
        var keepsSpacing: Bool
        /// Not shown, as with display:none.
        var hides: Bool
        /// A paragraph with space below it, as every `<p>` but Outlook's has.
        var spaced: Bool
        /// The items so far, in a numbered list.
        var items = 0
    }

    /// The words as they are written out, element by element.
    private struct Writer {
        private var output = ""
        private var open: [Element] = []

        private var keepsSpacing: Bool { open.contains { $0.keepsSpacing } }
        private var hidden: Bool { open.contains { $0.hides } }

        mutating func text(_ raw: String) {
            guard !hidden else { return }
            if keepsSpacing {
                output += QuotedText.decodingEntities(raw)
                return
            }
            var words = QuotedText.decodingEntities(raw.replacingOccurrences(of: "[ \\t\\n\\r\\f]+", with: " ", options: .regularExpression))
            if words.hasPrefix(" "), output.isEmpty || output.last?.isWhitespace == true { words.removeFirst() }
            output += words
        }

        mutating func open(_ name: String, attributes: String) {
            let hides = attributes.range(of: "display\\s*:\\s*none|mso-hide\\s*:\\s*all", options: [.regularExpression, .caseInsensitive]) != nil
            let spaced = name == "p" && !QuotedText.isOutlookParagraph(attributes)
            if !hidden, !hides {
                switch name {
                case "br":
                    lineBreak()
                case "p" where spaced:
                    paragraphBreak()
                case "li":
                    softBreak()
                    if let list = open.lastIndex(where: { $0.name == "ol" || $0.name == "ul" }), open[list].name == "ol" {
                        open[list].items += 1
                        output += "\(open[list].items). "
                    } else {
                        output += "• "
                    }
                case _ where QuotedText.blocks.contains(name):
                    softBreak()
                default:
                    break
                }
            }
            guard !QuotedText.voids.contains(name), !attributes.trimmed.hasSuffix("/") else { return }
            let keeps = ["pre", "textarea", "xmp", "plaintext"].contains(name)
                || attributes.range(of: "white-space\\s*:\\s*pre", options: [.regularExpression, .caseInsensitive]) != nil
            open.append(Element(name: name, keepsSpacing: keeps, hides: hides, spaced: spaced))
        }

        mutating func close(_ name: String) {
            var closed: Element?
            if let index = open.lastIndex(where: { $0.name == name }) {
                closed = open[index]
                open.removeSubrange(index...)
            }
            guard !hidden, closed?.hides != true else { return }
            switch name {
            case "p" where closed?.spaced ?? true:
                paragraphBreak()
            case "td", "th":
                if let last = output.last, !last.isWhitespace { output += " " }
            case _ where QuotedText.blocks.contains(name):
                softBreak()
            default:
                break
            }
        }

        private mutating func trimTrailingSpaces() {
            while let last = output.last, last == " " || last == "\t" { output.removeLast() }
        }

        private mutating func lineBreak() {
            trimTrailingSpaces()
            output += "\n"
        }

        /// Ends the line, unless it has just ended.
        private mutating func softBreak() {
            trimTrailingSpaces()
            if !output.isEmpty, !output.hasSuffix("\n") { output += "\n" }
        }

        /// Ends the line and leaves a blank one, unless that is done already.
        private mutating func paragraphBreak() {
            softBreak()
            if !output.isEmpty, !output.hasSuffix("\n\n") { output += "\n" }
        }

        var finished: String {
            var text = output.replacingOccurrences(of: "\u{00A0}", with: " ")
                .replacingOccurrences(of: "[\u{200B}\u{FEFF}\u{00AD}]", with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
            text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            return text.trimmed
        }
    }

    /// Whether a `<p>` is one of Outlook's, set with no space above or below it.
    static func isOutlookParagraph(_ attributes: String) -> Bool {
        let lowered = attributes.lowercased()
        return lowered.contains("mso") || lowered.contains("margin")
    }

    // MARK: - Entities

    /// The HTML 4 names for U+00A0 to U+00FF, in order.
    private static let latin1 = """
        nbsp iexcl cent pound curren yen brvbar sect uml copy ordf laquo not shy reg macr deg plusmn sup2 sup3 acute micro \
        para middot cedil sup1 ordm raquo frac14 frac12 frac34 iquest Agrave Aacute Acirc Atilde Auml Aring AElig Ccedil \
        Egrave Eacute Ecirc Euml Igrave Iacute Icirc Iuml ETH Ntilde Ograve Oacute Ocirc Otilde Ouml times Oslash Ugrave \
        Uacute Ucirc Uuml Yacute THORN szlig agrave aacute acirc atilde auml aring aelig ccedil egrave eacute ecirc euml \
        igrave iacute icirc iuml eth ntilde ograve oacute ocirc otilde ouml divide oslash ugrave uacute ucirc uuml yacute \
        thorn yuml
        """

    private static let named: [String: String] = {
        var names: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "hellip": "…", "mdash": "—", "ndash": "–",
            "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”", "bdquo": "„", "bull": "•", "euro": "€",
            "trade": "™", "dagger": "†", "Dagger": "‡", "permil": "‰", "lsaquo": "‹", "rsaquo": "›", "ensp": " ", "emsp": " ",
            "thinsp": " ", "zwnj": "\u{200C}", "zwj": "\u{200D}", "lrm": "\u{200E}", "rlm": "\u{200F}", "OElig": "Œ", "oelig": "œ",
            "Scaron": "Š", "scaron": "š", "Yuml": "Ÿ", "circ": "ˆ", "tilde": "˜", "larr": "←", "rarr": "→", "uarr": "↑",
            "darr": "↓", "harr": "↔", "check": "✓", "minus": "−",
        ]
        for (offset, name) in latin1.split(separator: " ").enumerated() {
            names[String(name)] = String(UnicodeScalar(UInt8(0xA0 + offset)))
        }
        return names
    }()

    private static let entity = try! NSRegularExpression(pattern: "&(#[0-9]{1,7}|#[xX][0-9A-Fa-f]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});")

    /// `text` with each character reference it holds as the character, in one pass, so that
    /// "&amp;lt;" reads "&lt;". One not known is left as it is.
    static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let source = text as NSString
        var output = ""
        var at = 0
        for match in entity.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: at, length: match.range.location - at))
            at = NSMaxRange(match.range)
            let reference = source.substring(with: match.range(at: 1))
            if reference.hasPrefix("#") {
                let digits = reference.dropFirst()
                let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
                if let value, value != 0, let scalar = UnicodeScalar(value) {
                    output.unicodeScalars.append(scalar)
                } else {
                    output += "\u{FFFD}"
                }
            } else if let character = named[reference] {
                output += character
            } else {
                output += source.substring(with: match.range)
            }
        }
        output += source.substring(from: at)
        return output
    }

    // MARK: - Stand-ins in plain text

    /// A picture's stand-in: "[cid:…]", "[image]", "[image: …]", a picture's address in
    /// brackets, Outlook's "[… Description automatically generated]" or "[signature_…]", with
    /// the "<address>" of the link on the picture when it follows on the same line. One cut off
    /// at the very end, as the few words the message list shows can be, goes too.
    private static let standIn = try! NSRegularExpression(pattern: """
        \\[(?:cid:[^\\]\\n]*|image(?:\\s*:[^\\]\\n]*)?|https?://[^\\s\\]]*|signature_[0-9]+|\
        [^\\]\\n]*Description automatically generated[^\\]\\n]*)(?:\\]|\\z)\
        (?:[ \\t]*<(?:https?|mailto):[^>\\s]*(?:>|\\z))?
        """, options: [.caseInsensitive])

    /// Where a stand-in was, while the lines it leaves are tidied.
    private static let removed = "\u{E000}"

    /// Plain text without the stand-ins a sender's mail program writes for its pictures (see
    /// `standIn`). A line left with nothing else on it goes, and so does the blank line that
    /// would then double one beside it. Every other line, and every link the sender typed,
    /// "https://…" or "report<https://…>" alike, stays as it was.
    public static func withoutPictureStandIns(_ text: String) -> String {
        let source = text.replacingOccurrences(of: "\r\n", with: "\n")
        let whole = NSRange(location: 0, length: (source as NSString).length)
        guard standIn.firstMatch(in: source, range: whole) != nil else { return source }
        let marked = standIn.stringByReplacingMatches(in: source, range: whole, withTemplate: removed)
        var lines: [String] = []
        var dropped = false
        for line in marked.components(separatedBy: "\n") {
            guard line.contains(removed) else {
                // A blank line after one that went would stand beside another blank line.
                if line.trimmed.isEmpty, dropped, lines.last?.trimmed.isEmpty ?? true {
                    continue
                }
                lines.append(line)
                dropped = false
                continue
            }
            var kept = line.replacingOccurrences(of: removed, with: "")
            kept = kept.replacingOccurrences(of: "(?<=\\S)[ \\t]{2,}(?=\\S)", with: " ", options: .regularExpression)
            kept = kept.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression)
            if kept.trimmed.isEmpty {
                dropped = true
                continue
            }
            // What followed a stand-in that began the line now begins it.
            if line.trimmingCharacters(in: .whitespaces).hasPrefix(removed) {
                kept = String(kept.drop { $0 == " " || $0 == "\t" })
            }
            lines.append(kept)
            dropped = false
        }
        return lines.joined(separator: "\n")
    }
}
