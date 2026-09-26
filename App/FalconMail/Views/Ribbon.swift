import SwiftUI

enum RibbonMetrics {
    static let disabledOpacity: CGFloat = 0.45
}

/// Draws a ribbon control exactly as its face says. The system's own dimming of a disabled
/// button would come on top of the tile's, leaving it darker than Outlook's.
struct RibbonButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

/// An Outlook ribbon glyph: a light-weight symbol in Outlook's grey, in a 28 point box, tinted
/// only where Outlook colours its own icon.
struct RibbonGlyph: View {
    /// The modern ribbon draws every icon in one grey line; only the accent colour, which marks
    /// the main action or a switch that is on, keeps its colour.
    static func modern(_ tint: Color?) -> Color? { tint == Theme.accent ? tint : nil }

    let symbol: String
    var tint: Color?
    var size: CGFloat = OL.ribbonIcon
    var box: CGFloat = OL.ribbonIconBox
    /// Off for the small rows, which never sit on a tile.
    var tileable = true
    @Environment(\.falconStyle) private var style

    var body: some View {
        if style.tiles, tileable {
            // Colour tiles: the icon in its own colour on a softly tinted rounded square.
            let colour = RibbonTileColour.colour(for: symbol, tint: tint)
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(colour)
                .frame(width: 30, height: 30)
                .background(colour.opacity(0.18), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .frame(width: box, height: box)
        } else {
            Image(systemName: symbol)
                .font(.system(size: style.glass ? size - 2 : size, weight: .light))
                .foregroundStyle(RibbonGlyph.modern(tint) ?? OLColor.ribbonIcon)
                .frame(width: box, height: box)
        }
    }
}

/// The caption under a tile. Outlook sets its two lines 10.5 points apart, tighter than the
/// font's own line height, so the lines are laid out one by one.
struct RibbonCaption: View {
    let title: String
    @Environment(\.falconStyle) private var style

    var body: some View {
        if !style.showsNames {
            EmptyView()
        } else if style.oneLineNames {
            // Glass: every name on one line, shortened where Outlook's needs two.
            Text(RibbonCaption.oneLine(title))
                .font(.system(size: 10.5))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(OLColor.ribbonLabel)
        } else {
            VStack(spacing: OL.ribbonLabelPitch - 13) {
                ForEach(Array(title.split(separator: "\n").enumerated()), id: \.offset) { _, line in
                    Text(String(line))
                        .font(.system(size: OL.ribbonLabelFont + 0.5))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(OLColor.ribbonLabel)
        }
    }

    /// Outlook's two-line names as one line, the long ones shortened.
    static func oneLine(_ title: String) -> String {
        let flat = title.replacingOccurrences(of: "\n", with: " ")
        let short = ["Mark All as Read": "All Read", "Send & Receive": "Sync", "Read/Unread": "Read/Unread",
                     "Reading Pane": "Pane", "Dark / Light": "Dark/Light"]
        return short[flat] ?? flat
    }
}

/// The face of every tile: the icon row at the top, the caption 44 points down, both centred,
/// the tile as wide as the wider of the two plus Outlook's six points each side.
private struct TileFace<Glyph: View>: View {
    let title: String
    var enabled: Bool
    var chevron = false
    let glyph: Glyph
    @Environment(\.falconStyle) private var style

    /// A disabled tile keeps a third of its glyph and half of its caption, as Outlook's Send does
    /// before there is anyone to send to.
    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 4) {
                glyph
                if chevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(OLColor.ribbonLabel)
                        .frame(width: 6, height: OL.ribbonIconBox)
                }
            }
            .opacity(enabled ? 1 : OL.ribbonGlyphDimmed)
            .padding(.top, style.glass || !style.showsNames ? 8 : OL.ribbonTileGlyphTop)
            RibbonCaption(title: title)
                .opacity(enabled ? 1 : OL.ribbonCaptionDimmed)
                .padding(.top, style.glass ? 40 : OL.ribbonLabelTop)
        }
        .padding(.horizontal, style.glass ? 7 : OL.ribbonTilePad)
        .frame(height: style.ribbonHeight, alignment: .top)
    }
}

extension TileFace where Glyph == RibbonGlyph {
    init(title: String, symbol: String, tint: Color? = nil, enabled: Bool, chevron: Bool = false) {
        self.init(title: title, enabled: enabled, chevron: chevron, glyph: RibbonGlyph(symbol: symbol, tint: enabled ? tint : nil))
    }
}

private struct TileBackground: ViewModifier {
    let hovering: Bool

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(hovering ? OLColor.hover : Color.clear)
                    .padding(.vertical, 4)
            }
            .contentShape(Rectangle())
    }
}

