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
/// window that FalconMail minimises them into instead of the Dock. While a mailbox window fills
/// the screen, they float inside its space instead, as Legacy Outlook's do, and the tray's
/// entries are the tabs in its status bar.
@MainActor
final class WindowTray: ObservableObject {
    static let shared = WindowTray()
    static let popupIdentifier = "falcon.popup"

    @Published private(set) var book = WindowTrayBook()
    /// The mailbox window filling the screen, whose status bar holds the tray as tabs.
    @Published private(set) var fullScreenMailbox: ObjectIdentifier?
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
    private let fullScreen = FullScreenItems()
    /// Messages and messages being written drawn inside the mailbox window, Outlook's way, rather
    /// than in windows of their own: every one opened while the mailbox window fills the screen.
    /// `deskShowing` are those on screen, the one in front last; the others are in the tray, as
    /// tabs in the status bar, and stay alive (a message being written keeps what was typed).
    @Published private(set) var deskMounted: [PopupKey] = []
    @Published private(set) var deskShowing: [PopupKey] = []
    /// Message or compose windows that went full screen on their own as they opened over a
    /// mailbox window filling the screen, being brought back into its space.
    private var leavingFullScreen = Set<PopupKey>()

    private init() {
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] n in
            guard let w = n.object as? NSWindow else { return }
            MainActor.assumeIsolated { self?.becameKey(w) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] n in
            guard let w = n.object as? NSWindow else { return }
            MainActor.assumeIsolated { self?.willClose(w) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: nil, queue: .main) { [weak self] n in
            guard let w = n.object as? NSWindow else { return }
            MainActor.assumeIsolated { self?.enteredFullScreen(w) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main) { [weak self] n in
            guard let w = n.object as? NSWindow else { return }
            MainActor.assumeIsolated { self?.exitedFullScreen(w) }
        })
        fullScreen.onSendToTab = { [weak self] key in
            guard let self, let window = self.window(for: key) else { return }
            self.minimize(window)
        }
    }

    private func becameKey(_ window: NSWindow) {
        front = kind(of: window)
        if let key = key(for: window) {
            book.showing(key, title: window.title)
            fullScreen.cameForward(key)
        }
    }

    private func willClose(_ window: NSWindow) {
        if let key = key(for: window) {
            book.closed(key)
            popupWindows[key] = nil
            fullScreen.forget(key)
            leavingFullScreen.remove(key)
            if front == .popup(key) { front = .other }
        }
        if window === fullScreen.host { endFullScreen() }
        popups.removeAll { $0.window == nil || $0.window === window }
        mailboxWindows.removeAll { $0.window == nil || $0.window === window }
    }

    // MARK: A mailbox window filling the screen

    /// A mailbox window went full screen: the message and compose windows showing come into its
    /// space, as many as fit side by side, the others to their tabs. One of them that went full
    /// screen on its own stays in its own space.
    private func enteredFullScreen(_ window: NSWindow) {
        if let key = key(for: window) {
            // One opening over the mailbox window as that filled the screen went full screen on
            // its own before it could be kept in: it is brought back out and into the space.
            guard fullScreen.isActive, leavingFullScreen.insert(key).inserted else { return }
            window.toggleFullScreen(nil)
            return
        }
        guard mailboxWindows.contains(where: { $0.window === window }), !fullScreen.isActive else { return }
        fullScreen.begin(in: window)
        fullScreenMailbox = ObjectIdentifier(window)
        let inFront = NSApp.keyWindow
        for entry in popups {
            guard let popup = entry.window, popup.isVisible, let key = key(for: popup) else { continue }
            take(popup, key: key, opening: false)
        }
        if let inFront, inFront.isVisible { inFront.makeKeyAndOrderFront(nil) }
    }

    private func exitedFullScreen(_ window: NSWindow) {
        if let key = key(for: window), leavingFullScreen.remove(key) != nil {
            if fullScreen.isActive {
                take(window, key: key, opening: false)
                window.makeKeyAndOrderFront(nil)
            }
            return
        }
        if window === fullScreen.host { endFullScreen() }
    }

    private func endFullScreen() {
        fullScreen.end()
        fullScreenMailbox = nil
        handOverDesk()
    }

    /// Those drawn inside the mailbox window whose views are going away because they became
    /// windows, not because they were closed: a message being written is not closed with them.
    private(set) var handedOver = Set<PopupKey>()

    /// The mailbox window left full screen: what was drawn inside it becomes windows of their
    /// own again, those showing opening at once and those in the tray opening when taken out.
    private func handOverDesk() {
        let showing = deskMounted.filter { deskShowing.contains($0) }
        let keys = deskMounted
        guard !keys.isEmpty else { return }
        handedOver.formUnion(showing)
        deskMounted = []
        deskShowing = []
        for key in showing { book.closed(key) }
        // Those in the tray are forgotten: a message being written is kept in Drafts.
        for key in keys where !showing.contains(key) { book.closed(key) }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for key in showing { self.openWindow?(key) }
            DispatchQueue.main.async { self.handedOver.subtract(showing) }
        }
    }

    /// Takes `window` into the space of the mailbox window filling the screen, sending to their
    /// tabs the windows it leaves no room for.
    private func take(_ window: NSWindow, key: PopupKey, opening: Bool) {
        for sent in fullScreen.take(window, key: key, opening: opening) {
            if let other = self.window(for: sent) { minimize(other) }
        }
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
        // Brought back at launch already filling the screen.
        if window.styleMask.contains(.fullScreen) { enteredFullScreen(window) }
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
        if fullScreen.isActive {
            // Before SwiftUI shows it, so that it opens inside the space rather than in one of its own.
            take(window, key: key, opening: !window.isVisible)
        } else if let anchor = popups.last?.window, anchor.isVisible {
            place(window, beside: anchor)
        }
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
        fullScreen.release(key)
        window.orderOut(nil)
    }

    /// Puts a message back into the tray without a window, as a launch does with those that were
    /// in the tray at the last quit; its window opens when it is taken out.
    func shelve(_ key: PopupKey, title: String) {
        guard window(for: key) == nil else { return }
        book.minimise(key, title: title)
    }

    // MARK: Drawn inside the mailbox window

    /// Shows `key` inside the mailbox window, Outlook's way, when that fills the screen or already
    /// holds it. False when it should open in a window of its own.
    func showInDesk(_ key: PopupKey) -> Bool {
        guard deskMounted.contains(key) || fullScreenMailbox != nil else { return false }
        if !deskMounted.contains(key) { deskMounted.append(key) }
        deskShowing.removeAll { $0 == key }
        deskShowing.append(key)
        if book.entry(key) == nil || book.entry(key)?.place == .tray {
            book.showing(key, title: book.entry(key)?.title ?? "")
        }
        // Two side by side at most, as Outlook: the one in front least recently goes to its tab.
        while deskShowing.count > FullScreenLayout.mostShowing {
            let oldest = deskShowing.removeFirst()
            book.minimise(oldest, title: book.entry(oldest)?.title ?? "")
        }
        return true
    }

    func inDesk(_ key: PopupKey) -> Bool { deskMounted.contains(key) }

    /// A message or a message being written drawn inside the mailbox window has its title.
    func deskTitle(_ key: PopupKey, _ title: String) {
        guard deskMounted.contains(key), book.entry(key)?.title != title else { return }
        if book.entry(key)?.place == .tray { book.minimise(key, title: title) } else { book.showing(key, title: title) }
    }

    /// Clicked: comes to the front of those inside the mailbox window.
    func deskFront(_ key: PopupKey) {
        guard deskShowing.last != key, deskShowing.contains(key) else { return }
        deskShowing.removeAll { $0 == key }
        deskShowing.append(key)
    }

    /// Its yellow button: to its tab in the status bar.
    func deskMinimise(_ key: PopupKey) {
        guard deskMounted.contains(key) else { return }
        deskShowing.removeAll { $0 == key }
        book.minimise(key, title: book.entry(key)?.title ?? "")
    }

    /// Its red button, Discard, Send, or an action that takes the message away.
    func deskClose(_ key: PopupKey) {
        deskMounted.removeAll { $0 == key }
        deskShowing.removeAll { $0 == key }
        book.closed(key)
    }

    /// Brings `key`'s window to the front, from the tray if it is there. False when no window
    /// holds it, and one should be opened.
    func bringForward(_ key: PopupKey) -> Bool {
        if window(for: key) == nil, showInDesk(key) { return true }
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
        if deskMounted.contains(key) { _ = showInDesk(key); return }
        guard let window = window(for: key) else {
            book.closed(key)
            openWindow?(key)
            return
        }
        book.restore(key)
        if fullScreen.isActive { take(window, key: key, opening: false) }
        window.makeKeyAndOrderFront(nil)
    }

    /// The tray's close button, and Discard on a message being written in a window of its own.
    /// Nothing is asked: a message not yet sent keeps what was written in Drafts as it closes.
    func close(_ key: PopupKey) {
        if deskMounted.contains(key) { return deskClose(key) }
        guard let window = window(for: key) else { return book.closed(key) }
        window.close()
    }

    /// Close Window in the Message menu, or Command-W, on the message or compose window in front.
    func performClose(_ key: PopupKey) {
        if deskMounted.contains(key) { return deskClose(key) }
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

}

