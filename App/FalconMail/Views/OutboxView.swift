import SwiftUI
import FalconCore

struct OutboxView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(model.outboxItems) { item in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.subject.isEmpty ? "(no subject)" : item.subject).font(.system(size: 13, weight: .medium))
                    Text(item.recipients.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(statusText(item)).font(.caption).foregroundStyle(item.status == .failed ? .red : .secondary)
                }
                Spacer()
                if item.canUndo { Button("Undo") { model.undoSend(item) } }
                if item.status == .failed { Button("Retry") { Task { try? await model.outbox.retry(item.id) } } }
                if item.status == .sent || item.status == .cancelled || item.status == .failed {
                    Button { Task { await model.outbox.remove(item.id) } } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
        .overlay { if model.outboxItems.isEmpty { ContentUnavailableView("Outbox is empty", systemImage: "paperplane") } }
    }

    private func statusText(_ item: OutboxItem) -> String {
        switch item.status {
        case .queued: return item.sendAt > Date().addingTimeInterval(60) ? "Scheduled for \(item.sendAt.formatted())" : "Sending shortly"
        case .sending: return "Sending…"
        case .sent: return "Sent"
        case .failed: return "Failed: \(item.error ?? "unknown error")"
        case .cancelled: return "Cancelled"
        }
    }
}
