import AppKit

/// The font a message is written in where its text says nothing of its own.
///
/// Out of the box it is Legacy Outlook for Mac's: Aptos at 12 point, which the HTML declares as
/// `Aptos, Calibri, Helvetica, Arial, sans-serif`, so an Outlook reader sees Aptos and any other
/// the nearest it has. Aptos comes with Office, not with macOS, so the composer shows the first
/// of those that is installed. Sizes are the composer's points, which a reader draws as CSS
/// pixels, as every picture and table the composer sends is measured: Outlook's 12 point is 16.
public struct ComposeFont: Equatable, Sendable {
    /// A family by name; `outlookFamily` stands for Outlook's list, `systemFamily` for the
    /// system's font.
    public var family: String
    public var size: CGFloat

    public init(family: String, size: CGFloat) {
        self.family = family
        self.size = size
    }

    public static let outlookFamily = "Aptos"
    public static let systemFamily = "System"
    public static let outlook = ComposeFont(family: outlookFamily, size: 16)

    /// The families Outlook's default is declared as, and shown in, in order.
    public static let outlookFamilies = ["Aptos", "Calibri", "Helvetica", "Arial"]

    /// Where Settings keeps the font for new messages.
    public static let familyKey = "composeFontFamily"
    public static let sizeKey = "composeFontSize"

    /// The font Settings chooses, else Outlook's.
    public static func chosen(in defaults: UserDefaults = .standard) -> ComposeFont {
        let family = defaults.string(forKey: familyKey).map(\.trimmed).flatMap { $0.isEmpty ? nil : $0 } ?? outlookFamily
        let size = defaults.object(forKey: sizeKey) as? Double ?? Double(outlook.size)
        return ComposeFont(family: family, size: CGFloat(min(max(size, 6), 96)))
    }

    /// The family list the HTML declares.
    public var cssFamily: String {
        switch family {
        case ComposeFont.outlookFamily: return "Aptos,Calibri,Helvetica,Arial,sans-serif"
        case ComposeFont.systemFamily: return "-apple-system,Helvetica,Arial,sans-serif"
        default:
            let generic = ComposeFont.serifFamilies.contains(family) ? "serif"
                : ComposeFont.monospacedFamilies.contains(family) ? "monospace" : "sans-serif"
            return ComposeFont.cssName(family) + "," + generic
        }
    }

    /// The size the HTML declares, in points as Outlook writes it: 16 is 12pt.
    public var cssSize: String { ComposeFont.points(size) }

    /// The declarations that set text in this font.
    public var css: String { "font-family:\(cssFamily);font-size:\(cssSize)" }

    /// The font the composer shows: the first installed of Outlook's list for Outlook's, the
    /// system's for the system's, else the family chosen, or the system's when it has gone.
    public var displayFont: NSFont {
        switch family {
        case ComposeFont.systemFamily:
            return NSFont.systemFont(ofSize: size)
        case ComposeFont.outlookFamily:
            for name in ComposeFont.outlookFamilies {
                if let font = NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size) { return font }
            }
            return NSFont.systemFont(ofSize: size)
        default:
            return NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
                ?? NSFont(name: family, size: size) ?? NSFont.systemFont(ofSize: size)
        }
    }

    /// Whether text in `font` is in this font, at its size, so it needs no font of its own.
    public func isShown(by font: NSFont) -> Bool {
        abs(font.pointSize - size) < 0.01 && font.familyName == displayFont.familyName
    }

    /// `pixels` in points, as CSS writes them: 16 as `12pt`, 14 as `10.5pt`.
    public static func points(_ pixels: CGFloat) -> String {
        let value = (Double(pixels) * 0.75 * 100).rounded() / 100
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "pt"
    }

    /// A family name as CSS writes it: quoted when it is more than one plain word.
    static func cssName(_ family: String) -> String {
        let plain = family.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } && !(family.first?.isNumber ?? true)
        if plain { return family }
        return "'" + family.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    private static let serifFamilies: Set<String> = ["Times New Roman", "Times", "Georgia", "Cambria", "Palatino", "Baskerville",
                                                     "Garamond", "Book Antiqua", "Hoefler Text", "Didot", "Charter"]
    private static let monospacedFamilies: Set<String> = ["Courier New", "Courier", "Menlo", "Monaco", "Consolas", "SF Mono",
                                                          "Andale Mono"]
}
