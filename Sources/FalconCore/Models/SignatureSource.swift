import AppKit

/// A signature's own HTML, as its owner made it in Gmail or on a web page, kept beside the rich
/// text the composer shows, so that what is sent is that HTML exactly: its tables, widths,
/// padding, fonts, colours and the size it gives each picture, whatever the composer's text can
/// hold of them. The rich text is only what is shown; while a message's body still holds it as
/// it was put in, the source goes out in its place (see ComposedHTML), each picture it shows
/// sent as an inline part by cid:, and nothing else in it changed.
public struct SignatureSource: Sendable, Hashable {
    /// The HTML fragment, as the owner made it.
    public var html: String
    /// The text the source reads as, without its spaces, line breaks and pictures, by which it
    /// is recognised in a message's body however that text has been kept.
    public var skeleton: String
    /// How many pictures the text shows.
    public var pictures: Int
    /// What of the text's formatting a trip through a draft keeps, its words bold, italic or
    /// linked, character by character of the skeleton, so that a
    /// signature made bold or linked in a message is known as changed.
    public var emphasis: String

    /// The source `html` for the signature `text`, as it was read from that HTML.
    public init(html: String, text: NSAttributedString) {
        self.html = html
        skeleton = SignatureSource.skeleton(of: text.string)
        pictures = InlinePictures.attachmentLocations(in: text).count
        emphasis = SignatureSource.emphasis(of: text, in: NSRange(location: 0, length: text.length))
    }

    /// Whether `text` still says exactly what the source says, with as many pictures and the same
    /// emphasis: it has not been edited, whatever else became of its formatting on the way.
    public func matches(_ text: NSAttributedString) -> Bool {
        !skeleton.isEmpty && SignatureSource.skeleton(of: text.string) == skeleton
            && InlinePictures.attachmentLocations(in: text).count == pictures
            && SignatureSource.emphasis(of: text, in: NSRange(location: 0, length: text.length)) == emphasis
    }

    /// For each character of `range` that is not loose, a letter for its emphasis, and for each
    /// link where it starts, its address.
    static func emphasis(of text: NSAttributedString, in range: NSRange) -> String {
        let string = text.string as NSString
        var output = ""
        var lastLink: String?
        let manager = NSFontManager.shared
        text.enumerateAttributes(in: range) { attributes, run, _ in
            var code = 0
            if let font = attributes[.font] as? NSFont {
                let traits = manager.traits(of: font)
                if traits.contains(.boldFontMask) { code |= 1 }
                if traits.contains(.italicFontMask) { code |= 2 }
            }
            let link = attributes[.link].map { ($0 as? URL)?.absoluteString ?? "\($0)" }
            for index in run.location..<NSMaxRange(run) {
                let unit = string.character(at: index)
                if !UTF16.isLeadSurrogate(unit), !UTF16.isTrailSurrogate(unit), isLoose(unit: unit) { continue }
                if UTF16.isTrailSurrogate(unit) { continue }
                if link != lastLink {
                    output += "[\(link ?? "")]"
                    lastLink = link
                }
                output += String(UnicodeScalar(UInt8(65 + code)))
            }
        }
        return output
    }

    // MARK: - What can be sent as it is

    private static let refused = try! NSRegularExpression(
        pattern: "(?is)<(script|iframe|object|embed|video|audio|frame|frameset|applet|form|input|textarea|button|link|base|style|xml)\\b|<!--\\[if|\\bmso-|<o:p\\b|<v:")
    private static let head = try! NSRegularExpression(pattern: "(?is)<head\\b[^>]*>(.*?)</head\\s*>")
    private static let bodyStart = try! NSRegularExpression(pattern: "(?is)<body\\b[^>]*>")
    private static let bodyEnd = try! NSRegularExpression(pattern: "(?is)</body\\s*>")
    private static let wrapper = try! NSRegularExpression(
        pattern: "(?is)<!doctype[^>]*>|</?html\\b[^>]*>|<meta\\b[^>]*>|<title\\b[^>]*>.*?</title\\s*>|<!--\\s*(?:Start|End)Fragment\\s*-->")

