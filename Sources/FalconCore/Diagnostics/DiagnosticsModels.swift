import Foundation
import CryptoKit

/// What happened, in the words of docs/DIAGNOSTICS.md.
public enum DiagnosticsKind: String, Codable, Sendable, CaseIterable {
    case error, warning, crash, hang, cpu, diskwrite, health, launch

    /// A crash or a MetricKit report carries its own stack, so two of them are never folded
    /// into one even when their signatures match.
    public var folds: Bool {
        switch self {
        case .error, .warning, .health, .launch: return true
        case .crash, .hang, .cpu, .diskwrite: return false
        }
    }

    /// Worth sending within a minute rather than at the next hourly upload.
    public var isUrgent: Bool { self == .crash || self == .hang }
}

/// The account an event concerns, without anything that identifies it outside this install.
public struct DiagnosticsAccount: Codable, Hashable, Sendable {
    public var provider: String
    public var kind: String
    public var host: String
    public var ref: String

    public init(provider: String, kind: String, host: String, ref: String) {
        self.provider = provider
        self.kind = kind
        self.host = host
        self.ref = ref
    }

    public init(_ account: AccountInfo, redactor: DiagnosticsRedactor) {
        self.init(provider: account.provider, kind: DiagnosticsAccount.kind(of: account),
                  host: account.imapHost, ref: redactor.ref(account.email))
    }

    public static func kind(of account: AccountInfo) -> String {
        let domain = account.email.split(separator: "@").last.map { $0.lowercased() } ?? ""
        if domain == "gmail.com" || domain == "googlemail.com" { return "gmail" }
        return account.provider == "google" ? "workspace" : "other"
    }
}

public struct DiagnosticsApp: Codable, Hashable, Sendable {
    public var version: String
    public var build: String
    public var channel: String

    public init(version: String, build: String, channel: String) {
        self.version = version
        self.build = build
        self.channel = channel
    }
}

/// One entry in an upload's `events` list.
public struct DiagnosticsEvent: Codable, Hashable, Sendable, Identifiable {
    public static let maxMessage = 2_000
    public static let maxContextBytes = 16 * 1024
    public static let maxTitle = 120
    /// The most occurrences one event may count; the backend caps `count` here. The queue starts
    /// a new event rather than fold past it, so no occurrence goes uncounted.
    public static let maxCount = 10_000

    public var id: String
    public var kind: DiagnosticsKind
    public var signature: String
    public var title: String
    public var area: String
    public var count: Int
    public var firstAt: Date
    public var lastAt: Date
    public var message: String
    public var context: JSONValue
    public var account: DiagnosticsAccount?

    /// Holds every field to the contract's limits, so nothing built elsewhere can overrun them.
    public init(id: String = UUID().uuidString, kind: DiagnosticsKind, signature: String, title: String, area: String,
                count: Int = 1, firstAt: Date, lastAt: Date? = nil, message: String, context: JSONValue = .object([:]),
                account: DiagnosticsAccount? = nil) {
        self.id = id
        self.kind = kind
        self.signature = signature
        self.title = String(title.prefix(DiagnosticsEvent.maxTitle))
        self.area = area
        self.count = max(1, count)
        self.firstAt = firstAt
        self.lastAt = max(firstAt, lastAt ?? firstAt)
        self.message = message.count > DiagnosticsEvent.maxMessage
            ? String(message.prefix(DiagnosticsEvent.maxMessage - 1)) + "…" : message
        self.context = context.fitted(to: DiagnosticsEvent.maxContextBytes)
        self.account = account
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, signature, title, area, count, firstAt, lastAt, message, context, account
    }

    // The contract spells out `"account": null`, which the synthesised encoder would leave out.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(signature, forKey: .signature)
        try c.encode(title, forKey: .title)
        try c.encode(area, forKey: .area)
        try c.encode(count, forKey: .count)
        try c.encode(firstAt, forKey: .firstAt)
        try c.encode(lastAt, forKey: .lastAt)
        try c.encode(message, forKey: .message)
        try c.encode(context, forKey: .context)
        if let account { try c.encode(account, forKey: .account) } else { try c.encodeNil(forKey: .account) }
    }

    /// The same UUID for the same seed within one install, so an event found twice, a crash
    /// report read again after its state was lost, is dropped by the server as a duplicate.
    public static func stableID(_ seed: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return uuid.uuidString
    }
}

/// A queued event and the build that saw it, so an event queued before an update still goes
/// out under the version it happened in.
public struct DiagnosticsRecord: Codable, Hashable, Sendable {
    public var event: DiagnosticsEvent
    public var app: DiagnosticsApp
    public var os: String
    /// Once part of an upload attempt an event is never folded into again: a resend must carry
    /// exactly what the server may already hold under that id.
    public var sealed: Bool

    public init(event: DiagnosticsEvent, app: DiagnosticsApp, os: String, sealed: Bool = false) {
        self.event = event
        self.app = app
        self.os = os
        self.sealed = sealed
    }
}

/// The body of one upload.
public struct DiagnosticsUpload: Encodable, Sendable {
    public var schema = 1
    public var key: String
    public var install: String
    public var app: DiagnosticsApp
    public var os: String
    public var hw: String
    public var locale: String
    public var sentAt: Date
    public var events: [DiagnosticsEvent]

    public init(key: String, install: String, app: DiagnosticsApp, os: String, hw: String, locale: String,
                sentAt: Date, events: [DiagnosticsEvent]) {
        self.key = key
        self.install = install
        self.app = app
        self.os = os
        self.hw = hw
        self.locale = locale
        self.sentAt = sentAt
        self.events = events
    }
}

public enum DiagnosticsJSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func iso(_ date: Date) -> String {
        ISO8601DateFormatter.archive.string(from: date)
    }
}
