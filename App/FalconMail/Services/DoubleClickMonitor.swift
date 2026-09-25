import SwiftUI
import AppKit

/// Watches the clicks in the view it sits behind without taking any: every click goes on to the
/// list as it came. `action` runs after a double-click, `onClick` after a single one, each once
/// the list has taken the click and moved its selection. A single click that brings the window
/// forward, as the first click back in the mailbox window after a message window had the front
/// does, is one AppKit spends on the window and never shows the list: `onClick` is then told the
/// row of the list under the pointer, so that the row is chosen all the same.
struct DoubleClickMonitor: NSViewRepresentable {
    let action: () -> Void
    var onClick: ((_ rowBroughtForward: Int?) -> Void)? = nil

    func makeNSView(context: Context) -> MonitorView {
        let v = MonitorView()
        v.action = action
        v.onClick = onClick
        return v
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.action = action
        nsView.onClick = onClick
    }

    final class MonitorView: NSView {
        var action: (() -> Void)?
        var onClick: ((Int?) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, event.window === self.window, event.clickCount == 1 || event.clickCount == 2 else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                if event.clickCount == 2 {
                    DispatchQueue.main.async { [weak self] in self?.action?() }
                } else {
                    let plain = event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty
                    let forward = plain && !(self.window?.isKeyWindow ?? true) ? self.tableRow(at: event.locationInWindow) : nil
                    DispatchQueue.main.async { [weak self] in self?.onClick?(forward) }
                }
                return event
            }
        }

        /// The row of the list at `point`, in the window's coordinates.
        private func tableRow(at point: NSPoint) -> Int? {
            guard let content = window?.contentView else { return nil }
            var view = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
            while let current = view, !(current is NSTableView) { view = current.superview }
            guard let table = view as? NSTableView else { return nil }
            let row = table.row(at: table.convert(point, from: nil))
            return row >= 0 ? row : nil
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
