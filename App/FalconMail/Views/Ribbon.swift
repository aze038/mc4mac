import SwiftUI

enum RibbonMetrics {
    static let disabledOpacity: CGFloat = 0.45
}

/// An Outlook ribbon glyph: a light-weight symbol in Outlook's grey, in a 28 point box, tinted
/// only where Outlook colours its own icon.
struct RibbonGlyph: View {
    let symbol: String
    var tint: Color?
    var size: CGFloat = OL.ribbonIcon
    var box: CGFloat = OL.ribbonIconBox

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(tint ?? OLColor.ribbonIcon)
            .frame(width: box, height: box)
    }
}

/// The caption under a tile. Outlook sets its two lines 10.5 points apart, tighter than the
/// font's own line height, so the lines are laid out one by one.
struct RibbonCaption: View {
    let title: String

    var body: some View {
        VStack(spacing: OL.ribbonLabelPitch - 13) {
            ForEach(Array(title.split(separator: "\n").enumerated()), id: \.offset) { _, line in
                Text(String(line))
                    .font(.system(size: OL.ribbonLabelFont))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .foregroundStyle(OLColor.ribbonLabel)
    }
}

/// The face of every tile: the icon row at the top, the caption 44 points down, both centred,
/// the tile as wide as the wider of the two plus Outlook's six points each side.
private struct TileFace: View {
    let title: String
    let symbol: String
    var tint: Color?
    var enabled: Bool
    var chevron = false

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 4) {
                RibbonGlyph(symbol: symbol, tint: enabled ? tint : nil)
                if chevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(OLColor.ribbonLabel)
                        .frame(width: 10, height: OL.ribbonIconBox)
                }
            }
            .padding(.top, OL.ribbonIconTop)
            RibbonCaption(title: title)
                .padding(.top, OL.ribbonLabelTop)
        }
        .padding(.horizontal, OL.ribbonTilePad)
        .frame(height: OL.ribbon, alignment: .top)
        .opacity(enabled ? 1 : RibbonMetrics.disabledOpacity)
    }
}

private struct TileBackground: ViewModifier {
    let hovering: Bool

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(hovering ? OLColor.hover : Color.clear)
                    .padding(.top, 2)
                    .padding(.bottom, 6)
            }
            .contentShape(Rectangle())
    }
}

struct RibbonTile: View {
    let title: String
    let symbol: String
    var tint: Color?
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            TileFace(title: title, symbol: symbol, tint: tint, enabled: enabled)
                .modifier(TileBackground(hovering: hovering && enabled))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(title.replacingOccurrences(of: "\n", with: " "))
    }
}

/// A tile whose face runs the primary action and whose chevron, beside the icon as Outlook
/// draws it, opens a menu.
struct RibbonSplitTile<Content: View>: View {
    let title: String
    let symbol: String
    var tint: Color?
    var enabled = true
    var action: (() -> Void)?
    @ViewBuilder var menu: () -> Content
    @State private var hovering = false

    var body: some View {
        Button { action?() } label: {
            TileFace(title: title, symbol: symbol, tint: tint, enabled: enabled, chevron: true)
                .modifier(TileBackground(hovering: hovering && enabled))
        }
        .buttonStyle(.plain)
        .disabled(!enabled || action == nil)
        .overlay(alignment: .top) {
            HStack(spacing: 4) {
                Color.clear.frame(width: OL.ribbonIconBox, height: OL.ribbonIconBox)
                Menu { menu() } label: {
                    Color.clear.frame(width: 10, height: OL.ribbonIconBox).contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!enabled)
            }
            .padding(.top, OL.ribbonIconTop)
        }
        .onHover { hovering = $0 }
        .help(title.replacingOccurrences(of: "\n", with: " "))
    }
}

/// A tile that is entirely a menu.
struct RibbonMenuTile<Content: View>: View {
    let title: String
    let symbol: String
    var tint: Color?
    var enabled = true
    @ViewBuilder var menu: () -> Content
    @State private var hovering = false

