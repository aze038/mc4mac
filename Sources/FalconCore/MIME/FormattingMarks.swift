import AppKit

/// Word's marks for what does not print, as ¶ shows them in the composer and the signature
/// editor: a ¶ where each paragraph ends, a · for each space and a → for each tab. They are only
/// drawn over the text, never put into it, so nothing that is saved or sent can carry them.
enum FormattingMarks {
    struct Mark: Equatable {
        /// The character the mark stands for, in the UTF-16 units a text view counts in. The
        /// empty line after a final line break, or the one paragraph of an empty text, has no
        /// character of its own; its ¶ is at the text's length.
        var character: Int
        var symbol: String
        /// Drawn after the character rather than over the gap it leaves: the last paragraph has
        /// no line break of its own to mark.
        var after: Bool

        init(character: Int, symbol: String, after: Bool = false) {
            self.character = character
            self.symbol = symbol
            self.after = after
        }
    }

    static let paragraph = "¶"
    static let space = "·"
    static let tab = "→"

    /// The mark Word draws for `character`, if it draws one.
    static func symbol(for character: unichar) -> String? {
        switch character {
        case 0x0A, 0x2029: return paragraph
        case 0x20: return space
        case 0x09: return tab
        default: return nil
        }
    }

    /// Whether what follows `character` starts a new line: after a paragraph's line break, or
    /// the line break within a paragraph that Shift-Return types, the caret stands on the next
    /// line.
    static func breaksLine(_ character: unichar) -> Bool {
        switch character {
        case 0x0A, 0x0D, 0x2028, 0x2029: return true
        default: return false
        }
    }

    /// The marks for the characters of `range`, and, when it reaches the end of `text`, the ¶
    /// Word puts at the end of the last paragraph: after a last paragraph that has no line
    /// break, or on the empty line that follows a final line break of either kind, as on the
    /// one line of an empty text.
    static func marks(in text: NSString, range: NSRange) -> [Mark] {
        var marks: [Mark] = []
        for index in range.location..<NSMaxRange(range) {
            if let symbol = symbol(for: text.character(at: index)) { marks.append(Mark(character: index, symbol: symbol)) }
        }
        guard NSMaxRange(range) == text.length else { return marks }
        if text.length == 0 || breaksLine(text.character(at: text.length - 1)) {
            marks.append(Mark(character: text.length, symbol: paragraph))
        } else {
            marks.append(Mark(character: text.length - 1, symbol: paragraph, after: true))
        }
        return marks
    }
}

/// A layout manager that draws `FormattingMarks` over the text while `showsMarks` is on. It is
/// TextKit 1's, as the composer's and the signature editor's text views are.
open class FormattingMarksLayoutManager: NSLayoutManager {
    open var showsMarks = false {
        didSet {
            guard showsMarks != oldValue else { return }
            // The whole of each view, as the empty last line has no characters to invalidate.
            for container in textContainers { container.textView?.needsDisplay = true }
        }
    }

    /// A reply's or forward's quoted original, as its text begins, whose heading has Outlook's
    /// line drawn above it, as Outlook for Mac's composer shows it, as do the headings of the
    /// earlier replies in the chain below it. The lines are drawn, never put into the text.
    open var quotedHistory = "" {
        didSet {
            guard quotedHistory != oldValue else { return }
            ruledCharacters = nil
            for container in textContainers { container.textView?.needsDisplay = true }
        }
    }

    /// Outlook's line above a quoted original's heading: one point of #B5C4DF.
    public static let headingRuleColour = NSColor(srgbRed: 181 / 255, green: 196 / 255, blue: 223 / 255, alpha: 1)

    /// Where the lines go, found again only when the text changes.
    private var ruledCharacters: (heading: Int?, all: [Int])?

    /// The first character of the reply's own heading, From:, while the body holds that heading
    /// whole, even once the original below it has been edited; nil otherwise, as for a custom
    /// attribution.
    public var headingRuleCharacter: Int? { rulings().heading }

    /// The first character of each heading that has Outlook's line above it: the reply's own and
    /// each earlier one in the original below it (see ReplyHeader.headingStarts).
    public var headingRuleCharacters: [Int] { rulings().all }

    private func rulings() -> (heading: Int?, all: [Int]) {
        if let known = ruledCharacters { return known }
        var found: (heading: Int?, all: [Int]) = (nil, [])
        if !quotedHistory.isEmpty, let storage = textStorage {
            let text = storage.string
            let heading = ReplyHeader.headingStart(in: text, history: quotedHistory).flatMap { $0 < storage.length ? $0 : nil }
            if let from = heading ?? ComposedBody.historyStart(in: text, history: quotedHistory) {
                var all = ReplyHeader.headingStarts(in: text as NSString, from: from)
                if let heading, !all.contains(heading) { all.insert(heading, at: 0) }
                found = (heading, all)
            }
        }
        ruledCharacters = found
        return found
    }

    open override func processEditing(for textStorage: NSTextStorage, edited editMask: NSTextStorageEditActions, range newCharRange: NSRange,
                                      changeInLength delta: Int, invalidatedRange invalidatedCharRange: NSRange) {
        if editMask.contains(.editedCharacters) { ruledCharacters = nil }
        super.processEditing(for: textStorage, edited: editMask, range: newCharRange, changeInLength: delta,
                             invalidatedRange: invalidatedCharRange)
    }

