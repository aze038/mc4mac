import SwiftUI
import AppKit

/// The one place the app's colour comes from. Settings → General's Theme colour is read here and
/// nowhere else; every blue that stands for "the app's colour" (buttons, links, unread mail, the
/// selected row, folder icons, the reply row, New Email) asks `Theme` for it.
///
/// The colours are dynamic: AppKit and SwiftUI ask for them each time they draw, so they follow
/// the chosen colour and light or dark alike. A change of colour posts `Theme.changed`, and the
/// windows redraw once, so nothing keeps the old colour on screen.
enum Theme {
    static let changed = Notification.Name("FalconThemeChanged")

    /// The chosen colour itself, as the settings swatch shows it.
    static var chosen: AccentTheme { AccentTheme.current() }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Buttons, links, the New Email button: the colour, a little lighter in dark.
    static let accentNS = NSColor(name: NSColor.Name("FalconAccent")) { appearance in
        let base = chosen.nsColor
        return isDark(appearance) ? base.blended(withFraction: 0.12, of: .white) ?? base : base
    }

    /// Unread senders and subjects, dates and counts: darker in light for contrast on white,
    /// lighter in dark.
    static let unreadNS = NSColor(name: NSColor.Name("FalconUnread")) { appearance in
        let base = chosen.nsColor
        return (isDark(appearance) ? base.blended(withFraction: 0.3, of: .white) : base.blended(withFraction: 0.15, of: .black)) ?? base
    }

    /// The selected row while the list has the keyboard: a pale wash of the colour in light, a
    /// deep one in dark, so its text in `unreadNS` stays readable.
    static let selectionNS = NSColor(name: NSColor.Name("FalconSelection")) { appearance in
        let base = chosen.nsColor
        return (isDark(appearance) ? base.blended(withFraction: 0.72, of: NSColor(white: 0.06, alpha: 1))
                                   : base.blended(withFraction: 0.8, of: .white)) ?? base
    }

    /// Folder icons in the sidebar.
    static let folderNS = NSColor(name: NSColor.Name("FalconFolder")) { appearance in
        let base = chosen.nsColor
        return (isDark(appearance) ? base.blended(withFraction: 0.25, of: .white) : base) ?? base
    }

    static let accent = Color(nsColor: accentNS)
    static let unread = Color(nsColor: unreadNS)
    static let selection = Color(nsColor: selectionNS)
    static let folder = Color(nsColor: folderNS)

    /// Saves the colour and redraws every window in it.
    static func choose(_ theme: AccentTheme) {
        Preferences.set(theme.rawValue, Pref.theme)
        refresh()
    }

    /// Makes every window draw its colours again. AppKit and SwiftUI resolve a dynamic colour
    /// again only when the appearance changes, so each window's is changed for one turn of the
    /// run loop and put back.
    static func refresh() {
        NotificationCenter.default.post(name: changed, object: nil)
        for window in NSApp.windows {
            let own = window.appearance
            let current = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
            window.appearance = NSAppearance(named: current == .darkAqua ? .vibrantDark : .vibrantLight)
            DispatchQueue.main.async {
                window.appearance = own
                window.contentView.map(redraw)
            }
        }
    }

    private static func redraw(_ view: NSView) {
        view.needsDisplay = true
        view.subviews.forEach(redraw)
    }
}
