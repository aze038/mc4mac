import SwiftUI
import AppKit
import FalconCore

struct RichTextEditor: NSViewRepresentable {
    @Binding var body: RichText.Body
    var onEditorReady: (NSTextView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        // Draws the marks ¶ shows, which are never part of the text that is saved or sent.
        let layout = FormattingMarksLayoutManager()
        let storage = NSTextStorage()
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        // Made on this text system from the start: a container put into a view made without one
        // joins the view's own layout manager, and this one would never draw.
        let text = ComposeTextView(frame: .zero, textContainer: container)
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
        context.coordinator.apply(to: text, body: body)
        onEditorReady(text)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        guard !context.coordinator.editing else { return }
        context.coordinator.apply(to: text, body: body)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        var editing = false
        private var lastApplied: Data?

        init(_ parent: RichTextEditor) { self.parent = parent }

        func apply(to text: NSTextView, body: RichText.Body) {
            guard let stored = body.rtfd ?? body.rtf else {
                // A formatted body replaced by a plain one, as when an untouched message's From
                // goes to an account with a plain signature, is replaced on screen even where
                // the words are the same; and should it come back, it is loaded again.
                if lastApplied != nil || text.string != body.plain { load(RichText.attributed(fromPlain: body.plain), into: text) }
                lastApplied = nil
                return
            }
            guard stored != lastApplied, let attributed = RichText.attributed(from: body) else { return }
            load(attributed, into: text)
            lastApplied = stored
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
            let body = RichText.body(of: storage)
            lastApplied = body.rtfd ?? body.rtf
            parent.body = body
        }
    }
}

enum RichText {
    /// The composer's body in every form a draft keeps it in: its words, its RTF, and, while
    /// it holds pictures, its RTFD (see ComposedBody.stored).
    struct Body: Equatable {
        var plain: String
        var rtf: Data?
        var rtfd: Data?
    }

    /// The font for new messages Settings chooses, out of the box Outlook for Mac's Aptos at 12
    /// point, shown in the nearest installed font (see ComposeFont).
    static var defaultFont: NSFont { ComposeFont.chosen().displayFont }

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

    static func attributed(from body: Body) -> NSAttributedString? {
        ComposedBody.text(rtf: body.rtf, rtfd: body.rtfd)
    }

    static func body(of text: NSAttributedString) -> Body {
        let stored = ComposedBody.stored(text)
        return Body(plain: text.string, rtf: stored.rtf, rtfd: stored.rtfd)
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
    /// HTML pasted with pictures from the web keeps them: each goes in as an empty box, is
    /// fetched once and put in its place, as Outlook's signature editor does with a signature
    /// copied from a web page. Elsewhere such pictures are left out.
    var fetchesPastedRemotePictures = false
    /// Where HTML pasted as a signature goes, with what it reads as, for the signature editor,
    /// which pastes such HTML as importing it would.
    var onPasteSignatureHTML: ((String, NSAttributedString) -> Void)?
    var remotePictureLoader = RemotePictureLoader.web

    /// An empty body has no glyphs, so its layout manager is never asked to draw any; with ¶ on,
    /// the ¶ of its one empty paragraph is still drawn, as Word draws it.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        (layoutManager as? FormattingMarksLayoutManager)?.drawMarksOfEmptyText(at: textContainerOrigin)
    }

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
        guard let source = ComposeTextView.attributedFromPasteboard(keepingRemotePictures: fetchesPastedRemotePictures) else {
            pasteAsPlainText(nil)
            normaliseTypingAttributes()
            return
        }
        insertRestyled(source)
    }

    /// As it came, pictures included, which are made as every picture put into a text is (see
    /// InlinePictures.pasted).
    @objc func pasteKeepingSourceFormatting() {
        // A signature copied from Gmail or a web page comes in as importing it would bring it
        // in, its tables and pictures laid out as its HTML lays them out, and that HTML is kept
        // to be sent for it.
        if let onPasteSignatureHTML, let signature = Signature.pasted(from: .general, attributes: RichText.bodyAttributes) {
            onPasteSignatureHTML(signature.html, signature.text)
            insertPasted(signature.text)
            return
        }
        guard let source = ComposeTextView.attributedFromPasteboard(keepingRemotePictures: fetchesPastedRemotePictures) else {
            pasteAsRichText(nil)
            return
        }
        insertPasted(source)
    }

    @objc func pastePlainText() {
        pasteAsPlainText(nil)
        normaliseTypingAttributes()
    }

    /// Reads the richest representation the source app offered. Excel, Word and browsers all put
    /// RTF or HTML on the pasteboard, which is what carries the table grid; a picture copied on
    /// its own, such as a screenshot, comes as a picture.
    static func attributedFromPasteboard(keepingRemotePictures: Bool = false) -> NSAttributedString? {
        InlinePictures.pasted(from: .general, keepingRemotePictures: keepingRemotePictures)
    }

    /// Whether Paste has a picture alone to put in, which a text view that does not take
    /// pictures by itself would not offer to paste.
    private static var pasteboardHasPicture: Bool {
        NSPasteboard.general.availableType(from: [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"),
                                                  NSPasteboard.PasteboardType("public.heic")]) != nil
    }

    private func insertRestyled(_ source: NSAttributedString) {
        insertPasted(ComposeTextView.restyle(source, to: typingAttributes[.font] as? NSFont ?? RichText.defaultFont))
    }

    private func insertPasted(_ restyled: NSAttributedString) {
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: restyled.string) else { return }
        textStorage?.replaceCharacters(in: range, with: restyled)
        setSelectedRange(NSRange(location: range.location + restyled.length, length: 0))
        didChangeText()
        if fetchesPastedRemotePictures { fetchPictures(in: restyled) }
    }

    /// Fetches, once, the pictures from the web that went in as empty boxes, and puts each in
    /// wherever its box is by then.
    private func fetchPictures(in pasted: NSAttributedString) {
        let addresses = RemotePictures.addresses(in: pasted)
        guard !addresses.isEmpty else { return }
        let loader = remotePictureLoader
        Task { @MainActor [weak self] in
            let fetched = await loader.fetch(addresses)
            guard let self, !fetched.isEmpty else { return }
            RemotePictures.fill(self, with: fetched)
        }
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
            || item.action == #selector(pasteMatchingFalconMailStyle) {
            return NSPasteboard.general.canReadObject(forClasses: [NSAttributedString.self, NSString.self], options: nil)
                || ComposeTextView.pasteboardHasPicture
        }
        if item.action == #selector(pastePlainText) {
            return NSPasteboard.general.canReadObject(forClasses: [NSAttributedString.self, NSString.self], options: nil)
        }
        if item.action == #selector(paste(_:)), isEditable, ComposeTextView.pasteboardHasPicture { return true }
        return super.validateMenuItem(item)
    }
}
