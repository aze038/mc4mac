import SwiftUI
import AppKit

@MainActor
@Observable
final class TextFormatter {
    var editor: NSTextView?
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

    // MARK: - clipboard

    func cut() { editor?.cut(nil) }
    func copy() { editor?.copy(nil) }
    func pasteMatchingStyle() { composeView?.pasteMatchingFalconMailStyle() }
    func pasteKeepingSource() { composeView?.pasteKeepingSourceFormatting() }
    func pastePlain() { composeView?.pastePlainText() }

    func copyFormatting() {
        guard let editor, let storage = editor.textStorage else { return }
        let range = effectiveRange()
        guard range.length > 0 else { return }
        storedFormat = storage.attributes(at: range.location, effectiveRange: nil)
    }

    func applyFormatting() {
        guard let stored = storedFormat, let editor, let storage = editor.textStorage else { return }
        let range = effectiveRange()
        guard range.length > 0 else { return }
        storage.setAttributes(stored, range: range)
        editor.didChangeText()
    }

    private var storedFormat: [NSAttributedString.Key: Any]?

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
        apply(.foregroundColor, NSColor(colour))
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

    func insertTable(rows: Int = 3, columns: Int = 3) {
        guard let editor, let storage = editor.textStorage else { return }
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        let body = NSMutableAttributedString()
        for row in 0..<rows {
            for column in 0..<columns {
                let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                block.setBorderColor(.separatorColor)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(4, type: .absoluteValueType, for: .padding)
                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                body.append(NSAttributedString(string: " \n", attributes: [.paragraphStyle: style, .font: RichText.defaultFont]))
            }
        }
        let range = editor.selectedRange()
        guard editor.shouldChangeText(in: range, replacementString: body.string) else { return }
        storage.replaceCharacters(in: range, with: body)
        editor.didChangeText()
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
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        let attachment = NSTextAttachment()
        let cell = NSTextAttachmentCell(imageCell: image)
        attachment.attachmentCell = cell
        let body = NSAttributedString(attachment: attachment)
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
