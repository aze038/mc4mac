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

    static let imageTag = try! NSRegularExpression(pattern: "<img\\b[^>]*>", options: [.caseInsensitive])

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

    /// The size a tag gives its picture, in points, from its style, as a browser reads it
    /// first, else from its width and height; either may be missing. A size given in anything
    /// but pixels, such as a percentage, is taken as not given.
    static func givenSize(of tag: String) -> (width: Double?, height: Double?) {
        let style = attribute("style", in: tag).map(HTMLEntities.decode) ?? ""
        func fromStyle(_ name: String) -> Double? {
            let pattern = "(?<![-\\w])\(name)\\s*:\\s*([0-9]+(?:\\.[0-9]+)?)\\s*(px)?\\s*(?:;|$|!)"
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = expression.firstMatch(in: style, range: NSRange(location: 0, length: (style as NSString).length)) else { return nil }
            return Double((style as NSString).substring(with: match.range(at: 1)))
        }
        func fromAttribute(_ name: String) -> Double? {
            guard let value = attribute(name, in: tag)?.trimmed.lowercased(), !value.hasSuffix("%") else { return nil }
            return Double(value.hasSuffix("px") ? String(value.dropLast(2)) : value)
        }
        return (fromStyle("width") ?? fromAttribute("width"), fromStyle("height") ?? fromAttribute("height"))
    }

    /// Whether a tag's picture is never seen: hidden by its style, given no room, or a pixel
    /// or two across, as the tracking pictures of mailing lists are.
    static func isHidden(_ tag: String) -> Bool {
        let style = (attribute("style", in: tag) ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        if style.contains("display:none") || style.contains("visibility:hidden") { return true }
        let size = givenSize(of: tag)
        if size.width == 0 || size.height == 0 { return true }
        if let width = size.width, let height = size.height, width <= 2, height <= 2 { return true }
        return false
    }

    /// The size to show a picture at when its tag gives `width` and `height`: both sides as
    /// given, or one side with the other in proportion to `natural`. Nil when the picture is
    /// shown at its own size, as it is with neither, or with a size that is its own; with
    /// `fitting`, a picture wider than RemotePictures.widest is scaled down to it.
    static func shownSize(width: Double?, height: Double?, natural: NSSize, fitting: Bool) -> NSSize? {
        var size: NSSize
        switch (width, height) {
        case let (w?, h?) where w > 0 && h > 0: size = NSSize(width: w, height: h)
        case let (w?, _) where w > 0 && natural.width > 0: size = NSSize(width: w, height: (natural.height * w / natural.width).rounded())
        case let (_, h?) where h > 0 && natural.height > 0: size = NSSize(width: (natural.width * h / natural.height).rounded(), height: h)
        default: size = natural
        }
        if fitting { size = RemotePictures.fitted(size) }
        guard size.width > 0, size.height > 0 else { return nil }
        return abs(natural.width - size.width) >= 1 || abs(natural.height - size.height) >= 1 ? size : nil
    }

    /// Shows `attachment`'s picture at `size`. A draft's RTFD keeps no size of its own for a
    /// picture, only the one its file declares, so a PNG's or JPEG's file is made to declare
    /// `size` by the resolution it states; not a pixel of it changes. A GIF declares none and
    /// shows at its own size once the draft is read back.
    static func show(_ attachment: NSTextAttachment, at size: NSSize) {
        if let data = attachment.fileWrapper?.regularFileContents, let declared = declaring(size, in: data) {
            let file = FileWrapper(regularFileWithContents: declared)
            file.preferredFilename = attachment.fileWrapper?.preferredFilename
            attachment.fileWrapper = file
        }
        attachment.bounds = NSRect(origin: .zero, size: size)
    }

    /// `data`, a PNG or JPEG, stating the resolution at which its pixels are `size` points big;
    /// nil when it cannot be made to, as for a GIF or a JPEG without a JFIF header.
    static func declaring(_ size: NSSize, in data: Data) -> Data? {
        guard size.width > 0, size.height > 0, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let wide = properties[kCGImagePropertyPixelWidth] as? Int, let high = properties[kCGImagePropertyPixelHeight] as? Int,
              wide > 0, high > 0 else { return nil }
        let dpi = (Double(wide) / Double(size.width) * 72, Double(high) / Double(size.height) * 72)
        let declared: Data?
        switch format(of: data) {
        case .png?: declared = png(data, dpi: dpi)
        case .jpeg?: declared = jpeg(data, dpi: dpi)
        default: declared = nil
        }
        guard let declared, let shown = NSImage(data: declared)?.size,
              abs(shown.width - size.width) < 0.5, abs(shown.height - size.height) < 0.5 else { return nil }
        return declared
    }

    /// A PNG with its pHYs chunk, in pixels a metre, saying `dpi`, just after its header.
    private static func png(_ data: Data, dpi: (Double, Double)) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 33 else { return nil }
        var output = Array(bytes[0..<33])
        var offset = 33
        while offset + 12 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let end = offset + 12 + length
            guard length >= 0, end <= bytes.count else { return nil }
            if String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self) != "pHYs" {
                output.append(contentsOf: bytes[offset..<end])
            }
            offset = end
        }
        func big(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        let perMetre = { (value: Double) in UInt32(max(1, min(Double(UInt32.max), (value / 0.0254).rounded()))) }
        let typed = Array("pHYs".utf8) + big(perMetre(dpi.0)) + big(perMetre(dpi.1)) + [1]
        let chunk = big(9) + typed + big(CRC32.checksum(Data(typed)))
        output.insert(contentsOf: chunk, at: 33)
        return Data(output)
    }

    /// A JPEG saying `dpi` wherever it states a resolution: in its JFIF header, and in the TIFF
    /// tags of its Exif block, which ImageIO reads before the JFIF header, as a picture saved by
    /// Word or taken by a camera has one. A JPEG that states none is given a JFIF header. Nil
    /// for what is not laid out as a JPEG.
    private static func jpeg(_ data: Data, dpi: (Double, Double)) -> Data? {
        var bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        let x = UInt16(max(1, min(65_535, dpi.0.rounded()))), y = UInt16(max(1, min(65_535, dpi.1.rounded())))
        var stated = false
        var offset = 2
        // The segments before the picture's own data, each a marker and a length that counts
        // itself.
        while offset + 4 <= bytes.count, bytes[offset] == 0xFF {
            let marker = bytes[offset + 1]
            if marker == 0xDA || marker == 0xD9 { break }
            let length = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let start = offset + 4, end = offset + 2 + length
            guard length >= 2, end <= bytes.count else { return nil }
            if marker == 0xE0, end - start >= 12, Array(bytes[start..<(start + 5)]) == Array("JFIF\0".utf8) {
                bytes[start + 7] = 1
                bytes[start + 8] = UInt8(x >> 8); bytes[start + 9] = UInt8(x & 0xFF)
                bytes[start + 10] = UInt8(y >> 8); bytes[start + 11] = UInt8(y & 0xFF)
                stated = true
            } else if marker == 0xE1, end - start >= 14, Array(bytes[start..<(start + 6)]) == Array("Exif\0\0".utf8) {
                if exifResolution(&bytes, tiff: start + 6, end: end, dpi: dpi) { stated = true }
            }
            offset = end
        }
        if !stated {
            let header: [UInt8] = [0xFF, 0xE0, 0x00, 0x10] + Array("JFIF\0".utf8) + [1, 1, 1, UInt8(x >> 8), UInt8(x & 0xFF),
                                                                                 UInt8(y >> 8), UInt8(y & 0xFF), 0, 0]
            bytes.insert(contentsOf: header, at: 2)
        }
        return Data(bytes)
    }

    /// Sets the XResolution, YResolution and ResolutionUnit tags of the first image of the TIFF
    /// block at `tiff`, in either byte order, where it has them. Returns whether it states a
    /// resolution now.
    private static func exifResolution(_ bytes: inout [UInt8], tiff: Int, end: Int, dpi: (Double, Double)) -> Bool {
        let little: Bool
        switch (bytes[tiff], bytes[tiff + 1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return false
        }
        func read(_ at: Int, _ size: Int) -> Int? {
            guard at >= tiff, at + size <= end else { return nil }
            var value = 0
            for index in 0..<size {
                value |= Int(bytes[at + index]) << (8 * (little ? index : size - 1 - index))
            }
            return value
        }
        func write(_ value: Int, _ at: Int, _ size: Int) {
            guard at >= tiff, at + size <= end else { return }
            for index in 0..<size {
                bytes[at + index] = UInt8(truncatingIfNeeded: value >> (8 * (little ? index : size - 1 - index)))
            }
        }
        guard let first = read(tiff + 4, 4), let count = read(tiff + first, 2) else { return false }
        var found = 0
        for entry in 0..<count {
            let at = tiff + first + 2 + entry * 12
            guard let tag = read(at, 2), let type = read(at + 2, 2) else { return false }
            switch (tag, type) {
            case (0x011A, 5), (0x011B, 5):
                guard let place = read(at + 8, 4), tiff + place + 8 <= end else { continue }
                let value = tag == 0x011A ? dpi.0 : dpi.1
                write(Int(max(1, min(4_000_000, (value * 1000).rounded()))), tiff + place, 4)
                write(1000, tiff + place + 4, 4)
                found += 1
            case (0x0128, 3):
                write(2, at + 8, 2)
            default:
                continue
            }
        }
        return found == 2
    }

    /// A message's HTML as the composer's body, its pictures in it again: each picture the HTML
    /// shows from the message's own parts, by cid:, or from a data: URI, as a draft from an
    /// earlier build holds a quoted original's, at the size the HTML gives it. Text the HTML
    /// gives no colour or font takes `attributes`, the composer's own. Nil when the HTML cannot
    /// be read.
    ///
    /// A picture the message would fetch from the web is left out, unless `remote` is given, as
    /// for a quoted original, a signature or a draft opened again: it is then the picture
    /// `remote` holds for its address, else an empty box of the size the HTML gives it that
    /// remembers the address (see RemotePictures). With `fitting`, which is the default when
    /// `remote` is given, a picture too wide for the composer is scaled down to fit; a draft
    /// opened again keeps the size it was sent at. A hidden picture or a tracking pixel is
    /// always left out. Nothing is fetched from the web while the HTML is read.
    ///
    /// AppKit reads HTML through WebKit, which must be on the main thread.
    @MainActor
    public static func text(fromHTML html: String, parts: [MIMEAttachment],
                            attributes: [NSAttributedString.Key: Any], remote: [String: Data]? = nil,
                            fitting: Bool? = nil) -> NSAttributedString? {
        let fitting = fitting ?? (remote != nil)
        var byID: [String: MIMEAttachment] = [:]
        for part in parts {
            guard let id = part.contentID?.lowercased(), byID[id] == nil else { continue }
            byID[id] = part
        }
        let html = withoutFetching(html)
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var placed: [String: NSTextAttachment] = [:]
        let source = html as NSString
        let marked = NSMutableString(string: html)
        for (index, match) in imageTag.matches(in: html, range: NSRange(location: 0, length: source.length)).enumerated().reversed() {
            let tag = source.substring(with: match.range)
            let src = attribute("src", in: tag)?.trimmed ?? ""
            var data: Data?
            var name: String?
            var attachment: NSTextAttachment?
            let given = givenSize(of: tag)
            if isHidden(tag) {
                attachment = nil
            } else if src.lowercased().hasPrefix("cid:") {
                let id = String(src.dropFirst(4))
                let part = byID[id.lowercased()] ?? byID[(id.removingPercentEncoding ?? id).lowercased()]
                data = part?.data
                name = part?.filename
            } else if let uri = dataURI.firstMatch(in: src, range: NSRange(location: 0, length: (src as NSString).length)),
                      uri.range.location == 0 {
                data = decodedDataURI(uri, in: src as NSString)
            } else if let remote, let address = RemotePictures.address(fromSource: src) {
                let mark = RemotePictures.Placeholder(address: address, width: given.width, height: given.height)
                attachment = remote[address].flatMap { RemotePictures.picture($0, for: mark) }
                    ?? RemotePictures.placeholder(for: address, width: given.width, height: given.height)
            }
            if let data, let made = self.attachment(for: data, named: name) {
                let natural = NSImage(data: made.fileWrapper?.regularFileContents ?? Data())?.size ?? .zero
                if let size = shownSize(width: given.width, height: given.height, natural: natural, fitting: fitting) {
                    show(made, at: size)
                }
                attachment = made
            }
            guard let attachment else {
                marked.replaceCharacters(in: match.range, with: "")
                continue
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

    private static let fetchingElements = try! NSRegularExpression(
        pattern: "(?is)<(script|iframe|object|video|audio|noscript)\\b[^>]*>.*?</\\1\\s*>|<(script|iframe|object|embed|video|audio|source|track|link|meta|base|input|frame|frameset|applet)\\b[^>]*>")
    private static let backgroundAttribute = try! NSRegularExpression(
        pattern: "(?i)\\s(background|poster|srcset|lowsrc|dynsrc)\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s>]+)")
    private static let remoteURL = try! NSRegularExpression(
        pattern: "(?i)url\\(\\s*(?:&quot;|[\"'])?\\s*(?:https?:)?//[^)]*\\)")
    private static let remoteImport = try! NSRegularExpression(pattern: "(?i)@import[^;]*;?")

    /// `html` with nothing left that WebKit would fetch while reading it or run: scripts,
    /// frames, embedded players, style sheets and fonts linked from the web, and pictures set
    /// behind text by an attribute or by CSS. What it says and how it is laid out stay.
    static func withoutFetching(_ html: String) -> String {
        var output = html
        for expression in [fetchingElements, backgroundAttribute, remoteImport] {
            output = expression.stringByReplacingMatches(in: output, range: NSRange(location: 0, length: (output as NSString).length),
                                                         withTemplate: "")
        }
        return remoteURL.stringByReplacingMatches(in: output, range: NSRange(location: 0, length: (output as NSString).length),
                                                  withTemplate: "none")
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
    ///
    /// With `keepingRemotePictures`, as the signature editor pastes, HTML keeps the pictures it
    /// would fetch from the web as boxes that remember their addresses, for the editor to fetch
    /// and put in (see RemotePictures); otherwise they are left out.
    @MainActor
    public static func pasted(from pasteboard: NSPasteboard, keepingRemotePictures: Bool = false) -> NSAttributedString? {
        func read(_ type: NSPasteboard.PasteboardType, as document: NSAttributedString.DocumentType) -> NSAttributedString? {
            if document == .html, keepingRemotePictures {
                guard let data = pasteboard.data(forType: type) else { return nil }
                return text(fromHTML: String(decoding: data, as: UTF8.self), parts: [], attributes: [:], remote: [:])
            }
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
