import SwiftUI
import AppKit
import FalconCore

enum AppRibbonTab: String, CaseIterable {
    case home, organise, tools

    var title: String {
        switch self {
        case .home: return "Home"
        case .organise: return "Organise"
        case .tools: return "Tools"
        }
    }
}

struct CommandBar: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.ribbonTab) private var tabRaw = AppRibbonTab.home.rawValue

    private var tab: Binding<AppRibbonTab> {
        Binding(get: { AppRibbonTab(rawValue: tabRaw) ?? .home }, set: { tabRaw = $0.rawValue })
    }

    var body: some View {
        VStack(spacing: 0) {
            quickAccessRow
            RibbonTabStrip(tabs: AppRibbonTab.allCases.map { ($0, $0.title) }, selection: tab)
                .padding(.horizontal, RibbonMetrics.edgeInset)
                .padding(.top, 2)
            Divider().opacity(0.4)
            Group {
                switch tab.wrappedValue {
                case .home: HomeRibbon()
                case .organise: OrganiseRibbon()
                case .tools: ToolsRibbon()
                }
            }
        }
        .background(ChromeBackground())
    }

    private var quickAccessRow: some View {
        ZStack {
            Text(model.windowTitle)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            HStack(spacing: 2) {
                RibbonQuickButton(symbol: "square.and.arrow.down", title: "Save all drafts") { model.saveLeftoverDrafts() }
                RibbonQuickButton(symbol: "arrow.uturn.backward", title: "Undo", enabled: model.canUndoAction) { model.undoLastAction() }
                RibbonQuickButton(symbol: "arrow.uturn.forward", title: "Redo", enabled: false) {}
                RibbonQuickButton(symbol: "envelope.badge.shield.half.filled", title: "Mark all as read", enabled: model.unifiedUnreadCount > 0) {
                    model.markAllReadEverywhere()
                }
                Spacer()
            }
        }
        .frame(height: 28)
        .padding(.horizontal, RibbonMetrics.edgeInset)
    }
}

struct HomeRibbon: View {
    @Environment(AppModel.self) private var model

    private var hasSelection: Bool { !model.selectedMessageIDs.isEmpty }

