import SwiftUI
import AppKit

struct TableSize: Equatable {
    var columns: Int
    var rows: Int

    /// Outlook names a table columns first: "3x4 Table" is three across, four down.
    var title: String { "\(columns)x\(rows) Table" }
}

/// The picker's geometry and colours. Unlike the rest of the look these are not measured: the
/// Legacy Outlook on this Mac can no longer be captured, so the grid follows Office's own picker,
/// ten squares by eight, in Outlook's blue.
enum TableGrid {
    static let columns = 10
    static let rows = 8
    static let square: CGFloat = 16
    static let gap: CGFloat = 2
    static let inset: CGFloat = 10
    static let fill = OLColor.dynamic(light: 0xFFFFFF, dark: 0x2B2B2B)
    static let line = OLColor.dynamic(light: 0xC0C0C0, dark: 0x5A5A5A)
    static let litFill = OLColor.dynamic(light: 0xDCEAF7, dark: 0x1B3A5C)
    static let litLine = OLColor.unread
}

/// The size the grid is showing, shared by the pointer and the arrow keys.
@MainActor
@Observable
final class TableGridSelection {
    var hovered: TableSize?

    /// Arrows grow or shrink the highlighted rectangle from its top-left corner, within the grid.
    func move(columns: Int, rows: Int) {
        let current = hovered ?? TableSize(columns: 0, rows: 0)
        hovered = TableSize(columns: min(max(current.columns + columns, 1), TableGrid.columns),
                            rows: min(max(current.rows + rows, 1), TableGrid.rows))
    }
}

/// Outlook's Table dropdown: the title names the size under the pointer, the squares from the
/// top-left corner to it light up, and a click inserts that table. Insert Table… below the grid
/// asks for a size the grid cannot show.
struct TableGridPicker: View {
    let selection: TableGridSelection
    let insert: (TableSize) -> Void
    let insertCustom: () -> Void
    @State private var customHovered = false

    private static var pitch: CGFloat { TableGrid.square + TableGrid.gap }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(selection.hovered?.title ?? "Insert Table")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OLColor.text)
                .frame(height: 26, alignment: .center)
                .padding(.horizontal, TableGrid.inset)
            grid
                .padding(.horizontal, TableGrid.inset)
            Rectangle()
                .fill(OLColor.ribbonSeparator)
                .frame(height: 1)
                .padding(.horizontal, TableGrid.inset)
                .padding(.vertical, 6)
            Button(action: insertCustom) {
                Text("Insert Table…")
                    .font(.system(size: 13))
                    .foregroundStyle(customHovered ? Color.white : OLColor.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, TableGrid.inset)
                    .frame(height: 22)
                    .background(customHovered ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { customHovered = $0 }
            .padding(.horizontal, 5)
            .padding(.bottom, 5)
        }
        .fixedSize()
    }

    private var grid: some View {
        VStack(spacing: TableGrid.gap) {
            ForEach(0..<TableGrid.rows, id: \.self) { row in
                HStack(spacing: TableGrid.gap) {
                    ForEach(0..<TableGrid.columns, id: \.self) { column in
                        square(lit: selection.hovered.map { column < $0.columns && row < $0.rows } ?? false)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): selection.hovered = size(at: point)
            case .ended: selection.hovered = nil
            }
        }
        .onTapGesture { point in insert(size(at: point)) }
    }

    private func square(lit: Bool) -> some View {
        Rectangle()
            .fill(lit ? TableGrid.litFill : TableGrid.fill)
            .overlay(Rectangle().strokeBorder(lit ? TableGrid.litLine : TableGrid.line, lineWidth: 1))
            .frame(width: TableGrid.square, height: TableGrid.square)
    }

    private func size(at point: CGPoint) -> TableSize {
        TableSize(columns: min(max(Int(point.x / Self.pitch) + 1, 1), TableGrid.columns),
                  rows: min(max(Int(point.y / Self.pitch) + 1, 1), TableGrid.rows))
    }
}

