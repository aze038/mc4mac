import SwiftUI

enum RibbonMetrics {
    static let tileWidth: CGFloat = 68
    static let tileHeight: CGFloat = 74
    static let glyph: CGFloat = 24
    static let caption: CGFloat = 11
    static let bodyHeight: CGFloat = 86
}

struct RibbonGlyph: View {
    let symbol: String
    var tint: Color?
    var size: CGFloat = RibbonMetrics.glyph

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .thin))
            .foregroundStyle(tint ?? Color.primary.opacity(0.85))
            .frame(height: size)
    }
}

struct RibbonCaption: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: RibbonMetrics.caption))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
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
            VStack(spacing: 5) {
                RibbonGlyph(symbol: symbol, tint: enabled ? tint : nil)
                RibbonCaption(title: title)
            }
            .frame(width: RibbonMetrics.tileWidth, height: RibbonMetrics.tileHeight)
            .opacity(enabled ? 1 : 0.38)
            .background(hovering && enabled ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(title)
    }
}

struct RibbonSplitTile<Content: View>: View {
    let title: String
    let symbol: String
    var tint: Color?
    var enabled = true
    var action: (() -> Void)?
    @ViewBuilder var menu: () -> Content
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button { action?() } label: {
                VStack(spacing: 5) {
                    RibbonGlyph(symbol: symbol, tint: enabled ? tint : nil)
                    RibbonCaption(title: title)
                }
                .frame(width: RibbonMetrics.tileWidth, height: RibbonMetrics.tileHeight)
                .opacity(enabled ? 1 : 0.38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled || action == nil)

            Menu { menu() } label: {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 16)
            .disabled(!enabled)
        }
        .background(hovering && enabled ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .onHover { hovering = $0 }
        .help(title)
    }
}

struct RibbonMenuTile<Content: View>: View {
    let title: String
    let symbol: String
    var tint: Color?
    var enabled = true
    @ViewBuilder var menu: () -> Content
    @State private var hovering = false

    var body: some View {
        Menu { menu() } label: {
            VStack(spacing: 5) {
                RibbonGlyph(symbol: symbol, tint: enabled ? tint : nil)
                HStack(spacing: 2) {
                    RibbonCaption(title: title)
                    Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
            .frame(width: RibbonMetrics.tileWidth + 8, height: RibbonMetrics.tileHeight)
            .opacity(enabled ? 1 : 0.38)
            .background(hovering && enabled ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(title)
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
                RibbonGlyph(symbol: symbol, tint: enabled ? tint : nil, size: 15).frame(width: 18)
                Text(title).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: 24)
            .padding(.horizontal, 4)
            .opacity(enabled ? 1 : 0.38)
            .background(hovering && enabled ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(title)
    }
}

struct RibbonMiniColumn<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) { content() }
            .frame(height: RibbonMetrics.tileHeight, alignment: .center)
            .fixedSize(horizontal: true, vertical: false)
    }
}

struct RibbonSeparator: View {
    var body: some View {
        Divider().frame(height: RibbonMetrics.tileHeight - 8).padding(.horizontal, 7)
    }
}

struct RibbonPill: View {
    let onLabel: String
    let offLabel: String
    let caption: String
    @Binding var isOn: Bool

    var body: some View {
        VStack(spacing: 6) {
            Button { isOn.toggle() } label: {
                HStack(spacing: 6) {
                    if isOn { Text(onLabel).font(.system(size: 12, weight: .medium)).foregroundStyle(.white) }
                    Circle().fill(.white).frame(width: 17, height: 17).shadow(radius: 1, y: 0.5)
                    if !isOn { Text(offLabel).font(.system(size: 12, weight: .medium)).foregroundStyle(.white) }
                }
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(isOn ? Color(red: 0.24, green: 0.72, blue: 0.4) : Color.secondary.opacity(0.7), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            Text(caption).font(.system(size: RibbonMetrics.caption)).lineLimit(1)
        }
        .frame(height: RibbonMetrics.tileHeight)
        .fixedSize(horizontal: true, vertical: false)
        .help(caption)
    }
}

struct RibbonTabStrip<Tab: Hashable>: View {
    let tabs: [(tab: Tab, title: String)]
    @Binding var selection: Tab

    var body: some View {
        HStack(spacing: 22) {
            ForEach(tabs, id: \.tab) { entry in
                Button { selection = entry.tab } label: {
                    VStack(spacing: 3) {
                        Text(entry.title)
                            .font(.system(size: 13.5, weight: selection == entry.tab ? .semibold : .regular))
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
                .font(.system(size: 14, weight: .light))
                .frame(width: 26, height: 22)
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

struct RibbonBody<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) { row }
        }
        .frame(height: RibbonMetrics.bodyHeight)
    }

    private var row: some View {
        HStack(alignment: .center, spacing: 1) {
            content()
            Spacer(minLength: 10)
        }
        .padding(.horizontal, 8)
    }
}
