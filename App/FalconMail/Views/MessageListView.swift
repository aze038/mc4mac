import SwiftUI
import FalconCore

struct MessageListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            listHeader
            filterBar
            Divider()
            if model.isSearching {
                ProgressView("Searching…").padding()
            }
            rowList
            loadOlderBar
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: model.selectedMessageIDs) { _, _ in model.selectionDidChange() }
    }

    private var listHeader: some View {
        HStack(spacing: 8) {
            Text(model.listTitle).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            Text("\(model.threads.count)").font(.caption).foregroundStyle(.secondary)
                .help("Conversations shown")
            Spacer()
            sortMenu
            densityMenu
            if model.hasExpandableThreads {
                Button { model.canCollapseSomething ? model.collapseAll() : model.expandAll() } label: {
                    Image(systemName: model.canCollapseSomething ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(model.canCollapseSomething ? "Collapse all conversations" : "Expand all conversations")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var currentSort: ListSort { ListSort(rawValue: model.listSort) ?? .date }

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
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 10))
                Text(currentSort.title).font(.caption)
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
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
                    .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 8))
            }
            .listStyle(.inset)
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
        switch row {
        case .group(let title):
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.top, 10).padding(.bottom, 2)
                .selectionDisabled()
        case .thread(let thread):
            ConversationRow(thread: thread)
                .contextMenu { rowMenu(thread) }
        case .message(let message, _):
            ChildMessageRow(message: message)
                .contextMenu { rowMenu(MessageThread(messages: [message])) }
        }
    }

    private var emptyTitle: LocalizedStringKey {
        if model.accounts.isEmpty { return "Add an account to get started" }
        return model.filters.isEmpty ? "No messages" : "No conversations match these filters"
    }

    @ViewBuilder private var loadOlderBar: some View {
        if case .folder = model.selection, model.searchText.isEmpty {
            Divider()
            Button("Load older messages") { model.loadOlder() }.buttonStyle(.link).padding(6)
        }
    }

    @ViewBuilder private func rowMenu(_ thread: MessageThread) -> some View {
        Button("Open") { model.openMessage(thread.latest) { openWindow(value: $0) } }
        Button("Open in Separate Window") { model.openMessage(thread.latest, forceWindow: true) { openWindow(value: $0) } }
        if thread.messages.count > 1 {
            Button(model.isExpanded(thread) ? "Collapse Conversation" : "Expand Conversation") { model.toggleExpanded(thread) }
        }
        Divider()
        Button(thread.latest.isRead ? "Mark as Unread" : "Mark as Read") { model.markRead(thread.messages, !thread.latest.isRead) }
        Button(thread.latest.isFlagged ? "Unflag" : "Flag") { model.setFlagged(thread.messages, !thread.latest.isFlagged) }
        Button("Archive") { model.archive(thread.messages) }
        Button(model.isInJunk(thread.messages) ? "Not Junk" : "Move to Junk") { model.toggleJunk(thread.messages) }
        Button(model.isMuted(thread) ? "Unmute Conversation" : "Mute Conversation") { model.toggleMute(thread) }
        Button("Delete", role: .destructive) { model.delete(thread.messages) }
    }
}

struct ConversationRow: View {
    @Environment(AppModel.self) private var model
    let thread: MessageThread

    private var unread: Bool { thread.unreadCount > 0 }

    @Environment(AppModel.self) private var listModel

    var body: some View {
        let m = thread.latest
        let compact = listModel.listDensity == .compact
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(unread ? Color.accentColor : Color.clear)
                .frame(width: 3)
                .padding(.vertical, compact ? 3 : 5)
            if !compact || thread.messages.count > 1 {
                AvatarView(name: m.from.displayName, address: m.from.address, size: compact ? 20 : 26)
                    .padding(.top, compact ? 1 : 2)
            }
            VStack(alignment: .leading, spacing: compact ? 1 : 2) {
                HStack(spacing: 6) {
                    Text(m.from.displayName)
                        .font(.system(size: 13, weight: unread ? .semibold : .regular))
                        .lineLimit(1)
                    if thread.messages.count > 1 {
                        Button { listModel.toggleExpanded(thread) } label: {
                            HStack(spacing: 2) {
                                Image(systemName: listModel.isExpanded(thread) ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 8, weight: .bold))
                                Text("\(thread.messages.count)").font(.system(size: 10, weight: .medium))
                            }
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(listModel.isExpanded(thread) ? "Collapse conversation" : "Expand conversation")
                    }
                    Spacer(minLength: 4)
                    if m.hasAttachments { Image(systemName: "paperclip").font(.system(size: 10)).foregroundStyle(.secondary) }
                    if m.isFlagged { Image(systemName: "flag.fill").font(.system(size: 10)).foregroundStyle(.orange) }
                    Text(MessageRow.dateText(m.date))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Text(m.subject.isEmpty ? "(no subject)" : m.subject)
                    .font(.system(size: 12.5, weight: unread ? .medium : .regular))
                    .foregroundStyle(unread ? .primary : .secondary)
                    .lineLimit(1)
                if !compact {
                    Text(m.snippet.isEmpty ? " " : m.snippet)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, compact ? 4 : 6)
        .contentShape(Rectangle())
    }

}

struct ChildMessageRow: View {
    let message: MessageSummary

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(message.isRead ? Color.clear : Color.accentColor)
                .frame(width: 7, height: 7)
                .padding(.top, 9)
            AvatarView(name: message.from.displayName, address: message.from.address, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(message.from.displayName)
                        .font(.system(size: 12.5, weight: message.isRead ? .regular : .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if message.hasAttachments { Image(systemName: "paperclip").font(.system(size: 10)).foregroundStyle(.secondary) }
                    if message.isFlagged { Image(systemName: "flag.fill").font(.system(size: 10)).foregroundStyle(.red) }
                    Text(MessageRow.dateText(message.date)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(message.snippet.isEmpty ? " " : message.snippet)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 44)
        .padding(.vertical, 4)
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
