import SwiftUI
import AppKit

/// Applies the theme colour, text size and material choice the General settings pane offers.
/// Window opacity is never touched: an unopaque window stops AppKit clearing its backing store,
/// which leaves stale pixels and other windows showing through.
struct ThemedRoot: ViewModifier {
    @AppStorage(Pref.theme) private var theme = AccentTheme.blue.rawValue
    @AppStorage(Pref.textSize) private var textSize = 0
    @AppStorage(Pref.windowStyle) private var window = WindowStyle.legacy.rawValue
    @AppStorage(Pref.ribbonIcons) private var icons = RibbonIconStyle.clean.rawValue
    @AppStorage(Pref.ribbonNames) private var names = true

    func body(content: Content) -> some View {
        content
            .tint(AccentTheme(rawValue: theme)?.colour ?? .accentColor)
            .environment(\.appTextScale, 1 + CGFloat(textSize) * 0.06)
            .environment(\.falconStyle, FalconStyle(window: window, icons: icons, names: names))
    }
}

private struct AppTextScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }

extension EnvironmentValues {
    var appTextScale: CGFloat {
        get { self[AppTextScaleKey.self] }
        set { self[AppTextScaleKey.self] = newValue }
    }
}

extension View {
    func themedRoot() -> some View { modifier(ThemedRoot()) }

    /// Scales a point size by the reader's Text display size preference.
    func scaledFont(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(ScaledFont(size: size, weight: weight))
    }
}

struct ScaledFont: ViewModifier {
    @Environment(\.appTextScale) private var scale
    let size: CGFloat
    let weight: Font.Weight

    func body(content: Content) -> some View {
        content.font(.system(size: size * scale, weight: weight))
    }
}

/// The background behind the ribbon strips. Translucent when the reader wants it, a solid
/// window colour otherwise. Either way the window itself stays opaque: clearing a window's
/// backing store stops AppKit repainting it and leaves other windows showing through.
struct ChromeBackground: View {
    @AppStorage(Pref.transparency) private var transparency = true

    var body: some View {
        if transparency {
            Rectangle().fill(.bar)
        } else {
            Rectangle().fill(Color(nsColor: .windowBackgroundColor))
        }
    }
}
