import SwiftUI
import AppKit
import FalconCore

/// Outlook's Settings panes, in the order its icon grid shows them.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, accounts, notifications, categories, fonts, autoCorrect, spelling
    case reading, composing, signatures, rules, junk
    case calendar, contacts, privacy

    var id: String { rawValue }

    /// The caption under the icon, broken where Outlook breaks it.
    var caption: String {
        switch self {
        case .general: return "General"
        case .accounts: return "Accounts"
        case .notifications: return "Notifications\n& Sounds"
        case .categories: return "Categories"
        case .fonts: return "Fonts"
        case .autoCorrect: return "Auto-correct"
        case .spelling: return "Spelling &\nGrammar"
        case .reading: return "Reading"
        case .composing: return "Composing"
        case .signatures: return "Signatures"
        case .rules: return "Rules"
        case .junk: return "Junk"
        case .calendar: return "Calendar"
        case .contacts: return "Contacts"
        case .privacy: return "Privacy"
        }
    }

    /// The window's title while the pane shows, which Outlook sometimes words otherwise than
    /// the caption.
    var windowTitle: String {
        switch self {
        case .notifications: return "Notifications and Sounds"
        case .autoCorrect: return "AutoCorrect"
        case .spelling: return "Spelling and Grammar"
        default: return caption
        }
    }

    /// The whole window, title bar included. Outlook's own sizes where it was measured; the
    /// others fit what FalconMail has to show in them.
    var windowSize: NSSize {
        switch self {
        case .signatures: return NSSize(width: 612, height: 425)
        case .notifications: return NSSize(width: 640, height: 596)
        case .general, .reading: return NSSize(width: 760, height: 700)
        case .accounts, .rules, .composing: return NSSize(width: 760, height: 620)
        case .autoCorrect: return NSSize(width: 760, height: 520)
        case .calendar, .privacy: return NSSize(width: 700, height: 600)
        case .categories, .fonts: return NSSize(width: 700, height: 440)
        case .spelling, .junk, .contacts: return NSSize(width: 640, height: 320)
        }
    }

    static let personal: [SettingsPane] = [.general, .accounts, .notifications, .categories, .fonts, .autoCorrect, .spelling]
    static let email: [SettingsPane] = [.reading, .composing, .signatures, .rules, .junk]
    static let other: [SettingsPane] = [.calendar, .contacts, .privacy]
}

/// Which page the Settings window shows: the icon grid, or one pane.
@MainActor
@Observable
final class SettingsNavigator {
    private(set) var pane: SettingsPane?
    @ObservationIgnored var didChange: ((SettingsPane?) -> Void)?

    init(pane: SettingsPane? = nil) {
        self.pane = pane
    }

    func show(_ pane: SettingsPane?) {
        guard pane != self.pane else { return }
        self.pane = pane
        didChange?(pane)
    }
}

/// Outlook's Settings window: the icon grid under a title bar with Show All at its right end.
/// Choosing an icon puts that pane in the grid's place, titles the window after it and sizes
/// the window to it, keeping its top edge where it was; Show All goes back.
@MainActor
final class SettingsWindows: NSObject {
    static let shared = SettingsWindows()
    static let gridSize = NSSize(width: 883, height: 373)
    static let gridTitle = "FalconMail Settings"
    /// The title bar, a toolbar's height so the window buttons sit in its middle as Outlook's do.
    static let titleBarHeight: CGFloat = 52

    weak var model: AppModel?
    weak var updates: UpdateManager?
    private var window: NSWindow?
    private let navigator = SettingsNavigator()

    /// Opens the window at `pane`, or as it was left when no pane is asked for.
    func show(_ pane: SettingsPane? = nil) {
        guard let model, let updates else { return }
        if window == nil {
            let made = Self.window(navigator: navigator, model: model, updates: updates)
            made.center()
            window = made
        }
        if let pane { navigator.show(pane) }
        window?.makeKeyAndOrderFront(nil)
    }

    static func size(of pane: SettingsPane?) -> NSSize { pane?.windowSize ?? gridSize }

    static func title(of pane: SettingsPane?) -> String { pane?.windowTitle ?? gridTitle }

