import SwiftUI
import Combine
import FalconCore

struct MessageListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Pref.focusedInbox) private var focusedInbox = false
    @AppStorage(Pref.showPreview) private var showPreview = true
    @AppStorage(Pref.quickActions) private var quickActionsRaw = QuickAction.defaults
    @AppStorage(Pref.leftSwipe) private var leftSwipeRaw = SwipeAction.archive.rawValue
    @AppStorage(Pref.rightSwipe) private var rightSwipeRaw = SwipeAction.none.rawValue
    @Environment(\.controlActiveState) private var activeState
    @FocusState private var listFocused: Bool
    /// Moved on at midnight, and on waking, so that the rows are written again and today's
    /// times become Yesterday without waiting for new mail. The rows read the clock themselves.
    @State private var today = Date()

    #if DEBUG
    /// Set by the offscreen snapshots, whose window never has the keyboard.
    static var snapshotListHasKeyboard: Bool?
    #endif

    /// Outlook's selection is blue while the list has the keyboard in the window in front, and
    /// grey otherwise.
    private var listHasKeyboard: Bool {
        #if DEBUG
        if let forced = MessageListView.snapshotListHasKeyboard { return forced }
        #endif
        return listFocused && activeState == .key
    }

    private var quickActions: [QuickAction] {
        quickActionsRaw.split(separator: ",").compactMap { QuickAction(rawValue: String($0)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            listHeader
            focusedTabs
            filterBar
            if model.isSearching {
                ProgressView("Searching…").padding()
            }
            searchNoticeBar
            rowList
            loadOlderBar
            moreResultsBar
        }
        .background(OLColor.list)
        .onChange(of: model.selectedMessageIDs) { _, _ in model.selectionDidChange() }
    }

    @ViewBuilder private var focusedTabs: some View {
        if focusedInbox && model.showsMessageList {
            Picker("", selection: Binding(get: { model.focusedTab }, set: { model.focusedTab = $0; Task { await model.reloadMessages() } })) {
                ForEach(FocusedTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }

    /// Outlook's list header: "By: Conversations ˅" and the direction arrow, right-aligned in a
    /// forty-three point band. The folder's name is in the window title, not here.
    private var listHeader: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 0)
            sortMenu
            Button { model.sortAscending.toggle() } label: {
                Image(systemName: model.sortAscending ? "arrow.up" : "arrow.down")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(OLColor.text)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.sortAscending ? "Oldest first" : "Newest first")
        }
        .padding(.trailing, OL.listHeaderRightInset)
        .frame(height: OL.listHeader)
        // Outlook's line under the header, a point thick, with the first row five points below.
        .overlay(alignment: .bottom) {
            Rectangle().fill(OLColor.divider).frame(height: 1).padding(.bottom, OL.listTopInset)
        }
        .help(model.storedInSelection > model.messages.count
              ? "Showing the newest \(model.messages.count) of \(model.storedInSelection) messages"
              : "\(model.threads.count) conversations")
    }

    private var currentSort: ListSort { ListSort(rawValue: model.listSort) ?? .date }

    private var arrangementTitle: Text {
        model.groupByThread ? Text("Conversations") : Text(currentSort.title)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(ListSort.allCases) { sort in
                Button { model.listSort = sort.rawValue } label: {
                    if model.listSort == sort.rawValue { Label(sort.title, systemImage: "checkmark") } else { Text(sort.title) }
                }
            }
            Divider()
            Button { model.groupByThread.toggle() } label: {
                if model.groupByThread { Label("Conversations", systemImage: "checkmark") } else { Text("Conversations") }
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
        } label: {
            HStack(spacing: 4) {
                (Text("By: ") + arrangementTitle)
                    .font(.system(size: OL.listHeaderFont))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(OLColor.text)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort order")
    }

    private var densityMenu: some View {
        Menu {
            Picker("Density", selection: Binding(get: { model.listDensity }, set: { model.listDensity = $0 })) {
                ForEach(ListDensity.allCases) { d in Text(d.title).tag(d) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "line.3.horizontal").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Row density")
    }

    @ViewBuilder private var filterBar: some View {
        if !model.filters.isEmpty {
            HStack(spacing: 6) {
                ForEach(MessageFilter.allCases.filter { model.filters.contains($0) }) { filter in
                    filterChip(filter)
                }
                Spacer()
                pinButton
                Button("Clear") { model.clearFilters() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private func filterChip(_ filter: MessageFilter) -> some View {
        HStack(spacing: 4) {
            Image(systemName: filter.symbol)
            Text(filter.title)
            Button { model.toggleFilter(filter) } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .help("Remove this filter")
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.15), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.4)))
    }

    private var pinButton: some View {
        Button { model.pinFilters.toggle() } label: {
            Image(systemName: model.pinFilters ? "pin.fill" : "pin.slash")
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.pinFilters ? Color.accentColor : Color.secondary)
        .help("Keep these filters when switching folders")
    }

    private var rowList: some View {
        @Bindable var model = model
        return ScrollViewReader { proxy in
            List(model.rows, selection: $model.selectedMessageIDs) { row in
                rowView(row)
                    .tag(row.id)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 1)
            .scrollContentBackground(.hidden)
            .background(OLColor.list)
            .focused($listFocused)
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in
                today = Date()
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                today = Date()
            }
            .background(ListTableTuner())
            .background(DoubleClickMonitor { if let t = model.currentThread { model.openMessage(t.latest, conversation: t) { openWindow(value: $0) } } })
            .onKeyPress(.return) {
                guard let t = model.currentThread else { return .ignored }
                model.openMessage(t.latest, conversation: t) { openWindow(value: $0) }
                return .handled
            }
            .onKeyPress(.rightArrow) { model.expandCurrent() ? .handled : .ignored }
            .onKeyPress(.leftArrow) { model.collapseCurrent() ? .handled : .ignored }
            .overlay {
                if model.threads.isEmpty && !model.isSearching {
                    ContentUnavailableView(emptyTitle, systemImage: model.filters.isEmpty ? "tray" : "line.3.horizontal.decrease.circle")
                }
            }
            .onChange(of: model.selectedMessageIDs) { _, ids in
                guard ids.count == 1, let id = ids.first else { return }
                proxy.scrollTo(id)
            }
        }
    }

    @ViewBuilder private func rowView(_ row: ListRow) -> some View {
        rowContent(row)
            .onAppear { if row.id == model.rows.last?.id { model.loadMoreSearchResults() } }
    }

    @ViewBuilder private func rowContent(_ row: ListRow) -> some View {
        switch row {
        case .group(let title):
            Text(title)
                .font(.system(size: OL.listLineFont, weight: .semibold))
                .foregroundStyle(OLColor.text)
                .padding(.leading, OL.listSeparatorX)
                .frame(height: 26, alignment: .bottomLeading)
                .padding(.bottom, 4)
                .selectionDisabled()
        case .thread(let thread):
            ConversationRow(thread: thread, showPreview: showPreview, listHasKeyboard: listHasKeyboard,
                            namesRecipients: namesRecipients, quickActions: quickActions, today: today)
                .contextMenu { rowMenu(thread) }
                .swipeActions(edge: .leading) { swipeButton(leftSwipeRaw, thread) }
                .swipeActions(edge: .trailing) { swipeButton(rightSwipeRaw, thread) }
        case .message(let message, let threadID):
            ChildMessageRow(message: message, last: isLastChild(message, of: threadID), listHasKeyboard: listHasKeyboard,
                            namesRecipients: namesRecipients, today: today)
                .contextMenu { rowMenu(MessageThread(messages: [message])) }
        }
    }

    /// The conversation's oldest message, whose row closes it with a full line underneath.
    private func isLastChild(_ message: MessageSummary, of threadID: String) -> Bool {
        guard case .thread(let thread) = model.rowIndex[threadID] else { return false }
        return thread.messages.last?.id == message.id
    }

    @ViewBuilder private func swipeButton(_ raw: String, _ thread: MessageThread) -> some View {
        let action = SwipeAction(rawValue: raw) ?? .none
        if action != .none, MessageActions.allowsChanges(thread.messages) {
            Button {
                switch action {
                case .archive: model.archive(thread.messages)
                case .delete: model.delete(thread.messages)
                case .markRead: model.markRead(thread.messages, !thread.latest.isRead)
                case .flag: model.setFlagged(thread.messages, !thread.latest.isFlagged)
                case .move: model.openMovePalette()
                case .junk: model.toggleJunk(thread.messages)
                case .none: break
                }
            } label: {
                Label(action.title, systemImage: action.symbol)
            }
            .tint(action == .delete ? .red : (action == .flag ? .orange : .accentColor))
        }
    }

    private var emptyTitle: LocalizedStringKey {
        if model.accounts.isEmpty { return "Add an account to get started" }
        return model.filters.isEmpty ? "No messages" : "No conversations match these filters"
    }

    @ViewBuilder private var loadOlderBar: some View {
        if model.searchText.isEmpty, model.canShowMore || isFolder {
            Rectangle().fill(OLColor.divider).frame(height: 1)
            HStack(spacing: 8) {
                Button(model.canShowMore ? "Show more" : "Load older messages") { model.loadOlder() }
                    .buttonStyle(QuietLinkStyle())
                if model.storedInSelection > model.messages.count {
                    Text("\(model.messages.count) of \(model.storedInSelection)")
                        .font(.system(size: OL.statusFont).monospacedDigit())
                        .foregroundStyle(OLColor.textDim)
                }
            }
            .padding(6)
        }
    }

    /// Why some results come from this Mac instead of Gmail: one sentence, wrapping once in a
    /// narrow list rather than losing its end.
    @ViewBuilder private var searchNoticeBar: some View {
        if let notice = model.searchNotice {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "info.circle")
                Text(notice).lineLimit(2).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: OL.statusFont))
            .foregroundStyle(OLColor.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .help(notice)
        }
    }

    /// Search results come a page at a time; the next page also loads when the last row scrolls in.
    @ViewBuilder private var moreResultsBar: some View {
        if !model.searchText.isEmpty, model.searchHasMore || model.isLoadingMoreResults {
            Rectangle().fill(OLColor.divider).frame(height: 1)
            HStack(spacing: 8) {
                Button("Show more") { model.loadMoreSearchResults() }
                    .buttonStyle(QuietLinkStyle())
                    .disabled(model.isLoadingMoreResults)
                if model.isLoadingMoreResults { ProgressView().controlSize(.small) }
            }
            .padding(6)
        }
    }

    private var isFolder: Bool {
        if case .folder = model.selection { return true }
        return false
    }

    /// Sent and Drafts name who the mail went to, as Outlook's do: their sender is always the
    /// owner.
    private var namesRecipients: Bool {
        guard case .folder(let id) = model.selection, let role = model.folder(id)?.role else { return false }
        return role == .sent || role == .drafts
    }

    @ViewBuilder private func rowMenu(_ thread: MessageThread) -> some View {
        Button("Open") { model.openMessage(thread.latest) { openWindow(value: $0) } }
        Button("Open in Separate Window") { model.openMessage(thread.latest, forceWindow: true) { openWindow(value: $0) } }
        if thread.messages.count > 1 {
            Button(model.isExpanded(thread) ? "Collapse Conversation" : "Expand Conversation") { model.toggleExpanded(thread) }
        }
        Divider()
        Group {
            Button(thread.latest.isRead ? "Mark as Unread" : "Mark as Read") { model.markRead(thread.messages, !thread.latest.isRead) }
            Button(thread.latest.isFlagged ? "Unflag" : "Flag") { model.setFlagged(thread.messages, !thread.latest.isFlagged) }
            Button("Archive") { model.archive(thread.messages) }
            Button(model.isInJunk(thread.messages) ? "Not Junk" : "Move to Junk") { model.toggleJunk(thread.messages) }
            Button(model.isMuted(thread) ? "Unmute Conversation" : "Mute Conversation") { model.toggleMute(thread) }
            Button("Delete", role: .destructive) { model.delete(thread.messages) }
        }
        .disabled(!MessageActions.allowsChanges(thread.messages))
    }
}

/// Outlook's list has no such button, so it stays out of the way: grey, not link blue, and
/// underlined only under the pointer.
private struct QuietLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { QuietLabel(configuration: configuration) }

    private struct QuietLabel: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: OL.statusFont))
                .underline(hovering)
                .foregroundStyle(OLColor.textMuted)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// A conversation's own row, or a lone message's: the drawn row, with the chevron's button over
