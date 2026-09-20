import SwiftUI
import AppKit

struct FormatBar: View {
    weak var editor: NSTextView?
    var onEditSignatures: () -> Void
    var onInsertSignature: () -> Void

    @State private var fontName = "System"
    @State private var fontSize: CGFloat = 14
    @State private var textColour = Color.primary
    @State private var highlight = Color.yellow

    private static let families: [String] = {
        let common = ["System", "Helvetica Neue", "Arial", "Times New Roman", "Georgia", "Courier New", "Menlo", "Verdana"]
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return common.filter { $0 == "System" || installed.contains($0) }
    }()

    private static let sizes: [CGFloat] = [9, 10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 36]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar
            ScrollView(.horizontal, showsIndicators: false) { bar }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var bar: some View {
        HStack(spacing: 4) {
            Picker("", selection: $fontName) {
                ForEach(FormatBar.families, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().frame(width: 130).help("Font")
            .onChange(of: fontName) { _, _ in applyFont() }

            Picker("", selection: $fontSize) {
                ForEach(FormatBar.sizes, id: \.self) { Text("\(Int($0))").tag($0) }
            }
            .labelsHidden().frame(width: 62).help("Size")
            .onChange(of: fontSize) { _, _ in applyFont() }

            Divider().frame(height: 18)
            tool("bold", "Bold") { NSFontManager.shared.addFontTrait(self) ; toggleTrait(.boldFontMask) }
            tool("italic", "Italic") { toggleTrait(.italicFontMask) }
            tool("underline", "Underline") { editor?.underline(nil) }
            tool("strikethrough", "Strikethrough") { toggleStrikethrough() }

            Divider().frame(height: 18)
            ColorPicker("", selection: $textColour, supportsOpacity: false)
                .labelsHidden().frame(width: 34).help("Text colour")
                .onChange(of: textColour) { _, new in apply(.foregroundColor, NSColor(new)) }
            ColorPicker("", selection: $highlight, supportsOpacity: false)
                .labelsHidden().frame(width: 34).help("Highlight")
                .onChange(of: highlight) { _, new in apply(.backgroundColor, NSColor(new)) }

            Divider().frame(height: 18)
            tool("list.bullet", "Bulleted list") { applyList(.disc) }
            tool("list.number", "Numbered list") { applyList(.decimal) }
            tool("decrease.indent", "Decrease indent") { changeIndent(by: -24) }
            tool("increase.indent", "Increase indent") { changeIndent(by: 24) }

            Divider().frame(height: 18)
            tool("text.alignleft", "Align left") { editor?.alignLeft(nil) }
            tool("text.aligncenter", "Centre") { editor?.alignCenter(nil) }
            tool("text.alignright", "Align right") { editor?.alignRight(nil) }
            tool("text.justify", "Justify") { editor?.alignJustified(nil) }

            Divider().frame(height: 18)
            tool("tablecells", "Insert table") { insertTable() }
            tool("link", "Insert link") { insertLink() }
            tool("eraser", "Clear formatting") { clearFormatting() }

            Divider().frame(height: 18)
            Menu {
                Button("Paste and Match FalconMail") { (editor as? ComposeTextView)?.pasteMatchingFalconMailStyle() }
                    .keyboardShortcut("v", modifiers: .command)
                Button("Paste Keeping Source Formatting") { (editor as? ComposeTextView)?.pasteKeepingSourceFormatting() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Paste options. Pasting normally matches FalconMail's formatting.")

            Divider().frame(height: 18)
            Menu {
                Button("Insert Signature") { onInsertSignature() }
                Button("Edit Signatures…") { onEditSignatures() }
            } label: {
                Image(systemName: "signature")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Signature")
        }
        .buttonStyle(.plain)
        .font(.system(size: 13))
    }

    private func tool(_ symbol: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .help(title)
    }

    // MARK: - actions

    private func applyFont() {
        guard let editor else { return }
        let size = fontSize
        let base: NSFont = fontName == "System"
            ? NSFont.systemFont(ofSize: size)
            : (NSFont(name: fontName, size: size) ?? NSFont.systemFont(ofSize: size))
        apply(.font, base)
        editor.typingAttributes[.font] = base
    }

    private func toggleTrait(_ trait: NSFontTraitMask) {
        guard let editor, let storage = editor.textStorage else { return }
        let range = effectiveRange(editor)
        guard range.length > 0 else {
            let current = editor.typingAttributes[.font] as? NSFont ?? RichText.defaultFont
            let manager = NSFontManager.shared
            let has = manager.traits(of: current).contains(trait)
            let updated = has ? manager.convert(current, toNotHaveTrait: trait) : manager.convert(current, toHaveTrait: trait)
            editor.typingAttributes[.font] = updated
            return
        }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, sub, _ in
            let font = value as? NSFont ?? RichText.defaultFont
            let manager = NSFontManager.shared
            let has = manager.traits(of: font).contains(trait)
            let updated = has ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
            storage.addAttribute(.font, value: updated, range: sub)
        }
        storage.endEditing()
        editor.didChangeText()
    }

    private func toggleStrikethrough() {
        guard let editor, let storage = editor.textStorage else { return }
        let range = effectiveRange(editor)
        guard range.length > 0 else { return }
        let current = storage.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) as? Int ?? 0
        storage.addAttribute(.strikethroughStyle, value: current == 0 ? NSUnderlineStyle.single.rawValue : 0, range: range)
        editor.didChangeText()
    }

    private func apply(_ key: NSAttributedString.Key, _ value: Any) {
        guard let editor, let storage = editor.textStorage else { return }
        let range = effectiveRange(editor)
        guard range.length > 0 else {
            editor.typingAttributes[key] = value
            return
        }
        storage.addAttribute(key, value: value, range: range)
        editor.didChangeText()
    }

    private func applyList(_ marker: NSTextList.MarkerFormat) {
        guard let editor, let storage = editor.textStorage else { return }
        let range = (editor.string as NSString).paragraphRange(for: effectiveRange(editor))
        guard range.length > 0 else { return }
        let style = NSMutableParagraphStyle()
        style.textLists = [NSTextList(markerFormat: marker, options: 0)]
        style.headIndent = 24
        style.firstLineHeadIndent = 8
        storage.addAttribute(.paragraphStyle, value: style, range: range)
        editor.didChangeText()
    }

    private func changeIndent(by delta: CGFloat) {
        guard let editor, let storage = editor.textStorage else { return }
        let range = (editor.string as NSString).paragraphRange(for: effectiveRange(editor))
        guard range.length > 0 else { return }
        storage.enumerateAttribute(.paragraphStyle, in: range) { value, sub, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.headIndent = max(0, style.headIndent + delta)
            style.firstLineHeadIndent = max(0, style.firstLineHeadIndent + delta)
            storage.addAttribute(.paragraphStyle, value: style, range: sub)
        }
        editor.didChangeText()
    }

    private func insertTable() {
        guard let editor else { return }
        let rows = 3, columns = 3
        var text = "\n"
        for _ in 0..<rows { text += Array(repeating: "\t", count: columns - 1).joined() + "\n" }
        editor.insertText(text, replacementRange: editor.selectedRange())
        editor.didChangeText()
    }

    private func insertLink() {
        guard let editor, let storage = editor.textStorage else { return }
        let range = effectiveRange(editor)
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

    private func clearFormatting() {
        guard let editor, let storage = editor.textStorage else { return }
        let range = effectiveRange(editor)
        guard range.length > 0 else { return }
        storage.setAttributes([.font: RichText.defaultFont, .foregroundColor: NSColor.labelColor], range: range)
        editor.didChangeText()
    }

    private func effectiveRange(_ editor: NSTextView) -> NSRange {
        let selected = editor.selectedRange()
        return selected.length > 0 ? selected : NSRange(location: selected.location, length: 0)
    }
}
