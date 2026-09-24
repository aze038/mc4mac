#if DEBUG
import SwiftUI
import AppKit
import FalconCore

/// `-FalconMailSnapshot <directory>` draws the compose window's title band and ribbon, the
/// Table picker, the main window's Home ribbon, which shares the compose ribbon's tiles, the
/// Settings window's icon grid, its Signatures pane with two stand-in signatures, with none and
/// with its notice of a damaged file set aside, its Notifications and Sounds pane and every other
/// pane, and a signature's editor window for a signature, for a new one and with ¶ showing the
/// marks for what does not print, in both appearances
/// into PNGs at twice their size in that directory, writes down beside them the words and
/// buttons of the question asked before a signature is deleted, then quits.
/// Nothing is ever put on screen or activated, so they can be measured against Outlook's while
/// the Mac is in use; the settings windows are drawn as they look in front, as Outlook's were
/// captured. Run it with CFFIXED_USER_HOME pointing at an empty folder, so the model reads no
/// mail; the stand-in signatures are held in memory and never saved.
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
            // The menu material's own grey, as it shows over a compose window.
            let ground = name == "dark" ? Color(red: 85 / 255, green: 84 / 255, blue: 90 / 255)
                                        : Color(red: 223 / 255, green: 222 / 255, blue: 228 / 255)
            render(picker.background(ground), size: NSSize(width: 220, height: 240), appearance: appearance,
                   to: "\(directory)/picker-\(name).png")
            render(CommandBar().environment(model).frame(maxHeight: .infinity, alignment: .top),
                   size: NSSize(width: 1728, height: 140), appearance: appearance,
                   to: "\(directory)/home-\(name).png")
        }
        signatures(model, to: directory)
        for (name, appearance) in appearances {
            captureSettings(nil, model: model, active: false, appearance: appearance, to: "\(directory)/settings-grid-\(name).png")
            captureSettings(.notifications, model: model, active: true, appearance: appearance,
                            to: "\(directory)/notifications-\(name).png")
            // A pane that scrolls does not come out of a titled window with a toolbar offscreen on
            // macOS 26, so the other panes are drawn on their own, without the window's buttons.
            for pane in SettingsPane.allCases where pane != .signatures && pane != .notifications {
                render(SettingsRoot(navigator: SettingsNavigator(pane: pane))
                        .environment(\.controlActiveState, .key).environment(model).environmentObject(model.updates).themedRoot(),
                       size: pane.windowSize, appearance: appearance, to: "\(directory)/settings-\(pane.rawValue)-\(name).png")
            }
            // macOS draws an alert's glass, words and buttons itself, so offscreen only its icon
            // comes out; what it says and how its buttons stand is written down instead.
            let alert = SignatureDeletion.alert()
            alert.window.appearance = NSAppearance(named: appearance)
            alert.layout()
            try? describe(alert).write(toFile: "\(directory)/delete-alert-\(name).txt", atomically: true, encoding: .utf8)
        }
        exit(0)
    }

    /// A Settings window at `pane`, built as the app builds it but drawn as it looks in front
    /// when `active`.
    @MainActor private static func captureSettings(_ pane: SettingsPane?, model: AppModel, active: Bool,
                                                   appearance: NSAppearance.Name, to path: String) {
        let navigator = SettingsNavigator(pane: pane)
        let window = SettingsWindows.window(navigator: navigator, model: model, updates: model.updates)
        let root = SettingsRoot(navigator: navigator)
            .environment(\.controlActiveState, active ? .key : .inactive)
            .environment(model)
            .environmentObject(model.updates)
            .themedRoot()
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        window.contentView = host
        window.appearance = NSAppearance(named: appearance)
        guard let frame = window.contentView?.superview else { return }
        capture(frame, appearance: appearance, to: path)
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
        // A new one as the pane's + makes it, named Untitled and holding the first account's name.
        let untitled = book.add(startingWith: accounts[0].displayName)
        let library = SignatureLibrary(book: book)
        for (name, appearance) in appearances {
            model.signatures = SignatureLibrary(book: { var shown = book; shown.remove(untitled.id); return shown }())
            captureSettings(.signatures, model: model, active: true, appearance: appearance, to: "\(directory)/signatures-\(name).png")
            model.signatures = SignatureLibrary(book: SignatureBook())
            captureSettings(.signatures, model: model, active: true, appearance: appearance,
                            to: "\(directory)/signatures-empty-\(name).png")
            let aside = URL(fileURLWithPath: "/signatures-unreadable-1790000000.json")
            model.signatures = SignatureLibrary(book: book, problem: .setAside(aside))
            captureSettings(.signatures, model: model, active: true, appearance: appearance,
                            to: "\(directory)/signatures-notice-\(name).png")
            for (id, file, marks) in [(formal.id, "signature-editor", false), (untitled.id, "signature-editor-new", false),
                                      (formal.id, "signature-editor-marks", true)] {
                guard let window = SignatureEditorWindows.window(for: id, library: library),
                      let frame = window.contentView?.superview else { continue }
                window.appearance = NSAppearance(named: appearance)
                if marks {
                    frame.layoutSubtreeIfNeeded()
                    (textView(in: frame)?.layoutManager as? SignatureLayoutManager)?.showsMarks = true
                }
                capture(frame, appearance: appearance, to: "\(directory)/\(file)-\(name).png")
            }
        }
    }

    @MainActor private static func textView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        for child in view.subviews {
            if let text = textView(in: child) { return text }
        }
        return nil
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

    @MainActor private static var picker: some View {
        let selection = TableGridSelection()
        selection.hovered = TableSize(columns: 3, rows: 4)
        return TableGridPicker(selection: selection, insert: { _ in }, insertCustom: {})
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @MainActor private static func render(_ view: some View, size: NSSize, appearance: NSAppearance.Name, to path: String) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        capture(host, appearance: appearance, to: path)
    }

    @MainActor private static func describe(_ alert: NSAlert) -> String {
        let buttons = alert.buttons.sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        let keys = buttons.map { button -> String in
            switch button.keyEquivalent {
            case "\r": return "\(button.title) (Return, default)"
            case "\u{1b}": return "\(button.title) (Escape)"
            default: return button.title
            }
        }
        return "\(alert.messageText)\n\(alert.informativeText)\nButtons, left to right: \(keys.joined(separator: ", "))\n"
            + "Panel \(Int(alert.window.frame.width)) × \(Int(alert.window.frame.height)) pt\n"
    }

    @MainActor private static func capture(_ view: NSView, appearance: NSAppearance.Name, to path: String) {
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        view.layoutSubtreeIfNeeded()
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
