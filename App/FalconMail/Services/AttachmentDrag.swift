import AppKit
import UniformTypeIdentifiers
import FalconCore

enum AttachmentTempFiles {
    static let directory: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FalconMail-Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func write(filename: String, data: Data) -> URL? {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = filename.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent(safe.isEmpty ? "attachment" : safe)
        return (try? data.write(to: url)) != nil ? url : nil
    }

    static func itemProvider(filename: String, data: Data) -> NSItemProvider {
        guard let url = write(filename: filename, data: data) else { return NSItemProvider() }
        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }

    static func fileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL? = await withCheckedContinuation { cont in
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    if let data = item as? Data { cont.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                    else if let url = item as? URL { cont.resume(returning: url) }
                    else { cont.resume(returning: nil) }
                }
            }
            if let url { urls.append(url) }
        }
        return urls
    }

    static func attachment(from url: URL) -> OutgoingAttachment? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return OutgoingAttachment(filename: url.lastPathComponent, mimeType: type, data: data)
    }
}

@MainActor
final class AttachmentEditSession {
    let attachmentID: UUID
    let url: URL
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private let onChange: (Data) -> Void

    init?(attachment: OutgoingAttachment, onChange: @escaping (Data) -> Void) {
        guard let url = AttachmentTempFiles.write(filename: attachment.filename, data: attachment.data) else { return nil }
        self.attachmentID = attachment.id
        self.url = url
        self.onChange = onChange
        watch()
        NSWorkspace.shared.open(url)
    }

    private func watch() {
        source?.cancel()
        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        s.setEventHandler { [weak self] in
            guard let self else { return }
            let events = s.data
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let data = try? Data(contentsOf: self.url) { self.onChange(data) }
                if events.contains(.rename) || events.contains(.delete) { self.watch() }
            }
        }
        s.setCancelHandler { [descriptor = self.descriptor] in close(descriptor) }
        s.resume()
        source = s
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}
