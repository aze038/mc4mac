import AppKit

/// The composer's body as a reply or forward holds it: the user's own text, then the original
/// quoted as plain text (the history). What is sent swaps that plain copy for the original's
/// own HTML, which it can only do while the body still ends with the history, so what the
/// ribbon inserts goes into the user's text and never into or after the original.
public enum ComposedBody {
    /// Where the history begins, in the UTF-16 units a text view counts in, while the text still
    /// ends with it.
    ///
    /// A body that has been through RTF, as a draft reopened from its store and the rich text
    /// that is sent both have, no longer holds the history exactly as it was quoted: RTF drops
    /// bidi embeddings, NULs and object characters, composes accented letters and turns
    /// paragraph separators and carriage returns into line feeds. So the history is looked for
    /// as it was quoted and then as the same trip through RTF gives it back.
    public static func historyStart(in text: String, history: String) -> Int? {
        guard !history.isEmpty else { return nil }
        let travelled = throughRTF(history)
        return start(of: history, endingThe: text) ?? start(of: travelled, endingThe: text)
            ?? equivalentStart(of: history, endingThe: text) ?? equivalentStart(of: travelled, endingThe: text)
    }

    /// The same, comparing canonically equivalent text as equal. RTF composes decomposed letters
    /// only within one run of formatting, so kana with a separate voicing mark or Hangul written
    /// as jamo, common in file names made on a Mac, can come back composed in one place and not
    /// in another. Equivalent strings have the same number of characters, so the history's
    /// length in characters, counted back from the end, finds where it begins.
    private static func equivalentStart(of tail: String, endingThe text: String) -> Int? {
        guard !tail.isEmpty, text.hasSuffix(tail),
              let index = text.index(text.endIndex, offsetBy: -tail.count, limitedBy: text.startIndex) else { return nil }
        return text.utf16.distance(from: text.utf16.startIndex, to: index.samePosition(in: text.utf16) ?? index)
    }

    /// The body as a draft keeps it: RTF, which every build reads, and beside it, only while the
    /// body holds pictures, flat RTFD, which keeps them. A build from before pictures were kept
    /// reads the RTF alone and opens the draft with its text and formatting, the pictures left
    /// out; a body without pictures is kept exactly as those builds kept it.
    public static func stored(_ text: NSAttributedString) -> (rtf: Data?, rtfd: Data?) {
        let whole = NSRange(location: 0, length: text.length)
        let rtf = text.rtf(from: whole, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        guard InlinePictures.hasPictures(text) else { return (rtf, nil) }
        return (rtf, text.rtfd(from: whole, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]))
    }

    /// The body a draft keeps, from its RTFD when it has one this build can read, else from its
    /// RTF; nil for a plain body.
    public static func text(rtf: Data?, rtfd: Data?) -> NSAttributedString? {
        if let rtfd, let text = try? NSAttributedString(data: rtfd, options: [.documentType: NSAttributedString.DocumentType.rtfd],
                                                         documentAttributes: nil) {
            return text
        }
        guard let rtf else { return nil }
        return try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
    }

