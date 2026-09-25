import AppKit

/// Pictures a message fetches from the web, as the composer holds them, as Legacy Outlook does:
/// fetched and shown where pictures from the web are loaded for that message, else as an empty
/// box of the size the message gives the picture. The picture's address is never shown as text.
///
/// The box is a picture of its own, a PNG that carries the address and the size the message
/// gave, so that it survives the trip through a draft's RTFD and through copy and paste. What
/// is sent for it is the message's own tag, which fetches the picture from the web as the
/// original did (see ComposedHTML); its PNG is never sent.
public enum RemotePictures {
    /// What an empty box stands for: where the picture lives and the size the message gave it,
    /// either of which it may leave out.
    public struct Placeholder: Equatable, Sendable {
        public var address: String
        public var width: Double?
        public var height: Double?
    }

    /// The widest a picture of no given size, or its box, is shown, as a message's body is laid
    /// out in the composer; a larger one is scaled down to it.
    public static let widest: CGFloat = 640

    /// The box for a picture of no given size.
    static let unsizedBox = NSSize(width: 40, height: 40)

    /// The PNG text chunk that marks a box and says what it stands for.
    private static let keyword = "FalconMail remote picture"

    // MARK: - Addresses

    /// The address a tag's `src` fetches, its entities read and a scheme given to one that
    /// starts with //; nil for anything not fetched from the web over HTTP or HTTPS.
    public static func address(fromSource source: String) -> String? {
        var text = HTMLEntities.decode(source).trimmed
        if text.hasPrefix("//") { text = "https:" + text }
        let lower = text.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        let url = URL(string: text) ?? text.addingPercentEncoding(withAllowedCharacters: addressCharacters).flatMap(URL.init(string:))
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url.absoluteString
    }

    /// The ASCII an address may hold as it is; anything else is percent-encoded.
    private static let addressCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~:/?#[]@!$&'()*+,;=%")

