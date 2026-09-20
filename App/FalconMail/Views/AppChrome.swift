import SwiftUI
import AppKit

/// Applies the theme colour and text size the General settings pane offers.
struct ThemedRoot: ViewModifier {
    @AppStorage(Pref.theme) private var theme = AccentTheme.blue.rawValue
    @AppStorage(Pref.textSize) private var textSize = 0
    @AppStorage(Pref.transparency) private var transparency = true

    func body(content: Content) -> some View {
        content
            .tint(AccentTheme(rawValue: theme)?.colour ?? .accentColor)
            .environment(\.appTextScale, 1 + CGFloat(textSize) * 0.06)
            .background(WindowTransparency(enabled: transparency))
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

struct WindowTransparency: NSViewRepresentable {
    let enabled: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { apply(view) }
    }

    private func apply(_ view: NSView) {
        guard let window = view.window else { return }
        window.titlebarAppearsTransparent = enabled
        window.isOpaque = !enabled
        window.backgroundColor = enabled ? .clear : .windowBackgroundColor
    }
}
