import AppKit

/// The composer's body as a reply or forward holds it: the user's own text, then the original
/// quoted as plain text (the history). What is sent swaps that plain copy for the original's
/// own HTML, which it can only do while the body still ends with the history, so what the
/// ribbon inserts goes into the user's text and never into or after the original.
public enum ComposedBody {
    /// Where the history begins, in the UTF-16 units a text view counts in, while the text still
    /// ends with it.
    public static func historyStart(in text: String, history: String) -> Int? {
        guard !history.isEmpty else { return nil }
        let units = text.utf16, tail = history.utf16
        guard units.count >= tail.count, units.suffix(tail.count).elementsEqual(tail) else { return nil }
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
        guard let storage = editor.textStorage, !block.isEmpty else { return }
        let location = insertionPoint(for: NSMaxRange(editor.selectedRange()), in: storage.string, history: history)
        let text = (startsParagraph(at: location, in: storage.string) ? "" : "\n") + block
        let range = NSRange(location: location, length: 0)
        editor.breakUndoCoalescing()
        guard editor.shouldChangeText(in: range, replacementString: text) else { return }
        let inserted = NSAttributedString(string: text, attributes: attributes(at: location, in: editor))
        storage.replaceCharacters(in: range, with: inserted)
        editor.didChangeText()
        editor.undoManager?.setActionName("Insert Signature")
        editor.setSelectedRange(NSRange(location: location + inserted.length, length: 0))
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
        let width = ComposedTable.width(room: room(at: location, inside: blocks, of: editor), columns: columns)

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

    /// The width of the text a table at `location` would sit in: the innermost table cell there
    /// as it is laid out, so a table inserted in a cell stays inside it, or else the body's.
    @MainActor
    private static func room(at location: Int, inside blocks: [NSTextBlock], of editor: NSTextView) -> CGFloat {
        let container = editor.textContainer
        let body = (container?.size.width ?? 0) - 2 * (container?.lineFragmentPadding ?? 0)
        guard let cell = blocks.last(where: { $0 is NSTextTableBlock }), let storage = editor.textStorage,
              let layout = editor.layoutManager, storage.length > 0 else { return body }
        let range = storage.range(of: cell, at: min(location, storage.length - 1))
        guard range.location != NSNotFound, range.length > 0 else { return body }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        layout.ensureLayout(forGlyphRange: glyphs)
        let laid = layout.layoutRect(for: cell, glyphRange: glyphs).width
        return laid > 0 ? laid : body
    }
}
