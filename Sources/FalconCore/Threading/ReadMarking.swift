import Foundation

/// Which messages reading marks read. Mail is read message by message: a message is read when it
/// is itself shown open, never because another message of its conversation was. Selecting a
/// conversation's row reads its newest message, the one its stack shows open; each of the others
/// is read when its card is opened or its own line in the list is selected. Only the Read/Unread
/// commands mark a whole conversation, when the owner asks for it.
///
/// Reading marks a message read after the delay chosen in Settings → Reading, and never when
/// the owner chose Never there; the commands act at once whatever was chosen.
public enum ReadMarking {
    /// A line of the message list, by what selecting it shows in the reading pane.
    public enum Line: Equatable, Sendable {
        /// A conversation's own row: its stack, with the newest message open. A conversation of
        /// one message is that message.
        case conversation([MessageSummary])
        /// One of a conversation's message lines, or a message listed on its own: that message
        /// alone.
        case message(MessageSummary)
    }

    /// What the message list's selection tag for one of a conversation's message lines starts
    /// with, before the message's id. A conversation's own row is tagged with its newest
    /// message's id.
    public static let messageLineTag = "child:"

    /// The line of the list selected as `tag`, among `conversations` as the list holds them, each
    /// newest first. Nil for a tag naming no message there, such as a group's heading.
    public static func line(tagged tag: String, in conversations: [[MessageSummary]]) -> Line? {
        guard tag.hasPrefix(messageLineTag) else {
            return conversations.first { $0.first?.id == tag }.map { .conversation($0) }
        }
        let id = String(tag.dropFirst(messageLineTag.count))
        for conversation in conversations {
            if let message = conversation.first(where: { $0.id == id }) { return .message(message) }
        }
        return nil
    }

    /// What selecting `line` marks read once the delay has passed: the one message it shows
    /// open, when that message is unread. The rest of a conversation keeps its state.
    public static func toMarkRead(selecting line: Line) -> [MessageSummary] {
        switch line {
        case .conversation(let messages): return ConversationStack(messages).toMarkRead
        case .message(let message): return message.isRead ? [] : [message]
        }
    }

    /// Whether the Home ribbon's Read/Unread, the list's Mark as Read or Unread, its quick action,
    /// its swipe and the U key mark `messages` read rather than unread. They act on every message
    /// of each conversation chosen, as Outlook does: read while any of them is unread, else
    /// unread.
    public static func readUnreadMarksRead(_ messages: [MessageSummary]) -> Bool {
        messages.contains { !$0.isRead }
    }
}
