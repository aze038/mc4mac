import Foundation
import XCTest
@testable import FalconCore

/// A clock the test moves by hand. Sleepers wake when it passes their time, or when their task is
/// cancelled, as the engine's loop expects of any clock.
final class ManualGmailClock: GmailEngineClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var sleepers: [UUID: (until: Date, continuation: CheckedContinuation<Void, Never>)] = [:]

    init(_ start: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
        current = start
    }

    func now() -> Date { lock.withLock { current } }

    func sleep(until date: Date) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    if date <= current || Task.isCancelled { return true }
                    sleepers[id] = (date, continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let sleeper = lock.withLock { sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume()
        }
    }

    func advance(by seconds: TimeInterval) {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            current = current.addingTimeInterval(seconds)
            let ready = sleepers.filter { $0.value.until <= current }
            for key in ready.keys { sleepers[key] = nil }
            return ready.values.map(\.continuation)
        }
        for continuation in due { continuation.resume() }
    }

    var sleeping: Int { lock.withLock { sleepers.count } }
}

/// Every event the engine sends, in order, as the app would hear them.
final class GmailEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SyncEvent] = []

    var events: [SyncEvent] { lock.withLock { stored } }

    func record(_ event: SyncEvent) { lock.withLock { stored.append(event) } }
    func clear() { lock.withLock { stored.removeAll() } }

    var healths: [AccountHealth] {
        events.compactMap { if case .health(_, let h) = $0 { return h } else { return nil } }
    }

    var errors: [String] {
        events.compactMap { if case .error(_, let m) = $0 { return m } else { return nil } }
    }

    var announced: [[MessageSummary]] {
        events.compactMap { if case .newMessages(_, _, let m) = $0 { return m } else { return nil } }
    }

    var announcedSubjects: [String] { announced.flatMap { $0.map(\.subject) } }

    /// A short name for each event, for comparing sequences.
    var names: [String] {
        events.compactMap { event in
            switch event {
            case .started: return "started"
            case .finished: return "finished"
            case .checked(_, let found): return "checked(\(found))"
            case .newMessages(_, _, let m): return "newMessages(\(m.count))"
            case .health(_, let h): return "health(\(h.diagnosticsName))"
            case .error: return "error"
            case .progress: return nil
            default: return "other"
            }
        }
    }
}

/// Wraps any transport to run test code just before a call reaches it, to fail a call, or to say
/// what Gmail's clock is: a message deleted between a check's history and its fetch, a pause, a
/// Mac whose clock is wrong.
final class HookedGmailTransport: GmailTransport, GmailServerClock, @unchecked Sendable {
    let inner: any GmailTransport
    private let lock = NSLock()
    private var hooks: [GmailMethod: [() -> Void]] = [:]
    private var listHook: ((GmailListQuery) -> Void)?
    private var failures: [(method: GmailMethod, error: GoogleAPIError)] = []
    private var _pause: GmailPause?
    private var _offset: TimeInterval?
    private var _listCalls: [GmailListQuery] = []
    private var _log: [GmailMethod] = []

    init(_ inner: any GmailTransport) { self.inner = inner }

    var accountID: UUID { inner.accountID }

    /// Runs `hook` once, just before the next call to `method`.
    func before(_ method: GmailMethod, _ hook: @escaping () -> Void) {
        lock.withLock { hooks[method, default: []].append(hook) }
    }

    /// Runs `hook` before every list call, with its query.
    func onList(_ hook: ((GmailListQuery) -> Void)?) { lock.withLock { listHook = hook } }

    func fail(_ method: GmailMethod, with error: GoogleAPIError, times: Int = 1) {
        lock.withLock { for _ in 0..<times { failures.append((method, error)) } }
    }

    func setPause(_ pause: GmailPause?) { lock.withLock { _pause = pause } }
    func setClockOffset(_ offset: TimeInterval?) { lock.withLock { _offset = offset } }
    var listCalls: [GmailListQuery] { lock.withLock { _listCalls } }
    /// Every call in the order it came, a batch as the methods of its parts.
    var log: [GmailMethod] { lock.withLock { _log } }
    func clearLog() { lock.withLock { _log.removeAll(); _listCalls.removeAll() } }

