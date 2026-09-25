import Foundation

/// What the list, message windows, notifications and actions pass around to name one message.
///
/// A Google row's string form is `"<accountUUID>:gm:<hex>"`. `MailStore.message(id:)` reads the
/// middle part as a folder UUID, finds none, and so never resolves it: no path written for stored
/// IMAP rows can act on a Gmail message by mistake. Every path that must act on one is routed to
/// the account's engine instead.
public enum RowKey: Hashable, Sendable, CustomStringConvertible {
    case gmail(account: UUID, id: GmailMessageID)
    /// Today's `"<account>:<folder>:<uid>"` id of a row kept by `MailStore`.
    case stored(String)

    static let gmailMarker = "gm"

    /// Nil for an empty string, and for one that has the Google form but not a valid account or
    /// message id: treating that as a stored id would send it where it can never be found.
    public init?(string: String) {
        guard !string.isEmpty else { return nil }
        let parts = string.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1] == RowKey.gmailMarker else {
            self = .stored(string)
            return
        }
        guard let account = UUID(uuidString: String(parts[0])), let id = GmailMessageID(hex: String(parts[2])) else { return nil }
        self = .gmail(account: account, id: id)
    }

    public var stringValue: String {
        switch self {
        case .gmail(let account, let id): return "\(account.uuidString):\(RowKey.gmailMarker):\(id.hex)"
        case .stored(let id): return id
        }
    }

    public var description: String { stringValue }

    /// The account the message belongs to; nil for a stored id that does not start with one.
    public var accountID: UUID? {
        switch self {
        case .gmail(let account, _): return account
        case .stored(let id): return id.split(separator: ":").first.flatMap { UUID(uuidString: String($0)) }
        }
    }

    public var gmailID: GmailMessageID? {
        if case .gmail(_, let id) = self { return id }
        return nil
    }

    public var isGmail: Bool { gmailID != nil }
}

extension RowKey: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let key = RowKey(string: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a row key")
        }
        self = key
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue)
    }
}

extension MessageSummary {
    /// The key of the row this summary was built for. A Google row's id is its key's string form.
    public var rowKey: RowKey { RowKey(string: id) ?? .stored(id) }
}
