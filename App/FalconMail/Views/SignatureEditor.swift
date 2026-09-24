import SwiftUI
import AppKit
import FalconCore

/// One window per signature, titled with its name, as Outlook opens them from the Signatures
/// pane.
@MainActor
final class SignatureEditorWindows: NSObject, NSWindowDelegate {
    static let shared = SignatureEditorWindows()
    /// Outlook's editor window, title row included.
    static let size = NSSize(width: 500, height: 437)

    private var windows: [UUID: NSWindow] = [:]
    private weak var library: SignatureLibrary?

    func open(_ id: UUID, library: SignatureLibrary) {
        if let window = windows[id] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        self.library = library
        guard let window = Self.window(for: id, library: library) else { return }
        window.delegate = self
        windows[id] = window
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    /// A signature that is deleted takes its editor with it.
    func close(_ id: UUID) {
        windows[id]?.close()
    }

    /// What was typed last is kept as the window goes, so an editor opened again at once starts
    /// from it.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = windows.first(where: { $0.value === window })?.key else { return }
        windows[id] = nil
        library?.saveNow()
    }

    /// The editor window, not yet on screen. Its title row is drawn with the rest, as Outlook
    /// puts Save, Undo and Redo in it.
    static func window(for id: UUID, library: SignatureLibrary) -> NSWindow? {
        guard let signature = library.signature(id) else { return nil }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = signature.name
        window.contentMinSize = NSSize(width: 460, height: 300)
        window.tabbingMode = .disallowed
        let editor = SignatureEditorView(id: id, library: library, initialName: signature.name,
                                         retitle: { [weak window] in window?.title = $0 })
        let host = NSHostingView(rootView: editor.themedRoot())
        host.sizingOptions = []
        window.contentView = host
        return window
    }
}

/// The editor's colours: a lighter band for the title row and ribbon, black lines round the
/// Signature Name row, and the text on the darker ground under it.
enum SignatureEditorLook {
    static let chrome = Classic.colour(light: 0xF6F6F6, dark: 0x282828)
    static let ground = Classic.colour(light: 0xFFFFFF, dark: 0x1E1E1E)
    static let line = Classic.colour(light: 0xC4C4C4, dark: 0x000000)
    static let fieldEdge = Classic.colour(light: 0xB4B4B4, dark: 0x585858)
    static let ink = Classic.colour(light: 0x505050, dark: 0xD4D4D4)
    static let popupFill = Classic.colour(light: 0xFFFFFF, dark: 0x333333)
    static let popupEdge = Classic.colour(light: 0xC8C8C8, dark: 0x3B3A3B)
    static let chosen = Classic.colour(light: 0xDADADA, dark: 0x4F4E4D)
    static let accent = Classic.colour(light: 0x2F74C9, dark: 0x5697D7)
    static let title = Classic.colour(light: 0x3C3C3C, dark: 0xDFDFDF)
    /// Save, Undo and Redo are white while they can act, as in Outlook's editor.
    static let quick = Classic.colour(light: 0x3C3C3C, dark: 0xFFFFFF)

    static let titleRow: CGFloat = 28
}

/// The editor: the title row, a ribbon with the one tab Signature, the name, then the
/// signature itself. Every change is handed to the library as it is made; only a change is, so
/// a signature opened just to be read is left exactly as it was.
struct SignatureEditorView: View {
    let id: UUID
    let library: SignatureLibrary
    let retitle: (String) -> Void
    @State private var name: String
    @State private var formatter = TextFormatter()
    @State private var initialText: NSAttributedString
    @State private var tab = 0
    @State private var canUndo = false
    @State private var canRedo = false

    init(id: UUID, library: SignatureLibrary, initialName: String, retitle: @escaping (String) -> Void) {
        self.id = id
        self.library = library
        self.retitle = retitle
        _name = State(initialValue: initialName)
        let text = library.signature(id)?.text ?? NSAttributedString()
        _initialText = State(initialValue: ComposedBody.filling(text, with: RichText.bodyAttributes))
    }

