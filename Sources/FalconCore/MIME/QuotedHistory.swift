import Foundation

/// The quoted history at the foot of a reply: the earlier messages it repeats. The conversation
/// stack hides it behind a small ••• button, as Gmail does, since the messages it repeats are on
/// screen already. It is hidden only when FalconMail is sure of it:
///
/// - it starts where a mail program starts one: Gmail's, Apple Mail's, Thunderbird's, Yahoo's or
///   Outlook's quote, FalconMail's own, an "Original Message" line, or lines beginning with ">";
/// - it runs to the end of the message, so no answer written under or between quoted lines is
///   ever hidden;
/// - it holds the opening words of an earlier message of the conversation;
/// - the message says something of its own above it.
///
/// Anything else is shown whole.
public enum QuotedHistory {
    public struct Split: Equatable, Sendable {
        /// The message's own part, as the card shows it.
        public var own: String
        /// The quoted history the ••• button shows.
        public var quoted: String
    }

    /// An earlier message counts as quoted when this many of its opening words, or all of them
    /// when it has fewer, appear in the quote in order.
    static let openingWords = 8
    /// An earlier message with fewer words than this, such as "Thanks!", is too short to be sure of.
    static let fewestWords = 4

    /// `message` with its quoted history taken out of the text the reader shows (its HTML when it
    /// has any, else its plain text), or nil when it has none FalconMail is sure of. `earlier` is
    /// what is known of the text of each earlier message of the conversation.
    public static func trimmed(_ message: MIMEMessage, repeating earlier: [String]) -> MIMEMessage? {
        if let html = message.textHTML, !html.trimmed.isEmpty {
            guard let split = split(html: html, repeating: earlier) else { return nil }
            var copy = message
            copy.textHTML = split.own
            return copy
        }
        guard let plain = message.textPlain, let split = split(plain: plain, repeating: earlier) else { return nil }
        var copy = message
        copy.textPlain = split.own
        return copy
    }

    // MARK: - HTML

    public static func split(html: String, repeating earlier: [String]) -> Split? {
        guard let start = quoteStart(inHTML: html) else { return nil }
        let own = withoutTrailingBlankLines(String(html[..<start]))
        let quoted = String(html[start...])
        guard !HTMLText.plainText(from: own).isEmpty, repeats(HTMLText.plainText(from: quoted), earlier) else { return nil }
        return Split(own: own, quoted: quoted)
    }

    private enum Shape {
        /// The quote is this element, which must be the last thing in the message.
        case element(String)
        /// A line naming the writer, followed by the quote in a blockquote that must be the last
        /// thing in the message.
        case attributionThenBlockquote
        /// The quote runs from here to the end, as Outlook's always does.
        case toEnd
    }

    private static let classValue = "\\bclass\\s*=\\s*[\"']?[^\"'>]*\\b"
    private static let markerPatterns: [(String, Shape)] = [
        ("<div\\b[^>]*" + classValue + "gmail_quote\\b", .element("div")),
        ("<blockquote\\b[^>]*" + classValue + "gmail_quote\\b", .element("blockquote")),
        ("<div\\b[^>]*" + classValue + "yahoo_quoted\\b", .element("div")),
        ("<blockquote\\b[^>]*\\btype\\s*=\\s*[\"']?cite\\b", .element("blockquote")),
        ("<div\\b[^>]*" + classValue + "moz-cite-prefix\\b", .attributionThenBlockquote),
        // Outlook on the web and the new Outlook, whose ids gain an x_ each time they are quoted.
        ("<div\\b[^>]*\\bid\\s*=\\s*[\"']?(x_)*(appendonsend|divRplyFwdMsg|mail-editor-reference-message-container)\\b", .toEnd),
        // Legacy Outlook for Mac.
        ("<(span|div)\\b[^>]*\\bid\\s*=\\s*[\"']?OLK_SRC_BODY_SECTION\\b", .toEnd),
        // Outlook for Windows: the rule above the From, Sent, To and Subject block.
        ("<div\\b[^>]*\\bstyle\\s*=\\s*[\"'][^\"']*border\\s*:\\s*none\\s*;\\s*border-top\\s*:\\s*solid", .toEnd),
        // FalconMail's own replies and forwards.
        ("<hr\\b[^>]*>\\s*<div\\b[^>]*>\\s*<b>\\s*From:\\s*</b>", .toEnd),
        ("-{2,}\\s*(" + originalMessage + ")\\s*-{2,}", .toEnd),
    ]
    private static let markers: [(NSRegularExpression, Shape)] = markerPatterns.map {
        (try! NSRegularExpression(pattern: $0.0, options: [.caseInsensitive]), $0.1)
    }

