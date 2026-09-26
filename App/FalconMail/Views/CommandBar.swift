import SwiftUI
import AppKit
import FalconCore

enum AppRibbonTab: String, CaseIterable {
    /// Organise's tools are all on Home now; a stored "organise" opens Home.
    case home, tools

    var title: String {
        switch self {
        case .home: return "Home"
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
            titleRow
            Group {
                switch tab.wrappedValue {
                case .home: HomeRibbon()
                case .tools: ToolsRibbon()
                }
            }
            Rectangle().fill(OLColor.chromeLine).frame(height: 1)
        }
        .background(OLColor.chrome)
    }

    /// The window's own title row: quick actions after the traffic lights, the folder and
    /// account in the middle, search at the right.
    private var titleRow: some View {
        ZStack {
            Text(model.windowTitle)
                .font(.system(size: OL.titleFont))
                .foregroundStyle(OLColor.title)
                .lineLimit(1)
            HStack(spacing: OL.quickPitch - 20) {
                RibbonQuickButton(symbol: "square.and.arrow.down", title: "Save all drafts") { model.saveLeftoverDrafts() }
                RibbonQuickButton(symbol: "arrow.uturn.backward", title: "Undo", enabled: model.canUndoAction) { model.undoLastAction() }
                RibbonQuickButton(symbol: "arrow.uturn.forward", title: "Redo", enabled: false) {}
                RibbonQuickButton(symbol: "envelope.badge.shield.half.filled", title: "Mark all as read", enabled: model.unifiedUnreadCount > 0) {
                    model.markAllReadEverywhere()
                }
                RibbonTabSwitch(tabs: AppRibbonTab.allCases.map { ($0, $0.title) }, selection: tab)
                    .padding(.leading, 14)
                Spacer()
                TitleSearchField()
            }
            .padding(.leading, OL.quickIconsStart)
            .padding(.trailing, OL.searchRightInset)
        }
        .frame(height: OL.titleRow)
    }
}