    /// The fragment of `html` a signature is made of, as Gmail keeps a signature and a browser
    /// copies one, else nil for what should not be sent as it is: HTML from Word or Outlook,
    /// whose look lives in a style sheet and in conditional comments, or anything that would run,
    /// take input or fetch more than pictures. Only what wraps the fragment is taken off: a
    /// document's doctype, html, head and body tags and a browser's fragment marks.
    public static func sendable(_ html: String) -> String? {
        var text = html
        func whole() -> NSRange { NSRange(location: 0, length: (text as NSString).length) }
        if let head = head.firstMatch(in: text, range: whole()) {
            // A head of more than a character set and a title says how the page looks.
            let inside = (text as NSString).substring(with: head.range(at: 1))
            let rest = wrapper.stringByReplacingMatches(in: inside, range: NSRange(location: 0, length: (inside as NSString).length),
                                                        withTemplate: "")
            guard rest.trimmed.isEmpty else { return nil }
            text = (text as NSString).replacingCharacters(in: head.range, with: "")
        }
        if let start = bodyStart.firstMatch(in: text, range: whole()) {
            text = (text as NSString).substring(from: NSMaxRange(start.range))
            if let end = bodyEnd.firstMatch(in: text, range: whole()) { text = (text as NSString).substring(to: end.range.location) }
        }
        text = wrapper.stringByReplacingMatches(in: text, range: whole(), withTemplate: "").trimmed
        guard !text.isEmpty, refused.firstMatch(in: text, range: whole()) == nil,
              looksLikeHTML(text) else { return nil }
        return text
    }

    private static func looksLikeHTML(_ text: String) -> Bool {
        text.range(of: "<[A-Za-z]", options: .regularExpression) != nil
    }

    // MARK: - Sending it

    private static let srcValue = try! NSRegularExpression(pattern: "(?i)\\ssrc\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))")

    /// Where the value of a tag's src lies in it.
    static func srcRange(in tag: String) -> NSRange? {
        guard let match = srcValue.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        for group in 1...3 where match.range(at: group).location != NSNotFound { return match.range(at: group) }
        return nil
    }

    /// Each tag of `html` that reading it made a picture of, as InlinePictures.text(fromHTML:)
    /// does: one not hidden, shown by cid:, from a data: URI or from the web.
    static func shownPictureTags(in html: String) -> [NSRange] {
        let source = html as NSString
        return InlinePictures.imageTag.matches(in: html, range: NSRange(location: 0, length: source.length)).compactMap { match in
            let tag = source.substring(with: match.range)
            guard !InlinePictures.isHidden(tag), let src = InlinePictures.attribute("src", in: tag)?.trimmed.lowercased() else { return nil }
            let shown = src.hasPrefix("cid:") || src.hasPrefix("data:") || RemotePictures.address(fromSource: src) != nil
            return shown ? match.range : nil
        }
    }

    /// The source as it goes into a message, from `shown`, the signature as the body holds it:
    /// each picture the body holds for one of the source's pictures, in order, is sent once as
    /// an inline part, and the tag's src alone becomes its cid:; a picture from the web that was
    /// not fetched keeps its address, as Gmail sends it. Nothing else in the HTML changes. Also
    /// what the plain text says for each of the body's pictures, in turn. Nil when the body's
    /// pictures do not pair with the source's, which is then not sent as it is.
    static func sending(_ html: String, shown: NSAttributedString,
                        into pictures: inout InlinePictures.Collector) -> (html: String, marks: [String])? {
        let tags = shownPictureTags(in: html)
        let located = InlinePictures.attachmentLocations(in: shown)
        guard tags.count == located.count else { return nil }
        var collected = pictures
        var replacements: [(NSRange, String)] = []
        var marks: [String] = []
        let source = html as NSString
        for (tagRange, (_, attachment)) in zip(tags, located) {
            let tag = source.substring(with: tagRange)
            guard let src = srcRange(in: tag) else { return nil }
            let value = (tag as NSString).substring(with: src).trimmed
            if let box = RemotePictures.placeholder(of: attachment) {
                // Not fetched: sent from its address, as the source has it, which must be the
                // box's own, or this is another signature of the same words.
                guard RemotePictures.address(fromSource: value) == box.address else { return nil }
                marks.append("")
                continue
            }
            guard let picture = InlinePictures.picture(in: attachment) else { return nil }
            let sent = collected.add(picture.data, picture.format)
            replacements.append((NSRange(location: tagRange.location + src.location, length: src.length), "cid:\(sent.contentID)"))
            marks.append(InlinePictures.plainMark(for: sent))
        }
        let output = NSMutableString(string: html)
        for (range, value) in replacements.reversed() { output.replaceCharacters(in: range, with: value) }
        pictures = collected
        return (output as String, marks)
    }

    // MARK: - Recognising it

