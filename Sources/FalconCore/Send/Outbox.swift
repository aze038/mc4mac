import Foundation

public struct OutboxItem: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable { case queued, sending, sent, failed, cancelled }

    public var id: UUID
    public var accountID: UUID
    public var subject: String
    public var recipients: [String]
    public var sender: String
    public var sendAt: Date
    public var createdAt: Date
    public var status: Status
    public var error: String?
    public var undoUntil: Date
    public var attempts: Int?

    public init(accountID: UUID, subject: String, recipients: [String], sender: String, sendAt: Date, undoWindow: TimeInterval) {
        self.id = UUID()
        self.accountID = accountID
        self.subject = subject
        self.recipients = recipients
        self.sender = sender
        self.sendAt = sendAt
        self.createdAt = Date()
        self.status = .queued
        self.error = nil
        self.undoUntil = max(sendAt, Date().addingTimeInterval(undoWindow))
    }

    public var canUndo: Bool { status == .queued && Date() < undoUntil }
}

public protocol MessageSender: Sendable {
    func send(accountID: UUID, from: String, recipients: [String], message: Data) async throws
}

public actor Outbox {
    private let directory: URL
    private var items: [UUID: OutboxItem] = [:]
    private var pump: Task<Void, Never>?
    private let sender: MessageSender
    public var undoWindow: TimeInterval
    private var listeners: [UUID: AsyncStream<[OutboxItem]>.Continuation] = [:]

    public init(layout: FileLayout, sender: MessageSender, undoWindow: TimeInterval = 10) {
        self.directory = layout.outboxDirectory
        self.sender = sender
        self.undoWindow = undoWindow
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "json" {
                if let item = AtomicFile.readJSON(OutboxItem.self, from: f) { items[item.id] = item }
            }
        }
    }

    public func updates() -> AsyncStream<[OutboxItem]> {
        let id = UUID()
        return AsyncStream { c in
            listeners[id] = c
            c.yield(snapshot())
            c.onTermination = { _ in Task { await self.removeListener(id) } }
        }
    }

    private func removeListener(_ id: UUID) { listeners[id] = nil }

    private func notify() {
        let s = snapshot()
        for l in listeners.values { l.yield(s) }
    }

    public func snapshot() -> [OutboxItem] {
        items.values.sorted { $0.createdAt > $1.createdAt }
    }

    public func enqueue(accountID: UUID, from: String, message: OutgoingMessage, sendAt: Date? = nil) throws -> OutboxItem {
        let raw = MIMEBuilder.build(message)
        let item = OutboxItem(accountID: accountID, subject: message.subject, recipients: message.allRecipients, sender: from,
                              sendAt: sendAt ?? Date().addingTimeInterval(undoWindow), undoWindow: undoWindow)
        try raw.write(to: directory.appendingPathComponent("\(item.id.uuidString).eml"), options: .atomic)
        try persist(item)
        items[item.id] = item
        notify()
        startPump()
        return item
    }

    public func rawMessage(for id: UUID) -> Data? {
        AtomicFile.read(directory.appendingPathComponent("\(id.uuidString).eml"))
    }

    public func cancel(_ id: UUID) throws {
        guard var item = items[id], item.status == .queued else { return }
        item.status = .cancelled
        try persist(item)
        items[id] = item
        notify()
    }

    public func remove(_ id: UUID) {
        items[id] = nil
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id.uuidString).json"))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id.uuidString).eml"))
        notify()
    }

    public func retry(_ id: UUID) throws {
        guard var item = items[id], item.status == .failed else { return }
        item.status = .queued
        item.error = nil
        item.sendAt = Date()
        try persist(item)
        items[id] = item
        notify()
        startPump()
    }

    public func startPump() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            while let self, !Task.isCancelled {
                let idle = await self.tick()
                if idle { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            await self?.pumpFinished()
        }
    }

    private func pumpFinished() { pump = nil }

    private func tick() async -> Bool {
        let due = items.values.filter { $0.status == .queued && $0.sendAt <= Date() }
        for var item in due {
            guard let raw = rawMessage(for: item.id) else { continue }
            item.status = .sending
            items[item.id] = item
            notify()
            do {
                try await sender.send(accountID: item.accountID, from: item.sender, recipients: item.recipients, message: raw)
                item.status = .sent
                item.error = nil
            } catch {
                let attempts = (item.attempts ?? 0) + 1
                item.attempts = attempts
                item.error = error.localizedDescription
                if Outbox.isTransient(error) && attempts < 30 {
                    item.status = .queued
                    item.sendAt = Date().addingTimeInterval(min(600, 15 * pow(2, Double(min(attempts, 6)))))
                    item.undoUntil = Date()
                } else {
                    item.status = .failed
                }
            }
            try? persist(item)
            items[item.id] = item
            notify()
        }
        return !items.values.contains { $0.status == .queued }
    }

    static func isTransient(_ error: Error) -> Bool {
        if let f = error as? FalconError {
            switch f {
            case .network: return true
            case .http(let code, _): return code >= 500 || code == 429
            default: return false
            }
        }
        return (error as? URLError) != nil
    }

    private func persist(_ item: OutboxItem) throws {
        try AtomicFile.writeJSON(item, to: directory.appendingPathComponent("\(item.id.uuidString).json"))
    }
}
