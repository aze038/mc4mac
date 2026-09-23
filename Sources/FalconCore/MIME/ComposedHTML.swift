import AppKit

/// The composer's rich text as the HTML part that is sent.
///
/// The composer draws text, and the lines of the tables it inserts, in the system's label
/// colour so both read in either appearance. AppKit's HTML writer would put that colour down as
/// a translucent near-black. What goes out instead is what Outlook sends: text in the automatic
/// colour carries no colour, so the reader's default applies, and table lines in a colour that
/// follows the appearance become Table Grid's solid black. Colours chosen by hand are kept.
public enum ComposedHTML {
    /// The HTML part of a message from the composer: its rich text when it has any, else its
    /// plain text. A reply or forward whose body still ends with the quoted original sends the
    /// original's own HTML in place of that plain copy.
    public static func document(rtf: Data?, plain: String, historyPlain: String, historyHTML: String) -> String {
        let style = "font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:14px"
        if let rtf, let rich = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                        documentAttributes: nil) {
            // The original is found at the end of the rich text itself and cut off there. A length
            // taken from the plain body would not fit: counted in characters it misses the second
            // UTF-16 unit of every emoji, counted in UTF-16 units it keeps the carriage returns and
            // pictures that RTF leaves out, and either way the difference comes off the end of the
            // user's own text, usually the signature.
            if !historyHTML.isEmpty, let start = ComposedBody.historyStart(in: rich.string, history: historyPlain),
               let own = start == 0 ? "" : html(from: rich.attributedSubstring(from: NSRange(location: 0, length: start))) {
                return "<html><body style=\"\(style)\">\(own)\(historyHTML)</body></html>"
            }
            if let whole = html(from: rich) {
                return "<html><body style=\"\(style)\">\(whole)</body></html>"
            }
        }
        if !historyHTML.isEmpty, !historyPlain.isEmpty, plain.hasSuffix(historyPlain) {
            let own = String(plain.dropLast(historyPlain.count))
            return "<html><body style=\"\(style)\"><div style=\"white-space:pre-wrap\">\(HTMLText.escape(own))</div>\(historyHTML)</body></html>"
        }
        return "<html><body style=\"\(style);white-space:pre-wrap\">\(HTMLText.escape(plain))</body></html>"
    }

    public static func html(from text: NSAttributedString) -> String? {
        let prepared = forSending(text)
        let options: [NSAttributedString.DocumentAttributeKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
            .excludedElements: ["doctype", "XML", "meta", "style", "title", "head"]
        ]
        guard let data = try? prepared.data(from: NSRange(location: 0, length: prepared.length), documentAttributes: options) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// A copy with automatic text colours removed and appearance-dependent table lines made
    /// black. The text's own blocks are left alone: every block is copied once, so paragraphs
    /// that shared a cell still share it.
    static func forSending(_ text: NSAttributedString) -> NSAttributedString {
        let output = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: output.length)
        var copies: [ObjectIdentifier: NSTextBlock] = [:]
        output.beginEditing()
        output.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
            if let colour = value as? NSColor, isAutomatic(colour) { output.removeAttribute(.foregroundColor, range: range) }
        }
        output.enumerateAttribute(.paragraphStyle, in: whole) { value, range, _ in
            guard let style = value as? NSParagraphStyle, style.textBlocks.contains(where: hasAppearanceBorder),
                  let sent = style.mutableCopy() as? NSMutableParagraphStyle else { return }
            sent.textBlocks = style.textBlocks.map { block in
                guard hasAppearanceBorder(block) else { return block }
                if let copy = copies[ObjectIdentifier(block)] { return copy }
                let copy = (block.copy() as? NSTextBlock) ?? block
                for edge in edges where copy.borderColor(for: edge).map(followsAppearance) == true {
                    copy.setBorderColor(.black, for: edge)
                }
                copies[ObjectIdentifier(block)] = copy
                return copy
            }
            output.addAttribute(.paragraphStyle, value: sent, range: range)
        }
        output.endEditing()
        return output
    }

    private static let edges: [NSRectEdge] = [.minX, .minY, .maxX, .maxY]

    private static let automaticNames: Set<String> = ["labelColor", "textColor", "controlTextColor"]

    static func isAutomatic(_ colour: NSColor) -> Bool {
        colour.type == .catalog && colour.catalogNameComponent == "System" && automaticNames.contains(colour.colorNameComponent)
    }

    /// System and dynamic colours are catalogue colours; a colour picked by hand is not.
    static func followsAppearance(_ colour: NSColor) -> Bool {
        colour.type == .catalog
    }

    private static func hasAppearanceBorder(_ block: NSTextBlock) -> Bool {
        edges.contains { edge in block.borderColor(for: edge).map(followsAppearance) == true }
    }
}
