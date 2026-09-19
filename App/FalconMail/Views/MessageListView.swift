import SwiftUI
import FalconCore

struct MessageListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            filterBar
            Divider()
            if model.isSearching {
                ProgressView("Searching…").padding()
            }
            threadList
            loadOlderBar
        }
        .onChange(of: model.selectedMessageIDs) { _, _ in model.selectionDidChange() }
        .onChange(of: model.focusSearchToken) { _, _ in searchFocused = true }
    }

    private var searchBar: some View {
        @Bindable var model = model
        return HStack {
            TextField("Search mail", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { Task { await model.runSearch() } }
                .onExitCommand {
                    model.clearSearch()
                    searchFocused = false
                }
            if !model.searchText.isEmpty {
                Button { model.clearSearch() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
            }
            Toggle(isOn: $model.groupByThread) { Image(systemName: "bubble.left.and.bubble.right") }
                .toggleStyle(.button)
                .help("Group by conversation")
        }
        .padding(8)
    }

    @ViewBuilder private var filterBar: some View {
        if !model.filters.isEmpty {
            HStack(spacing: 6) {
                ForEach(MessageFilter.allCases.filter { model.filters.contains($0) }) { filter in
                    filterChip(filter)
                }
                Spacer()
                Text("\(model.threads.count) conversations")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                pinButton
                Button("Clear") { model.clearFilters() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
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

    private var threadList: some View {
        @Bindable var model = model
        return ScrollViewReader { proxy in
            List(model.threads, selection: $model.selectedMessageIDs) { thread in
                MessageRow(thread: thread)
                    .tag(thread.id)
                    .contextMenu { rowMenu(thread) }
            }
            .listStyle(.inset)
            .background(DoubleClickMonitor { if let t = model.currentThread { model.openMessage(t.latest) { openWindow(value: $0) } } })
            .onKeyPress(.return) {
                guard let t = model.currentThread else { return .ignored }
                model.openMessage(t.latest) { openWindow(value: $0) }
                return .handled
            }
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
        Button(thread.latest.isRead ? "Mark as Unread" : "Mark as Read") { model.markRead(thread.messages, !thread.latest.isRead) }
        Button(thread.latest.isFlagged ? "Unflag" : "Flag") { model.setFlagged(thread.messages, !thread.latest.isFlagged) }
        Button("Archive") { model.archive(thread.messages) }
        Button(model.isInJunk(thread.messages) ? "Not Junk" : "Move to Junk") { model.toggleJunk(thread.messages) }
        Button(model.isMuted(thread) ? "Unmute Conversation" : "Mute Conversation") { model.toggleMute(thread) }
        Button("Delete", role: .destructive) { model.delete(thread.messages) }
    }
}

struct MessageRow: View {
    let thread: MessageThread

    var body: some View {
        let m = thread.latest
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(thread.unreadCount > 0 ? Color.accentColor : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(m.from.displayName)
                        .font(.system(size: 13, weight: thread.unreadCount > 0 ? .semibold : .regular))
                        .lineLimit(1)
                    if thread.messages.count > 1 {
                        Text("\(thread.messages.count)")
                            .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    Spacer()
                    Text(MessageRow.dateText(m.date)).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text(m.subject.isEmpty ? "(no subject)" : m.subject)
                        .font(.system(size: 13, weight: thread.unreadCount > 0 ? .medium : .regular))
                        .lineLimit(1)
                    Spacer()
                    if m.hasAttachments { Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary) }
                    if m.isFlagged { Image(systemName: "flag.fill").font(.caption).foregroundStyle(.red) }
                }
                Text(m.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

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