    var body: some View {
        let thread = model.currentThread
        let hasSingle = thread != nil
        let first = thread?.latest
        return RibbonBody {
            RibbonTile(title: "New\nEmail", symbol: "envelope", tint: .accentColor, enabled: !model.accounts.isEmpty) { model.composeNew() }
            RibbonMenuTile(title: "New\nItems", symbol: "envelope.badge.person.crop", enabled: !model.accounts.isEmpty) {
                Button("Message") { model.composeNew() }
                Button("Meeting") {
                    model.showModule(.calendar)
                    NotificationCenter.default.post(name: .falconNewMeeting, object: nil)
                }
                Button("Contact") { model.showModule(.people) }
                Divider()
                Button("Folder…") { model.promptForNewFolder() }
            }
            RibbonSeparator()

            RibbonTile(title: "Delete", symbol: "trash", enabled: hasSelection) { model.delete(model.selectedMessages) }
            RibbonTile(title: "Archive", symbol: "archivebox", tint: .green, enabled: hasSelection) { model.archive(model.selectedMessages) }
            RibbonSeparator()

            RibbonTile(title: "Reply", symbol: "arrowshape.turn.up.left", tint: .purple, enabled: hasSingle) { model.replyToSelection(all: false) }
            RibbonTile(title: "Reply\nto All", symbol: "arrowshape.turn.up.left.2", tint: .purple, enabled: hasSingle) { model.replyToSelection(all: true) }
            RibbonTile(title: "Forward", symbol: "arrowshape.turn.up.right", tint: .blue, enabled: hasSingle) { model.forwardSelection() }
            RibbonMiniColumn {
                RibbonMiniItem(title: "Meeting", symbol: "calendar.badge.plus") {
                    model.showModule(.calendar)
                    NotificationCenter.default.post(name: .falconNewMeeting, object: nil)
                }
                RibbonMiniItem(title: "Attachment", symbol: "paperclip", enabled: hasSingle) { model.forwardAsAttachment(model.selectedMessages) }
            }
            RibbonSeparator()

            RibbonTile(title: "Switch\nBackground", symbol: "sun.max", tint: .yellow) { model.cycleAppearance() }
            RibbonSeparator()

            RibbonSplitTile(title: "Move", symbol: "arrow.down.to.line.compact", tint: .blue, enabled: hasSelection, action: { model.openMovePalette() }) {
                MoveMenuItems()
            }
            RibbonSplitTile(title: "Junk", symbol: "person.crop.circle.badge.xmark", tint: .red, enabled: hasSelection, action: { model.toggleJunkOnSelection() }) {
                Button(model.selectionIsAllInJunk ? "Not Junk" : "Move to Junk") { model.toggleJunkOnSelection() }
                Button("Mute Conversation") { model.muteSelection() }
            }
            RibbonMenuTile(title: "Rules", symbol: "envelope.open.badge.clock") {
                Button("Run Rules Now") { model.runRulesNow() }
                Button("Edit Rules…") { openSettings() }
            }
            RibbonSeparator()

            RibbonTile(title: "Read/Unread", symbol: first?.isRead == false ? "envelope.open" : "envelope", enabled: hasSelection) { model.toggleReadOnSelection() }
            RibbonMenuTile(title: "Categorise", symbol: "square.grid.2x2", tint: .orange, enabled: hasSelection) {
                CategoryMenuItems()
            }
            RibbonSplitTile(title: "Follow\nUp", symbol: "flag", tint: .red, enabled: hasSelection, action: { model.toggleFlagOnSelection() }) {
                Button(first?.isFlagged == true ? "Clear Flag" : "Flag Message") { model.toggleFlagOnSelection() }
                Button("Mark All as Read") { model.markAllReadInSelection() }
            }
            RibbonSeparator()

            RibbonMenuTile(title: "Filter\nEmails", symbol: model.filters.isEmpty ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill", tint: .blue) {
                FilterMenuItems()
            }
            RibbonSeparator()

            VStack(alignment: .leading, spacing: RibbonMetrics.miniGap) {
                RibbonSearchField()
                RibbonMiniItem(title: "Address Book", symbol: "person.text.rectangle") { model.showModule(.people) }
            }
            .frame(height: RibbonMetrics.tileHeight, alignment: .center)
            RibbonSeparator()

            RibbonTile(title: "Send &\nReceive", symbol: "arrow.triangle.2.circlepath", tint: .green, enabled: !model.accounts.isEmpty) { model.syncNow() }
        }
    }

    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

struct OrganiseRibbon: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.readingPane) private var readingPane = ReadingPanePosition.right.rawValue
    @AppStorage(Pref.showPreview) private var showPreview = true

    private var currentSort: ListSort { ListSort(rawValue: model.listSort) ?? .date }

    var body: some View {
        @Bindable var model = model
        return RibbonBody {
            RibbonTile(title: "New\nFolder", symbol: "folder.badge.plus", tint: .accentColor, enabled: !model.accounts.isEmpty) { model.promptForNewFolder() }
            RibbonSeparator()

            RibbonTile(title: "Conversations", symbol: model.groupByThread ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right",
                       tint: model.groupByThread ? .accentColor : nil) { model.groupByThread.toggle() }
            RibbonMenuTile(title: "Message\nPreview", symbol: "text.alignleft", tint: .blue) {
                Toggle("Show Message Preview", isOn: $showPreview)
                Divider()
                Picker("Density", selection: Binding(get: { model.listDensity }, set: { model.listDensity = $0 })) {
                    ForEach(ListDensity.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            }
            RibbonMenuTile(title: "Arrange\nby", symbol: "arrow.up.arrow.down.square", tint: .blue) {
                ForEach(ListSort.allCases) { sort in
                    Button { model.listSort = sort.rawValue } label: {
                        if model.listSort == sort.rawValue { Label(sort.title, systemImage: "checkmark") } else { Text(sort.title) }
                    }
                }
                Divider()
                Button { model.sortAscending = true } label: {
                    if model.sortAscending { Label(currentSort.ascendingTitle, systemImage: "checkmark") } else { Text(currentSort.ascendingTitle) }
                }
                Button { model.sortAscending = false } label: {
                    if !model.sortAscending { Label(currentSort.descendingTitle, systemImage: "checkmark") } else { Text(currentSort.descendingTitle) }
                }
                Divider()
                Button { model.showInGroups.toggle() } label: {
                    if model.showInGroups { Label("Show in Groups", systemImage: "checkmark") } else { Text("Show in Groups") }
                }
                Divider()
                Button("Restore to Defaults") { model.restoreListDefaults() }
            }
            RibbonMenuTile(title: "Reading\nPane", symbol: ReadingPanePosition(rawValue: readingPane)?.symbol ?? "rectangle.righthalf.inset.filled", tint: .blue) {
                Picker("Reading Pane", selection: $readingPane) {
                    ForEach(ReadingPanePosition.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
            }
            RibbonSeparator()

            RibbonTile(title: "Mark All\nas Read", symbol: "envelope.open", enabled: model.unifiedUnreadCount > 0) { model.markAllReadEverywhere() }
            RibbonMenuTile(title: "Rules", symbol: "envelope.open.badge.clock") {
                Button("Run Rules Now") { model.runRulesNow() }
                Button("Edit Rules…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
            }
            RibbonTile(title: "Delete\nAll", symbol: "trash.slash", tint: .red, enabled: model.canEmptyCurrentFolder) { model.emptyCurrentFolder() }
            RibbonSeparator()

            RibbonTile(title: "Sync\nFolder", symbol: "arrow.clockwise.circle", tint: .green, enabled: !model.accounts.isEmpty) { model.syncNow() }
        }
    }
}

struct ToolsRibbon: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.offlineMode) private var offline = false

    var body: some View {
        RibbonBody {
            RibbonTile(title: "Accounts", symbol: "person.crop.square") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
            RibbonTile(title: "Out of\nOffice", symbol: "arrow.left.square", enabled: false) {}
            RibbonTile(title: "Public\nFolders", symbol: "folder.badge.person.crop", enabled: false) {}
            RibbonSeparator()

            RibbonTile(title: "Import", symbol: "square.and.arrow.down.on.square", tint: .blue) {
                NotificationCenter.default.post(name: .falconImport, object: nil)
            }
            RibbonTile(title: "Export", symbol: "square.and.arrow.up.on.square", tint: .blue, enabled: !model.selectedMessageIDs.isEmpty) {
                NotificationCenter.default.post(name: .falconExport, object: nil)
            }
            RibbonSeparator()

            RibbonMenuTile(title: "Sync\nStatus", symbol: "list.bullet.rectangle", tint: .green) {
                Text(model.statusText)
                Divider()
                ForEach(model.accounts) { account in
                    Text("\(account.email) — \(model.online[account.id] == false ? "offline" : "online")")
                }
            }
            RibbonMenuTile(title: "Sync\nErrors", symbol: "exclamationmark.triangle", tint: .orange) {
                if let error = model.actionError { Text(error) } else { Text("No sync errors") }
                Divider()
                Button("Retry Now") { model.syncNow() }
            }
            RibbonSeparator()

            RibbonPill(onLabel: "Online", offLabel: "Offline", caption: "Online/Offline",
                       isOn: Binding(get: { !offline }, set: { offline = !$0; model.setWorkOffline(!$0) }))
            RibbonSeparator()

            RibbonTile(title: "Archive\nMail", symbol: "externaldrive.badge.timemachine", tint: .purple) {
                NotificationCenter.default.post(name: .falconArchive, object: nil)
            }
        }
    }
}

struct MoveMenuItems: View {
    @Environment(AppModel.self) private var model

    private var recent: [FolderInfo] {
        let scope = Set(model.selectedMessages.map(\.accountID))
        return model.folders.values.flatMap { $0 }.filter { scope.contains($0.accountID) && model.isRecentTarget($0) }.prefix(6).map { $0 }
    }

    var body: some View {
        ForEach(recent) { folder in
            Button(folder.path) { model.move(model.selectedMessages, to: folder) }
        }
        if !recent.isEmpty { Divider() }
        Button("Move to Folder…") { model.openMovePalette() }
        if let last = model.lastMoveTarget {
            Button("Move Again to \(last.name)") { model.moveToLastTarget() }
        }
        Divider()
        Button("Archive") { model.archive(model.selectedMessages) }
    }
}

struct CategoryMenuItems: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(model.categories) { category in
            Button {
                model.toggleCategory(category, on: model.selectedMessages)
            } label: {
                if model.selectionHasCategory(category) {
                    Label(category.name, systemImage: "checkmark")
                } else {
                    Text(category.name)
                }
            }
        }
        Divider()
        Button("Clear Categories") { model.clearCategories(on: model.selectedMessages) }
        Button("Edit Categories…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
    }
}

struct FilterMenuItems: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        return Group {
            Toggle("Only Unread", isOn: binding(.unread))
            Toggle("Only Flagged", isOn: binding(.flagged))
            Divider()
            Toggle("Keep Filters When Switching Folders", isOn: $model.pinFilters)
            Button("Clear Filters") { model.clearFilters() }.disabled(model.filters.isEmpty)
            Divider()
            Toggle("Group by Conversation", isOn: $model.groupByThread)
            Button("Expand All Conversations") { model.expandAll() }.disabled(!model.hasExpandableThreads)
            Button("Collapse All Conversations") { model.collapseAll() }.disabled(!model.canCollapseSomething)
        }
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
            TextField("Find a Contact or Message", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
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
        .frame(width: 190)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(focused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.12)))
        .onChange(of: model.focusSearchToken) { _, _ in focused = true }
    }
}
