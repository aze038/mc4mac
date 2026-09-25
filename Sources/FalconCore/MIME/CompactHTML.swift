import AppKit

/// The composer's text as HTML the way Outlook writes it: paragraphs with no margin, the
/// message's font declared once around them, and only what differs from it on the text itself.
///
/// AppKit's writer wraps every run in `<font face size style="font: …">`, puts the font again on
/// every empty paragraph with a minimum height and a `<br>`, and writes every length as
/// `0.0px`, which triples the size of a short reply and sets it in a font of its own in every
/// reader. Here, text in the message's font loses its font altogether, other text keeps only the
/// family and size that differ, in points, empty paragraphs become Outlook's `&nbsp;`, and
/// empty tags go. Colours, links, pictures, lists and tables are left exactly as written.
public enum CompactHTML {
    /// `html`, as AppKit's writer made it, as the inside of the element that declares `font`.
    public static func compact(_ html: String, font: ComposeFont) -> String {
        let defaultFace = face(of: font.displayFont)?.lowercased()
        var text = html
        if let start = text.range(of: "<body>", options: .caseInsensitive) { text = String(text[start.upperBound...]) }
        if let end = text.range(of: "</body>", options: [.caseInsensitive, .backwards]) { text = String(text[..<end.lowerBound]) }
        let source = text as NSString
        var output = ""
        var position = 0
        var fonts: [Bool] = []
        var spans: [Bool] = []
        /// Where the open paragraph's content starts in `output`.
        var paragraphContent: String.Index?
        for match in tag.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: position, length: match.range.location - position))
            position = NSMaxRange(match.range)
            let closing = match.range(at: 1).length > 0
            let name = source.substring(with: match.range(at: 2)).lowercased()
            let rest = source.substring(with: match.range(at: 3))
            let attributes = HTMLAttributes.parse(" " + rest)
            switch (name, closing) {
            case ("p", false), ("li", false):
                let style = paragraphStyle(attributes["style"] ?? "", font: font, defaultFace: defaultFace)
                output += "<\(name)" + (style.isEmpty ? "" : " style=\"\(style)\"") + ">"
                if name == "p" { paragraphContent = output.endIndex }
            case ("br", false):
                // An empty paragraph is Outlook's &nbsp;, which gives it its height.
                if let start = paragraphContent, onlyEmptyTags(String(output[start...])),
                   source.substring(from: position).hasPrefix("</p>") {
                    output += "&nbsp;"
                } else {
                    output += "<br>"
                }
            case ("p", true):
                paragraphContent = nil
                output += "</p>"
            case ("font", false):
                let style = runStyle(face: attributes["face"], style: attributes["style"] ?? "", font: font, defaultFace: defaultFace)
                fonts.append(!style.isEmpty)
                if !style.isEmpty { output += "<span style=\"\(style)\">" }
            case ("font", true):
                if fonts.popLast() ?? false { output += "</span>" }
            case ("span", false):
                let converted = attributes["class"] == "Apple-converted-space"
                spans.append(!converted)
                if !converted { output += source.substring(with: match.range) }
            case ("span", true):
                if spans.popLast() ?? true { output += "</span>" }
            default:
                output += source.substring(with: match.range)
            }
        }
        output += source.substring(from: position)
        // Tags left holding nothing, as the writer leaves after bold on an empty line.
        var previous = ""
        while previous != output {
            previous = output
            output = output.replacingOccurrences(of: "<(b|i|u|s|strike|sup|sub|span)>(</\\1>)", with: "", options: .regularExpression)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let tag = try! NSRegularExpression(pattern: "<(/?)([A-Za-z][A-Za-z0-9]*)([^>]*)>")

    private static func onlyEmptyTags(_ text: String) -> Bool {
        text.replacingOccurrences(of: "<(b|i|u|s|strike|sup|sub)>|</(b|i|u|s|strike|sup|sub)>", with: "", options: .regularExpression).isEmpty
    }

    // MARK: - declarations

    /// A paragraph's style: its margins as short as they go, the font it repeats for an empty
    /// line only where it differs from the message's, and no minimum height.
    private static func paragraphStyle(_ style: String, font: ComposeFont, defaultFace: String?) -> String {
        var output: [String] = []
        for (property, value) in declarations(style) {
            switch property {
            case "margin", "padding", "text-indent", "line-height", "margin-left", "margin-right", "margin-top", "margin-bottom":
                output.append("\(property):\(lengths(value))")
            case "font":
                output += fontDeclarations(value, face: nil, font: font, defaultFace: defaultFace)
            case "min-height", "color":
                continue
            default:
                output.append("\(property):\(value)")
            }
        }
        return output.joined(separator: ";")
    }

    /// A run's style: its family and size where they differ from the message's, and the rest,
    /// colours above all, as written, a colour the writer repeats given once.
    private static func runStyle(face: String?, style: String, font: ComposeFont, defaultFace: String?) -> String {
        var output: [String] = []
        var sawFont = false
        for (property, value) in declarations(style) {
            if property == "font" {
                sawFont = true
                output += fontDeclarations(value, face: face, font: font, defaultFace: defaultFace)
            } else {
                output.append("\(property):\(value)")
            }
        }
        if !sawFont, let face, face.lowercased() != defaultFace {
            output.insert("font-family:\(ComposeFont(family: familyName(face), size: font.size).cssFamily)", at: 0)
        }
        return output.joined(separator: ";")
    }

    /// The CSS `font` shorthand the writer uses, `[bold] [italic] 14.0px 'Family', …`, as the
    /// declarations that differ from the message's font.
    private static func fontDeclarations(_ value: String, face: String?, font: ComposeFont, defaultFace: String?) -> [String] {
        let words = value.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let sizeIndex = words.firstIndex(where: { $0.hasSuffix("px") && Double($0.dropLast(2).split(separator: "/").first ?? "") != nil })
        else { return ["font:\(value)"] }
        var output: [String] = []
        let family = face ?? familyName(words[(sizeIndex + 1)...].joined(separator: " "))
        if family.lowercased() != defaultFace {
            output.append("font-family:\(ComposeFont(family: familyName(family), size: font.size).cssFamily)")
        }
        let size = CGFloat(Double(words[sizeIndex].dropLast(2).split(separator: "/").first ?? "") ?? Double(font.size))
        if abs(size - font.size) >= 0.01 || family.lowercased() != defaultFace {
            output.append("font-size:\(ComposeFont.points(size))")
        }
        for word in words[..<sizeIndex] {
            switch word.lowercased() {
            case "bold", "bolder", "600", "700", "800", "900": output.append("font-weight:bold")
            case "italic", "oblique": output.append("font-style:italic")
            default: break
            }
        }
        return output
    }

    /// The first family of a CSS family list, unquoted; the system's font as the writer names
    /// it stands for the system's.
    private static func familyName(_ list: String) -> String {
        let first = list.split(separator: ",").first.map(String.init)?.trimmed ?? list
        let name = first.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        return name.hasPrefix(".") ? ComposeFont.systemFamily : name
    }

    /// `property: value` pairs of a style attribute, in order, a repeated property keeping its
    /// last value where it stood first.
    private static func declarations(_ style: String) -> [(String, String)] {
        var result: [(String, String)] = []
        for part in style.split(separator: ";") {
            guard let colon = part.firstIndex(of: ":") else { continue }
            let property = String(part[..<colon]).trimmed.lowercased()
            let value = String(part[part.index(after: colon)...]).trimmed
            guard !property.isEmpty, !value.isEmpty else { continue }
            if let index = result.firstIndex(where: { $0.0 == property }) {
                result[index].1 = value
            } else {
                result.append((property, value))
            }
        }
        return result
    }

    /// Lengths without their needless decimals, and zero without its unit: `0.0px 12.0px` as
    /// `0 12px`, and four equal ones as one.
    private static func lengths(_ value: String) -> String {
        let parts = value.split(separator: " ").map { part -> String in
            var text = String(part)
            if text.hasSuffix(".0px") { text = String(text.dropLast(4)) + "px" }
            if text == "0px" || text == "-0px" { text = "0" }
            return text
        }
        if parts.count == 4, Set(parts).count == 1 { return parts[0] }
        return parts.joined(separator: " ")
    }

    // MARK: - the writer's name for a font

    private static let faces = NSCache<NSString, NSString>()

    /// The face AppKit's writer names `font` by, which differs from its family for the system's.
    static func face(of font: NSFont) -> String? {
        let key = "\(font.fontName)|\(font.pointSize)" as NSString
        if let known = faces.object(forKey: key) { return known as String }
        guard let written = ComposedHTML.html(from: NSAttributedString(string: "x", attributes: [.font: font])),
              let match = faceAttribute.firstMatch(in: written, range: NSRange(location: 0, length: (written as NSString).length))
        else { return nil }
        let face = (written as NSString).substring(with: match.range(at: 1))
        faces.setObject(face as NSString, forKey: key)
        return face
    }

    private static let faceAttribute = try! NSRegularExpression(pattern: "<font face=\"([^\"]*)\"")
}
