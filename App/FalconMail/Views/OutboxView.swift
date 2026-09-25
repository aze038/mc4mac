import SwiftUI
import FalconCore

struct OutboxView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(model.outboxItems) { item in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.subject.isEmpty ? "(no subject)" : item.subject).font(.system(size: 13, weight: .medium))
                    Text(item.recipientSummary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .help(item.recipientSummary)
                    Text(statusText(item)).font(.caption).foregroundStyle(statusStyle(item))
                }
                Spacer()
                actions(item)
            }
            .padding(.vertical, 4)
        }
        .overlay { if model.outboxItems.isEmpty { ContentUnavailableView("Outbox is empty", systemImage: "paperplane") } }
    }

    @ViewBuilder private func actions(_ item: OutboxItem) -> some View {
        if isSendingSoon(item) {
            Button("Undo") { reopen(item) }
        } else if item.status == .queued {
            Button("Edit") { reopen(item) }.help("Stops the message and reopens it as a draft")
        }
        if item.status == .failed {
            Button(item.isHeld ? "Send Again" : "Retry") { Task { try? await model.outbox.retry(item.id) } }
        }
        if item.status == .sent || item.status == .cancelled || item.status == .failed {
            Button { Task { await model.outbox.remove(item.id) } } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain)
        }
    }

    private func isSendingSoon(_ item: OutboxItem) -> Bool {
        item.isSendingSoon(within: TimeInterval(model.undoSendSeconds))
    }

    private func reopen(_ item: OutboxItem) {
        model.cancelAndReopen(item)
    }

    private func statusStyle(_ item: OutboxItem) -> Color {
        if item.isHeld { return .orange }
        return item.status == .failed ? .red : .secondary
    }

    private func statusText(_ item: OutboxItem) -> String {
        if item.isHeld { return "Held: \(item.error ?? "not sent again by itself")" }
        switch item.status {
        case .queued:
            if let e = item.error { return "Waiting for connection, retrying at \(item.sendAt.formatted(date: .omitted, time: .shortened)) (\(e))" }
            if item.sendAt > Date().addingTimeInterval(60) { return "Scheduled for \(item.sendAt.formatted()). Edit to change it." }
            return "Sending shortly"
        case .sending: return "Sending…"
        case .sent: return "Sent"
        case .failed: return "Failed: \(item.error ?? "unknown error")"
        case .cancelled: return "Cancelled"
        }
    }
}
