import SwiftUI
import FalconCore

/// The horizontal module switcher that sits along the bottom of the sidebar, as Outlook does.
struct ModuleRail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppModule.allCases) { module in
                RailButton(title: module.title,
                           symbol: module.symbol,
                           selected: model.module == module,
                           badge: module == .mail ? model.unifiedUnreadCount : 0) {
                    model.showModule(module)
                }
            }
            RailButton(title: "Notes", symbol: "note.text", selected: false, badge: 0) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            Spacer(minLength: 0)
            SettingsLink {
                RailLabel(title: "Settings", symbol: "gearshape", selected: false, badge: 0)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct RailButton: View {
    let title: LocalizedStringKey
    let symbol: String
    let selected: Bool
    let badge: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RailLabel(title: title, symbol: symbol, selected: selected, badge: badge)
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

struct RailLabel: View {
    let title: LocalizedStringKey
    let symbol: String
    let selected: Bool
    let badge: Int
    @State private var hovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .regular))
            .frame(width: 34, height: 26)
            .overlay(alignment: .topTrailing) { badgeView }
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .background(selected ? Color.accentColor.opacity(0.14) : (hovering ? Color.primary.opacity(0.06) : Color.clear),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }
    }

    @ViewBuilder private var badgeView: some View {
        if badge > 0 {
            Text(badge > 99 ? "99+" : "\(badge)")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 3).padding(.vertical, 0.5)
                .background(Color.red, in: Capsule())
                .offset(x: 4, y: -1)
        }
    }
}
