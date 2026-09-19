import Foundation

public enum SourceFolderKind: String, Codable, Sendable {
    case inbox, sent, drafts, trash, junk, archive, outbox, other, system
}

public struct SourceFolder: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var path: String
    public var kind: SourceFolderKind
    public var messageCount: Int

    public init(id: String, name: String, path: String, kind: SourceFolderKind, messageCount: Int) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.messageCount = messageCount
    }
}

public struct SourceMessage: Sendable {
    public var folderID: String
    public var messageID: String
    public var isRead: Bool
    public var isFlagged: Bool
    public var date: Date?
    public var load: @Sendable () throws -> Data

    public init(folderID: String, messageID: String, isRead: Bool, isFlagged: Bool, date: Date?, load: @escaping @Sendable () throws -> Data) {
        self.folderID = folderID
        self.messageID = messageID
        self.isRead = isRead
        self.isFlagged = isFlagged
        self.date = date
        self.load = load
    }
}

public protocol MigrationSource: Sendable {
    var identifier: String { get }
    var title: String { get }
    var folders: [SourceFolder] { get }
    func messages(in folder: SourceFolder) throws -> [SourceMessage]
}

public enum MIMENormalizer {
    public static func crlf(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count + data.count / 30)
        var previous: UInt8 = 0
        for b in data {
            if b == 0x0A {
                if previous != 0x0D { out.append(0x0D) }
                out.append(0x0A)
            } else if previous == 0x0D && b != 0x0A {
                out.append(0x0A)
                out.append(b)
            } else if b != 0x0D {
                out.append(b)
            } else {
                out.append(b)
            }
            previous = b
        }
        if previous == 0x0D { out.append(0x0A) }
        return out
    }

    public static func messageID(in data: Data) -> String {
        let headers = MIMEParser.parseHeaders(data)
        return AddressParser.messageIDs(headers.first("Message-ID")).first ?? ""
    }
}
