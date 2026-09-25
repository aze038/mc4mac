import Foundation
@testable import FalconCore

/// `MemoryGmailTransport` with the failures a plain double cannot make, for sending, drafts,
/// imports and the archive job: an upload Gmail took whose answer never came (a timeout after
/// acceptance), calls held at a gate until a test lets them go, and a Gmail that replaces a
/// sent message's Message-ID without keeping FalconMail's anywhere. Everything else is the
/// mailbox's own.
final class ScriptedGmailTransport: GmailTransport, @unchecked Sendable {
    let mailbox: MemoryGmailTransport
    private let lock = NSLock()
    private var afterAccepting: [GmailMethod: [GoogleAPIError]] = [:]
    private var gates: [GmailMethod: Gate] = [:]
    private var lateGates: [GmailMethod: Gate] = [:]
    private var refusals: [GmailMethod: GoogleAPIError] = [:]
    private var refusalsLater: [GmailMethod: (allowing: Int, error: GoogleAPIError)] = [:]
    private var passed: [GmailMethod: Int] = [:]
    private var _dropsOriginalMessageID = false
    private var _uploads: [GmailMethod: [Data]] = [:]

    init(_ mailbox: MemoryGmailTransport = MemoryGmailTransport()) {
        self.mailbox = mailbox
    }

    var accountID: UUID { mailbox.accountID }

    /// The next `times` calls to `method` are carried out, and then answered with `error`, as a
    /// timeout after Gmail accepted an upload would be.
    func failAfterAccepting(_ method: GmailMethod, with error: GoogleAPIError, times: Int = 1) {
        lock.withLock { afterAccepting[method, default: []] += Array(repeating: error, count: times) }
    }

    /// Holds every call to `method` until the gate opens.
    @discardableResult
    func hold(_ method: GmailMethod) -> Gate {
        let gate = Gate()
        lock.withLock { gates[method] = gate }
        return gate
    }

    /// Carries out every call to `method`, then holds its answer until the gate opens, as when
    /// Gmail took an upload and FalconMail stopped before the answer came.
    @discardableResult
    func holdAfterAccepting(_ method: GmailMethod) -> Gate {
        let gate = Gate()
        lock.withLock { lateGates[method] = gate }
        return gate
    }

    /// Every later call to `method` fails with `error` before reaching the mailbox; nil ends it.
    func refuse(_ method: GmailMethod, with error: GoogleAPIError?) {
        lock.withLock { refusals[method] = error }
    }

    /// Lets `count` more calls to `method` through, then fails every later one with `error`.
    func refuse(_ method: GmailMethod, with error: GoogleAPIError, afterAllowing count: Int) {
        lock.withLock {
            passed[method] = 0
            refusalsLater[method] = (count, error)
        }
    }

    func release(_ method: GmailMethod) {
        lock.withLock { gates.removeValue(forKey: method) }?.open()
    }

    /// A Gmail that gives a sent message a Message-ID of its own and keeps FalconMail's nowhere,
    /// not even in X-Google-Original-Message-ID.
    var dropsOriginalMessageID: Bool {
        get { lock.withLock { _dropsOriginalMessageID } }
        set {
            lock.withLock { _dropsOriginalMessageID = newValue }
            mailbox.replacesMessageIDOnSend = newValue || mailbox.replacesMessageIDOnSend
        }
    }

    /// The bytes of every upload, as Gmail received them.
    func uploads(_ method: GmailMethod) -> [Data] { lock.withLock { _uploads[method] ?? [] } }

    private func gate(_ method: GmailMethod) async throws {
        let gate = lock.withLock { gates[method] }
        await gate?.pass()
        let refusal: GoogleAPIError? = lock.withLock {
            if let standing = refusals[method] { return standing }
            guard let later = refusalsLater[method] else { return nil }
            passed[method, default: 0] += 1
            return passed[method, default: 0] > later.allowing ? later.error : nil
        }
        if let refusal { throw refusal }
    }

    private func accepted(_ method: GmailMethod) async throws {
        let late = lock.withLock { lateGates[method] }
        await late?.pass()
        let error: GoogleAPIError? = lock.withLock {
            guard var queue = afterAccepting[method], !queue.isEmpty else { return nil }
            let first = queue.removeFirst()
            afterAccepting[method] = queue
            return first
        }
        if let error { throw error }
    }

    private func record(_ method: GmailMethod, _ raw: Data) {
        lock.withLock { _uploads[method, default: []].append(raw) }
    }

    // MARK: - GmailTransport

    func profile(work: WorkClass) async throws -> GmailProfile { try await mailbox.profile(work: work) }
    func labels(work: WorkClass) async throws -> [GmailLabel] { try await mailbox.labels(work: work) }
    func label(_ id: GmailLabelID, work: WorkClass) async throws -> GmailLabel { try await mailbox.label(id, work: work) }
    func createLabel(named name: String, work: WorkClass) async throws -> GmailLabel { try await mailbox.createLabel(named: name, work: work) }
    func sendAs(work: WorkClass) async throws -> [GmailSendAs] { try await mailbox.sendAs(work: work) }

    func list(_ query: GmailListQuery, work: WorkClass) async throws -> GmailListPage {
        try await gate(.messagesList)
        return try await mailbox.list(query, work: work)
    }

