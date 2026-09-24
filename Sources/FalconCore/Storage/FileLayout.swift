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
    public var diagnosticsDirectory: URL { root.appendingPathComponent("Diagnostics", isDirectory: true) }

    public func accountDirectory(_ accountID: UUID) -> URL {
        root.appendingPathComponent("Accounts", isDirectory: true).appendingPathComponent(accountID.uuidString, isDirectory: true)
    }

    public func foldersFile(_ accountID: UUID) -> URL {
        accountDirectory(accountID).appendingPathComponent("folders.json")
    }

    /// State kept beside folders.json that earlier builds ignore (`SyncExtras`).
    public func syncExtrasFile(_ accountID: UUID) -> URL {
        accountDirectory(accountID).appendingPathComponent("syncExtras.json")
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

    /// Reads a stored JSON file without ever losing it. A file this build cannot decode, perhaps
    /// written by another version, is moved aside whole under a new name, so the next save
    /// cannot overwrite it; one that cannot be read at all is left where it is. Either way it
    /// is logged, and noted for the owner, as `what`. `names` are the folder names `what` holds,
    /// which diagnostics take out.
    public static func loadJSON<T: Decodable>(_ type: T.Type, from url: URL, what: String, names: [String] = []) -> StoredFile<T> {
        load(from: url, what: what, names: names) { data in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(type, from: data)
        }
    }

    public static func load<T>(from url: URL, what: String, names: [String] = [], decode: (Data) throws -> T) -> StoredFile<T> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            Log.error("Store", "could not read \(what) at \(url.lastPathComponent): \(error.localizedDescription)", error: error,
                      code: "unreadable", names: names, logAs: "store")
            StoredFileNotices.add(what, names: names)
            return .unreadable(detail: error.localizedDescription)
        }
        do {
            return .loaded(try decode(data))
        } catch {
            let detail = String(describing: error)
            guard let aside = setAside(url) else {
                Log.error("Store", "could not decode \(what) at \(url.lastPathComponent), and could not move it aside: \(detail)",
                          error: error, code: "unreadable", names: names, logAs: "store")
                StoredFileNotices.add(what, names: names)
                return .unreadable(detail: detail)
            }
            Log.error("Store", "could not decode \(what); kept it as \(aside.lastPathComponent): \(detail)", error: error,
                      code: "setAside", names: names, logAs: "store")
            StoredFileNotices.add(what, names: names)
            return .setAside(aside, detail: detail)
        }
    }

    /// The copies of `url` set aside so far, oldest first.
    public static func setAsideCopies(of url: URL) -> [URL] {
        let prefix = url.lastPathComponent + ".unreadable-"
        let listed = (try? FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        return listed.filter { $0.lastPathComponent.hasPrefix(prefix) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Renames `url` to `<name>.unreadable-<date>`, never replacing an earlier one. Nil when the
    /// file could not be moved.
    static func setAside(_ url: URL) -> URL? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(url.lastPathComponent).unreadable-\(f.string(from: Date()))"
        let directory = url.deletingLastPathComponent()
        for n in 0..<100 {
            let aside = directory.appendingPathComponent(n == 0 ? base : "\(base)-\(n)")
            guard !FileManager.default.fileExists(atPath: aside.path) else { continue }
            do {
                try FileManager.default.moveItem(at: url, to: aside)
                return aside
            } catch {
                return nil
            }
        }
        return nil
    }
}

/// What reading a stored file gave.
public enum StoredFile<Value> {
    case missing
    case loaded(Value)
    /// There but not understood: moved whole to the URL, which nothing writes to.
    case setAside(URL, detail: String)
    /// There but not readable, as with wrong permissions: left alone, and must not be written over.
    case unreadable(detail: String)

    public var value: Value? {
        if case .loaded(let v) = self { return v }
        return nil
    }

    /// True unless saving would write over a file that is still there and was never read.
    public var canSave: Bool {
        if case .unreadable = self { return false }
        return true
    }
}

/// Stored files this run could not read, named for the owner, so the app can say so once
/// instead of starting quietly without them.
public enum StoredFileNotices {
    private static let lock = NSLock()
    private static var notes: [(what: String, names: [String])] = []

    static func add(_ what: String, names: [String] = []) {
        lock.withLock { notes.append((what, names)) }
    }

    /// The names noted since the last call.
    public static func take() -> [String] {
        lock.withLock {
            defer { notes.removeAll() }
            return notes.map(\.what)
        }
    }

    /// What to tell the owner of the files noted since the last call, nil when there are none,
    /// with the folder names it holds for diagnostics to take out.
    public static func takeNotice() -> StoredFileNotice? {
        let taken = lock.withLock {
            defer { notes.removeAll() }
            return notes
        }
        guard !taken.isEmpty else { return nil }
        return StoredFileNotice(text: "FalconMail could not read \(ListFormatter.localizedString(byJoining: taken.map(\.what))). "
                                    + "Nothing was written over: each was left as it was or kept under a name ending in “unreadable”. "
                                    + "Details are in the log.",
                                names: Array(Set(taken.flatMap(\.names))).sorted())
    }
}

/// The owner's notice of stored files that could not be read.
public struct StoredFileNotice: Sendable, Equatable {
    public var text: String
    /// The folder names `text` holds.
    public var names: [String]
}

/// A folder's stored list of messages that is there but could not be read, as with wrong
/// permissions. Nothing is written over it, and the folder is not synced until it can be read.
public struct FolderIndexUnreadable: Error, LocalizedError, Sendable, Equatable {
    /// The folder as the owner is told of it, such as "HR of ana@example.com".
    public var folder: String
    /// The folder's path and name, which diagnostics take out of every line about it.
    public var names: [String]
    public var detail: String

    public var errorDescription: String? { "The messages listed for \(folder) could not be read: \(detail)" }
}