struct RibbonTile: View {
    let title: String
    let symbol: String
    var tint: Color?
    var enabled = true
    /// The tooltip, when it should say more than the caption.
    var help: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            TileFace(title: title, symbol: symbol, tint: tint, enabled: enabled)
                .modifier(TileBackground(hovering: hovering && enabled))
        }
        .buttonStyle(RibbonButtonStyle())
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help ?? title.replacingOccurrences(of: "\n", with: " "))
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
        .buttonStyle(RibbonButtonStyle())
        .disabled(!enabled || action == nil)
        .overlay(alignment: .top) {
            HStack(spacing: 4) {
                Color.clear.frame(width: OL.ribbonIconBox, height: OL.ribbonIconBox)
                Menu { menu() } label: {
                    Color.clear.frame(width: 6, height: OL.ribbonIconBox).contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!enabled)
            }
            .padding(.top, OL.ribbonTileGlyphTop)
        }
        .onHover { hovering = $0 }
        .help(title.replacingOccurrences(of: "\n", with: " "))
    }
}

/// A tile that drops a panel of its own rather than a menu, as Outlook's Table does: the face
/// and its chevron both open it, and the tile stays lit while it is open. Its glyph is drawn by
/// the caller, as Table's is.
struct RibbonDropdownTile<Glyph: View>: View {
    let title: String
    var isOpen = false
    let glyph: Glyph
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            TileFace(title: title, enabled: true, chevron: true, glyph: glyph)
                .modifier(TileBackground(hovering: hovering || isOpen))
        }
        .buttonStyle(RibbonButtonStyle())
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
        .buttonStyle(RibbonButtonStyle())
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
                RibbonGlyph(symbol: symbol, tint: enabled ? tint : nil, size: OL.ribbonMiniIcon, box: OL.ribbonMiniIcon, tileable: false)
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
    @Environment(\.falconStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: OL.ribbonMiniGap) { content() }
            .padding(.top, OL.ribbonIconTop)
            .frame(height: max(style.ribbonHeight, OL.ribbon), alignment: .top)
    }
}

struct RibbonSeparator: View {
    var body: some View {
        Rectangle()
            .fill(OLColor.ribbonSeparator)
            .frame(width: 1, height: OL.ribbonSeparatorHeight - 16)
            .padding(.top, OL.ribbonIconTop + 8)
            .padding(.horizontal, OL.ribbonSeparatorPad)
    }
}

/// The modern ribbon's group: its tiles on a soft rounded card, a small gap from the next.
struct RibbonGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.falconStyle) private var style

    var body: some View {
        if style.glass {
            // Glass: no cards; each button stands alone, groups kept apart by space alone.
            // Every button the same distance from the next, whether or not a group ends there.
            HStack(alignment: .top, spacing: 4) { content() }
                .frame(height: style.ribbonHeight, alignment: .top)
        } else {
            HStack(alignment: .top, spacing: OL.ribbonTileGap) { content() }
                .padding(.horizontal, 4)
                .frame(height: OL.ribbon, alignment: .top)
                .background {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(OLColor.ribbonCard)
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(OLColor.ribbonCardLine, lineWidth: 1))
                        .padding(.vertical, 3)
                }
                .padding(.trailing, 6)
        }
    }
}

struct RibbonPill: View {
    let onLabel: String
    let offLabel: String
    let caption: String
    @Binding var isOn: Bool
    @Environment(\.falconStyle) private var style

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
            .padding(.top, style.glass || !style.showsNames ? 8 : OL.ribbonIconTop)
            RibbonCaption(title: caption).padding(.top, style.glass ? 40 : OL.ribbonLabelTop)
        }
        .padding(.horizontal, OL.ribbonTilePad)
        .frame(height: style.ribbonHeight, alignment: .top)
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
                            .font(.system(size: OL.tabFont - 1.5, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? OLColor.tabSelected : OLColor.tab)
                            .padding(.top, OL.tabTextTop)
                            .frame(height: OL.tabUnderlineTop, alignment: .top)
                        Capsule()
                            .fill(selected ? Theme.accent : Color.clear)
                            .frame(height: 2)
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

/// Home · Organise · Tools as a small switch in the title row, so the ribbon needs no tab row.
struct RibbonTabSwitch<Tab: Hashable>: View {
    let tabs: [(tab: Tab, title: String)]
    @Binding var selection: Tab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.tab) { entry in
                let selected = selection == entry.tab
                Button { selection = entry.tab } label: {
                    Text(entry.title)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? OLColor.tabSelected : OLColor.tab)
                        .padding(.horizontal, 10)
                        .frame(height: 18)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(OLColor.ribbonCard)
                                    .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .fixedSize()
    }
}

struct RibbonQuickButton: View {
    let symbol: String
    let title: String
    var enabled = true
    var ink = OLColor.ribbonLabel
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: OL.quickIcon, weight: .regular))
                .foregroundStyle(ink)
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
    @Environment(\.falconStyle) private var style

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: style.glass ? 4 : OL.ribbonTileGap) {
                content()
            }
            .padding(.horizontal, OL.ribbonInset)
            .frame(height: style.ribbonHeight, alignment: .top)
        }
        .scrollIndicators(.never)
        .frame(height: style.ribbonHeight)
    }
}
