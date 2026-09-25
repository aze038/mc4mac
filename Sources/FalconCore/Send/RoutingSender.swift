import Foundation

/// How one account's mail goes out.
public enum SendRoute: Sendable {
    /// By SMTP, as every account sent before the Gmail engine, and every account not switched to
    /// it still does.
    case smtp
    /// A switched Google account: by Gmail's own send only.
    case gmail(any MessageSender)
    /// A switched Google account whose Gmail engine is not running yet, as while it starts or
    /// waits for the owner to sign in again. Its mail waits in the Outbox; it never goes by
    /// SMTP instead.
    case gmailUnavailable
}

/// The Outbox's one sender, which hands each message to its account's way of sending: Gmail's
/// `messages.send` for a switched Google account, and SMTP for every other account. There is no
/// SMTP fallback for a switched Google account (§8.1, open question 10).
public struct RoutingSender: MessageSender {
    private let smtp: any MessageSender
    private let route: @Sendable (UUID) async -> SendRoute

    /// `route` is asked for every step, so switching an account takes effect with its next
    /// message. An attempt looked for after the switch is looked for the new way, which for SMTP
    /// finds nothing and so holds it for the owner: never a second send.
    public init(smtp: any MessageSender, route: @escaping @Sendable (UUID) async -> SendRoute) {
        self.smtp = smtp
        self.route = route
    }

    static let notReady = SendFailure(next: .retry,
                                      sentence: "Gmail isn't ready to send from this account yet. The message stays in the Outbox and goes by itself.",
                                      code: "notConnected")

    public func send(accountID: UUID, from: String, recipients: [String], message: Data) async throws {
        switch await route(accountID) {
        case .smtp: try await smtp.send(accountID: accountID, from: from, recipients: recipients, message: message)
        case .gmail(let gmail): try await gmail.send(accountID: accountID, from: from, recipients: recipients, message: message)
        case .gmailUnavailable: throw RoutingSender.notReady
        }
    }

    public func prepare(_ item: OutboxItem, message: Data) async -> OutboxItem {
        switch await route(item.accountID) {
        case .smtp: return await smtp.prepare(item, message: message)
        case .gmail(let gmail): return await gmail.prepare(item, message: message)
        case .gmailUnavailable: return item
        }
    }

    public func send(_ item: OutboxItem, message: Data) async throws -> OutboxItem {
        switch await route(item.accountID) {
        case .smtp: return try await smtp.send(item, message: message)
        case .gmail(let gmail): return try await gmail.send(item, message: message)
        case .gmailUnavailable: throw RoutingSender.notReady
        }
    }

    public func confirm(_ item: OutboxItem) async -> SendConfirmation {
        switch await route(item.accountID) {
        case .smtp: return await smtp.confirm(item)
        case .gmail(let gmail): return await gmail.confirm(item)
        // A later look may find the engine running.
        case .gmailUnavailable: return .lookFailed
        }
    }

    public func finish(_ item: OutboxItem) async -> OutboxItem {
        switch await route(item.accountID) {
        case .smtp: return await smtp.finish(item)
        case .gmail(let gmail): return await gmail.finish(item)
        case .gmailUnavailable: return item
        }
    }
}
