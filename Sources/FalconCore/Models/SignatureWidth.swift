import AppKit

/// How wide a signature is at its own size, so it can be shown so, never wrapped or squeezed
/// to the width of the window that shows it.
public enum SignatureWidth {
    /// How wide `text` is when nothing in it is wrapped to a page: its widest line or picture, or
    /// its widest table. A table the HTML gave a width in points is that wide; any other, as a
    /// browser draws one, is as wide as its columns, each as wide as its widest cell's content
    /// set on one line, a table inside a cell included.
    public static func natural(of text: NSAttributedString, padding: CGFloat = 0) -> CGFloat {
        guard text.length > 0 else { return 0 }
        let string = text.string as NSString
        var widest: CGFloat = 0
        var cellContent: [ObjectIdentifier: CGFloat] = [:]
        var tables: [ObjectIdentifier: NSTextTable] = [:]
        var cellsOf: [ObjectIdentifier: [NSTextTableBlock]] = [:]
        var tableOrder: [ObjectIdentifier] = []
        var parentCell: [ObjectIdentifier: NSTextTableBlock] = [:]
        var location = 0
        while location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            let style = text.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
            let width = lineWidth(of: text.attributedSubstring(from: paragraph), padding: padding)
                + max(style?.headIndent ?? 0, style?.firstLineHeadIndent ?? 0)
            let cells = (style?.textBlocks ?? []).compactMap { $0 as? NSTextTableBlock }
            for (depth, cell) in cells.enumerated() {
                let table = ObjectIdentifier(cell.table)
                if tables[table] == nil {
                    tables[table] = cell.table
                    tableOrder.append(table)
                    if depth > 0 { parentCell[table] = cells[depth - 1] }
                }
                if !(cellsOf[table] ?? []).contains(where: { $0 === cell }) { cellsOf[table, default: []].append(cell) }
            }
            if let innermost = cells.last {
                cellContent[ObjectIdentifier(innermost), default: 0] = max(cellContent[ObjectIdentifier(innermost)] ?? 0, width)
            } else {
                widest = max(widest, width)
            }
        }
        // Inner tables first, so each is part of the cell it sits in.
        for table in tableOrder.reversed() {
            guard let object = tables[table] else { continue }
            let width = tableWidth(object, cells: cellsOf[table] ?? [], content: cellContent)
            if let parent = parentCell[table] {
                cellContent[ObjectIdentifier(parent)] = max(cellContent[ObjectIdentifier(parent)] ?? 0, width)
            } else {
                widest = max(widest, width + padding * 2)
            }
        }
        return ceil(widest)
    }

    /// A paragraph's width set on one line, without the table it may be in.
    private static func lineWidth(of paragraph: NSAttributedString, padding: CGFloat) -> CGFloat {
        let line = NSMutableAttributedString(attributedString: paragraph)
        line.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: line.length)) { value, range, _ in
            guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
            style.textBlocks = []
            style.lineBreakMode = .byClipping
            line.addAttribute(.paragraphStyle, value: style, range: range)
        }
        let bounds = line.boundingRect(with: NSSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading])
        // Measuring outside a window may give a picture no room, so each is counted at its own
        // size, beside the words' own width.
        var pictures: CGFloat = 0
        var words = NSMutableAttributedString(attributedString: line)
        line.enumerateAttribute(.attachment, in: NSRange(location: 0, length: line.length), options: .reverse) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            pictures += pictureWidth(attachment)
            words.deleteCharacters(in: range)
        }
        guard pictures > 0 else { return bounds.width + padding * 2 }
        words = words.length > 0 ? words : NSMutableAttributedString()
        let wordsWidth = words.boundingRect(with: NSSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude),
                                            options: [.usesLineFragmentOrigin, .usesFontLeading]).width
        return max(bounds.width, wordsWidth + pictures) + padding * 2
    }

    /// A picture's width as it is shown: the size it was given, else its image's own.
    private static func pictureWidth(_ attachment: NSTextAttachment) -> CGFloat {
        if attachment.bounds.width > 0 { return attachment.bounds.width }
        if let image = attachment.image, image.size.width > 0 { return image.size.width }
        if let data = attachment.fileWrapper?.regularFileContents ?? attachment.contents, let image = NSImage(data: data) {
            return image.size.width
        }
        return 0
    }

    /// A table's width: the width in points the HTML gave it, else its columns'.
    private static func tableWidth(_ table: NSTextTable, cells: [NSTextTableBlock], content: [ObjectIdentifier: CGFloat]) -> CGFloat {
        let own = edges(of: table)
        if table.contentWidthValueType == .absoluteValueType, table.contentWidth > 0 { return table.contentWidth + own }
        var columns = [CGFloat](repeating: 0, count: max(1, table.numberOfColumns))
        var spanning: [(first: Int, span: Int, width: CGFloat)] = []
        for cell in cells {
            var width = (content[ObjectIdentifier(cell)] ?? 0) + edges(of: cell)
            if cell.valueType(for: .width) == .absoluteValueType, cell.value(for: .width) > 0 {
                width = max(width, cell.value(for: .width) + edges(of: cell))
            }
            let first = max(0, cell.startingColumn)
            let span = max(1, cell.columnSpan)
            if first + span > columns.count { columns += [CGFloat](repeating: 0, count: first + span - columns.count) }
            if span == 1 { columns[first] = max(columns[first], width) } else { spanning.append((first, span, width)) }
        }
        // A cell across several columns widens them evenly if they are too narrow for it.
        for cell in spanning {
            let range = cell.first..<(cell.first + cell.span)
            let short = cell.width - columns[range].reduce(0, +)
            if short > 0 { for i in range { columns[i] += short / CGFloat(cell.span) } }
        }
        return columns.reduce(0, +) + own
    }

    /// A block's padding, border and margin, left and right.
    private static func edges(of block: NSTextBlock) -> CGFloat {
        var total: CGFloat = 0
        for layer in [NSTextBlock.Layer.padding, .border, .margin] {
            total += block.width(for: layer, edge: .minX) + block.width(for: layer, edge: .maxX)
        }
        return total
    }
}
