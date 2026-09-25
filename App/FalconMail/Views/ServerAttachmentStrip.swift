import SwiftUI
import AppKit
import Quartz
import FalconCore

/// The attachments of a message opened from Gmail. Each is known by name and size only, and is
/// fetched when it is chosen, opened, saved or copied. As in Outlook and in 1.10: a click
/// chooses an attachment (and starts fetching it), Space shows it in Quick Look, the arrow keys
/// move between them, and a double-click or Return opens it in its app.
struct ServerAttachmentStrip: View {
    @Environment(AppModel.self) private var model
    let message: MessageSummary
    let stubs: [GmailAttachmentStub]
    @State private var fetching = Set<String>()
    @State private var driveTarget: DriveSave?
    @State private var selectedIndex: Int?
    @State private var focusToken = 0
    @State private var waiting: [String: [@MainActor (URL) -> Void]] = [:]

    struct DriveSave: Identifiable {
        let id = UUID()
        let name: String
        let data: Data
        let mimeType: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(stubs.enumerated()), id: \.element.id) { index, stub in
                        // Dragged as a promise, downloaded when it is dropped: onto a compose window
                        // it attaches, onto Finder it makes the file; the window never moves.
                        AttachmentCard(
                            filename: stub.filename, size: stub.size,
                            selected: index == selectedIndex, busy: fetching.contains(stub.id),
                            handle: AttachmentDragHandle(
                                filename: stub.filename,
                                content: .promise(filename: stub.filename, mimeType: stub.mimeType,
                                                  fetch: download(stub)),
                                onClick: { select(index) },
                                onDoubleClick: { select(index); open(stub) },
                                menu: menu(stub, index).map { a in .init(title: a.title, enabled: a.enabled, action: a.run) }),
                            actions: menu(stub, index))
                    }
                }
                .padding(.vertical, 2)
            }
            AttachmentAllLinks(count: stubs.count, downloadAll: { downloadAll() }, previewAll: { previewAll() })
        }
        .background(
            QuickLookHostView(urls: stubs.map(localURL), selectedIndex: Binding(
                get: { selectedIndex ?? 0 }, set: { selectedIndex = $0 }), focusToken: focusToken,
                              onOpen: { index in if stubs.indices.contains(index) { open(stubs[index]) } })
                .frame(width: 0, height: 0)
        )
        .onChange(of: selectedIndex) { _, index in
            if let index, stubs.indices.contains(index) { prepare(stubs[index]) }
        }
        .onKeyPress(.space) { toggleQuickLook(); return .handled }
        .onKeyPress(.return) { if let stub = current { open(stub) }; return .handled }
        .sheet(item: $driveTarget) { target in
            DrivePicker(accountID: message.accountID, mode: .save, savingName: target.name,
                        savingData: target.data, savingMime: target.mimeType)
                .environment(model)
        }
    }

    private func chip(_ stub: GmailAttachmentStub, selected: Bool) -> some View {
        HStack(spacing: 6) {
            if fetching.contains(stub.id) {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: isLocal(stub) ? "doc" : "icloud.and.arrow.down")
                    .foregroundStyle(selected ? Color.white : Color.accentColor)
            }
            VStack(alignment: .leading) {
                Text(stub.filename).font(.caption).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(stub.size), countStyle: .file))
                    .font(.caption2).foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
            }
        }
        .padding(6)
        .background(selected ? Color.accentColor : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(selected ? Color.white : Color.primary)
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    private func menu(_ stub: GmailAttachmentStub, _ index: Int) -> [AttachmentCard.Action] {
        [
            .init(title: "Preview") { select(index); toggleQuickLook() },
            .init(title: "Open") { open(stub) },
            .init(title: "Download") { downloadToDownloads(stub) },
            .init(title: "Save As…") { saveAs(stub) },
            .init(title: "Save to Google Drive…") { saveToDrive(stub) },
            .init(title: "Copy") { copy(stub) },
        ]
    }

    /// Into the Downloads folder, as Outlook's Download does, and shown there.
    private func downloadToDownloads(_ stub: GmailAttachmentStub) {
        guard let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        prepare(stub) { url in
            let target = AttachmentFolderPicker.freeURL(for: stub.filename, in: folder)
            guard (try? FileManager.default.copyItem(at: url, to: target)) != nil else { return }
            NSWorkspace.shared.activateFileViewerSelecting([target])
        }
    }

    private func downloadAll() {
        guard let folder = AttachmentFolderPicker.chooseFolder() else { return }
        for stub in stubs {
            prepare(stub) { url in
                _ = try? FileManager.default.copyItem(at: url, to: AttachmentFolderPicker.freeURL(for: stub.filename, in: folder))
            }
        }
    }

    /// Quick Look over every attachment, the arrow keys going from one to the next.
    private func previewAll() {
        for stub in stubs { prepare(stub) }
        select(selectedIndex ?? 0)
        toggleQuickLook()
    }

    private var current: GmailAttachmentStub? {
        guard let selectedIndex, stubs.indices.contains(selectedIndex) else { return nil }
        return stubs[selectedIndex]
    }

    private func select(_ index: Int) {
        selectedIndex = index
        focusToken += 1
    }

    /// Where an attachment's file is kept once fetched: one place per message and attachment, so
    /// Quick Look can be pointed at it before it arrives and shows it when it does.
    private func localURL(_ stub: GmailAttachmentStub) -> URL {
        let key = "\(message.id)-\(stub.id)".unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }.joined()
        let folder = AttachmentTempFiles.directory.appendingPathComponent("gmail-" + String(key.suffix(120)), isDirectory: true)
        let safe = stub.filename.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return folder.appendingPathComponent(safe.isEmpty ? "attachment" : safe)
    }

    private func isLocal(_ stub: GmailAttachmentStub) -> Bool {
        FileManager.default.fileExists(atPath: localURL(stub).path)
    }

    /// Fetches the attachment to its file if it is not there yet, then hands the file over.
    private func prepare(_ stub: GmailAttachmentStub, then use: @escaping @MainActor (URL) -> Void = { _ in }) {
        let url = localURL(stub)
        if FileManager.default.fileExists(atPath: url.path) { use(url); return }
        // A double-click lands while the click's fetch is still running: it waits for that one.
        waiting[stub.id, default: []].append(use)
        guard !fetching.contains(stub.id) else { return }
        fetching.insert(stub.id)
        Task {
            let data = await model.serverAttachmentData(message, stub)
            fetching.remove(stub.id)
            let waiters = waiting.removeValue(forKey: stub.id) ?? []
            guard let data else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? data.write(to: url, options: .atomic)) != nil else { return }
            if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
                QLPreviewPanel.shared().reloadData()
            }
            waiters.forEach { $0(url) }
        }
    }

    private func toggleQuickLook() {
        guard !stubs.isEmpty else { return }
        if selectedIndex == nil { selectedIndex = 0 }
        let index = selectedIndex ?? 0
        focusToken += 1
        prepare(stubs[index])
        let panel = QLPreviewPanel.shared()!
        DispatchQueue.main.async {
            if panel.isVisible { panel.orderOut(nil) } else { panel.currentPreviewItemIndex = index; panel.makeKeyAndOrderFront(nil) }
        }
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

    /// For a drag's promise, which may ask from any thread: hands over the bytes, or nil.
    private func download(_ stub: GmailAttachmentStub) -> (@escaping (Data?) -> Void) -> Void {
        let model = self.model, message = self.message
        return { done in Task { @MainActor in done(await model.serverAttachmentData(message, stub)) } }
    }

    private func open(_ stub: GmailAttachmentStub) {
        prepare(stub) { url in NSWorkspace.shared.open(url) }
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
