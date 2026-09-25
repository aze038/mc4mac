import AppKit
import UniformTypeIdentifiers

/// Files dragged onto a compose window: what counts as a file drag, and the attachments it makes.
///
/// Outlook attaches whatever file is dropped anywhere on a message being written, pictures
/// included, and never types its path or a file:// link into the text. A drag that carries a
/// file, whether as a file URL or as a promise to write one (as Mail, Outlook, Safari and
/// FalconMail's own message windows give), is therefore always an attachment; a drag of
/// words or of a web link is left to the text it lands on.
public enum DroppedFiles {
    public static let fileURLType = "public.file-url"
    /// The old name for a list of paths, which some apps still put on a drag.
    public static let filenamesType = "NSFilenamesPboardType"
    /// The types a promise to write a file is announced by, old and new.
    public static let promiseTypes = [
        "com.apple.NSFilePromiseItemMetaData",
        "com.apple.pasteboard.promised-file-url",
        "com.apple.pasteboard.promised-file-content-type",
        "com.apple.pasteboard.promised-suggested-file-name",
        "Apple files promise pasteboard type",
    ]

    /// Every type a compose window takes as a file to attach.
    public static var types: [String] { [fileURLType, filenamesType] + promiseTypes }

    /// Whether a drag with these pasteboard types carries a file, and so is to be attached
    /// rather than written into the text.
    public static func carriesFiles(_ types: [String]) -> Bool {
        let set = Set(types)
        return self.types.contains { set.contains($0) }
    }

    /// The files named on these pasteboard items, each once, in order. Web addresses are not
    /// files and are left out.
    public static func fileURLs(in items: [NSPasteboardItem]) -> [URL] {
        var urls: [URL] = []
        for item in items {
            if let string = item.string(forType: NSPasteboard.PasteboardType(fileURLType)),
               let url = URL(string: string), url.isFileURL {
                urls.append(url)
            } else if let data = item.data(forType: NSPasteboard.PasteboardType(fileURLType)),
                      let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
                urls.append(url)
            }
            if let paths = item.propertyList(forType: NSPasteboard.PasteboardType(filenamesType)) as? [String] {
                urls += paths.map { URL(fileURLWithPath: $0) }
            }
        }
        return unique(urls)
    }

    /// The same files named more than once, as a drag giving both a URL and a path does, once.
    public static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { $0.isFileURL && seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// The MIME type a file of this name is sent as.
    public static func mimeType(forFilename name: String) -> String {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return "application/octet-stream" }
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// The attachments these dropped files make, in order, each file once. A folder, or a file
    /// that cannot be read, is passed over.
    public static func attachments(from urls: [URL],
                                   read: (URL) -> Data? = DroppedFiles.readFile) -> [OutgoingAttachment] {
        unique(urls).compactMap { url in
            guard let data = read(url) else { return nil }
            let name = url.lastPathComponent.isEmpty ? "attachment" : url.lastPathComponent
            return OutgoingAttachment(filename: name, mimeType: mimeType(forFilename: name), data: data)
        }
    }

    public static func readFile(_ url: URL) -> Data? {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else { return nil }
        return try? Data(contentsOf: url)
    }
}
