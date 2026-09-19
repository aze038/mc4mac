import Foundation

public struct GoogleDriveStorage: ArchiveStorage {
    public let kind = "googleDrive"
    let api: GoogleAPI
    static let filesURL = URL(string: "https://www.googleapis.com/drive/v3/files")!
    static let uploadURL = URL(string: "https://www.googleapis.com/upload/drive/v3/files")!
    public static let folderMime = "application/vnd.google-apps.folder"

    struct DriveFile: Decodable {
        var id: String
        var name: String
        var mimeType: String
        var size: String?
        var modifiedTime: Date?
    }

    struct FileList: Decodable {
        var files: [DriveFile]
        var nextPageToken: String?
    }

    public init(tokens: TokenStore, accountID: UUID) {
        api = GoogleAPI(tokens: tokens, accountID: accountID)
    }

    public func createFolder(name: String, parentID: String?) async throws -> String {
        struct Meta: Encodable { var name: String; var mimeType: String; var parents: [String] }
        let meta = Meta(name: name, mimeType: GoogleDriveStorage.folderMime, parents: [parentID ?? "root"])
        let f: DriveFile = try await api.json(DriveFile.self, "POST", GoogleDriveStorage.filesURL, body: meta, query: ["fields": "id,name,mimeType"])
        return f.id
    }

    public func list(parentID: String?) async throws -> [RemoteFile] {
        var out: [RemoteFile] = []
        var token: String?
        repeat {
            var q = ["q": "'\(parentID ?? "root")' in parents and trashed = false",
                     "fields": "nextPageToken,files(id,name,mimeType,size,modifiedTime)", "pageSize": "1000"]
            if let token { q["pageToken"] = token }
            let page: FileList = try await api.json(FileList.self, "GET", GoogleDriveStorage.filesURL, query: q)
            out.append(contentsOf: page.files.map { RemoteFile(id: $0.id, name: $0.name, isFolder: $0.mimeType == GoogleDriveStorage.folderMime,
                                                               size: $0.size.flatMap { Int($0) }, modified: $0.modifiedTime) })
            token = page.nextPageToken
        } while token != nil
        return out
    }

    public func find(name: String, parentID: String?) async throws -> RemoteFile? {
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let q = ["q": "name = '\(escaped)' and '\(parentID ?? "root")' in parents and trashed = false",
                 "fields": "files(id,name,mimeType,size,modifiedTime)", "pageSize": "10"]
        let page: FileList = try await api.json(FileList.self, "GET", GoogleDriveStorage.filesURL, query: q)
        return page.files.first.map { RemoteFile(id: $0.id, name: $0.name, isFolder: $0.mimeType == GoogleDriveStorage.folderMime,
                                                 size: $0.size.flatMap { Int($0) }, modified: $0.modifiedTime) }
    }

    public func listArchives() async throws -> [RemoteFile] {
        let q = ["q": "mimeType = '\(GoogleDriveStorage.folderMime)' and name contains '.fmarchive' and trashed = false",
                 "fields": "files(id,name,mimeType,modifiedTime)", "pageSize": "200"]
        let page: FileList = try await api.json(FileList.self, "GET", GoogleDriveStorage.filesURL, query: q)
        return page.files.map { RemoteFile(id: $0.id, name: $0.name, isFolder: true, modified: $0.modifiedTime) }
    }

    public func upload(name: String, parentID: String, data: Data, mimeType: String) async throws -> String {
        struct Meta: Encodable { var name: String; var parents: [String] }
        let created: DriveFile = try await api.json(DriveFile.self, "POST", GoogleDriveStorage.filesURL,
                                                    body: Meta(name: name, parents: [parentID]), query: ["fields": "id,name,mimeType"])
        let url = URL(string: "https://www.googleapis.com/upload/drive/v3/files/\(created.id)?uploadType=media")!
        _ = try await api.request("PATCH", url, body: data, contentType: mimeType)
        return created.id
    }

    public func beginUpload(name: String, parentID: String, mimeType: String) async throws -> ArchiveUploadSession {
        struct Meta: Encodable { var name: String; var parents: [String] }
        let body = try JSONEncoder().encode(Meta(name: name, parents: [parentID]))
        var comps = URLComponents(url: GoogleDriveStorage.uploadURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "uploadType", value: "resumable")]
        let (_, response) = try await api.request("POST", comps.url!, body: body, contentType: "application/json; charset=UTF-8",
                                                  headers: ["X-Upload-Content-Type": mimeType])
        guard let location = response.value(forHTTPHeaderField: "Location"), let sessionURL = URL(string: location) else {
            throw FalconError.network("Drive did not return an upload session")
        }
        return DriveUploadSession(api: api, sessionURL: sessionURL)
    }

    public func read(fileID: String, range: Range<Int>?) async throws -> Data {
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)?alt=media")!
        var headers: [String: String] = [:]
        if let range { headers["Range"] = "bytes=\(range.lowerBound)-\(range.upperBound - 1)" }
        let (data, _) = try await api.request("GET", url, headers: headers)
        if let range, data.count > range.count { return data.subdata(in: range.lowerBound..<range.upperBound) }
        return data
    }

    public func delete(fileID: String) async throws {
        _ = try await api.request("DELETE", URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)")!)
    }
}

final class DriveUploadSession: ArchiveUploadSession, @unchecked Sendable {
    private let api: GoogleAPI
    private let sessionURL: URL
    private let lock = NSLock()
    private var buffer = Data()
    private var sent = 0
    private let pieceSize = 8 * 1024 * 1024
    private let granularity = 256 * 1024

    init(api: GoogleAPI, sessionURL: URL) {
        self.api = api
        self.sessionURL = sessionURL
    }

    func write(_ data: Data) async throws {
        lock.lock()
        buffer.append(data)
        lock.unlock()
        while buffer.count >= pieceSize {
            let count = (buffer.count / granularity) * granularity
            let piece = buffer.prefix(count)
            try await send(Data(piece), total: nil)
            lock.lock()
            buffer.removeFirst(count)
            lock.unlock()
        }
    }

    func finish() async throws -> String {
        let total = sent + buffer.count
        let last = buffer
        buffer = Data()
        return try await send(last, total: total)
    }

    @discardableResult
    private func send(_ piece: Data, total: Int?) async throws -> String {
        let start = sent
        let end = start + piece.count - 1
        let rangeHeader: String
        if piece.isEmpty {
            rangeHeader = "bytes */\(total ?? 0)"
        } else {
            rangeHeader = "bytes \(start)-\(end)/\(total.map(String.init) ?? "*")"
        }
        var attempt = 0
        while true {
            do {
                let (data, response) = try await api.request("PUT", sessionURL, body: piece, contentType: "application/octet-stream",
                                                             headers: ["Content-Range": rangeHeader], accept: [200, 201, 308])
                sent += piece.count
                if response.statusCode == 308 { return "" }
                struct Reply: Decodable { var id: String }
                return (try? JSONDecoder().decode(Reply.self, from: data))?.id ?? ""
            } catch {
                attempt += 1
                if attempt >= 4 { throw error }
                try await Task.sleep(nanoseconds: UInt64(attempt * 2) * 1_000_000_000)
            }
        }
    }
}
