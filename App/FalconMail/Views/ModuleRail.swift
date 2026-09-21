import SwiftUI
import FalconCore

/// The row of module icons under the sidebar: Mail, Calendar, People, Tasks, Notes, eighteen
/// points each, fifty-four apart, the chosen one in Outlook's blue.
struct ModuleRail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: OL.railPitch - OL.railIcon) {
            ForEach(AppModule.allCases) { module in
                RailButton(title: module.title, symbol: ModuleRail.outline(module), selected: model.module == module, enabled: true) {
                    model.showModule(module)
                }
            }
            RailButton(title: "Tasks", symbol: "checklist.unchecked", selected: false, enabled: false) {}
            RailButton(title: "Notes", symbol: "note.text", selected: false, enabled: false) {}
            Spacer(minLength: 0)
        }
        .padding(.leading, OL.railFirstCenter - OL.railIcon / 2)
        .frame(height: OL.rail)
        .background(OLColor.sidebar)
    }
}

extension ModuleRail {
    /// Outlook's rail icons are line drawings, never filled.
    static func outline(_ module: AppModule) -> String {
        switch module {
        case .mail: return "envelope"
        case .calendar: return "calendar"
        case .people: return "person.2"
        }
    }
}

struct RailButton: View {
    let title: LocalizedStringKey
    let symbol: String
    let selected: Bool
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: OL.railIcon - 2, weight: .regular))
                .foregroundStyle(selected ? OLColor.inbox : OLColor.icon)
                .frame(width: OL.railIcon, height: OL.rail)
                .opacity(enabled ? 1 : 0.45)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(enabled ? Text(title) : Text("Not in FalconMail yet"))
    }
}
