import SwiftUI
import AppKit
import ObjectiveC
import FalconCore

/// Which kind of window is key, for the commands that act on the one in front.
enum FrontWindow: Equatable {
    case mailbox
    case popup(PopupKey)
    case other

    var popup: PopupKey? {
        if case .popup(let key) = self { return key }
        return nil
    }
}

/// The message and compose windows of their own, and the tray along the foot of the mailbox
/// window that FalconMail minimises them into instead of the Dock.
@MainActor
final class WindowTray: ObservableObject {
    static let shared = WindowTray()
    static let popupIdentifier = "falcon.popup"

    @Published private(set) var book = WindowTrayBook()
    /// Opens a window for an entry the tray holds without one, as a message window put back
    /// into the tray at launch has until it is first shown.
    var openWindow: (@MainActor (PopupKey) -> Void)?
    /// Told whenever another window comes to the front.
    var frontChanged: (@MainActor (FrontWindow) -> Void)?
    private var popups: [WeakWindow] = []
    private var popupWindows: [PopupKey: WeakWindow] = [:]
    private var mailboxWindows: [WeakWindow] = []
    private var observers: [NSObjectProtocol] = []
    private var front = FrontWindow.mailbox {
        didSet { if front != oldValue { frontChanged?(front) } }
    }

    private init() {
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] n in
            guard let w = n.object as? NSWindow else { return }
            MainActor.assumeIsolated { self?.becameKey(w) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] n in
            guard let w = n.object as? NSWindow else { return }
            MainActor.assumeIsolated { self?.willClose(w) }
        })
    }

    private func becameKey(_ window: NSWindow) {
        front = kind(of: window)
        if let key = key(for: window) { book.showing(key, title: window.title) }
    }

    private func willClose(_ window: NSWindow) {
        if let key = key(for: window) {
            book.closed(key)
            popupWindows[key] = nil
            if front == .popup(key) { front = .other }
        }
        popups.removeAll { $0.window == nil || $0.window === window }
        mailboxWindows.removeAll { $0.window == nil || $0.window === window }
    }

    private func kind(of window: NSWindow) -> FrontWindow {
        if mailboxWindows.contains(where: { $0.window === window }) { return .mailbox }
        if let key = key(for: window) { return .popup(key) }
        return .other
    }

    private func key(for window: NSWindow) -> PopupKey? {
        popupWindows.first { $0.value.window === window }?.key
    }

    func window(for key: PopupKey) -> NSWindow? {
        popupWindows[key]?.window
    }

    func register(mailbox window: NSWindow) {
        mailboxWindows.removeAll { $0.window == nil }
        guard !mailboxWindows.contains(where: { $0.window === window }) else { return }
        mailboxWindows.append(WeakWindow(window))
        if window.isKeyWindow { front = .mailbox }
    }

    var mailboxWindowTakesUndo: Bool {
        guard let key = NSApp.keyWindow, mailboxWindows.contains(where: { $0.window === key }) else { return false }
        return !(key.firstResponder is NSText)
    }

    var mailboxWindowIsShowing: Bool {
        NSApp.isActive && mailboxWindows.contains { $0.window?.isVisible == true }
    }

    /// The mailbox window a question about one of its tabs belongs over: the key one, else the
    /// last one showing.
    var frontMailboxWindow: NSWindow? {
        let windows = mailboxWindows.compactMap(\.window)
        return windows.first { $0.isKeyWindow } ?? windows.last { $0.isVisible }
    }

    func orderMailboxWindowFront() -> Bool {
        mailboxWindows.removeAll { $0.window == nil }
        let candidates = mailboxWindows.compactMap { $0.window }
        guard let window = candidates.last(where: { $0.isVisible || $0.isMiniaturized }) else { return false }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// A message or compose window, holding what `key` names, has come on screen.
    func register(popup window: NSWindow, key: PopupKey) {
        popupWindows[key] = WeakWindow(window)
        book.showing(key, title: window.title)
        if window.isKeyWindow { front = .popup(key) }
        guard !popups.contains(where: { $0.window === window }) else { return }
        window.identifier = NSUserInterfaceItemIdentifier(WindowTray.popupIdentifier)
        popups.removeAll { $0.window == nil }
        if let anchor = popups.last?.window, anchor.isVisible { place(window, beside: anchor) }
        popups.append(WeakWindow(window))
    }

    private func place(_ window: NSWindow, beside anchor: NSWindow) {
        guard let screen = anchor.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        frame.size.height = anchor.frame.height
        frame.origin.y = anchor.frame.origin.y
        let gap: CGFloat = 12
        if anchor.frame.maxX + gap + frame.width <= visible.maxX {
            frame.origin.x = anchor.frame.maxX + gap
        } else if anchor.frame.minX - gap - frame.width >= visible.minX {
            frame.origin.x = anchor.frame.minX - gap - frame.width
        } else {
            let half = (visible.width - gap) / 2
            var left = anchor.frame
            left.origin.x = visible.minX
            left.size.width = half
            anchor.setFrame(left, display: true, animate: true)
            frame.origin.x = visible.minX + half + gap
            frame.size.width = half
        }
        window.setFrame(frame, display: true, animate: false)
    }

    /// The yellow button, Minimize in the Window menu or Command-M on a message or compose
    /// window: into the tray, out of sight.
    func minimize(_ window: NSWindow) {
        // The hook swapped the two, so this is AppKit's own minimise, to the Dock.
        guard let key = key(for: window) else { return window.falcon_miniaturize(nil) }
        book.minimise(key, title: window.title)
        window.orderOut(nil)
    }

    /// Puts a message back into the tray without a window, as a launch does with those that were
    /// in the tray at the last quit; its window opens when it is taken out.
    func shelve(_ key: PopupKey, title: String) {
        guard window(for: key) == nil else { return }
        book.minimise(key, title: title)
    }

    /// Brings `key`'s window to the front, from the tray if it is there. False when no window
    /// holds it, and one should be opened.
    func bringForward(_ key: PopupKey) -> Bool {
        switch book.opening(key) {
        case .open:
            return false
        case .bringForward:
            guard let window = window(for: key) else {
                book.closed(key)
                return false
            }
            window.makeKeyAndOrderFront(nil)
            return true
        case .restoreFromTray:
            restore(key)
            return true
        }
    }

    func restore(_ key: PopupKey) {
        guard let window = window(for: key) else {
            book.closed(key)
            openWindow?(key)
            return
        }
        book.restore(key)
        window.makeKeyAndOrderFront(nil)
    }

    /// The tray's close button.
    func close(_ key: PopupKey) {
        guard let window = window(for: key) else { return book.closed(key) }
        // A window that may ask before it closes, as a message not yet sent does, comes back
        // first, so its question has somewhere to appear.
        if window.closeGuard != nil {
            window.makeKeyAndOrderFront(nil)
            window.performClose(nil)
        } else {
            window.close()
        }
    }

    /// Close Window in the Message menu, or Command-W, on the message or compose window in front.
    func performClose(_ key: PopupKey) {
        window(for: key)?.performClose(nil)
    }

    nonisolated static func installMinimizeHook() {
        if let original = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.miniaturize(_:))),
           let replacement = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.falcon_miniaturize(_:))) {
            method_exchangeImplementations(original, replacement)
        }
        if let original = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.performMiniaturize(_:))),
           let replacement = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.falcon_performMiniaturize(_:))) {
            method_exchangeImplementations(original, replacement)
        }
    }

    /// Routes the close button, Close in the File menu and Command-W through a window's close
    /// guard. SwiftUI keeps its windows' delegates to itself, so windowShouldClose is not ours to
    /// answer; a window without a guard closes as it always did.
    nonisolated static func installCloseHook() {
        if let original = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.performClose(_:))),
           let replacement = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.falcon_performClose(_:))) {
            method_exchangeImplementations(original, replacement)
        }
    }
}

