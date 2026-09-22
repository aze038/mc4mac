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

    /// Every cell is an empty paragraph in `attributes`; a paragraph style there is kept, and
    /// its blocks enclose the table, so a table inserted inside a cell nests in it.
    public static func grid(rows: Int, columns: Int, width: CGFloat, lines: NSColor,
                            attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let outer = (attributes[.paragraphStyle] as? NSParagraphStyle) ?? .default
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        // Absolute widths: a percentage does not survive the draft's trip through RTF, which
        // writes fiftieths of a per cent and reads them back as twentieths.
        table.setContentWidth(width, type: .absoluteValueType)
        let cellWidth = (width / CGFloat(columns) - 2 * cellPadding - lineWidth).rounded(.down)
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
                cells.append(NSAttributedString(string: "\n", attributes: cell))
            }
        }
        return cells
    }
}
