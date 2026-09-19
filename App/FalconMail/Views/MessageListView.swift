import SwiftUI
import FalconCore

struct MessageListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack {
                TextField("Search mail", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.runSearch() } }
                if !model.searchText.isEmpty {
                    Button { model.searchText = ""; Task { await model.reloadMessages() } } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                }
                Toggle(isOn: $model.groupByThread) { Image(systemName: "bubble.left.and.bubble.right") }
                    .toggleStyle(.button)
                    .help("Group by conversation")
            }
            .padding(8)
            Divider()
            if model.isSearching {
                ProgressView("Searching…").padding()
            }
            List(model.threads, selection: $model.selectedMessageIDs) { thread in
                MessageRow(thread: thread)
                    .tag(thread.id)
                    .contextMenu {
                        Button("Open") { model.openMessage(thread.latest) { openWindow(value: $0) } }
                        Button("Open in Separate Window") { openWindow(value: thread.latest.id) }
                        Button(thread.latest.isRead ? "Mark as Unread" : "Mark as Read") { model.markRead(thread.messages, !thread.latest.isRead) }
                        Button(thread.latest.isFlagged ? "Unflag" : "Flag") { model.setFlagged(thread.messages, !thread.latest.isFlagged) }
                        Button("Archive") { model.archive(thread.messages) }
                        Button("Delete", role: .destructive) { model.delete(thread.messages) }
                    }
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
                    ContentUnavailableView(model.accounts.isEmpty ? "Add an account to get started" : "No messages", systemImage: "tray")
                }
            }
            if case .folder = model.selection, model.searchText.isEmpty {
                Divider()
                Button("Load older messages") { model.loadOlder() }.buttonStyle(.link).padding(6)
            }
        }
        .onChange(of: model.selectedMessageIDs) { _, new in
            if new.count == 1, let t = model.threads.first(where: { $0.id == new.first! }), !t.latest.isRead {
                model.markRead([t.latest], true)
            }
        }
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