    /// Every picture `html` would fetch from the web and shows, once each, in order. A hidden
    /// picture and a tracking pixel are not among them.
    public static func addresses(inHTML html: String) -> [String] {
        var seen = Set<String>()
        var found: [String] = []
        let source = html as NSString
        for match in InlinePictures.imageTag.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            let tag = source.substring(with: match.range)
            guard let address = InlinePictures.attribute("src", in: tag).flatMap(address(fromSource:)),
                  !InlinePictures.isHidden(tag), seen.insert(address).inserted else { continue }
            found.append(address)
        }
        return found
    }

    /// Every address the boxes in `text` stand for, once each, in order.
    public static func addresses(in text: NSAttributedString) -> [String] {
        var seen = Set<String>()
        return InlinePictures.attachmentLocations(in: text).compactMap { placeholder(of: $0.1)?.address }
            .filter { seen.insert($0).inserted }
    }

    // MARK: - Boxes

    /// An empty box standing for the picture at `address`, as big as `width` and `height` say, a
    /// square when only one is given and a small one when neither is, never wider than `widest`.
    public static func placeholder(for address: String, width: Double?, height: Double?) -> NSTextAttachment {
        let size = boxSize(width: width, height: height)
        let file = FileWrapper(regularFileWithContents: box(size, marking: Placeholder(address: address, width: width, height: height)))
        file.preferredFilename = "Picture.png"
        let attachment = NSTextAttachment(fileWrapper: file)
        attachment.bounds = NSRect(origin: .zero, size: size)
        return attachment
    }

    static func boxSize(width: Double?, height: Double?) -> NSSize {
        var size: NSSize
        switch (width, height) {
        case let (w?, h?): size = NSSize(width: w, height: h)
        case let (w?, nil): size = NSSize(width: w, height: w)
        case let (nil, h?): size = NSSize(width: h, height: h)
        case (nil, nil): size = unsizedBox
        }
        size = NSSize(width: max(1, size.width), height: max(1, size.height))
        return fitted(size)
    }

    /// `size` scaled down to `widest` when it is wider.
    static func fitted(_ size: NSSize) -> NSSize {
        guard size.width > widest else { return size }
        return NSSize(width: widest, height: max(1, (size.height * widest / size.width).rounded()))
    }

    /// What an attachment's box stands for; nil for a picture.
    public static func placeholder(of attachment: NSTextAttachment) -> Placeholder? {
        guard let file = attachment.fileWrapper, file.isRegularFile, let data = file.regularFileContents else { return nil }
        return placeholder(in: data)
    }

    /// The box's mark, read from its PNG's text chunks.
    static func placeholder(in data: Data) -> Placeholder? {
        guard InlinePictures.format(of: data) == .png else { return nil }
        let bytes = [UInt8](data)
        var offset = 8
        while offset + 12 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            let start = offset + 8
            guard length >= 0, start + length + 4 <= bytes.count else { return nil }
            if type == "IEND" { return nil }
            if type == "tEXt" {
                let chunk = bytes[start..<(start + length)]
                if let zero = chunk.firstIndex(of: 0),
                   String(decoding: chunk[chunk.startIndex..<zero], as: UTF8.self) == keyword {
                    return parse(String(decoding: chunk[(zero + 1)...], as: UTF8.self))
                }
            }
            offset = start + length + 4
        }
        return nil
    }

    /// "width height address", a size not given written as -.
    private static func text(of mark: Placeholder) -> String {
        func number(_ value: Double?) -> String { value.map { String(format: "%g", $0) } ?? "-" }
        return "\(number(mark.width)) \(number(mark.height)) \(mark.address)"
    }

    private static func parse(_ text: String) -> Placeholder? {
        let fields = text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3, !fields[2].isEmpty else { return nil }
        return Placeholder(address: String(fields[2]), width: Double(fields[0]), height: Double(fields[1]))
    }

    /// The box drawn at twice its size, a faint ground inside a thin line, with a picture's
    /// symbol in its corner when there is room, and its mark.
    private static func box(_ size: NSSize, marking mark: Placeholder) -> Data {
        let scale: CGFloat = 2
        let pixels = (max(1, Int((size.width * scale).rounded())), max(1, Int((size.height * scale).rounded())))
        var png = Data()
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels.0, pixelsHigh: pixels.1, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0) {
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            let frame = NSRect(origin: .zero, size: size)
            NSColor(white: 0.5, alpha: 0.08).setFill()
            frame.fill()
            if size.width >= 3, size.height >= 3 {
                NSColor(white: 0.5, alpha: 0.55).setStroke()
                let line = NSBezierPath(rect: frame.insetBy(dx: 0.5, dy: 0.5))
                line.lineWidth = 1
                line.stroke()
            }
            if size.width >= 24, size.height >= 20,
               let symbol = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .regular)) {
                let tinted = NSImage(size: symbol.size, flipped: false) { rect in
                    symbol.draw(in: rect)
                    NSColor(white: 0.5, alpha: 0.8).set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: 5, y: size.height - symbol.size.height - 5, width: symbol.size.width, height: symbol.size.height))
            }
            NSGraphicsContext.restoreGraphicsState()
            png = rep.representation(using: .png, properties: [:]) ?? Data()
        }
        return marked(png, with: text(of: mark))
    }

    /// `png` with a tEXt chunk holding `text` under the box's keyword, before its end.
    private static func marked(_ png: Data, with text: String) -> Data {
        guard png.count >= 20, InlinePictures.format(of: png) == .png else { return png }
        var body = Data(keyword.utf8)
        body.append(0)
        body.append(Data(text.utf8))
        var chunk = Data()
        let length = UInt32(body.count)
        chunk.append(contentsOf: [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        var typed = Data("tEXt".utf8)
        typed.append(body)
        chunk.append(typed)
        let crc = CRC32.checksum(typed)
        chunk.append(contentsOf: [UInt8(crc >> 24), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)])
        var output = png
        // IEND is the last twelve bytes of every PNG.
        output.insert(contentsOf: chunk, at: output.count - 12)
        return output
    }

    /// The tag a box is sent as: the picture from its address, at the size the original gave
    /// it.
    static func tag(for mark: Placeholder) -> String {
        var tag = "<img"
        var style: [String] = []
        if let width = mark.width.map({ Int($0.rounded()) }) {
            tag += " width=\"\(width)\""
            style.append("width:\(width)px")
        }
        if let height = mark.height.map({ Int($0.rounded()) }) {
            tag += " height=\"\(height)\""
            style.append("height:\(height)px")
        }
        if !style.isEmpty { tag += " style=\"\(style.joined(separator: ";"))\"" }
        return tag + " src=\"\(HTMLText.escape(mark.address))\">"
    }

    // MARK: - Putting the pictures in

    /// The picture fetched for a box, as `InlinePictures.attachment(for:named:)` makes one, at
    /// the size the message gave it: both sides as given, one side with the other in
    /// proportion, or, with neither, its own size, never wider than `widest`.
    static func picture(_ data: Data, for mark: Placeholder) -> NSTextAttachment? {
        guard let attachment = InlinePictures.attachment(for: data, named: filename(for: mark.address)) else { return nil }
        let natural = NSImage(data: attachment.fileWrapper?.regularFileContents ?? Data())?.size ?? .zero
        if let size = InlinePictures.shownSize(width: mark.width, height: mark.height, natural: natural, fitting: true) {
            InlinePictures.show(attachment, at: size)
        }
        return attachment
    }

    /// The name the picture's file takes: the last part of its address, else Picture.
    static func filename(for address: String) -> String? {
        let name = URL(string: address)?.lastPathComponent ?? ""
        return name.isEmpty || name == "/" ? nil : name
    }

    /// `text` with each box whose picture is in `fetched`, by address, holding that picture in
    /// its place, with its formatting and any link on it. Returns whether any was put in.
    @discardableResult
    public static func fill(_ text: NSMutableAttributedString, with fetched: [String: Data]) -> Bool {
        guard !fetched.isEmpty else { return false }
        var made: [String: NSTextAttachment] = [:]
        var changed = false
        text.beginEditing()
        for (location, attachment) in InlinePictures.attachmentLocations(in: text) {
            guard let mark = placeholder(of: attachment), let data = fetched[mark.address] else { continue }
            // One picture shown in several places at one size is one attachment, as a pasted
            // text has it.
            let key = RemotePictures.text(of: mark)
            guard let picture = made[key] ?? self.picture(data, for: mark) else { continue }
            made[key] = picture
            text.addAttribute(.attachment, value: picture, range: NSRange(location: location, length: 1))
            changed = true
        }
        text.endEditing()
        return changed
    }

    /// The same in a text view the owner may be typing in: the text keeps its length, so the
    /// selection stays where it is, and the change is reported as the view's own, so what is
    /// kept of it follows; it is not a step Undo takes back.
    @MainActor
    @discardableResult
    public static func fill(_ editor: NSTextView, with fetched: [String: Data]) -> Bool {
        guard let storage = editor.textStorage else { return false }
        let selection = editor.selectedRanges
        guard fill(storage, with: fetched) else { return false }
        editor.selectedRanges = selection
        editor.didChangeText()
        return true
    }
}

