import Foundation
@testable import FalconCore

/// The in-memory Gmail behind the real transport: `FakeGmailMailbox` served over
/// `FakeGmailURLProtocol`, reached through `GmailHTTPTransport` with its budget on a virtual clock,
/// so waits for units take no time. It offers the setting-up and looking API of
/// `MemoryGmailTransport`, in Gmail's typed ids, so the engine's tests read as they did while
/// every call now goes through the transport's HTTP, batches, budget, refusal sorting and retries.
final class FakeGmail: GmailTransport, GmailServerClock, @unchecked Sendable {
    typealias Message = MemoryGmailTransport.Message
    typealias UserLabel = MemoryGmailTransport.UserLabel

    let mailbox: FakeGmailMailbox
    let http: GmailHTTPTransport
    let clock: VirtualClock
    let email: String

    init(email: String = "owner@example.com", accountID: UUID = UUID(), mailbox: FakeGmailMailbox? = nil,
         policy: GmailBudgetPolicy = .standard, options: GmailTransportOptions = GmailTransportOptions(),
         clock: VirtualClock = VirtualClock()) {
        self.email = email
        self.clock = clock
        let mailbox = mailbox ?? FakeGmailMailbox(email: email)
        self.mailbox = mailbox
        http = GmailTestKit.transport(mailbox, clock: clock, accountID: accountID, policy: policy, options: options)
    }

    var accountID: UUID { http.accountID }

    // MARK: - Setting the mailbox up, as another device would change it

    @discardableResult
    func add(subject: String, from: String = "Ana <ana@example.com>", to: String? = nil, cc: String = "",
             text: String = "Hello", labels: Set<GmailLabelID> = [.inbox, .unread], date: Date = Date(),
             thread: GmailThreadID? = nil, messageID: String? = nil, hasAttachment: Bool = false, size: Int? = nil,
             recordHistory: Bool = true) -> GmailRef {
        let attachments = hasAttachment
            ? [FakeGmailMailbox.Attachment(filename: "attachment.pdf", mimeType: "application/pdf", data: Data(count: 50_000))] : []
        let added = mailbox.add(subject: subject, from: from, to: to ?? email, cc: cc, text: text, labels: Set(labels.map(\.value)),
                                date: date, messageID: messageID, threadID: thread?.hex, attachments: attachments, size: size,
                                recordHistory: recordHistory)
        return FakeGmail.ref(added)
    }

    func relabel(_ id: GmailMessageID, adding: Set<GmailLabelID> = [], removing: Set<GmailLabelID> = []) {
        mailbox.relabel(id.hex, adding: Set(adding.map(\.value)), removing: Set(removing.map(\.value)))
    }

    func delete(_ id: GmailMessageID) {
        mailbox.delete(id.hex)
    }

    @discardableResult
    func addUserLabel(named name: String, visibility: String = "labelShow") -> GmailLabelID {
        GmailLabelID(mailbox.addUserLabel(named: name, visibility: visibility))
    }

    func expireHistory() {
        mailbox.expireHistory()
    }

    /// Refuses the next `times` calls to `method`, or any call when nil, as Gmail would refuse
    /// them over HTTP; the transport then sorts the refusal, and tries again what may be tried.
    func fail(_ method: GmailMethod?, with error: GoogleAPIError, times: Int = 1) {
        mailbox.inject(FakeGmail.fault(error, method: method), for: method, times: times)
    }

    /// Refuses every call to `method` until cleared with nil.
    func failAlways(_ method: GmailMethod, with error: GoogleAPIError?) {
        mailbox.always(error.map { FakeGmail.fault($0, method: method) }, for: method)
    }

    var replacesMessageIDOnSend: Bool {
        get { mailbox.replacesMessageIDOnSend }
        set { mailbox.replacesMessageIDOnSend = newValue }
    }

    var sendAsAddresses: [GmailSendAs] {
        get { mailbox.sendAsAddresses.enumerated().map { GmailSendAs(sendAsEmail: $1, isPrimary: $0 == 0, isDefault: $0 == 0) } }
        set { mailbox.sendAsAddresses = newValue.map(\.sendAsEmail) }
    }

    // MARK: - Looking at it

