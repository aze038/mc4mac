import Foundation

/// A conversation as the reading pane shows it when its row in the list is clicked: every message
/// one under another, newest at the top, the way Gmail shows a conversation but the other way up,
/// which is the owner's choice. The newest message and every unread one start open; the others
/// are one line each and open on a click. Only an open card fetches its message's text.
///
/// The list keeps one row per conversation; clicking one of its per-message lines still shows
/// that message alone, and a conversation of one message shows as it always did.
public struct ConversationStack: Equatable, Sendable {
    /// Newest first.
    public private(set) var messages: [MessageSummary]
    /// The ids of the cards shown open.
    public private(set) var expanded: Set<String>

    public init(_ messages: [MessageSummary]) {
        self.messages = Self.newestFirst(messages)
        self.expanded = Self.startsOpen(self.messages)
    }

    /// Newest first however the caller ordered them; two messages sent in the same second keep
    /// the order they came in.
    public static func newestFirst(_ messages: [MessageSummary]) -> [MessageSummary] {
        messages.enumerated()
            .sorted { $0.element.date != $1.element.date ? $0.element.date > $1.element.date : $0.offset < $1.offset }
            .map(\.element)
    }

    /// The cards open when the stack opens: the newest message and every unread one.
    public static func startsOpen(_ messages: [MessageSummary]) -> Set<String> {
        var open = Set(messages.filter { !$0.isRead }.map(\.id))
        if let newest = newestFirst(messages).first { open.insert(newest.id) }
        return open
    }

    public var newest: MessageSummary? { messages.first }

    public func isExpanded(_ id: String) -> Bool { expanded.contains(id) }

    /// The open cards' messages, newest first: the ones whose text is fetched.
    public var expandedMessages: [MessageSummary] { messages.filter { expanded.contains($0.id) } }

    /// What opening the stack marks read, as opening a message marks it: the unread messages
    /// shown open, which are all the unread ones, since every unread card starts open.
    public var toMarkRead: [MessageSummary] { expandedMessages.filter { !$0.isRead } }

    /// A click on a card's header or folded line: it opens, or folds again.
    public mutating func toggle(_ id: String) {
        guard messages.contains(where: { $0.id == id }) else { return }
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// Whether every card is open, which turns Expand all into Collapse all.
    public var allExpanded: Bool { messages.allSatisfy { expanded.contains($0.id) } }

    public mutating func expandAll() {
        expanded = Set(messages.map(\.id))
    }

    /// Folds every card but the newest, so that the pane always has a message to read.
    public mutating func collapseAll() {
        expanded = newest.map { [$0.id] } ?? []
    }

    /// The control at the top right: Expand all while any card is folded, else Collapse all.
    public mutating func toggleAll() {
        if allExpanded { collapseAll() } else { expandAll() }
    }

    /// The same conversation read again, as its flags change or a message comes or goes. Cards
    /// opened or folded stay so; a message new to the stack opens when it is unread or the newest.
    public mutating func update(_ latest: [MessageSummary]) {
        let known = Set(messages.map(\.id))
        let ordered = Self.newestFirst(latest)
        var open = expanded.intersection(ordered.map(\.id))
        for (index, message) in ordered.enumerated() where !known.contains(message.id) && (index == 0 || !message.isRead) {
            open.insert(message.id)
        }
        messages = ordered
        expanded = open
    }

    /// The messages older than `id`, newest first: the ones a reply to them may quote.
    public func older(than id: String) -> [MessageSummary] {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return [] }
        return Array(messages[(index + 1)...])
    }

    /// Where Reply, Reply All or Forward was asked for.
    public enum ActionSource: Equatable, Sendable {
        /// The small buttons on a card's header, or its menu.
        case card(String)
        /// The ribbon, the Message menu and their shortcuts.
        case conversation
    }

    /// The message Reply, Reply All and Forward act on: a card's own buttons act on that card's
    /// message, the ribbon and the Message menu on the newest. Nil for a card no longer shown.
    public func target(of source: ActionSource) -> MessageSummary? {
        switch source {
        case .card(let id): return messages.first { $0.id == id }
        case .conversation: return newest
        }
    }

    /// A folded card's words after its sender: the message's first words on one line.
    public static func preview(of message: MessageSummary) -> String {
        MessageListText.preview(message.snippet)
    }
}
