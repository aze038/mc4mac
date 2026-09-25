import Foundation

/// The original a reply or forward carries below the new text, as Legacy Outlook for Mac
/// carries it: the heading (see ReplyHeader), then the original whole and unchanged, its own
/// earlier chain included.
public struct ReplyHistory: Equatable, Sendable {
    /// The heading as the composer shows it, from the empty line before it to the one after it.
    public var heading: String
    /// The heading and the original's text, as the plain text part sends them.
    public var plain: String
    /// What the HTML part sends for them while the original is untouched: `<html …><head>…</head>`
    /// with what the reply's own `<html>` and head must carry, then the heading and the original
    /// (see ComposedHTML).
    public var html: String

    public init(heading: String, plain: String, html: String) {
        self.heading = heading
        self.plain = plain
        self.html = html
    }

    /// `original`'s history: its heading in `attribution`, and its HTML, or its text when it has
    /// none, set in from the left with `indent`, the heading and a text original in `font`.
    public init(original: ReplyHeader.Original, html: String?, text: String, attribution: ReplyHeader.Attribution,
                indent: Bool, font: ComposeFont) {
        heading = ReplyHeader.plain(original, attribution: attribution)
        let trimmedText = text.trimmed
        let quotedText = indent
            ? trimmedText.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
            : trimmedText
        plain = heading + quotedText + "\n"

        let indentStyle = indent ? "border-left:3px solid #B5C4DF;padding-left:10px;margin-left:2px" : ""
        let quote: QuotedOriginal
        if let html, !html.trimmed.isEmpty {
            quote = QuotedOriginal(html: html, style: indentStyle)
        } else {
            let style = [font.css, indentStyle].filter { !$0.isEmpty }.joined(separator: ";")
            quote = QuotedOriginal(namespaces: "", head: "", body: "<div style=\"\(style)\">\(ReplyHistory.paragraphs(trimmedText))</div>")
        }
        self.html = "<html\(quote.namespaces)><head>\(quote.head)</head>"
            + ReplyHeader.html(original, attribution: attribution, font: font) + quote.body
    }

    /// Plain text as Outlook's paragraphs: one to a line, an empty line as `&nbsp;`, runs of
    /// spaces kept.
    public static func paragraphs(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let escaped = HTMLText.escape(String(line)).replacingOccurrences(of: "  ", with: "&nbsp; ")
            let kept = escaped.hasPrefix(" ") ? "&nbsp;" + escaped.dropFirst() : Substring(escaped)
            return "<p style=\"margin:0\">\(kept.isEmpty ? "&nbsp;" : String(kept))</p>"
        }.joined()
    }

    /// A history split into what the reply's `<html>` tag and head take and what its body takes;
    /// a history kept by an earlier build is all body.
    public static func parts(of html: String) -> (namespaces: String, head: String, body: String) {
        guard html.hasPrefix("<html"), let tagEnd = html.firstIndex(of: ">"),
              let headStart = html.range(of: "<head>"), headStart.lowerBound == html.index(after: tagEnd),
              let headEnd = html.range(of: "</head>", range: headStart.upperBound..<html.endIndex) else {
            return ("", "", html)
        }
        let namespaces = String(html[html.index(html.startIndex, offsetBy: 5)..<tagEnd])
        return (namespaces, String(html[headStart.upperBound..<headEnd.lowerBound]), String(html[headEnd.upperBound...]))
    }
}
