import Foundation

/// Events waiting to be sent, one JSON record per line in `queue.jsonl`. A new event is
/// appended as a line of its own, so what was queued before a crash is on disk when the app
/// next starts. A repeat of a recent event only raises its count. The file never grows past
/// `maxBytes`: the oldest events go first, crashes last.
///
/// Not thread-safe; the diagnostics centre uses it from its own queue only.
public final class DiagnosticsQueue {
    public static let maxBytes = 1_000_000
    public static let foldWindow: TimeInterval = 60 * 60
    /// A file this large was not written by the queue, which never lets it pass `maxBytes`.
    static let unreadableSize = 8_000_000

    public let url: URL
    public private(set) var records: [DiagnosticsRecord] = []
    private var lines: [Data] = []
    /// A fold changed a record already on disk; `flush()` rewrites the file.
    public private(set) var needsFlush = false
    /// Where a damaged file was moved, when one was found on opening.
    public private(set) var setAside: URL?

    public init(url: URL) {
        self.url = url
        load()
    }

    public var totalBytes: Int { lines.reduce(0) { $0 + $1.count + 1 } }
    public var isEmpty: Bool { records.isEmpty }

    // MARK: Changes

    public enum Outcome: Equatable { case added, folded }

    /// Folds into a record of the same signature, kind, account and build that began less than
    /// an hour before, has not been sent and has room in its count, or adds a new one.
    @discardableResult
    public func add(_ record: DiagnosticsRecord) -> Outcome {
        if record.event.kind.folds, let i = foldTarget(for: record) {
            var existing = records[i]
            existing.event.count += record.event.count
            existing.event.firstAt = min(existing.event.firstAt, record.event.firstAt)
            existing.event.lastAt = max(existing.event.lastAt, record.event.lastAt)
            records[i] = existing
            lines[i] = encode(existing)
            needsFlush = true
            return .folded
        }
        let line = encode(record)
        records.append(record)
        lines.append(line)
        if dropOverflow() {
            rewrite()
        } else {
            appendLine(line)
        }
        return .added
    }

    public func contains(id: String) -> Bool {
        records.contains { $0.event.id == id }
    }

    /// Marks records as part of an upload attempt, before it is made.
    public func seal(_ ids: Set<String>) {
        var changed = false
        for i in records.indices where ids.contains(records[i].event.id) && !records[i].sealed {
            records[i].sealed = true
            lines[i] = encode(records[i])
            changed = true
        }
        if changed { rewrite() }
    }

    /// Takes out what the server has confirmed.
    public func remove(_ ids: Set<String>) {
        let before = records.count
        let kept = zip(records, lines).filter { !ids.contains($0.0.event.id) }
        records = kept.map(\.0)
        lines = kept.map(\.1)
        if records.count != before { rewrite() }
    }

    /// Deletes the queue and any damaged file set aside from it.
    public func clear() {
        records = []
        lines = []
        needsFlush = false
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        for aside in setAsideFiles() { try? fm.removeItem(at: aside) }
        setAside = nil
    }

    public func flush() {
        guard needsFlush else { return }
        rewrite()
    }

    // MARK: Folding and the size cap

    private func foldTarget(for record: DiagnosticsRecord) -> Int? {
        records.lastIndex { existing in
            !existing.sealed
                && existing.event.count + record.event.count <= DiagnosticsEvent.maxCount
                && existing.event.signature == record.event.signature
                && existing.event.kind == record.event.kind
                && existing.event.account?.ref == record.event.account?.ref
                && existing.app == record.app
                && record.event.lastAt.timeIntervalSince(existing.event.firstAt) < DiagnosticsQueue.foldWindow
                && record.event.firstAt >= existing.event.firstAt.addingTimeInterval(-DiagnosticsQueue.foldWindow)
        }
    }

    /// True when records had to go to bring the file back under the cap.
    private func dropOverflow() -> Bool {
        var total = totalBytes
        var dropped = false
        while total > DiagnosticsQueue.maxBytes, records.count > 1 {
            let victim = records.firstIndex { $0.event.kind != .crash } ?? 0
            total -= lines[victim].count + 1
            records.remove(at: victim)
            lines.remove(at: victim)
            dropped = true
        }
        return dropped
    }

    // MARK: Disk

    private func encode(_ record: DiagnosticsRecord) -> Data {
        (try? DiagnosticsJSON.encoder.encode(record)) ?? Data()
    }

    private func appendLine(_ line: Data) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) else {
            rewrite()
            return
        }
        defer { try? handle.close() }
        do {
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: line + Data([0x0A]))
        } catch {
            rewrite()
        }
    }

    private func rewrite() {
        needsFlush = false
        guard !lines.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        var data = Data(capacity: totalBytes)
        for line in lines {
            data.append(line)
            data.append(0x0A)
        }
        try? AtomicFile.write(data, to: url)
    }

    /// Reads what is there. The last line may be cut short by a crash in mid-write and is then
    /// dropped quietly; anything else that does not decode means the file was damaged, so it
    /// is moved aside for inspection and the records that did decode are kept.
    private func load() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return }
        let size = (attributes[.size] as? Int) ?? 0
        guard size <= DiagnosticsQueue.unreadableSize, let data = try? Data(contentsOf: url) else {
            moveAside()
            return
        }
        var damaged = false
        let chunks = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        for (index, chunk) in chunks.enumerated() where !chunk.isEmpty {
            if let record = try? DiagnosticsJSON.decoder.decode(DiagnosticsRecord.self, from: Data(chunk)) {
                records.append(record)
                lines.append(Data(chunk))
            } else if index != chunks.count - 1 {
                damaged = true
            }
        }
        if damaged { moveAside() }
        let trimmed = dropOverflow()
        if damaged || trimmed || data.last != 0x0A || lines.count != chunks.filter({ !$0.isEmpty }).count {
            rewrite()
        }
    }

    private func moveAside() {
        for old in setAsideFiles() { try? FileManager.default.removeItem(at: old) }
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = url.deletingLastPathComponent().appendingPathComponent("queue-damaged-\(stamp).jsonl")
        if (try? FileManager.default.moveItem(at: url, to: aside)) != nil {
            setAside = aside
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func setAsideFiles() -> [URL] {
        let dir = url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix("queue-damaged-") }.map { dir.appendingPathComponent($0) }
    }
}
