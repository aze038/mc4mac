import Foundation

public struct RemoteFile: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var isFolder: Bool
    public var size: Int?
    public var modified: Date?

    public init(id: String, name: String, isFolder: Bool, size: Int? = nil, modified: Date? = nil) {
        self.id = id
        self.name = name
        self.isFolder = isFolder
        self.size = size
        self.modified = modified
    }
}

public protocol ArchiveUploadSession: AnyObject, Sendable {
    func write(_ data: Data) async throws
    func finish() async throws -> String
}

public protocol ArchiveStorage: Sendable {
    var kind: String { get }
    func createFolder(name: String, parentID: String?) async throws -> String
    func list(parentID: String?) async throws -> [RemoteFile]
    func find(name: String, parentID: String?) async throws -> RemoteFile?
    func upload(name: String, parentID: String, data: Data, mimeType: String) async throws -> String
    func beginUpload(name: String, parentID: String, mimeType: String) async throws -> ArchiveUploadSession
    func read(fileID: String, range: Range<Int>?) async throws -> Data
    func delete(fileID: String) async throws
}

extension ArchiveStorage {
    public func findOrCreateFolder(name: String, parentID: String?) async throws -> String {
        if let f = try await find(name: name, parentID: parentID), f.isFolder { return f.id }
        return try await createFolder(name: name, parentID: parentID)
    }
}

public struct LocalFolderStorage: ArchiveStorage {
    public let kind = "local"
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    private func url(_ id: String?) -> URL {
        guard let id, !id.isEmpty else { return root }
        return URL(fileURLWithPath: id)
    }

    public func createFolder(name: String, parentID: String?) async throws -> String {
        let u = url(parentID).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u.path
    }

    public func list(parentID: String?) async throws -> [RemoteFile] {
        let dir = url(parentID)
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])) ?? []
        return items.map { u in
            let values = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            return RemoteFile(id: u.path, name: u.lastPathComponent, isFolder: values?.isDirectory ?? false,
                              size: values?.fileSize, modified: values?.contentModificationDate)
        }
    }

    public func find(name: String, parentID: String?) async throws -> RemoteFile? {
        try await list(parentID: parentID).first { $0.name == name }
    }

    public func upload(name: String, parentID: String, data: Data, mimeType: String) async throws -> String {
        let u = url(parentID).appendingPathComponent(name)
        try data.write(to: u, options: .atomic)
        return u.path
    }

    public func beginUpload(name: String, parentID: String, mimeType: String) async throws -> ArchiveUploadSession {
        let u = url(parentID).appendingPathComponent(name)
        FileManager.default.createFile(atPath: u.path, contents: nil)
        return try LocalUploadSession(url: u)
    }

    public func read(fileID: String, range: Range<Int>?) async throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: fileID))
        defer { try? handle.close() }
        guard let range else { return try handle.readToEnd() ?? Data() }
        try handle.seek(toOffset: UInt64(range.lowerBound))
        return try handle.read(upToCount: range.count) ?? Data()
    }

    public func delete(fileID: String) async throws {
        try FileManager.default.removeItem(atPath: fileID)
    }
}

final class LocalUploadSession: ArchiveUploadSession, @unchecked Sendable {
    private let handle: FileHandle
    private let url: URL

    init(url: URL) throws {
        self.url = url
        self.handle = try FileHandle(forWritingTo: url)
    }

    func write(_ data: Data) async throws {
        try handle.write(contentsOf: data)
    }

    func finish() async throws -> String {
        try handle.close()
        return url.path
    }
}
