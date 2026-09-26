import SwiftUI
import FalconCore

struct ContactsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @State private var selected: String?

    private var filtered: [ContactInfo] {
        let q = query.lowercased().trimmed
        var seen = Set<String>()
        return model.contactList
            .filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.email.lowercased().contains(q) }
            .sorted { ($0.name.isEmpty ? $0.email : $0.name).localizedCaseInsensitiveCompare($1.name.isEmpty ? $1.email : $1.name) == .orderedAscending }
            .filter { seen.insert($0.email.lowercased()).inserted }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search contacts", text: $query).textFieldStyle(.roundedBorder)
                Button { Task { await model.syncContacts() } } label: { Image(systemName: "arrow.clockwise") }
            }
            .padding(8)
            Divider()
            List(filtered, selection: $selected) { c in
                HStack(spacing: 10) {
                    Circle().fill(Theme.accent.opacity(0.2)).frame(width: 30, height: 30)
                        .overlay(Text(String((c.name.isEmpty ? c.email : c.name).prefix(1)).uppercased()).font(.caption.bold()))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.name.isEmpty ? c.email : c.name).font(.system(size: 13, weight: .medium))
                        if !c.name.isEmpty { Text(c.email).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Text(sourceLabel(c.source)).font(.caption2).foregroundStyle(.secondary)
                    Button { compose(to: c) } label: { Image(systemName: "square.and.pencil") }.buttonStyle(.plain).help("New message")
                }
                .padding(.vertical, 2)
                .tag(c.id)
                .contextMenu {
                    Button("New Message") { compose(to: c) }
                    Button("Copy Email Address") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(c.email, forType: .string)
                    }
                }
            }
            .overlay { if filtered.isEmpty { ContentUnavailableView("No contacts", systemImage: "person.crop.circle") } }
            Divider()
            Text("\(filtered.count) contacts").font(.caption).foregroundStyle(.secondary).padding(6)
        }
    }

    private func sourceLabel(_ s: String) -> String {
        switch s {
        case "google": return "Google"
        case "google-other": return "Google (other)"
        case "recent": return "Recent"
        default: return s
        }
    }

    private func compose(to c: ContactInfo) {
        guard let account = model.accounts.first(where: { $0.id == c.accountID }) ?? model.accounts.first else { return }
        var draft = ComposeDraft.blank(account: account, signature: model.signature(for: account, .newMessages))
        draft.to = EmailAddress(name: c.name, address: c.email).rfc5322
        model.openCompose(draft, origin: .new)
    }
}
