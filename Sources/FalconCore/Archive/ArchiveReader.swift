import Foundation

public actor ArchiveReader {
    public let storage: ArchiveStorage
    public let rootID: String
    private var password: String?
    private var crypto: ArchiveCrypto?
    public private(set) var manifest: ArchiveManifest?
    private var fileIDs: [String: String] = [:]
    public private(set) var entries: [ArchiveEntry] = []
    private var terms: [String: [Int]] = [:]
    private var indexLoaded = false

    public init(storage: ArchiveStorage, rootID: String, password: String? = nil) {
        self.storage = storage
        self.rootID = rootID
        self.password = password
    }

    public func open() async throws -> ArchiveManifest {
        if let m = manifest { return m }
        let rootFiles = try await storage.list(parentID: rootID)
        guard let manifestFile = rootFiles.first(where: { $0.name == "manifest.json" }) else {
            throw FalconError.storage("manifest.json not found in archive")
        }
        let data = try await storage.read(fileID: manifestFile.id, range: nil)
        let m = try ArchiveJSON.decoder.decode(ArchiveManifest.self, from: data)
        guard m.format == ArchiveManifest.formatName else { throw FalconError.storage("not a FalconMail archive") }
        if let enc = m.encryption, let password, !password.isEmpty {
            crypto = try ArchiveCrypto.open(password: password, info: enc)
        }
        for f in rootFiles where f.isFolder && (f.name == "chunks" || f.name == "index") {
            for child in try await storage.list(parentID: f.id) { fileIDs["\(f.name)/\(child.name)"] = child.id }
        }
        manifest = m
        return m
    }

    public func setPassword(_ p: String) throws {
        password = p
        if let enc = manifest?.encryption { crypto = try ArchiveCrypto.open(password: p, info: enc) }
    }

    public func loadIndex() async throws {
        guard !indexLoaded else { return }
        let m = try await open()
        if m.isEncrypted && crypto == nil { throw FalconError.invalidInput("This archive is encrypted. Enter the password.") }
        var all: [ArchiveEntry] = []
        var merged: [String: [Int]] = [:]
        let decoder = ArchiveJSON.decoder
        for shard in m.indexShards {
            let base = all.count
            guard let msgID = fileIDs[shard.messages] else { continue }
            var data = try await storage.read(fileID: msgID, range: nil)
            if let crypto { data = try crypto.unseal(data) }
            for line in data.split(separator: 0x0A) {
                if let e = try? decoder.decode(ArchiveEntry.self, from: line) { all.append(e) }
            }
            if let termID = fileIDs[shard.terms] {
                var tdata = try await storage.read(fileID: termID, range: nil)
                if let crypto { tdata = try crypto.unseal(tdata) }
                if let shardTerms = try? JSONDecoder().decode([String: [Int]].self, from: tdata) {
                    for (t, lines) in shardTerms { merged[t, default: []].append(contentsOf: lines.map { $0 + base }) }
                }
            }
        }
        entries = all.sorted { $0.date > $1.date }
        let order = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($0.element.id + "|" + $0.element.entry, $0.offset) })
        var remap: [Int: Int] = [:]
        for (i, e) in entries.enumerated() { if let original = order[e.id + "|" + e.entry] { remap[original] = i } }
        terms = merged.mapValues { $0.compactMap { remap[$0] } }
        indexLoaded = true
    }

    public func search(_ query: String) -> [ArchiveEntry] {
        let words = ArchiveTerms.tokenize(query.lowercased())
        guard !words.isEmpty else { return entries }
        var result: Set<Int>?
        for w in words {
            var matches = Set<Int>(terms[w] ?? [])
            if matches.isEmpty {
                for (t, lines) in terms where t.hasPrefix(w) { matches.formUnion(lines) }
            }
            result = result.map { $0.intersection(matches) } ?? matches
            if result?.isEmpty == true { break }
        }
        return (result ?? []).sorted().map { entries[$0] }
    }

    public func message(_ entry: ArchiveEntry) async throws -> Data {
        let m = try await open()
        if m.isEncrypted && crypto == nil { throw FalconError.invalidInput("This archive is encrypted. Enter the password.") }
        guard let chunkID = fileIDs[entry.chunk] else { throw FalconError.storage("chunk \(entry.chunk) not found") }
        let data = try await storage.read(fileID: chunkID, range: entry.offset..<(entry.offset + entry.length))
        guard data.count == entry.length else { throw FalconError.storage("short read from archive") }
        if let crypto { return try crypto.unseal(data) }
        return data
    }

    public func folders() -> [String] {
        Array(Set(entries.map { $0.folder })).sorted()
    }
}

public actor ArchiveRecordStore {
    private let url: URL
    private var records: [ArchiveRecord] = []

    public init(layout: FileLayout) {
        url = layout.archivesFile
        records = AtomicFile.readJSON([ArchiveRecord].self, from: url) ?? []
    }

    public func all() -> [ArchiveRecord] { records.sorted { $0.createdAt > $1.createdAt } }

    public func add(_ r: ArchiveRecord) throws {
        records.removeAll { $0.rootID == r.rootID && $0.storageKind == r.storageKind }
        records.append(r)
        try AtomicFile.writeJSON(records, to: url)
    }

    public func remove(_ id: UUID) throws {
        records.removeAll { $0.id == id }
        try AtomicFile.writeJSON(records, to: url)
    }
}