    var body: some View {
        Menu { menu() } label: {
            TileFace(title: title, symbol: symbol, tint: tint, enabled: enabled, chevron: true)
                .modifier(TileBackground(hovering: hovering && enabled))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(title.replacingOccurrences(of: "\n", with: " "))
    }
}

/// One of the small icon-and-caption rows Outlook stacks beside its tiles (Meeting, Attachment).
struct RibbonMiniItem: View {
    let title: String
    let symbol: String
    var tint: Color?
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                RibbonGlyph(symbol: symbol, tint: enabled ? tint : nil, size: OL.ribbonMiniIcon, box: OL.ribbonMiniIcon)
                Text(title).font(.system(size: OL.ribbonMiniFont)).foregroundStyle(OLColor.ribbonLabel).lineLimit(1)
            }
            .padding(.horizontal, 4)
            .frame(height: OL.ribbonMiniRow)
            .opacity(enabled ? 1 : RibbonMetrics.disabledOpacity)
            .background(hovering && enabled ? OLColor.hover : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(title)
    }
}

/// Small rows stacked to the height of a tile, top-aligned with the icons beside them.
struct RibbonMiniColumn<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: OL.ribbonMiniGap) { content() }
            .padding(.top, OL.ribbonIconTop)
            .frame(height: OL.ribbon, alignment: .top)
    }
}

struct RibbonSeparator: View {
    var body: some View {
        Rectangle()
            .fill(OLColor.ribbonSeparator)
            .frame(width: 1, height: OL.ribbonSeparatorHeight)
            .padding(.top, OL.ribbonIconTop)
            .padding(.horizontal, OL.ribbonSeparatorPad)
    }
}

struct RibbonPill: View {
    let onLabel: String
    let offLabel: String
    let caption: String
    @Binding var isOn: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Button { isOn.toggle() } label: {
                HStack(spacing: 5) {
                    if isOn { Text(onLabel).font(.system(size: 11, weight: .medium)).foregroundStyle(.white) }
                    Circle().fill(.white).frame(width: 16, height: 16).shadow(radius: 1, y: 0.5)
                    if !isOn { Text(offLabel).font(.system(size: 11, weight: .medium)).foregroundStyle(.white) }
                }
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(isOn ? OLColor.sendGreen : Color.secondary.opacity(0.7), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .frame(height: OL.ribbonIconBox)
            .padding(.top, OL.ribbonIconTop)
            RibbonCaption(title: caption).padding(.top, OL.ribbonLabelTop)
        }
        .padding(.horizontal, OL.ribbonTilePad)
        .frame(height: OL.ribbon, alignment: .top)
        .help(caption)
    }
}

/// Home · Organise · Tools. The chosen tab is bright with a three point white line under it.
struct RibbonTabStrip<Tab: Hashable>: View {
    let tabs: [(tab: Tab, title: String)]
    @Binding var selection: Tab

    var body: some View {
        HStack(alignment: .top, spacing: OL.tabGap) {
            ForEach(tabs, id: \.tab) { entry in
                let selected = selection == entry.tab
                Button { selection = entry.tab } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(entry.title)
                            .font(.system(size: OL.tabFont, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? OLColor.tabSelected : OLColor.tab)
                            .padding(.top, OL.tabTextTop)
                            .frame(height: OL.tabUnderlineTop, alignment: .top)
                        Rectangle()
                            .fill(selected ? OLColor.tabUnderline : Color.clear)
                            .frame(height: OL.tabUnderline)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .frame(height: OL.tabRow, alignment: .top)
    }
}

struct RibbonQuickButton: View {
    let symbol: String
    let title: String
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: OL.quickIcon, weight: .regular))
                .foregroundStyle(OLColor.ribbonLabel)
                .frame(width: 20, height: 20)
                .opacity(enabled ? 1 : 0.35)
                .background(hovering && enabled ? OLColor.hover : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(title)
    }
}

/// The ribbon row: tiles top-aligned, two points apart, eight points in from the edge so the
/// first icon lands at fourteen. Scrolls sideways when the window is narrower than Outlook's.
struct RibbonBody<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: OL.ribbonTileGap) {
                content()
            }
            .padding(.horizontal, OL.ribbonInset)
            .frame(height: OL.ribbon, alignment: .top)
        }
        .scrollIndicators(.never)
        .frame(height: OL.ribbon)
    }
}