final class WeakWindow {
    weak var window: NSWindow?
    init(_ w: NSWindow) { window = w }
}

private var closeGuardKey: UInt8 = 0

extension NSWindow {
    /// Asked before the window closes at the user's request; false keeps it open, as when an
    /// alert has gone up that will close it or not once answered. Closing it from code, as
    /// sending a message does, is never asked.
    var closeGuard: (@MainActor (NSWindow) -> Bool)? {
        get { objc_getAssociatedObject(self, &closeGuardKey) as? @MainActor (NSWindow) -> Bool }
        set { objc_setAssociatedObject(self, &closeGuardKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    @objc func falcon_performClose(_ sender: Any?) {
        if let closeGuard, !closeGuard(self) { return }
        falcon_performClose(sender)
    }

    @objc func falcon_miniaturize(_ sender: Any?) {
        if identifier?.rawValue == WindowTray.popupIdentifier {
            MainActor.assumeIsolated { WindowTray.shared.minimize(self) }
        } else {
            falcon_miniaturize(sender)
        }
    }

    @objc func falcon_performMiniaturize(_ sender: Any?) {
        if identifier?.rawValue == WindowTray.popupIdentifier {
            MainActor.assumeIsolated { WindowTray.shared.minimize(self) }
        } else {
            falcon_performMiniaturize(sender)
        }
    }
}

/// Dresses the message or compose window this sits in as Outlook's, and tells the tray which
/// message it holds.
struct PopupWindowAccessor: NSViewRepresentable {
    let key: PopupKey

    func makeNSView(context: Context) -> AccessorView {
        let view = AccessorView()
        view.key = key
        return view
    }

    func updateNSView(_ nsView: AccessorView, context: Context) {}

    final class AccessorView: NSView {
        var key: PopupKey?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let key else { return }
            // Message and compose windows draw Outlook's own title row too.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.toolbar = nil
            window.titlebarSeparatorStyle = .none
            DispatchQueue.main.async {
                window.toolbar = nil
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                while !window.titlebarAccessoryViewControllers.isEmpty { window.removeTitlebarAccessoryViewController(at: 0) }
            }
            WindowTray.shared.register(popup: window, key: key)
        }
    }
}

struct MailboxWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> AccessorView { AccessorView() }
    func updateNSView(_ nsView: AccessorView, context: Context) {}

    final class AccessorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // The chrome draws its own title row, Outlook's way: the window's title bar is see-through
            // and the traffic lights sit over the chrome.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.toolbar = nil
            WindowTray.shared.register(mailbox: window)
        }
    }
}

