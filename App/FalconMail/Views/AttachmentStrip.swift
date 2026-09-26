import SwiftUI
import AppKit
import Quartz
import FalconCore

final class QuickLookHost: NSView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var urls: [URL] = []
    var currentIndex = 0 { didSet { if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() } } }
    var onSelectionChange: ((Int) -> Void)?
    /// Opens the chosen item when the item's file may not be on the Mac yet; nil opens its URL.
    var onOpen: ((Int) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        if event.keyCode == 123 || event.keyCode == 124 {
            keyDown(with: event)
            return true
        }
        return false
    }

    func togglePanel() {
        guard !urls.isEmpty else { return }
        window?.makeFirstResponder(self)
        let panel = QLPreviewPanel.shared()!
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.currentPreviewItemIndex = currentIndex
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: togglePanel()
        case 123: move(-1)
        case 124: move(1)
        case 36, 76: openCurrent()
        default: super.keyDown(with: event)
        }
    }

    private func move(_ delta: Int) {
        guard !urls.isEmpty else { return }
        currentIndex = max(0, min(urls.count - 1, currentIndex + delta))
        onSelectionChange?(currentIndex)
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().currentPreviewItemIndex = currentIndex }
    }

    func openCurrent() {
        guard urls.indices.contains(currentIndex) else { return }
        if let onOpen { onOpen(currentIndex) } else { NSWorkspace.shared.open(urls[currentIndex]) }
    }
}

struct QuickLookHostView: NSViewRepresentable {
    let urls: [URL]
    @Binding var selectedIndex: Int
    let focusToken: Int
    var onOpen: ((Int) -> Void)? = nil

    func makeNSView(context: Context) -> QuickLookHost {
        let host = QuickLookHost()
        host.onSelectionChange = { context.coordinator.parent.selectedIndex = $0 }
        return host
    }

