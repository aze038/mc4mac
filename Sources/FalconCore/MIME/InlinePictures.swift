import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A picture a message shows in its text, sent as Outlook sends one: a part of its own beside the
/// text, inside multipart/related, named image001.png, image002.jpg and on in the order the
/// pictures first appear, which the HTML shows by its Content-ID.
public struct InlinePicture: Sendable, Hashable {
    public var filename: String
    public var mimeType: String
    /// As Outlook makes one: the file's name, then the time the message was put together
    /// (image001.png@01DB0F8A.5C6D7E80).
    public var contentID: String
    public var data: Data

    /// The part as the message carries it: inline, under its Content-ID.
    public var attachment: OutgoingAttachment {
        OutgoingAttachment(filename: filename, mimeType: mimeType, data: data, contentID: contentID)
    }
}

/// Pictures in the composer's text: how one is put in, whichever way it comes (the Pictures
/// button, the signature editor's Picture button, Paste), how each goes out as an inline part,
/// and how a message's pictures come back into a body when a draft is opened again.
public enum InlinePictures {
    /// The formats every mail reader shows in a message's text.
    public enum Format: String, Sendable {
        case png, jpeg, gif

        public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
        public var mimeType: String { "image/\(rawValue)" }
    }

    /// Known by the file's first bytes, whatever it is called.
    public static func format(of data: Data) -> Format? {
        let bytes = [UInt8](data.prefix(8))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) { return .gif }
        return nil
    }

    /// A picture as it is sent. PNG, JPEG and GIF go exactly as they are, however large, as
    /// Outlook sends them: nothing is scaled or compressed again. A format mail readers do not
    /// show in a message's text becomes one they do: a photo in HEIC or HEIF becomes a JPEG,
    /// anything else, such as the TIFF a screenshot is copied to the clipboard as, BMP or PDF,
    /// becomes a PNG, which loses nothing. Nil for what is not a picture.
    public static func sendable(_ data: Data) -> (data: Data, format: Format)? {
        if let format = format(of: data) { return (data, format) }
        guard !data.isEmpty else { return nil }
        if let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
           let type = CGImageSourceGetType(source).map({ UTType($0 as String) }) ?? nil {
            let photo = type.conforms(to: .heic) || type.conforms(to: .heif)
            if let converted = convert(source, to: photo ? .jpeg : .png) { return converted }
        }
        // PDF and EPS are drawn, not decoded, so they go through AppKit's own drawing.
        guard let image = NSImage(data: data), let tiff = image.tiffRepresentation,
              let source = CGImageSourceCreateWithData(tiff as CFData, nil) else { return nil }
        return convert(source, to: .png)
    }

    /// The first image of `source` as `format`, keeping its resolution, so it is shown at the
    /// size it was.
    private static func convert(_ source: CGImageSource, to format: Format) -> (data: Data, format: Format)? {
        let output = NSMutableData()
        let type = (format == .jpeg ? UTType.jpeg : UTType.png).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return nil }
        let options = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary : nil
        CGImageDestinationAddImageFromSource(destination, source, 0, options)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { return nil }
        return (output as Data, format)
    }

    // MARK: - Putting a picture into a text

    /// A picture to put into a text, held as its file so that RTFD keeps it with the text, in a
    /// format every reader shows; nil when `data` is no picture. The composer's Pictures button,
    /// the signature editor's Picture button and Paste all make their pictures here.
    public static func attachment(for data: Data, named name: String? = nil) -> NSTextAttachment? {
        guard let sendable = sendable(data) else { return nil }
        let file = FileWrapper(regularFileWithContents: sendable.data)
        file.preferredFilename = filename(name, format: sendable.format)
        return NSTextAttachment(fileWrapper: file)
    }

    /// `name` with the extension of the format it is kept in, or Picture.png for none.
    static func filename(_ name: String?, format: Format) -> String {
        let base = ((name ?? "") as NSString).deletingPathExtension.trimmed
        return (base.isEmpty ? "Picture" : base) + "." + format.fileExtension
    }

    /// `text` with every picture it holds made as `attachment(for:named:)` makes one, keeping
    /// the size it is shown at. What holds no picture, such as a file pasted with the text, is
    /// taken out.
    public static func normalised(_ text: NSAttributedString) -> NSAttributedString {
        let output = NSMutableAttributedString(attributedString: text)
        let marks = attachmentLocations(in: text)
        guard !marks.isEmpty else { return text }
        output.beginEditing()
        for (location, attachment) in marks.reversed() {
            if isKept(attachment) { continue }
            let range = NSRange(location: location, length: 1)
            guard let contents = contents(of: attachment),
                  let made = self.attachment(for: contents, named: attachment.fileWrapper?.preferredFilename) else {
                output.deleteCharacters(in: range)
                continue
            }
            made.bounds = attachment.bounds
            output.addAttribute(.attachment, value: made, range: range)
        }
        output.endEditing()
        return output
    }

    /// Already held as its file, in a format every reader shows.
    private static func isKept(_ attachment: NSTextAttachment) -> Bool {
        guard let file = attachment.fileWrapper, file.isRegularFile, let data = file.regularFileContents else { return false }
        return format(of: data) != nil
    }

    /// The bytes an attachment holds: its file, else what it was made with, else its image.
    static func contents(of attachment: NSTextAttachment) -> Data? {
        if let file = attachment.fileWrapper, file.isRegularFile, let data = file.regularFileContents, !data.isEmpty { return data }
        if let data = attachment.contents, !data.isEmpty { return data }
        return (attachment.image ?? (attachment.attachmentCell as? NSCell)?.image)?.tiffRepresentation
    }

    /// Every character of `text` that holds an attachment, with it, in order. One attachment can
    /// stand at several characters in a row.
    static func attachmentLocations(in text: NSAttributedString) -> [(Int, NSTextAttachment)] {
        var found: [(Int, NSTextAttachment)] = []
        let string = text.string as NSString
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            for location in range.location..<NSMaxRange(range) where string.character(at: location) == 0xFFFC {
                found.append((location, attachment))
            }
        }
        return found
    }

    /// Whether `text` holds anything drawn as a picture.
    public static func hasPictures(_ text: NSAttributedString) -> Bool {
        !attachmentLocations(in: text).isEmpty
    }

    /// The picture an attachment holds, as sent, and the size it is shown at, in points; nil for
    /// one that holds no picture.
    static func picture(in attachment: NSTextAttachment) -> (data: Data, format: Format, size: NSSize)? {
        guard let contents = contents(of: attachment), let sendable = sendable(contents) else { return nil }
        let bounds = attachment.bounds.size
        let size = bounds.width > 0 && bounds.height > 0 ? bounds : NSImage(data: sendable.data)?.size ?? .zero
        return (sendable.data, sendable.format, size)
    }

    // MARK: - Sending

    /// Names each different picture of one message once, in the order the pictures first
    /// appear, so a picture shown twice, such as a logo in two signatures, is sent once.
    struct Collector {
        let stamp: String
        private(set) var pictures: [InlinePicture] = []
        private var byContents: [Data: Int] = [:]

        init(date: Date) {
            stamp = InlinePictures.stamp(for: date)
        }

        mutating func add(_ data: Data, _ format: Format) -> InlinePicture {
            if let known = byContents[data] { return pictures[known] }
            let name = String(format: "image%03d.%@", pictures.count + 1, format.fileExtension)
            let picture = InlinePicture(filename: name, mimeType: format.mimeType, contentID: "\(name)@\(stamp)", data: data)
            byContents[data] = pictures.count
            pictures.append(picture)
            return picture
        }
    }

    /// What Outlook puts after the @ of a picture's Content-ID: the time as Windows counts it,
    /// in hundreds of nanoseconds since 1601, in hexadecimal, its two halves split by a point.
    public static func stamp(for date: Date) -> String {
        let ticks = UInt64(max(0, (date.timeIntervalSince1970 + 11_644_473_600) * 10_000_000))
        return String(format: "%08X.%08X", UInt32(truncatingIfNeeded: ticks >> 32), UInt32(truncatingIfNeeded: ticks))
    }

    /// The picture's tag in the HTML, shown at the size it is shown in the composer, as Outlook
    /// writes it.
    static func tag(for picture: InlinePicture, size: NSSize) -> String {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard width > 0, height > 0 else { return "<img src=\"cid:\(picture.contentID)\">" }
        return "<img width=\"\(width)\" height=\"\(height)\" style=\"width:\(width)px;height:\(height)px\" src=\"cid:\(picture.contentID)\">"
    }

    /// What the plain text part says where a picture was, as Outlook writes it.
    static func plainMark(for picture: InlinePicture) -> String {
        "[cid:\(picture.contentID)]"
    }

    /// A picture's data: URI, its base64 wrapped over lines or not.
    private static let dataURI = try! NSRegularExpression(
        pattern: "data:(image/[a-z0-9.+-]+);base64,([a-z0-9+/=]+(?:\\r?\\n[a-z0-9+/=]+)*)", options: [.caseInsensitive])

    private static func decodedDataURI(_ match: NSTextCheckingResult, in text: NSString) -> Data? {
        Data(base64Encoded: text.substring(with: match.range(at: 2)), options: .ignoreUnknownCharacters)
    }

    /// `html` with every picture it holds as a data: URI, as a reply's or forward's original
    /// keeps its pictures, sent as a part the HTML refers to by cid: instead. Gmail shows no
    /// picture given as a data: URI, nor does Outlook for Windows.
    static func sendingDataURIs(in html: String, into collector: inout Collector) -> String {
        let text = html as NSString
        let matches = dataURI.matches(in: html, range: NSRange(location: 0, length: text.length))
        guard !matches.isEmpty else { return html }
        var replacements: [(NSRange, String)] = []
        for match in matches {
            guard let data = decodedDataURI(match, in: text), let sendable = sendable(data) else { continue }
            replacements.append((match.range, "cid:" + collector.add(sendable.data, sendable.format).contentID))
        }
        let output = NSMutableString(string: html)
        for (range, replacement) in replacements.reversed() { output.replaceCharacters(in: range, with: replacement) }
        return output as String
    }

    // MARK: - Reading

    private static let cidReference = try! NSRegularExpression(pattern: "cid:([^\"'\\s<>)]+)", options: [.caseInsensitive])

    /// `html` with every picture it refers to by cid: that is among `parts` put in as a data: URI,
    /// for the reader, which loads nothing from outside the message, and for the original a reply
    /// or forward quotes. A reference no part answers is left as it is.
    public static func resolvingCIDs(in html: String, with parts: [MIMEAttachment]) -> String {
        var byID: [String: MIMEAttachment] = [:]
        for part in parts {
            guard let id = part.contentID?.lowercased(), byID[id] == nil else { continue }
            byID[id] = part
        }
        guard !byID.isEmpty else { return html }
        let text = html as NSString
        let output = NSMutableString(string: html)
        for match in cidReference.matches(in: html, range: NSRange(location: 0, length: text.length)).reversed() {
            let id = text.substring(with: match.range(at: 1))
            guard let part = byID[id.lowercased()] ?? byID[(id.removingPercentEncoding ?? id).lowercased()] else { continue }
            output.replaceCharacters(in: match.range, with: "data:\(part.mimeType);base64,\(part.data.base64EncodedString())")
        }
        return output as String
    }

    /// Whether the message's HTML shows `part` in its text, by cid:. Such a part stays in the
    /// text of a forward and of a draft opened again; any other part, an inline one included,
    /// as a photo sent from an iPhone in a plain message is, goes with them as an attachment.
    public static func isShownInText(_ part: MIMEAttachment, html: String?) -> Bool {
        guard let id = part.contentID?.lowercased(), !id.isEmpty, let html = html?.lowercased() else { return false }
        return html.contains("cid:" + id) || html.contains("cid:" + (id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id))
    }

    private static let imageTag = try! NSRegularExpression(pattern: "<img\\b[^>]*>", options: [.caseInsensitive])

    /// The value of `name` in a tag, quoted or not; `data-src` is not `src`.
    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\s\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        for group in 1...3 where match.range(at: group).location != NSNotFound {
            return (tag as NSString).substring(with: match.range(at: group))
        }
        return nil
    }

    /// A message's HTML as the composer's body, its pictures in it again: each picture the HTML
    /// shows from the message's own parts, by cid:, or from a data: URI, as a draft from an
    /// earlier build holds a quoted original's, at the size the HTML gives it. A picture the
    /// message would fetch from the web cannot be held in the body and is left out. Text the
    /// HTML gives no colour or font takes `attributes`, the composer's own. Nil when the HTML
    /// cannot be read.
    ///
    /// AppKit reads HTML through WebKit, which must be on the main thread.
    @MainActor
    public static func text(fromHTML html: String, parts: [MIMEAttachment],
                            attributes: [NSAttributedString.Key: Any]) -> NSAttributedString? {
        var byID: [String: MIMEAttachment] = [:]
        for part in parts {
            guard let id = part.contentID?.lowercased(), byID[id] == nil else { continue }
            byID[id] = part
        }
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var placed: [String: NSTextAttachment] = [:]
        let source = html as NSString
        let marked = NSMutableString(string: html)
        for (index, match) in imageTag.matches(in: html, range: NSRange(location: 0, length: source.length)).enumerated().reversed() {
            let tag = source.substring(with: match.range)
            let src = attribute("src", in: tag)?.trimmed ?? ""
            var data: Data?
            var name: String?
            if src.lowercased().hasPrefix("cid:") {
                let id = String(src.dropFirst(4))
                let part = byID[id.lowercased()] ?? byID[(id.removingPercentEncoding ?? id).lowercased()]
                data = part?.data
                name = part?.filename
            } else if let uri = dataURI.firstMatch(in: src, range: NSRange(location: 0, length: (src as NSString).length)),
                      uri.range.location == 0 {
                data = decodedDataURI(uri, in: src as NSString)
            }
            guard let data, let attachment = attachment(for: data, named: name) else {
                marked.replaceCharacters(in: match.range, with: "")
                continue
            }
            if let width = attribute("width", in: tag).flatMap(Double.init), let height = attribute("height", in: tag).flatMap(Double.init),
               width > 0, height > 0, let natural = NSImage(data: attachment.fileWrapper?.regularFileContents ?? Data())?.size,
               abs(natural.width - width) >= 1 || abs(natural.height - height) >= 1 {
                attachment.bounds = NSRect(x: 0, y: 0, width: width, height: height)
            }
            let token = "FalconMailPicture\(nonce)N\(index)E"
            placed[token] = attachment
            marked.replaceCharacters(in: match.range, with: token)
        }
        guard let read = try? NSMutableAttributedString(data: Data((marked as String).utf8),
                                                        options: [.documentType: NSAttributedString.DocumentType.html,
                                                                  .characterEncoding: String.Encoding.utf8.rawValue],
                                                        documentAttributes: nil) else { return nil }
        // What WebKit made of anything else drawn, such as a picture it could not load, is left
        // out: only the message's own pictures come back.
        for (location, _) in attachmentLocations(in: read).reversed() {
            read.deleteCharacters(in: NSRange(location: location, length: 1))
        }
        for (token, attachment) in placed {
            let range = (read.string as NSString).range(of: token)
            guard range.location != NSNotFound else { continue }
            var own = read.attributes(at: range.location, effectiveRange: nil)
            own[.attachment] = attachment
            read.replaceCharacters(in: range, with: NSAttributedString(string: "\u{FFFC}", attributes: own))
        }
        return ComposedBody.filling(read, with: attributes)
    }

    /// Pasted HTML without the pictures it would fetch from the web, which WebKit would put in
    /// as a stand-in icon.
    public static func withoutRemotePictures(_ html: String) -> String {
        let source = html as NSString
        let output = NSMutableString(string: html)
        for match in imageTag.matches(in: html, range: NSRange(location: 0, length: source.length)).reversed() {
            let src = attribute("src", in: source.substring(with: match.range))?.trimmed.lowercased() ?? ""
            if src.hasPrefix("http:") || src.hasPrefix("https:") || src.hasPrefix("//") || src.hasPrefix("cid:") {
                output.replaceCharacters(in: match.range, with: "")
            }
        }
        return output as String
    }

    // MARK: - Pasting

    /// What a paste puts into a text, from the richest thing on `pasteboard`: RTFD, which holds
    /// pictures; a web archive when its pictures would otherwise be lost, as copying from a web
    /// page or from Word leaves an RTF without them; RTF; HTML; or a picture alone, as a copied
    /// screenshot is. Its pictures are made as `attachment(for:named:)` makes them. Nil when
    /// there is only plain text.
    @MainActor
    public static func pasted(from pasteboard: NSPasteboard) -> NSAttributedString? {
        func read(_ type: NSPasteboard.PasteboardType, as document: NSAttributedString.DocumentType) -> NSAttributedString? {
            guard var data = pasteboard.data(forType: type) else { return nil }
            var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: document]
            if document == .html {
                data = Data(withoutRemotePictures(String(decoding: data, as: UTF8.self)).utf8)
                options[.characterEncoding] = String.Encoding.utf8.rawValue
            }
            guard let text = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else { return nil }
            return normalised(text)
        }
        if let text = read(.rtfd, as: .rtfd), text.length > 0 { return text }
        let rtf = read(.rtf, as: .rtf)
        if !(rtf.map(hasPictures) ?? false) {
            for type in ["com.apple.webarchive", "Apple Web Archive pasteboard type"] {
                if let archive = read(NSPasteboard.PasteboardType(type), as: .webArchive), hasPictures(archive) { return archive }
            }
        }
        if let rtf, rtf.length > 0 { return rtf }
        if let html = read(.html, as: .html), html.length > 0 { return html }
        for type in [NSPasteboard.PasteboardType.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"),
                     NSPasteboard.PasteboardType("com.compuserve.gif"), NSPasteboard.PasteboardType("public.heic")] {
            guard let data = pasteboard.data(forType: type), let attachment = attachment(for: data, named: "image") else { continue }
            return NSAttributedString(attachment: attachment)
        }
        return nil
    }
}
