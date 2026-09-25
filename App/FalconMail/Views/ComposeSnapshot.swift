#if DEBUG
import SwiftUI
import AppKit
import FalconCore

/// `-FalconMailSnapshot <directory>` draws the compose window's title band and ribbon, the
/// ribbon over a body with ¶ showing its marks, the Table picker idle and with a size and text to
/// convert, the address suggestions over a compose window's header, the alert on closing an
/// unsent message, the main window's Home ribbon,
/// which shares the compose ribbon's tiles, the Settings window's icon grid, its Signatures pane
/// with two stand-in signatures, with none and with its notice of a damaged file set aside, its
/// Notifications and Sounds pane and every other pane, the Privacy pane with its diagnostics
/// section as a release build shows it and the sheet of data waiting to be sent, and a
/// signature's editor window for a signature, for a new one and with ¶ showing the marks for
/// what does not print, in both appearances into PNGs at twice their size in that directory,
/// writes down beside them the words and buttons of the question asked before a signature is
/// deleted, and the message list with made-up conversations, then quits. With
/// `-FalconMailSnapshotOnly list` it draws the message list alone.
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
        messageList(model, to: directory)
        if UserDefaults.standard.string(forKey: "FalconMailSnapshotOnly") == "list" { exit(0) }
        for (name, appearance) in appearances {
            render(ribbon(formatter), size: NSSize(width: OL.composeWindowWidth, height: 160), appearance: appearance,
                   to: "\(directory)/ribbon-\(name).png")
            render(composeWithMarks(), size: NSSize(width: OL.composeWindowWidth, height: 380), appearance: appearance,
                   to: "\(directory)/compose-marks-\(name).png")
            let menu = NSSize(width: TableGrid.width, height: 272)
            render(picker(hovering: nil, converts: false), size: menu, appearance: appearance, to: "\(directory)/table-\(name).png")
            render(picker(hovering: TableSize(columns: 3, rows: 4), converts: true), size: menu, appearance: appearance,
                   to: "\(directory)/table-hover-\(name).png")
            suggestions(model, appearance: appearance, to: directory, name: name)
            unsentAlert(appearance: appearance, to: "\(directory)/close-unsent-\(name).png")
            render(CommandBar().environment(model).frame(maxHeight: .infinity, alignment: .top),
                   size: NSSize(width: 1728, height: 140), appearance: appearance,
                   to: "\(directory)/home-\(name).png")
        }
        signatures(model, to: directory)
        // Before the settings panes, so that the Privacy pane shows the release build's stand-in.
        privacy(model, to: directory)
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

    /// The message list at Outlook's width, over made-up mail: an unread conversation opened
    /// out with its newest message selected, read conversations with previews, a paperclip, an
    /// unread count, names too long for their line, senders sent on by a group, one message
    /// whose preview has not arrived, a flag, and dates of today, yesterday and earlier. Drawn
    /// with the list holding the keyboard, as Outlook's was captured, once without, and once
    /// with the pointer on a conversation.
    @MainActor private static func messageList(_ model: AppModel, to directory: String) {
        let account = AccountInfo(email: "alex@example.com", displayName: "Alex Example", provider: "imap",
                                  imapHost: "example.invalid", smtpHost: "example.invalid")
        model.accounts = [account]
        let threads = ListSnapshotMail(accountID: account.id).threads
        model.threads = threads
        model.messages = threads.flatMap(\.messages)
        model.storedInSelection = 300
        model.rebuildRows()
        model.expandedThreadIDs = [threads[0].id]
        model.selectedMessageIDs = [ListRow.childTag(threads[0].messages[0].id)]
        let size = NSSize(width: OL.listWidth, height: 830)
        for (focused, suffix) in [(true, ""), (false, "-unfocused")] {
            MessageListView.snapshotListHasKeyboard = focused
            for (name, appearance) in appearances {
                render(MessageListView().environment(model).environmentObject(model.updates).themedRoot(),
                       size: size, appearance: appearance, to: "\(directory)/list\(suffix)-\(name).png")
            }
        }
        // The pointer on the conversation with the count, its quick actions over its icons.
        MessageListView.snapshotListHasKeyboard = true
        ConversationRow.snapshotHoveredID = threads[4].id
        render(MessageListView().environment(model).environmentObject(model.updates).themedRoot(),
               size: size, appearance: .darkAqua, to: "\(directory)/list-hover-dark.png")
        ConversationRow.snapshotHoveredID = nil
        MessageListView.snapshotListHasKeyboard = nil
        model.threads = []
        model.messages = []
        model.expandedThreadIDs = []
        model.selectedMessageIDs = []
        model.rebuildRows()
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

    /// As a release build shows it. The waiting data is what a real diagnostics centre makes of
    /// a few of the engine's failures and an alert, given as the engine gives them, kept in a
    /// temporary folder and never started on the network: it reads no crash reports, its session
    /// refuses every request, and it is stopped before its first upload is due a minute later.
    @MainActor private static func privacy(_ model: AppModel, to directory: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FalconMailSnapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let center = DiagnosticsCenter(
            directory: folder,
            gate: DiagnosticsGate(endpoint: URL(string: "https://example.invalid/exec"), key: "snapshot", isReleaseBuild: true,
                                  bundleIdentifier: DiagnosticsGate.releaseBundleIdentifier, userEnabled: true),
            environment: DiagnosticsEnvironment(app: DiagnosticsApp(version: "1.10.0", build: "123", channel: "release"),
                                                os: "macOS 26.6 (25G5023)", hardware: "MacBookPro18,3", locale: "en_GB",
                                                homePath: NSHomeDirectory()),
            crashReportsDirectory: nil,
            session: DiagnosticsUploader.makeSession(protocolClasses: [NoNetwork.self]))
        let logging = Log.isEnabled
        Log.isEnabled = false
        center.start()
        let account = AccountInfo.google(email: "alex@example.com", displayName: "Alex Example")
        let throttled = MailServiceError(kind: .throttled, account: account, detail: "BYE [THROTTLED] Account exceeded command or bandwidth limits.")
        for _ in 0..<3 {
            Log.failure("IMAP", throttled, "alex@example.com: throttled: \(throttled.detail)", account: account, logAs: "sync",
                        keeping: account.email)
        }
        let gone = MailServiceError(kind: .messageGone, account: account, detail: "UID 4127 not returned")
        Log.failure("Open", gone, "alex@example.com: opening a message in Clients/ACME failed: messageGone: \(gone.detail)",
                    account: account, names: ["Clients/ACME", "ACME"], logAs: "sync", keeping: account.email)
        Log.error("Alert", "The file “Invoice ACME.pdf” couldn’t be opened because there is no such file.")
        center.waitUntilIdle()
        let waiting = center.pendingDescription()
        center.stop()
        Log.isEnabled = logging

        DiagnosticsService.shared = DiagnosticsService(standInID: center.diagnosticsID)
        for (name, appearance) in appearances {
            render(DiagnosticsPendingSheet(text: waiting).background(Color(nsColor: .windowBackgroundColor)),
                   size: NSSize(width: 640, height: 520), appearance: appearance, to: "\(directory)/privacy-waiting-\(name).png")
        }
    }

    /// Fails every request, so nothing the snapshot builds can reach a network.
    private final class NoNetwork: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
        override func stopLoading() {}
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

    /// The ribbon over the body a compose window writes in, ¶ turned on through the formatter
    /// before the body is attached to it, as when SwiftUI makes a body again: the button lit and
    /// the body's paragraph ends, spaces and tabs marked, down to the empty line after its last
    /// line break.
    @MainActor private static func composeWithMarks() -> some View {
        let formatter = TextFormatter()
        formatter.toggleFormattingMarks()
        let body = NSMutableAttributedString(string: "Hello Sam,\n\nThe figures for this week are below.\n", attributes: RichText.bodyAttributes)
        body.append(NSAttributedString(string: "North\t1,240\nSouth\t985\n\n", attributes: RichText.bodyAttributes))
        body.append(NSAttributedString(string: "The full report is at ", attributes: RichText.bodyAttributes))
        body.append(NSAttributedString(string: "example.com", attributes: RichText.bodyAttributes.merging([
            .link: URL(string: "https://example.com")!]) { $1 }))
        body.append(NSAttributedString(string: ".\n\nBest wishes,\nAlex\n", attributes: RichText.bodyAttributes))
        return VStack(spacing: 0) {
            OLColor.chrome.frame(height: OL.titleRow)
            ComposeRibbon(tab: .constant(.message), formatter: formatter, showsBcc: .constant(false),
                          importance: .constant("normal"), canSend: false, onSend: {}, onAttachFile: {},
                          onAttachFromDrive: {}, signatures: [], onInsertSignature: { _ in }, onEditSignatures: {},
                          onInsertTableDialog: {}, onCycleBackground: {})
            Rectangle().fill(OLColor.chromeLine).frame(height: 1)
            RichTextEditor(rtf: .constant(RichText.rtf(from: body)), plain: .constant(body.string)) { view in
                Task { @MainActor in formatter.attach(view) }
            }
        }
        .background(OLColor.reading)
    }

    @MainActor private static func picker(hovering size: TableSize?, converts: Bool) -> some View {
        let selection = TableGridSelection()
        selection.hovered = size
        return TableGridPicker(selection: selection, insert: { _ in }, insertCustom: {}, convertText: converts ? {} : nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The address suggestions as a compose window shows them: its own header with "kam" typed
    /// in To, and over it the list where the field hangs its window, placed by the field's own
    /// reckoning, since a child window is not drawn with the window it hangs from. The list holds
    /// a contact with a label and two recent addresses, the middle one highlighted, the last two
    /// too long for their columns. Cut twice to Outlook's captures: the list alone, framed from
    /// the outside of the To box's foot and left edge, and the list in context, that corner 67
    /// points in and 100 down.
    @MainActor private static func suggestions(_ model: AppModel, appearance: NSAppearance.Name, to directory: String, name: String) {
        var draft = ComposeDraft(accountID: UUID())
        draft.to = "kam"
        let id = model.newDraft(draft)
        defer { model.drafts[id] = nil }
        // Titled, with its content under the title bar, as a compose window is: the view dresses
        // its window's title bar, and a borderless window has none to dress.
        let compose = host(ComposeView(draftID: id).themedRoot().environment(model).environmentObject(model.updates),
                           size: NSSize(width: OL.composeWindowWidth, height: 480), appearance: appearance,
                           style: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        let rows = [
            RecipientSuggestion(name: "Kamal Muradov", email: "kamal.muradov@example.com", label: "Work"),
            RecipientSuggestion(name: "kamal-muradov-example", email: "notifications@example.com", isRecentAddress: true),
            RecipientSuggestion(name: "kamal-muradov-example/example-project-tools",
                                email: "example-project-tools@noreply.example.com", isRecentAddress: true),
        ]
        let list = NSHostingView(rootView: SuggestionList(rows: rows, highlighted: 1, accept: { _ in }, highlight: { _ in },
                                                          remove: { _ in }))
        let listSize = list.fittingSize
        guard let drawnWindow = image(of: compose, appearance: appearance),
              let drawnList = image(of: host(list, size: listSize, appearance: appearance), appearance: appearance),
              let box = views(of: RecipientSuggestions.AnchorView.self, in: compose)
                  .map({ $0.convert($0.bounds, to: nil) }).max(by: { $0.maxY < $1.maxY })
        else { return }
        // The content reaches under the title bar, so it is taller than asked for.
        let size = compose.bounds.size
        guard let shown = draw([(drawnWindow, NSRect(origin: .zero, size: size)),
                                (drawnList, RecipientSuggestions.panelFrame(under: box, size: listSize))], size: size)
        else { return }
        let corner = box.insetBy(dx: -SuggestionLook.boxBorderOutside, dy: -SuggestionLook.boxBorderOutside).origin
        let cuts = [("suggestions", NSRect(x: corner.x, y: corner.y - 148, width: 516, height: 148)),
                    ("suggestions-in-context", NSRect(x: corner.x - 67, y: corner.y - 10, width: 500, height: 110))]
        for (cut, rect) in cuts {
            write(draw([(shown, NSRect(x: -rect.minX, y: -rect.minY, width: size.width, height: size.height))], size: rect.size),
                  to: "\(directory)/\(cut)-\(name).png")
        }
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

    /// Every view of `type` under `view`.
    @MainActor private static func views<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { ($0 as? T).map { [$0] } ?? views(of: type, in: $0) }
    }

    /// Bitmaps laid over one another in a new one `size` points big, each in its rectangle.
    private static func draw(_ layers: [(NSBitmapImageRep, NSRect)], size: NSSize) -> NSBitmapImageRep? {
        guard let rep = bitmap(size) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (layer, rect) in layers {
            layer.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
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
        capture(host(view, size: size, appearance: appearance), appearance: appearance, to: path)
    }

    /// `view`, `size` points big, as the content of a window in `appearance` that is never shown.
    @MainActor private static func host<V: NSView>(_ view: V, size: NSSize, appearance: NSAppearance.Name,
                                                   style: NSWindow.StyleMask = [.borderless]) -> V {
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: style, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        return view
    }

    @MainActor private static func host(_ view: some View, size: NSSize, appearance: NSAppearance.Name,
                                        style: NSWindow.StyleMask = [.borderless]) -> NSView {
        host(NSHostingView(rootView: view), size: size, appearance: appearance, style: style)
    }

    @MainActor private static func capture(_ view: NSView, appearance: NSAppearance.Name, ground: NSColor? = nil, to path: String) {
        write(image(of: view, appearance: appearance, ground: ground), to: path)
    }

    @MainActor private static func image(of view: NSView, appearance: NSAppearance.Name, ground: NSColor? = nil) -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        view.layoutSubtreeIfNeeded()
        let size = view.bounds.size
        guard var rep = bitmap(size) else { return nil }
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
        return rep
    }

    private static func write(_ rep: NSBitmapImageRep?, to path: String) {
        try? rep?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private static func bitmap(_ size: NSSize) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = size
        return rep
    }
}
/// Made-up mail for the message list's snapshot: every name, address and subject is invented.
private struct ListSnapshotMail {
    let accountID: UUID
    private let folderID = UUID()
    private let now = Date()

    private var startOfToday: Date { Calendar.current.startOfDay(for: now) }

    /// Earlier today, however soon after midnight the snapshot is drawn.
    private func today(_ share: Double) -> Date { startOfToday + now.timeIntervalSince(startOfToday) * share }

    private func daysAgo(_ days: Int, hour: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: startOfToday)! + Double(hour) * 3_600
    }

    private func message(_ uid: UInt32, _ name: String, _ address: String, _ subject: String, _ date: Date,
                         read: Bool = true, flagged: Bool = false, attachment: Bool = false, preview: String = "") -> MessageSummary {
        var flags: MessageFlags = read ? [.seen] : []
        if flagged { flags.insert(.flagged) }
        return MessageSummary(accountID: accountID, folderID: folderID, uid: uid, messageID: "<\(uid)@example.com>",
                              inReplyTo: "", references: [], subject: subject, from: EmailAddress(name: name, address: address),
                              to: [EmailAddress(name: "Alex Example", address: "alex@example.com")], cc: [], date: date,
                              flags: flags, size: 12_000, snippet: preview, hasAttachments: attachment)
    }

    var threads: [MessageThread] {
        let route = "ROUTE 14B - INVOICE 2231 - PO88K"
        let maya = ("Maya Lindqvist", "maya@example.com")
        let mayaLong = ("Maya Lindqvist-Barrington", "maya@example.com")
        let tom = ("Tom Okafor", "tom@example.net")
        let opened = MessageThread(messages: [
            message(101, maya.0, maya.1, route, today(0.95), read: false, preview: "Please find the corrected invoice attached."),
            message(100, tom.0, tom.1, "RE: " + route, today(0.9)),
            message(99, mayaLong.0, mayaLong.1, "RE: " + route, daysAgo(1, hour: 21)),
            message(98, tom.0, tom.1, "RE: " + route, daysAgo(1, hour: 18)),
            message(97, mayaLong.0, mayaLong.1, "RE: " + route, daysAgo(2, hour: 16)),
            message(96, tom.0, tom.1, "RE: " + route, daysAgo(2, hour: 15)),
            message(95, mayaLong.0, mayaLong.1, route, daysAgo(2, hour: 11)),
        ])
        let dock = MessageThread(messages: [
            message(90, "Ravi Patel", "ravi@example.org", "Dock schedule change from Monday", today(0.5), flagged: true,
                    preview: "Hi all, from Monday the dock opens at 06:00 instead of 07:00."),
        ])
        let pallets = MessageThread(messages: [
            message(82, "Priya Raman", "priya@example.com", "Pallet count for Tuesday", daysAgo(1, hour: 17), attachment: true,
                    preview: "Good afternoon, if you are going to file a claim for the damaged pallets, send the photos by Friday."),
            message(81, "Daniel Hughes", "daniel@example.net", "Pallet count for Tuesday", daysAgo(1, hour: 12)),
            message(80, "Priya Raman", "priya@example.com", "Pallet count for Tuesday", daysAgo(1, hour: 10)),
        ])
        let weekly = MessageThread(messages: [
            message(70, "'Northwind Weekly' via Example Group", "group@example.com",
                    "Northwind Weekly: your roundup of warehouse automation news", daysAgo(1, hour: 16),
                    preview: "September insights worth bookmarking before the peak season starts"),
        ])
        let order = MessageThread(messages: [
            message(62, "Oliver Brandt", "oliver@example.com", "Sales order 4471-B", daysAgo(1, hour: 15), read: false,
                    attachment: true, preview: "Sounds good, thank you for the update. -- Oliver"),
            message(61, "'Carmen Ortiz' via Example Group", "group@example.com", "Sales order 4471-B", daysAgo(1, hour: 14),
                    read: false),
            message(60, "Sam Lee", "sam@example.org", "Sales order 4471-B", daysAgo(1, hour: 9)),
        ])
        let harbour = MessageThread(messages: [
            message(50, "'Harbour Freight Lines' via Example Group", "group@example.com",
                    "On a tight timeline? Harbour Freight collects the same day", daysAgo(1, hour: 8),
                    preview: "Explore guaranteed LTL, exclusive-use equipment and more with one call."),
        ])
        let statement = MessageThread(messages: [
            message(40, "Alexandria Montgomery-Fitzgerald of Example Logistics International", "accounts@example.com",
                    "STATEMENT SUMMARY", daysAgo(3, hour: 9),
                    preview: "Dear customer, your statement for September is attached to this message."),
        ])
        let customs = MessageThread(messages: [
            message(31, "Hannah Weber", "hannah@example.net", "Customs paperwork for container 7", daysAgo(12, hour: 13)),
            message(30, "Ravi Patel", "ravi@example.org", "Customs paperwork for container 7", daysAgo(12, hour: 10)),
        ])
        return [opened, dock, pallets, weekly, order, harbour, statement, customs]
    }
}
#endif
