import SwiftUI
import AppKit
import Quartz
import FalconCore

final class QuickLookHost: NSView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var urls: [URL] = []
    var currentIndex = 0 { didSet { if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() } } }
    var onSelectionChange: ((Int) -> Void)?

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
        NSWorkspace.shared.open(urls[currentIndex])
    }
}

struct QuickLookHostView: NSViewRepresentable {
    let urls: [URL]
    @Binding var selectedIndex: Int
    let focusToken: Int

    func makeNSView(context: Context) -> QuickLookHost {
        let host = QuickLookHost()
        host.onSelectionChange = { context.coordinator.parent.selectedIndex = $0 }
        return host
    }

    func updateNSView(_ host: QuickLookHost, context: Context) {
        context.coordinator.parent = self
        host.urls = urls
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
    let attachments: [MIMEAttachment]
    @State private var selectedIndex = 0
    @State private var focusToken = 0
    @State private var tempURLs: [String: URL] = [:]
    @State private var hostView: QuickLookHost?

    private var visible: [MIMEAttachment] { attachments.filter { !$0.isInline || $0.contentID == nil } }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, a in
                    AttachmentChip(attachment: a, selected: index == selectedIndex)
                        .onTapGesture(count: 2) { select(index); open(a) }
                        .onTapGesture { select(index) }
                        .onDrag { AttachmentTempFiles.itemProvider(filename: a.filename, data: a.data) }
                        .contextMenu {
                            Button("Quick Look") { select(index); toggleQuickLook() }
                            Button("Open") { open(a) }
                            Button("Save As…") { saveAs(a) }
                            Button("Copy") { copyToPasteboard(a) }
                        }
                }
            }
            .padding(.vertical, 2)
        }
        .background(
            QuickLookHostView(urls: visible.map { url(for: $0) }, selectedIndex: $selectedIndex, focusToken: focusToken)
                .frame(width: 0, height: 0)
        )
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

    private var current: MIMEAttachment? { visible.indices.contains(selectedIndex) ? visible[selectedIndex] : nil }

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
            Image(systemName: icon).foregroundStyle(selected ? Color.white : Color.accentColor)
            VStack(alignment: .leading) {
                Text(attachment.filename).font(.caption).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file)).font(.caption2).foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
            }
        }
        .padding(6)
        .background(selected ? Color.accentColor : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(selected ? Color.white : Color.primary)
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}
