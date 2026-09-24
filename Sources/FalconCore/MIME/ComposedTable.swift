import AppKit

/// Outlook's Table Grid as rich text for the composer: equal columns across a given width,
/// cells padded 5.4 points either side and not at all above or below, thin solid lines.
///
/// The lines are laid out the way Outlook writes them: every cell draws its right and bottom
/// edges, the first row its top and the first column its left, so each line is drawn once.
/// Drawing all four edges of every cell would lay the inner lines down twice, and a
/// translucent colour such as the label colour then shows them brighter than the outer ones.
public enum ComposedTable {
    public static let lineWidth: CGFloat = 1
    public static let cellPadding: CGFloat = 5.4
    /// Outlook's page: a table it inserts spans the six and a half inches, 468 points, between a
    /// letter page's margins, however wide the window. The composer's points go out as CSS
    /// pixels, so without this cap a table would be sent as wide as the sender's window.
    public static let pageWidth: CGFloat = 468
    /// The least text a cell keeps when a table is squeezed, into a narrow cell of another or
    /// by many columns.
    static let leastCellText: CGFloat = 8

    /// How wide a table of `columns` is made in `room` points of text, in a body `body` points
    /// wide: the room less a line for the table's own border, no wider than Outlook's page.
    /// Columns that would leave a cell no room for text there take what they need instead, but
    /// never more than the body, past which the table could not be seen whole and would go out
    /// wider than the message.
    public static func width(room: CGFloat, body: CGFloat, columns: Int) -> CGFloat {
        let fitted = min(room, pageWidth) - lineWidth
        let needed = CGFloat(max(columns, 1)) * (2 * cellPadding + lineWidth + leastCellText)
        return min(max(fitted, needed), body - lineWidth)
    }

    /// Every cell is a paragraph in `attributes`, empty or holding its text from `contents`,
    /// rows of columns; a paragraph style there is kept, and its blocks enclose the table, so a
    /// table inserted inside a cell nests in it.
    public static func grid(rows: Int, columns: Int, width: CGFloat, lines: NSColor,
                            attributes: [NSAttributedString.Key: Any], contents: [[String]] = []) -> NSAttributedString {
        let outer = (attributes[.paragraphStyle] as? NSParagraphStyle) ?? .default
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        // Absolute widths: a percentage does not survive the draft's trip through RTF, which
        // writes fiftieths of a per cent and reads them back as twentieths.
        table.setContentWidth(width, type: .absoluteValueType)
        let cellWidth = max(0, (width / CGFloat(columns) - 2 * cellPadding - lineWidth).rounded(.down))
        let cells = NSMutableAttributedString()
        for row in 0..<rows {
            for column in 0..<columns {
                let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                block.setBorderColor(lines)
                block.setWidth(0, type: .absoluteValueType, for: .border)
                block.setWidth(lineWidth, type: .absoluteValueType, for: .border, edge: .maxX)
                block.setWidth(lineWidth, type: .absoluteValueType, for: .border, edge: .maxY)
                if row == 0 { block.setWidth(lineWidth, type: .absoluteValueType, for: .border, edge: .minY) }
                if column == 0 { block.setWidth(lineWidth, type: .absoluteValueType, for: .border, edge: .minX) }
                block.setWidth(cellPadding, type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(cellPadding, type: .absoluteValueType, for: .padding, edge: .maxX)
                block.setValue(cellWidth, type: .absoluteValueType, for: .width)
                block.verticalAlignment = .topAlignment
                let style = (outer.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                style.textBlocks = outer.textBlocks + [block]
                var cell = attributes
                cell[.paragraphStyle] = style
                let text = contents.indices.contains(row) && contents[row].indices.contains(column) ? contents[row][column] : ""
                cells.append(NSAttributedString(string: text + "\n", attributes: cell))
            }
        }
        return cells
    }

    /// Lines of text as the cells of a table, as Convert Text to Table reads them: a row to a
    /// line, blank lines left out, split at tabs when any line has one and at commas otherwise,
    /// every row padded to the widest.
    public static func cells(from text: String) -> [[String]] {
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmed.isEmpty }
        let separator: Character = lines.contains { $0.contains("\t") } ? "\t" : ","
        let rows = lines.map { $0.split(separator: separator, omittingEmptySubsequences: false).map { String($0).trimmed } }
        let columns = rows.map(\.count).max() ?? 0
        return rows.map { $0 + Array(repeating: "", count: columns - $0.count) }
    }
}
