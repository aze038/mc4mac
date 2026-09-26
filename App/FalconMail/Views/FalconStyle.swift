import SwiftUI
import AppKit

/// The look of the mailbox window, from Settings → Appearance: Legacy Outlook, as it has been,
/// or iOS 27 Glass; the ribbon's icons as clean lines or colour tiles; and the buttons' names
/// shown or hidden. Views read it from the environment, which the mailbox window sets.
enum WindowStyle: String, CaseIterable, Identifiable {
    case legacy, glass

    var id: String { rawValue }

    var title: String {
        switch self {
        case .legacy: return "Legacy Outlook"
        case .glass: return "iOS 27 Glass"
        }
    }
}

enum RibbonIconStyle: String, CaseIterable, Identifiable {
    case clean, tiles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clean: return "Clean lines"
        case .tiles: return "Colour tiles"
        }
    }
}

struct FalconStyle: Equatable {
    var glass = false
    var tiles = false
    var showsNames = true

    init(glass: Bool = false, tiles: Bool = false, showsNames: Bool = true) {
        self.glass = glass
        self.tiles = tiles
        self.showsNames = showsNames
    }

    /// From the stored settings.
    init(window: String, icons: String, names: Bool) {
        self.init(glass: WindowStyle(rawValue: window) == .glass, tiles: RibbonIconStyle(rawValue: icons) == .tiles,
                  showsNames: names)
    }

    /// The ribbon's height: Outlook's with names under the icons (two lines in Legacy, one in
    /// Glass), and only the icons' without.
    var ribbonHeight: CGFloat {
        guard showsNames else { return 48 }
        return glass ? 62 : OL.ribbon
    }

    /// Glass puts each name on one line; Legacy keeps Outlook's two.
    var oneLineNames: Bool { glass }

    static let paneCorner: CGFloat = 14
    static let paneGap: CGFloat = 8
}

private struct FalconStyleKey: EnvironmentKey {
    static let defaultValue = FalconStyle()
}

extension EnvironmentValues {
    var falconStyle: FalconStyle {
        get { self[FalconStyleKey.self] }
        set { self[FalconStyleKey.self] = newValue }
    }
}

/// Reads the three settings and hands them to everything inside.
struct FalconStyleReader<Content: View>: View {
    @AppStorage(Pref.windowStyle) private var window = WindowStyle.legacy.rawValue
    @AppStorage(Pref.ribbonIcons) private var icons = RibbonIconStyle.clean.rawValue
    @AppStorage(Pref.ribbonNames) private var names = true
    @ViewBuilder var content: (FalconStyle) -> Content

    var body: some View {
        let style = FalconStyle(window: window, icons: icons, names: names)
        content(style).environment(\.falconStyle, style)
    }
}

// MARK: - Glass surfaces

/// The window's own frosted background in Glass: the desktop shows through, softly.
struct GlassWindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension View {
    /// A floating glass pane: Apple's Liquid Glass on macOS 26, its frosted material before.
    @ViewBuilder
    func glassPane(cornerRadius: CGFloat = FalconStyle.paneCorner) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        }
    }

    /// A solid rounded card on the glass, for the list and the message, which must stay easy to
    /// read.
    func glassCard(cornerRadius: CGFloat = FalconStyle.paneCorner) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self.clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

// MARK: - Colour tiles

enum RibbonTileColour {
    /// Each command's own colour on a tile, by its icon: red for Delete, green for Archive and so
    /// on, as iOS Settings colours its rows.
    static func colour(for symbol: String, tint: Color?) -> Color {
        let pairs: [(String, Color)] = [
            ("trash", .red), ("archivebox", .green), ("arrow.down.to.line", .blue), ("folder", .blue),
            ("person.crop.circle.badge.xmark", .orange), ("envelope.open.badge", .purple),
            ("envelope", .blue), ("tag", .yellow), ("flag", .red), ("text.alignleft", .teal),
            ("rectangle", .indigo), ("line.3.horizontal.decrease", .teal), ("circle.lefthalf", .gray),
            ("sun", .orange), ("arrow.triangle.2.circlepath", .green), ("arrow.clockwise", .green),
            ("bubble", .blue), ("paperplane", .blue), ("paperclip", .gray), ("calendar", .red),
            ("person", .blue), ("square.and.arrow", .blue), ("list.bullet", .green),
            ("exclamationmark", .orange), ("externaldrive", .purple), ("doc", .gray),
        ]
        for (prefix, colour) in pairs where symbol.hasPrefix(prefix) { return colour }
        return tint ?? .accentColor
    }
}
