import SwiftUI
import AppKit
import FalconCore

@MainActor
@Observable
final class TextFormatter {
    private(set) var editor: NSTextView?
    /// The quoted original a reply or forward ends with, which insertions stay in front of (see
    /// ComposedBody).
    var history = "" {
        didSet { (editor?.layoutManager as? FormattingMarksLayoutManager)?.quotedHistory = history }
    }
    /// What the ribbon's small icons can act on: Cut and Copy need a selection in the body that
    /// has the keyboard.
    private(set) var editorHasFocus = false
    private(set) var hasSelection = false
    /// Format Painter is armed: the next selection made with the mouse takes the copied format.
    private(set) var isPaintingFormat = false
    /// Format Painter takes the formatting at the caret, which a body has even before it is
    /// clicked, so it is lit whenever there is a body, as in a fresh Outlook message.
    var canPaintFormat: Bool { editor != nil }
    var fontName = ComposeFont.chosen().family
    var fontSize: CGFloat = ComposeFont.chosen().size
    /// The paragraph's alignment at the caret; natural is left in a left-to-right text.
    private(set) var alignment = NSTextAlignment.natural
    /// The colours the Text colour and Highlight buttons show and apply with a click on their
    /// face; they start, as Outlook's do, on its pure red and yellow.
    var textColour = TextFormatter.firstTextColour
    var highlight = TextFormatter.firstHighlight
    /// ¶ is on. The marks are only drawn over the body, so the text that is saved and sent
    /// never holds them.
    private(set) var showsFormattingMarks = false

    static let families: [String] = {
        // Aptos stands for Outlook's own list, which is sent whether or not Aptos is installed.
        let common = ["System", ComposeFont.outlookFamily, "Helvetica Neue", "Arial", "Times New Roman", "Georgia", "Courier New",
                      "Menlo", "Verdana"]
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return common.filter { $0 == "System" || $0 == ComposeFont.outlookFamily || installed.contains($0) }
    }()

    static let sizes: [CGFloat] = [8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 36, 48]

    /// Outlook's pure red and yellow. Its Display P3 capture holds them as 0xEB3323 and
    /// 0xFFFF53, which read as sRGB would be a duller red and a paler yellow than it applies.
    static let firstTextColour = sRGB(0xFF0000)
    static let firstHighlight = sRGB(0xFFFF00)

    // Word's highlight colours and Outlook's standard font colours, in the sRGB they are sent
    // in. SwiftUI's named colours follow the appearance, so one picked in dark would be sent in
    // its dark shade, and most are not the colour Outlook's name stands for.
    static let highlightPalette: [(String, Color)] = [
        ("Yellow", sRGB(0xFFFF00)), ("Bright Green", sRGB(0x00FF00)), ("Turquoise", sRGB(0x00FFFF)), ("Pink", sRGB(0xFF00FF)),
        ("Blue", sRGB(0x0000FF)), ("Red", sRGB(0xFF0000)), ("Dark Blue", sRGB(0x000080)), ("Teal", sRGB(0x008080)),
        ("Green", sRGB(0x008000)), ("Violet", sRGB(0x800080)), ("Dark Red", sRGB(0x800000)), ("Grey", sRGB(0x808080)),
    ]
    static let textPalette: [(String, Color)] = [
        ("Automatic", .primary), ("Black", sRGB(0x000000)), ("Dark Red", sRGB(0xC00000)), ("Red", sRGB(0xFF0000)),
        ("Orange", sRGB(0xFFC000)), ("Yellow", sRGB(0xFFFF00)), ("Green", sRGB(0x00B050)), ("Blue", sRGB(0x0070C0)),
        ("Dark Blue", sRGB(0x002060)), ("Purple", sRGB(0x7030A0)), ("Grey", sRGB(0x808080)), ("White", sRGB(0xFFFFFF)),
    ]

    private static func sRGB(_ hex: Int) -> Color { Color(nsColor: NSColor(hex: hex)) }

    private var composeView: ComposeTextView? { editor as? ComposeTextView }