    var body: some View {
        VStack(spacing: 0) {
            titleRow
            RibbonTabStrip(tabs: [(0, "Signature")], selection: $tab)
                .padding(.horizontal, 11)
            SignatureRibbon(formatter: formatter)
            SignatureEditorLook.line.frame(height: 1)
            nameRow
            SignatureEditorLook.line.frame(height: 1)
            SignatureTextEditor(text: initialText, onChange: { library.setText($0, of: id) }, onReady: { formatter.attach($0) })
        }
        .background(SignatureEditorLook.chrome)
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerCheckpoint)) { _ in refreshUndo() }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) { _ in refreshUndo() }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange)) { _ in refreshUndo() }
    }

    /// Save, Undo and Redo after the window buttons, the signature's name in the middle.
    private var titleRow: some View {
        ZStack {
            WindowDragArea()
            Text(name.trimmed.isEmpty ? (library.signature(id)?.name ?? "") : name.trimmed)
                .font(.system(size: 12))
                .foregroundStyle(SignatureEditorLook.title)
                .lineLimit(1)
                .padding(.horizontal, 170)
                .offset(y: 1)
                .allowsHitTesting(false)
            HStack(spacing: OL.quickPitch - 20) {
                RibbonQuickButton(symbol: "square.and.arrow.down", title: "Save", ink: SignatureEditorLook.quick) { library.saveNow() }
                RibbonQuickButton(symbol: "arrow.uturn.backward", title: "Undo", enabled: canUndo, ink: SignatureEditorLook.quick) {
                    formatter.editor?.undoManager?.undo()
                }
                RibbonQuickButton(symbol: "arrow.uturn.forward", title: "Redo", enabled: canRedo, ink: SignatureEditorLook.quick) {
                    formatter.editor?.undoManager?.redo()
                }
                Spacer()
            }
            .padding(.leading, 92)
            .offset(y: 0.75)
        }
        .frame(height: SignatureEditorLook.titleRow)
    }

    /// "Signature Name:" and its field, thirty-eight points of the window between two black
    /// lines, the field running to nine points from the window's right edge.
    private var nameRow: some View {
        GeometryReader { geometry in
            Placements(width: geometry.size.width, height: 38) {
                SignatureEditorLook.ground.frame(width: geometry.size.width, height: 38)
                Text("Signature Name:").font(.system(size: 13)).foregroundStyle(OLColor.text).fixedSize()
                    .at(x: 8.4, baseline: 24)
                Rectangle().strokeBorder(SignatureEditorLook.fieldEdge, lineWidth: 1)
                    .frame(width: max(0, geometry.size.width - 126), height: 22)
                    .at(x: 117, y: 8)
                TextField("Signature Name:", text: $name)
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .frame(width: max(0, geometry.size.width - 134))
                    .at(x: 121, baseline: 24)
                    .onChange(of: name) { _, new in
                        library.rename(id, to: new)
                        retitle(library.signature(id)?.name ?? new)
                    }
            }
        }
        .frame(height: 38)
    }

    private func refreshUndo() {
        let manager = formatter.editor?.undoManager
        canUndo = manager?.canUndo ?? false
        canRedo = manager?.canRedo ?? false
    }
}

/// The Signature tab: Paste with Cut and Copy; the font and size, lists, indents and ¶ over
/// bold, italic, underline, strikethrough, highlight, text colour and alignment; Picture. At
/// Outlook's positions, which run past a window of its width: the ribbon then scrolls, with
/// Outlook's black strip and arrow at its right end.
struct SignatureRibbon: View {
    let formatter: TextFormatter