    func gmailClockOffset() async -> TimeInterval? { lock.withLock { _offset } }

    private func enter(_ method: GmailMethod) throws {
        let (hook, failure) = lock.withLock { () -> ((() -> Void)?, GoogleAPIError?) in
            _log.append(method)
            let hook = hooks[method]?.isEmpty == false ? hooks[method]!.removeFirst() : nil
            var failure: GoogleAPIError?
            if let i = failures.firstIndex(where: { $0.method == method }) { failure = failures.remove(at: i).error }
            return (hook, failure)
        }
        hook?()
        if let failure { throw failure }
    }

    func profile(work: WorkClass) async throws -> GmailProfile { try enter(.profile); return try await inner.profile(work: work) }
    func labels(work: WorkClass) async throws -> [GmailLabel] { try enter(.labelsList); return try await inner.labels(work: work) }
    func label(_ id: GmailLabelID, work: WorkClass) async throws -> GmailLabel { try enter(.labelsGet); return try await inner.label(id, work: work) }
    func createLabel(named name: String, work: WorkClass) async throws -> GmailLabel {
        try enter(.labelsCreate); return try await inner.createLabel(named: name, work: work)
    }
    func sendAs(work: WorkClass) async throws -> [GmailSendAs] { try enter(.sendAsList); return try await inner.sendAs(work: work) }
    func list(_ query: GmailListQuery, work: WorkClass) async throws -> GmailListPage {
        let hook = lock.withLock { () -> ((GmailListQuery) -> Void)? in
            _listCalls.append(query)
            return listHook
        }
        hook?(query)
        try enter(.messagesList)
        return try await inner.list(query, work: work)
    }
    func history(since start: HistoryID, types: Set<GmailHistoryType>, label: GmailLabelID?, pageToken: String?,
                 work: WorkClass) async throws -> GmailHistoryPage {
        try enter(.historyList)
        return try await inner.history(since: start, types: types, label: label, pageToken: pageToken, work: work)
    }
    func message(_ id: GmailMessageID, format: GmailFormat, work: WorkClass) async throws -> GmailMessage {
        try enter(.messagesGet); return try await inner.message(id, format: format, work: work)
    }
    func thread(_ id: GmailThreadID, format: GmailFormat, work: WorkClass) async throws -> GmailThread {
        try enter(.threadsGet); return try await inner.thread(id, format: format, work: work)
    }
    func batch(_ parts: [GmailBatchPart], work: WorkClass) async throws -> [GmailBatchPart: Result<GmailBatchAnswer, GoogleAPIError>] {
        for method in Set(parts.map(\.method)) { try enter(method) }
        return try await inner.batch(parts, work: work)
    }
    func attachment(_ attachmentID: String, of message: GmailMessageID, work: WorkClass) async throws -> Data {
        try enter(.attachmentsGet); return try await inner.attachment(attachmentID, of: message, work: work)
    }
    func modify(_ id: GmailMessageID, adding: Set<GmailLabelID>, removing: Set<GmailLabelID>, work: WorkClass) async throws -> GmailMessage {
        try enter(.messagesModify); return try await inner.modify(id, adding: adding, removing: removing, work: work)
    }
    func batchModify(_ ids: [GmailMessageID], adding: Set<GmailLabelID>, removing: Set<GmailLabelID>, work: WorkClass) async throws {
        try enter(.messagesBatchModify); try await inner.batchModify(ids, adding: adding, removing: removing, work: work)
    }
    func batchDelete(_ ids: [GmailMessageID], work: WorkClass) async throws {
        try enter(.messagesBatchDelete); try await inner.batchDelete(ids, work: work)
    }
    func trash(_ id: GmailMessageID, work: WorkClass) async throws -> GmailMessage { try enter(.messagesTrash); return try await inner.trash(id, work: work) }
    func untrash(_ id: GmailMessageID, work: WorkClass) async throws -> GmailMessage {
        try enter(.messagesUntrash); return try await inner.untrash(id, work: work)
    }
    func send(_ raw: Data, threadID: GmailThreadID?, work: WorkClass) async throws -> GmailMessage {
        try enter(.messagesSend); return try await inner.send(raw, threadID: threadID, work: work)
    }
    func importMessage(_ raw: Data, labels: Set<GmailLabelID>, options: GmailImportOptions, work: WorkClass) async throws -> GmailMessage {
        try enter(.messagesImport); return try await inner.importMessage(raw, labels: labels, options: options, work: work)
    }
    func createDraft(_ raw: Data, threadID: GmailThreadID?, work: WorkClass) async throws -> GmailDraft {
        try enter(.draftsCreate); return try await inner.createDraft(raw, threadID: threadID, work: work)
    }
    func updateDraft(_ draftID: String, raw: Data, threadID: GmailThreadID?, work: WorkClass) async throws -> GmailDraft {
        try enter(.draftsUpdate); return try await inner.updateDraft(draftID, raw: raw, threadID: threadID, work: work)
    }
    func deleteDraft(_ draftID: String, work: WorkClass) async throws { try enter(.draftsDelete); try await inner.deleteDraft(draftID, work: work) }
    func drafts(pageToken: String?, work: WorkClass) async throws -> GmailDraftList {
        try enter(.draftsList); return try await inner.drafts(pageToken: pageToken, work: work)
    }
    func setFloodMode(_ on: Bool) async { await inner.setFloodMode(on) }
    func noteOwnerActivity(at date: Date) async { await inner.noteOwnerActivity(at: date) }
    func pause() async -> GmailPause? {
        if let own = lock.withLock({ _pause }) { return own }
        return await inner.pause()
    }
    func usage() async -> GmailUsage { await inner.usage() }
}

