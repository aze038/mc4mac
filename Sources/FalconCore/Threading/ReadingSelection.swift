import Foundation

/// Keeps the list's selection on what the owner chose while the list is rebuilt under it, so
/// that the reading pane goes on showing it.
///
/// A conversation's row is tagged with its newest message's id, so a reply arriving gives the
/// row a new tag; a message line (tagged `ReadMarking.messageLineTag` and its message's id)
/// loses its row when its conversation is folded. Either way the selection used to name a row
/// that was no longer there and was dropped, leaving the reading pane with nothing selected.
public enum ReadingSelection {
    /// `selected` with every tag that names no row in `rows` carried to the row now showing its
    /// message: the message's own line when that is listed, else its conversation's row. A tag
    /// whose message is no longer listed at all is dropped. `conversations` are the list's
    /// conversations, each its message ids newest first, the first being its row's tag.
    public static func carried(_ selected: Set<String>, rows: Set<String>, conversations: [[String]]) -> Set<String> {
        guard !selected.isSubset(of: rows) else { return selected }
        var out = Set<String>()
        for tag in selected {
            if rows.contains(tag) {
                out.insert(tag)
                continue
            }
            let isLine = tag.hasPrefix(ReadMarking.messageLineTag)
            let id = isLine ? String(tag.dropFirst(ReadMarking.messageLineTag.count)) : tag
            guard let conversation = conversations.first(where: { $0.contains(id) }), let row = conversation.first else { continue }
            let line = ReadMarking.messageLineTag + id
            if isLine, rows.contains(line) {
                out.insert(line)
            } else if rows.contains(row) {
                out.insert(row)
            }
        }
        return out
    }
}
