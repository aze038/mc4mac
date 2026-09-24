import SwiftUI
import AppKit
import FalconCore

/// One window per signature, titled with its name, as Outlook opens them from the Signatures
/// pane.
@MainActor
final class SignatureEditorWindows: NSObject, NSWindowDelegate {
    static let shared = SignatureEditorWindows()
    static let size = NSSize(width: 620, height: 400)

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

    /// The editor window, not yet on screen.
    static func window(for id: UUID, library: SignatureLibrary) -> NSWindow? {
        guard let signature = library.signature(id) else { return nil }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = signature.name
        window.contentMinSize = NSSize(width: 460, height: 240)
        let editor = SignatureEditorView(id: id, library: library, initialName: signature.name,
                                         retitle: { [weak window] in window?.title = $0 })
        window.contentView = NSHostingView(rootView: editor.themedRoot())
        return window
    }
}

/// The editor: the name at the top, a small formatting bar, then the signature itself. Every
/// change is handed to the library as it is made; only a change is, so a signature opened just
/// to be read is left exactly as it was.
struct SignatureEditorView: View {
    let id: UUID
    let library: SignatureLibrary
    let retitle: (String) -> Void
    @State private var name: String
    @State private var formatter = TextFormatter()
    @State private var initialText: NSAttributedString

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
            HStack(spacing: 8) {
                Text("Signature name:").font(.system(size: 13))
                TextField("Signature name:", text: $name)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: name) { _, new in
                        library.rename(id, to: new)
                        retitle(library.signature(id)?.name ?? new)
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            formatBar
            Rectangle().fill(OLColor.chromeLine).frame(height: 1)
            SignatureTextEditor(text: initialText, onChange: { library.setText($0, of: id) }, onReady: { formatter.attach($0) })
        }
        .background(OLColor.chrome)
    }

    /// The compose ribbon's own controls, only those a signature needs.
    private var formatBar: some View {
        HStack(spacing: 0) {
            FmtPopup(text: formatter.fontName, width: 120) {
                ForEach(TextFormatter.families, id: \.self) { family in Button(family) { formatter.setFontName(family) } }
            }
            FmtPopup(text: "\(Int(formatter.fontSize))", width: 53) {
                ForEach(TextFormatter.sizes, id: \.self) { size in Button("\(Int(size))") { formatter.setFontSize(size) } }
            }
            .padding(.leading, 8)
            FmtSeparator()
            HStack(spacing: 4) {
                FmtButton("bold", "Bold") { formatter.toggleBold() }
                FmtButton("italic", "Italic") { formatter.toggleItalic() }
                FmtButton("underline", "Underline") { formatter.toggleUnderline() }
            }
            FmtSeparator()
            FmtColourButton("textformat", "Text colour", colour: formatter.textColour, palette: TextFormatter.textPalette) {
                formatter.setTextColour($0)
            }
            FmtSeparator()
            HStack(spacing: 4) {
                FmtButton("link", "Link") { formatter.insertLink() }
                FmtButton("photo", "Picture") { formatter.insertPicture() }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

/// The signature's text: the composer's text view, so pictures and the formatting bar behave
/// as they do in a message.
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
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.backgroundColor = .textBackgroundColor
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
        scroll.backgroundColor = .textBackgroundColor
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
