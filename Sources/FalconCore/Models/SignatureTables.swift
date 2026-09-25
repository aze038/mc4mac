import AppKit

/// The tables of a signature's HTML as the composer shows them: laid out as the HTML lays them
/// out. AppKit's HTML reader gives a table that sets no width of its own, as a signature's
/// usually does so that it is only as wide as what it holds, a width of its own, and forgets
/// max-width, so the signature is drawn wider than it is and, once edited, is sent with widths
/// it never had. Here each table and cell that sets no width is given none, so it is laid out
/// automatically, as a browser does; a width the HTML does give, in pixels or per cent, is kept
/// as given, and max-width becomes the table's greatest width. Only the tables AppKit made from
/// the HTML are touched, and only when they pair one for one with the HTML's.
public enum SignatureTables {
    /// A table of the HTML, its own attributes and its own cells', in order, not those of the
    /// tables inside it.
    struct Table {
        var attributes: [String: String]
        var cells: [[String: String]] = []
    }

    private static let tag = try! NSRegularExpression(pattern: "(?is)<(/?)(table|td|th)\\b([^>]*)>")

    /// The tables of `html` in the order they start.
    static func tables(in html: String) -> [Table] {
        var tables: [Table] = []
        var open: [Int] = []
        let source = html as NSString
        for match in tag.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            let closing = match.range(at: 1).length > 0
            let name = source.substring(with: match.range(at: 2)).lowercased()
            let attributes = HTMLAttributes.parse(" " + source.substring(with: match.range(at: 3)))
            switch (name, closing) {
            case ("table", false):
                tables.append(Table(attributes: attributes))
                open.append(tables.count - 1)
            case ("table", true):
                _ = open.popLast()
            case (_, false):
                if let current = open.last { tables[current].cells.append(attributes) }
            default:
                break
            }
        }
        return tables
    }

    /// A width the HTML gives, from a style's `property` first, as a browser reads it, else from
    /// the `width` attribute: points, taking a CSS pixel as a point, as the composer does, or a
    /// percentage. Nil when none is given, or `auto`.
    static func width(_ property: String, in attributes: [String: String]) -> (value: CGFloat, type: NSTextBlock.ValueType)? {
        if let style = attributes["style"] {
            for part in style.split(separator: ";") {
                let pair = part.split(separator: ":", maxSplits: 1).map { String($0).trimmed.lowercased() }
                guard pair.count == 2, pair[0] == property else { continue }
                return length(pair[1].replacingOccurrences(of: "!important", with: "").trimmed)
            }
        }
        guard property == "width", let given = attributes["width"]?.trimmed.lowercased() else { return nil }
        return length(given)
    }

    private static func length(_ text: String) -> (value: CGFloat, type: NSTextBlock.ValueType)? {
        if text.hasSuffix("%"), let value = Double(text.dropLast()) { return (CGFloat(value), .percentageValueType) }
        let number = text.hasSuffix("px") ? String(text.dropLast(2)) : text
        guard let value = Double(number.trimmed), value >= 0 else { return nil }
        return (CGFloat(value), .absoluteValueType)
    }

    /// Every table AppKit made in `text`, in the order it starts, each with its cells in order.
    static func textTables(in text: NSAttributedString) -> [(table: NSTextTable, cells: [NSTextTableBlock])] {
        var found: [(table: NSTextTable, cells: [NSTextTableBlock])] = []
        var index: [ObjectIdentifier: Int] = [:]
        var seenCells = Set<ObjectIdentifier>()
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            for block in (value as? NSParagraphStyle)?.textBlocks ?? [] {
                guard let cell = block as? NSTextTableBlock else { continue }
                let key = ObjectIdentifier(cell.table)
                if index[key] == nil {
                    index[key] = found.count
                    found.append((cell.table, []))
                }
                if seenCells.insert(ObjectIdentifier(cell)).inserted, let at = index[key] { found[at].cells.append(cell) }
            }
        }
        return found
    }

    /// Lays out the tables of `text`, read from `html`, as the HTML lays them out.
    public static func honour(_ html: String, in text: NSAttributedString) {
        let given = tables(in: html)
        let made = textTables(in: text)
        guard !made.isEmpty, given.count == made.count else { return }
        for (source, (table, cells)) in zip(given, made) {
            if let width = width("width", in: source.attributes) {
                table.setContentWidth(width.value, type: width.type)
            } else {
                // No width of its own: as wide as what it holds, as a browser draws it.
                table.layoutAlgorithm = .automaticLayoutAlgorithm
                table.setContentWidth(0, type: .absoluteValueType)
                table.setValue(0, type: .absoluteValueType, for: .width)
            }
            if let most = width("max-width", in: source.attributes) {
                table.setValue(most.value, type: most.type, for: .maximumWidth)
            }
            guard source.cells.count == cells.count else { continue }
            for (attributes, cell) in zip(source.cells, cells) {
                if let width = width("width", in: attributes) {
                    cell.setValue(width.value, type: width.type, for: .width)
                } else {
                    cell.setValue(0, type: .absoluteValueType, for: .width)
                }
            }
        }
    }
}
