import Foundation

public struct EmailAddress: Codable, Hashable, Sendable {
    public var name: String
    public var address: String

    public init(name: String = "", address: String) {
        self.name = name
        self.address = address
    }

    public var displayName: String { name.isEmpty ? address : name }

    public var rfc5322: String {
        if name.isEmpty { return address }
        let needsQuote = name.contains(where: { "()<>[]:;@\\,.\"".contains($0) })
        let n = needsQuote ? "\"" + name.replacingOccurrences(of: "\"", with: "\\\"") + "\"" : name
        return "\(n) <\(address)>"
    }
}

public enum FolderRole: String, Codable, Sendable, CaseIterable {
    case inbox, sent, drafts, trash, junk, archive, all, flagged, important, other

    public var sortOrder: Int {
        switch self {
        case .inbox: return 0
        case .drafts: return 1
        case .sent: return 2
        case .archive: return 3
        case .junk: return 4
        case .trash: return 5
        case .flagged: return 6
        case .important: return 7
        case .all: return 8
        case .other: return 9
        }
    }
}

public struct AccountInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var email: String
    public var displayName: String
    public var provider: String
    public var imapHost: String
    public var imapPort: UInt16
    public var smtpHost: String
    public var smtpPort: UInt16
    public var signature: String
    public var isEnabled: Bool
    public var createdAt: Date
    public var authMethod: String?
    public var username: String?

    public var usesPassword: Bool { authMethod == "password" }
    public var loginName: String { username?.isEmpty == false ? username! : email }

    public init(id: UUID = UUID(), email: String, displayName: String, provider: String = "google",
                imapHost: String = "imap.gmail.com", imapPort: UInt16 = 993,
                smtpHost: String = "smtp.gmail.com", smtpPort: UInt16 = 465,
                signature: String = "", isEnabled: Bool = true, createdAt: Date = Date(),
                authMethod: String? = nil, username: String? = nil) {
        self.authMethod = authMethod
        self.username = username
        self.id = id
        self.email = email
        self.displayName = displayName
        self.provider = provider
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.signature = signature
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }

    public static func google(email: String, displayName: String) -> AccountInfo {
        AccountInfo(email: email, displayName: displayName, authMethod: "oauth")
    }

    public static func custom(email: String, displayName: String, imapHost: String, imapPort: UInt16,
                              smtpHost: String, smtpPort: UInt16, username: String) -> AccountInfo {
        AccountInfo(email: email, displayName: displayName, provider: "imap", imapHost: imapHost, imapPort: imapPort,
                    smtpHost: smtpHost, smtpPort: smtpPort, authMethod: "password", username: username)
    }
}

public struct FolderInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var accountID: UUID
    public var path: String
    public var name: String
    public var delimiter: String
    public var role: FolderRole
    public var attributes: [String]
    public var isSelectable: Bool
    public var uidValidity: UInt32
    public var uidNext: UInt32
    public var lastSyncedUID: UInt32
    public var oldestSyncedUID: UInt32
    public var totalCount: Int
    public var unreadCount: Int
    public var lastSyncDate: Date?

    public init(id: UUID = UUID(), accountID: UUID, path: String, name: String, delimiter: String,
                role: FolderRole, attributes: [String], isSelectable: Bool) {
        self.id = id
        self.accountID = accountID
        self.path = path
        self.name = name
        self.delimiter = delimiter
        self.role = role
        self.attributes = attributes
        self.isSelectable = isSelectable
        self.uidValidity = 0
        self.uidNext = 0
        self.lastSyncedUID = 0
        self.oldestSyncedUID = 0
        self.totalCount = 0
        self.unreadCount = 0
        self.lastSyncDate = nil
    }

    public var depth: Int {
        guard !delimiter.isEmpty else { return 0 }
        return path.components(separatedBy: delimiter).count - 1
    }
}

