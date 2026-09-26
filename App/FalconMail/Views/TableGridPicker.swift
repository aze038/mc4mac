import SwiftUI
import AppKit
import FalconCore

struct TableSize: Equatable {
    var columns: Int
    var rows: Int

    /// Outlook names a table columns first: "3x4 Table" is three across, four down.
    var title: String { "\(columns)x\(rows) Table" }
}

/// The picker measured off Outlook's (2x, dark): a 246 × 272 point menu, its title in 12 points
/// with its capitals from 6.5 points down, ten by eight outlined squares of 18 points on a 22
/// point pitch from (15, 29), a two point rule at 214, then Insert Table… and Convert Text to
/// Table… in 14 points on a 24 point pitch, each after a twenty point icon.
enum TableGrid {
    static let columns = 10
    static let rows = 8
    static let width: CGFloat = 246
    static let corner: CGFloat = 5
    static let titleFont: CGFloat = 12
    static let titleX: CGFloat = 15
    static let titleTop: CGFloat = 4
    static let gridX: CGFloat = 15
    static let gridTop: CGFloat = 29
    static let square: CGFloat = 18
    static let gap: CGFloat = 4
    static let ruleTop: CGFloat = 214
    static let rule: CGFloat = 2
    static let itemFont: CGFloat = 14
    static let itemRow: CGFloat = 24
    static let itemsTop: CGFloat = 218
    static let itemTextTop: CGFloat = 4.5
    static let itemIconX: CGFloat = 20
    static let itemTextX: CGFloat = 44
    static let itemHighlightInset: CGFloat = 5
    static let bottom: CGFloat = 6
    /// A dimmed item's icon, as Outlook fades Convert Text to Table… with nothing to convert.
    static let dimmedIcon: CGFloat = 0.35

    static let ground = OLColor.dynamic(light: 0xF2F2F2, dark: 0x323232)
    static let text = OLColor.dynamic(light: 0x262626, dark: 0xE0E0E0)
    static let dimmedText = OLColor.dynamic(light: 0xB0B0B0, dark: 0x656565)
    static let line = OLColor.dynamic(light: 0x8C8C8C, dark: 0x969696)
    static let litFill = OLColor.dynamic(light: 0xDCEAF7, dark: 0x1B3A5C)
    static let litLine = OLColor.unread
    static let separator = OLColor.dynamic(light: 0xD9D9D9, dark: 0x464646)
    static let iconGrey = OLColor.dynamic(light: 0x5A5A5A, dark: 0xD4D4D4)
    /// The capture's 0x5698D6 is in its screen's profile, which is Display P3's; this is the
    /// same blue in sRGB.
    static let iconBlue = OLColor.dynamic(light: 0x2F78C4, dark: 0x3B9ADB)
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
/// asks for a size the grid cannot show; Convert Text to Table… turns the selected lines into a
/// table, and is dimmed while there is nothing selected it can convert.
struct TableGridPicker: View {
    let selection: TableGridSelection
    let insert: (TableSize) -> Void
    let insertCustom: () -> Void
    /// Nil while there is no text to convert.
    let convertText: (() -> Void)?

    private static var pitch: CGFloat { TableGrid.square + TableGrid.gap }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            text(selection.hovered?.title ?? "Insert Table", size: TableGrid.titleFont, top: TableGrid.titleTop)
                .foregroundStyle(TableGrid.text)
                .frame(height: TableGrid.gridTop, alignment: .top)
                .padding(.leading, TableGrid.titleX)
            grid
                .padding(.leading, TableGrid.gridX)
            Rectangle()
                .fill(TableGrid.separator)
                .frame(height: TableGrid.rule)
                .padding(.top, TableGrid.ruleTop - TableGrid.gridTop - gridHeight)
            PickerItem(title: "Insert Table…", enabled: true, action: insertCustom) { InsertTableIcon() }
                .padding(.top, TableGrid.itemsTop - TableGrid.ruleTop - TableGrid.rule)
            PickerItem(title: "Convert Text to Table…", enabled: convertText != nil, action: { convertText?() }) { ConvertTextIcon() }
        }
        .padding(.bottom, TableGrid.bottom)
        .frame(width: TableGrid.width, alignment: .leading)
        .background(TableGrid.ground, in: RoundedRectangle(cornerRadius: TableGrid.corner))
        .fixedSize()
    }

    private var gridHeight: CGFloat { CGFloat(TableGrid.rows) * Self.pitch - TableGrid.gap }

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
            .fill(lit ? TableGrid.litFill : Color.clear)
            .overlay(Rectangle().strokeBorder(lit ? TableGrid.litLine : TableGrid.line, lineWidth: 1))
            .frame(width: TableGrid.square, height: TableGrid.square)
    }

    private func size(at point: CGPoint) -> TableSize {
        TableSize(columns: min(max(Int(point.x / Self.pitch) + 1, 1), TableGrid.columns),
                  rows: min(max(Int(point.y / Self.pitch) + 1, 1), TableGrid.rows))
    }
}

