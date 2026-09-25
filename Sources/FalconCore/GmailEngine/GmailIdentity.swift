import Foundation

// The keys the Gmail engine works in. Gmail's message and thread ids are 64-bit numbers written
// in hex, so they are held as numbers: the index keeps 32 bytes a message only because an id
// fits in 8 of them, and comparing numbers is cheaper than comparing strings.

/// The hex text of a Gmail id, or nil when it is not one. Only the form Gmail itself writes is
/// taken, lower-case with no leading zeros, because the id is sent back to Gmail as `hex`: any
/// other spelling of the same number would name a message Gmail does not know.
private func gmailHexNumber(_ text: String) -> UInt64? {
    guard (1...16).contains(text.utf8.count),
          let value = UInt64(text, radix: 16),
          String(value, radix: 16) == text else { return nil }
    return value
}

/// A Gmail message id, the API's `id`.
public struct GmailMessageID: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let raw: UInt64

    public init(raw: UInt64) {
        self.raw = raw
    }

    /// Nil unless `hex` is an id as Gmail writes it.
    public init?(hex: String) {
        guard let value = gmailHexNumber(hex) else { return nil }
        raw = value
    }

    /// An id read from one of Gmail's answers. One that does not parse is logged, so that a
    /// change in Gmail's ids shows in the log rather than as mail that quietly never appears.
    public static func fromGmail(_ text: String, in context: String) -> GmailMessageID? {
        if let id = GmailMessageID(hex: text) { return id }
        logRefused(text, what: "message", context: context)
        return nil
    }

    public var hex: String { String(raw, radix: 16) }
    public var description: String { hex }

    public static func < (a: GmailMessageID, b: GmailMessageID) -> Bool { a.raw < b.raw }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let id = GmailMessageID(hex: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a Gmail message id")
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// A Gmail thread id, the API's `threadId`: one conversation.
public struct GmailThreadID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: UInt64

    public init(raw: UInt64) {
        self.raw = raw
    }

    public init?(hex: String) {
        guard let value = gmailHexNumber(hex) else { return nil }
        raw = value
    }

    public static func fromGmail(_ text: String, in context: String) -> GmailThreadID? {
        if let id = GmailThreadID(hex: text) { return id }
        logRefused(text, what: "thread", context: context)
        return nil
    }

    /// The thread key rows of one Gmail conversation share. Server-only search rows already use
    /// this form, so the two kinds of row group together.
    public var threadKey: String { "gm:" + hex }

    public init?(threadKey: String) {
        guard threadKey.hasPrefix("gm:"), let id = GmailThreadID(hex: String(threadKey.dropFirst(3))) else { return nil }
        self = id
    }

    public var hex: String { String(raw, radix: 16) }
    public var description: String { hex }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let id = GmailThreadID(hex: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a Gmail thread id")
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// Only the length goes into the log: the id itself says nothing useful about what went wrong.
private func logRefused(_ text: String, what: String, context: String) {
    Log.info("gmail", "refused a \(what) id of \(text.count) characters in \(context): not a 64-bit hex number")
}

/// A message's id together with its conversation's, as every list and history record gives them.
public struct GmailRef: Hashable, Codable, Sendable {
    public var id: GmailMessageID
    public var threadID: GmailThreadID

    public init(id: GmailMessageID, threadID: GmailThreadID) {
        self.id = id
        self.threadID = threadID
    }
}

/// A Gmail label id: a system label such as `INBOX`, or a user label such as `Label_123`.
public struct GmailLabelID: Hashable, Comparable, Codable, Sendable, CustomStringConvertible,
                            ExpressibleByStringLiteral {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public init(stringLiteral value: String) {
        self.value = value
    }

    public var description: String { value }

    public static func < (a: GmailLabelID, b: GmailLabelID) -> Bool { a.value < b.value }

    public init(from decoder: Decoder) throws {
        value = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    public static let inbox: GmailLabelID = "INBOX"
    public static let sent: GmailLabelID = "SENT"
    public static let draft: GmailLabelID = "DRAFT"
    public static let spam: GmailLabelID = "SPAM"
    public static let trash: GmailLabelID = "TRASH"
    public static let unread: GmailLabelID = "UNREAD"
    public static let starred: GmailLabelID = "STARRED"
    public static let important: GmailLabelID = "IMPORTANT"
    public static let categoryPersonal: GmailLabelID = "CATEGORY_PERSONAL"
    public static let categorySocial: GmailLabelID = "CATEGORY_SOCIAL"
    public static let categoryPromotions: GmailLabelID = "CATEGORY_PROMOTIONS"
    public static let categoryUpdates: GmailLabelID = "CATEGORY_UPDATES"
    public static let categoryForums: GmailLabelID = "CATEGORY_FORUMS"
    public static let chat: GmailLabelID = "CHAT"

    /// The labels with a fixed bit in every index record, in slot order. Slots 14 and 15 are
    /// spare, and 16–63 belong to the largest shown user labels.
    public static let fixedSlots: [GmailLabelID] = [
        .inbox, .sent, .draft, .spam, .trash, .unread, .starred, .important,
        .categoryPersonal, .categorySocial, .categoryPromotions, .categoryUpdates, .categoryForums, .chat
    ]
    public static let firstUserSlot = 16
    public static let slotCount = 64

    private static let slotByLabel: [GmailLabelID: Int] =
        Dictionary(uniqueKeysWithValues: fixedSlots.enumerated().map { ($0.element, $0.offset) })

    /// This label's bit in every index record, when it is one of the fixed system labels.
    public var fixedSlot: Int? { GmailLabelID.slotByLabel[self] }

    /// Gmail names user labels `Label_…`; every other id is one of Gmail's own.
    public var isUserLabel: Bool { value.hasPrefix("Label_") }

    /// Promotions, Social and Forums: the Inbox mail Outlook's Other tab shows. Primary, Updates
    /// and mail with no category are Focused, because order confirmations, shipping notices and
    /// bills arrive as Updates and a freight business has to see them.
    public static let otherCategories: Set<GmailLabelID> = [.categoryPromotions, .categorySocial, .categoryForums]
    public static let categories: Set<GmailLabelID> =
        [.categoryPersonal, .categorySocial, .categoryPromotions, .categoryUpdates, .categoryForums]

    /// Gmail refuses to let an app add or remove these, so no action may ask it to.
    public static let fixedByGmail: Set<GmailLabelID> = [.sent, .draft]
}

/// A position in an account's change history. Gmail sends it as a string of digits.
public struct HistoryID: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let raw: UInt64

    public init(raw: UInt64) {
        self.raw = raw
    }

    public init?(_ text: String) {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let value = UInt64(text) else { return nil }
        raw = value
    }

    public var description: String { String(raw) }

    public static func < (a: HistoryID, b: HistoryID) -> Bool { a.raw < b.raw }

    /// Written as Gmail writes it. A number is read too, since a hand-made file may hold one.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            guard let id = HistoryID(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a history id")
            }
            self = id
        } else {
            raw = try container.decode(UInt64.self)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Gmail's system folders as the owner's Legacy Outlook shows them: Inbox at the top of the
/// account, then the [Gmail] group in Outlook's order and with Outlook's names.
public enum GmailSystemFolder: CaseIterable, Sendable {
    case inbox, drafts, archive, sent, deletedItems, junkEmail, important, starred

    /// The label whose messages the folder shows. Archive is All Mail, which has no label.
    public var label: GmailLabelID? {
        switch self {
        case .inbox: return .inbox
        case .drafts: return .draft
        case .archive: return nil
        case .sent: return .sent
        case .deletedItems: return .trash
        case .junkEmail: return .spam
        case .important: return .important
        case .starred: return .starred
        }
    }

    public var role: FolderRole {
        switch self {
        case .inbox: return .inbox
        case .drafts: return .drafts
        case .archive: return .all
        case .sent: return .sent
        case .deletedItems: return .trash
        case .junkEmail: return .junk
        case .important: return .important
        case .starred: return .flagged
        }
    }

    public var outlookName: String {
        switch self {
        case .inbox: return "Inbox"
        case .drafts: return "Drafts"
        case .archive: return "Archive"
        case .sent: return "Sent"
        case .deletedItems: return "Deleted Items"
        case .junkEmail: return "Junk Email"
        case .important: return "Important"
        case .starred: return "Starred"
        }
    }

    /// Whether it sits in the [Gmail] group rather than at the top of the account.
    public var isInGmailGroup: Bool { self != .inbox }

    /// Drafts, Archive, Sent, Deleted Items and Junk Email lead the group in this order; Important
    /// and Starred follow, sorted by name with the rest of the group.
    public var fixedPlace: Int? {
        switch self {
        case .inbox: return 0
        case .drafts: return 1
        case .archive: return 2
        case .sent: return 3
        case .deletedItems: return 4
        case .junkEmail: return 5
        case .important, .starred: return nil
        }
    }

    public init?(label: GmailLabelID?) {
        guard let found = GmailSystemFolder.allCases.first(where: { $0.label == label }) else { return nil }
        self = found
    }
}