    func history(since start: HistoryID, types: Set<GmailHistoryType>, label: GmailLabelID?, pageToken: String?,
                 work: WorkClass) async throws -> GmailHistoryPage {
        try await gate(.historyList)
        return try await mailbox.history(since: start, types: types, label: label, pageToken: pageToken, work: work)
    }

    func message(_ id: GmailMessageID, format: GmailFormat, work: WorkClass) async throws -> GmailMessage {
        try await gate(.messagesGet)
        return scrub(try await mailbox.message(id, format: format, work: work))
    }

    func thread(_ id: GmailThreadID, format: GmailFormat, work: WorkClass) async throws -> GmailThread {
        try await mailbox.thread(id, format: format, work: work)
    }

    func batch(_ parts: [GmailBatchPart], work: WorkClass) async throws -> [GmailBatchPart: Result<GmailBatchAnswer, GoogleAPIError>] {
        try await gate(.messagesGet)
        let answers = try await mailbox.batch(parts, work: work)
        return answers.mapValues { result in
            result.map { answer in
                if case .message(let m) = answer { return .message(scrub(m)) }
                return answer
            }
        }
    }

    func attachment(_ attachmentID: String, of message: GmailMessageID, work: WorkClass) async throws -> Data {
        try await mailbox.attachment(attachmentID, of: message, work: work)
    }

    func modify(_ id: GmailMessageID, adding: Set<GmailLabelID>, removing: Set<GmailLabelID>, work: WorkClass) async throws -> GmailMessage {
        try await mailbox.modify(id, adding: adding, removing: removing, work: work)
    }

    func batchModify(_ ids: [GmailMessageID], adding: Set<GmailLabelID>, removing: Set<GmailLabelID>, work: WorkClass) async throws {
        try await gate(.messagesBatchModify)
        try await mailbox.batchModify(ids, adding: adding, removing: removing, work: work)
    }

    func batchDelete(_ ids: [GmailMessageID], work: WorkClass) async throws { try await mailbox.batchDelete(ids, work: work) }
    func trash(_ id: GmailMessageID, work: WorkClass) async throws -> GmailMessage { try await mailbox.trash(id, work: work) }
    func untrash(_ id: GmailMessageID, work: WorkClass) async throws -> GmailMessage { try await mailbox.untrash(id, work: work) }

    func send(_ raw: Data, threadID: GmailThreadID?, work: WorkClass) async throws -> GmailMessage {
        try await gate(.messagesSend)
        record(.messagesSend, raw)
        let answer = try await mailbox.send(raw, threadID: threadID, work: work)
        try await accepted(.messagesSend)
        return answer
    }

    func importMessage(_ raw: Data, labels: Set<GmailLabelID>, options: GmailImportOptions, work: WorkClass) async throws -> GmailMessage {
        try await gate(.messagesImport)
        record(.messagesImport, raw)
        let answer = try await mailbox.importMessage(raw, labels: labels, options: options, work: work)
        try await accepted(.messagesImport)
        return answer
    }

    func createDraft(_ raw: Data, threadID: GmailThreadID?, work: WorkClass) async throws -> GmailDraft {
        try await gate(.draftsCreate)
        record(.draftsCreate, raw)
        let answer = try await mailbox.createDraft(raw, threadID: threadID, work: work)
        try await accepted(.draftsCreate)
        return answer
    }

    func updateDraft(_ draftID: String, raw: Data, threadID: GmailThreadID?, work: WorkClass) async throws -> GmailDraft {
        try await gate(.draftsUpdate)
        record(.draftsUpdate, raw)
        let answer = try await mailbox.updateDraft(draftID, raw: raw, threadID: threadID, work: work)
        try await accepted(.draftsUpdate)
        return answer
    }

    func deleteDraft(_ draftID: String, work: WorkClass) async throws {
        try await gate(.draftsDelete)
        try await mailbox.deleteDraft(draftID, work: work)
    }

    func drafts(pageToken: String?, work: WorkClass) async throws -> GmailDraftList { try await mailbox.drafts(pageToken: pageToken, work: work) }

    func setFloodMode(_ on: Bool) async { await mailbox.setFloodMode(on) }
    func noteOwnerActivity(at date: Date) async { await mailbox.noteOwnerActivity(at: date) }
    func pause() async -> GmailPause? { await mailbox.pause() }
    func usage() async -> GmailUsage { await mailbox.usage() }

    /// The answer as a Gmail that keeps nothing of FalconMail's Message-ID would give it.
    private func scrub(_ message: GmailMessage) -> GmailMessage {
        guard dropsOriginalMessageID, var payload = message.payload else { return message }
        payload.headers = payload.headers?.filter { $0.name.caseInsensitiveCompare("X-Google-Original-Message-ID") != .orderedSame }
        var out = message
        out.payload = payload
        return out
    }
}

/// Holds whoever passes it until it opens, counting them.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var _arrivals = 0

    var arrivals: Int { lock.withLock { _arrivals } }

    func pass() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let proceed: Bool = lock.withLock {
                _arrivals += 1
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if proceed { continuation.resume() }
        }
    }

    func open() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in waiting { waiter.resume() }
    }
}
