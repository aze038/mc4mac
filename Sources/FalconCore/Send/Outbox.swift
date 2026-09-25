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
    /// Who it goes to, box by box, for the Outbox to show and a message called back to open
    /// with, Bcc included, should its draft beside it be missing. `recipients` stays what it
    /// goes to, all of them, as the previous release reads it; these it ignores, and items it
    /// queued have none.
    public var to: [EmailAddress]?
    public var cc: [EmailAddress]?
    public var bcc: [EmailAddress]?
    /// The Message-ID it goes out with, as the .eml has it. Absent from items an earlier build
    /// queued.
    public var messageID: String?

    // The Gmail engine's fields. An account on SMTP leaves them empty, and the previous release
    // ignores them.

    /// Names one attempt at sending, in the `X-FalconMail-Attempt` header of Gmail's upload, so
    /// the attempt can be recognised in Gmail's records even if Gmail gives the message a
    /// Message-ID of its own. Every attempt has a new one.
    public var attemptID: UUID?
    /// Where the account's history stood when the attempt began, never later than Gmail's own
    /// position: a send whose outcome is unclear is looked for in the history after it.
    public var preSendHistoryID: HistoryID?
    /// Gmail's id for the message once Gmail has it, from its answer or from its records. Only
    /// a sent item with one is ever cleared out by itself.
    public var gmailSentID: GmailMessageID?
    /// The Gmail draft the message was written in, deleted once the send is confirmed. It stays
    /// here until Gmail has deleted it, so a relaunch finishes the delete.
    public var gmailDraftID: String?
    /// The conversation a reply or forward goes into.
    public var gmailThreadID: GmailThreadID?

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

    /// Readies one attempt before its start is written to disk, so that everything needed to
    /// look for it later is saved first. Gmail's sender names the attempt and notes where the
    /// history stands; SMTP has nothing to note.
    func prepare(_ item: OutboxItem, message: Data) async -> OutboxItem
    /// Sends one attempt, and returns the item with what the server said about it. A failure
    /// that must be told apart from "try again", such as an answer that leaves it unclear
    /// whether the message went, is thrown as a `SendFailure`.
    func send(_ item: OutboxItem, message: Data) async throws -> OutboxItem
    /// Looks in the server's own records for an attempt whose outcome is unclear. Only ever used
    /// to confirm that a message went, never to allow sending it again.
    func confirm(_ item: OutboxItem) async -> SendConfirmation
    /// Tidies up after a confirmed send, such as deleting the Gmail draft the message was
    /// written in, and returns the item as it then stands. Whatever it could not do yet stays in
    /// the item, and a relaunch tries it again.
    func finish(_ item: OutboxItem) async -> OutboxItem
}

extension MessageSender {
    public func prepare(_ item: OutboxItem, message: Data) async -> OutboxItem { item }

    public func send(_ item: OutboxItem, message: Data) async throws -> OutboxItem {
        try await send(accountID: item.accountID, from: item.sender, recipients: item.recipients, message: message)
        return item
    }

    /// An SMTP server keeps no record a client can read, so there is nothing to look in.
    public func confirm(_ item: OutboxItem) async -> SendConfirmation { .noRecords }

    public func finish(_ item: OutboxItem) async -> OutboxItem { item }
}

/// What the server's records say about a send whose outcome was unclear.
public enum SendConfirmation: Sendable, Equatable {
    /// Found: it went, with the server's id for it where it has one.
    case sent(GmailMessageID?)
    /// Not found. That never proves it did not go: Gmail may still be taking it in.
    case notFound
    /// The records could not be read this time, as when offline; a later look may manage.
    case lookFailed
    /// There are no records to look in, as for SMTP: the send is held for the owner at once.
    case noRecords
}

/// A failed send, with what the Outbox must do next so that a message is never sent twice.
public struct SendFailure: Error, LocalizedError, Sendable {
    public enum Next: Sendable, Equatable {
        /// It provably never reached the server, so it is tried again by itself, with backoff.
        case retry
        /// The server refused it for now and said until when; it goes again then.
        case wait(until: Date)
        /// It may have gone. It is looked for in the server's records and marked sent if found,
        /// and otherwise held for the owner. It is never sent again by itself.
        case confirm
        /// Held for the owner, who decides whether to send it again.
        case hold
        /// Refused for good, such as an address the server will not take.
        case fail
    }