    var messages: [Message] { mailbox.messages.map(FakeGmail.typed).sorted { $0.ref.id < $1.ref.id } }
    func message(_ id: GmailMessageID) -> Message? { mailbox.message(id.hex).map(FakeGmail.typed) }
    var historyID: HistoryID { HistoryID(raw: mailbox.historyID) }
    var units: [GmailMethod: Int] { mailbox.units }
    var calls: [GmailMethod: Int] { mailbox.calls }
    /// Every call that reached the mailbox, answered or refused, retries included.
    var attempts: [GmailMethod: Int] { mailbox.attempts }
    var totalUnits: Int { mailbox.totalUnits }
    var userLabels: [GmailLabelID: UserLabel] {
        Dictionary(uniqueKeysWithValues: mailbox.userLabels.map { (GmailLabelID($0.key), UserLabel(name: $0.value)) })
    }
    var draftIDs: [String: GmailMessageID] { mailbox.draftIDs.compactMapValues { GmailMessageID(hex: $0) } }
    func isFloodMode() async -> Bool { await http.budget.isFloodMode }

    static func ref(_ message: FakeGmailMailbox.Message) -> GmailRef {
        GmailRef(id: GmailMessageID(hex: message.id)!, threadID: GmailThreadID(hex: message.threadID)!)
    }

    static func typed(_ m: FakeGmailMailbox.Message) -> Message {
        let labels: Set<GmailLabelID> = Set(m.labels.map { GmailLabelID($0) })
        let headers: [GmailHeader] = m.headers.map { GmailHeader(name: $0.name, value: $0.value) }
        let attached: Int = m.attachments.reduce(0) { $0 + $1.data.count }
        let size: Int = m.raw?.count ?? (m.text.utf8.count + (m.html?.utf8.count ?? 0) + attached)
        return Message(ref: ref(m), labels: labels, date: m.date, headers: headers, text: m.text, raw: m.raw,
                       hasAttachment: !m.attachments.isEmpty, size: size, historyID: HistoryID(raw: m.historyID))
    }

    /// Gmail's refusal on the wire that the transport sorts back into `error`'s kind.
    static func fault(_ error: GoogleAPIError, method: GmailMethod?) -> FakeGmailMailbox.Fault {
        let retry = error.retryAfter.map { String(Int($0.rounded(.up))) }
        switch error.kind {
        case .offline:
            return error.delivery == .unknown ? .acceptedThenDropped : .offline
        case .temporary where error.httpStatus == 0:
            return .timeout
        case .temporary:
            return .status(error.httpStatus, reason: error.reason ?? "backendError", retryAfter: retry)
        case .rateLimited:
            return .google(429, reason: error.reason ?? "rateLimitExceeded", message: "User-rate limit exceeded", retryAfter: retry ?? "1")
        case .sendingLimit:
            return .google(429, reason: "rateLimitExceeded", message: "User-rate limit exceeded (Mail sending)", retryAfter: retry)
        case .downloadLimit, .uploadLimit:
            return .bandwidth(retryAfter: Int(max(error.retryAfter ?? 7_200, GoogleErrorParser.longRetry)))
        case .quotaExhausted:
            return .status(403, reason: error.reason ?? "dailyLimitExceeded")
        case .apiDisabled:
            return .status(403, reason: error.reason ?? "accessNotConfigured")
        case .insufficientPermissions:
            return .status(403, reason: error.reason ?? "insufficientPermissions")
        case .needsSignIn:
            return .status(401, reason: error.reason ?? "authError")
        case .clientRejected:
            return .status(401, reason: error.reason ?? "unauthorized_client")
        case .notFound, .historyExpired:
            return .status(404, reason: error.reason ?? "notFound")
        case .domainPolicy:
            return .status(403, reason: "domainPolicy")
        case .gmailNotEnabled:
            return .status(400, reason: "failedPrecondition")
        case .tooLarge:
            return .status(413, reason: "payloadTooLarge")
        case .other:
            return .status(error.httpStatus == 0 ? 400 : error.httpStatus, reason: error.reason ?? "badRequest", retryAfter: retry)
        }
    }

    // MARK: - GmailTransport: the real one