struct HomeRibbon: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.offlineMode) private var offline = false

    /// Actions need a selection with nothing in it that was found only on the server.
    private var canChange: Bool { model.hasSelection && !model.selectionIsReadOnly }

    /// A command that changes mail, where the folder shown allows it: on a Google account on the
    /// Gmail API, by Gmail's rules, so Archive is not offered in Sent or Drafts, nor Move in Drafts.
    private func can(_ verb: MailActionRequest.Verb) -> Bool { canChange && model.allowsCommand(verb) }

    var body: some View {
        let thread = model.currentThread
        let hasSingle = thread != nil
        let first = thread?.latest
        return RibbonBody {
            RibbonGroup {
                RibbonTile(title: "Delete", symbol: "trash", enabled: can(.delete)) {
                    model.onSelection(.delete) { model.delete(model.selectedMessages) }
                }
                RibbonTile(title: "Archive", symbol: "archivebox", tint: OLColor.archiveGreen, enabled: can(.archive)) {
                    model.onSelection(.archive) { model.archive(model.selectedMessages) }
                }
            }
            RibbonGroup {
                RibbonSplitTile(title: "Move", symbol: "arrow.down.to.line.compact", tint: OLColor.forwardBlue, enabled: can(.move(to: UUID())),
                                action: { model.onSelection(.move) { model.openMovePalette() } }) {
                    MoveMenuItems()
                }
                RibbonSplitTile(title: "Junk", symbol: "person.crop.circle.badge.xmark", tint: OLColor.junkRed,
                                enabled: can(model.selectionIsAllInJunk ? .notJunk : .junk),
                                action: { model.onSelection(.junk) { model.toggleJunkOnSelection() } }) {
                    Button(model.selectionIsAllInJunk ? "Not Junk" : "Move to Junk") { model.onSelection(.junk) { model.toggleJunkOnSelection() } }
                    Button("Mute Conversation") { model.onSelection(.mute) { model.muteSelection() } }
                        .disabled(!model.allowsCommand(.mute))
                }
                RibbonMenuTile(title: "Rules", symbol: "envelope.open.badge.clock") {
                    Button("Run Rules Now") { model.runRulesNow() }
                    Button("Edit Rules…") { SettingsWindows.shared.show(.rules) }
                }
            }
            RibbonGroup {
                RibbonTile(title: "Read/Unread", symbol: ReadMarking.readUnreadMarksRead(model.selectedMessages) ? "envelope.open" : "envelope",
                           enabled: can(.markRead)) { model.onSelection(.markRead) { model.toggleReadOnSelection() } }
                RibbonMenuTile(title: "Labels", symbol: "tag", enabled: canChange && model.canLabelSelection) {
                    LabelMenuItems()
                }
                RibbonSplitTile(title: "Follow\nUp", symbol: "flag", tint: OLColor.flagRed, enabled: can(.flag),
                                action: { model.onSelection(.flag) { model.toggleFlagOnSelection() } }) {
                    Button(first?.isFlagged == true ? "Clear Flag" : "Flag Message") { model.onSelection(.flag) { model.toggleFlagOnSelection() } }
                }
                RibbonTile(title: "Mark All\nas Read", symbol: "envelope.open", enabled: model.unifiedUnreadCount > 0) { model.markAllReadEverywhere() }
            }
            RibbonGroup {
                ListViewTiles()
            }
            RibbonGroup {
                RibbonMenuTile(title: "Filter", symbol: model.filters.isEmpty ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill") {
                    FilterMenuItems()
                }
                RibbonTile(title: "Dark /\nLight", symbol: "circle.lefthalf.filled") { model.cycleAppearance() }
            }
            RibbonGroup {
                RibbonPill(onLabel: "Online", offLabel: "Offline", caption: "Status",
                           isOn: Binding(get: { !offline }, set: { offline = !$0; model.setWorkOffline(!$0) }))
                RibbonTile(title: "Send &\nReceive", symbol: "arrow.triangle.2.circlepath", tint: OLColor.sendGreen, enabled: !model.accounts.isEmpty) { model.checkForNewMail() }
            }
        }
    }
}

/// How the list is shown: Preview and Reading Pane. Arrange by and Conversations are over the list.
struct ListViewTiles: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.readingPane) private var readingPane = ReadingPanePosition.right.rawValue
    @AppStorage(Pref.showPreview) private var showPreview = true

    var body: some View {
        @Bindable var model = model
        return Group {
                RibbonMenuTile(title: "Preview", symbol: "text.alignleft", tint: .blue) {
                    Toggle("Show Message Preview", isOn: $showPreview)
                    Divider()
                    Picker("Density", selection: Binding(get: { model.listDensity }, set: { model.listDensity = $0 })) {
                        ForEach(ListDensity.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
                RibbonMenuTile(title: "Reading\nPane", symbol: ReadingPanePosition(rawValue: readingPane)?.symbol ?? "rectangle.righthalf.inset.filled", tint: .blue) {
                    Picker("Reading Pane", selection: $readingPane) {
                        ForEach(ReadingPanePosition.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.inline)
                }
        }
    }
}

struct ToolsRibbon: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.offlineMode) private var offline = false

    var body: some View {
        RibbonBody {
            RibbonGroup {
                RibbonTile(title: "Accounts", symbol: "person.crop.square") { SettingsWindows.shared.show(.accounts) }
                RibbonTile(title: "Out of\nOffice", symbol: "arrow.left.square", enabled: false) {}
                RibbonTile(title: "Public\nFolders", symbol: "folder.badge.person.crop", enabled: false) {}
            }
            RibbonGroup {
                RibbonTile(title: "Import", symbol: "square.and.arrow.down.on.square", tint: .blue) {
                    NotificationCenter.default.post(name: .falconImport, object: nil)
                }
                RibbonTile(title: "Export", symbol: "square.and.arrow.up.on.square", tint: .blue, enabled: model.hasSelection) {
                    NotificationCenter.default.post(name: .falconExport, object: nil)
                }
            }
            RibbonGroup {
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
            }
            RibbonGroup {
                RibbonTile(title: "Archive\nMail", symbol: "externaldrive.badge.timemachine", tint: .purple) {
                    NotificationCenter.default.post(name: .falconArchive, object: nil)
                }
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
            // A Google account's folders by the name the sidebar gives them, such as Sent, never
            // Gmail's own path, such as [Gmail]/Sent Mail.
            Button(model.isGmailEngineFolder(folder) ? folder.name : folder.path) {
                model.onSelection(.move) { model.move(model.selectedMessages, to: folder) }
            }
        }
        if !recent.isEmpty { Divider() }
        Button("Move to Folder…") { model.openMovePalette() }
        if let last = model.lastMoveTarget {
            Button("Move Again to \(last.name)") { model.afterSelectionRead { model.moveToLastTarget() } }
        }
        Divider()
        Button("Archive") { model.afterSelectionRead { model.archive(model.selectedMessages) } }
    }
}

/// Labels on the ribbon: Gmail's own labels of the selected messages' account, each adding
/// that label, as Gmail's Label as does; New Label… makes one.
struct LabelMenuItems: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let labels = model.labelsForSelection
        if labels.isEmpty {
            Text("No labels yet")
        } else {
            ForEach(labels) { folder in
                Button(folder.path) { model.onSelection(.copy) { model.addLabel(folder, to: model.selectedMessages) } }
            }
        }
        Divider()
        Button("New Label…") { model.promptForNewFolder() }
    }
}

