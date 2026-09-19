import SwiftUI
import FalconCore

struct ModuleRail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 4) {
            ForEach(AppModule.allCases) { module in
                RailButton(title: module.title, symbol: module.symbol, selected: model.module == module, badge: module == .mail ? model.unifiedUnreadCount : 0) {
                    model.showModule(module)
                }
            }
            Spacer()
            SettingsLink {
                RailLabel(title: "Settings", symbol: "gearshape", selected: false, badge: 0)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .frame(width: 64)
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
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .regular))
                .frame(height: 22)
                .overlay(alignment: .topTrailing) { badgeView }
            Text(title).font(.system(size: 10))
        }
        .frame(width: 54, height: 50)
        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        .background(selected ? Color.accentColor.opacity(0.14) : (hovering ? Color.primary.opacity(0.06) : Color.clear), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var badgeView: some View {
        if badge > 0 {
            Text(badge > 99 ? "99+" : "\(badge)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.red, in: Capsule())
                .offset(x: 10, y: -6)
        }
    }
}