    func attach(_ view: NSTextView) {
        editor = view
        if let compose = view as? ComposeTextView {
            compose.onFocusChange = { [weak self] focused in self?.editorHasFocus = focused }
            compose.onSelectionChange = { [weak self] in self?.selectionChanged() }
            compose.onMouseSelection = { [weak self] in self?.paintFormat() }
        }
        // SwiftUI can make the body's text view again while the formatter lives on, and the new
        // one should show ¶ as the ribbon does.
        (view.layoutManager as? FormattingMarksLayoutManager)?.showsMarks = showsFormattingMarks
        // And Outlook's line above a quoted original's heading.
        (view.layoutManager as? FormattingMarksLayoutManager)?.quotedHistory = history
        selectionChanged()
    }

    /// Also catches the body taking the keyboard before it was attached: a window gives its
    /// first responder the keyboard without asking it again.
    private func selectionChanged() {
        guard let editor else { return }
        let selected = editor.selectedRange().length > 0
        if selected != hasSelection { hasSelection = selected }
        let focused = editor.window?.firstResponder === editor
        if focused != editorHasFocus { editorHasFocus = focused }
        followTypingAttributes(of: editor)
    }

    /// The font boxes and the alignment buttons show what the caret would type, as Outlook's do.
    private func followTypingAttributes(of editor: NSTextView) {
        let attributes = editor.typingAttributes
        if let font = attributes[.font] as? NSFont {
            // Text in the font standing in for Outlook's Aptos is Aptos, as it is sent.
            let chosen = ComposeFont.chosen()
            let standIn = chosen.family == ComposeFont.outlookFamily && font.familyName == chosen.displayFont.familyName
            let family = standIn ? ComposeFont.outlookFamily : font.familyName.map { $0.hasPrefix(".") ? "System" : $0 } ?? "System"
            if family != fontName { fontName = family }
            if font.pointSize != fontSize { fontSize = font.pointSize }
        }
        let aligned = (attributes[.paragraphStyle] as? NSParagraphStyle)?.alignment ?? .natural
        if aligned != alignment { alignment = aligned }
    }

    // MARK: - clipboard

    func cut() { editor?.cut(nil) }
    func copy() { editor?.copy(nil) }
    func pasteMatchingStyle() { composeView?.pasteMatchingFalconMailStyle() }
    func pasteKeepingSource() { composeView?.pasteKeepingSourceFormatting() }
    func pastePlain() { composeView?.pastePlainText() }

    /// Format Painter: takes the character formatting at the selection (or at the caret) and
    /// gives it to the next text selected with the mouse. Pressing it again puts it down.
    func toggleFormatPainter() {
        guard !isPaintingFormat else {
            isPaintingFormat = false
            return
        }
        guard let editor, let storage = editor.textStorage else { return }
        let range = editor.selectedRange()
        let source = range.length > 0 ? storage.attributes(at: range.location, effectiveRange: nil) : editor.typingAttributes
        storedFormat = source.filter { TextFormatter.paintedKeys.contains($0.key) }
        isPaintingFormat = true
    }

    /// Only the look of the characters travels: paragraph styles would turn text into table
    /// cells or list items, and links or pictures must never be dropped from what they cover.
    private static let paintedKeys: Set<NSAttributedString.Key> = [
        .font, .foregroundColor, .backgroundColor, .underlineStyle, .strikethroughStyle, .baselineOffset,
    ]

    private func paintFormat() {
        guard isPaintingFormat, let editor, let storage = editor.textStorage else { return }
        let range = editor.selectedRange()
        guard range.length > 0 else { return }
        isPaintingFormat = false
        guard editor.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        for key in TextFormatter.paintedKeys { storage.removeAttribute(key, range: range) }
        storage.addAttributes(storedFormat, range: range)
        storage.endEditing()
        editor.didChangeText()
        editor.undoManager?.setActionName("Format Painter")
    }

    private var storedFormat: [NSAttributedString.Key: Any] = [:]

    // MARK: - font

    func setFontName(_ name: String) {
        fontName = name
        applyFont()
    }

    func setFontSize(_ size: CGFloat) {
        fontSize = size
        applyFont()
    }

