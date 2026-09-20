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
            if let rtf, rtf != lastApplied {
                if let attributed = RichText.attributed(fromRTF: rtf) {
                    text.textStorage?.setAttributedString(attributed)
                    lastApplied = rtf
                    return
                }
            }
            if rtf == nil, text.string != plain {
                text.textStorage?.setAttributedString(RichText.attributed(fromPlain: plain))
            }
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

    static func attributed(fromPlain text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: defaultFont, .foregroundColor: NSColor.labelColor])
    }

    static func attributed(fromRTF data: Data) -> NSAttributedString? {
        try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
    }

    static func rtf(from storage: NSAttributedString) -> Data? {
        storage.rtf(from: NSRange(location: 0, length: storage.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    /// Converts the composed text to HTML suitable for an email body.
    static func html(fromRTF data: Data) -> String? {
        guard let attributed = attributed(fromRTF: data) else { return nil }
        let options: [NSAttributedString.DocumentAttributeKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
            .excludedElements: ["doctype", "XML", "meta", "style", "title", "head"]
        ]
        guard let htmlData = try? attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: options) else { return nil }
        return String(decoding: htmlData, as: UTF8.self)
    }

    static func trimmedRTF(_ data: Data, keepingPrefixOfLength length: Int) -> Data? {
        guard let attributed = attributed(fromRTF: data), length > 0, length <= attributed.length else { return nil }
        return rtf(from: attributed.attributedSubstring(from: NSRange(location: 0, length: length)))
    }

    static func isEmpty(_ data: Data?) -> Bool {
        guard let data, let attributed = attributed(fromRTF: data) else { return true }
        return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}


/// A text view whose plain Paste adopts FalconMail's formatting, the way Outlook and Word do by default.
final class ComposeTextView: NSTextView {
    override func paste(_ sender: Any?) {
        pasteMatchingFalconMailStyle()
    }

    @objc func pasteMatchingFalconMailStyle() {
        pasteAsPlainText(nil)
        normaliseTypingAttributes()
    }

    @objc func pasteKeepingSourceFormatting() {
        pasteAsRichText(nil)
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

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(pasteKeepingSourceFormatting) || item.action == #selector(pasteMatchingFalconMailStyle) {
            return NSPasteboard.general.canReadObject(forClasses: [NSAttributedString.self, NSString.self], options: nil)
        }
        return super.validateMenuItem(item)
    }
}