/// A line of the picker's text, `top` points below the top of its row.
private func text(_ string: String, size: CGFloat, top: CGFloat) -> some View {
    Text(string)
        .font(.system(size: size))
        .lineLimit(1)
        .padding(.top, top)
}

/// One of the items under the grid: its icon, its title, lit under the pointer as a menu item
/// is, dimmed with nothing to act on.
private struct PickerItem<Icon: View>: View {
    let title: String
    let enabled: Bool
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                icon()
                    .opacity(enabled ? 1 : TableGrid.dimmedIcon)
                    .padding(.leading, TableGrid.itemIconX)
                text(title, size: TableGrid.itemFont, top: TableGrid.itemTextTop)
                    .foregroundStyle(lit ? Color.white : enabled ? TableGrid.text : TableGrid.dimmedText)
                    .padding(.leading, TableGrid.itemTextX)
            }
            .frame(width: TableGrid.width, height: TableGrid.itemRow, alignment: .topLeading)
            .background {
                if lit {
                    RoundedRectangle(cornerRadius: 4).fill(Theme.accent).padding(.horizontal, TableGrid.itemHighlightInset)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(enabled)
        .onHover { hovered = $0 }
    }

    private var lit: Bool { enabled && hovered }
}

/// Insert Table…'s icon, twenty points by eighteen four points down its row: a table with an
/// arrow going into it from the left.
private struct InsertTableIcon: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(systemName: "squareshape.split.3x3")
                .resizable()
                .frame(width: 18, height: 18)
                .foregroundStyle(TableGrid.iconGrey)
                .padding(.leading, 2)
            Image(systemName: "arrow.right")
                .resizable()
                .frame(width: 10, height: 7)
                .foregroundStyle(TableGrid.iconBlue)
                .padding(.top, 7)
        }
        .padding(.top, 4)
    }
}

/// Convert Text to Table…'s icon, twenty points by nineteen three points down its row: lines of
/// text turning into a column of cells.
private struct ConvertTextIcon: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(systemName: "text.alignleft")
                .resizable()
                .frame(width: 8, height: 7)
                .foregroundStyle(TableGrid.iconGrey)
                .padding(.leading, 2)
            Image(systemName: "arrow.turn.down.right")
                .resizable()
                .frame(width: 9, height: 9)
                .foregroundStyle(TableGrid.iconBlue)
                .padding(.top, 11)
            Image(systemName: "rectangle.grid.1x3")
                .resizable()
                .frame(width: 8, height: 19)
                .foregroundStyle(TableGrid.iconGrey)
                .padding(.leading, 11)
        }
        .padding(.top, 3)
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
                     insertCustom: @escaping () -> Void, convertText: (() -> Void)?, closed: @escaping () -> Void) {
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
                                     },
                                     convertText: convertText.map { convert in
                                         { [weak panel] in
                                             panel?.close()
                                             convert()
                                         }
                                     })
        let host = NSHostingView(rootView: picker)
        let fitting = host.fittingSize
        host.frame = NSRect(origin: .zero, size: fitting)
        panel.contentView = host

        // Hang two points below the tile's lit area, which stops six points above its foot, and
        // stay on the screen as a menu does: a compose window near its edge, or wider than the
        // room the ribbon has, would otherwise leave part of the grid off it.
        let tile = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let screen = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? parent.frame
        panel.setFrame(PopupPlacement.frame(size: fitting, below: tile, overlap: 4, on: screen), display: false)
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
