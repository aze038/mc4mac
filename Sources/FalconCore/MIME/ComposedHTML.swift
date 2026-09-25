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
    /// What the composer's body sends: the HTML part, the plain text part, and the pictures the
    /// HTML shows, each once, which go beside it as inline parts in multipart/related.
    public struct Content: Sendable {
        public var html: String
        /// The plain text, with `[cid:…]` where each picture stands in the HTML, as Outlook
        /// writes it; no picture's bytes are in it.
        public var plain: String
        public var pictures: [InlinePicture]
    }

    /// The same, from a body as a draft keeps it (see ComposedBody.stored).
    public static func content(rtf: Data?, rtfd: Data? = nil, plain: String, historyPlain: String, historyHTML: String,
                               date: Date = Date(), font: ComposeFont = .outlook) -> Content {
        content(rich: ComposedBody.text(rtf: rtf, rtfd: rtfd), plain: plain, historyPlain: historyPlain, historyHTML: historyHTML,
                date: date, font: font)
    }

    /// The HTML part of a message from the composer: its rich text when it has any, else its
    /// plain text, as Outlook writes it (see CompactHTML), inside one element that declares
    /// `font`. A reply or forward whose body still ends with the quoted original sends the
    /// original's own HTML in place of that plain copy (see QuotedHistory), what it carries for
    /// the head in the head. Every picture, the composer's own and the original's, is sent as
    /// Outlook sends it: once, as an inline part named image001.png and on, the HTML showing it
    /// by `cid:` at the size it is shown in the composer. `date` is when the message is put
    /// together, which each picture's Content-ID carries.
    public static func content(rich: NSAttributedString?, plain: String, historyPlain: String, historyHTML: String,
                               date: Date = Date(), font: ComposeFont = .outlook) -> Content {
        var pictures = InlinePictures.Collector(date: date)
        let plainOwn = historyHTML.isEmpty ? nil
            : ComposedBody.historyStart(in: plain, history: historyPlain).map { (plain as NSString).substring(to: $0) }
        if let rich {
            if !historyHTML.isEmpty, let start = ownLength(of: rich, history: historyPlain, plainOwn: plainOwn) {
                var collected = pictures
                let own: (html: String, marks: [String])?
                if start == 0 {
                    own = ("", [])
                } else {
                    own = html(from: rich.attributedSubstring(from: NSRange(location: 0, length: start)), pictures: &collected)
                }
                if let own {
                    pictures = collected
                    let history = InlinePictures.sendingDataURIs(in: historyHTML, into: &pictures)
                    return Content(html: document(own: CompactHTML.compact(own.html, font: font), history: history, font: font),
                                   plain: plainText(plain, marks: own.marks), pictures: pictures.pictures)
                }
            }
            var collected = pictures
            if let whole = html(from: rich, pictures: &collected) {
                return Content(html: document(own: CompactHTML.compact(whole.html, font: font), history: "", font: font),
                               plain: plainText(plain, marks: whole.marks), pictures: collected.pictures)
            }
        }
        if let plainOwn {
            let history = InlinePictures.sendingDataURIs(in: historyHTML, into: &pictures)
            return Content(html: document(own: paragraphs(plainText(plainOwn, marks: [])), history: history, font: font),
                           plain: plainText(plain, marks: []), pictures: pictures.pictures)
        }
        let text = plainText(plain, marks: [])
        return Content(html: document(own: paragraphs(text), history: "", font: font), plain: text, pictures: [])
    }

    /// The HTML part alone, for a body as a draft keeps it.
    public static func document(rtf: Data?, rtfd: Data? = nil, plain: String, historyPlain: String, historyHTML: String,
                                font: ComposeFont = .outlook) -> String {
        content(rtf: rtf, rtfd: rtfd, plain: plain, historyPlain: historyPlain, historyHTML: historyHTML, font: font).html
    }

    /// The message: the user's own text in the element declaring `font`, then the history, the
    /// namespaces and head it carries on the document's own tags.
    static func document(own: String, history: String, font: ComposeFont) -> String {
        let parts = QuotedHistory.parts(of: history)
        let head = parts.head.isEmpty ? "" : "<head>\(parts.head)</head>"
        let text = own.isEmpty ? "" : "<div style=\"\(font.css)\">\(own)</div>"
        return "<html\(parts.namespaces)>\(head)<body>\(text)\(parts.body)</body></html>"
    }

    /// Plain text as paragraphs, the line break that ends it ending its last paragraph.
    private static func paragraphs(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        return QuotedHistory.paragraphs(text.hasSuffix("\n") ? String(text.dropLast()) : text)
    }

    /// `plain` with each object character, where the composer's text holds a picture, replaced
    /// in turn by the mark of the picture sent for it; one for which nothing is sent is taken
    /// out.
    private static func plainText(_ plain: String, marks: [String]) -> String {
        guard plain.contains("\u{FFFC}") else { return plain }
        var remaining = marks[...]
        var output = ""
        for character in plain {
            if character == "\u{FFFC}" {
                output += remaining.popFirst() ?? ""
            } else {
                output.append(character)
            }
        }
        return output
    }

    /// How much of the rich text, in UTF-16 units, is the user's own, when the body still ends
    /// with the original.
    ///
    /// The original is found at the end of the rich text itself. A length taken straight from
    /// the plain body would not fit a body read from RTF, as one kept by an earlier build is:
    /// counted in characters it misses the second UTF-16 unit of every emoji, counted in UTF-16
    /// units it keeps the carriage returns and pictures that RTF leaves out, and either way the
    /// difference comes off the end of the user's own text, usually the signature. RTF can still
    /// set the original down in the body otherwise than on its own, since it cuts a NUL's run
    /// short and composes an accent only within one run of formatting; the plain body then says
    /// where the user's text ends, measured as RTF gives that text back.
    private static func ownLength(of rich: NSAttributedString, history: String, plainOwn: String?) -> Int? {
        if let start = ComposedBody.historyStart(in: rich.string, history: history) { return start }
        return plainOwn.map { min(ComposedBody.throughRTF($0).utf16.count, rich.length) }
    }

    /// `text` as HTML, each picture in it collected into `pictures` and shown by `cid:`, each
    /// box standing for a picture from the web that was not fetched shown from its address, and
    /// what the plain text says for each of its pictures in turn.
    ///
    /// The writer would put a picture down as a file beside the page, by a name two pictures can
    /// share and at no size, so each is held out of its way: every picture is written as a word
    /// no text holds, which keeps the picture's place and formatting, a link on it included, and
    /// that word is then replaced by the picture's tag.
    static func html(from text: NSAttributedString, pictures: inout InlinePictures.Collector) -> (html: String, marks: [String])? {
        let located = InlinePictures.attachmentLocations(in: text)
        guard !located.isEmpty else { return html(from: text).map { ($0, []) } }
        let marked = NSMutableAttributedString(attributedString: text)
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var tags: [(word: String, tag: String)] = []
        var marks: [String] = []
        for (index, (_, attachment)) in located.enumerated() {
            // A picture from the web that was not fetched goes as the original's tag did, from
            // its address, and the plain text says nothing for it.
            if let remote = RemotePictures.placeholder(of: attachment) {
                tags.append(("FalconMailPicture\(nonce)N\(index)E", RemotePictures.tag(for: remote)))
                marks.append("")
                continue
            }
            guard let picture = InlinePictures.picture(in: attachment) else {
                tags.append(("", ""))
                marks.append("")
                continue
            }
            let sent = pictures.add(picture.data, picture.format)
            tags.append(("FalconMailPicture\(nonce)N\(index)E", InlinePictures.tag(for: sent, size: picture.size)))
            marks.append(InlinePictures.plainMark(for: sent))
        }
        marked.beginEditing()
        for ((location, _), word) in zip(located, tags.map(\.word)).reversed() {
            let range = NSRange(location: location, length: 1)
            var attributes = marked.attributes(at: location, effectiveRange: nil)
            attributes[.attachment] = nil
            marked.replaceCharacters(in: range, with: NSAttributedString(string: word, attributes: attributes))
        }
        marked.endEditing()
        guard var written = html(from: marked) else { return nil }
        for (word, tag) in tags where !word.isEmpty {
            written = written.replacingOccurrences(of: word, with: tag)
        }
        return (written, marks)
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