/// its left end and, while the pointer is on it, the quick actions over its icons.
struct ConversationRow: View {
    @Environment(AppModel.self) private var model
    let thread: MessageThread
    let showPreview: Bool
    let listHasKeyboard: Bool
    let namesRecipients: Bool
    let quickActions: [QuickAction]
    /// Only here so that the row is written again when the day moves on; see `MessageListView.today`.
    let today: Date
    @State private var pointerInside = false

    #if DEBUG
    /// The conversation the offscreen snapshots draw as if the pointer were on it.
    static var snapshotHoveredID: String?
    #endif

    private var hovering: Bool {
        #if DEBUG
        if ConversationRow.snapshotHoveredID == thread.id { return true }
        #endif
        return pointerInside
    }

    var body: some View {
        let selected = model.selectedMessageIDs.contains(thread.id)
        let categories = model.categories(for: thread.latest)
        let row = MessageRowModel.conversation(
            thread, expanded: model.isExpanded(thread), showsPreview: showPreview,
            selection: selected ? (listHasKeyboard ? .focused : .unfocused) : .none, namesRecipients: namesRecipients,
            categories: categories.isEmpty ? [] : categories.map { NSColor($0.swatch) },
            actionsWidth: hovering ? Self.actionsWidth(quickActions.count) : 0,
            // The clock, not `today`: a night asleep may bring no notice that the day changed, and
            // today's mail must not then read as older.
            now: Date())
        ZStack(alignment: .topLeading) {
            MessageRowCell(model: row).allowsHitTesting(false)
            // Takes the row's clicks, menu and hover over the drawn row, which takes none.
            Color.clear.contentShape(Rectangle())
            if thread.messages.count > 1 {
                Button { model.toggleExpanded(thread) } label: {
                    Color.clear.frame(width: 26, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.isExpanded(thread) ? "Collapse conversation" : "Expand conversation")
                // The chevron is drawn by the row, so the button has no image for VoiceOver to name.
                .accessibilityLabel(model.isExpanded(thread) ? "Collapse conversation" : "Expand conversation")
            }
            if hovering, !quickActions.isEmpty {
                quickActionRow
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, OL.listIconRight)
                    .padding(.top, OL.listBadgeTop - 1)
            }
        }
        .frame(height: row.height)
        .onHover { pointerInside = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.spoken(row))
    }