    /// Each line above a heading, across the message at the top of the heading's first line,
    /// behind the text.
    open override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        for character in headingRuleCharacters {
            let glyphs = glyphRange(forCharacterRange: NSRange(location: character, length: 1), actualCharacterRange: nil)
            guard NSIntersectionRange(glyphs, glyphsToShow).length > 0, let rect = ruleRect(at: character) else { continue }
            FormattingMarksLayoutManager.headingRuleColour.setFill()
            rect.offsetBy(dx: origin.x, dy: origin.y).fill()
        }
    }

    /// The line above the reply's own heading, in its text container.
    public func headingRuleRect() -> NSRect? {
        headingRuleCharacter.flatMap(ruleRect(at:))
    }

    /// Every line, in the text container.
    public func headingRuleRects() -> [NSRect] {
        headingRuleCharacters.compactMap(ruleRect(at:))
    }

    /// A line one point high at the top of the line `character` is on, from where its paragraph
    /// is set in to the far side of the text, so it follows the window's width as a div's top
    /// border follows the message's.
    private func ruleRect(at character: Int) -> NSRect? {
        guard let storage = textStorage, character < storage.length else { return nil }
        let glyph = glyphIndexForCharacter(at: character)
        guard glyph < numberOfGlyphs, let container = textContainer(forGlyphAt: glyph, effectiveRange: nil) else { return nil }
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let style = storage.attribute(.paragraphStyle, at: character, effectiveRange: nil) as? NSParagraphStyle
        let indent = style.map { min($0.headIndent, $0.firstLineHeadIndent) } ?? 0
        let padding = container.lineFragmentPadding
        let x = line.minX + padding + max(0, indent)
        return NSRect(x: x, y: line.minY, width: max(0, line.maxX - padding - x), height: 1)
    }

    /// The glyphs, then the marks for their characters over them.
    open override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        drawMarks(forCharacterRange: characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil), at: origin)
    }

    /// The ¶ of an empty text, which its text view has to ask for when it draws: with no glyphs
    /// to draw, the view never calls `drawGlyphs`.
    public func drawMarksOfEmptyText(at origin: NSPoint) {
        guard showsMarks, textStorage?.length == 0 else { return }
        if let container = textContainers.first { ensureLayout(for: container) }
        drawMarks(forCharacterRange: NSRange(location: 0, length: 0), at: origin)
    }

    /// A text view draws only the glyphs in the rectangle it redraws, and draws nothing where it
    /// finds none, as on the empty line after a final line break. While the marks show, that
    /// line takes in the line break before it, so its ¶ is drawn whenever the line is; the line
    /// break itself leaves no ink.
    open override func glyphRange(forBoundingRect bounds: NSRect, in container: NSTextContainer) -> NSRange {
        let range = super.glyphRange(forBoundingRect: bounds, in: container)
        guard showsMarks, numberOfGlyphs > 0, extraLineFragmentTextContainer === container,
              bounds.intersects(extraLineFragmentRect) else { return range }
        let last = NSRange(location: numberOfGlyphs - 1, length: 1)
        return range.length == 0 ? last : NSUnionRange(range, last)
    }

    /// Each mark in the text's own size and a secondary grey.
    private func drawMarks(forCharacterRange characters: NSRange, at origin: NSPoint) {
        guard showsMarks, let storage = textStorage else { return }
        for mark in FormattingMarks.marks(in: storage.string as NSString, range: characters) {
            guard let baseline = baselineStart(of: mark) else { continue }
            let font = font(of: mark)
            NSAttributedString(string: mark.symbol, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
                .draw(at: NSPoint(x: origin.x + baseline.x, y: origin.y + baseline.y - font.ascender))
        }
    }

    /// Where `mark` starts on its baseline, in the text container: over the gap its character
    /// leaves, just after the character, or where the caret stands on the empty last line.
    func baselineStart(of mark: FormattingMarks.Mark) -> NSPoint? {
        if mark.character == textStorage?.length {
            // Set as an empty paragraph's ¶ is, on the baseline its text would have.
            guard let container = extraLineFragmentTextContainer else { return nil }
            let used = extraLineFragmentUsedRect
            return NSPoint(x: used.minX + container.lineFragmentPadding, y: used.minY + defaultBaselineOffset(for: font(of: mark)))
        }
        let glyph = glyphIndexForCharacter(at: mark.character)
        guard glyph < numberOfGlyphs, let container = textContainer(forGlyphAt: glyph, effectiveRange: nil) else { return nil }
        var lineGlyphs = NSRange()
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
        let x = mark.after ? boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).maxX
                           : line.minX + location(forGlyphAt: glyph).x
        // An empty paragraph's line break is set at the foot of its line rather than on the
        // baseline its text would have, so its ¶ is put where that text would stand.
        if !mark.after, mark.symbol == FormattingMarks.paragraph, lineGlyphs.location == glyph {
            let top = lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).minY
            return NSPoint(x: x, y: top + defaultBaselineOffset(for: font(of: mark)))
        }
        return NSPoint(x: x, y: line.minY + location(forGlyphAt: glyph).y)
    }

    /// The font of the mark's character; the empty last line's is that of the line break before
    /// it, which what is typed there takes, and an empty text's the one its view types in.
    private func font(of mark: FormattingMarks.Mark) -> NSFont {
        let fallback = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        guard let storage = textStorage, storage.length > 0 else {
            return firstTextView?.typingAttributes[.font] as? NSFont ?? fallback
        }
        return storage.attribute(.font, at: min(mark.character, storage.length - 1), effectiveRange: nil) as? NSFont ?? fallback
    }
}
