import SwiftUI
import AppKit

/// Outlook's three columns: sidebar, message list, reading pane, each a fixed width the reader
/// can drag, parted by one-point lines. Drawn by hand rather than with NavigationSplitView so
/// the widths, the lines and the absence of a toolbar are exactly Outlook's.
struct OutlookColumns<Sidebar: View, List: View, Detail: View>: View {
    @AppStorage(Pref.sidebarWidth) private var sidebarWidth: Double = Double(OL.sidebarWidth)
    @AppStorage(Pref.listWidth) private var listWidth: Double = Double(OL.listWidth)
    var showList = true
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var list: () -> List
    @ViewBuilder var detail: () -> Detail
    @Environment(\.falconStyle) private var style

    var body: some View {
        HStack(spacing: 0) {
            // Glass: the folder pane is frosted glass and the list and the message float as
            // rounded cards, the gaps between them the dividers' grab zones.
            sidebar()
                .frame(width: CGFloat(sidebarWidth))
                .clipped()
                .modifier(GlassColumn(glass: style.glass, frosted: true))
            PaneDivider(width: $sidebarWidth, range: 180...460)
            if showList {
                list()
                    .frame(width: CGFloat(listWidth))
                    .clipped()
                    .modifier(GlassColumn(glass: style.glass, frosted: false))
                PaneDivider(width: $listWidth, range: 260...700)
            }
            detail()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(GlassColumn(glass: style.glass, frosted: false))
        }
    }
}

private struct GlassColumn: ViewModifier {
    let glass: Bool
    let frosted: Bool

    func body(content: Content) -> some View {
        if !glass {
            content
        } else if frosted {
            content.glassPane()
        } else {
            content.glassCard()
        }
    }
}

/// The one-point line between columns, with a seven-point grab zone the cursor reacts to.
struct PaneDivider: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var startWidth: Double?

    @Environment(\.falconStyle) private var style

    var body: some View {
        Rectangle()
            .fill(style.glass ? Color.clear : OLColor.divider)
            .frame(width: style.glass ? FalconStyle.paneGap : OL.divider)
            .overlay {
                Color.clear
                    .frame(width: 7)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if startWidth == nil { startWidth = width }
                                width = min(max((startWidth ?? width) + value.translation.width, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
    }
}