/// Fetches the pictures a quoted original or a pasted signature shows from the web, when the
/// owner lets pictures from the web load. Nothing is kept on disk: no cache, no cookies, no
/// credentials, and a picture larger than `largest`, or a response that is no picture, is
/// dropped. Tests give it a loader of their own and never reach the network.
public struct RemotePictureLoader: Sendable {
    public typealias Load = @Sendable (URL) async throws -> Data

    /// The most one picture may hold.
    public static let largest = 10 * 1024 * 1024
    /// The most pictures fetched for one text; a message holding more keeps boxes for the rest.
    public static let most = 40

    private let load: Load

    public init(load: @escaping Load) {
        self.load = load
    }

    /// Fetches over an ephemeral session, which keeps nothing on disk.
    public static let web = RemotePictureLoader(session: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }())

    public init(session: URLSession) {
        self.init { url in
            var request = URLRequest(url: url)
            request.setValue("image/png,image/jpeg,image/gif,image/*;q=0.8", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            if response.expectedContentLength > Int64(RemotePictureLoader.largest) { throw URLError(.dataLengthExceedsMaximum) }
            var data = Data()
            if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
            for try await byte in bytes {
                data.append(byte)
                if data.count > RemotePictureLoader.largest { throw URLError(.dataLengthExceedsMaximum) }
            }
            return data
        }
    }

    /// The pictures at `addresses` that could be fetched, by address, each as it came. An
    /// address not over HTTP or HTTPS is never fetched.
    public func fetch(_ addresses: [String]) async -> [String: Data] {
        var seen = Set<String>()
        let wanted = addresses.filter { seen.insert($0).inserted }.prefix(RemotePictureLoader.most).compactMap { address -> (String, URL)? in
            guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                return nil
            }
            return (address, url)
        }
        guard !wanted.isEmpty else { return [:] }
        let load = self.load
        return await withTaskGroup(of: (String, Data?).self) { group in
            for (address, url) in wanted {
                group.addTask {
                    guard let data = try? await load(url), data.count <= RemotePictureLoader.largest,
                          InlinePictures.sendable(data) != nil else { return (address, nil) }
                    return (address, data)
                }
            }
            var fetched: [String: Data] = [:]
            for await (address, data) in group {
                if let data { fetched[address] = data }
            }
            return fetched
        }
    }
}

/// The character references an HTML attribute may hold.
enum HTMLEntities {
    private static let named: [String: String] = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">", "nbsp": "\u{00A0}"]
    private static let reference = try! NSRegularExpression(pattern: "&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);")

    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let source = text as NSString
        let output = NSMutableString(string: text)
        for match in reference.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let name = source.substring(with: match.range(at: 1))
            var value: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                value = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if name.hasPrefix("#") {
                value = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                value = named[name.lowercased()]
            }
            if let value { output.replaceCharacters(in: match.range, with: value) }
        }
        return output as String
    }
}
