import Foundation
import CryptoKit
@testable import FalconCore

/// v1.10.3's stored files, as v1.10.3 declares them (mc4mac `5ad12ba`): its own types, copied
/// field for field with its synthesised coding, so a test can write what v1.10.3 wrote and read
/// back what this build writes the way v1.10.3 would. v1.10.3 decodes strictly: every field it
/// declares without `?` must be there, and it skips any key it does not know.
enum PreviousRelease {
    struct EmailAddress: Codable, Equatable {
        var name: String
        var address: String
    }

    enum FolderRole: String, Codable {
        case inbox, sent, drafts, trash, junk, archive, all, flagged, important, other
    }

    struct AccountInfo: Codable, Equatable {
        var id: UUID
        var email: String
        var displayName: String
        var provider: String
        var imapHost: String
        var imapPort: UInt16
        var smtpHost: String
        var smtpPort: UInt16
        var signature: String
        var isEnabled: Bool
        var createdAt: Date
        var authMethod: String?
        var username: String?
    }

    struct FolderInfo: Codable, Equatable {
        var id: UUID
        var accountID: UUID
        var path: String
        var name: String
        var delimiter: String
        var role: FolderRole
        var attributes: [String]
        var isSelectable: Bool
        var uidValidity: UInt32
        var uidNext: UInt32
        var lastSyncedUID: UInt32
        var oldestSyncedUID: UInt32
        var totalCount: Int
        var unreadCount: Int
        var lastSyncDate: Date?
    }

    struct MessageSummary: Codable, Equatable {
        var id: String
        var accountID: UUID
        var folderID: UUID
        var uid: UInt32
        var messageID: String
        var inReplyTo: String
        var references: [String]
        var subject: String
        var from: EmailAddress
        var to: [EmailAddress]
        var cc: [EmailAddress]
        var date: Date
        var isRead: Bool
        var isFlagged: Bool
        var isAnswered: Bool
        var isDraft: Bool
        var size: Int
        var snippet: String
        var hasAttachments: Bool
        var hasBody: Bool
        var threadKey: String
    }

    struct OutboxItem: Codable, Equatable {
        enum Status: String, Codable { case queued, sending, sent, failed, cancelled }
        var id: UUID
        var accountID: UUID
        var subject: String
        var recipients: [String]
        var sender: String
        var sendAt: Date
        var createdAt: Date
        var status: Status
        var error: String?
        var undoUntil: Date
        var attempts: Int?
        var heldBack: Bool?
        var sendBegan: Bool?
    }

    struct PendingServerOperation: Codable, Equatable {
        enum Verb: String, Codable { case archive, move, expunge, store }
        var id: UUID
        var accountID: UUID
        var folderID: UUID
        var verb: Verb
        var uids: [UInt32]
        var uidValidity: UInt32?
        var destinationPath: String
        var flagNames: [String]
        var enabled: Bool
        var date: Date
    }

    struct MutedThread: Codable, Equatable {
        var accountID: UUID
        var threadKey: String
        var messageIDs: Set<String>
        var normalizedSubject: String
        var subject: String
        var mutedAt: Date
    }

    /// v1.10.3's session.json, whose every field has a default and is therefore required.
    struct SessionState: Codable {
        var selectedMessageIDs: [String]
        var searchText: String
        var openMessageWindows: [String]
        var trayMessageWindows: [String]?
        var openDraftIDs: [UUID]
        var savedAt: Date
    }

    /// A stored row, as a test describes it.
    struct Row {
        var uid: UInt32
        var messageID: String
        var subject: String
        var date: Date

        static let samples = [
            Row(uid: 101, messageID: "<invoice-7@supplier.example>", subject: "Invoice 7", date: Date(timeIntervalSince1970: 1_789_000_000)),
            Row(uid: 102, messageID: "<rates@carrier.example>", subject: "Rates for October", date: Date(timeIntervalSince1970: 1_789_100_000)),
            Row(uid: 103, messageID: "", subject: "No Message-ID", date: Date(timeIntervalSince1970: 1_789_200_000))
        ]
    }

    /// What `writeStore` wrote.
    struct Store {
        var folders: [FolderInfo]
        var inbox: FolderInfo
        var rows: [MessageSummary]

        func key(uid: UInt32) -> String { rows.first { $0.uid == uid }!.id }
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func account(_ a: FalconCore.AccountInfo) -> AccountInfo {
        AccountInfo(id: a.id, email: a.email, displayName: a.displayName, provider: a.provider, imapHost: a.imapHost, imapPort: a.imapPort,
                    smtpHost: a.smtpHost, smtpPort: a.smtpPort, signature: a.signature, isEnabled: a.isEnabled, createdAt: a.createdAt,
                    authMethod: a.authMethod, username: a.username)
    }

