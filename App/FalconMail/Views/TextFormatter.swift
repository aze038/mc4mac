import SwiftUI
import AppKit
import FalconCore

@MainActor
@Observable
final class TextFormatter {
    private(set) var editor: NSTextView?
    /// The quoted original a reply or forward ends with, which insertions stay in front of (see
    /// ComposedBody).
    var history = ""
    /// What the ribbon's small icons can act on: Cut and Copy need a selection in the body that
    /// has the keyboard.
    private(set) var editorHasFocus = false
    private(set) var hasSelection = false
    /// Format Painter is armed: the next selection made with the mouse takes the copied format.
    private(set) var isPaintingFormat = false
    /// Format Painter takes the formatting at the caret, which a body has even before it is
    /// clicked, so it is lit whenever there is a body, as in a fresh Outlook message.
    var canPaintFormat: Bool { editor != nil }
    var fontName = "System"
    var fontSize: CGFloat = 14
    var textColour = Color.primary
    var highlight = Color.yellow

    static let families: [String] = {
        let common = ["System", "Aptos", "Helvetica Neue", "Arial", "Times New Roman", "Georgia", "Courier New", "Menlo", "Verdana"]
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return common.filter { $0 == "System" || installed.contains($0) }
    }()

    static let sizes: [CGFloat] = [8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 36, 48]

    static let highlightPalette: [(String, Color)] = [
        ("Yellow", .yellow), ("Bright Green", Color(red: 0.4, green: 1, blue: 0.2)), ("Turquoise", .cyan), ("Pink", .pink),
        ("Blue", .blue), ("Red", .red), ("Dark Blue", Color(red: 0, green: 0.2, blue: 0.5)), ("Teal", .teal),
        ("Green", .green), ("Violet", .purple), ("Dark Red", Color(red: 0.55, green: 0, blue: 0)), ("Grey", .gray),
    ]
    static let textPalette: [(String, Color)] = [
        ("Automatic", .primary), ("Black", .black), ("Dark Red", Color(red: 0.55, green: 0, blue: 0)), ("Red", .red),
        ("Orange", .orange), ("Yellow", .yellow), ("Green", .green), ("Blue", .blue), ("Dark Blue", Color(red: 0, green: 0.2, blue: 0.5)),
        ("Purple", .purple), ("Grey", .gray), ("White", .white),
    ]

    private var composeView: ComposeTextView? { editor as? ComposeTextView }

    func attach(_ view: NSTextView) {
        editor = view
        if let compose = view as? ComposeTextView {
            compose.onFocusChange = { [weak self] focused in self?.editorHasFocus = focused }
            compose.onSelectionChange = { [weak self] in self?.selectionChanged() }
            compose.onMouseSelection = { [weak self] in self?.paintFormat() }
        }
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
        let base: NSFont = fontName == "System"
            ? NSFont.systemFont(ofSize: fontSize)
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

    func cycleLineSpacing() {
        guard let editor, let storage = editor.textStorage else { return }
        let range = (editor.string as NSString).paragraphRange(for: effectiveRange())
        guard range.length > 0 else { return }
        let existing = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.lineHeightMultiple ?? 1
        let next: CGFloat = existing < 1.15 ? 1.5 : (existing < 1.75 ? 2 : 1)
        storage.enumerateAttribute(.paragraphStyle, in: range) { value, sub, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.lineHeightMultiple = next
            storage.addAttribute(.paragraphStyle, value: style, range: sub)
        }
        editor.didChangeText()
    }

    func align(_ alignment: NSTextAlignment) {
        switch alignment {
        case .center: editor?.alignCenter(nil)
        case .right: editor?.alignRight(nil)
        case .justified: editor?.alignJustified(nil)
        default: editor?.alignLeft(nil)
        }
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

    func insertPicture() {
        guard let editor, let storage = editor.textStorage else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, NSImage(contentsOf: url) != nil,
              let file = try? FileWrapper(url: url, options: .immediate) else { return }
        // Held as its file, which RTFD writes out with the text, so a signature keeps it.
        let body = NSAttributedString(attachment: NSTextAttachment(fileWrapper: file))
        let range = editor.selectedRange()
        guard editor.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.replaceCharacters(in: range, with: body)
        editor.didChangeText()
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
