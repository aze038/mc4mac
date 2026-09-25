import Foundation

/// An original's HTML as a reply or forward quotes it: whole and unchanged below the heading,
/// but held so that nothing in it reaches the new text above it.
///
/// A message's `<style>` rules apply to the whole message it ends up in, and so, once an
/// original is quoted, to the reply written above it: its `p { margin }`, its `body { font }`,
/// its link colours. So every rule the original carries, in its head or its body, goes into the
/// reply's head scoped to the element that holds the quote (see ScopedCSS), and its body's own
/// attributes, its style, language, direction and colours, go onto that element. Everything
/// else is kept as it was: Word's MsoNormal paragraphs and their classes, its conditional
/// comments, in the body and in the head, and the VML they hold, whose namespaces the reply's
/// own `<html>` then declares.
public struct QuotedOriginal: Sendable, Equatable {
    /// The `xmlns:` attributes of the original's `<html>`, each with a space before it, as the
    /// reply's `<html>` declares them so Word reads the original's `o:`, `v:` and `w:` elements.
    public var namespaces: String
    /// What the reply's head takes: the original's rules, scoped, and its head's conditional
    /// comments, each once.
    public var head: String
    /// The original's body, in the element that holds it.
    public var body: String

    /// The class of the element that holds a quoted original. A quote inside a quote is held the
    /// same way, and its rules, scoped once already, are scoped again under the outer quote.
    public static let scopeClass = "fm-q"

    public init(namespaces: String, head: String, body: String) {
        self.namespaces = namespaces
        self.head = head
        self.body = body
    }

    /// `html` as a quote holds it; `style` is added to the holding element's own style, as the
    /// indent a reply's original may be set in by.
    public init(html: String, style: String = "") {
        let s = html as NSString
        // A body tag is the document's own only when nothing but a head comes before it; one
        // further in belongs to a document an earlier reply held inside its own.
        let bodyTag = QuotedOriginal.firstTag("body", in: s, from: 0).flatMap {
            QuotedOriginal.isHead(s.substring(to: $0.location)) ? $0 : nil
        }
        var headEnd = 0
        var contentStart = 0
        if let bodyTag {
            headEnd = bodyTag.location
            contentStart = NSMaxRange(bodyTag)
        } else {
            let closing = s.range(of: "</head>", options: .caseInsensitive)
            if closing.location != NSNotFound {
                headEnd = closing.location
                contentStart = NSMaxRange(closing)
            }
        }
        var contentEnd = s.length
        let closingBody = s.range(of: "</body>", options: [.caseInsensitive, .backwards])
        if bodyTag != nil, closingBody.location != NSNotFound, closingBody.location >= contentStart { contentEnd = closingBody.location }

        var styles: [String] = []
        var conditionals: [String] = []
        QuotedOriginal.scan(s, range: NSRange(location: 0, length: headEnd)) { kind, range, content in
            switch kind {
            case .style: styles.append(content)
            case .comment:
                let comment = s.substring(with: range)
                if comment.hasPrefix("<!--[if"), !conditionals.contains(comment) { conditionals.append(comment) }
            }
        }
        var body = ""
        var position = contentStart
        QuotedOriginal.scan(s, range: NSRange(location: contentStart, length: max(0, contentEnd - contentStart))) { kind, range, content in
            guard kind == .style else { return }
            styles.append(content)
            body += s.substring(with: NSRange(location: position, length: range.location - position))
            position = NSMaxRange(range)
        }
        body += s.substring(with: NSRange(location: position, length: max(0, contentEnd - position)))
        body = body.replacingOccurrences(of: "(?is)<script\\b[^>]*>.*?</script\\s*>", with: "", options: .regularExpression)
        body = body.replacingOccurrences(of: "(?is)<title\\b[^>]*>.*?</title\\s*>", with: "", options: .regularExpression)
        // A document held inside keeps what its body said, as the element that now holds it.
        body = body.replacingOccurrences(of: "(?i)<body\\b", with: "<div", options: .regularExpression)
        body = body.replacingOccurrences(of: "(?i)</body\\s*>", with: "</div>", options: .regularExpression)
        body = body.replacingOccurrences(of: "(?i)</?(html|head)\\b[^>]*>", with: "", options: .regularExpression)
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)

        let attributes = bodyTag.map { HTMLAttributes.parse(s.substring(with: $0)) } ?? [:]
        var rules = ""
        for (attribute, pseudo) in [("link", "link"), ("vlink", "visited"), ("alink", "active")] {
            if let colour = attributes[attribute].flatMap(QuotedOriginal.cssColour) {
                rules += "body a:\(pseudo){color:\(colour)}"
            }
        }
        let sheet = (styles + [rules]).joined(separator: "\n")
        let scoped = ScopedCSS.scope(sheet, to: "." + QuotedOriginal.scopeClass)

        var declarations: [String] = []
        if let ground = attributes["bgcolor"].flatMap(QuotedOriginal.cssColour) { declarations.append("background-color:\(ground)") }
        if let text = attributes["text"].flatMap(QuotedOriginal.cssColour) { declarations.append("color:\(text)") }
        if let own = attributes["style"]?.trimmed, !own.isEmpty { declarations.append(own.hasSuffix(";") ? String(own.dropLast()) : own) }
        if !style.isEmpty { declarations.append(style) }
        var classes: [String] = []
        if !scoped.isEmpty { classes.append(QuotedOriginal.scopeClass) }
        if let own = attributes["class"]?.trimmed, !own.isEmpty { classes.append(own) }
        var open = "<div"
        if !classes.isEmpty { open += " class=\"\(HTMLText.escape(classes.joined(separator: " ")))\"" }
        for name in ["lang", "dir"] {
            if let value = attributes[name]?.trimmed, !value.isEmpty { open += " \(name)=\"\(HTMLText.escape(value))\"" }
        }
        if !declarations.isEmpty { open += " style=\"\(HTMLText.escape(declarations.joined(separator: ";")))\"" }
        open += ">"

