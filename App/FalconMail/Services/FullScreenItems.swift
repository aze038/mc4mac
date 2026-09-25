import AppKit
import FalconCore

/// Legacy Outlook's own little window manager while its mailbox window fills the screen: a
/// message or compose window does not open as a full-screen space of its own but floats inside the
/// mailbox window's, over the mailbox and above its status bar, with its own buttons, title and
/// ribbon. One showing stands in the middle at its own size, two stand side by side, and one
/// minimised becomes a tab in the status bar (the tray's entries, drawn there).
///
/// Each window taken in becomes a child window of the mailbox window, so that it stays in that
/// space and above it, and is marked as an auxiliary of a full-screen window with its green button
/// turned off, as Outlook's are. When the mailbox window leaves full screen, every window taken in
/// becomes an ordinary window again, where it stood before, or where it is if it opened meanwhile.
@MainActor
final class FullScreenItems {
    /// The mailbox window filling the screen, while one does.
    private(set) weak var host: NSWindow?
    private var deck = FullScreenDeck()
    private var taken: [PopupKey: Taken] = [:]
    private var hostObservers: [NSObjectProtocol] = []
    private var keyMonitor: Any?

    /// What a window taken in was, to be given back when full screen ends.
    private struct Taken {
        let window: WeakWindow
        /// Where it stood on the desktop; nil for one that opened in full screen.
        let home: NSRect?
        /// The size it is laid out at.
        let size: NSSize
        let behavior: NSWindow.CollectionBehavior
        let tabbing: NSWindow.TabbingMode
        let zoomEnabled: Bool
        /// Laid out again when it first comes to the front, since SwiftUI may place a new window
        /// after it was taken in.
        var awaitingFront: Bool
    }

    var isActive: Bool { host != nil }