struct CategoryMenuItems: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(model.categories) { category in
            Button {
                model.afterSelectionRead { model.toggleCategory(category, on: model.selectedMessages) }
            } label: {
                if model.selectionHasCategory(category) {
                    Label(category.name, systemImage: "checkmark")
                } else {
                    Text(category.name)
                }
            }
        }
        Divider()
        Button("Clear Categories") { model.afterSelectionRead { model.clearCategories(on: model.selectedMessages) } }
        Button("Edit Categories…") { SettingsWindows.shared.show(.categories) }
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
            if model.engineList.isShown {
                // A folder of 200,000 messages is never opened out all at once; each conversation
                // opens by its chevron or the right arrow.
                Button("Collapse All Conversations") { Task { await model.engineList.controller.collapseAll() } }
                    .disabled(!model.engineList.controller.hasExpanded)
            } else {
                Button("Expand All Conversations") { model.expandAll() }.disabled(!model.hasExpandableThreads)
                Button("Collapse All Conversations") { model.collapseAll() }.disabled(!model.canCollapseSomething)
            }
        }
    }

    private func binding(_ filter: MessageFilter) -> Binding<Bool> {
        Binding(get: { model.filters.contains(filter) }, set: { _ in model.toggleFilter(filter) })
    }
}

/// The search box in the title row, where Outlook keeps it.
struct TitleSearchField: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        return HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(OLColor.fieldText)
            TextField("Search", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
                .onSubmit { Task { await model.runSearch() } }
                .onExitCommand {
                    model.clearSearch()
                    focused = false
                }
            if !model.searchText.isEmpty {
                Button { model.clearSearch() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(OLColor.fieldText) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .frame(width: OL.searchWidth, height: OL.searchHeight)
        .background(OLColor.field, in: RoundedRectangle(cornerRadius: 4))
        .onChange(of: model.focusSearchToken) { _, _ in focused = true }
    }
}

/// "Find a Contact", the small field in the Home ribbon above Address Book.
struct FindContactField: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""

    var body: some View {
        HStack(spacing: 4) {
            TextField("Find a Contact", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .onSubmit { model.showModule(.people) }
        }
        .padding(.horizontal, 6)
        .frame(width: OL.findFieldWidth, height: OL.findFieldHeight)
        .background(OLColor.ribbonField, in: RoundedRectangle(cornerRadius: 3))
        .padding(.top, 1)
    }
}
