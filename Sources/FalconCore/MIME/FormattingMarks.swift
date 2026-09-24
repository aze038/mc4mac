import AppKit

/// Word's marks for what does not print, as ¶ shows them in the composer and the signature
/// editor: a ¶ where each paragraph ends, a · for each space and a → for each tab. They are only
/// drawn over the text, never put into it, so nothing that is saved or sent can carry them.
enum FormattingMarks {
    struct Mark: Equatable {
        /// The character the mark stands for, in the UTF-16 units a text view counts in.
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

    /// The marks for the characters of `range`, and, when it reaches the end of `text`, the ¶
    /// Word puts at the end of a last paragraph that has no line break.
    static func marks(in text: NSString, range: NSRange) -> [Mark] {
        var marks: [Mark] = []
        for index in range.location..<NSMaxRange(range) {
            if let symbol = symbol(for: text.character(at: index)) { marks.append(Mark(character: index, symbol: symbol)) }
        }
        if text.length > 0, NSMaxRange(range) == text.length, symbol(for: text.character(at: text.length - 1)) != paragraph {
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
            guard showsMarks != oldValue, let storage = textStorage else { return }
            invalidateDisplay(forCharacterRange: NSRange(location: 0, length: storage.length))
        }
    }

    /// Each mark in the text's own size and a secondary grey.
    open override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard showsMarks, let storage = textStorage, storage.length > 0 else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        for mark in FormattingMarks.marks(in: storage.string as NSString, range: characters) {
            guard let baseline = baselineStart(of: mark) else { continue }
            let font = font(of: mark)
            NSAttributedString(string: mark.symbol, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
                .draw(at: NSPoint(x: origin.x + baseline.x, y: origin.y + baseline.y - font.ascender))
        }
    }

    /// Where `mark` starts on its baseline, in the text container: over the gap its character
    /// leaves, or just after the character.
    func baselineStart(of mark: FormattingMarks.Mark) -> NSPoint? {
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

    private func font(of mark: FormattingMarks.Mark) -> NSFont {
        textStorage?.attribute(.font, at: mark.character, effectiveRange: nil) as? NSFont
            ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
    }
}