    /// What VoiceOver reads for a row that is drawn rather than made of text views.
    static func spoken(_ row: MessageRowModel) -> String {
        var parts = [row.sender]
        if !row.subject.isEmpty { parts.append(row.subject) }
        parts.append(row.date)
        if row.isUnread { parts.append("unread") }
        if row.hasAttachments { parts.append("has attachments") }
        if row.isFlagged { parts.append("flagged") }
        if let preview = row.preview, !preview.isEmpty { parts.append(preview) }
        return parts.joined(separator: ", ")
    }

    private static let actionButton = CGSize(width: 18, height: 16)
    private static let actionSpacing: CGFloat = 6

    private static func actionsWidth(_ count: Int) -> CGFloat {
        count == 0 ? 0 : CGFloat(count) * actionButton.width + CGFloat(count - 1) * actionSpacing
    }

    private var quickActionRow: some View {
        HStack(spacing: Self.actionSpacing) {
            ForEach(quickActions) { action in
                Button { run(action) } label: {
                    Image(systemName: symbol(action))
                        .font(.system(size: 12))
                        .foregroundStyle(OLColor.textMuted)
                        .frame(width: Self.actionButton.width, height: Self.actionButton.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(action.title))
            }
        }
        .disabled(!MessageActions.allowsChanges(thread.messages))
    }

    private func symbol(_ action: QuickAction) -> String {
        switch action {
        case .markRead: return thread.latest.isRead ? "envelope.badge" : "envelope.open"
        case .flag: return thread.latest.isFlagged ? "flag.slash" : "flag"
        default: return action.symbol
        }
    }

    private func run(_ action: QuickAction) {
        switch action {
        case .delete: model.delete(thread.messages)
        case .archive: model.archive(thread.messages)
        case .flag: model.setFlagged(thread.messages, !thread.latest.isFlagged)
        case .move: model.openMovePalette()
        case .markRead: model.markRead(thread.messages, !thread.latest.isRead)
        case .snooze: model.mute([thread])
        }
    }
}

/// One message of an expanded conversation, on one short line under it as in Outlook: who sent
/// it and when, set in from the left.
struct ChildMessageRow: View {
    @Environment(AppModel.self) private var model
    let message: MessageSummary
    /// The conversation's oldest, the last of its rows.
    let last: Bool
    let listHasKeyboard: Bool
    let namesRecipients: Bool
    /// Only here so that the row is written again when the day moves on.
    let today: Date

