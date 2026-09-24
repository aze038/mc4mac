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
    /// Kept back rather than failed: sending began and whether it finished is not known, or the
    /// daily sending limit was reached. Stored under the status `failed`, which the previous
    /// release reads and, like this one, never sends by itself.
    public var heldBack: Bool?
    /// Set only on disk, while the message is going out. The file then already says what it
    /// must say if FalconMail stops before the send ends: held, and under the status `failed`,
    /// since the previous release has no way out of "Sending…" for one it finds after a crash.
    public var sendBegan: Bool?

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

    /// Held, as one whose send may or may not have finished.
    var interrupted: OutboxItem {
        var held = self
        held.status = .failed
        held.heldBack = true
        held.error = Outbox.interruptedText
        return held
    }

    /// Waiting for the owner to decide, and never sent again by itself.
    public var isHeld: Bool { status == .failed && heldBack == true }

    public func isSendingSoon(within window: TimeInterval) -> Bool {
        canUndo && sendAt <= Date().addingTimeInterval(max(0, window))
    }
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

    public static func draftSidecarURL(directory: URL, id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).draft.json")
    }

    public init(layout: FileLayout, sender: MessageSender, undoWindow: TimeInterval = 10) {
        self.directory = layout.outboxDirectory
        self.sender = sender
        self.undoWindow = undoWindow
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var loaded: [UUID: OutboxItem] = [:]
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "json" && !f.lastPathComponent.hasSuffix(".draft.json") {
                guard var item = AtomicFile.loadJSON(OutboxItem.self, from: f, what: "a message in the Outbox").value else { continue }
                if item.sendBegan == true || item.status == .sending {
                    // FalconMail stopped while this was going out, so it may already have been
                    // delivered. Sending it again by itself could send it twice.
                    item = item.interrupted
                    item.sendBegan = nil
                    Log.info("send", "\(item.sender): Outbox item \(item.id) was being sent when FalconMail stopped; held")
                    try? Outbox.write(item, in: directory)
                }
                loaded[item.id] = item
            }
        }
        items = loaded
    }

    static let interruptedText = "FalconMail stopped while this was being sent, so it may already have gone. Check Sent, then send it again or remove it."

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

    @discardableResult
    public func cancel(_ id: UUID) throws -> Bool {
        guard var item = items[id], item.status == .queued else { return false }
        item.status = .cancelled
        try persist(item)
        items[id] = item
        notify()
        return true
    }

    public func remove(_ id: UUID) {
        items[id] = nil
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id.uuidString).json"))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id.uuidString).eml"))
        try? FileManager.default.removeItem(at: Outbox.draftSidecarURL(directory: directory, id: id))
        notify()
    }

    public func retry(_ id: UUID) throws {
        guard var item = items[id], item.status == .failed else { return }
        item.status = .queued
        item.heldBack = nil
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
        let due = items.values.filter { $0.status == .queued && $0.sendAt <= Date() }.map { $0.id }
        for id in due {
            guard var item = items[id], item.status == .queued, item.sendAt <= Date() else { continue }
            guard let raw = rawMessage(for: id) else { continue }
            item.status = .sending
            do {
                // On disk before the first byte goes out: after a crash the item must be found
                // held, never "queued", or it would go out a second time.
                try persist(item)
            } catch {
                Log.info("send", "\(item.sender): not sending Outbox item \(item.id), its state could not be saved: \(error.localizedDescription)")
                item.status = .failed
                item.error = "FalconMail could not save the Outbox, so it did not send this."
                items[item.id] = item
                notify()
                continue
            }
            items[item.id] = item
            notify()
            do {
                try await sender.send(accountID: item.accountID, from: item.sender, recipients: item.recipients, message: raw)
                item.status = .sent
                item.error = nil
            } catch {
                let attempts = (item.attempts ?? 0) + 1
                let failure = MailServiceError.classify(error, email: item.sender, isGoogle: false)
                Log.info("send", "\(item.sender): attempt \(attempts) of Outbox item \(item.id) failed: \(failure.kind.rawValue): "
                         + Log.redacted(failure.detail, keeping: item.sender))
                item.attempts = attempts
                item.error = failure.sentence
                if failure.kind == .sendingLimit {
                    item.status = .failed
                    item.heldBack = true
                } else if failure.isTransient && attempts < 30 {
                    item.status = .queued
                    item.sendAt = Date().addingTimeInterval(min(600, 15 * pow(2, Double(min(attempts, 6)))))
                    item.undoUntil = Date()
                } else {
                    item.status = .failed
                }
            }
            do {
                try persist(item)
            } catch {
                Log.info("send", "\(item.sender): could not save Outbox item \(item.id) after sending: \(error.localizedDescription)")
            }
            items[item.id] = item
            notify()
        }
        return !items.values.contains { $0.status == .queued }
    }

    static func isTransient(_ error: Error) -> Bool {
        MailServiceError.classify(error, email: "", isGoogle: false).isTransient
    }

    private func persist(_ item: OutboxItem) throws {
        guard item.status == .sending else { return try Outbox.write(item, in: directory) }
        var stored = item.interrupted
        stored.sendBegan = true
        try Outbox.write(stored, in: directory)
    }

    private static func write(_ item: OutboxItem, in directory: URL) throws {
        try AtomicFile.writeJSON(item, to: directory.appendingPathComponent("\(item.id.uuidString).json"))
    }
}