final class WeakWindow {
    weak var window: NSWindow?
    init(_ w: NSWindow) { window = w }
}

extension NSWindow {
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
    /// Told which window the mailbox is in, once it is in one.
    var inWindow: (NSWindow) -> Void = { _ in }

    func makeNSView(context: Context) -> AccessorView {
        let view = AccessorView()
        view.inWindow = inWindow
        return view
    }

    func updateNSView(_ nsView: AccessorView, context: Context) {}

    final class AccessorView: NSView {
        var inWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            let inWindow = self.inWindow
            DispatchQueue.main.async { inWindow?(window) }
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
    /// False while the mailbox window fills the screen, when its status bar shows the windows
    /// minimised as tabs and this row only the tabs minimised inside the mailbox window.
    var holdsWindows = true

    private var windows: [WindowTrayBook.Entry] { holdsWindows ? tray.book.tray : [] }

    var body: some View {
        if !windows.isEmpty || !model.minimizedTabs.isEmpty {
            HStack(spacing: 8) {
                ForEach(model.minimizedTabs) { tab in
                    HStack(spacing: 6) {
                        Image(systemName: model.icon(for: tab)).font(.caption)
                        Text(model.title(for: tab)).font(.caption).lineLimit(1)
                            .frame(maxWidth: 220, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                        Button { model.closeTab(tab) } label: { Image(systemName: "xmark.circle.fill").font(.caption) }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .onTapGesture { model.openTab(tab) }
                }
                ForEach(windows) { entry in
                    HStack(spacing: 6) {
                        Image(systemName: WindowTrayBar.icon(for: entry.key)).font(.caption)
                        // Hugs its title, as a tab's chip does, and cuts a long one short.
                        Text(WindowTrayBar.title(for: entry)).font(.caption).lineLimit(1)
                            .frame(maxWidth: 260, alignment: .leading).fixedSize(horizontal: true, vertical: false)
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

/// The tabs in the middle of the status bar while the mailbox window fills the screen, one for
/// each message or compose window minimised, as Legacy Outlook's: the title and account of what
/// it holds, as its window's title row reads, in a darker tab rising from the foot of the screen.
/// A click brings its window back into the space; the cross that shows under the pointer closes it.
struct FullScreenTabStrip: View {
    @ObservedObject var tray = WindowTray.shared
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { proxy in
            let entries = tray.book.tray
            let width = FullScreenLayout.tabWidth(count: entries.count, band: proxy.size.width)
            HStack(spacing: FullScreenLayout.tabGap) {
                ForEach(entries) { entry in
                    FullScreenTab(title: title(for: entry), restore: { tray.restore(entry.key) }, close: { tray.close(entry.key) })
                        .frame(width: width)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
        }
    }

    /// "Subject • account", as the window's own title row reads.
    private func title(for entry: WindowTrayBook.Entry) -> String {
        let subject = WindowTrayBar.title(for: entry)
        let accountID: UUID?
        switch entry.key {
        case .message(let id): accountID = model.messageWindowRows[id]?.accountID
        case .compose(let id): accountID = model.drafts[id]?.accountID
        }
        guard let email = model.accounts.first(where: { $0.id == accountID })?.email else { return subject }
        return "\(subject) • \(email)"
    }
}

struct FullScreenTab: View {
    let title: String
    let restore: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            UnevenRoundedRectangle(topLeadingRadius: OL.fullScreenTabRadius, topTrailingRadius: OL.fullScreenTabRadius)
                .fill(hovering ? OLColor.fullScreenTabHover : OLColor.fullScreenTab)
            Text(title)
                .font(.system(size: OL.statusFont))
                .foregroundStyle(OLColor.title)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 26)
            if hovering {
                HStack {
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(OLColor.textMuted)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                    Spacer()
                }
                .padding(.leading, 6)
            }
        }
        .frame(height: OL.fullScreenTab)
        .contentShape(Rectangle())
        .onTapGesture(perform: restore)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Show", action: restore)
            Button("Close", action: close)
        }
        .help(title)
    }
}
