import SwiftUI
import AppKit
import ObjectiveC

@MainActor
final class WindowTray: ObservableObject {
    static let shared = WindowTray()
    static let popupIdentifier = "falcon.popup"

    struct Entry: Identifiable {
        let id: Int
        let title: String
        weak var window: NSWindow?
    }

    @Published private(set) var entries: [Entry] = []
    private var popups: [WeakWindow] = []
    private var observers: [NSObjectProtocol] = []

    private init() {
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] n in
            guard let w = n.object as? NSWindow else { return }
            MainActor.assumeIsolated { self?.remove(w) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] n in
            guard let w = n.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                self?.remove(w)
                self?.popups.removeAll { $0.window == nil || $0.window === w }
            }
        })
    }

    func register(popup window: NSWindow) {
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

    func minimize(_ window: NSWindow) {
        remove(window)
        entries.append(Entry(id: window.windowNumber, title: window.title.isEmpty ? "Window" : window.title, window: window))
        window.orderOut(nil)
    }

    func restore(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        entry.window?.makeKeyAndOrderFront(nil)
    }

    func close(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        entry.window?.close()
    }

    private func remove(_ window: NSWindow) {
        entries.removeAll { $0.id == window.windowNumber }
    }

    nonisolated static func installMinimizeHook() {
        guard let original = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.miniaturize(_:))),
              let replacement = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.falcon_miniaturize(_:))) else { return }
        method_exchangeImplementations(original, replacement)
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
}

struct PopupWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> AccessorView { AccessorView() }
    func updateNSView(_ nsView: AccessorView, context: Context) {}

    final class AccessorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            WindowTray.shared.register(popup: window)
        }
    }
}

struct WindowTrayBar: View {
    @ObservedObject var tray = WindowTray.shared
    @Environment(AppModel.self) private var model

    var body: some View {
        if !tray.entries.isEmpty || !model.minimizedTabs.isEmpty {
            HStack(spacing: 8) {
                ForEach(model.minimizedTabs) { tab in
                    HStack(spacing: 6) {
                        Image(systemName: model.icon(for: tab)).font(.caption)
                        Text(model.title(for: tab)).font(.caption).lineLimit(1).frame(maxWidth: 220)
                        Button { model.closeTab(tab) } label: { Image(systemName: "xmark.circle.fill").font(.caption) }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .onTapGesture { model.openTab(tab) }
                }
                ForEach(tray.entries) { e in
                    HStack(spacing: 6) {
                        Image(systemName: "macwindow").font(.caption)
                        Text(e.title).font(.caption).lineLimit(1).frame(maxWidth: 220)
                        Button { tray.close(e) } label: { Image(systemName: "xmark.circle.fill").font(.caption) }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .onTapGesture { tray.restore(e) }
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(.bar)
        }
    }
}