    /// `window` has gone full screen. Nothing changes while another mailbox window fills a screen.
    func begin(in window: NSWindow) {
        guard host == nil else { return }
        host = window
        hostObservers = [NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fitToScreen() }
            }
        }
        // As it shrinks back to a window, nothing is laid out again or sent to a tab; the windows
        // stay with it until it has left full screen, and are given back then.
        hostObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window,
                                                                    queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopFollowingHost() }
        })
        // Command-` goes round the mailbox window and the windows over it, whether or not macOS
        // counts a child window among those it goes round; Command-M and the full-screen keys
        // work in a window over it, whether or not the menus count it as one they can act on.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let held = event.modifierFlags
            guard let self, let key = FullScreenKey(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                                                    command: held.contains(.command), shift: held.contains(.shift),
                                                    option: held.contains(.option), control: held.contains(.control),
                                                    function: held.contains(.function))
            else { return event }
            return MainActor.assumeIsolated { self.answer(key) } ? nil : event
        }
    }

    /// Answers `key`. False when it is left to the menus and macOS: always in a window that is
    /// neither the mailbox window nor one showing over it.
    private func answer(_ key: FullScreenKey) -> Bool {
        switch key {
        case .cycle(let backwards):
            return cycle(backwards: backwards)
        case .minimise:
            guard let front = showingInFront else { return false }
            onSendToTab?(front)
            return true
        case .leaveFullScreen:
            // With the mailbox window in front, the menu does it.
            guard showingInFront != nil, let host, host.styleMask.contains(.fullScreen) else { return false }
            host.toggleFullScreen(nil)
            return true
        }
    }

    /// What the window over the mailbox that is in front holds, when one is.
    private var showingInFront: PopupKey? {
        guard let front = NSApp.keyWindow else { return nil }
        return deck.showing.first { taken[$0]?.window.window === front }
    }

    /// Brings the next window round to the front. False when the window in front is neither the
    /// mailbox window nor one over it, or when nothing is over it, so that macOS goes round as
    /// it always does.
    private func cycle(backwards: Bool) -> Bool {
        guard let host, let front = NSApp.keyWindow else { return false }
        let current: FullScreenDeck.Stop
        if front === host {
            current = .mailbox
        } else if let key = showingInFront {
            current = .window(key)
        } else {
            return false
        }
        let window: NSWindow?
        switch deck.next(after: current, backwards: backwards) {
        case nil: return false
        case .mailbox?: window = host
        case .window(let key)?: window = taken[key]?.window.window
        }
        guard let window else { return false }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    private func stopFollowingHost() {
        hostObservers.forEach(NotificationCenter.default.removeObserver)
        hostObservers = []
    }

    /// Takes `window`, holding `key`, into the space, on the right of those showing. `opening` is
    /// true for a window SwiftUI is about to show for the first time. Returns the windows that no
    /// longer fit, to be sent to their tabs.
    func take(_ window: NSWindow, key: PopupKey, opening: Bool) -> [PopupKey] {
        guard let host, window !== host, !window.styleMask.contains(.fullScreen) else { return [] }
        if taken[key]?.window.window !== window {
            let zoom = window.standardWindowButton(.zoomButton)
            taken[key] = Taken(window: WeakWindow(window), home: opening ? nil : window.frame,
                               size: opening ? FullScreenItems.openingSize(of: key) : window.frame.size,
                               behavior: window.collectionBehavior, tabbing: window.tabbingMode,
                               zoomEnabled: zoom?.isEnabled ?? true, awaitingFront: opening)
        }
        var behavior = window.collectionBehavior
        behavior.remove([.fullScreenPrimary, .fullScreenNone])
        behavior.insert([.fullScreenAuxiliary, .fullScreenDisallowsTiling])
        window.collectionBehavior = behavior
        window.tabbingMode = .disallowed
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        // A window on the desktop's space leaves it for the mailbox window's.
        let moving = window.isVisible && window.parent !== host
        if moving { window.orderOut(nil) }
        if window.parent !== host { host.addChildWindow(window, ordered: .above) }
        let sent = deck.show(key, capacity: capacity)
        layout(placingAtOnce: key)
        if moving { window.orderFront(nil) }
        if opening {
            // SwiftUI may set the frame of a window it opens after this, so it is laid out again.
            DispatchQueue.main.async { [weak self] in self?.layout() }
        }
        return sent
    }

    /// `key`'s window goes to its tab: out of the space, the others laid out again. It stays
    /// marked as the mailbox window's, so that it comes back into the space.
    func release(_ key: PopupKey) {
        guard let entry = taken[key] else { return }
        deck.hide(key)
        if let window = entry.window.window, window.parent != nil { window.parent?.removeChildWindow(window) }
        layout()
    }

    /// `key`'s window closed.
    func forget(_ key: PopupKey) {
        guard taken.removeValue(forKey: key) != nil else { return }
        deck.hide(key)
        // After the window has gone.
        DispatchQueue.main.async { [weak self] in self?.layout() }
    }

    /// `key`'s window became the one in front. One opened in full screen is laid out once more,
    /// now that SwiftUI has placed it.
    func cameForward(_ key: PopupKey) {
        deck.cameForward(key)
        if taken[key]?.awaitingFront == true {
            taken[key]?.awaitingFront = false
            layout()
        }
    }

    /// The mailbox window left full screen, or closed: every window taken in is an ordinary
    /// window again, those showing where they stood before, and one that opened in full screen
    /// where it is, kept within the screen. Those in the tray stay there.
    func end() {
        let host = self.host
        for entry in taken.values {
            guard let window = entry.window.window else { continue }
            if let host, window.parent === host { host.removeChildWindow(window) }
            window.collectionBehavior = entry.behavior
            window.tabbingMode = entry.tabbing
            window.standardWindowButton(.zoomButton)?.isEnabled = entry.zoomEnabled
            let frame = entry.home ?? FullScreenItems.fitted(window.frame, in: (window.screen ?? host?.screen)?.visibleFrame)
            window.setFrame(frame, display: window.isVisible, animate: false)
        }
        stopFollowingHost()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        taken = [:]
        deck = FullScreenDeck()
        self.host = nil
    }

    /// Sends `key`'s window to its tab, as minimising it does.
    var onSendToTab: ((PopupKey) -> Void)?

    /// The mailbox window changed size or screen: the windows that no longer fit go to their
    /// tabs, and the rest are laid out again.
    private func fitToScreen() {
        for key in deck.fit(capacity: capacity) { onSendToTab?(key) }
        layout()
    }

    // MARK: Layout

    /// The space over the mailbox window above its status bar.
    private var area: NSRect {
        guard var area = host?.frame else { return .zero }
        area.origin.y += OL.fullScreenStatus
        area.size.height -= OL.fullScreenStatus
        return area
    }

    private var capacity: Int { FullScreenLayout.capacity(forWidth: area.width) }

    /// Puts each window showing in its place: at once for `placingAtOnce`, which is coming on
    /// screen, and with a short slide for any other that moves.
    private func layout(placingAtOnce newcomer: PopupKey? = nil) {
        let showing = deck.showing.compactMap { key in taken[key].flatMap { entry in entry.window.window.map { (key, $0, entry.size) } } }
        let frames = FullScreenLayout.frames(for: showing.map(\.2), in: area)
        var sliding: [(NSWindow, NSRect)] = []
        for ((key, window, _), frame) in zip(showing, frames) where window.frame != frame {
            if key == newcomer || !window.isVisible {
                window.setFrame(frame, display: window.isVisible, animate: false)
            } else {
                sliding.append((window, frame))
            }
        }
        guard !sliding.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            for (window, frame) in sliding { window.animator().setFrame(frame, display: true) }
        }
    }

    /// The size a window opened in full screen is laid out at: its window group's own, as
    /// Outlook's message window keeps 917 × 1006.
    static func openingSize(of key: PopupKey) -> NSSize {
        switch key {
        case .message: return NSSize(width: OL.messageWindowWidth, height: OL.messageWindowHeight)
        case .compose: return NSSize(width: OL.composeWindowWidth, height: OL.composeWindowHeight)
        }
    }

    /// `frame` moved, and cut if it must be, to lie within `bounds`.
    static func fitted(_ frame: NSRect, in bounds: NSRect?) -> NSRect {
        guard let bounds, !bounds.isEmpty else { return frame }
        var frame = frame
        frame.size.width = min(frame.width, bounds.width)
        frame.size.height = min(frame.height, bounds.height)
        frame.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - frame.height)
        return frame
    }
}
