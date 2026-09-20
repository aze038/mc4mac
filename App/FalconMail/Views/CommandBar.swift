import SwiftUI
import FalconCore

struct CommandBar: View {
    @Environment(AppModel.self) private var model

    private var hasSelection: Bool { !model.selectedMessageIDs.isEmpty }
    private var hasSingle: Bool { model.currentThread != nil }
    private var first: MessageSummary? { model.firstSelectedMessage }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ribbon.environment(\.ribbonShowsLabels, true)
            ribbon.environment(\.ribbonShowsLabels, false)
            ScrollView(.horizontal, showsIndicators: false) {
                ribbon.environment(\.ribbonShowsLabels, false)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var ribbon: some View {
        HStack(spacing: 2) {
            NewMailButton()
            RibbonDivider()
            RibbonButton("Delete", "trash", enabled: hasSelection) { model.delete(model.selectedMessages) }
            RibbonButton("Archive", "archivebox", enabled: hasSelection) { model.archive(model.selectedMessages) }
            RibbonButton(model.selectionIsAllInJunk ? "Not Junk" : "Junk", "xmark.bin", enabled: hasSelection) { model.toggleJunkOnSelection() }
            RibbonButton("Mute", "bell.slash", enabled: hasSelection) { model.muteSelection() }
            RibbonDivider()
            RibbonButton("Reply", "arrowshape.turn.up.left", enabled: hasSingle) { model.replyToSelection(all: false) }
            RibbonButton("Reply All", "arrowshape.turn.up.left.2", enabled: hasSingle) { model.replyToSelection(all: true) }
            RibbonButton("Forward", "arrowshape.turn.up.right", enabled: hasSingle) { model.forwardSelection() }
            RibbonDivider()
            MoveMenu()
            RibbonButton(first?.isRead == false ? "Mark Read" : "Mark Unread", first?.isRead == false ? "envelope.open" : "envelope.badge", enabled: hasSelection) { model.toggleReadOnSelection() }
            RibbonButton(first?.isFlagged == true ? "Unflag" : "Flag", first?.isFlagged == true ? "flag.slash" : "flag", enabled: hasSelection) { model.toggleFlagOnSelection() }
            RibbonDivider()
            FilterMenu()
            RibbonButton("Sync", "arrow.clockwise", enabled: !model.accounts.isEmpty) { model.syncNow() }
            RibbonButton("Undo", "arrow.uturn.backward", enabled: model.canUndoAction) { model.undoLastAction() }
            Spacer(minLength: 12)
            RibbonSearchField()
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct RibbonLabelsKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    var ribbonShowsLabels: Bool {
        get { self[RibbonLabelsKey.self] }
        set { self[RibbonLabelsKey.self] = newValue }
    }
}

struct NewMailButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.ribbonShowsLabels) private var showsLabels

    var body: some View {
        Menu {
            Button("New Message") { model.composeNew() }
            Button("New Meeting…") {
                model.showModule(.calendar)
                NotificationCenter.default.post(name: .falconNewMeeting, object: nil)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.pencil")
                if showsLabels { Text("New Mail").lineLimit(1) }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 4)
        } primaryAction: {
            model.composeNew()
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .disabled(model.accounts.isEmpty)
        .fixedSize()
        .help("New Mail")
        .padding(.trailing, 4)
    }
}

struct RibbonButton: View {
    let title: LocalizedStringKey
    let symbol: String
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    init(_ title: LocalizedStringKey, _ symbol: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            RibbonLabel(title: title, symbol: symbol, hovering: hovering && enabled)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(title)
    }
}

struct RibbonLabel: View {
    @Environment(\.ribbonShowsLabels) private var showsLabels
    let title: LocalizedStringKey
    let symbol: String
    var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Color.accentColor)
            if showsLabels {
                Text(title).font(.system(size: 12.5)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, showsLabels ? 8 : 7)
        .padding(.vertical, 6)
        .background(hovering ? Color.primary.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .help(title)
    }
}

struct RibbonDivider: View {
    var body: some View {
        Divider().frame(height: 22).padding(.horizontal, 4)
    }
}

struct MoveMenu: View {
    @Environment(AppModel.self) private var model

    private var recent: [FolderInfo] {
        let scope = Set(model.selectedMessages.map(\.accountID))
        return model.folders.values.flatMap { $0 }.filter { scope.contains($0.accountID) && model.isRecentTarget($0) }.prefix(6).map { $0 }
    }

    var body: some View {
        Menu {
            ForEach(recent) { folder in
                Button(folder.path) { model.move(model.selectedMessages, to: folder) }
            }
            if !recent.isEmpty { Divider() }
            Button("Move to Folder…") { model.openMovePalette() }
            if let last = model.lastMoveTarget {
                Button("Move Again to \(last.name)") { model.moveToLastTarget() }
            }
        } label: {
            RibbonLabel(title: "Move", symbol: "folder")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.selectedMessageIDs.isEmpty)
        .help("Move to folder")
    }
}

struct FilterMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        return Menu {
            Toggle("Only Unread", isOn: binding(.unread))
            Toggle("Only Flagged", isOn: binding(.flagged))
            Divider()
            Toggle("Keep Filters When Switching Folders", isOn: $model.pinFilters)
            Button("Clear Filters") { model.clearFilters() }.disabled(model.filters.isEmpty)
            Divider()
            Toggle("Group by Conversation", isOn: $model.groupByThread)
            Button("Expand All Conversations") { model.expandAll() }.disabled(!model.hasExpandableThreads)
            Button("Collapse All Conversations") { model.collapseAll() }.disabled(!model.canCollapseSomething)
        } label: {
            RibbonLabel(title: "Filter", symbol: model.filters.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter and view options")
    }

    private func binding(_ filter: MessageFilter) -> Binding<Bool> {
        Binding(get: { model.filters.contains(filter) }, set: { _ in model.toggleFilter(filter) })
    }
}

struct RibbonSearchField: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
            TextField("Search mail", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit { Task { await model.runSearch() } }
                .onExitCommand {
                    model.clearSearch()
                    focused = false
                }
            if !model.searchText.isEmpty {
                Button { model.clearSearch() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(minWidth: 150, idealWidth: 220, maxWidth: 320)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(focused ? Color.accentColor.opacity(0.6) : Color.clear))
        .onChange(of: model.focusSearchToken) { _, _ in focused = true }
    }
}
