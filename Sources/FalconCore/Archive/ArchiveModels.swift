import Foundation

public struct ArchiveEncryptionInfo: Codable, Sendable, Hashable {
    public var algorithm: String
    public var kdf: String
    public var iterations: Int
    public var salt: String
    public var check: String
}

public struct ArchiveFolderSummary: Codable, Sendable, Hashable {
    public var path: String
    public var messageCount: Int
}

public struct ArchiveChunkInfo: Codable, Sendable, Hashable {
    public var name: String
    public var messageCount: Int
    public var byteSize: Int
    public var sha256: String
}

public struct ArchiveIndexShard: Codable, Sendable, Hashable {
    public var messages: String
    public var terms: String
}

public struct ArchiveAccountInfo: Codable, Sendable, Hashable {
    public var email: String
    public var provider: String
}

public struct ArchiveManifest: Codable, Sendable, Hashable {
    public static let formatName = "falconmail-archive"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    public var name: String
    public var createdAt: Date
    public var generator: String
    public var account: ArchiveAccountInfo?
    public var encryption: ArchiveEncryptionInfo?
    public var folders: [ArchiveFolderSummary]
    public var chunks: [ArchiveChunkInfo]
    public var indexShards: [ArchiveIndexShard]
    public var messageCount: Int
    public var byteSize: Int

    public var isEncrypted: Bool { encryption != nil }
}

public struct ArchiveEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var folder: String
    public var uid: UInt32
    public var messageId: String
    public var subject: String
    public var from: String
    public var fromName: String
    public var to: [String]
    public var cc: [String]
    public var date: Date
    public var flags: [String]
    public var size: Int
    public var hasAttachments: Bool
    public var attachments: [String]
    public var threadKey: String
    public var chunk: String
    public var entry: String
    public var offset: Int
    public var length: Int
    public var snippet: String
}

public struct ArchiveRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var accountID: UUID?
    public var storageKind: String
    public var rootID: String
    public var createdAt: Date
    public var messageCount: Int
    public var byteSize: Int
    public var isEncrypted: Bool

    public init(name: String, accountID: UUID?, storageKind: String, rootID: String, manifest: ArchiveManifest) {
        self.id = UUID()
        self.name = name
        self.accountID = accountID
        self.storageKind = storageKind
        self.rootID = rootID
        self.createdAt = manifest.createdAt
        self.messageCount = manifest.messageCount
        self.byteSize = manifest.byteSize
        self.isEncrypted = manifest.isEncrypted
    }
}

public enum ArchiveJSON {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static var prettyEncoder: JSONEncoder {
        let e = encoder
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
