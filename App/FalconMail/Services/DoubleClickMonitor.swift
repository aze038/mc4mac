import SwiftUI
import AppKit

struct DoubleClickMonitor: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let v = MonitorView()
        v.action = action
        return v
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.action = action
    }

    final class MonitorView: NSView {
        var action: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, event.clickCount == 2, event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(point) {
                    DispatchQueue.main.async { self.action?() }
                }
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
