import SwiftUI
import AppKit

struct RichTextEditor: NSViewRepresentable {
    @Binding var rtf: Data?
    @Binding var plain: String
    var onEditorReady: (NSTextView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let text = ComposeTextView(frame: .zero)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        let layout = NSLayoutManager()
        let storage = NSTextStorage()
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        text.replaceTextContainer(container)
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        text.isRichText = true
        text.allowsUndo = true
        text.isAutomaticLinkDetectionEnabled = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.usesFindBar = true
        text.delegate = context.coordinator
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.font = RichText.defaultFont
        text.textColor = .labelColor
        text.backgroundColor = .textBackgroundColor
        context.coordinator.apply(to: text, rtf: rtf, plain: plain)
        onEditorReady(text)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        guard !context.coordinator.editing else { return }
        context.coordinator.apply(to: text, rtf: rtf, plain: plain)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        var editing = false
        private var lastApplied: Data?

        init(_ parent: RichTextEditor) { self.parent = parent }

        func apply(to text: NSTextView, rtf: Data?, plain: String) {
            guard let rtf else {
                // A formatted body replaced by a plain one, as when an untouched message's From
                // goes to an account with a plain signature, is replaced on screen even where
                // the words are the same; and should it come back, it is loaded again.
                if lastApplied != nil || text.string != plain { load(RichText.attributed(fromPlain: plain), into: text) }
                lastApplied = nil
                return
            }
            guard rtf != lastApplied, let attributed = RichText.attributed(fromRTF: rtf) else { return }
            load(attributed, into: text)
            lastApplied = rtf
        }

        /// A draft opens with the caret at the start of the user's own text, as Outlook's does.
        /// Left where AppKit puts it, at the very end, it would sit after a reply's quoted
        /// original, and whatever the ribbon inserted would land there.
        private func load(_ body: NSAttributedString, into text: NSTextView) {
            text.textStorage?.setAttributedString(body)
            text.setSelectedRange(NSRange(location: 0, length: 0))
        }

        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? NSTextView, let storage = text.textStorage else { return }
            editing = true
            defer { editing = false }
            let data = RichText.rtf(from: storage)
            lastApplied = data
            parent.rtf = data
            parent.plain = storage.string
        }
    }
}

enum RichText {
    static let defaultFont = NSFont.systemFont(ofSize: 14)

    /// Table lines take the text's own colour, so they read in both appearances; what is sent
    /// turns them black (see ComposedHTML).
    static let tableLines = NSColor.labelColor