    /// Where the quoted history begins, when it has one of the known shapes and nothing but the
    /// quote follows it.
    private static func quoteStart(inHTML html: String) -> String.Index? {
        let whole = NSRange(html.startIndex..., in: html)
        var first: (range: Range<String.Index>, shape: Shape)?
        for (regex, shape) in markers {
            guard let match = regex.firstMatch(in: html, range: whole), let range = Range(match.range, in: html) else { continue }
            if first == nil || range.lowerBound < first!.range.lowerBound { first = (range, shape) }
        }
        guard let (range, shape) = first else { return nil }
        switch shape {
        case .element(let tag):
            guard endsTheMessage(elementNamed: tag, at: range.lowerBound, in: html) else { return nil }
            return backingOverAttribution(range.lowerBound, in: html)
        case .attributionThenBlockquote:
            guard let blockquote = html.range(of: "<blockquote", options: .caseInsensitive, range: range.upperBound..<html.endIndex),
                  endsTheMessage(elementNamed: "blockquote", at: blockquote.lowerBound, in: html) else { return nil }
            return range.lowerBound
        case .toEnd:
            return backingOverRule(range.lowerBound, in: html)
        }
    }

    private static let trailingBlank = try! NSRegularExpression(
        pattern: "(?:\\s|&nbsp;|<br\\s*/?>|<(?:p|div)\\b[^>]*>(?:\\s|&nbsp;|<br\\s*/?>)*</(?:p|div)\\s*>)+$",
        options: [.caseInsensitive])

    /// The empty lines a mail program leaves above its quote go with it, so that the ••• button
    /// stands under the last line of the message's own.
    private static func withoutTrailingBlankLines(_ html: String) -> String {
        let from = html.index(html.endIndex, offsetBy: -2_000, limitedBy: html.startIndex) ?? html.startIndex
        guard let match = trailingBlank.firstMatch(in: html, range: NSRange(from..., in: html)),
              let range = Range(match.range, in: html) else { return html }
        return String(html[..<range.lowerBound])
    }

