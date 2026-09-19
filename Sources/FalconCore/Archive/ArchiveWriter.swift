import Foundation

public struct ArchiveOptions: Sendable {
    public var chunkByteLimit: Int
    public var chunkEntryLimit: Int
    public var password: String?

    public init(chunkByteLimit: Int = 256 * 1024 * 1024, chunkEntryLimit: Int = 60_000, password: String? = nil) {
        self.chunkByteLimit = chunkByteLimit
        self.chunkEntryLimit = chunkEntryLimit
        self.password = password
    }
}

public struct ArchiveInput: Sendable {
    public var folderPath: String
    public var uid: UInt32
    public var raw: Data
    public var flags: MessageFlags

    public init(folderPath: String, uid: UInt32, raw: Data, flags: MessageFlags) {
        self.folderPath = folderPath
        self.uid = uid
        self.raw = raw
        self.flags = flags
    }
}

public actor ArchiveWriter {
    public let storage: ArchiveStorage
    public let name: String
    private let parentID: String?
    private let account: AccountInfo?
    private let options: ArchiveOptions
    private var crypto: ArchiveCrypto?
    private var encryptionInfo: ArchiveEncryptionInfo?
    private var rootID = ""
    private var chunksID = ""
    private var indexID = ""
    private var chunk: ZipChunkWriter?
    private var chunkNumber = 0
    private var chunkEntries: [ArchiveEntry] = []
    private var chunkTerms: [String: [Int]] = [:]
    private var chunks: [ArchiveChunkInfo] = []
    private var shards: [ArchiveIndexShard] = []
    private var folderCounts: [String: Int] = [:]
    private var totalMessages = 0
    private var totalBytes = 0
    private var threadKeys: [String: String] = [:]

    public init(storage: ArchiveStorage, parentID: String?, name: String, account: AccountInfo?, options: ArchiveOptions = ArchiveOptions()) {
        self.storage = storage
        self.parentID = parentID
        self.name = name
        self.account = account
        self.options = options
    }

    public var rootFolderID: String { rootID }

    public func begin() async throws {
        if let password = options.password, !password.isEmpty {
            let (c, info) = try ArchiveCrypto.create(password: password)
            crypto = c
            encryptionInfo = info
        }
        rootID = try await storage.createFolder(name: "\(name).fmarchive", parentID: parentID)
        chunksID = try await storage.createFolder(name: "chunks", parentID: rootID)
        indexID = try await storage.createFolder(name: "index", parentID: rootID)
    }

    public func add(_ input: ArchiveInput) async throws {
        let parsed = MIMEParser.parse(input.raw)
        let shortID = String(UUID().uuidString.prefix(8)).lowercased()
        let folderName = input.folderPath.replacingOccurrences(of: "\\", with: "/")
        var entryName = "\(folderName)/\(input.uid)-\(shortID).eml"
        var payload = input.raw
        if let crypto {
            payload = try crypto.seal(payload)
            entryName += ".enc"
        }
        if let current = chunk, current.entryCount >= options.chunkEntryLimit || current.projectedSize(adding: payload, name: entryName) > options.chunkByteLimit {
            try await closeChunk()
        }
        if chunk == nil { try await openChunk() }
        guard let current = chunk else { throw FalconError.storage("no chunk") }
        let date = parsed.date ?? Date()
        let (offset, length) = try await current.add(name: entryName, data: payload, modified: date)

        let key = ConversationThreader.threadKey(messageID: parsed.messageID, inReplyTo: parsed.inReplyTo, references: parsed.references,
                                                 subject: parsed.subject) { threadKeys[$0] }
        if !parsed.messageID.isEmpty { threadKeys[parsed.messageID] = key }
        let entry = ArchiveEntry(
            id: shortID, folder: input.folderPath, uid: input.uid, messageId: parsed.messageID, subject: parsed.subject,
            from: parsed.from.address, fromName: parsed.from.name, to: parsed.to.map { $0.address }, cc: parsed.cc.map { $0.address },
            date: date, flags: input.flags.archiveNames, size: input.raw.count, hasAttachments: !parsed.attachments.isEmpty,
            attachments: parsed.attachments.map { $0.filename }, threadKey: key, chunk: "chunks/\(current.name)", entry: entryName,
            offset: offset, length: length, snippet: parsed.snippet)
        let line = chunkEntries.count
        chunkEntries.append(entry)
        for term in ArchiveTerms.tokens(entry: entry, body: parsed.bestText) {
            chunkTerms[term, default: []].append(line)
        }
        folderCounts[input.folderPath, default: 0] += 1
        totalMessages += 1
        totalBytes += input.raw.count
    }

    public func finish() async throws -> ArchiveManifest {
        if chunk != nil { try await closeChunk() }
        let manifest = ArchiveManifest(
            format: ArchiveManifest.formatName, version: ArchiveManifest.currentVersion, name: name, createdAt: Date(),
            generator: "FalconMail 1.0.0", account: account.map { ArchiveAccountInfo(email: $0.email, provider: $0.provider) },
            encryption: encryptionInfo,
            folders: folderCounts.map { ArchiveFolderSummary(path: $0.key, messageCount: $0.value) }.sorted { $0.path < $1.path },
            chunks: chunks, indexShards: shards, messageCount: totalMessages, byteSize: totalBytes)
        let data = try ArchiveJSON.prettyEncoder.encode(manifest)
        _ = try await storage.upload(name: "manifest.json", parentID: rootID, data: data, mimeType: "application/json")
        return manifest
    }

    private func openChunk() async throws {
        chunkNumber += 1
        let chunkName = String(format: "chunk-%05d.zip", chunkNumber)
        let session = try await storage.beginUpload(name: chunkName, parentID: chunksID, mimeType: "application/zip")
        chunk = ZipChunkWriter(session: session, name: chunkName)
        chunkEntries = []
        chunkTerms = [:]
    }

    private func closeChunk() async throws {
        guard let current = chunk else { return }
        let result = try await current.close()
        chunks.append(ArchiveChunkInfo(name: "chunks/\(current.name)", messageCount: current.entryCount, byteSize: result.byteSize, sha256: result.sha256))
        let suffix = String(format: "%05d", chunkNumber)
        var messagesData = Data()
        let encoder = ArchiveJSON.encoder
        for e in chunkEntries {
            messagesData.append(try encoder.encode(e))
            messagesData.append(0x0A)
        }
        var termsData = try JSONEncoder().encode(chunkTerms)
        var messagesName = "messages-\(suffix).jsonl"
        var termsName = "terms-\(suffix).json"
        if let crypto {
            messagesData = try crypto.seal(messagesData)
            termsData = try crypto.seal(termsData)
            messagesName += ".enc"
            termsName += ".enc"
        }
        _ = try await storage.upload(name: messagesName, parentID: indexID, data: messagesData, mimeType: "application/octet-stream")
        _ = try await storage.upload(name: termsName, parentID: indexID, data: termsData, mimeType: "application/octet-stream")
        shards.append(ArchiveIndexShard(messages: "index/\(messagesName)", terms: "index/\(termsName)"))
        chunk = nil
        chunkEntries = []
        chunkTerms = [:]
    }
}

public enum ArchiveTerms {
    public static func tokens(entry: ArchiveEntry, body: String) -> Set<String> {
        var text = entry.subject + " " + entry.from + " " + entry.fromName + " " + entry.to.joined(separator: " ") + " " + entry.cc.joined(separator: " ")
        text += " " + entry.attachments.joined(separator: " ") + " " + body.prefix(200_000)
        return tokenize(text, limit: 5000)
    }

    public static func tokenize(_ text: String, limit: Int = Int.max) -> Set<String> {
        var out = Set<String>()
        var current = ""
        func flush() {
            if current.count >= 2 && current.count <= 40 { out.insert(current) }
            current = ""
        }
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "@" || scalar == "." || scalar == "-" || scalar == "_" {
                current.unicodeScalars.append(scalar)
            } else {
                flush()
                if out.count >= limit { break }
            }
        }
        flush()
        var expanded = out
        for t in out where t.contains("@") || t.contains(".") || t.contains("-") || t.contains("_") {
            for piece in t.split(whereSeparator: { "@.-_".contains($0) }) where piece.count >= 2 { expanded.insert(String(piece)) }
        }
        return expanded
    }
}
