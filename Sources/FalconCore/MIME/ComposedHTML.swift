import AppKit

/// The composer's rich text as the HTML part that is sent.
///
/// The composer draws text, and the lines of the tables it inserts, in the system's label
/// colour so both read in either appearance. AppKit's HTML writer would put that colour down as
/// a translucent near-black. What goes out instead is what Outlook sends: text in the automatic
/// colour carries no colour, so the reader's default applies, and table lines in a colour that
/// follows the appearance become Table Grid's solid black. Colours chosen by hand go out as
/// exactly the sRGB colour that was chosen (see `SentColour`).
public enum ComposedHTML {
    /// The HTML part of a message from the composer: its rich text when it has any, else its
    /// plain text. A reply or forward whose body still ends with the quoted original sends the
    /// original's own HTML in place of that plain copy.
    public static func document(rtf: Data?, plain: String, historyPlain: String, historyHTML: String) -> String {
        let style = "font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:14px"
        let plainOwn = historyHTML.isEmpty ? nil
            : ComposedBody.historyStart(in: plain, history: historyPlain).map { (plain as NSString).substring(to: $0) }
        if let rtf, let rich = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                        documentAttributes: nil) {
            if !historyHTML.isEmpty, let start = ownLength(of: rich, history: historyPlain, plainOwn: plainOwn),
               let own = start == 0 ? "" : html(from: rich.attributedSubstring(from: NSRange(location: 0, length: start))) {
                return "<html><body style=\"\(style)\">\(own)\(historyHTML)</body></html>"
            }
            if let whole = html(from: rich) {
                return "<html><body style=\"\(style)\">\(whole)</body></html>"
            }
        }
        if let plainOwn {
            return "<html><body style=\"\(style)\"><div style=\"white-space:pre-wrap\">\(HTMLText.escape(plainOwn))</div>\(historyHTML)</body></html>"
        }
        return "<html><body style=\"\(style);white-space:pre-wrap\">\(HTMLText.escape(plain))</body></html>"
    }

    /// How much of the rich text, in UTF-16 units, is the user's own, when the body still ends
    /// with the original.
    ///
    /// The original is found at the end of the rich text itself. A length taken straight from
    /// the plain body would not fit: counted in characters it misses the second UTF-16 unit of
    /// every emoji, counted in UTF-16 units it keeps the carriage returns and pictures that RTF
    /// leaves out, and either way the difference comes off the end of the user's own text,
    /// usually the signature. RTF can still set the original down in the body otherwise than on
    /// its own, since it cuts a NUL's run short and composes an accent only within one run of
    /// formatting; the plain body then says where the user's text ends, measured as RTF gives
    /// that text back.
    private static func ownLength(of rich: NSAttributedString, history: String, plainOwn: String?) -> Int? {
        if let start = ComposedBody.historyStart(in: rich.string, history: history) { return start }
        return plainOwn.map { min(ComposedBody.throughRTF($0).utf16.count, rich.length) }
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

    /// A copy with automatic text colours removed, appearance-dependent table lines made black
    /// and every other colour, of the characters, their blocks and tables, made one the writer
    /// puts down as its exact sRGB value. The text's own attributes and blocks are left alone.
    static func forSending(_ text: NSAttributedString) -> NSAttributedString {
        let output = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: output.length)
        output.beginEditing()
        output.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
            guard let colour = value as? NSColor else { return }
            if isAutomatic(colour) {
                output.removeAttribute(.foregroundColor, range: range)
            } else {
                output.addAttribute(.foregroundColor, value: SentColour.forWriter(colour), range: range)
            }
        }
        // The writer leaves underline and strikethrough colours out, so a reader draws those
        // lines in the text's colour; they are made exact all the same, as nothing else is sent
        // shifted.
        for key: NSAttributedString.Key in [.backgroundColor, .underlineColor, .strikethroughColor, .strokeColor] {
            output.enumerateAttribute(key, in: whole) { value, range, _ in
                guard let colour = value as? NSColor else { return }
                output.addAttribute(key, value: SentColour.forWriter(colour), range: range)
            }
        }
        output.enumerateAttribute(.shadow, in: whole) { value, range, _ in
            guard let shadow = value as? NSShadow, let colour = shadow.shadowColor,
                  let sent = shadow.copy() as? NSShadow else { return }
            sent.shadowColor = SentColour.forWriter(colour)
            output.addAttribute(.shadow, value: sent, range: range)
        }
        let blocks = sentBlocks(in: output)
        if !blocks.isEmpty {
            output.enumerateAttribute(.paragraphStyle, in: whole) { value, range, _ in
                guard let style = value as? NSParagraphStyle, !style.textBlocks.isEmpty,
                      let sent = style.mutableCopy() as? NSMutableParagraphStyle else { return }
                sent.textBlocks = style.textBlocks.map { blocks[ObjectIdentifier($0)] ?? $0 }
                output.addAttribute(.paragraphStyle, value: sent, range: range)
            }
        }
        output.endEditing()
        return output
    }

    /// A recoloured copy of every block in `text`, and of every table its cells belong to, by the
    /// block it replaces.
    ///
    /// A cell's table cannot be swapped for another, and it carries colours of its own, the
    /// table's background and outer lines, so the blocks are copied through one keyed archive:
    /// that copies each cell with its table, keeping the paragraphs that share a cell and the
    /// cells that share a table sharing their copies, as the writer needs them to lay the table
    /// out, and changes nothing else about them.
    private static func sentBlocks(in text: NSAttributedString) -> [ObjectIdentifier: NSTextBlock] {
        var originals: [NSTextBlock] = []
        var seen = Set<ObjectIdentifier>()
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            for block in (value as? NSParagraphStyle)?.textBlocks ?? [] where seen.insert(ObjectIdentifier(block)).inserted {
                originals.append(block)
            }
        }
        // The archive is made and read here and nowhere else, so it is read without the checks
        // an archive from outside would need.
        guard !originals.isEmpty,
              let archive = try? NSKeyedArchiver.archivedData(withRootObject: originals as NSArray, requiringSecureCoding: false),
              let reader = try? NSKeyedUnarchiver(forReadingFrom: archive) else { return [:] }
        reader.requiresSecureCoding = false
        let decoded = reader.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? [NSTextBlock]
        reader.finishDecoding()
        guard let copies = decoded, copies.count == originals.count else { return [:] }
        var tables = Set<ObjectIdentifier>()
        for copy in copies {
            recolour(copy)
            if let cell = copy as? NSTextTableBlock, tables.insert(ObjectIdentifier(cell.table)).inserted { recolour(cell.table) }
        }
        return Dictionary(uniqueKeysWithValues: zip(originals.map(ObjectIdentifier.init), copies))
    }

    /// A block's, or a table's, background and lines in their exact sRGB, and lines in a colour
    /// that follows the appearance in Table Grid's black.
    private static func recolour(_ block: NSTextBlock) {
        if let background = block.backgroundColor { block.backgroundColor = SentColour.forWriter(background) }
        for edge in edges {
            guard let colour = block.borderColor(for: edge) else { continue }
            block.setBorderColor(SentColour.forWriter(followsAppearance(colour) ? .black : colour), for: edge)
        }
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
}