    func profile(work: WorkClass) async throws -> GmailProfile { try await http.profile(work: work) }
    func labels(work: WorkClass) async throws -> [GmailLabel] { try await http.labels(work: work) }
    func label(_ id: GmailLabelID, work: WorkClass) async throws -> GmailLabel { try await http.label(id, work: work) }
    func createLabel(named name: String, work: WorkClass) async throws -> GmailLabel { try await http.createLabel(named: name, work: work) }
    func sendAs(work: WorkClass) async throws -> [GmailSendAs] { try await http.sendAs(work: work) }
    func list(_ query: GmailListQuery, work: WorkClass) async throws -> GmailListPage { try await http.list(query, work: work) }
    func history(since start: HistoryID, types: Set<GmailHistoryType>, label: GmailLabelID?, pageToken: String?,
                 work: WorkClass) async throws -> GmailHistoryPage {
        try await http.history(since: start, types: types, label: label, pageToken: pageToken, work: work)
    }
    func message(_ id: GmailMessageID, format: GmailFormat, work: WorkClass) async throws -> GmailMessage {
        try await http.message(id, format: format, work: work)
    }
    func thread(_ id: GmailThreadID, format: GmailFormat, work: WorkClass) async throws -> GmailThread {
        try await http.thread(id, format: format, work: work)
    }
    func batch(_ parts: [GmailBatchPart], work: WorkClass) async throws -> [GmailBatchPart: Result<GmailBatchAnswer, GoogleAPIError>] {
        try await http.batch(parts, work: work)
    }
    func attachment(_ attachmentID: String, of message: GmailMessageID, work: WorkClass) async throws -> Data {
        try await http.attachment(attachmentID, of: message, work: work)
    }
    func modify(_ id: GmailMessageID, adding: Set<GmailLabelID>, removing: Set<GmailLabelID>, work: WorkClass) async throws -> GmailMessage {
        try await http.modify(id, adding: adding, removing: removing, work: work)
    }
    func batchModify(_ ids: [GmailMessageID], adding: Set<GmailLabelID>, removing: Set<GmailLabelID>, work: WorkClass) async throws {
        try await http.batchModify(ids, adding: adding, removing: removing, work: work)
    }
    func batchDelete(_ ids: [GmailMessageID], work: WorkClass) async throws { try await http.batchDelete(ids, work: work) }
    func trash(_ id: GmailMessageID, work: WorkClass) async throws -> GmailMessage { try await http.trash(id, work: work) }
    func untrash(_ id: GmailMessageID, work: WorkClass) async throws -> GmailMessage { try await http.untrash(id, work: work) }
    func send(_ raw: Data, threadID: GmailThreadID?, work: WorkClass) async throws -> GmailMessage {
        try await http.send(raw, threadID: threadID, work: work)
    }
    func importMessage(_ raw: Data, labels: Set<GmailLabelID>, options: GmailImportOptions, work: WorkClass) async throws -> GmailMessage {
        try await http.importMessage(raw, labels: labels, options: options, work: work)
    }
    func createDraft(_ raw: Data, threadID: GmailThreadID?, work: WorkClass) async throws -> GmailDraft {
        try await http.createDraft(raw, threadID: threadID, work: work)
    }
    func updateDraft(_ draftID: String, raw: Data, threadID: GmailThreadID?, work: WorkClass) async throws -> GmailDraft {
        try await http.updateDraft(draftID, raw: raw, threadID: threadID, work: work)
    }
    func deleteDraft(_ draftID: String, work: WorkClass) async throws { try await http.deleteDraft(draftID, work: work) }
    func drafts(pageToken: String?, work: WorkClass) async throws -> GmailDraftList { try await http.drafts(pageToken: pageToken, work: work) }
    func setFloodMode(_ on: Bool) async { await http.setFloodMode(on) }
    func noteOwnerActivity(at date: Date) async { await http.noteOwnerActivity(at: date) }
    func pause() async -> GmailPause? { await http.pause() }
    func usage() async -> GmailUsage { await http.usage() }
    func gmailClockOffset() async -> TimeInterval? { await http.gmailClockOffset() }
}

/// The account's engine as what places FalconMail's own uploads in the index: not started, with
/// nothing to list, over the transport and the real store a test gives it.
enum GmailTestPlacer {
    static func engine(transport: any GmailTransport, store: any GmailStore, email: String = "owner@example.com",
                       now: @escaping @Sendable () -> Date = { Date() }) -> GmailAccountEngine {
        GmailAccountEngine(account: AccountInfo(id: transport.accountID, email: email, displayName: "Owner", authMethod: "oauth"),
                           transport: transport, store: store, clock: ClosureGmailClock(now: now), events: { _ in })
    }

    /// A store on disk in a folder of its own under `root`.
    static func store(accountID: UUID, root: URL) -> GmailFileStore {
        GmailFileStore(accountID: accountID, files: GmailFiles(directory: root.appendingPathComponent("gmail-\(UUID().uuidString)", isDirectory: true)))
    }
}

/// A clock whose time a test gives; its sleeps take real time.
struct ClosureGmailClock: GmailEngineClock {
    let time: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date) { time = now }

    func now() -> Date { time() }

    func sleep(until date: Date) async {
        let seconds = date.timeIntervalSince(time())
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(min(seconds, 3_600) * 1_000_000_000))
    }
}
