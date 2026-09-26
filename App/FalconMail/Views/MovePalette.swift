import SwiftUI
import FalconCore

struct MovePalette: View {
    @Environment(AppModel.self) private var model
    /// Runs once the messages are on their way, as a message window closes when its message moves.
    var onMoved: (() -> Void)?
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
                .onTapGesture { model.closeMovePalette() }
            panel
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
            Divider()
            results
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 24)
        .onAppear { Task { @MainActor in fieldFocused = true } }
        .onExitCommand { model.closeMovePalette() }
        .onKeyPress(.upArrow) { highlight(-1) }
        .onKeyPress(.downArrow) { highlight(1) }
        .onKeyPress(keys: ["n", "p"]) { press in
            guard press.modifiers.contains(.control) else { return .ignored }
            return highlight(press.key.character == "n" ? 1 : -1)
        }
    }

    private var field: some View {
        TextField("Move to folder", text: $query)
            .textFieldStyle(.plain)
            .font(.title3)
            .padding(12)
            .focused($fieldFocused)
            .onSubmit { commit() }
            .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private var matches: [FolderInfo] { model.paletteTargets(matching: query) }

    private var activeIndex: Int { max(0, min(highlighted, matches.count - 1)) }

    private var highlightedFolder: FolderInfo? {
        let list = matches
        guard !list.isEmpty else { return nil }
        return list[activeIndex]
    }

    @ViewBuilder private var results: some View {
        if matches.isEmpty {
            Text(query.isEmpty ? "No folders for the selected messages" : "No folders match")
                .font(.callout).foregroundStyle(.secondary).padding(12)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, folder in
                            row(folder, active: index == activeIndex)
                                .contentShape(Rectangle())
                                .onTapGesture { move(to: folder) }
                        }
                    }
                }
                .frame(maxHeight: 300)
                footer
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if let folder = highlightedFolder {
            let total = model.paletteMessages.count
            let applies = model.paletteMessages.filter { $0.accountID == folder.accountID }.count
            if applies != total {
                Divider()
                Text("Moves \(applies) of \(total) selected messages")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
    }

    private func row(_ folder: FolderInfo, active: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.name)
                Text("\(model.accountName(folder.accountID)) · \(folder.path)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if model.isRecentTarget(folder) {
                Text("Recent")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(active ? Theme.accent.opacity(0.22) : Color.clear)
    }

    private func highlight(_ offset: Int) -> KeyPress.Result {
        let count = matches.count
        guard count > 0 else { return .handled }
        highlighted = min(max(activeIndex + offset, 0), count - 1)
        return .handled
    }

    private func commit() {
        guard let folder = highlightedFolder else { return }
        move(to: folder)
    }

    private func move(to folder: FolderInfo) {
        if model.commitPalette(folder) { onMoved?() }
    }
}
