import AppKit
import UniformTypeIdentifiers
import FalconCore

enum AttachmentTempFiles {
    static let directory: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FalconMail-Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// How long a copy made to open, preview, drag or edit an attachment is kept once nothing
    /// has touched it: a day, so one being worked on in another app is left alone.
    static let keptFor: TimeInterval = 24 * 3_600

    /// Deletes the copies nothing has touched for `keptFor`: at launch and every few hours, so
    /// that opened attachments never pile up on the Mac. Gmail's are fetched again when needed.
    static func cleanUp(now: Date = Date()) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .contentAccessDateKey]) else { return }
        var freed = 0
        for folder in items {
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .contentAccessDateKey, .fileSizeKey])) ?? []
            let touched = ([folder] + files).compactMap { url -> Date? in
                let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .contentAccessDateKey])
                return [v?.contentModificationDate, v?.contentAccessDate].compactMap { $0 }.max()
            }.max() ?? .distantPast
            guard now.timeIntervalSince(touched) > keptFor else { continue }
            freed += files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
            try? fm.removeItem(at: folder)
        }
        if freed > 0 { Log.info("storage", "removed \(freed / 1_024) KB of attachment copies no longer used") }
    }

    @MainActor private static var sweeping: Timer?

    /// Cleans up now and every six hours while FalconMail runs.
    @MainActor static func startCleaning() {
        DispatchQueue.global(qos: .utility).async { cleanUp() }
        sweeping?.invalidate()
        sweeping = Timer.scheduledTimer(withTimeInterval: 6 * 3_600, repeats: true) { _ in
            DispatchQueue.global(qos: .utility).async { cleanUp() }
        }
    }

    static func write(filename: String, data: Data) -> URL? {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = filename.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent(safe.isEmpty ? "attachment" : safe)
        return (try? data.write(to: url)) != nil ? url : nil
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