    static let contentWidth: CGFloat = 512

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    content.id("ribbon")
                }
                .scrollIndicators(.never)
                .overlay(alignment: .trailing) {
                    if geometry.size.width < Self.contentWidth {
                        Button { withAnimation { reader.scrollTo("ribbon", anchor: .trailing) } } label: {
                            ZStack {
                                Classic.colour(light: 0xDCDCDC, dark: 0x090A0A)
                                Image(systemName: "arrowtriangle.right.fill").font(.system(size: 8))
                                    .foregroundStyle(Classic.colour(light: 0x6E6E6E, dark: 0x9D9D9D))
                            }
                            .frame(width: 15, height: OL.ribbon)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("More")
                    }
                }
            }
        }
        .frame(height: OL.ribbon)
    }

    private var ink: Color { SignatureEditorLook.ink }

    private var content: some View {
        Placements(width: Self.contentWidth, height: OL.ribbon) {
            Button { formatter.pasteMatchingStyle() } label: {
                Placements(width: 34, height: 50) {
                    Image(systemName: "doc.on.clipboard")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(ink, Color(red: 0.89, green: 0.62, blue: 0.24))
                        .font(.system(size: 27, weight: .light))
                        .frame(width: 28, height: 31)
                        .at(x: 1.5, y: 0)
                    Text("Paste").font(.system(size: 11)).foregroundStyle(OLColor.text).fixedSize().at(x: 0, baseline: 44.5)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Paste")
            .at(x: 14.5, y: 9)
            RibbonSmallButton(title: "Cut", enabled: formatter.editorHasFocus && formatter.hasSelection,
                              glyph: SmallGlyph(symbol: "scissors", size: 12, turn: .degrees(-90), ink: ink)) { formatter.cut() }
                .at(x: 49, y: 10)
            RibbonSmallButton(title: "Copy", enabled: formatter.editorHasFocus && formatter.hasSelection,
                              glyph: CopyGlyph(ink: ink)) { formatter.copy() }
                .at(x: 49, y: 42)
            separator(height: 62).at(x: 82, y: 4)

            FmtPopup(text: formatter.fontName, width: 99, height: 24, textSize: 12, inset: 6,
                     fill: SignatureEditorLook.popupFill, edge: SignatureEditorLook.popupEdge) {
                ForEach(TextFormatter.families, id: \.self) { family in Button(family) { formatter.setFontName(family) } }
            }
            .at(x: 93, y: 9)
            FmtPopup(text: sizeText, width: 54, height: 24, textSize: 12, inset: 6,
                     fill: SignatureEditorLook.popupFill, edge: SignatureEditorLook.popupEdge) {
                ForEach(TextFormatter.sizes, id: \.self) { size in Button("\(Int(size))") { formatter.setFontSize(size) } }
            }
            .at(x: 194, y: 9)
            FmtMenuButton("list.bullet", "Bullets", ink: ink, accent: SignatureEditorLook.accent, chevronInk: ink, size: 15, box: 24,
                          action: { formatter.applyList(.disc) }) {
                Button("Bullets") { formatter.applyList(.disc) }
            }
            .at(x: 249.5, y: 9)
            FmtMenuButton("list.number", "Numbering", ink: ink, accent: SignatureEditorLook.accent, chevronInk: ink, size: 15, box: 24,
                          action: { formatter.applyList(.decimal) }) {
                Button("Numbers") { formatter.applyList(.decimal) }
            }
            .at(x: 287.5, y: 9)
            separator(height: 18).at(x: 332, y: 12)
            FmtButton("decrease.indent", "Decrease indent", ink: ink, accent: SignatureEditorLook.accent, size: 12.5, box: 24) {
                formatter.changeIndent(by: -24)
            }
                .at(x: 341, y: 8.5)
            FmtButton("increase.indent", "Increase indent", ink: ink, accent: SignatureEditorLook.accent, size: 12.5, box: 24) {
                formatter.changeIndent(by: 24)
            }
                .at(x: 367, y: 8.5)
            separator(height: 18).at(x: 399, y: 12)
            FmtButton("paragraphsign", "Show paragraph marks", ink: ink, size: 13, box: 24) { formatter.cycleLineSpacing() }
                .at(x: 408, y: 9)

            FmtButton("bold", "Bold", ink: ink, size: 14, box: 24) { formatter.toggleBold() }.at(x: 93.5, y: 39.75)
            FmtButton("italic", "Italic", ink: ink, size: 14, box: 24) { formatter.toggleItalic() }.at(x: 119, y: 39.75)
            FmtButton("underline", "Underline", ink: ink, size: 14, box: 24) { formatter.toggleUnderline() }.at(x: 144.5, y: 41)
            Button { formatter.toggleStrikethrough() } label: {
                Text("ab").font(.system(size: 14.5, weight: .thin)).strikethrough().foregroundStyle(ink)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Strikethrough")
            .at(x: 171, y: 40)
            separator(height: 18).at(x: 203, y: 44)
            FmtColourButton("highlighter", "Highlight", colour: formatter.highlight, palette: TextFormatter.highlightPalette,
                            ink: ink, chevronInk: ink, size: 13, box: 24, glyphHeight: 13) { formatter.setHighlight($0) }
                .at(x: 212, y: 41)
            FmtColourButton("textformat", "Text colour", colour: formatter.textColour, palette: TextFormatter.textPalette,
                            ink: ink, chevronInk: ink, size: 13, box: 24, glyphHeight: 13) { formatter.setTextColour($0) }
                .at(x: 250, y: 41)
            separator(height: 18).at(x: 294, y: 44)
            alignment(.left, "text.alignleft", "Align left", x: 303)
            alignment(.center, "text.aligncenter", "Centre", x: 329)
            alignment(.right, "text.alignright", "Align right", x: 355)
            alignment(.justified, "text.justify", "Justify", x: 381)
            separator(height: 62).at(x: 442, y: 4)

            Button { formatter.insertPicture() } label: {
                Placements(width: 42, height: 50) {
                    Image(systemName: "photo")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(SignatureEditorLook.accent, ink)
                        .font(.system(size: 27, weight: .light))
                        .frame(width: 30, height: 31)
                        .offset(x: 1, y: -1.5)
                    Text("Picture").font(.system(size: 11)).foregroundStyle(OLColor.text).fixedSize().at(x: 0, baseline: 44.5)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Picture")
            .at(x: 456.4, y: 8.5)
        }
    }

    private var sizeText: String {
        let size = formatter.fontSize
        return size == size.rounded() ? "\(Int(size))" : String(format: "%.1f", size)
    }

    private func separator(height: CGFloat) -> some View {
        OLColor.ribbonSeparator.frame(width: 1, height: height)
    }

    /// The alignment the caret's paragraph has is shown on a grey square, as Outlook shows it.
    private func alignment(_ value: NSTextAlignment, _ symbol: String, _ title: String, x: CGFloat) -> some View {
        let current = formatter.alignment == .natural ? NSTextAlignment.left : formatter.alignment
        return FmtButton(symbol, title, ink: ink, size: 15, box: 24) { formatter.align(value) }
            .background(current == value ? SignatureEditorLook.chosen : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            .at(x: x, y: 41)
    }
}

/// The signature's text: the composer's text view, so pictures and the ribbon behave as they
/// do in a message.
struct SignatureTextEditor: NSViewRepresentable {
    let text: NSAttributedString
    /// Called with the text after each change the user makes, never for the text it opens with.
    let onChange: (NSAttributedString) -> Void
    let onReady: (NSTextView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = ComposeTextView(frame: scroll.contentView.bounds)
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.isRichText = true
        view.importsGraphics = true
        view.pastesSourceFormatting = true
        view.allowsUndo = true
        view.usesFindBar = true
        // Outlook's text starts ten points in and its first baseline twenty-nine points down.
        view.textContainerInset = NSSize(width: 5.5, height: 15)
        view.backgroundColor = NSColor(SignatureEditorLook.ground)
        view.textStorage?.setAttributedString(text)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        // Text typed into a new signature is set as a message's is; otherwise the caret takes
        // the formatting it lands in.
        if text.length == 0 { view.typingAttributes = RichText.bodyAttributes }
        view.delegate = context.coordinator
        view.setAccessibilityLabel("Signature")
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(SignatureEditorLook.ground)
        onReady(view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onChange = onChange
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: (NSAttributedString) -> Void

        init(onChange: @escaping (NSAttributedString) -> Void) { self.onChange = onChange }

        func textDidChange(_ notification: Notification) {
            guard let storage = (notification.object as? NSTextView)?.textStorage else { return }
            onChange(NSAttributedString(attributedString: storage))
        }
    }
}