    public var next: Next
    /// What the Outbox shows.
    public var sentence: String
    /// The server's refusal, for the log, whose kind gives the diagnostics code. Nil for a
    /// failure found on this Mac, which `code` names instead.
    public var cause: GoogleAPIError?
    public var code: String?

    public init(next: Next, sentence: String, cause: GoogleAPIError? = nil, code: String? = nil) {
        self.next = next
        self.sentence = sentence
        self.cause = cause
        self.code = code
    }

    public var errorDescription: String? { sentence }
}

public actor Outbox {
    private let directory: URL
    private var items: [UUID: OutboxItem] = [:]
    private var pump: Task<Void, Never>?
    private let sender: MessageSender
    public var undoWindow: TimeInterval
    private var listeners: [UUID: AsyncStream<[OutboxItem]>.Continuation] = [:]
    /// When an unclear send is looked for in the server's records, counted from the moment it
    /// became unclear: Gmail can take a send in and still be processing it minutes later.
    private let confirmAfter: [TimeInterval]
    /// The wait before trying again a send that provably never reached the server.
    private let retryDelay: @Sendable (_ attempts: Int) -> TimeInterval
    private var confirming: [UUID: Task<Void, Never>] = [:]

    /// A sent item is cleared out this long after it went, once Gmail's id for it is known.
    static let sentItemsKept: TimeInterval = 7 * 24 * 3600
    /// The Bcc recipients of what is sent, written down as each message is queued.
    public nonisolated let sentBcc: SentBccStore

    public static func draftSidecarURL(directory: URL, id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).draft.json")
    }

    public init(layout: FileLayout, sender: MessageSender, undoWindow: TimeInterval = 10,
                confirmAfter: [TimeInterval] = [30, 120],
                retryDelay: @escaping @Sendable (_ attempts: Int) -> TimeInterval = { min(600, 15 * pow(2, Double(min($0, 6)))) }) {
        self.directory = layout.outboxDirectory
        self.sender = sender
        self.undoWindow = undoWindow
        self.confirmAfter = confirmAfter.isEmpty ? [0] : confirmAfter
        self.retryDelay = retryDelay
        self.sentBcc = SentBccStore.shared(file: layout.sentBccFile)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var loaded: [UUID: OutboxItem] = [:]
        var unclear: [UUID] = []
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "json" && !f.lastPathComponent.hasSuffix(".draft.json") {
                guard var item = AtomicFile.loadJSON(OutboxItem.self, from: f, what: "a message in the Outbox").value else { continue }
                if item.sendBegan == true || item.status == .sending {
                    // FalconMail stopped while this was going out, so it may already have been
                    // delivered. Sending it again by itself could send it twice.
                    if item.attemptID != nil {
                        // An attempt Gmail's records can confirm. The file already says held,
                        // and stays so until a look finds the message; nothing sends it again.
                        item.status = .sending
                        item.sendBegan = nil
                        item.heldBack = nil
                        item.error = nil
                        unclear.append(item.id)
                        // Only a look that finds nothing makes this a held message worth reporting.
                        Log.info("send", "\(item.sender): Outbox item \(item.id) was being sent when FalconMail stopped; looking for it in Gmail's records")
                    } else {
                        item = item.interrupted
                        item.sendBegan = nil
                        Log.warning("Outbox", "\(item.sender): Outbox item \(item.id) was being sent when FalconMail stopped; held",
                                    code: "interrupted", logAs: "send")
                        try? Outbox.write(item, in: directory)
                    }
                }
                loaded[item.id] = item
            }
        }
        items = loaded
        let unfinished = loaded.values.filter { $0.status == .sent && $0.gmailDraftID != nil }.map(\.id)
        if !unclear.isEmpty || !unfinished.isEmpty {
            Task { await self.resumeAfterLaunch(unclear: unclear, unfinished: unfinished) }
        }
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

    /// `gmailThreadID` and `gmailDraftID` are a Google account's: the conversation a reply goes
    /// into, and the Gmail draft to delete once the message has gone.
    public func enqueue(accountID: UUID, from: String, message: OutgoingMessage, sendAt: Date? = nil,
                        gmailThreadID: GmailThreadID? = nil, gmailDraftID: String? = nil) throws -> OutboxItem {
        // No Bcc header: the Bcc recipients are in `recipients`, the envelope, and nowhere else.
        let raw = MIMEBuilder.build(message)
        var item = OutboxItem(accountID: accountID, subject: message.subject, recipients: message.allRecipients, sender: from,
                              sendAt: sendAt ?? Date().addingTimeInterval(undoWindow), undoWindow: undoWindow)
        item.to = message.to
        item.cc = message.cc
        item.bcc = message.bcc
        item.messageID = message.messageID
        item.gmailThreadID = gmailThreadID
        item.gmailDraftID = gmailDraftID
        try raw.write(to: directory.appendingPathComponent("\(item.id.uuidString).eml"), options: .atomic)
        try persist(item)
        sentBcc.record(messageID: message.messageID, bcc: message.bcc)
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
        // One cancelled never went, and one called back goes again under a new Message-ID.
        if let item = items[id], item.status == .cancelled, let messageID = item.messageID {
            sentBcc.forget(messageID: messageID)
        }
        items[id] = nil
        confirming.removeValue(forKey: id)?.cancel()
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
        clearOutSentItems()
        let due = items.values.filter { $0.status == .queued && $0.sendAt <= Date() }.map { $0.id }
        for id in due {
            guard var item = items[id], item.status == .queued, item.sendAt <= Date() else { continue }
            guard let raw = rawMessage(for: id) else { continue }
            item = await sender.prepare(item, message: raw)
            // The owner may have taken it back while the attempt was being readied.
            guard items[id]?.status == .queued else { continue }
            item.status = .sending
            do {
                // On disk before the first byte goes out: after a crash the item must be found
                // held, never "queued", or it would go out a second time.
                try persist(item)
            } catch {
                Log.error("Outbox", "\(item.sender): not sending Outbox item \(item.id), its state could not be saved: \(error.localizedDescription)",
                          error: error, logAs: "send")
                item.status = .failed
                item.error = "FalconMail could not save the Outbox, so it did not send this."
                items[item.id] = item
                notify()
                continue
            }
            items[item.id] = item
            notify()
            do {
                item = try await sender.send(item, message: raw)
                item.status = .sent
                item.error = nil
            } catch let failure as SendFailure {
                if failure.next == .confirm {
                    // Still "sending" here, and held on disk, until Gmail's records say it went.
                    Log.warning("Send", "\(item.sender): the outcome of sending Outbox item \(item.id) is unclear; looking for it in Gmail's records",
                                error: failure.cause, code: failure.cause == nil ? failure.code : nil,
                                details: ["outcome": "confirming"], logAs: "send", keeping: item.sender)
                    items[item.id] = item
                    notify()
                    startConfirming(item.id)
                    continue
                }
                apply(failure, to: &item)
            } catch {
                let attempts = (item.attempts ?? 0) + 1
                let failure = MailServiceError.classify(error, email: item.sender, isGoogle: false)
                let heldBack = failure.kind == .sendingLimit
                let retrying = !heldBack && failure.isTransient && attempts < 30
                // Tried again by itself, a warning; held or given up on, an error the owner sees.
                Log.failure("SMTP", failure, "\(item.sender): attempt \(attempts) of Outbox item \(item.id) failed: \(failure.kind.rawValue): "
                            + failure.detail, level: retrying ? .warning : .error,
                            details: ["attempt": "\(attempts)", "outcome": heldBack ? "held" : retrying ? "retrying" : "failed"],
                            logAs: "send", keeping: item.sender)
                item.attempts = attempts
                item.error = failure.sentence
                if heldBack {
                    item.status = .failed
                    item.heldBack = true
                } else if retrying {
                    item.status = .queued
                    item.sendAt = Date().addingTimeInterval(retryDelay(attempts))
                    item.undoUntil = Date()
                } else {
                    item.status = .failed
                }
            }
            save(item, what: "after sending")
            if item.status == .sent { await finishSent(item.id) }
        }
        return !items.values.contains { $0.status == .queued }
    }

    /// What a failed attempt leaves the item as, by what the sender said of it.
    private func apply(_ failure: SendFailure, to item: inout OutboxItem) {
        let attempts = (item.attempts ?? 0) + 1
        item.attempts = attempts
        item.error = failure.sentence
        let outcome: String
        switch failure.next {
        case .retry where attempts < 30:
            item.status = .queued
            item.sendAt = Date().addingTimeInterval(retryDelay(attempts))
            item.undoUntil = Date()
            outcome = "retrying"
        case .wait(let until):
            item.status = .queued
            item.sendAt = max(until, Date())
            item.undoUntil = Date()
            outcome = "waiting"
        case .hold:
            item.status = .failed
            item.heldBack = true
            outcome = "held"
        case .retry, .fail, .confirm:
            item.status = .failed
            outcome = "failed"
        }
        let level: LogLevel = item.status == .queued ? .warning : .error
        let line = "\(item.sender): attempt \(attempts) of Outbox item \(item.id) failed: \(failure.cause?.kind.rawValue ?? failure.code ?? "local")"
        let details = ["attempt": "\(attempts)", "outcome": outcome]
        let code = failure.cause == nil ? failure.code : nil
        if level == .warning {
            Log.warning("Send", line, error: failure.cause, code: code, details: details, logAs: "send", keeping: item.sender)
        } else {
            Log.error("Send", line, error: failure.cause, code: code, details: details, logAs: "send", keeping: item.sender)
        }
    }

    // MARK: - Confirming a send whose outcome is unclear

    private func resumeAfterLaunch(unclear: [UUID], unfinished: [UUID]) async {
        for id in unclear { startConfirming(id) }
        for id in unfinished { await finishSent(id) }
    }

    private func startConfirming(_ id: UUID) {
        guard confirming[id] == nil else { return }
        confirming[id] = Task { [weak self] in await self?.confirm(id) }
    }

    /// Looks for the message in the server's records at each of `confirmAfter`. Found, it is
    /// sent; not found by the last look, it is held for the owner with the words v1.10.0 uses
    /// for an interrupted send. Nothing here ever sends it again.
    private func confirm(_ id: UUID) async {
        let began = Date()
        defer { confirming[id] = nil }
        looking: for delay in confirmAfter {
            let wait = delay - Date().timeIntervalSince(began)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard !Task.isCancelled, let item = items[id], item.status == .sending else { return }
            let answer = await sender.confirm(item)
            guard !Task.isCancelled, var current = items[id], current.status == .sending else { return }
            switch answer {
            case .sent(let gmailID):
                current.status = .sent
                current.error = nil
                current.gmailSentID = gmailID ?? current.gmailSentID
                Log.info("send", "\(current.sender): Outbox item \(current.id) was found in Gmail's records; marked sent")
                save(current, what: "after confirming it")
                await finishSent(id)
                return
            case .notFound, .lookFailed:
                continue looking
            case .noRecords:
                break looking
            }
        }
        guard var current = items[id], current.status == .sending else { return }
        current = current.interrupted
        Log.warning("Outbox", "\(current.sender): Outbox item \(current.id) was not found in Gmail's records; held",
                    code: "interrupted", logAs: "send")
        save(current, what: "after looking for it")
    }

    /// What is left after a confirmed send, such as deleting the draft it was written in.
    private func finishSent(_ id: UUID) async {
        guard let item = items[id], item.status == .sent else { return }
        let finished = await sender.finish(item)
        guard var current = items[id], current.status == .sent else { return }
        guard finished.gmailDraftID != current.gmailDraftID || finished.gmailSentID != current.gmailSentID else { return }
        current.gmailDraftID = finished.gmailDraftID
        current.gmailSentID = finished.gmailSentID ?? current.gmailSentID
        save(current, what: "after tidying up")
    }

    /// Sent items go a week after sending, but only once Gmail's id for them is known and
    /// nothing is left to tidy up: one sent by SMTP stays until the owner removes it, as before.
    private func clearOutSentItems() {
        let cutoff = Date().addingTimeInterval(-Outbox.sentItemsKept)
        let old = items.values.filter { $0.status == .sent && $0.gmailSentID != nil && $0.gmailDraftID == nil && $0.sendAt < cutoff }
        for item in old { remove(item.id) }
    }

    private func save(_ item: OutboxItem, what: String) {
        do {
            try persist(item)
        } catch {
            Log.error("Outbox", "\(item.sender): could not save Outbox item \(item.id) \(what): \(error.localizedDescription)",
                      error: error, logAs: "send")
        }
        items[item.id] = item
        notify()
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