    /// The window, not yet on screen. Its title bar is drawn with the rest, as Outlook's colours
    /// and its Show All need, over an empty toolbar that gives it Outlook's height.
    static func window(navigator: SettingsNavigator, model: AppModel, updates: UpdateManager) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size(of: navigator.pane)),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.toolbar = NSToolbar(identifier: "FalconMailSettings")
        window.toolbarStyle = .unified
        window.title = title(of: navigator.pane)
        window.tabbingMode = .disallowed
        let root = SettingsRoot(navigator: navigator)
            .environment(model)
            .environmentObject(updates)
            .themedRoot()
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        window.contentView = host
        navigator.didChange = { [weak window] pane in
            guard let window else { return }
            window.title = title(of: pane)
            let size = size(of: pane)
            var frame = window.frame
            frame.origin.y += frame.height - size.height
            frame.size = size
            window.setFrame(frame, display: true, animate: window.isVisible)
        }
        return window
    }
}

/// The window's content: the title bar and the grid or the pane under it.
struct SettingsRoot: View {
    let navigator: SettingsNavigator

    var body: some View {
        ZStack(alignment: .top) {
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, SettingsWindows.titleBarHeight)
            SettingsTitleBar(title: SettingsWindows.title(of: navigator.pane)) { navigator.show(nil) }
        }
        .background(Classic.pane)
        .ignoresSafeArea()
    }

    @ViewBuilder private var page: some View {
        switch navigator.pane {
        case nil: SettingsGrid { navigator.show($0) }
        case .general: GeneralSettings()
        case .accounts: AccountSettings()
        case .notifications: NotificationsSettings()
        case .categories: CategoriesSettings()
        case .fonts: FontsSettings()
        case .autoCorrect: AutoCorrectSettings()
        case .spelling: SpellingSettings()
        case .reading: ReadingSettings()
        case .composing: ComposingSettings()
        case .signatures: SignaturesSettings()
        case .rules: RulesSettings()
        case .junk: JunkSettings()
        case .calendar: CalendarSettings()
        case .contacts: ContactsSettings()
        case .privacy: PrivacySettings()
        }
    }
}

/// Outlook's title bar: the window's name in fifteen point semibold after the window buttons,
/// Show All as an outlined button at the right end, a black line under both. Both dim with the
/// window.
struct SettingsTitleBar: View {
    let title: String
    let showAll: () -> Void
    @Environment(\.controlActiveState) private var activeState

    private var active: Bool { activeState != .inactive }