    var body: some View {
        let selected = model.selectedMessageIDs.contains(ListRow.childTag(message.id))
        let row = MessageRowModel.child(message, last: last,
                                        selection: selected ? (listHasKeyboard ? .focused : .unfocused) : .none,
                                        namesRecipients: namesRecipients, now: Date())
        ZStack {
            MessageRowCell(model: row).allowsHitTesting(false)
            Color.clear.contentShape(Rectangle())
        }
        .frame(height: row.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ConversationRow.spoken(row))
    }
}

struct AvatarView: View {
    let name: String
    let address: String
    let size: CGFloat

    private static let palette: [Color] = [
        Color(red: 0.20, green: 0.47, blue: 0.96), Color(red: 0.86, green: 0.30, blue: 0.36), Color(red: 0.16, green: 0.63, blue: 0.47),
        Color(red: 0.93, green: 0.55, blue: 0.14), Color(red: 0.55, green: 0.36, blue: 0.86), Color(red: 0.13, green: 0.61, blue: 0.75),
        Color(red: 0.76, green: 0.40, blue: 0.18), Color(red: 0.42, green: 0.53, blue: 0.20)
    ]

    private var initials: String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        let letters = words.prefix(2).compactMap { $0.first }.map { String($0).uppercased() }
        if !letters.isEmpty { return letters.joined() }
        return String((address.first.map { String($0) } ?? "?").uppercased())
    }

    static func color(for key: String) -> Color {
        var hash: UInt32 = 5381
        for b in key.lowercased().utf8 { hash = hash &* 33 &+ UInt32(b) }
        return palette[Int(hash % UInt32(palette.count))]
    }

    private var color: Color { AvatarView.color(for: address) }

    var body: some View {
        Circle()
            .fill(color.opacity(0.85))
            .frame(width: size, height: size)
            .overlay(Text(initials).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white))
    }
}