struct WindowTrayBar: View {
    @ObservedObject var tray = WindowTray.shared
    @Environment(AppModel.self) private var model

    var body: some View {
        if !tray.book.tray.isEmpty || !model.minimizedTabs.isEmpty {
            HStack(spacing: 8) {
                ForEach(model.minimizedTabs) { tab in
                    HStack(spacing: 6) {
                        Image(systemName: model.icon(for: tab)).font(.caption)
                        Text(model.title(for: tab)).font(.caption).lineLimit(1).frame(maxWidth: 220)
                        Button { model.closeTabAsked(tab) } label: { Image(systemName: "xmark.circle.fill").font(.caption) }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .onTapGesture { model.openTab(tab) }
                }
                ForEach(tray.book.tray) { entry in
                    HStack(spacing: 6) {
                        Image(systemName: WindowTrayBar.icon(for: entry.key)).font(.caption)
                        Text(WindowTrayBar.title(for: entry)).font(.caption).lineLimit(1).frame(maxWidth: 260)
                        Button { tray.close(entry.key) } label: { Image(systemName: "xmark.circle.fill").font(.caption) }
                            .buttonStyle(.plain)
                            .help("Close")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture { tray.restore(entry.key) }
                    .help("Show this window again")
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(.bar)
        }
    }

    /// The same glyphs a message and a message being written have as tabs.
    static func icon(for key: PopupKey) -> String {
        switch key {
        case .message: return "envelope.open"
        case .compose: return "square.and.pencil"
        }
    }

    static func title(for entry: WindowTrayBook.Entry) -> String {
        guard entry.title.isEmpty else { return entry.title }
        switch entry.key {
        case .message: return "Message"
        case .compose: return "New Message"
        }
    }
}