    func stepFontSize(_ delta: CGFloat) {
        setFontSize(max(6, min(96, fontSize + delta)))
    }

    private func applyFont() {
        guard let editor else { return }
        let base: NSFont = fontName == "System" || fontName == ComposeFont.outlookFamily
            ? ComposeFont(family: fontName, size: fontSize).displayFont
            : (NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize))
        apply(.font, base)
        editor.typingAttributes[.font] = base
    }

    func toggleBold() { toggleTrait(.boldFontMask) }
    func toggleItalic() { toggleTrait(.italicFontMask) }
    func toggleUnderline() { editor?.underline(nil) }

    func toggleStrikethrough() {
        guard let editor, let storage = editor.textStorage else { return }
        let range = effectiveRange()
        guard range.length > 0 else { return }
        let current = storage.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) as? Int ?? 0
        storage.addAttribute(.strikethroughStyle, value: current == 0 ? NSUnderlineStyle.single.rawValue : 0, range: range)
        editor.didChangeText()
    }

    func setBaseline(_ offset: CGFloat) {
        guard let editor, let storage = editor.textStorage else { return }
        let range = effectiveRange()
        guard range.length > 0 else { return }
        let current = storage.attribute(.baselineOffset, at: range.location, effectiveRange: nil) as? CGFloat ?? 0
        let value: CGFloat = abs(current - offset) < 0.01 ? 0 : offset
        storage.addAttribute(.baselineOffset, value: value, range: range)
        let smaller = NSFont.systemFont(ofSize: value == 0 ? fontSize : fontSize * 0.75)
        storage.addAttribute(.font, value: smaller, range: range)
        editor.didChangeText()
    }

    func setTextColour(_ colour: Color) {
        textColour = colour
        // Automatic is the system's label colour, which survives the body's round trip through
        // RTF as itself: SwiftUI's primary would be written down as a fixed near-black and turn
        // invisible when the draft is next opened in dark appearance.
        apply(.foregroundColor, colour == .primary ? NSColor.labelColor : NSColor(colour))
    }

    func setHighlight(_ colour: Color) {
        highlight = colour
        apply(.backgroundColor, NSColor(colour))
    }

    func clearFormatting() {
        guard let editor, let storage = editor.textStorage else { return }
        let range = effectiveRange()
        guard range.length > 0 else { return }
        storage.setAttributes([.font: RichText.defaultFont, .foregroundColor: NSColor.labelColor], range: range)
        editor.didChangeText()
    }

    // MARK: - paragraph

    func applyList(_ marker: NSTextList.MarkerFormat) {
        guard let editor, let storage = editor.textStorage else { return }
        let range = (editor.string as NSString).paragraphRange(for: effectiveRange())
        guard range.length > 0 else { return }
        let style = NSMutableParagraphStyle()
        style.textLists = [NSTextList(markerFormat: marker, options: 0)]
        style.headIndent = 24
        style.firstLineHeadIndent = 8
        storage.addAttribute(.paragraphStyle, value: style, range: range)
        editor.didChangeText()
    }

    func changeIndent(by delta: CGFloat) {
        guard let editor, let storage = editor.textStorage else { return }
        let range = (editor.string as NSString).paragraphRange(for: effectiveRange())
        guard range.length > 0 else { return }
        storage.enumerateAttribute(.paragraphStyle, in: range) { value, sub, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.headIndent = max(0, style.headIndent + delta)
            style.firstLineHeadIndent = max(0, style.firstLineHeadIndent + delta)
            storage.addAttribute(.paragraphStyle, value: style, range: sub)
        }
        editor.didChangeText()
    }

    /// ¶: shows or hides the marks for what does not print, as Outlook's does, leaving the text
    /// itself and its undo history alone.
    func toggleFormattingMarks() {
        showsFormattingMarks.toggle()
        (editor?.layoutManager as? FormattingMarksLayoutManager)?.showsMarks = showsFormattingMarks
    }

    func align(_ alignment: NSTextAlignment) {
        switch alignment {
        case .center: editor?.alignCenter(nil)
        case .right: editor?.alignRight(nil)
        case .justified: editor?.alignJustified(nil)
        default: editor?.alignLeft(nil)
        }
        if let editor { followTypingAttributes(of: editor) }
    }

    // MARK: - insert

    func insertTable(rows: Int, columns: Int) {
        guard let editor else { return }
        ComposedBody.insertTable(rows: rows, columns: columns, into: editor, before: history,
                                 font: RichText.defaultFont, lines: RichText.tableLines)
    }

    /// Whether the selection is text Convert Text to Table can turn into a table.
    var canConvertTextToTable: Bool {
        editor.map { ComposedBody.convertibleRange(in: $0, before: history) != nil } ?? false
    }

    func convertTextToTable() {
        guard let editor else { return }
        ComposedBody.convertToTable(in: editor, before: history, font: RichText.defaultFont, lines: RichText.tableLines)
    }

    func insertSignature(_ signature: Signature) {
        guard let editor, !signature.isBlank else { return }
        ComposedBody.insertSignature(signature.block, into: editor, before: history)
    }

    func insertLink() {
        guard let editor, let storage = editor.textStorage else { return }
        let range = effectiveRange()
        let alert = NSAlert()
        alert.messageText = "Insert link"
        alert.informativeText = range.length > 0 ? "The selected text will link to this address." : "Both the text and the address."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
        field.placeholderString = "https://example.com"
        alert.accessoryView = field
        alert.addButton(withTitle: "Insert")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var address = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return }
        if !address.contains("://") { address = "https://" + address }
        guard let url = URL(string: address) else { return }
        if range.length > 0 {
            storage.addAttribute(.link, value: url, range: range)
        } else {
            let link = NSAttributedString(string: address, attributes: [.link: url, .font: RichText.defaultFont])
            storage.insert(link, at: editor.selectedRange().location)
        }
        editor.didChangeText()
    }

    /// Outlook's Pictures, in a message and in the signature editor alike: the picture goes in
    /// as its file, which RTFD keeps with the text, so a draft and a signature keep it, and it is
    /// sent as it is (see InlinePictures).
    func insertPicture() {
        guard let editor else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url),
              let picture = InlinePictures.attachment(for: data, named: url.lastPathComponent) else { return }
        ComposedBody.insertPicture(picture, into: editor, before: history)
    }

    func checkSpelling() {
        editor?.checkSpelling(nil)
    }

    func toggleContinuousSpellCheck() {
        guard let editor else { return }
        editor.isContinuousSpellCheckingEnabled.toggle()
        Preferences.set(editor.isContinuousSpellCheckingEnabled, Pref.checkSpelling)
    }

    func showZoomPanel() {
        NSApp.sendAction(Selector(("orderFrontFontPanel:")), to: nil, from: nil)
    }

    // MARK: - helpers

    private func toggleTrait(_ trait: NSFontTraitMask) {
        guard let editor, let storage = editor.textStorage else { return }
        let range = effectiveRange()
        let manager = NSFontManager.shared
        guard range.length > 0 else {
            let current = editor.typingAttributes[.font] as? NSFont ?? RichText.defaultFont
            let has = manager.traits(of: current).contains(trait)
            editor.typingAttributes[.font] = has ? manager.convert(current, toNotHaveTrait: trait) : manager.convert(current, toHaveTrait: trait)
            return
        }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, sub, _ in
            let font = value as? NSFont ?? RichText.defaultFont
            let has = manager.traits(of: font).contains(trait)
            storage.addAttribute(.font, value: has ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait), range: sub)
        }
        storage.endEditing()
        editor.didChangeText()
    }

    private func apply(_ key: NSAttributedString.Key, _ value: Any) {
        guard let editor, let storage = editor.textStorage else { return }
        let range = effectiveRange()
        guard range.length > 0 else {
            editor.typingAttributes[key] = value
            return
        }
        storage.addAttribute(key, value: value, range: range)
        editor.didChangeText()
    }

    private func effectiveRange() -> NSRange {
        guard let editor else { return NSRange(location: 0, length: 0) }
        let selected = editor.selectedRange()
        return selected.length > 0 ? selected : NSRange(location: selected.location, length: 0)
    }
}