    /// A text without what writing it down and reading it back may change: spaces, line breaks,
    /// pictures and invisible marks.
    static func skeleton(of text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !isLoose($0) }))
    }

    static func isLoose(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value == 0xFFFC || scalar.value == 0 { return true }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar) { return true }
        switch scalar.value {
        case 0x200B...0x200F, 0x2028...0x202E, 0x2060...0x206F, 0xFEFF: return true
        default: return false
        }
    }

    static func isLoose(unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return isLoose(scalar)
    }

    /// Where the signature lies in `text`, in UTF-16 units: from the start of the paragraph its
    /// first word or picture is in to the end of the one its last is in, holding its words
    /// unedited and exactly its pictures; nil when `text` does not hold it so.
    func range(in text: NSAttributedString) -> NSRange? {
        guard !skeleton.isEmpty else { return nil }
        let string = text.string as NSString
        var units: [unichar] = []
        var offsets: [Int] = []
        for index in 0..<string.length {
            let unit = string.character(at: index)
            if !UTF16.isLeadSurrogate(unit), !UTF16.isTrailSurrogate(unit), SignatureSource.isLoose(unit: unit) { continue }
            units.append(unit)
            offsets.append(index)
        }
        let wanted = Array(skeleton.utf16)
        guard !wanted.isEmpty, wanted.count <= units.count else { return nil }
        let pictureLocations = InlinePictures.attachmentLocations(in: text).map(\.0)
        var start = 0
        while start + wanted.count <= units.count {
            defer { start += 1 }
            guard units[start] == wanted[0], Array(units[start..<(start + wanted.count)]) == wanted else { continue }
            let first = offsets[start], last = offsets[start + wanted.count - 1] + 1
            guard SignatureSource.emphasis(of: text, in: NSRange(location: first, length: last - first)) == emphasis,
                  let range = widened(first: first, last: last, in: string, pictures: pictureLocations),
                  SignatureSource.followsSignatureLine(range.location, in: string) else { continue }
            return range
        }
        return nil
    }

    /// Whether the paragraph before `location` is the "-- " line every signature is put into a
    /// message under (see Signature.block), so the same words typed in the message are never
    /// taken for it.
    static func followsSignatureLine(_ location: Int, in string: NSString) -> Bool {
        guard location > 0 else { return false }
        let previous = string.paragraphRange(for: NSRange(location: location - 1, length: 0))
        return string.substring(with: previous).trimmed == "--"
    }

    /// The words from `first` to `last` widened over the loose characters around them to take
    /// in the pictures the signature shows before its first word and after its last, as a logo
    /// in a table's first cell is, then to whole paragraphs.
    private func widened(first: Int, last: Int, in string: NSString, pictures located: [Int]) -> NSRange? {
        let inside = located.filter { $0 >= first && $0 < last }.count
        guard inside <= pictures else { return nil }
        var missing = pictures - inside
        var start = first, end = last
        // Before the first word first, where a signature's logo usually is.
        var probe = start
        while missing > 0, probe > 0, SignatureSource.isLoose(unit: string.character(at: probe - 1)) {
            probe -= 1
            if located.contains(probe) {
                missing -= 1
                start = probe
            }
        }
        probe = end
        while missing > 0, probe < string.length, SignatureSource.isLoose(unit: string.character(at: probe)) {
            if located.contains(probe) {
                missing -= 1
                end = probe + 1
            }
            probe += 1
        }
        guard missing == 0 else { return nil }
        let from = string.paragraphRange(for: NSRange(location: start, length: 0)).location
        let to = NSMaxRange(string.paragraphRange(for: NSRange(location: end - 1, length: 0)))
        let range = NSRange(location: from, length: to - from)
        guard located.filter({ NSLocationInRange($0, range) }).count == pictures else { return nil }
        return range
    }
}

/// The sources of the signatures this run knows, which a message's body is searched for as it is
/// sent. Every signature with a source is known here once the signatures are loaded or it is put
/// into a message, so a draft opened again after a relaunch still sends its signature's source.
public enum SignatureSources {
    private static let lock = NSLock()
    private static var known: [String: SignatureSource] = [:]

    public static func register(_ source: SignatureSource?) {
        guard let source, !source.skeleton.isEmpty else { return }
        lock.withLock { known[source.html + "\u{0}" + source.emphasis] = source }
    }

    public static func register(_ signatures: [Signature]) {
        for signature in signatures where signature.html != nil { register(signature.source) }
    }

    /// Every known source, the longest first, so a signature that holds a shorter one is found
    /// before it.
    public static var all: [SignatureSource] {
        lock.withLock { Array(known.values) }.sorted {
            $0.skeleton.utf16.count != $1.skeleton.utf16.count ? $0.skeleton.utf16.count > $1.skeleton.utf16.count
                : $0.html != $1.html ? $0.html < $1.html : $0.emphasis < $1.emphasis
        }
    }

    /// Each of `sources` that `text` holds unedited, and where, in the order given.
    static func found(_ sources: [SignatureSource], in text: NSAttributedString) -> [(source: SignatureSource, range: NSRange)] {
        sources.compactMap { source in source.range(in: text).map { (source, $0) } }
    }
}
