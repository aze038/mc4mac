import SwiftUI
import AppKit

/// Makes the table under a SwiftUI List draw as Outlook's list does: rows the list's full width,
/// where SwiftUI sets each cell in from both ends, and no selection of its own, since the rows
/// draw Outlook's. Put it behind the List; it finds the table that stands where it stands.
struct ListTableTuner: NSViewRepresentable {
    func makeNSView(context: Context) -> TunerView { TunerView() }

    func updateNSView(_ view: TunerView, context: Context) {
        // After SwiftUI's own update of the table, which may set its spacing again.
        DispatchQueue.main.async { view.tune() }
    }

    final class TunerView: NSView {
        private weak var table: NSTableView?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.tune() }
        }

        override func layout() {
            super.layout()
            tune()
        }

        func tune() {
            let known = table.flatMap { $0.window == nil ? nil : $0 }
            guard let table = known ?? findTable() else { return }
            self.table = table
            if table.intercellSpacing.width != 0 {
                table.intercellSpacing = NSSize(width: 0, height: table.intercellSpacing.height)
            }
            if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
            if let column = table.tableColumns.last, abs(column.width - table.bounds.width) > 0.5 {
                table.sizeLastColumnToFit()
            }
        }

        /// The table whose scroll view covers this view: the window holds other lists, such as
        /// the sidebar's, in the same hosting view.
        private func findTable() -> NSTableView? {
            guard window != nil else { return nil }
            let frame = convert(bounds, to: nil)
            var ancestor = superview
            while let view = ancestor {
                if let table = tables(in: view).first(where: { table in
                    guard let scroll = table.enclosingScrollView else { return false }
                    let scrollFrame = scroll.convert(scroll.bounds, to: nil)
                    return abs(scrollFrame.minX - frame.minX) < 1 && abs(scrollFrame.width - frame.width) < 1
                        && scrollFrame.intersects(frame)
                }) { return table }
                ancestor = view.superview
            }
            return nil
        }

        private func tables(in view: NSView) -> [NSTableView] {
            if let table = view as? NSTableView { return [table] }
            return view.subviews.flatMap { tables(in: $0) }
        }
    }
}
