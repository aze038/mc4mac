import Foundation

/// A conversation as the reading pane shows it when its row in the list is clicked: every message
/// one under another, newest at the top, the way Gmail shows a conversation but the other way up,
/// which is the owner's choice. Only the newest message starts open; the others, read or not,
/// are one line each and open on a click, an unread one with its blue dot and blue sender. Only
/// an open card fetches its message's text.
///
/// Mail is read message by message: showing the stack reads only its newest message, and each
/// of the others is read when its card is opened, never because the conversation was selected.
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

    /// The cards open when the stack opens: the newest message alone. An unread message below it
    /// starts folded and stays unread until its card is opened.
    public static func startsOpen(_ messages: [MessageSummary]) -> Set<String> {
        newestFirst(messages).first.map { [$0.id] } ?? []
    }

    public var newest: MessageSummary? { messages.first }

    public func isExpanded(_ id: String) -> Bool { expanded.contains(id) }

    /// The open cards' messages, newest first: the ones whose text is fetched.
    public var expandedMessages: [MessageSummary] { messages.filter { expanded.contains($0.id) } }

    /// What showing the stack marks read once the delay in Settings → Reading has passed, as
    /// selecting a message marks it: the newest message, the one card that starts open, when it
    /// is unread. The others stay unread whatever else is opened, until their own card is.
    public var toMarkRead: [MessageSummary] { newest.map { $0.isRead ? [] : [$0] } ?? [] }

    /// A click on a card's header or folded line: it opens, or folds again. Returns the message
    /// this click opened when it is unread, the one message the click reads.
    @discardableResult
    public mutating func toggle(_ id: String) -> MessageSummary? {
        guard let message = messages.first(where: { $0.id == id }) else { return nil }
        if expanded.contains(id) {
            expanded.remove(id)
            return nil
        }
        expanded.insert(id)
        return message.isRead ? nil : message
    }

    /// Whether every card is open, which turns Expand all into Collapse all.
    public var allExpanded: Bool { messages.allSatisfy { expanded.contains($0.id) } }

    /// Opens every card to be looked through; it reads none of them.
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
    /// opened or folded stay so; a message new to the stack opens when it is the newest, and
    /// starts folded otherwise, unread or not.
    public mutating func update(_ latest: [MessageSummary]) {
        let known = Set(messages.map(\.id))
        let ordered = Self.newestFirst(latest)
        var open = expanded.intersection(ordered.map(\.id))
        if let newest = ordered.first, !known.contains(newest.id) { open.insert(newest.id) }
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
