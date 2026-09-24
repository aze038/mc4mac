#if DEBUG
import SwiftUI
import AppKit
import FalconCore

/// `-FalconMailSnapshot <directory>` draws the compose window's title band and ribbon, the
/// Table picker idle and with a size and text to convert, the address suggestions under a
/// recipient field, the alert on closing an unsent message, the main window's Home ribbon,
/// which shares the compose ribbon's tiles, the Signatures pane with two stand-in signatures,
/// with none and with its notice of a damaged file set aside, and a signature's editor window,
/// in both appearances into PNGs at twice their size in that directory, then quits. Nothing is ever put on screen or activated, so
/// they can be measured against Outlook's while the Mac is in use. Run it with
/// CFFIXED_USER_HOME pointing at an empty folder, so the model reads no mail; the stand-in
/// signatures are held in memory and never saved.
enum ComposeSnapshot {
    private static let appearances: [(String, NSAppearance.Name)] = [("dark", .darkAqua), ("light", .aqua)]

    @MainActor static func runIfRequested() {
        guard let directory = UserDefaults.standard.string(forKey: "FalconMailSnapshot") else { return }
        NSApplication.shared.setActivationPolicy(.prohibited)
        // A body that exists but has not been clicked, as in a fresh message.
        let formatter = TextFormatter()
        formatter.attach(ComposeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200)))
        let model = AppModel()
        for (name, appearance) in appearances {
            render(ribbon(formatter), size: NSSize(width: OL.composeWindowWidth, height: 160), appearance: appearance,
                   to: "\(directory)/ribbon-\(name).png")
            let menu = NSSize(width: TableGrid.width, height: 272)
            render(picker(hovering: nil, converts: false), size: menu, appearance: appearance, to: "\(directory)/table-\(name).png")
            render(picker(hovering: TableSize(columns: 3, rows: 4), converts: true), size: menu, appearance: appearance,
                   to: "\(directory)/table-hover-\(name).png")
            render(suggestions, size: NSSize(width: 516, height: 148), appearance: appearance,
                   to: "\(directory)/suggestions-\(name).png")
            unsentAlert(appearance: appearance, to: "\(directory)/close-unsent-\(name).png")
            render(CommandBar().environment(model).frame(maxHeight: .infinity, alignment: .top),
                   size: NSSize(width: 1728, height: 140), appearance: appearance,
                   to: "\(directory)/home-\(name).png")
        }
        signatures(model, to: directory)
        exit(0)
    }

    @MainActor private static func signatures(_ model: AppModel, to directory: String) {
        let accounts = [
            AccountInfo(email: "alex@example.com", displayName: "Alex Example", provider: "imap",
                        imapHost: "example.invalid", smtpHost: "example.invalid"),
            AccountInfo(email: "office@example.com", displayName: "Example Office", provider: "imap",
                        imapHost: "example.invalid", smtpHost: "example.invalid"),
        ]
        model.accounts = accounts
        var book = SignatureBook()
        let formal = book.add()
        book.rename(formal.id, to: "Formal")
        book.setText(formalText(), of: formal.id)
        let short = book.add()
        book.rename(short.id, to: "Short")
        book.setText(NSAttributedString(string: "Alex", attributes: RichText.bodyAttributes), of: short.id,
                     plainIn: RichText.bodyAttributes)
        book.setDefault(formal.id, for: accounts[0].id, .newMessages)
        book.setDefault(short.id, for: accounts[0].id, .replies)
        let library = SignatureLibrary(book: book)
        let pane = NSSize(width: 760, height: 620)
        for (name, appearance) in appearances {
            model.signatures = library
            render(SettingsView(pane: .signatures).environment(model), size: pane, appearance: appearance,
                   to: "\(directory)/signatures-\(name).png")
            model.signatures = SignatureLibrary(book: SignatureBook())
            render(SettingsView(pane: .signatures).environment(model), size: pane, appearance: appearance,
                   to: "\(directory)/signatures-empty-\(name).png")
            let aside = URL(fileURLWithPath: "/signatures-unreadable-1790000000.json")
            model.signatures = SignatureLibrary(book: book, problem: .setAside(aside))
            render(SettingsView(pane: .signatures).environment(model), size: pane, appearance: appearance,
                   to: "\(directory)/signatures-notice-\(name).png")
            guard let window = SignatureEditorWindows.window(for: formal.id, library: library),
                  let frame = window.contentView?.superview else { continue }
            window.appearance = NSAppearance(named: appearance)
            capture(frame, appearance: appearance, to: "\(directory)/signature-editor-\(name).png")
        }
    }

    /// A signature with what the editor can do: a bold name, a coloured line, a link and a
    /// picture.
    @MainActor private static func formalText() -> NSAttributedString {
        let body = RichText.bodyAttributes
        let text = NSMutableAttributedString(string: "Alex Example\n", attributes: body.merging([
            .font: NSFontManager.shared.convert(RichText.defaultFont, toHaveTrait: .boldFontMask)]) { $1 })
        text.append(NSAttributedString(string: "Operations Manager, Example Ltd\n", attributes: body))
        text.append(NSAttributedString(string: "+44 20 7946 0000\n", attributes: body.merging([.foregroundColor: NSColor.systemBlue]) { $1 }))
        text.append(NSAttributedString(string: "example.com\n", attributes: body.merging([.link: URL(string: "https://example.com")!]) { $1 }))
        if let logo = logo() { text.append(NSAttributedString(attachment: logo)) }
        return text
    }

    @MainActor private static func logo() -> NSTextAttachment? {
        let size = NSSize(width: 96, height: 28)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.systemTeal.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 5, yRadius: 5).fill()
        NSAttributedString(string: "EXAMPLE", attributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.white])
            .draw(at: NSPoint(x: 18, y: 6))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let file = FileWrapper(regularFileWithContents: png)
        file.preferredFilename = "logo.png"
        return NSTextAttachment(fileWrapper: file)
    }

    @MainActor private static func ribbon(_ formatter: TextFormatter) -> some View {
        VStack(spacing: 0) {
            OLColor.chrome.frame(height: OL.titleRow)
            ComposeRibbon(tab: .constant(.message), formatter: formatter, showsBcc: .constant(false),
                          importance: .constant("normal"), canSend: false, onSend: {}, onAttachFile: {},
                          onAttachFromDrive: {}, signatures: [], onInsertSignature: { _ in }, onEditSignatures: {},
                          onInsertTableDialog: {}, onCycleBackground: {})
            Rectangle().fill(OLColor.chromeLine).frame(height: 1)
            OLColor.sidebar
        }
    }

    @MainActor private static func picker(hovering size: TableSize?, converts: Bool) -> some View {
        let selection = TableGridSelection()
        selection.hovered = size
        return TableGridPicker(selection: selection, insert: { _ in }, insertCustom: {}, convertText: converts ? {} : nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Outlook's capture in the same frame: the left edge on the recipient field's, the field's
    /// foot five points down, the list hung from it where the field would hang it, over a
    /// contact with a label and two recent addresses, the middle one highlighted, the last two
    /// too long for their columns.
    @MainActor private static var suggestions: some View {
        let rows = [
            RecipientSuggestion(name: "Kamal Muradov", email: "kamal.muradov@example.com", label: "Work"),
            RecipientSuggestion(name: "kamal-muradov-example", email: "notifications@example.com", isRecentAddress: true),
            RecipientSuggestion(name: "kamal-muradov-example/example-project-tools",
                                email: "example-project-tools@noreply.example.com", isRecentAddress: true),
        ]
        return ZStack(alignment: .topLeading) {
            OLColor.reading
            SuggestionList(rows: rows, highlighted: 1, accept: { _ in }, highlight: { _ in }, remove: { _ in })
                .fixedSize()
                .padding(.leading, SuggestionLook.bodyX)
                .padding(.top, 5)
        }
    }

    /// The alert's own content: its glass cannot be drawn off screen, so the content is laid on
    /// the window background colour, and a window that is not key draws its default button grey
    /// rather than blue.
    @MainActor private static func unsentAlert(appearance: NSAppearance.Name, to path: String) {
        let alert = UnsentMessageAlert.make()
        alert.window.appearance = NSAppearance(named: appearance)
        alert.layout()
        guard let content = alert.window.contentView else { return }
        capture(content, appearance: appearance, ground: .windowBackgroundColor, to: path)
    }

    @MainActor private static func render(_ view: some View, size: NSSize, appearance: NSAppearance.Name, to path: String) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        capture(host, appearance: appearance, to: path)
    }

    @MainActor private static func capture(_ view: NSView, appearance: NSAppearance.Name, ground: NSColor? = nil, to path: String) {
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        view.layoutSubtreeIfNeeded()
        let size = view.bounds.size
        guard var rep = bitmap(size) else { return }
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        if let ground, let grounded = bitmap(size) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: grounded)
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                ground.setFill()
                NSRect(origin: .zero, size: size).fill()
                rep.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1,
                         respectFlipped: false, hints: nil)
            }
            NSGraphicsContext.restoreGraphicsState()
            rep = grounded
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private static func bitmap(_ size: NSSize) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = size
        return rep
    }
}
#endif
