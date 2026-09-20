import SwiftUI

enum RibbonMetrics {
    /// Every tile is the same size, so a row of them lines up whatever the caption says.
    static let tileWidth: CGFloat = 78
    static let tileHeight: CGFloat = 76
    static let tileGap: CGFloat = 2
    static let edgeInset: CGFloat = 12

    static let glyphBox: CGFloat = 26
    static let glyphSize: CGFloat = 22
    static let glyphWeight: Font.Weight = .regular

    static let caption: CGFloat = 11
    /// Two caption lines are always reserved, so a one-line tile and a two-line tile
    /// put their icons at the same height.
    static let captionBlock: CGFloat = 28
    static let captionTop: CGFloat = 4

    static let miniRow: CGFloat = 22
    static let miniGap: CGFloat = 3
    static let miniWidth: CGFloat = 104

    static let disabledOpacity: CGFloat = 0.45
    static var bodyHeight: CGFloat { tileHeight + 10 }
}

struct RibbonGlyph: View {
    let symbol: String
    var tint: Color?
    var size: CGFloat = RibbonMetrics.glyphSize

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: RibbonMetrics.glyphWeight))
            .foregroundStyle(tint ?? Color.primary.opacity(0.88))
            .frame(width: size + 4, height: size)
    }
}

struct RibbonCaption: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: RibbonMetrics.caption))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.85)
            .frame(width: RibbonMetrics.tileWidth - 6, height: RibbonMetrics.captionBlock, alignment: .top)
    }
}

/// The shared body of every tile: a centred glyph over a caption box of fixed height.
private struct TileFace: View {
    let title: String
    let symbol: String
    var tint: Color?
    var enabled: Bool

    var body: some View {
        VStack(spacing: RibbonMetrics.captionTop) {
            RibbonGlyph(symbol: symbol, tint: enabled ? tint : nil)
            RibbonCaption(title: title)
        }
        .frame(width: RibbonMetrics.tileWidth, height: RibbonMetrics.tileHeight, alignment: .top)
        .padding(.top, 6)
        .opacity(enabled ? 1 : RibbonMetrics.disabledOpacity)
    }
}

private struct TileBackground: ViewModifier {
    let hovering: Bool

    func body(content: Content) -> some View {
        content
            .frame(width: RibbonMetrics.tileWidth, height: RibbonMetrics.tileHeight)
            .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(RoundedRectangle(cornerRadius: 5))
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

/// A tile whose face runs the primary action and whose corner chevron opens a menu.
/// The chevron sits inside the tile so the glyph stays centred, the way Outlook draws it.
struct RibbonSplitTile<Content: View>: View {
    let title: String
    let symbol: String
    var tint: Color?
    var enabled = true
    var action: (() -> Void)?
    @ViewBuilder var menu: () -> Content
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Button { action?() } label: {
                TileFace(title: title, symbol: symbol, tint: tint, enabled: enabled)
            }
            .buttonStyle(.plain)
            .disabled(!enabled || action == nil)

            Menu { menu() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.trailing, 3)
            .padding(.bottom, 2)
            .disabled(!enabled)
            .opacity(enabled ? 1 : RibbonMetrics.disabledOpacity)
        }
        .modifier(TileBackground(hovering: hovering && enabled))
        .onHover { hovering = $0 }
        .help(title.replacingOccurrences(of: "\n", with: " "))
    }
}

/// A tile that is entirely a menu. Same footprint as a plain tile, with the chevron
/// tucked into the corner rather than widening the tile.
struct RibbonMenuTile<Content: View>: View {
    let title: String
    let symbol: String
    var tint: Color?
    var enabled = true
    @ViewBuilder var menu: () -> Content
    @State private var hovering = false

    var body: some View {
        Menu { menu() } label: {
            ZStack(alignment: .bottomTrailing) {
                TileFace(title: title, symbol: symbol, tint: tint, enabled: enabled)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 6)
                    .padding(.bottom, 4)
                    .opacity(enabled ? 1 : RibbonMetrics.disabledOpacity)
            }
            .modifier(TileBackground(hovering: hovering && enabled))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(title.replacingOccurrences(of: "\n", with: " "))
    }
}

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
                RibbonGlyph(symbol: symbol, tint: enabled ? tint : nil, size: 14).frame(width: 18)
                Text(title).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .frame(width: RibbonMetrics.miniWidth, height: RibbonMetrics.miniRow, alignment: .leading)
            .opacity(enabled ? 1 : RibbonMetrics.disabledOpacity)
            .background(hovering && enabled ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(title)
    }
}

/// Two or three small rows stacked to the height of one tile, centred against it.
struct RibbonMiniColumn<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: RibbonMetrics.miniGap) { content() }
            .frame(width: RibbonMetrics.miniWidth, height: RibbonMetrics.tileHeight, alignment: .center)
    }
}

struct RibbonSeparator: View {
    var body: some View {
        Divider()
            .frame(height: RibbonMetrics.tileHeight - 12)
            .padding(.horizontal, 6)
    }
}

struct RibbonPill: View {
    let onLabel: String
    let offLabel: String
    let caption: String
    @Binding var isOn: Bool

    var body: some View {
        VStack(spacing: RibbonMetrics.captionTop) {
            Button { isOn.toggle() } label: {
                HStack(spacing: 5) {
                    if isOn { Text(onLabel).font(.system(size: 11, weight: .medium)).foregroundStyle(.white) }
                    Circle().fill(.white).frame(width: 16, height: 16).shadow(radius: 1, y: 0.5)
                    if !isOn { Text(offLabel).font(.system(size: 11, weight: .medium)).foregroundStyle(.white) }
                }
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(isOn ? Color(red: 0.24, green: 0.72, blue: 0.4) : Color.secondary.opacity(0.7), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .frame(height: RibbonMetrics.glyphBox)
            RibbonCaption(title: caption)
        }
        .frame(width: RibbonMetrics.tileWidth, height: RibbonMetrics.tileHeight, alignment: .top)
        .padding(.top, 6)
        .help(caption)
    }
}

struct RibbonTabStrip<Tab: Hashable>: View {
    let tabs: [(tab: Tab, title: String)]
    @Binding var selection: Tab

    var body: some View {
        HStack(spacing: 20) {
            ForEach(tabs, id: \.tab) { entry in
                Button { selection = entry.tab } label: {
                    VStack(spacing: 3) {
                        Text(entry.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(selection == entry.tab ? Color.primary : Color.secondary)
                        Rectangle()
                            .fill(selection == entry.tab ? Color.accentColor : .clear)
                            .frame(height: 2)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
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
                .font(.system(size: 13, weight: .regular))
                .frame(width: 24, height: 20)
                .opacity(enabled ? 0.85 : 0.3)
                .background(hovering && enabled ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(title)
    }
}

/// The ribbon row. Always scrollable, so the layout is measured once rather than
/// twice as ViewThatFits would, and so nothing is ever silently clipped.
struct RibbonBody<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .center, spacing: RibbonMetrics.tileGap) {
                content()
            }
            .padding(.horizontal, RibbonMetrics.edgeInset)
            .frame(height: RibbonMetrics.bodyHeight)
        }
        .scrollIndicators(.automatic)
        .frame(height: RibbonMetrics.bodyHeight)
    }
}
