import Foundation

enum FolderJournalOp: Codable {
    case upsert(MessageSummary)
    case flags(uid: UInt32, flags: MessageFlags)
    case remove(uids: [UInt32])
    case body(uid: UInt32, snippet: String, hasAttachments: Bool)
    case threadKey(uid: UInt32, key: String)
}

public actor FolderStore {
    public let folderID: UUID
    public let accountID: UUID
    private let directory: URL
    private var messages: [UInt32: MessageSummary] = [:]
    private var byMessageID: [String: UInt32] = [:]
    private var journalHandle: FileHandle?
    private var journalOps = 0
    private var loaded = false
    private let compactThreshold = 2000

    private var snapshotURL: URL { directory.appendingPathComponent("index.plist") }
    private var journalURL: URL { directory.appendingPathComponent("journal.jsonl") }
    private var bodiesURL: URL { directory.appendingPathComponent("Bodies", isDirectory: true) }

    public init(accountID: UUID, folderID: UUID, directory: URL) {
        self.accountID = accountID
        self.folderID = folderID
        self.directory = directory
    }

    public func load() throws {
        guard !loaded else { return }
        loaded = true
        try FileManager.default.createDirectory(at: bodiesURL, withIntermediateDirectories: true)
        if let data = AtomicFile.read(snapshotURL),
           let list = try? PropertyListDecoder().decode([MessageSummary].self, from: data) {
            for m in list { messages[m.uid] = m }
        }
        if let data = AtomicFile.read(journalURL) {
            let decoder = JSONDecoder()
            for line in data.split(separator: 0x0A) {
                if let op = try? decoder.decode(FolderJournalOp.self, from: line) { apply(op) ; journalOps += 1 }
            }
        }
        for m in messages.values where !m.messageID.isEmpty { byMessageID[m.messageID] = m.uid }
        if journalOps > compactThreshold { try compact() }
    }

    public var count: Int { messages.count }

    public func all() -> [MessageSummary] {
        Array(messages.values)
    }

    public func message(uid: UInt32) -> MessageSummary? { messages[uid] }

    public func uids() -> Set<UInt32> { Set(messages.keys) }

    public func uid(forMessageID id: String) -> UInt32? { byMessageID[id] }

    public func threadKey(forMessageID id: String) -> String? {
        guard let uid = byMessageID[id] else { return nil }
        return messages[uid]?.threadKey
    }

    public func threadKeys(for ids: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for id in ids {
            if let uid = byMessageID[id], let key = messages[uid]?.threadKey, !key.isEmpty { out[id] = key }
        }
        return out
    }

    public func upsert(_ batch: [MessageSummary]) throws {
        for m in batch {
            try journal(.upsert(m))
            apply(.upsert(m))
        }
        try compactIfNeeded()
    }

    public func setFlags(_ updates: [(uid: UInt32, flags: MessageFlags)]) throws -> [UInt32] {
        var changed: [UInt32] = []
        for u in updates {
            guard let existing = messages[u.uid], existing.flags != u.flags else { continue }
            try journal(.flags(uid: u.uid, flags: u.flags))
            apply(.flags(uid: u.uid, flags: u.flags))
            changed.append(u.uid)
        }
        try compactIfNeeded()
        return changed
    }

    public func remove(uids: [UInt32]) throws {
        let present = uids.filter { messages[$0] != nil }
        guard !present.isEmpty else { return }
        try journal(.remove(uids: present))
        apply(.remove(uids: present))
        for uid in present { try? FileManager.default.removeItem(at: bodyURL(uid)) }
        try compactIfNeeded()
    }

    public func removeAll() throws {
        messages.removeAll()
        byMessageID.removeAll()
        journalHandle?.closeFile()
        journalHandle = nil
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: bodiesURL, withIntermediateDirectories: true)
        journalOps = 0
    }

    public func setThreadKey(uid: UInt32, key: String) throws {
        guard messages[uid] != nil else { return }
        try journal(.threadKey(uid: uid, key: key))
        apply(.threadKey(uid: uid, key: key))
    }

    public func storeBody(uid: UInt32, raw: Data, snippet: String, hasAttachments: Bool) throws {
        try raw.write(to: bodyURL(uid), options: .atomic)
        guard messages[uid] != nil else { return }
        try journal(.body(uid: uid, snippet: snippet, hasAttachments: hasAttachments))
        apply(.body(uid: uid, snippet: snippet, hasAttachments: hasAttachments))
    }

    public func body(uid: UInt32) -> Data? {
        AtomicFile.read(bodyURL(uid))
    }

    public func hasBody(uid: UInt32) -> Bool {
        FileManager.default.fileExists(atPath: bodyURL(uid).path)
    }

    public func flush() throws {
        try compact()
    }

    private func bodyURL(_ uid: UInt32) -> URL { bodiesURL.appendingPathComponent("\(uid).eml") }

    private func apply(_ op: FolderJournalOp) {
        switch op {
        case .upsert(let m):
            if let old = messages[m.uid], !old.messageID.isEmpty { byMessageID[old.messageID] = nil }
            messages[m.uid] = m
            if !m.messageID.isEmpty { byMessageID[m.messageID] = m.uid }
        case .flags(let uid, let flags):
            messages[uid]?.apply(flags: flags)
        case .remove(let uids):
            for uid in uids {
                if let old = messages.removeValue(forKey: uid), !old.messageID.isEmpty { byMessageID[old.messageID] = nil }
            }
        case .body(let uid, let snippet, let hasAttachments):
            messages[uid]?.snippet = snippet
            messages[uid]?.hasAttachments = hasAttachments
            messages[uid]?.hasBody = true
        case .threadKey(let uid, let key):
            messages[uid]?.threadKey = key
        }
    }

    private func journal(_ op: FolderJournalOp) throws {
        if journalHandle == nil {
            if !FileManager.default.fileExists(atPath: journalURL.path) {
                FileManager.default.createFile(atPath: journalURL.path, contents: nil)
            }
            journalHandle = try FileHandle(forWritingTo: journalURL)
            _ = try journalHandle?.seekToEnd()
        }
        var line = try JSONEncoder().encode(op)
        line.append(0x0A)
        try journalHandle?.write(contentsOf: line)
        journalOps += 1
    }

    private func compactIfNeeded() throws {
        if journalOps >= compactThreshold { try compact() }
    }

    private func compact() throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(Array(messages.values))
        try AtomicFile.write(data, to: snapshotURL)
        journalHandle?.closeFile()
        journalHandle = nil
        try? FileManager.default.removeItem(at: journalURL)
        journalOps = 0
    }
}