    var body: some View {
        GeometryReader { geometry in
            Placements(width: geometry.size.width, height: SettingsWindows.titleBarHeight + 1) {
                (active ? Classic.titleBar : Classic.titleBarInactive)
                    .frame(width: geometry.size.width, height: SettingsWindows.titleBarHeight)
                WindowDragArea().frame(width: geometry.size.width, height: SettingsWindows.titleBarHeight)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(active ? Classic.titleText : Classic.titleTextInactive)
                    .fixedSize()
                    .allowsHitTesting(false)
                    .at(x: 91, baseline: 31)
                Button(action: showAll) {
                    Text("Show All")
                        .font(.system(size: 13))
                        .foregroundStyle(active ? Classic.showAllText : Classic.showAllTextInactive)
                        .offset(y: -1)
                        .frame(width: 65.5, height: 28)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(active ? Classic.showAllBorder : Classic.showAllBorderInactive, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .at(x: geometry.size.width - 12.5 - 65.5, y: 12)
                VStack(spacing: 0) {
                    Classic.toolbarLine.frame(height: 0.5)
                    Classic.toolbarLineShade.frame(height: 0.5)
                }
                .frame(width: geometry.size.width)
                .at(x: 0, y: SettingsWindows.titleBarHeight)
            }
        }
        .frame(height: SettingsWindows.titleBarHeight + 1)
    }
}

// MARK: - the icon grid

/// Personal Settings, Email and Other in three bands a hundred and two points apart, each
/// headed in thirteen point bold with its icons in columns a hundred and nine points wide,
/// captioned in eleven points.
struct SettingsGrid: View {
    let open: (SettingsPane) -> Void

    static let bandPitch: CGFloat = 102
    static let columnPitch: CGFloat = 109
    static let firstColumnCentre: CGFloat = 60

    var body: some View {
        VStack(spacing: 0) {
            band("Personal Settings", SettingsPane.personal, dark: true, height: Self.bandPitch)
            band("Email", SettingsPane.email, dark: false, height: Self.bandPitch)
            // The last band runs down to the window's bottom edge, its line a point higher and
            // its icons a point lower than the others', as in Outlook's.
            band("Other", SettingsPane.other, dark: true,
                 height: SettingsWindows.gridSize.height - SettingsWindows.titleBarHeight - 2 * Self.bandPitch, last: true)
        }
    }

    private func band(_ title: String, _ panes: [SettingsPane], dark: Bool, height: CGFloat, last: Bool = false) -> some View {
        Placements(width: SettingsWindows.gridSize.width, height: height) {
            (dark ? Classic.bandDark : Classic.bandLight).frame(width: SettingsWindows.gridSize.width, height: height)
            (dark ? Classic.bandDarkLine : Classic.bandLightLine)
                .frame(width: SettingsWindows.gridSize.width, height: 1)
                .at(x: 0, y: height - (last ? 2.5 : 1.5))
            ClassicText(title, weight: .bold).at(x: 13, baseline: 19)
            ForEach(Array(panes.enumerated()), id: \.element) { index, pane in
                SettingsTile(pane: pane) { open(pane) }
                    .at(x: Self.firstColumnCentre + CGFloat(index) * Self.columnPitch - Self.columnPitch / 2, y: last ? 27 : 26)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// One icon and its caption: the icon centred on its column forty-six and a half points below
/// the band's top, the caption's lines centred under it with baselines at seventy-eight and
/// fourteen points lower.
struct SettingsTile: View {
    let pane: SettingsPane
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Placements(width: SettingsGrid.columnPitch, height: 70) {
                SettingsIcon(pane: pane)
                    .frame(width: 32, height: 32)
                    .at(x: SettingsGrid.columnPitch / 2 - 16, y: 4.5)
                ForEach(Array(pane.caption.split(separator: "\n").enumerated()), id: \.offset) { line, words in
                    Text(words)
                        .font(.system(size: 11))
                        .foregroundStyle(Classic.label)
                        .fixedSize()
                        .at(centreX: SettingsGrid.columnPitch / 2, baseline: 52 + CGFloat(line) * 14)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pane.windowTitle)
    }
}

/// The pane icons, drawn from SF Symbols in the colours of Outlook's own.
struct SettingsIcon: View {
    let pane: SettingsPane

    private static let blue = Color(red: 0.29, green: 0.53, blue: 0.85)
    /// White parts in the dark, grey on the light ground where white would vanish.
    private static let paper = Classic.colour(light: 0x9A9A9A, dark: 0xEDEDED)
    private static let ink = Classic.colour(light: 0x5A5A5A, dark: 0x6B6B6B)
    private static let letters = Classic.colour(light: 0x7A7A7A, dark: 0xC7C7C7)

    var body: some View {
        let fit = fit
        drawn
            .scaleEffect(x: fit.width, y: fit.height)
            .offset(x: fit.x, y: fit.y)
    }

    /// Stretches and nudges each stand-in into the box Outlook's icon fills, which the symbol's
    /// own proportions miss by up to four points (measured against Outlook's grid at 2x).
    private var fit: (width: CGFloat, height: CGFloat, x: CGFloat, y: CGFloat) {
        switch pane {
        case .general: (1.02, 0.94, -0.25, 0.25)
        case .accounts: (0.98, 1.2, -0.25, -0.5)
        case .notifications: (0.86, 0.98, -0.25, 0.75)
        case .categories: (1, 1, 0, 0.5)
        case .fonts: (0.98, 1.15, 1.25, -0.75)
        case .autoCorrect: (1.05, 1.11, 0.25, 0.25)
        case .spelling: (0.97, 1.11, -0.5, 0.25)
        case .reading: (0.98, 0.96, -0.25, -1)
        case .composing: (1, 0.89, 0, 0)
        case .signatures: (0.96, 1.07, 0.5, 0.25)
        case .rules: (0.96, 1.02, 0.5, -0.25)
        case .junk: (0.935, 1, 1, -0.5)
        case .calendar: (0.96, 1, 0, 0.5)
        case .contacts: (0.96, 0.95, 0, -1)
        case .privacy: (1.09, 0.98, -0.5, -1.25)
        }
    }

    @ViewBuilder private var drawn: some View {
        switch pane {
        case .general:
            symbol("lightswitch.off.square.fill", 28, Self.ink, Self.paper)
        case .accounts:
            symbol("person.text.rectangle.fill", 22, Self.paper, Self.blue)
        case .notifications:
            symbol("alarm.fill", 27, Self.paper, Self.blue)
        case .categories:
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    swatch(Color(red: 0.82, green: 0.29, blue: 0.29))
                    swatch(Color(red: 0.95, green: 0.76, blue: 0.23))
                }
                GridRow {
                    swatch(Color(red: 0.51, green: 0.71, blue: 0.40))
                    swatch(Color(red: 0.29, green: 0.53, blue: 0.85))
                }
            }
        case .fonts:
            ZStack(alignment: .bottomLeading) {
                Text("A").font(.system(size: 31, weight: .regular)).foregroundStyle(Self.letters)
                    .offset(x: 9, y: 3)
                Text("A").font(.system(size: 25, weight: .light).italic()).foregroundStyle(Self.blue)
                    .offset(x: 1, y: -4)
            }
            .frame(width: 32, height: 32, alignment: .bottomLeading)
            .offset(x: 0.5, y: 0)
        case .autoCorrect:
            lettered(accent: Image(systemName: "bolt.fill"), colour: Color(red: 0.93, green: 0.55, blue: 0.23))
                .offset(y: 1.75)
        case .spelling:
            lettered(accent: Image(systemName: "checkmark"), colour: Color(red: 0.35, green: 0.75, blue: 0.35))
                .offset(x: -1.25, y: 2)
        case .reading:
            symbol("envelope.open.fill", 22.5, Self.ink, Self.paper)
        case .composing:
            symbol("square.and.pencil", 29, Color(red: 0.93, green: 0.62, blue: 0.20), Self.paper)
                .offset(x: -1.25, y: -2.25)
        case .signatures:
            symbol("signature", 19, Self.paper, Self.blue)
        case .rules:
            symbol("arrow.triangle.branch", 27.5, Color(red: 0.55, green: 0.40, blue: 0.80), Self.paper)
                .offset(y: 1.5)
        case .junk:
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "folder.fill").font(.system(size: 25)).foregroundStyle(Color(red: 0.55, green: 0.66, blue: 0.80))
                Image(systemName: "nosign").font(.system(size: 14, weight: .bold)).foregroundStyle(Color(red: 0.87, green: 0.22, blue: 0.20))
                    .background(Circle().fill(.white).padding(1))
                    .offset(x: 1, y: 3)
            }
            .offset(x: -2)
        case .calendar:
            symbol("calendar", 25.5, Self.paper, Color(white: 0.55))
        case .contacts:
            symbol("person.crop.rectangle.fill", 23.5, Self.paper, Self.blue)
        case .privacy:
            symbol("shield.lefthalf.filled", 28, Self.blue, Self.paper)
        }
    }

    private func symbol(_ name: String, _ size: CGFloat, _ primary: Color, _ secondary: Color) -> some View {
        Image(systemName: name)
            .symbolRenderingMode(.palette)
            .foregroundStyle(primary, secondary)
            .font(.system(size: size))
    }

    private func swatch(_ colour: Color) -> some View {
        RoundedRectangle(cornerRadius: 1).fill(colour).frame(width: 12, height: 12)
    }

    private func lettered(accent: Image, colour: Color) -> some View {
        ZStack(alignment: .topTrailing) {
            Text("ABC").font(.system(size: 14.5, weight: .bold)).foregroundStyle(Self.letters)
                .frame(width: 32, height: 32, alignment: .bottom)
                .offset(y: -3)
            accent.font(.system(size: 13, weight: .bold)).foregroundStyle(colour).offset(x: -2, y: 1)
        }
        .frame(width: 32, height: 32)
    }
}
