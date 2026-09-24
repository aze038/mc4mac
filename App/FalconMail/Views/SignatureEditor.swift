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
    /// The capture's 0x5697D7 is in Display P3, as it was taken on such a screen; this is the
    /// same blue in sRGB, the space these values are read in.
    static let accent = Classic.colour(light: 0x2F74C9, dark: 0x3B99DD)
    static let title = Classic.colour(light: 0x3C3C3C, dark: 0xDFDFDF)
    /// Save, Undo and Redo are white while they can act, as in Outlook's editor.
    static let quick = Classic.colour(light: 0x3C3C3C, dark: 0xFFFFFF)
    /// The ribbon's labels, the font boxes' text and the chevrons are white in Outlook's dark
    /// editor, brighter than the compose ribbon's.
    static let bright = Classic.colour(light: 0x1E1E1E, dark: 0xFFFFFF)
    static let chevron = Classic.colour(light: 0x505050, dark: 0xFFFFFF)
    /// The name is typed a shade dimmer than its label.
    static let nameText = Classic.colour(light: 0x000000, dark: 0xDDDDDD)
    static let overflow = Classic.colour(light: 0xDCDCDC, dark: 0x0A0A0A)
    static let overflowEdge = Classic.colour(light: 0xC8C8C8, dark: 0x333333)
    static let overflowArrow = Classic.colour(light: 0x6E6E6E, dark: 0x9D9D9D)
    /// The colours Text colour and Highlight start with, Outlook's pure red and yellow. Its
    /// Display P3 capture holds them as 0xEB3323 and 0xFFFF53, which read as sRGB would be a
    /// duller red and a paler yellow than it applies.
    static let firstTextColour = Color(.sRGB, red: 1, green: 0, blue: 0)
    static let firstHighlight = Color(.sRGB, red: 1, green: 1, blue: 0)

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
    @State private var formatter: TextFormatter = {
        let formatter = TextFormatter()
        formatter.textColour = SignatureEditorLook.firstTextColour
        formatter.highlight = SignatureEditorLook.firstHighlight
        return formatter
    }()
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
            SignatureTextEditor(text: initialText, onChange: { library.setText($0, of: id) }, onReady: { view in
                formatter.attach(view)
                (view as? ComposeTextView)?.onInsertLink = { formatter.insertLink() }
            })
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
                HistoryButton(symbol: "arrow.uturn.backward", title: "Undo", enabled: canUndo) {
                    formatter.editor?.undoManager?.undo()
                }
                .offset(x: 0.5)
                HistoryButton(symbol: "arrow.uturn.forward", title: "Redo", enabled: canRedo) {
                    formatter.editor?.undoManager?.redo()
                }
                .offset(x: -0.5)
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
                    .foregroundStyle(SignatureEditorLook.nameText)
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
                            OverflowStrip().contentShape(Rectangle())
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
            // As ⌘V here: a signature is often designed elsewhere and pasted in whole.
            Button { formatter.pasteKeepingSource() } label: {
                Placements(width: 34, height: 50) {
                    // Outlook's clipboard is a tenth shorter than the symbol drawn at its width.
                    Image(systemName: "doc.on.clipboard")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(ink, Color(red: 0.89, green: 0.62, blue: 0.24))
                        .font(.system(size: 27, weight: .light))
                        .scaleEffect(x: 1, y: 0.91)
                        .frame(width: 28, height: 31)
                        .at(x: 3, y: 0)
                    Text("Paste").font(.system(size: 11)).foregroundStyle(SignatureEditorLook.bright).fixedSize().at(x: 0, baseline: 44.5)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Paste")
            .at(x: 13.5, y: 8.5)
            RibbonSmallButton(title: "Cut", enabled: formatter.editorHasFocus && formatter.hasSelection,
                              glyph: SmallGlyph(symbol: "scissors", size: 12, turn: .degrees(-90), ink: ink)) { formatter.cut() }
                .at(x: 49, y: 10)
            RibbonSmallButton(title: "Copy", enabled: formatter.editorHasFocus && formatter.hasSelection,
                              glyph: CopyGlyph(ink: ink)) { formatter.copy() }
                .at(x: 49, y: 42)
            separator(height: 62).at(x: 82, y: 4)

            FmtPopup(text: formatter.fontName, width: 99, height: 24, textSize: 12, inset: 6,
                     fill: SignatureEditorLook.popupFill, edge: SignatureEditorLook.popupEdge, textInk: SignatureEditorLook.bright,
                     chevron: HeavyChevron(ink: SignatureEditorLook.chevron, drop: 0.5), chevronInset: 4.5) {
                ForEach(TextFormatter.families, id: \.self) { family in Button(family) { formatter.setFontName(family) } }
            }
            .at(x: 93, y: 9)
            FmtPopup(text: sizeText, width: 54, height: 24, textSize: 12, inset: 6,
                     fill: SignatureEditorLook.popupFill, edge: SignatureEditorLook.popupEdge, textInk: SignatureEditorLook.bright,
                     chevron: HeavyChevron(ink: SignatureEditorLook.chevron, drop: 0.5), chevronInset: 4.5) {
                ForEach(TextFormatter.sizes, id: \.self) { size in Button("\(Int(size))") { formatter.setFontSize(size) } }
            }
            .at(x: 194, y: 9)
            // Outlook's list icons are square: its rows stand further apart than the symbols'.
            ListButton(symbol: "list.bullet", title: "Bullets", stretch: 15 / 11) { formatter.applyList(.disc) }
                .at(x: 249.5, y: 8.5)
            menuChevron { Button("Bullets") { formatter.applyList(.disc) } }
                .at(x: 275, y: 9.5)
            ListButton(symbol: "list.number", title: "Numbering", stretch: 16 / 12.5) { formatter.applyList(.decimal) }
                .at(x: 287.5, y: 8.75)
            menuChevron { Button("Numbers") { formatter.applyList(.decimal) } }
                .at(x: 313, y: 9.5)
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
            FmtButton("paragraphsign", "Show paragraph marks", ink: ink, size: 13, box: 24) { formatter.toggleFormattingMarks() }
                .background(formatter.showsFormattingMarks ? SignatureEditorLook.chosen : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .accessibilityAddTraits(formatter.showsFormattingMarks ? .isSelected : [])
                .at(x: 408, y: 9)

            FmtButton("bold", "Bold", ink: ink, size: 14, box: 24) { formatter.toggleBold() }.at(x: 93.5, y: 39.75)
            FmtButton("italic", "Italic", ink: ink, size: 14, box: 24) { formatter.toggleItalic() }.at(x: 119, y: 39.75)
            FmtButton("underline", "Underline", ink: ink, size: 14, box: 24) { formatter.toggleUnderline() }.at(x: 144.5, y: 41)
            Button { formatter.toggleStrikethrough() } label: {
                Text("ab").font(.system(size: 13.5, weight: .thin)).strikethrough().foregroundStyle(ink)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Strikethrough")
            .at(x: 171, y: 41.5)
            separator(height: 18).at(x: 203, y: 44)
            colourButton(Image(systemName: "highlighter").font(.system(size: 13)), "Highlight", colour: formatter.highlight) {
                formatter.setHighlight($0)
            }
            .at(x: 212, y: 41)
            menuChevron {
                ForEach(TextFormatter.highlightPalette, id: \.0) { entry in Button(entry.0) { formatter.setHighlight(entry.1) } }
            }
            .at(x: 237, y: 41.5)
            colourButton(Text("A").font(.system(size: 14.5, weight: .light)), "Text colour", colour: formatter.textColour) {
                formatter.setTextColour($0)
            }
            .at(x: 250, y: 41)
            menuChevron {
                ForEach(TextFormatter.textPalette, id: \.0) { entry in Button(entry.0) { formatter.setTextColour(entry.1) } }
            }
            .at(x: 275, y: 41.5)
            separator(height: 18).at(x: 294, y: 44)
            alignment(.left, "text.alignleft", "Align left", x: 303)
            alignment(.center, "text.aligncenter", "Centre", x: 329)
            alignment(.right, "text.alignright", "Align right", x: 355)
            alignment(.justified, "text.justify", "Justify", x: 381)
            separator(height: 62).at(x: 442, y: 4)

            Button { formatter.insertPicture() } label: {
                Placements(width: 42, height: 50) {
                    // Outlook's picture is an eighth shorter than the symbol drawn at its width.
                    Image(systemName: "photo")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(SignatureEditorLook.accent, ink)
                        .font(.system(size: 27, weight: .light))
                        .scaleEffect(x: 1, y: 0.875)
                        .frame(width: 30, height: 31)
                        .offset(x: 2, y: -1.5)
                    Text("Picture").font(.system(size: 11)).foregroundStyle(SignatureEditorLook.bright).fixedSize().at(x: 0, baseline: 44.5)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Picture")
            .at(x: 455.4, y: 8.5)
        }
    }

    private var sizeText: String {
        let size = formatter.fontSize
        return size == size.rounded() ? "\(Int(size))" : String(format: "%.1f", size)
    }

    private func separator(height: CGFloat) -> some View {
        OLColor.ribbonSeparator.frame(width: 1, height: height)
    }

    /// The chevron beside a list or colour button, which opens its menu.
    private func menuChevron<Items: View>(@ViewBuilder _ items: @escaping () -> Items) -> some View {
        Menu { items() } label: {
            HeavyChevron(ink: SignatureEditorLook.chevron).frame(width: 10, height: 24).contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Highlight and Text colour: the glyph over a bar four points deep in the colour the
    /// button gives; its chevron offers the others.
    private func colourButton(_ glyph: some View, _ title: String, colour: Color, apply: @escaping (Color) -> Void) -> some View {
        Button { apply(colour) } label: {
            Placements(width: 24, height: 24) {
                glyph.foregroundStyle(ink).frame(width: 24, height: 17, alignment: .bottom).at(x: 0, y: 1.5)
                RoundedRectangle(cornerRadius: 0.5).fill(colour).frame(width: 16, height: 4).at(x: 4, y: 16)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }

    /// The alignment the caret's paragraph has is shown on a grey square, as Outlook shows it.
    private func alignment(_ value: NSTextAlignment, _ symbol: String, _ title: String, x: CGFloat) -> some View {
        let current = formatter.alignment == .natural ? NSTextAlignment.left : formatter.alignment
        return FmtButton(symbol, title, ink: ink, size: 15, box: 24) { formatter.align(value) }
            .background(current == value ? SignatureEditorLook.chosen : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            .at(x: x, y: 41)
    }
}

/// Undo and Redo in the editor's title row: Outlook's arrows, sixteen points tall where the
/// symbols are thirteen wide, dimmed once while there is nothing to undo or redo.
private struct HistoryButton: View {
    let symbol: String
    let title: String
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: OL.quickIcon, weight: .regular))
                .scaleEffect(x: 1, y: 16 / 12.5)
                .foregroundStyle(SignatureEditorLook.quick)
                .frame(width: 20, height: 20)
                .opacity(enabled ? 1 : 0.35)
                .background(hovering && enabled ? OLColor.hover : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        // The plain style dims a disabled button again on top of the opacity above.
        .buttonStyle(UndimmedButtonStyle())
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(title)
    }
}

private struct UndimmedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

/// Bullets and Numbering: the symbol with its first layer in Outlook's blue, stretched upright
/// to the square Outlook's icons fill.
private struct ListButton: View {
    let symbol: String
    let title: String
    let stretch: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .symbolRenderingMode(.palette)
                .foregroundStyle(SignatureEditorLook.accent, SignatureEditorLook.ink)
                .scaleEffect(x: 1, y: stretch)
                .frame(width: 24, height: 24)
                .background(hovering ? OLColor.hover : Color.clear, in: RoundedRectangle(cornerRadius: 3))
                .contentShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
    }
}

/// The black strip at the ribbon's right end when the window is narrower than the ribbon:
/// three points below the ribbon's top, edged a shade lighter along its top and left, with a
/// ▶ seven points tall.
private struct OverflowStrip: View {
    var body: some View {
        Placements(width: 15, height: OL.ribbon) {
            SignatureEditorLook.overflowEdge.frame(width: 15, height: OL.ribbon - 3).at(x: 0, y: 3)
            SignatureEditorLook.overflow.frame(width: 14, height: OL.ribbon - 4).at(x: 1, y: 4)
            Path { path in
                path.move(to: .zero)
                path.addLine(to: CGPoint(x: 6, y: 3.5))
                path.addLine(to: CGPoint(x: 0, y: 7))
                path.closeSubpath()
            }
            .fill(SignatureEditorLook.overflowArrow)
            .frame(width: 6, height: 7)
            .at(x: 5, y: 36)
        }
        .frame(width: 15, height: OL.ribbon)
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
        // TextKit 1, as the composer's, for a layout manager that draws as Outlook's editor.
        let storage = NSTextStorage()
        let layout = SignatureLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let view = ComposeTextView(frame: .zero, textContainer: container)
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isRichText = true
        view.importsGraphics = true
        view.pastesSourceFormatting = true
        view.allowsUndo = true
        view.usesFindBar = true
        // An address typed in becomes a link, as in a message; ⌘K makes one of any text.
        view.isAutomaticLinkDetectionEnabled = Preferences.bool(Pref.smartLinks, default: true)
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
        let scroll = NSScrollView()
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

/// Draws the signature as Outlook's editor shows it, without changing what is saved: text in
/// the automatic colour a shade brighter in dark than the system's label colour, and, while ¶ is
/// on, Word's marks for what does not print, as the composer draws them.
final class SignatureLayoutManager: FormattingMarksLayoutManager {
    /// Outlook's automatic text in its dark editor.
    private static let automaticDark = NSColor(hex: 0xF6F6F6)

    override func showCGGlyphs(_ glyphs: UnsafePointer<CGGlyph>, positions: UnsafePointer<CGPoint>, count glyphCount: Int,
                               font: NSFont, textMatrix: CGAffineTransform, attributes: [NSAttributedString.Key: Any] = [:],
                               in context: CGContext) {
        // A link keeps the label colour it was typed in, but the text view draws it in its link
        // colour, which is already the fill here and must not be brightened over.
        if attributes[.link] == nil, let colour = attributes[.foregroundColor] as? NSColor, colour == NSColor.labelColor,
           NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            context.setFillColor(Self.automaticDark.cgColor)
        }
        super.showCGGlyphs(glyphs, positions: positions, count: glyphCount, font: font, textMatrix: textMatrix,
                           attributes: attributes, in: context)
    }
}