/// One account's engine over a transport and a store, with a hand-moved clock and every event
/// kept. Its files live in a temporary folder of their own, removed at the end.
struct GmailEngineRig {
    let account: AccountInfo
    let transport: HookedGmailTransport
    let store: MemoryGmailStore
    let clock: ManualGmailClock
    let events: GmailEventRecorder
    let engine: GmailAccountEngine
    let directory: URL

    init(transport inner: any GmailTransport, email: String = "owner@example.com", store existing: MemoryGmailStore? = nil,
         clock: ManualGmailClock = ManualGmailClock(), settings: GmailEngineSettings? = nil, hints: [FolderInfo] = [],
         parts: GmailEngineParts = GmailEngineParts(), muted: (@Sendable (MessageSummary) async -> Bool)? = nil,
         directory: URL? = nil) {
        account = AccountInfo(id: inner.accountID, email: email, displayName: "Owner", authMethod: "oauth")
        transport = HookedGmailTransport(inner)
        self.directory = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("gmail-engine-\(UUID().uuidString)",
                                                                                                    isDirectory: true)
        store = existing ?? MemoryGmailStore(accountID: account.id, files: GmailFiles(directory: self.directory))
        self.clock = clock
        let events = GmailEventRecorder()
        self.events = events
        var chosen = settings ?? GmailEngineSettings()
        if settings == nil { chosen.fillsCache = false }
        engine = GmailAccountEngine(account: account, transport: transport, store: store, settings: chosen, clock: clock,
                                    folderHints: hints, parts: parts, muted: muted, events: { events.record($0) })
    }

    /// The same store and folder under a new engine, as after a relaunch.
    func relaunched(settings: GmailEngineSettings? = nil) -> GmailEngineRig {
        GmailEngineRig(transport: transport.inner, email: account.email, store: store, clock: clock, settings: settings, directory: directory)
    }

    /// Steps 0 to 4 and 7 of the first load, without the loop or the cache: every message listed.
    func listEverything() async throws {
        try await engine.backfillStart()
        await engine.runBackfill()
    }

    func finish() async {
        await engine.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Waits, in real time, until `condition` holds, for work the engine does in tasks of its own.
func waitUntil(timeout: TimeInterval = 10, _ what: String = "condition", _ condition: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("timed out waiting for \(what)")
}