        self.body = open + body + "</div>"
        self.head = ScopedCSS.sheets(scoped).map { "<style>\($0)</style>" }.joined() + conditionals.joined()
        let htmlTag = QuotedOriginal.firstTag("html", in: s, from: 0).map { s.substring(with: $0) } ?? ""
        self.namespaces = HTMLAttributes.parse(htmlTag)
            .filter { $0.key.hasPrefix("xmlns:") }
            .sorted { $0.key < $1.key }
            .map { " \($0.key)=\"\(HTMLText.escape($0.value))\"" }
            .joined()
    }

    // MARK: - reading the original

    /// Whether `prefix` holds nothing a reader shows: only a head, its comments, styles and tags.
    private static func isHead(_ prefix: String) -> Bool {
        var rest = prefix.replacingOccurrences(of: "(?s)<!--.*?-->", with: "", options: .regularExpression)
        rest = rest.replacingOccurrences(of: "(?is)<(style|script|title|xml)\\b[^>]*>.*?</\\1\\s*>", with: "", options: .regularExpression)
        rest = rest.replacingOccurrences(of: "(?i)<(!doctype|/?html|/?head|meta|link|base|\\?xml)\\b[^>]*>", with: "", options: .regularExpression)
        return rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private enum Found { case style, comment }

    /// Each `<style>` element and each comment in `range`, in order, a style inside a comment
    /// being part of the comment: Word hides VML's styles from every reader but itself that way.
    private static func scan(_ s: NSString, range: NSRange, _ found: (Found, NSRange, String) -> Void) {
        var location = range.location
        let end = NSMaxRange(range)
        var nextStyle = firstTag("style", in: s, from: location, before: end)
        while location < end {
            let rest = NSRange(location: location, length: end - location)
            let comment = s.range(of: "<!--", options: [], range: rest)
            if let found = nextStyle, found.location < location { nextStyle = firstTag("style", in: s, from: location, before: end) }
            let style = nextStyle
            if comment.location != NSNotFound, style.map({ comment.location < $0.location }) ?? true {
                let after = NSRange(location: NSMaxRange(comment), length: end - NSMaxRange(comment))
                let close = s.range(of: "-->", options: [], range: after)
                let stop = close.location == NSNotFound ? end : NSMaxRange(close)
                found(.comment, NSRange(location: comment.location, length: stop - comment.location), "")
                location = stop
            } else if let style {
                let after = NSRange(location: NSMaxRange(style), length: end - NSMaxRange(style))
                let close = s.range(of: "</style", options: .caseInsensitive, range: after)
                guard close.location != NSNotFound else {
                    found(.style, NSRange(location: style.location, length: end - style.location), s.substring(with: after))
                    return
                }
                let gt = s.range(of: ">", options: [], range: NSRange(location: NSMaxRange(close), length: end - NSMaxRange(close)))
                let stop = gt.location == NSNotFound ? end : NSMaxRange(gt)
                let content = s.substring(with: NSRange(location: NSMaxRange(style), length: close.location - NSMaxRange(style)))
                found(.style, NSRange(location: style.location, length: stop - style.location), content)
                location = stop
            } else {
                return
            }
        }
    }

    /// The first start tag `<name …>` at or after `from`, not `<names…>`.
    private static func firstTag(_ name: String, in s: NSString, from: Int, before end: Int? = nil) -> NSRange? {
        let limit = end ?? s.length
        var location = from
        while location < limit {
            let found = s.range(of: "<" + name, options: .caseInsensitive, range: NSRange(location: location, length: limit - location))
            guard found.location != NSNotFound else { return nil }
            let next = NSMaxRange(found)
            if next < s.length, let scalar = UnicodeScalar(s.character(at: next)),
               CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar == ">" || scalar == "/" {
                let gt = s.range(of: ">", options: [], range: NSRange(location: next, length: s.length - next))
                guard gt.location != NSNotFound else { return nil }
                return NSRange(location: found.location, length: NSMaxRange(gt) - found.location)
            }
            location = next
        }
        return nil
    }

    /// A colour attribute as CSS: `#0563C1` and `blue` as they are, `0563C1` with its `#`.
    private static func cssColour(_ value: String) -> String? {
        let trimmed = value.trimmed
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "#" }) else { return nil }
        if trimmed.count == 6, trimmed.allSatisfy(\.isHexDigit) { return "#" + trimmed }
        return trimmed
    }
}

/// An HTML start tag's attributes, by lower-cased name, their entities read.
enum HTMLAttributes {
    static func parse(_ tag: String) -> [String: String] {
        var result: [String: String] = [:]
        let text = tag as NSString
        for match in pattern.matches(in: tag, range: NSRange(location: 0, length: text.length)) {
            let name = text.substring(with: match.range(at: 1)).lowercased()
            guard result[name] == nil else { continue }
            var value = ""
            for group in 2...4 where match.range(at: group).location != NSNotFound {
                value = text.substring(with: match.range(at: group))
                break
            }
            result[name] = decoded(value)
        }
        return result
    }

    private static let pattern = try! NSRegularExpression(
        pattern: "\\s([A-Za-z_:][-A-Za-z0-9_:.]*)(?:\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+)))?")

    private static func decoded(_ value: String) -> String {
        guard value.contains("&") else { return value }
        return value.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