public struct MessageSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var accountID: UUID
    public var folderID: UUID
    public var uid: UInt32
    public var messageID: String
    public var inReplyTo: String
    public var references: [String]
    public var subject: String
    public var from: EmailAddress
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var date: Date
    public var isRead: Bool
    public var isFlagged: Bool
    public var isAnswered: Bool
    public var isDraft: Bool
    public var size: Int
    public var snippet: String
    public var hasAttachments: Bool
    public var hasBody: Bool
    public var threadKey: String

    public static func makeID(accountID: UUID, folderID: UUID, uid: UInt32) -> String {
        "\(accountID.uuidString):\(folderID.uuidString):\(uid)"
    }

    public init(accountID: UUID, folderID: UUID, uid: UInt32, messageID: String, inReplyTo: String,
                references: [String], subject: String, from: EmailAddress, to: [EmailAddress], cc: [EmailAddress],
                date: Date, flags: MessageFlags, size: Int, snippet: String = "", hasAttachments: Bool,
                hasBody: Bool = false, threadKey: String = "") {
        self.id = MessageSummary.makeID(accountID: accountID, folderID: folderID, uid: uid)
        self.accountID = accountID
        self.folderID = folderID
        self.uid = uid
        self.messageID = messageID
        self.inReplyTo = inReplyTo
        self.references = references
        self.subject = subject
        self.from = from
        self.to = to
        self.cc = cc
        self.date = date
        self.isRead = flags.contains(.seen)
        self.isFlagged = flags.contains(.flagged)
        self.isAnswered = flags.contains(.answered)
        self.isDraft = flags.contains(.draft)
        self.size = size
        self.snippet = snippet
        self.hasAttachments = hasAttachments
        self.hasBody = hasBody
        self.threadKey = threadKey
    }

    public var flags: MessageFlags {
        var f = MessageFlags()
        if isRead { f.insert(.seen) }
        if isFlagged { f.insert(.flagged) }
        if isAnswered { f.insert(.answered) }
        if isDraft { f.insert(.draft) }
        return f
    }

    public mutating func apply(flags: MessageFlags) {
        isRead = flags.contains(.seen)
        isFlagged = flags.contains(.flagged)
        isAnswered = flags.contains(.answered)
        isDraft = flags.contains(.draft)
    }
}

public struct MessageFlags: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let seen = MessageFlags(rawValue: 1 << 0)
    public static let answered = MessageFlags(rawValue: 1 << 1)
    public static let flagged = MessageFlags(rawValue: 1 << 2)
    public static let deleted = MessageFlags(rawValue: 1 << 3)
    public static let draft = MessageFlags(rawValue: 1 << 4)

    public init(imapFlags: [String]) {
        var v = MessageFlags()
        for f in imapFlags {
            switch f.lowercased() {
            case "\\seen": v.insert(.seen)
            case "\\answered": v.insert(.answered)
            case "\\flagged": v.insert(.flagged)
            case "\\deleted": v.insert(.deleted)
            case "\\draft": v.insert(.draft)
            default: break
            }
        }
        self = v
    }

    public var imapFlags: [String] {
        var out: [String] = []
        if contains(.seen) { out.append("\\Seen") }
        if contains(.answered) { out.append("\\Answered") }
        if contains(.flagged) { out.append("\\Flagged") }
        if contains(.deleted) { out.append("\\Deleted") }
        if contains(.draft) { out.append("\\Draft") }
        return out
    }

    public var archiveNames: [String] {
        var out: [String] = []
        if contains(.seen) { out.append("seen") }
        if contains(.answered) { out.append("answered") }
        if contains(.flagged) { out.append("flagged") }
        if contains(.draft) { out.append("draft") }
        return out
    }
}

public struct ContactInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var accountID: UUID
    public var name: String
    public var email: String
    public var source: String
    public var useCount: Int
    public var lastUsed: Date?

    public init(id: String, accountID: UUID, name: String, email: String, source: String, useCount: Int = 0, lastUsed: Date? = nil) {
        self.id = id
        self.accountID = accountID
        self.name = name
        self.email = email
        self.source = source
        self.useCount = useCount
        self.lastUsed = lastUsed
    }
}

public enum FalconError: Error, LocalizedError, Sendable {
    case notAuthenticated
    case protocolError(String)
    case network(String)
    case http(Int, String)
    case storage(String)
    case invalidInput(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not signed in."
        // What the server said goes to the log; the owner reads a plain sentence.
        case .protocolError: return "The mail server refused the request."
        case .network(let s): return "Network error: \(s)"
        case .http(let code, let s): return "HTTP \(code): \(s)"
        case .storage(let s): return "Storage error: \(s)"
        case .invalidInput(let s): return s
        case .cancelled: return "Cancelled."
        }
    }
}
