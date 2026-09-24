import SwiftUI
import FalconCore

struct MessageListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Pref.focusedInbox) private var focusedInbox = false
    @AppStorage(Pref.showPreview) private var showPreview = true
    @AppStorage(Pref.showSenderImage) private var showSenderImage = true
    @AppStorage(Pref.quickActions) private var quickActionsRaw = QuickAction.defaults
    @AppStorage(Pref.leftSwipe) private var leftSwipeRaw = SwipeAction.archive.rawValue
    @AppStorage(Pref.rightSwipe) private var rightSwipeRaw = SwipeAction.none.rawValue

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
            .scrollContentBackground(.hidden)
            .background(OLColor.list)
            .background(DoubleClickMonitor { if let t = model.currentThread { model.openMessage(t.latest) { openWindow(value: $0) } } })
            .onKeyPress(.return) {
                guard let t = model.currentThread else { return .ignored }
                model.openMessage(t.latest) { openWindow(value: $0) }
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
            ConversationRow(thread: thread,
                            density: model.listDensity,
                            showPreview: showPreview,
                            showSenderImage: showSenderImage,
                            quickActions: quickActions)
                .contextMenu { rowMenu(thread) }
                .swipeActions(edge: .leading) { swipeButton(leftSwipeRaw, thread) }
                .swipeActions(edge: .trailing) { swipeButton(rightSwipeRaw, thread) }
        case .message(let message, _):
            ChildMessageRow(message: message)
                .contextMenu { rowMenu(MessageThread(messages: [message])) }
        }
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
                    .buttonStyle(.link)
                    .font(.system(size: OL.statusFont))
                if model.storedInSelection > model.messages.count {
                    Text("\(model.messages.count) of \(model.storedInSelection)")
                        .font(.system(size: OL.statusFont).monospacedDigit())
                        .foregroundStyle(OLColor.textMuted)
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
                    .buttonStyle(.link)
                    .font(.system(size: OL.statusFont))
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

struct ConversationRow: View {
    @Environment(AppModel.self) private var model
    let thread: MessageThread
    let density: ListDensity
    let showPreview: Bool
    let showSenderImage: Bool
    let quickActions: [QuickAction]
    @State private var hovering = false

    private var unread: Bool { thread.unreadCount > 0 }
    private var selected: Bool { model.selectedMessageIDs.contains(thread.id) }

    var body: some View {
        let m = thread.latest
        ZStack(alignment: .topLeading) {
            if selected {
                OLColor.listSelected
            } else {
                OLColor.list
                Rectangle()
                    .fill(OLColor.divider)
                    .frame(height: 1)
                    .padding(.horizontal, OL.listSeparatorX)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            if unread {
                Rectangle().fill(OLColor.unread).frame(width: 3).padding(.vertical, 4)
            }
            if thread.messages.count > 1 {
                Button { model.toggleExpanded(thread) } label: {
                    Image(systemName: model.isExpanded(thread) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(OLColor.text)
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, OL.listChevronX)
                .padding(.top, OL.listNameTop + 3)
                .help(model.isExpanded(thread) ? "Collapse conversation" : "Expand conversation")
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(m.from.displayName)
                        .font(.system(size: OL.listNameFont, weight: unread ? .semibold : .regular))
                        .foregroundStyle(OLColor.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if hovering {
                        quickActionRow(for: thread)
                    } else {
                        HStack(spacing: 4) {
                            ForEach(model.categories(for: m)) { category in
                                Circle().fill(category.swatch).frame(width: 8, height: 8).help(category.name)
                            }
                            if m.hasAttachments {
                                Image(systemName: "paperclip").font(.system(size: 13)).foregroundStyle(OLColor.textMuted)
                            }
                            if m.isFlagged {
                                Image(systemName: "flag.fill").font(.system(size: 12)).foregroundStyle(OLColor.flagRed)
                            }
                        }
                        .padding(.trailing, OL.listIconRight - OL.listRightInset)
                    }
                }
                .frame(height: OL.listLinePitch, alignment: .top)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(m.subject.isEmpty ? "(no subject)" : m.subject)
                        .font(.system(size: OL.listLineFont))
                        .foregroundStyle(OLColor.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(MessageRow.dateText(m.date))
                        .font(.system(size: OL.listLineFont))
                        .foregroundStyle(OLColor.textMuted)
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.top, 2)
                .frame(height: OL.listLinePitch, alignment: .top)
                if showPreview {
                    Text(m.snippet.isEmpty ? " " : m.snippet)
                        .font(.system(size: OL.listLineFont))
                        .foregroundStyle(OLColor.textMuted)
                        .lineLimit(1)
                        .padding(.top, 2)
                        .frame(height: OL.listLinePitch, alignment: .top)
                }
            }
            .padding(.leading, OL.listTextX)
            .padding(.trailing, OL.listRightInset)
            .padding(.top, OL.listNameTop - 2)
        }
        .frame(height: showPreview ? OL.listRow : OL.listRow - OL.listLinePitch)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func quickActionRow(for thread: MessageThread) -> some View {
        HStack(spacing: 6) {
            ForEach(quickActions) { action in
                Button { run(action, on: thread) } label: {
                    Image(systemName: symbol(action, thread))
                        .font(.system(size: 12))
                        .foregroundStyle(OLColor.textMuted)
                        .frame(width: 18, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(action.title))
            }
        }
        .disabled(!MessageActions.allowsChanges(thread.messages))
        .padding(.trailing, OL.listIconRight - OL.listRightInset)
    }

    private func symbol(_ action: QuickAction, _ thread: MessageThread) -> String {
        switch action {
        case .markRead: return thread.latest.isRead ? "envelope.badge" : "envelope.open"
        case .flag: return thread.latest.isFlagged ? "flag.slash" : "flag"
        default: return action.symbol
        }
    }

    private func run(_ action: QuickAction, on thread: MessageThread) {
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

/// One message of an expanded conversation: the same three lines, set in from the left.
struct ChildMessageRow: View {
    @Environment(AppModel.self) private var model
    let message: MessageSummary

    private var selected: Bool { model.selectedMessageIDs.contains(message.id) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if selected {
                OLColor.listSelected
            } else {
                OLColor.list
                Rectangle()
                    .fill(OLColor.divider)
                    .frame(height: 1)
                    .padding(.horizontal, OL.listSeparatorX)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            if !message.isRead {
                Rectangle().fill(OLColor.unread).frame(width: 3).padding(.vertical, 4)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(message.from.displayName)
                        .font(.system(size: OL.listNameFont, weight: message.isRead ? .regular : .semibold))
                        .foregroundStyle(OLColor.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    HStack(spacing: 4) {
                        if message.hasAttachments { Image(systemName: "paperclip").font(.system(size: 13)).foregroundStyle(OLColor.textMuted) }
                        if message.isFlagged { Image(systemName: "flag.fill").font(.system(size: 12)).foregroundStyle(OLColor.flagRed) }
                    }
                    .padding(.trailing, OL.listIconRight - OL.listRightInset)
                }
                .frame(height: OL.listLinePitch, alignment: .top)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                        .font(.system(size: OL.listLineFont))
                        .foregroundStyle(OLColor.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(MessageRow.dateText(message.date))
                        .font(.system(size: OL.listLineFont))
                        .foregroundStyle(OLColor.textMuted)
                        .fixedSize()
                }
                .padding(.top, 2)
                .frame(height: OL.listLinePitch, alignment: .top)
                Text(message.snippet.isEmpty ? " " : message.snippet)
                    .font(.system(size: OL.listLineFont))
                    .foregroundStyle(OLColor.textMuted)
                    .lineLimit(1)
                    .padding(.top, 2)
                    .frame(height: OL.listLinePitch, alignment: .top)
            }
            .padding(.leading, OL.listTextX + 20)
            .padding(.trailing, OL.listRightInset)
            .padding(.top, OL.listNameTop - 2)
        }
        .frame(height: OL.listRow)
        .contentShape(Rectangle())
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

enum MessageRow {
    static let timeFormatter: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f }()
    static let dayFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE"; return f }()
    static let dateFormatter: DateFormatter = { let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .none; return f }()

    static func dateText(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return timeFormatter.string(from: date) }
        if let week = cal.date(byAdding: .day, value: -6, to: Date()), date > week { return dayFormatter.string(from: date) }
        return dateFormatter.string(from: date)
    }
}
