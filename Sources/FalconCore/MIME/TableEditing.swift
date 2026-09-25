import AppKit

/// Changing a table in a message being written, as Outlook's right-click menu does: insert a row
/// above or below, a column left or right, delete a row, a column or the whole table.
///
/// A table in the composer is laid out by AppKit from blocks each cell's paragraphs carry, and a
/// block's row and column cannot be changed once made, so every change reads the table's cells
/// and writes it again as Outlook's Table Grid (see ComposedTable) with the cells' own text and
/// formatting, as one step Undo takes back. A table with merged cells cannot be read as a grid
/// and is left alone.
public enum TableEditing {
    public enum Change: CaseIterable, Sendable {
        case rowAbove, rowBelow, columnLeft, columnRight, deleteRow, deleteColumn, deleteTable

        public var title: String {
            switch self {
            case .rowAbove: return "Insert Row Above"
            case .rowBelow: return "Insert Row Below"
            case .columnLeft: return "Insert Column Left"
            case .columnRight: return "Insert Column Right"
            case .deleteRow: return "Delete Row"
            case .deleteColumn: return "Delete Column"
            case .deleteTable: return "Delete Table"
            }
        }
    }

    /// A table found around a place in the text: where it lies, and each of its cells' ranges,
    /// rows of columns, the last newline of each included.
    public struct Found {
        public let table: NSTextTable
        /// Where the table's cells sit among a paragraph's blocks: tables around it come first.
        let depth: Int
        public let range: NSRange
        public let cells: [[NSRange]]
        public let row: Int
        public let column: Int
        public var rows: Int { cells.count }
        public var columns: Int { cells.first?.count ?? 0 }
    }

