import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// An attachment as Outlook for Mac shows one, in a message and in a message being written: a
/// box with the file's own icon, its name and size, and an arrow on the right that opens its
/// menu (Preview, Open, Download, and Remove while writing). A click selects it, Space shows it
/// in Quick Look, a double-click opens it, and it can be dragged out.
struct AttachmentCard: View {
    struct Action {
        var title: String
        var enabled = true
        var destructive = false
        var run: () -> Void
    }

    let filename: String
    let size: Int
    var selected = false
    var busy = false
    /// What the box drags and how it answers clicks (see AttachmentDragHandle).
    let handle: AttachmentDragHandle
    let actions: [Action]

    static let width: CGFloat = 192
    static let height: CGFloat = 42

    private var icon: NSImage {
        let ext = (filename as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                ZStack {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 26, height: 26)
                    if busy { ProgressView().controlSize(.small) }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(filename).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(selected ? Color.white : OLColor.text)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        .font(.system(size: 11)).lineLimit(1)
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : OLColor.textMuted)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay { handle }
            Menu {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    if action.destructive { Divider() }
                    Button(action.title, role: action.destructive ? .destructive : nil, action: action.run)
                        .disabled(!action.enabled)
                }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : OLColor.textMuted)
                    .frame(width: 24, height: AttachmentCard.height)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
            .padding(.trailing, 2)
            .help("More for this attachment")
        }
        .frame(width: AttachmentCard.width, height: AttachmentCard.height)
        .background(selected ? Theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? Theme.accent : OLColor.textMuted.opacity(0.45), lineWidth: 1))
        .help(filename)
    }
}

/// "Download All • Preview All" under a message's attachments, as Outlook shows.
struct AttachmentAllLinks: View {
    let count: Int
    let downloadAll: () -> Void
    let previewAll: () -> Void

    var body: some View {
        if count > 1 {
            HStack(spacing: 6) {
                Button("Download All", action: downloadAll)
                Text("•").foregroundStyle(OLColor.textMuted)
                Button("Preview All", action: previewAll)
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
        }
    }
}

enum AttachmentFolderPicker {
    /// Asks where to save several attachments; nil when cancelled.
    @MainActor static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// `name` in `folder`, numbered if a file of that name is already there.
    static func freeURL(for name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var url = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }
}
