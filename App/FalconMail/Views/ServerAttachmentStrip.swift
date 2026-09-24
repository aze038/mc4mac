import SwiftUI
import AppKit
import FalconCore

/// The attachments of a message opened from Gmail. Each is known by name and size only, and is
/// fetched into memory when it is opened, saved or copied.
struct ServerAttachmentStrip: View {
    @Environment(AppModel.self) private var model
    let message: MessageSummary
    let stubs: [GmailAttachmentStub]
    @State private var fetching = Set<String>()
    @State private var driveTarget: DriveSave?

    struct DriveSave: Identifiable {
        let id = UUID()
        let name: String
        let data: Data
        let mimeType: String
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(stubs) { stub in
                    chip(stub)
                        .onTapGesture(count: 2) { open(stub) }
                        .contextMenu {
                            Button("Open") { open(stub) }
                            Button("Save As…") { saveAs(stub) }
                            Button("Save to Google Drive…") { saveToDrive(stub) }
                            Button("Copy") { copy(stub) }
                        }
                        .help("Downloads from Gmail when opened or saved")
                }
            }
            .padding(.vertical, 2)
        }
        .sheet(item: $driveTarget) { target in
            DrivePicker(accountID: message.accountID, mode: .save, savingName: target.name,
                        savingData: target.data, savingMime: target.mimeType)
                .environment(model)
        }
    }

    private func chip(_ stub: GmailAttachmentStub) -> some View {
        HStack(spacing: 6) {
            if fetching.contains(stub.id) {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "icloud.and.arrow.down").foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading) {
                Text(stub.filename).font(.caption).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(stub.size), countStyle: .file))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    private func fetch(_ stub: GmailAttachmentStub, then use: @escaping @MainActor (Data) -> Void) {
        guard !fetching.contains(stub.id) else { return }
        fetching.insert(stub.id)
        Task {
            let data = await model.serverAttachmentData(message, stub)
            fetching.remove(stub.id)
            if let data { use(data) }
        }
    }

    private func open(_ stub: GmailAttachmentStub) {
        fetch(stub) { data in
            if let url = AttachmentTempFiles.write(filename: stub.filename, data: data) { NSWorkspace.shared.open(url) }
        }
    }

    private func saveAs(_ stub: GmailAttachmentStub) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = stub.filename
        guard panel.runModal() == .OK, let target = panel.url else { return }
        fetch(stub) { data in try? data.write(to: target) }
    }

    private func saveToDrive(_ stub: GmailAttachmentStub) {
        fetch(stub) { data in driveTarget = DriveSave(name: stub.filename, data: data, mimeType: stub.mimeType) }
    }

    private func copy(_ stub: GmailAttachmentStub) {
        fetch(stub) { data in
            guard let url = AttachmentTempFiles.write(filename: stub.filename, data: data) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([url as NSURL])
        }
    }
}
