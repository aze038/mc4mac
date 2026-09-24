import Foundation

public struct FileLayout: Sendable {
    public let root: URL

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.root = base.appendingPathComponent("FalconMail", isDirectory: true)
        }
    }

    public var accountsFile: URL { root.appendingPathComponent("accounts.json") }
    public var signaturesFile: URL { root.appendingPathComponent("signatures.json") }
    public var rulesFile: URL { root.appendingPathComponent("rules.json") }
    public var archivesFile: URL { root.appendingPathComponent("archives.json") }
    public var pendingActionsFile: URL { root.appendingPathComponent("pendingActions.json") }
    public var moveTargetsFile: URL { root.appendingPathComponent("moveTargets.json") }
    public var mutedFile: URL { root.appendingPathComponent("muted.json") }
    public var notificationPolicyFile: URL { root.appendingPathComponent("notifications.json") }
    public var outboxDirectory: URL { root.appendingPathComponent("Outbox", isDirectory: true) }
    public var contactsDirectory: URL { root.appendingPathComponent("Contacts", isDirectory: true) }

    public func accountDirectory(_ accountID: UUID) -> URL {
        root.appendingPathComponent("Accounts", isDirectory: true).appendingPathComponent(accountID.uuidString, isDirectory: true)
    }

    public func foldersFile(_ accountID: UUID) -> URL {
        accountDirectory(accountID).appendingPathComponent("folders.json")
    }

    public func folderDirectory(accountID: UUID, folderID: UUID) -> URL {
        accountDirectory(accountID).appendingPathComponent("Folders", isDirectory: true).appendingPathComponent(folderID.uuidString, isDirectory: true)
    }

    public func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

public enum AtomicFile {
    public static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public static func read(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    public static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try write(try encoder.encode(value), to: url)
    }

    public static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = read(url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}