    /// `accounts.json`, the account's `folders.json`, and an Inbox with `rows` in its index and one
    /// more row and a flag change in its journal, as v1.10.3 writes them.
    static func writeStore(for account: FalconCore.AccountInfo, rows: [Row], layout: FileLayout) throws -> Store {
        var accounts = (try? decoder().decode([AccountInfo].self, from: Data(contentsOf: layout.accountsFile))) ?? []
        accounts.removeAll { $0.id == account.id }
        accounts.append(Self.account(account))
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        try encoder().encode(accounts).write(to: layout.accountsFile, options: .atomic)
        func folder(_ path: String, _ name: String, _ role: FolderRole, validity: UInt32) -> FolderInfo {
            FolderInfo(id: UUID(), accountID: account.id, path: path, name: name, delimiter: "/", role: role,
                       attributes: role == .inbox || role == .other ? [] : ["\\" + name.replacingOccurrences(of: " ", with: "")],
                       isSelectable: true, uidValidity: validity, uidNext: 200, lastSyncedUID: 150, oldestSyncedUID: 1, totalCount: rows.count,
                       unreadCount: 1, lastSyncDate: Date(timeIntervalSince1970: 1_789_300_000))
        }
        let inbox = folder("INBOX", "Inbox", .inbox, validity: 1_700_000_000)
        let folders = [inbox, folder("[Gmail]/Sent Mail", "Sent Mail", .sent, validity: 1_700_000_100),
                       folder("[Gmail]/Drafts", "Drafts", .drafts, validity: 1_700_000_110),
                       folder("[Gmail]/Trash", "Trash", .trash, validity: 1_700_000_200),
                       folder("[Gmail]/Spam", "Spam", .junk, validity: 1_700_000_210),
                       folder("[Gmail]/All Mail", "All Mail", .all, validity: 1_700_000_300),
                       folder("Clients", "Clients", .other, validity: 1_700_000_400)]
        try FileManager.default.createDirectory(at: layout.accountDirectory(account.id), withIntermediateDirectories: true)
        try encoder().encode(folders).write(to: layout.foldersFile(account.id), options: .atomic)
        let stored = rows.map { row in
            MessageSummary(id: "\(account.id.uuidString):\(inbox.id.uuidString):\(row.uid)", accountID: account.id, folderID: inbox.id,
                           uid: row.uid, messageID: row.messageID, inReplyTo: "", references: [], subject: row.subject,
                           from: EmailAddress(name: "Ana", address: "ana@supplier.example"),
                           to: [EmailAddress(name: "", address: account.email)], cc: [], date: row.date, isRead: row.uid != 101,
                           isFlagged: false, isAnswered: false, isDraft: false, size: 4_000, snippet: "First words of \(row.subject)",
                           hasAttachments: false, hasBody: false, threadKey: row.messageID)
        }
        let directory = layout.folderDirectory(accountID: account.id, folderID: inbox.id)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Bodies", isDirectory: true), withIntermediateDirectories: true)
        let plist = PropertyListEncoder()
        plist.outputFormat = .binary
        let indexed = stored.dropLast()
        try plist.encode(Array(indexed)).write(to: directory.appendingPathComponent("index.plist"), options: .atomic)
        // The last row arrived after the index was written, and the first was flagged since:
        // both are only in the journal, as FolderStore appends them.
        var journal = Data()
        if let last = stored.last { journal.append(try JSONEncoder().encode(JournalUpsert(upsert: JournalUpsert.Payload(_0: last)))) }
        journal.append(0x0A)
        journal.append(Data(#"{"flags":{"uid":101,"flags":5}}"#.utf8))
        journal.append(0x0A)
        try journal.write(to: directory.appendingPathComponent("journal.jsonl"), options: .atomic)
        return Store(folders: folders, inbox: inbox, rows: stored)
    }

    /// `FolderJournalOp.upsert` as Swift's synthesised coding writes it.
    private struct JournalUpsert: Encodable {
        struct Payload: Encodable {
            // swiftlint:disable:next identifier_name
            var _0: MessageSummary
        }
        var upsert: Payload
    }

    /// Every file under `directory` but those under `excluding`, by path, with a digest of its bytes.
    static func digest(of directory: URL, excluding: String) -> [String: String] {
        var out: [String: String] = [:]
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return out }
        let base = directory.standardizedFileURL.path
        for case let url as URL in walker {
            let path = String(url.standardizedFileURL.path.dropFirst(base.count))
            if path.hasPrefix("/" + excluding + "/") || path == "/" + excluding { continue }
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            if isFile, let data = try? Data(contentsOf: url) {
                out[path] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            } else {
                out[path] = "directory"
            }
        }
        return out
    }
}