    /// How the composer sets text that carries no formatting of its own.
    static var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: defaultFont, .foregroundColor: NSColor.labelColor]
    }

    static func attributed(fromPlain text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: bodyAttributes)
    }

    static func attributed(fromRTF data: Data) -> NSAttributedString? {
        try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
    }

    static func rtf(from storage: NSAttributedString) -> Data? {
        storage.rtf(from: NSRange(location: 0, length: storage.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    static func isEmpty(_ data: Data?) -> Bool {
        guard let data, let attributed = attributed(fromRTF: data) else { return true }
        return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}


/// A text view whose plain Paste adopts FalconMail's formatting the way Outlook and Word do:
/// structure such as tables, lists and links survives, while fonts and colours become FalconMail's.
final class ComposeTextView: NSTextView {
    /// Keep the ribbon's small icons in step: whether the body has the keyboard, what is
    /// selected, and when a selection made with the mouse is finished (for Format Painter).
    var onFocusChange: ((Bool) -> Void)?
    var onSelectionChange: (() -> Void)?
    var onMouseSelection: (() -> Void)?
    /// A signature is often designed elsewhere and pasted in whole, so its editor keeps what is
    /// pasted as it came; Paste and Match Style still takes the editor's own.
    var pastesSourceFormatting = false
    /// Where ⌘K and the context menu's Link… go, for an editor with no ribbon button for links
    /// (the signature editor, as Outlook's).
    var onInsertLink: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        onSelectionChange?()
    }

    /// NSTextView tracks a drag inside mouseDown, so the selection is complete when it returns.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onMouseSelection?()
    }

    override func paste(_ sender: Any?) {
        if pastesSourceFormatting { pasteKeepingSourceFormatting() } else { pasteMatchingFalconMailStyle() }
    }

    @objc func pasteMatchingFalconMailStyle() {
        guard let source = ComposeTextView.attributedFromPasteboard() else {
            pasteAsPlainText(nil)
            normaliseTypingAttributes()
            return
        }
        insertRestyled(source)
    }

    @objc func pasteKeepingSourceFormatting() {
        pasteAsRichText(nil)
    }

    @objc func pastePlainText() {
        pasteAsPlainText(nil)
        normaliseTypingAttributes()
    }

    /// Reads the richest representation the source app offered. Excel, Word and browsers all put
    /// RTF or HTML on the pasteboard, which is what carries the table grid.
    static func attributedFromPasteboard() -> NSAttributedString? {
        let board = NSPasteboard.general
        if let data = board.data(forType: .rtfd),
           let value = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil) {
            return value
        }
        if let data = board.data(forType: .rtf),
           let value = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            return value
        }
        if let data = board.data(forType: .html),
           let value = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                    .characterEncoding: String.Encoding.utf8.rawValue],
                                               documentAttributes: nil) {
            return value
        }
        return nil
    }

    private func insertRestyled(_ source: NSAttributedString) {
        let restyled = ComposeTextView.restyle(source, to: typingAttributes[.font] as? NSFont ?? RichText.defaultFont)
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: restyled.string) else { return }
        textStorage?.replaceCharacters(in: range, with: restyled)
        setSelectedRange(NSRange(location: range.location + restyled.length, length: 0))
        didChangeText()
    }

    /// Keeps every structural attribute, replaces the typeface and size with the composer's, and
    /// drops source colours so pasted text stays readable in both light and dark appearance.
    static func restyle(_ source: NSAttributedString, to base: NSFont) -> NSAttributedString {
        let output = NSMutableAttributedString(attributedString: source)
        let whole = NSRange(location: 0, length: output.length)
        let manager = NSFontManager.shared
        output.beginEditing()
        output.enumerateAttributes(in: whole) { attributes, range, _ in
            var font = base
            if let existing = attributes[.font] as? NSFont {
                let traits = manager.traits(of: existing)
                if traits.contains(.boldFontMask) { font = manager.convert(font, toHaveTrait: .boldFontMask) }
                if traits.contains(.italicFontMask) { font = manager.convert(font, toHaveTrait: .italicFontMask) }
            }
            output.addAttribute(.font, value: font, range: range)
            if attributes[.link] == nil {
                output.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
            if let background = attributes[.backgroundColor] as? NSColor, background.alphaComponent < 0.05 {
                output.removeAttribute(.backgroundColor, range: range)
            }
        }
        output.endEditing()
        return output
    }

    private func normaliseTypingAttributes() {
        guard let storage = textStorage else { return }
        let inserted = selectedRange()
        guard inserted.length == 0, inserted.location > 0 else { return }
        let font = typingAttributes[.font] as? NSFont ?? RichText.defaultFont
        let colour = typingAttributes[.foregroundColor] as? NSColor ?? .labelColor
        let start = max(0, inserted.location - 1)
        let range = NSRange(location: start, length: min(1, storage.length - start))
        guard range.length > 0 else { return }
        storage.addAttributes([.font: font, .foregroundColor: colour], range: range)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let onInsertLink, window?.firstResponder === self,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "k" {
            onInsertLink()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        if onInsertLink != nil, let menu {
            let item = NSMenuItem(title: "Link…", action: #selector(insertLinkFromMenu), keyEquivalent: "k")
            item.target = self
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        return menu
    }

    @objc private func insertLinkFromMenu() { onInsertLink?() }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(pasteKeepingSourceFormatting)
            || item.action == #selector(pasteMatchingFalconMailStyle)
            || item.action == #selector(pastePlainText) {
            return NSPasteboard.general.canReadObject(forClasses: [NSAttributedString.self, NSString.self], options: nil)
        }
        return super.validateMenuItem(item)
    }
}