/// The window the picker hangs in: borderless, drawn like a menu, just under the Table button
/// and moving with the compose window. It takes the keyboard while it is open, so the arrows
/// move the highlight, Return inserts and Escape closes, and it closes itself when anything
/// else is clicked.
final class TableGridPanel: NSPanel {
    private let selection = TableGridSelection()
    private var onInsert: ((TableSize) -> Void)?
    private var onClose: (() -> Void)?
    private var clickMonitor: Any?
    private var isClosing = false
    private static weak var shown: TableGridPanel?

    @MainActor
    static func show(below anchor: NSView, hovering size: TableSize? = nil, insert: @escaping (TableSize) -> Void,
                     insertCustom: @escaping () -> Void, closed: @escaping () -> Void) {
        shown?.close()
        guard let parent = anchor.window else { return }
        let panel = TableGridPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        panel.selection.hovered = size
        panel.onInsert = insert
        panel.onClose = closed
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false

        let picker = TableGridPicker(selection: panel.selection,
                                     insert: { [weak panel] size in panel?.choose(size) },
                                     insertCustom: { [weak panel] in
                                         panel?.close()
                                         insertCustom()
                                     })
        let host = NSHostingView(rootView: picker)
        let fitting = host.fittingSize
        let ground = NSVisualEffectView(frame: NSRect(origin: .zero, size: fitting))
        ground.material = .menu
        ground.state = .active
        ground.blendingMode = .behindWindow
        ground.wantsLayer = true
        ground.layer?.cornerRadius = 6
        ground.layer?.masksToBounds = true
        host.frame = ground.bounds
        host.autoresizingMask = [.width, .height]
        ground.addSubview(host)
        panel.contentView = ground

        // Hang two points below the tile's lit area, which stops six points above its foot.
        let tile = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        panel.setFrame(NSRect(x: tile.minX, y: tile.minY + 4 - fitting.height, width: fitting.width, height: fitting.height), display: false)
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        // A click anywhere else closes the picker, as it would a menu; a click on the Table
        // button itself only closes it rather than opening it again.
        panel.clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak panel, weak anchor] event in
            guard let panel, event.window !== panel else { return event }
            let onButton = anchor.map { $0.window === event.window && $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) } ?? false
            panel.close()
            return onButton ? nil : event
        }
        shown = panel
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        close()
    }

    override func close() {
        guard !isClosing else { return }
        isClosing = true
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        let parent = self.parent
        parent?.removeChildWindow(self)
        super.close()
        parent?.makeKey()
        onClose?()
    }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown else { return super.sendEvent(event) }
        switch event.keyCode {
        case 123: selection.move(columns: -1, rows: 0)
        case 124: selection.move(columns: 1, rows: 0)
        case 125: selection.move(columns: 0, rows: 1)
        case 126: selection.move(columns: 0, rows: -1)
        case 36, 76: if let size = selection.hovered { choose(size) }
        case 53: close()
        default: super.sendEvent(event)
        }
    }

    private func choose(_ size: TableSize) {
        let insert = onInsert
        close()
        insert?(size)
    }
}

/// Outlook's Insert Table dialog, for a table larger than the grid.
struct InsertTableSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var columns = 5
    @State private var rows = 2
    let insert: (TableSize) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Insert Table").font(.system(size: 13, weight: .semibold))
            Text("Table size").font(.system(size: 12)).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Number of columns:")
                    CountField(value: $columns, range: 1...63)
                }
                GridRow {
                    Text("Number of rows:")
                    CountField(value: $rows, range: 1...100)
                }
            }
            .font(.system(size: 13))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK") {
                    insert(TableSize(columns: min(max(columns, 1), 63), rows: min(max(rows, 1), 100)))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 300)
    }
}

private struct CountField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 4) {
            TextField("", value: $value, format: .number)
                .multilineTextAlignment(.trailing)
                .frame(width: 52)
                .onChange(of: value) { _, new in value = min(max(new, range.lowerBound), range.upperBound) }
            Stepper("", value: $value, in: range).labelsHidden()
        }
    }
}

/// Hands a SwiftUI view's NSView to AppKit code that needs to know where it is on screen.
struct ScreenAnchor: NSViewRepresentable {
    let found: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { found(view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