    /// Whether the element named `tag` opening at `start` is followed by no words of its own:
    /// anything written after a quote is an answer under it, never to be hidden.
    private static func endsTheMessage(elementNamed tag: String, at start: String.Index, in html: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "<(/?)\(tag)\\b[^>]*>", options: [.caseInsensitive]) else { return false }
        var depth = 0
        for match in regex.matches(in: html, range: NSRange(start..., in: html)) {
            depth += match.range(at: 1).length > 0 ? -1 : 1
            guard depth == 0, let end = Range(match.range, in: html)?.upperBound else { continue }
            return HTMLText.plainText(from: String(html[end...])).isEmpty
        }
        // Never closed: everything after it is inside it.
        return true
    }

    /// The line naming the writer, such as "On 24 Sep 2026, at 16:02, Sam wrote:", goes with the
    /// quote it stands above.
    private static func backingOverAttribution(_ cut: String.Index, in html: String) -> String.Index {
        let from = html.index(cut, offsetBy: -600, limitedBy: html.startIndex) ?? html.startIndex
        guard let regex = try? NSRegularExpression(pattern: "<(div|p)\\b[^>]*>|<br\\s*/?>", options: [.caseInsensitive]) else { return cut }
        for match in regex.matches(in: html, range: NSRange(from..<cut, in: html)).reversed() {
            guard let range = Range(match.range, in: html) else { continue }
            let start = match.range(at: 1).length > 0 ? range.lowerBound : range.upperBound
            let text = HTMLText.plainText(from: String(html[start..<cut]))
            if text.isEmpty { continue }
            return isAttribution(text) ? start : cut
        }
        return cut
    }

    /// Outlook draws a rule above its quote; it goes with the quote.
    private static func backingOverRule(_ cut: String.Index, in html: String) -> String.Index {
        let from = html.index(cut, offsetBy: -300, limitedBy: html.startIndex) ?? html.startIndex
        let before = String(html[from..<cut])
        guard let rule = before.range(of: "<hr\\b[^>]*>\\s*$", options: [.regularExpression, .caseInsensitive]) else { return cut }
        return html.index(from, offsetBy: before.distance(from: before.startIndex, to: rule.lowerBound))
    }

    // MARK: - Plain text

    public static func split(plain: String, repeating earlier: [String]) -> Split? {
        let lines = plain.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let cut = quoteStart(inLines: lines) else { return nil }
        let own = lines[..<cut].joined(separator: "\n").replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        let quoted = lines[cut...].joined(separator: "\n")
        guard !own.trimmed.isEmpty, repeats(quoted, earlier) else { return nil }
        return Split(own: own, quoted: quoted)
    }

    private static func quoteStart(inLines lines: [String]) -> Int? {
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.range(of: "^-{2,}\\s*(" + originalMessage + ")\\s*-{2,}$", options: [.regularExpression, .caseInsensitive]) != nil {
                return index
            }
            // Outlook's plain text: a line of underscores over From:, Sent:, To: and Subject:.
            if line.range(of: "^_{10,}$", options: .regularExpression) != nil, headerFollows(index, in: lines) {
                return index
            }
            if line.hasPrefix(">") {
                // Quoted to the end, or an answer between quoted lines, which is never hidden.
                let rest = lines[index...].map { $0.trimmingCharacters(in: .whitespaces) }
                guard rest.allSatisfy({ $0.isEmpty || $0.hasPrefix(">") }) else { return nil }
                return attribution(above: index, in: lines) ?? index
            }
        }
        return nil
    }

    private static func headerFollows(_ index: Int, in lines: [String]) -> Bool {
        let next = lines[(index + 1)...].lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        guard let next else { return false }
        return next.range(of: "^\\p{L}[\\p{L} -]{0,24}\\s?:\\s*\\S", options: .regularExpression) != nil
    }

    /// The line naming the writer above a quote, and the line before it when the name wrapped
    /// onto two, as Gmail wraps a long one.
    private static func attribution(above index: Int, in lines: [String]) -> Int? {
        guard let line = (0..<index).last(where: { !lines[$0].trimmed.isEmpty }), isAttribution(lines[line]) else { return nil }
        let opener = "^(on|am|le|el|il|op|em|den|в|w)\\s"
        guard line > 0, !lines[line - 1].trimmed.isEmpty,
              lines[line].trimmed.range(of: opener, options: [.regularExpression, .caseInsensitive]) == nil,
              lines[line - 1].trimmed.range(of: opener, options: [.regularExpression, .caseInsensitive]) != nil,
              isAttribution(lines[line - 1] + " " + lines[line]) else { return line }
        return line - 1
    }

    // MARK: - Shared

    private static let originalMessage =
        "original message|ursprüngliche nachricht|message d'origine|oorspronkelijk bericht|mensaje original|исходное сообщение"

    private static let attributionVerbs =
        "\\b(wrote|writes|schrieb|schrieben|a écrit|escribió|ha scritto|schreef|escreveu|написал|написала|yazdı|yazıb|yazmış|yazdılar)\\b"

    /// "On 24 Sep 2026, at 16:02, Sam <sam@example.com> wrote:" and its kind in other languages.
    static func isAttribution(_ text: String) -> Bool {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.hasSuffix(":"), line.count <= 400 else { return false }
        return line.range(of: attributionVerbs, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Whether `quoted` holds the opening words of one of the earlier messages.
    static func repeats(_ quoted: String, _ earlier: [String]) -> Bool {
        let haystack = " " + words(quoted).joined(separator: " ") + " "
        for text in earlier {
            let opening = words(text).prefix(openingWords)
            guard opening.count >= fewestWords else { continue }
            if haystack.contains(" " + opening.joined(separator: " ") + " ") { return true }
        }
        return false
    }

    private static func words(_ text: String) -> [Substring] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }
    }
}
