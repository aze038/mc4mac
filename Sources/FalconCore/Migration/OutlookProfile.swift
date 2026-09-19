import Foundation

public struct OutlookAccount: Identifiable, Hashable, Sendable {
    public var id: Int
    public var email: String
    public var name: String
    public var folderCount: Int
    public var messageCount: Int
    public var label: String { email.isEmpty ? (name.isEmpty ? "Account \(id)" : name) : email }
}

public struct OutlookProfile: MigrationSource {
    public private(set) var identifier: String
    public private(set) var title: String
    public let dataURL: URL
    public let accountEmail: String
    public private(set) var folders: [SourceFolder]
    public let accounts: [OutlookAccount]
    public private(set) var selectedAccounts: [OutlookAccount] = []
    private let allFolders: [SourceFolder]
    private let folderAccounts: [String: Int]
    private let rows: [OutlookMailRow]
    private let sourcesByUUID: [String: URL]

    struct OutlookMailRow: Sendable {
        var recordID: Int
        var folderID: Int
        var messageID: String
        var read: Bool
        var flagged: Bool
        var received: Double?
        var sent: Double?
        var sourceUUID: String?
    }

    public static var profilesRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/UBF8T346G9.Office/Outlook/Outlook 15 Profiles", isDirectory: true)
    }

    public static func discover() -> [URL] {
        let root = profilesRoot
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.map { root.appendingPathComponent($0).appendingPathComponent("Data", isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Outlook.sqlite").path) }
    }

    public init(dataURL: URL) throws {
        self.dataURL = dataURL
        let profileName = dataURL.deletingLastPathComponent().lastPathComponent
        identifier = "outlook:" + profileName
        let snapshot = try OutlookProfile.snapshotDatabase(at: dataURL)
        defer { try? FileManager.default.removeItem(at: snapshot.deletingLastPathComponent()) }

        var accountRows = try OutlookProfile.query(snapshot, "select Record_RecordID as id, Account_EmailAddress as email, Account_Name as name from AccountsMail")
        if let exchange = try? OutlookProfile.query(snapshot, "select Record_RecordID as id, Account_EmailAddress as email, Account_Name as name from AccountsExchange") {
            accountRows.append(contentsOf: exchange)
        }
        accountEmail = accountRows.first?["email"] as? String ?? ""
        title = "Outlook · " + (accountEmail.isEmpty ? profileName : accountEmail)

        let folderRows = try OutlookProfile.query(snapshot, "select Record_RecordID as id, Folder_ParentID as parent, Folder_SpecialFolderType as special, Folder_Name as name, Record_AccountUID as account from Folders")
        let mailRows = try OutlookProfile.query(snapshot, "select Record_RecordID as id, Record_FolderID as folder, Message_MessageID as mid, Message_ReadFlag as read, Record_FlagStatus as flag, Message_TimeReceived as received, Message_TimeSent as sent from Mail")
        let blockRows = try OutlookProfile.query(snapshot, "select Record_RecordID as id, hex(BlockID) as block from Mail_OwnedBlocks where BlockTag = 1297314403")

        var blocks: [Int: String] = [:]
        for b in blockRows {
            if let id = OutlookProfile.int(b["id"]), let hex = b["block"] as? String { blocks[id] = OutlookProfile.uuidString(hex) }
        }
        var rows: [OutlookMailRow] = []
        for m in mailRows {
            guard let id = OutlookProfile.int(m["id"]), let folder = OutlookProfile.int(m["folder"]) else { continue }
            rows.append(OutlookMailRow(recordID: id, folderID: folder, messageID: (m["mid"] as? String ?? "").trimmed,
                                       read: OutlookProfile.int(m["read"]) == 1, flagged: (OutlookProfile.int(m["flag"]) ?? 0) > 0,
                                       received: m["received"] as? Double, sent: m["sent"] as? Double, sourceUUID: blocks[id]))
        }
        self.rows = rows

        var index: [String: URL] = [:]
        let sourcesRoot = dataURL.appendingPathComponent("Message Sources", isDirectory: true)
        if let e = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil) {
            for case let url as URL in e where url.pathExtension == "olk15MsgSource" {
                index[url.deletingPathExtension().lastPathComponent.uppercased()] = url
            }
        }
        sourcesByUUID = index

        var byID: [Int: (parent: Int, special: Int, name: String)] = [:]
        var accountOf: [String: Int] = [:]
        for f in folderRows {
            guard let id = OutlookProfile.int(f["id"]) else { continue }
            byID[id] = (OutlookProfile.int(f["parent"]) ?? -1, OutlookProfile.int(f["special"]) ?? 0, f["name"] as? String ?? "")
            accountOf[String(id)] = (OutlookProfile.int(f["account"]) ?? 0) & 0xFFFF_FFFF
        }
        folderAccounts = accountOf
        let counts = Dictionary(grouping: rows.filter { $0.sourceUUID != nil }, by: \.folderID).mapValues(\.count)
        var list: [SourceFolder] = []
        for (id, f) in byID where counts[id, default: 0] > 0 {
            var path: [String] = [OutlookProfile.displayName(f.name)]
            var p = f.parent
            var guardCount = 0
            while let parent = byID[p], guardCount < 20 {
                let name = OutlookProfile.displayName(parent.name)
                if !name.isEmpty && parent.special != 99 { path.insert(name, at: 0) }
                p = parent.parent
                guardCount += 1
            }
            list.append(SourceFolder(id: String(id), name: OutlookProfile.displayName(f.name), path: path.joined(separator: "/"),
                                     kind: OutlookProfile.kind(special: f.special, name: f.name), messageCount: counts[id, default: 0]))
        }
        let sorted = list.sorted { ($0.kind.order, $0.path) < ($1.kind.order, $1.path) }
        allFolders = sorted
        folders = sorted
        var accounts: [OutlookAccount] = []
        for a in accountRows {
            guard let id = OutlookProfile.int(a["id"]) else { continue }
            let owned = sorted.filter { accountOf[$0.id] == id }
            accounts.append(OutlookAccount(id: id, email: (a["email"] as? String ?? "").trimmed, name: (a["name"] as? String ?? "").trimmed,
                                           folderCount: owned.count, messageCount: owned.reduce(0) { $0 + $1.messageCount }))
        }
        let known = Set(accounts.map(\.id))
        let local = sorted.filter { !known.contains(accountOf[$0.id] ?? 0) }
        if !local.isEmpty {
            accounts.append(OutlookAccount(id: 0, email: "", name: "On My Computer", folderCount: local.count, messageCount: local.reduce(0) { $0 + $1.messageCount }))
        }
        self.accounts = accounts.filter { $0.folderCount > 0 }
    }

    public func selecting(_ accountIDs: Set<Int>) -> OutlookProfile {
        var copy = self
        let profileName = dataURL.deletingLastPathComponent().lastPathComponent
        let chosen = accounts.filter { accountIDs.contains($0.id) }
        copy.selectedAccounts = chosen
        guard !chosen.isEmpty, chosen.count < accounts.count else {
            copy.selectedAccounts = []
            copy.folders = allFolders
            copy.identifier = "outlook:" + profileName
            copy.title = "Outlook · " + (accountEmail.isEmpty ? profileName : accountEmail)
            return copy
        }
        let known = Set(accounts.map(\.id))
        let wanted = Set(chosen.map(\.id))
        copy.folders = allFolders.filter { f in
            let owner = folderAccounts[f.id] ?? 0
            let effective = known.contains(owner) ? owner : 0
            return wanted.contains(effective)
        }
        copy.identifier = "outlook:" + profileName + ":" + wanted.sorted().map(String.init).joined(separator: "+")
        copy.title = "Outlook · " + chosen.map(\.label).joined(separator: ", ")
        return copy
    }

    public func messages(in folder: SourceFolder) throws -> [SourceMessage] {
        guard let folderID = Int(folder.id) else { return [] }
        return rows.filter { $0.folderID == folderID }.compactMap { row in
            guard let uuid = row.sourceUUID, let url = sourcesByUUID[uuid] else { return nil }
            return SourceMessage(folderID: folder.id, messageID: row.messageID, isRead: row.read, isFlagged: row.flagged,
                                 date: OutlookProfile.validDate(row.received) ?? OutlookProfile.validDate(row.sent)) {
                try OutlookProfile.mime(at: url)
            }
        }
    }

    static func validDate(_ seconds: Double?) -> Date? {
        guard let seconds, seconds > 978_393_600 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func mime(at url: URL) throws -> Data {
        let raw = try Data(contentsOf: url)
        var body = raw
        if let tag = raw.range(of: Data("crSM".utf8)), tag.upperBound + 4 <= raw.count {
            body = raw.subdata(in: (tag.upperBound + 4)..<raw.count)
        }
        return MIMENormalizer.crlf(body)
    }

    static func snapshotDatabase(at dataURL: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("falconmail-outlook-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["Outlook.sqlite", "Outlook.sqlite-wal", "Outlook.sqlite-shm"] {
            let src = dataURL.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: src.path) { try FileManager.default.copyItem(at: src, to: dir.appendingPathComponent(name)) }
        }
        return dir.appendingPathComponent("Outlook.sqlite")
    }

    static func query(_ db: URL, _ sql: String) throws -> [[String: Any]] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = ["-readonly", "-json", db.path, sql]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw FalconError.storage("Could not read the Outlook database: " + String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        if data.isEmpty { return [] }
        return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }

    static func uuidString(_ hex: String) -> String {
        let h = hex.count > 32 ? String(hex.uppercased().suffix(32)) : hex.uppercased()
        guard h.count == 32 else { return h }
        let parts = [8, 4, 4, 4, 12]
        var out: [String] = []
        var i = h.startIndex
        for n in parts {
            let j = h.index(i, offsetBy: n)
            out.append(String(h[i..<j]))
            i = j
        }
        return out.joined(separator: "-")
    }

    static func displayName(_ raw: String) -> String {
        guard raw.hasPrefix("Placeholder_") else { return raw }
        return raw.replacingOccurrences(of: "Placeholder_", with: "").replacingOccurrences(of: "_Placeholder", with: "").replacingOccurrences(of: "_", with: " ")
    }

    static func kind(special: Int, name: String) -> SourceFolderKind {
        switch special {
        case 1: return .inbox
        case 2: return .outbox
        case 8: return .sent
        case 9: return .trash
        case 10: return .drafts
        case 12: return .junk
        case 15: return .archive
        case 3, 4, 5, 6, 99, 103: return .system
        default:
            let n = name.lowercased()
            if n == "archive" || n == "archives" || n == "all mail" { return .archive }
            return .other
        }
    }
}

extension SourceFolderKind {
    var order: Int {
        switch self {
        case .inbox: return 0
        case .drafts: return 1
        case .sent: return 2
        case .archive: return 3
        case .other: return 4
        case .junk: return 5
        case .trash: return 6
        case .outbox: return 7
        case .system: return 8
        }
    }
}