    /// The innermost table holding `location`, when its cells form a whole grid.
    public static func find(in text: NSAttributedString, at location: Int) -> Found? {
        guard text.length > 0 else { return nil }
        let at = min(max(location, 0), text.length - 1)
        guard let style = text.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle,
              let depth = style.textBlocks.lastIndex(where: { $0 is NSTextTableBlock }),
              let here = style.textBlocks[depth] as? NSTextTableBlock else { return nil }
        let table = here.table
        let range = text.range(of: table, at: at)
        guard range.location != NSNotFound, range.length > 0 else { return nil }

        var grid = [[NSRange?]](repeating: [NSRange?](repeating: nil, count: table.numberOfColumns), count: 0)
        let string = text.string as NSString
        var position = range.location
        var current: (block: NSTextTableBlock, range: NSRange)?
        func close() -> Bool {
            guard let cell = current else { return true }
            let block = cell.block
            guard block.rowSpan == 1, block.columnSpan == 1,
                  block.startingColumn >= 0, block.startingColumn < table.numberOfColumns else { return false }
            while grid.count <= block.startingRow {
                grid.append([NSRange?](repeating: nil, count: table.numberOfColumns))
            }
            guard grid[block.startingRow][block.startingColumn] == nil else { return false }
            grid[block.startingRow][block.startingColumn] = cell.range
            current = nil
            return true
        }
        while position < NSMaxRange(range) {
            let paragraph = string.paragraphRange(for: NSRange(location: position, length: 0))
            let blocks = (text.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks ?? []
            guard blocks.count > depth, let block = blocks[depth] as? NSTextTableBlock, block.table === table else { return nil }
            if let open = current, open.block === block {
                current = (block, NSUnionRange(open.range, paragraph))
            } else {
                guard close() else { return nil }
                current = (block, paragraph)
            }
            position = NSMaxRange(paragraph)
        }
        guard close(), !grid.isEmpty else { return nil }
        let cells = grid.compactMap { row -> [NSRange]? in
            let whole = row.compactMap { $0 }
            return whole.count == row.count ? whole : nil
        }
        guard cells.count == grid.count else { return nil }
        guard let row = cells.firstIndex(where: { $0.contains { NSLocationInRange(at, $0) } }),
              let column = cells[row].firstIndex(where: { NSLocationInRange(at, $0) }) else { return nil }
        return Found(table: table, depth: depth, range: range, cells: cells, row: row, column: column)
    }

    /// Makes `change` to the table around the caret, or around `location`, as one step Undo takes
    /// back; the caret lands in the cell that took the place of the one it was in. Returns false,
    /// changing nothing, when there is no table there that can be changed.
    @MainActor
    @discardableResult
    public static func apply(_ change: Change, in editor: NSTextView, at location: Int? = nil) -> Bool {
        guard let storage = editor.textStorage,
              let found = find(in: storage, at: location ?? editor.selectedRange().location) else { return false }

        // Each cell's text without the newline that ends it, as the grid writes it again.
        var contents: [[NSAttributedString]] = found.cells.map { row in
            row.map { range in
                var inner = range
                if inner.length > 0, (storage.string as NSString).character(at: NSMaxRange(inner) - 1) == 0x0A { inner.length -= 1 }
                return storage.attributedSubstring(from: inner)
            }
        }
        let empty = NSAttributedString()
        var caret = (row: found.row, column: found.column)
        switch change {
        case .rowAbove:
            contents.insert(Array(repeating: empty, count: found.columns), at: found.row)
        case .rowBelow:
            contents.insert(Array(repeating: empty, count: found.columns), at: found.row + 1)
            caret.row += 1
        case .columnLeft:
            guard found.columns < ComposedBody.mostTableColumns else { return false }
            contents = contents.map { var row = $0; row.insert(empty, at: found.column); return row }
        case .columnRight:
            guard found.columns < ComposedBody.mostTableColumns else { return false }
            contents = contents.map { var row = $0; row.insert(empty, at: found.column + 1); return row }
            caret.column += 1
        case .deleteRow:
            contents.remove(at: found.row)
            caret.row = min(found.row, contents.count - 1)
        case .deleteColumn:
            contents = contents.map { var row = $0; row.remove(at: found.column); return row }
            caret.column = min(found.column, (contents.first?.count ?? 0) - 1)
        case .deleteTable:
            contents = []
        }

        let replacement: NSAttributedString
        var caretOffset = 0
        if contents.isEmpty || contents[0].isEmpty {
            replacement = NSAttributedString()
        } else {
            let first = storage.attributes(at: found.range.location, effectiveRange: nil)
            var attributes = first
            attributes[.link] = nil
            attributes[.attachment] = nil
            // The blocks of any table this one sits in, so it stays inside that table's cell.
            let style = (first[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.textBlocks = Array(style.textBlocks.prefix(found.depth))
            attributes[.paragraphStyle] = style
            let cell = found.table.textBlocks(in: storage, at: found.range.location)
            let lines = cell?.borderColor(for: .maxX) ?? .separatorColor
            let width = found.table.contentWidthValueType == .absoluteValueType && found.table.contentWidth > 0
                ? found.table.contentWidth : ComposedTable.pageWidth
            replacement = ComposedTable.grid(rows: contents.count, columns: contents[0].count, width: width,
                                             lines: lines, attributes: attributes, contents: contents)
            for row in 0...caret.row {
                for column in 0..<contents[row].count where row < caret.row || column < caret.column {
                    caretOffset += contents[row][column].length + 1
                }
            }
        }

        editor.breakUndoCoalescing()
        guard editor.shouldChangeText(in: found.range, replacementString: replacement.string) else { return false }
        storage.replaceCharacters(in: found.range, with: replacement)
        editor.didChangeText()
        editor.undoManager?.setActionName(change.title)
        editor.setSelectedRange(NSRange(location: min(found.range.location + caretOffset, storage.length), length: 0))
        return true
    }
}

private extension NSTextTable {
    /// The table's cell block at `location`, for its line colour.
    func textBlocks(in text: NSAttributedString, at location: Int) -> NSTextTableBlock? {
        let style = text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
        return style?.textBlocks.compactMap { $0 as? NSTextTableBlock }.first { $0.table === self }
    }
}