    func updateNSView(_ host: QuickLookHost, context: Context) {
        context.coordinator.parent = self
        host.urls = urls
        host.onOpen = onOpen
        if host.currentIndex != selectedIndex { host.currentIndex = selectedIndex }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { host.window?.makeFirstResponder(host) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator {
        var parent: QuickLookHostView
        var lastFocusToken = -1
        init(parent: QuickLookHostView) { self.parent = parent }
    }
}

struct AttachmentStrip: View {
    @Environment(AppModel.self) private var model
    let attachments: [MIMEAttachment]
    var html: String? = nil
    var accountID: UUID? = nil
    @State private var driveTarget: MIMEAttachment?
    @State private var selectedIndex = 0
    @State private var focusToken = 0
    @State private var tempURLs: [String: URL] = [:]
    @State private var hostView: QuickLookHost?

    private var visible: [MIMEAttachment] {
        let body = html?.lowercased() ?? ""
        var seen = Set<Data>()
        return attachments.filter { a in
            if let cid = a.contentID, a.isInline || body.contains("cid:" + cid.lowercased()) {
                if body.contains("cid:" + cid.lowercased()) { return false }
            }
            return seen.insert(a.data).inserted
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, a in
                        // Clicks, the menu and dragging go through AppKit (see AttachmentDragHandle),
                        // so that dragging the box drags the file and never the window.
                        AttachmentCard(
                            filename: a.filename, size: a.size, selected: index == selectedIndex,
                            handle: AttachmentDragHandle(
                                filename: a.filename,
                                content: .file({ url(for: a) }),
                                onClick: { select(index) },
                                onDoubleClick: { select(index); open(a) },
                                menu: menu(a, index).map { m in .init(title: m.title, enabled: m.enabled, action: m.run) }),
                            actions: menu(a, index))
                    }
                }
                .padding(.vertical, 2)
            }
            AttachmentAllLinks(count: visible.count, downloadAll: { downloadAll() }, previewAll: { select(selectedIndex); toggleQuickLook() })
        }
        .background(
            QuickLookHostView(urls: visible.map { url(for: $0) }, selectedIndex: $selectedIndex, focusToken: focusToken)
                .frame(width: 0, height: 0)
        )
        .sheet(item: $driveTarget) { attachment in
            if let account = driveAccount {
                DrivePicker(accountID: account, mode: .save,
                            savingName: attachment.filename,
                            savingData: attachment.data,
                            savingMime: attachment.mimeType)
                    .environment(model)
            }
        }
        .onKeyPress(.space) { toggleQuickLook(); return .handled }
        .onKeyPress(.return) { if let a = current { open(a) }; return .handled }
        .onKeyPress("s", phases: .down) { press in
            guard press.modifiers.contains(.command), let a = current else { return .ignored }
            saveAs(a)
            return .handled
        }
        .onKeyPress("c", phases: .down) { press in
            guard press.modifiers.contains(.command), let a = current else { return .ignored }
            copyToPasteboard(a)
            return .handled
        }
    }

    private func menu(_ a: MIMEAttachment, _ index: Int) -> [AttachmentCard.Action] {
        [
            .init(title: "Preview") { select(index); toggleQuickLook() },
            .init(title: "Open") { open(a) },
            .init(title: "Download") { download(a) },
            .init(title: "Save As…") { saveAs(a) },
            .init(title: "Save to Google Drive…", enabled: driveAccount != nil) { driveTarget = a },
            .init(title: "Copy") { copyToPasteboard(a) },
        ]
    }

    /// Into the Downloads folder, as Outlook's Download does, and shown there.
    private func download(_ a: MIMEAttachment) {
        guard let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let target = AttachmentFolderPicker.freeURL(for: a.filename, in: folder)
        guard (try? a.data.write(to: target)) != nil else { return }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    private func downloadAll() {
        guard let folder = AttachmentFolderPicker.chooseFolder() else { return }
        for a in visible { try? a.data.write(to: AttachmentFolderPicker.freeURL(for: a.filename, in: folder)) }
    }

    private var current: MIMEAttachment? { visible.indices.contains(selectedIndex) ? visible[selectedIndex] : nil }

    private var driveAccount: UUID? {
        if let accountID, model.accounts.contains(where: { $0.id == accountID && !$0.usesPassword }) { return accountID }
        return model.accounts.first { !$0.usesPassword }?.id
    }

    private func select(_ index: Int) {
        selectedIndex = index
        focusToken += 1
    }

    private func url(for a: MIMEAttachment) -> URL {
        if let u = tempURLs[a.id] { return u }
        let u = AttachmentTempFiles.write(filename: a.filename, data: a.data) ?? URL(fileURLWithPath: "/dev/null")
        DispatchQueue.main.async { tempURLs[a.id] = u }
        return u
    }

    private func toggleQuickLook() {
        guard !visible.isEmpty else { return }
        focusToken += 1
        let panel = QLPreviewPanel.shared()!
        DispatchQueue.main.async {
            if panel.isVisible { panel.orderOut(nil) } else { panel.currentPreviewItemIndex = selectedIndex; panel.makeKeyAndOrderFront(nil) }
        }
    }

    private func open(_ a: MIMEAttachment) {
        NSWorkspace.shared.open(url(for: a))
    }

    private func saveAs(_ a: MIMEAttachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = a.filename
        if panel.runModal() == .OK, let target = panel.url { try? a.data.write(to: target) }
    }

    private func copyToPasteboard(_ a: MIMEAttachment) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url(for: a) as NSURL])
    }
}

struct AttachmentChip: View {
    let attachment: MIMEAttachment
    let selected: Bool

    private var icon: String {
        let ext = (attachment.filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "heic", "tiff": return "photo"
        case "xlsx", "xls", "csv", "numbers": return "tablecells"
        case "docx", "doc", "pages", "rtf", "txt": return "doc.text"
        case "pptx", "ppt", "key": return "rectangle.on.rectangle"
        case "zip", "gz", "7z", "rar": return "doc.zipper"
        default: return "doc"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(selected ? Color.white : Theme.accent)
            VStack(alignment: .leading) {
                Text(attachment.filename).font(.caption).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file)).font(.caption2).foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
            }
        }
        .padding(6)
        .background(selected ? Theme.accent : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(selected ? Color.white : Color.primary)
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}