    /// Plain text as it reads once written to RTF and read back, the trip the composer's body
    /// made to its draft store and to what is sent before drafts kept their pictures, and still
    /// makes in a draft an earlier build kept.
    static func throughRTF(_ plain: String) -> String {
        let text = NSAttributedString(string: plain)
        guard let data = text.rtf(from: NSRange(location: 0, length: text.length),
                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]),
              let read = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                 documentAttributes: nil) else { return plain }
        return read.string
    }

    private static func start(of tail: String, endingThe text: String) -> Int? {
        let units = text.utf16, tail = tail.utf16
        guard !tail.isEmpty, units.count >= tail.count, units.suffix(tail.count).elementsEqual(tail) else { return nil }
        return units.count - tail.count
    }

    /// Where an insertion lands: at the caret, or just before the history when the caret is in
    /// it or after it.
    public static func insertionPoint(for caret: Int, in text: String, history: String) -> Int {
        guard let start = historyStart(in: text, history: history) else { return caret }
        return min(caret, start)
    }

    public static func startsParagraph(at location: Int, in text: String) -> Bool {
        let string = text as NSString
        guard location > 0, location <= string.length else { return true }
        return string.paragraphRange(for: NSRange(location: location, length: 0)).location == location
    }

    /// Puts a signature in after the caret, or above the original when the caret is in it, in
    /// the formatting found there, as one step Undo takes back. Selected text stays.
    @MainActor
    public static func insertSignature(_ block: String, into editor: NSTextView, before history: String) {
        insertSignature(NSAttributedString(string: block), into: editor, before: history)
    }

    /// The same for a signature with formatting of its own, which it keeps; what it leaves
    /// unsaid, and a table cell it lands in, come from where it goes.
    @MainActor
    public static func insertSignature(_ block: NSAttributedString, into editor: NSTextView, before history: String) {
        guard let storage = editor.textStorage, block.length > 0 else { return }
        let location = insertionPoint(for: NSMaxRange(editor.selectedRange()), in: storage.string, history: history)
        let text = NSMutableAttributedString(string: startsParagraph(at: location, in: storage.string) ? "" : "\n")
        text.append(block)
        let range = NSRange(location: location, length: 0)
        editor.breakUndoCoalescing()
        guard editor.shouldChangeText(in: range, replacementString: text.string) else { return }
        let inserted = filling(text, with: attributes(at: location, in: editor))
        storage.replaceCharacters(in: range, with: inserted)
        editor.didChangeText()
        editor.undoManager?.setActionName("Insert Signature")
        editor.setSelectedRange(NSRange(location: location + inserted.length, length: 0))
    }

    /// Puts a picture in at the caret, in place of what is selected, or above the original when
    /// the caret is in it, as one step Undo takes back, and leaves the caret after it. Pictures
    /// from the Pictures button, in the composer and in the signature editor, go in here.
    @MainActor
    public static func insertPicture(_ attachment: NSTextAttachment, into editor: NSTextView, before history: String) {
        guard let storage = editor.textStorage else { return }
        var range = editor.selectedRange()
        let location = insertionPoint(for: range.location, in: storage.string, history: history)
        if location != range.location { range = NSRange(location: location, length: 0) }
        var own = attributes(at: location, in: editor)
        own[.attachment] = attachment
        let picture = NSAttributedString(string: "\u{FFFC}", attributes: own)
        editor.breakUndoCoalescing()
        guard editor.shouldChangeText(in: range, replacementString: picture.string) else { return }
        storage.replaceCharacters(in: range, with: picture)
        editor.didChangeText()
        editor.undoManager?.setActionName("Insert Picture")
        editor.setSelectedRange(NSRange(location: range.location + picture.length, length: 0))
    }

    /// A message's body as it opens: `lead`, the signature, then `tail`, a reply's quoted
    /// original. A signature without formatting of its own gives plain text alone, exactly as an
    /// account's signature always did; one with formatting also gives the rich text, the rest of
    /// it set in `attributes`.
    public static func opening(lead: String, signature: Signature?, tail: String,
                               attributes: [NSAttributedString.Key: Any]) -> (plain: String, rich: NSAttributedString?) {
        guard let signature, !signature.isBlank else { return (lead + tail, nil) }
        guard signature.rich != nil else { return (lead + signature.block.string + tail, nil) }
        let text = NSMutableAttributedString(string: lead)
        text.append(signature.block)
        text.append(NSAttributedString(string: tail))
        let rich = filling(text, with: attributes)
        return (rich.string, rich)
    }

    /// `text` with `base` wherever it says nothing of its own. A table cell in `base` holds every
    /// paragraph of it, so a signature put in a cell stays in the cell.
    public static func filling(_ text: NSAttributedString, with base: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let output = NSMutableAttributedString(attributedString: text)
        let blocks = (base[.paragraphStyle] as? NSParagraphStyle)?.textBlocks ?? []
        output.beginEditing()
        output.enumerateAttributes(in: NSRange(location: 0, length: output.length)) { own, range, _ in
            var merged = base.merging(own) { _, mine in mine }
            if !blocks.isEmpty, let style = own[.paragraphStyle] as? NSParagraphStyle,
               let placed = style.mutableCopy() as? NSMutableParagraphStyle {
                placed.textBlocks = blocks
                merged[.paragraphStyle] = placed
            }
            output.setAttributes(merged, range: range)
        }
        output.endEditing()
        return output
    }

    /// Inserts Outlook's Table Grid (see ComposedTable) as wide as the room at the caret allows,
    /// its lines in `lines` and its text in the formatting at the caret. Nothing selected is
    /// replaced: the table goes in after the selection, or above the original, on its own
    /// paragraph, and the caret lands in its first cell.
    @MainActor
    public static func insertTable(rows: Int, columns: Int, into editor: NSTextView, before history: String,
                                   font: NSFont, lines: NSColor) {
        guard let storage = editor.textStorage, rows > 0, columns > 0 else { return }
        let location = insertionPoint(for: NSMaxRange(editor.selectedRange()), in: storage.string, history: history)
        var attributes = attributes(at: location, in: editor)
        attributes[.font] = attributes[.font] ?? font
        attributes[.foregroundColor] = attributes[.foregroundColor] ?? NSColor.labelColor
        let blocks = (attributes[.paragraphStyle] as? NSParagraphStyle)?.textBlocks ?? []
        let bodyWidth = textWidth(of: editor)
        let room = cellWidth(at: location, inside: blocks, of: editor) ?? bodyWidth
        let width = ComposedTable.width(room: room, body: bodyWidth, columns: columns)

        let body = NSMutableAttributedString()
        if !startsParagraph(at: location, in: storage.string) {
            body.append(NSAttributedString(string: "\n", attributes: attributes))
        }
        let tableStart = body.length
        body.append(ComposedTable.grid(rows: rows, columns: columns, width: width, lines: lines, attributes: attributes))
        // A table at the very end would leave nowhere to type below it.
        if location == storage.length {
            body.append(NSAttributedString(string: "\n", attributes: attributes))
        }
        let range = NSRange(location: location, length: 0)
        editor.breakUndoCoalescing()
        guard editor.shouldChangeText(in: range, replacementString: body.string) else { return }
        storage.replaceCharacters(in: range, with: body)
        editor.didChangeText()
        editor.undoManager?.setActionName("Insert Table")
        editor.setSelectedRange(NSRange(location: location + tableStart, length: 0))
        editor.window?.makeFirstResponder(editor)
    }

    /// Outlook's most columns a table can have, as Insert Table allows.
    public static let mostTableColumns = 63

    /// What Convert Text to Table would turn into a table: the whole paragraphs the selection
    /// touches, stopping short of the original, when the selection is in the user's own text and
    /// holds only text outside any table. Nil when there is nothing it can convert, which is what
    /// dims the menu item.
    @MainActor
    public static func convertibleRange(in editor: NSTextView, before history: String) -> NSRange? {
        guard let storage = editor.textStorage else { return nil }
        let selection = editor.selectedRange()
        guard selection.length > 0, NSMaxRange(selection) <= storage.length else { return nil }
        let text = storage.string as NSString
        var range = text.paragraphRange(for: selection)
        if let start = historyStart(in: storage.string, history: history) {
            guard selection.location < start else { return nil }
            range.length = min(NSMaxRange(range), start) - range.location
        }
        guard range.length > 0 else { return nil }
        var plain = true
        storage.enumerateAttributes(in: range) { attributes, _, stop in
            let inTable = !((attributes[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.isEmpty ?? true)
            if inTable || attributes[.attachment] != nil {
                plain = false
                stop.pointee = true
            }
        }
        let cells = ComposedTable.cells(from: text.substring(with: range))
        guard plain, let columns = cells.first?.count, columns <= mostTableColumns else { return nil }
        return range
    }

    /// Replaces the paragraphs `convertibleRange` finds with Outlook's Table Grid holding their
    /// text, as one step Undo takes back; the caret lands in the first cell. Each cell keeps its
    /// text's own formatting and links, so nothing the recipient would have had is lost; the
    /// paragraph breaks and the cells padding short rows take the formatting where the text
    /// starts.
    @MainActor
    public static func convertToTable(in editor: NSTextView, before history: String, font: NSFont, lines: NSColor) {
        guard let range = convertibleRange(in: editor, before: history), let storage = editor.textStorage else { return }
        let contents = ComposedTable.cellRanges(in: (storage.string as NSString).substring(with: range)).map { row in
            row.map { storage.attributedSubstring(from: NSRange(location: range.location + $0.location, length: $0.length)) }
        }
        guard let columns = contents.first?.count else { return }
        var attributes = storage.attributes(at: range.location, effectiveRange: nil)
        attributes[.link] = nil
        attributes[.font] = attributes[.font] ?? font
        attributes[.foregroundColor] = attributes[.foregroundColor] ?? NSColor.labelColor
        let bodyWidth = textWidth(of: editor)
        let width = ComposedTable.width(room: bodyWidth, body: bodyWidth, columns: columns)
        let table = NSMutableAttributedString(attributedString: ComposedTable.grid(rows: contents.count, columns: columns, width: width,
                                                                                   lines: lines, attributes: attributes, contents: contents))
        // A table at the very end would leave nowhere to type below it.
        if NSMaxRange(range) == storage.length {
            table.append(NSAttributedString(string: "\n", attributes: attributes))
        }
        editor.breakUndoCoalescing()
        guard editor.shouldChangeText(in: range, replacementString: table.string) else { return }
        storage.replaceCharacters(in: range, with: table)
        editor.didChangeText()
        editor.undoManager?.setActionName("Convert Text to Table")
        editor.setSelectedRange(NSRange(location: range.location, length: 0))
        editor.window?.makeFirstResponder(editor)
    }

    /// The caret's formatting, or, when the insertion was moved out of the original, the
    /// formatting where the original starts: the character before it may close a table cell, and
    /// its paragraph would draw the insertion into that cell.
    @MainActor
    private static func attributes(at location: Int, in editor: NSTextView) -> [NSAttributedString.Key: Any] {
        var attributes = editor.typingAttributes
        if let storage = editor.textStorage, location != NSMaxRange(editor.selectedRange()), location < storage.length {
            attributes = storage.attributes(at: location, effectiveRange: nil)
        }
        attributes[.link] = nil
        attributes[.attachment] = nil
        return attributes
    }

    /// The width of the body's text.
    @MainActor
    private static func textWidth(of editor: NSTextView) -> CGFloat {
        let container = editor.textContainer
        return (container?.size.width ?? 0) - 2 * (container?.lineFragmentPadding ?? 0)
    }

    /// The width of the text in the innermost table cell at `location`, as it is laid out, so a
    /// table inserted in a cell stays inside it; nil outside a table.
    @MainActor
    private static func cellWidth(at location: Int, inside blocks: [NSTextBlock], of editor: NSTextView) -> CGFloat? {
        guard let cell = blocks.last(where: { $0 is NSTextTableBlock }), let storage = editor.textStorage,
              let layout = editor.layoutManager, storage.length > 0 else { return nil }
        let range = storage.range(of: cell, at: min(location, storage.length - 1))
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        layout.ensureLayout(forGlyphRange: glyphs)
        let laid = layout.layoutRect(for: cell, glyphRange: glyphs).width
        return laid > 0 ? laid : nil
    }
}
