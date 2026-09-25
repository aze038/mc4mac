import Foundation
@testable import FalconCore

/// A Gmail mailbox in memory behind `GmailTransport`, so work built on the transport can be tested
/// without HTTP. It keeps Google's rules where the engine depends on them: history after a start
/// point in the order changes were made, a floor below which history is gone, a new message id for
/// every draft save, SENT and DRAFT refused to modify, at most 1,000 ids a bulk call, and every
/// call's units at Google's prices. `FakeGmailMailbox` serves the same mailbox over HTTP.
final class MemoryGmailTransport: GmailTransport, @unchecked Sendable {
    struct Message {
        var ref: GmailRef
        var labels: Set<GmailLabelID>
        /// When Gmail received it.
        var date: Date
        var headers: [GmailHeader]
        var text: String
        /// The bytes as uploaded, for a message that was sent, imported or saved as a draft.
        var raw: Data?
        var hasAttachment: Bool
        var size: Int
        var historyID: HistoryID
    }

    struct UserLabel {
        var name: String
        var labelListVisibility = "labelShow"
    }

    let accountID: UUID
    let email: String
    private let lock = NSLock()
    private var store: [UInt64: Message] = [:]
    private var nextMessage: UInt64 = 0x19a0_0000_0000_0000
    private var log: [GmailHistoryRecord] = []
    private var current = HistoryID(raw: 5_000)
    private var floor = HistoryID(raw: 5_000)
    private var _userLabels: [GmailLabelID: UserLabel] = [:]
    private var nextLabel = 1
    private var draftMessages: [String: UInt64] = [:]
    private var nextDraft = 1
    private var faults: [(method: GmailMethod?, error: GoogleAPIError)] = []
    private var standing: [GmailMethod: GoogleAPIError] = [:]
    private var _units: [GmailMethod: Int] = [:]
    private var _calls: [GmailMethod: Int] = [:]
    private var _attempts: [GmailMethod: Int] = [:]
    private var bytesDown = 0
    private var bytesUp = 0
    private var _floodMode = false
    private var _activity: [Date] = []
    private var _pause: GmailPause?
    private var _historyPageSize = 500
    private var _replacesMessageIDOnSend = false
    private var _sendAs: [GmailSendAs]

    static let systemLabels: [GmailLabelID] = GmailLabelID.fixedSlots

    init(email: String = "owner@example.com", accountID: UUID = UUID()) {
        self.email = email
        self.accountID = accountID
        _sendAs = [GmailSendAs(sendAsEmail: email, isPrimary: true, isDefault: true)]
    }

    // MARK: - Setting the mailbox up

    @discardableResult
    func add(subject: String, from: String = "Ana <ana@example.com>", to: String? = nil, cc: String = "",
             text: String = "Hello", labels: Set<GmailLabelID> = [.inbox, .unread], date: Date = Date(),
             thread: GmailThreadID? = nil, messageID: String? = nil, hasAttachment: Bool = false, size: Int? = nil,
             recordHistory: Bool = true) -> GmailRef {
        lock.withLock {
            let id = newMessageID()
            var headers = [GmailHeader(name: "From", value: from), GmailHeader(name: "To", value: to ?? email),
                           GmailHeader(name: "Subject", value: subject), GmailHeader(name: "Date", value: RFC5322Date.format(date)),
                           GmailHeader(name: "Message-ID", value: messageID ?? "<\(id.hex)@mail.example.com>")]
            if !cc.isEmpty { headers.append(GmailHeader(name: "Cc", value: cc)) }
            let ref = GmailRef(id: id, threadID: thread ?? GmailThreadID(raw: id.raw))
            insert(Message(ref: ref, labels: labels, date: date, headers: headers, text: text, raw: nil,
                           hasAttachment: hasAttachment, size: size ?? (text.utf8.count + (hasAttachment ? 50_000 : 0)),
                           historyID: current), recordHistory: recordHistory)
            return ref
        }
    }

    /// Changes a message's labels as another device would, writing history for what really changed.
    func relabel(_ id: GmailMessageID, adding: Set<GmailLabelID> = [], removing: Set<GmailLabelID> = []) {
        lock.withLock { _ = applyLabels(id, adding: adding, removing: removing) }
    }

    /// Deletes a message for good, as another device would.
    func delete(_ id: GmailMessageID) {
        lock.withLock { remove(id) }
    }

    @discardableResult
    func addUserLabel(named name: String, visibility: String = "labelShow") -> GmailLabelID {
        lock.withLock { newUserLabel(named: name, visibility: visibility) }
    }

    /// Forgets the history so far, as Gmail does after a week or sometimes hours: any earlier
    /// start point is then refused as expired.
    func expireHistory() {
        lock.withLock { floor = current }
    }

    /// Refuses the next `times` calls to `method`, or any call when nil, with `error`.
    func fail(_ method: GmailMethod?, with error: GoogleAPIError, times: Int = 1) {
        lock.withLock { for _ in 0..<times { faults.append((method, error)) } }
    }

    /// Refuses every call to `method` with `error` until cleared with nil.
    func failAlways(_ method: GmailMethod, with error: GoogleAPIError?) {
        lock.withLock { standing[method] = error }
    }

    func setPause(_ pause: GmailPause?) { lock.withLock { _pause = pause } }

    var historyPageSize: Int {
        get { lock.withLock { _historyPageSize } }
        set { lock.withLock { _historyPageSize = max(1, newValue) } }
    }

    /// Google does not promise that a sent message keeps FalconMail's Message-ID. When this is
    /// set, the fake gives it one of its own and keeps the original in
    /// X-Google-Original-Message-ID, as some reports say Gmail does.
    var replacesMessageIDOnSend: Bool {
        get { lock.withLock { _replacesMessageIDOnSend } }
        set { lock.withLock { _replacesMessageIDOnSend = newValue } }
    }

    var sendAsAddresses: [GmailSendAs] {
        get { lock.withLock { _sendAs } }
        set { lock.withLock { _sendAs = newValue } }
    }

    // MARK: - Looking at it

    var messages: [Message] { lock.withLock { store.values.sorted { $0.ref.id < $1.ref.id } } }
    func message(_ id: GmailMessageID) -> Message? { lock.withLock { store[id.raw] } }
    var historyID: HistoryID { lock.withLock { current } }
    var units: [GmailMethod: Int] { lock.withLock { _units } }
    var calls: [GmailMethod: Int] { lock.withLock { _calls } }
    /// Every call that reached the mailbox, answered or refused.
    var attempts: [GmailMethod: Int] { lock.withLock { _attempts } }
    var totalUnits: Int { units.values.reduce(0, +) }
    var isFloodMode: Bool { lock.withLock { _floodMode } }
    var ownerActivity: [Date] { lock.withLock { _activity } }
    var userLabels: [GmailLabelID: UserLabel] { lock.withLock { _userLabels } }
    var draftIDs: [String: GmailMessageID] { lock.withLock { draftMessages.mapValues { GmailMessageID(raw: $0) } } }

    // MARK: - GmailTransport: the account

    func profile(work: WorkClass) async throws -> GmailProfile {
        try lock.withLock {
            try begin(.profile)
            charge(.profile)
            return GmailProfile(emailAddress: email, messagesTotal: store.count,
                                threadsTotal: Set(store.values.map(\.ref.threadID)).count, historyId: current.description)
        }
    }

    func labels(work: WorkClass) async throws -> [GmailLabel] {
        try lock.withLock {
            try begin(.labelsList)
            charge(.labelsList)
            let system = MemoryGmailTransport.systemLabels.map { GmailLabel(id: $0.value, name: $0.value, type: "system") }
            let user = _userLabels.sorted { $0.key < $1.key }.map {
                GmailLabel(id: $0.key.value, name: $0.value.name, type: "user", labelListVisibility: $0.value.labelListVisibility,
                           messageListVisibility: "show")
            }
            return system + user
        }
    }

    func label(_ id: GmailLabelID, work: WorkClass) async throws -> GmailLabel {
        try lock.withLock {
            try begin(.labelsGet)
            let answer = try labelAnswer(id)
            charge(.labelsGet)
            return answer
        }
    }

    func createLabel(named name: String, work: WorkClass) async throws -> GmailLabel {
        try lock.withLock {
            try begin(.labelsCreate)
            if _userLabels.values.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                throw GoogleAPIError(kind: .other, httpStatus: 409, reason: "duplicate", detail: "Label name exists or conflicts")
            }
            let id = newUserLabel(named: name, visibility: "labelShow")
            charge(.labelsCreate)
            return GmailLabel(id: id.value, name: name, type: "user", labelListVisibility: "labelShow", messageListVisibility: "show")
        }
    }

    func sendAs(work: WorkClass) async throws -> [GmailSendAs] {
        try lock.withLock {
            try begin(.sendAsList)
            charge(.sendAsList)
            return _sendAs
        }
    }

    // MARK: - GmailTransport: reading

    func list(_ query: GmailListQuery, work: WorkClass) async throws -> GmailListPage {
        try lock.withLock {
            try begin(.messagesList)
            let terms = MemoryGmailTransport.terms(query.query ?? "")
            let spamTrashAsked = query.includeSpamTrash || query.labels.contains(.spam) || query.labels.contains(.trash)
                || terms.contains { ["in:spam", "in:trash", "in:anywhere"].contains($0.lowercased()) }
            let wanted = Set(query.labels)
            let hits = store.values
                .filter { wanted.isSubset(of: $0.labels) }
                .filter { spamTrashAsked || $0.labels.isDisjoint(with: [.spam, .trash]) }
                .filter { m in terms.allSatisfy { matches(m, $0) } }
                .sorted { ($0.date, $0.ref.id) > ($1.date, $1.ref.id) }
            let offset = Int(query.pageToken ?? "") ?? 0
            let page = Array(hits.dropFirst(offset).prefix(max(1, min(500, query.maxResults))))
            charge(.messagesList)
            let next = offset + page.count < hits.count ? String(offset + page.count) : nil
            return GmailListPage(refs: page.map(\.ref), nextPageToken: next, resultSizeEstimate: hits.count)
        }
    }

    func history(since start: HistoryID, types: Set<GmailHistoryType>, label: GmailLabelID?,
                 pageToken: String?, work: WorkClass) async throws -> GmailHistoryPage {
        try lock.withLock {
            try begin(.historyList)
            guard start >= floor else {
                throw GoogleAPIError(kind: .historyExpired, httpStatus: 404, reason: "notFound", detail: "Requested entity was not found.")
            }
            let wanted = types.isEmpty ? Set(GmailHistoryType.allCases) : types
            let records = log.filter { $0.id > start }.map { filtered($0, types: wanted, label: label) }.filter { !$0.isEmpty }
            let offset = Int(pageToken ?? "") ?? 0
            let page = Array(records.dropFirst(offset).prefix(_historyPageSize))
            charge(.historyList)
            let next = offset + page.count < records.count ? String(offset + page.count) : nil
            return GmailHistoryPage(records: page, nextPageToken: next, historyID: current)
        }
    }

    func message(_ id: GmailMessageID, format: GmailFormat, work: WorkClass) async throws -> GmailMessage {
        try lock.withLock {
            try begin(.messagesGet)
            let answer = try messageAnswer(id, format)
            charge(.messagesGet, down: answer.payload?.body?.size ?? answer.raw?.count ?? 0)
            return answer
        }
    }

    func thread(_ id: GmailThreadID, format: GmailFormat, work: WorkClass) async throws -> GmailThread {
        try lock.withLock {
            try begin(.threadsGet)
            let answer = try threadAnswer(id, format)
            charge(.threadsGet)
            return answer
        }
    }

    func batch(_ parts: [GmailBatchPart], work: WorkClass) async throws -> [GmailBatchPart: Result<GmailBatchAnswer, GoogleAPIError>] {
        try lock.withLock {
            if let i = faults.firstIndex(where: { $0.method == nil }) { throw faults.remove(at: i).error }
            var out: [GmailBatchPart: Result<GmailBatchAnswer, GoogleAPIError>] = [:]
            for part in parts {
                do {
                    try begin(part.method)
                    switch part {
                    case .message(let id, let format): out[part] = .success(.message(try messageAnswer(id, format)))
                    case .thread(let id, let format): out[part] = .success(.thread(try threadAnswer(id, format)))
                    case .label(let id): out[part] = .success(.label(try labelAnswer(id)))
                    }
                    charge(part.method)
                } catch let error as GoogleAPIError {
                    out[part] = .failure(error)
                }
            }
            return out
        }
    }

    func attachment(_ attachmentID: String, of message: GmailMessageID, work: WorkClass) async throws -> Data {
        try lock.withLock {
            try begin(.attachmentsGet)
            guard let m = store[message.raw], m.hasAttachment, attachmentID == MemoryGmailTransport.attachmentID(message) else {
                throw MemoryGmailTransport.notFound
            }
            let data = MemoryGmailTransport.attachmentBytes(m.ref.id)
            charge(.attachmentsGet, down: data.count)
            return data
        }
    }

    // MARK: - GmailTransport: changing

    func modify(_ id: GmailMessageID, adding: Set<GmailLabelID>, removing: Set<GmailLabelID>,
                work: WorkClass) async throws -> GmailMessage {
        try lock.withLock {
            try begin(.messagesModify)
            try checkLabels(adding.union(removing))
            guard store[id.raw] != nil else { throw MemoryGmailTransport.notFound }
            _ = applyLabels(id, adding: adding, removing: removing)
            charge(.messagesModify)
            return try messageAnswer(id, .minimal)
        }
    }

    func batchModify(_ ids: [GmailMessageID], adding: Set<GmailLabelID>, removing: Set<GmailLabelID>,
                     work: WorkClass) async throws {
        try lock.withLock {
            try begin(.messagesBatchModify)
            try checkBulk(ids)
            try checkLabels(adding.union(removing))
            for id in ids where store[id.raw] != nil { _ = applyLabels(id, adding: adding, removing: removing) }
            charge(.messagesBatchModify)
        }
    }

    func batchDelete(_ ids: [GmailMessageID], work: WorkClass) async throws {
        try lock.withLock {
            try begin(.messagesBatchDelete)
            try checkBulk(ids)
            for id in ids { remove(id) }
            charge(.messagesBatchDelete)
        }
    }

    func trash(_ id: GmailMessageID, work: WorkClass) async throws -> GmailMessage {
        try lock.withLock {
            try begin(.messagesTrash)
            guard store[id.raw] != nil else { throw MemoryGmailTransport.notFound }
            _ = applyLabels(id, adding: [.trash], removing: [])
            charge(.messagesTrash)
            return try messageAnswer(id, .minimal)
        }
    }

    func untrash(_ id: GmailMessageID, work: WorkClass) async throws -> GmailMessage {
        try lock.withLock {
            try begin(.messagesUntrash)
            guard store[id.raw] != nil else { throw MemoryGmailTransport.notFound }
            _ = applyLabels(id, adding: [], removing: [.trash])
            charge(.messagesUntrash)
            return try messageAnswer(id, .minimal)
        }
    }

    // MARK: - GmailTransport: uploading

    func send(_ raw: Data, threadID: GmailThreadID?, work: WorkClass) async throws -> GmailMessage {
        try lock.withLock {
            try begin(.messagesSend)
            let parsed = MIMEParser.parse(raw)
            var headers = parsed.headers.fields.map { GmailHeader(name: $0.name, value: $0.value) }
            if _replacesMessageIDOnSend, let i = headers.firstIndex(where: { $0.name.caseInsensitiveCompare("Message-ID") == .orderedSame }) {
                let original = headers[i].value
                headers[i].value = "<gmail-\(UUID().uuidString.lowercased())@mail.gmail.com>"
                headers.append(GmailHeader(name: "X-Google-Original-Message-ID", value: original))
            }
            let recipients = (AddressParser.parse(parsed.headers.first("To")) + AddressParser.parse(parsed.headers.first("Cc")))
                .map { $0.address.lowercased() }
            var labels: Set<GmailLabelID> = [.sent]
            if recipients.contains(email.lowercased()) { labels.formUnion([.inbox, .unread]) }
            let message = upload(raw, headers: headers, text: parsed.textPlain ?? "", labels: labels, date: Date(), thread: threadID)
            charge(.messagesSend, up: raw.count)
            return try messageAnswer(message.id, .minimal)
        }
    }

    func importMessage(_ raw: Data, labels: Set<GmailLabelID>, options: GmailImportOptions,
                       work: WorkClass) async throws -> GmailMessage {
        try lock.withLock {
            try begin(.messagesImport)
            try checkLabels(labels.subtracting([.draft, .sent]))
            let parsed = MIMEParser.parse(raw)
            let date = options.internalDateSource == .dateHeader ? (parsed.date ?? Date()) : Date()
            let headers = parsed.headers.fields.map { GmailHeader(name: $0.name, value: $0.value) }
            let message = upload(raw, headers: headers, text: parsed.textPlain ?? "", labels: labels, date: date, thread: nil)
            charge(.messagesImport, up: raw.count)
            return try messageAnswer(message.id, .minimal)
        }
    }

    func createDraft(_ raw: Data, threadID: GmailThreadID?, work: WorkClass) async throws -> GmailDraft {
        try lock.withLock {
            try begin(.draftsCreate)
            let draftID = "r\(nextDraft)"
            nextDraft += 1
            let message = saveDraftMessage(raw, thread: threadID)
            draftMessages[draftID] = message.id.raw
            charge(.draftsCreate, up: raw.count)
            return GmailDraft(id: draftID, message: try messageAnswer(message.id, .minimal))
        }
    }

    func updateDraft(_ draftID: String, raw: Data, threadID: GmailThreadID?, work: WorkClass) async throws -> GmailDraft {
        try lock.withLock {
            try begin(.draftsUpdate)
            guard let old = draftMessages[draftID] else { throw MemoryGmailTransport.notFound }
            // Gmail files every save as a new message and deletes the one before it.
            remove(GmailMessageID(raw: old))
            let message = saveDraftMessage(raw, thread: threadID)
            draftMessages[draftID] = message.id.raw
            charge(.draftsUpdate, up: raw.count)
            return GmailDraft(id: draftID, message: try messageAnswer(message.id, .minimal))
        }
    }

    func deleteDraft(_ draftID: String, work: WorkClass) async throws {
        try lock.withLock {
            try begin(.draftsDelete)
            guard let old = draftMessages.removeValue(forKey: draftID) else { throw MemoryGmailTransport.notFound }
            remove(GmailMessageID(raw: old))
            charge(.draftsDelete)
        }
    }

    func drafts(pageToken: String?, work: WorkClass) async throws -> GmailDraftList {
        try lock.withLock {
            try begin(.draftsList)
            let all = draftMessages.sorted { $0.key < $1.key }
            let offset = Int(pageToken ?? "") ?? 0
            let page = all.dropFirst(offset).prefix(100)
            charge(.draftsList)
            let drafts = page.map { entry -> GmailDraft in
                let ref = store[entry.value]?.ref
                return GmailDraft(id: entry.key, message: ref.map { GmailMessage(id: $0.id.hex, threadId: $0.threadID.hex) })
            }
            let next = offset + page.count < all.count ? String(offset + page.count) : nil
            return GmailDraftList(drafts: drafts, nextPageToken: next, resultSizeEstimate: all.count)
        }
    }

    // MARK: - GmailTransport: the budget

    func setFloodMode(_ on: Bool) async { lock.withLock { _floodMode = on } }
    func noteOwnerActivity(at date: Date) async { lock.withLock { _activity.append(date) } }
    func pause() async -> GmailPause? { lock.withLock { _pause } }

    func usage() async -> GmailUsage {
        lock.withLock { GmailUsage(units: _units, calls: _calls, bytesDown: bytesDown, bytesUp: bytesUp) }
    }

    // MARK: - Inside the lock

    static let notFound = GoogleAPIError(kind: .notFound, httpStatus: 404, reason: "notFound", detail: "Requested entity was not found.")

    static func attachmentID(_ id: GmailMessageID) -> String { "att-\(id.hex)" }
    static func attachmentBytes(_ id: GmailMessageID) -> Data { Data("attachment of \(id.hex)".utf8) }

    private func begin(_ method: GmailMethod) throws {
        _attempts[method, default: 0] += 1
        if let i = faults.firstIndex(where: { $0.method == nil || $0.method == method }) { throw faults.remove(at: i).error }
        if let error = standing[method] { throw error }
    }

    private func charge(_ method: GmailMethod, down: Int = 0, up: Int = 0) {
        _units[method, default: 0] += method.units
        _calls[method, default: 0] += 1
        bytesDown += down
        bytesUp += up
    }

    private func newMessageID() -> GmailMessageID {
        nextMessage += 0x10
        return GmailMessageID(raw: nextMessage)
    }

    private func newUserLabel(named name: String, visibility: String) -> GmailLabelID {
        let id = GmailLabelID("Label_\(nextLabel)")
        nextLabel += 1
        _userLabels[id] = UserLabel(name: name, labelListVisibility: visibility)
        return id
    }

    private func bump() -> HistoryID {
        current = HistoryID(raw: current.raw + 1)
        return current
    }

    private func insert(_ message: Message, recordHistory: Bool = true) {
        var m = message
        if recordHistory {
            m.historyID = bump()
            log.append(GmailHistoryRecord(id: m.historyID, messagesAdded: [GmailHistoryMessage(ref: m.ref, labels: m.labels.sorted())]))
        }
        store[m.ref.id.raw] = m
    }

    private func remove(_ id: GmailMessageID) {
        guard let m = store.removeValue(forKey: id.raw) else { return }
        let history = bump()
        log.append(GmailHistoryRecord(id: history, messagesDeleted: [GmailHistoryMessage(ref: m.ref, labels: m.labels.sorted())]))
    }

    /// Writes one history record for what really changed, as Gmail does: adding a label a
    /// message has, or removing one it lacks, changes nothing and writes nothing.
    private func applyLabels(_ id: GmailMessageID, adding: Set<GmailLabelID>, removing: Set<GmailLabelID>) -> Bool {
        guard var m = store[id.raw] else { return false }
        let added = adding.subtracting(m.labels)
        let removed = removing.intersection(m.labels).subtracting(adding)
        guard !added.isEmpty || !removed.isEmpty else { return false }
        m.labels.formUnion(added)
        m.labels.subtract(removed)
        m.historyID = bump()
        store[id.raw] = m
        let message = GmailHistoryMessage(ref: m.ref, labels: m.labels.sorted())
        log.append(GmailHistoryRecord(id: m.historyID,
                                      labelsAdded: added.isEmpty ? [] : [GmailLabelChange(message: message, labels: added.sorted())],
                                      labelsRemoved: removed.isEmpty ? [] : [GmailLabelChange(message: message, labels: removed.sorted())]))
        return true
    }

    private func upload(_ raw: Data, headers: [GmailHeader], text: String, labels: Set<GmailLabelID>, date: Date,
                        thread: GmailThreadID?) -> GmailRef {
        let id = newMessageID()
        let threadID = thread.flatMap { t in store.values.contains { $0.ref.threadID == t } ? t : nil } ?? GmailThreadID(raw: id.raw)
        let ref = GmailRef(id: id, threadID: threadID)
        insert(Message(ref: ref, labels: labels, date: date, headers: headers, text: text, raw: raw, hasAttachment: false,
                       size: raw.count, historyID: current))
        return ref
    }

    private func saveDraftMessage(_ raw: Data, thread: GmailThreadID?) -> GmailRef {
        let parsed = MIMEParser.parse(raw)
        let headers = parsed.headers.fields.map { GmailHeader(name: $0.name, value: $0.value) }
        return upload(raw, headers: headers, text: parsed.textPlain ?? "", labels: [.draft], date: Date(), thread: thread)
    }

    private func checkLabels(_ labels: Set<GmailLabelID>) throws {
        if !labels.isDisjoint(with: GmailLabelID.fixedByGmail) {
            throw GoogleAPIError(kind: .other, httpStatus: 400, reason: "invalidArgument", detail: "Invalid label")
        }
        for label in labels where label.isUserLabel && _userLabels[label] == nil {
            throw GoogleAPIError(kind: .notFound, httpStatus: 404, reason: "notFound", detail: "Label not found")
        }
    }

    private func checkBulk(_ ids: [GmailMessageID]) throws {
        guard ids.count <= 1_000 else {
            throw GoogleAPIError(kind: .other, httpStatus: 400, reason: "invalidArgument", detail: "Too many ids")
        }
    }

    private func labelAnswer(_ id: GmailLabelID) throws -> GmailLabel {
        let user = _userLabels[id]
        guard user != nil || MemoryGmailTransport.systemLabels.contains(id) else { throw MemoryGmailTransport.notFound }
        let members = store.values.filter { $0.labels.contains(id) }
        let unread = members.filter { $0.labels.contains(.unread) }
        return GmailLabel(id: id.value, name: user?.name ?? id.value, type: user == nil ? "system" : "user",
                          labelListVisibility: user?.labelListVisibility, messageListVisibility: user == nil ? nil : "show",
                          messagesTotal: members.count, messagesUnread: unread.count,
                          threadsTotal: Set(members.map(\.ref.threadID)).count, threadsUnread: Set(unread.map(\.ref.threadID)).count)
    }

    private func messageAnswer(_ id: GmailMessageID, _ format: GmailFormat) throws -> GmailMessage {
        guard let m = store[id.raw] else { throw MemoryGmailTransport.notFound }
        return MemoryGmailTransport.answer(m, format)
    }

    private func threadAnswer(_ id: GmailThreadID, _ format: GmailFormat) throws -> GmailThread {
        let members = store.values.filter { $0.ref.threadID == id }.sorted { ($0.date, $0.ref.id) < ($1.date, $1.ref.id) }
        guard let newest = members.last else { throw MemoryGmailTransport.notFound }
        return GmailThread(id: id.hex, historyId: newest.historyID.description, messages: members.map { MemoryGmailTransport.answer($0, format) })
    }

    private func filtered(_ record: GmailHistoryRecord, types: Set<GmailHistoryType>, label: GmailLabelID?) -> GmailHistoryRecord {
        func keep(_ m: GmailHistoryMessage) -> Bool { label.map { m.labels?.contains($0) ?? false } ?? true }
        var out = GmailHistoryRecord(id: record.id)
        if types.contains(.messageAdded) { out.messagesAdded = record.messagesAdded.filter(keep) }
        if types.contains(.messageDeleted) { out.messagesDeleted = record.messagesDeleted.filter(keep) }
        if types.contains(.labelAdded) { out.labelsAdded = record.labelsAdded.filter { keep($0.message) } }
        if types.contains(.labelRemoved) { out.labelsRemoved = record.labelsRemoved.filter { keep($0.message) } }
        return out
    }

    static func answer(_ m: Message, _ format: GmailFormat) -> GmailMessage {
        var out = GmailMessage(id: m.ref.id.hex, threadId: m.ref.threadID.hex, labelIds: m.labels.map(\.value).sorted(),
                               historyId: m.historyID.description,
                               internalDate: String(Int64(m.date.timeIntervalSince1970 * 1000)), sizeEstimate: m.size)
        switch format {
        case .minimal:
            break
        case .metadata(let names):
            let wanted = Set(names.map { $0.lowercased() })
            out.snippet = String(m.text.prefix(100))
            out.payload = GmailPart(partId: "", mimeType: "text/plain", filename: "",
                                    headers: wanted.isEmpty ? m.headers : m.headers.filter { wanted.contains($0.name.lowercased()) })
        case .full:
            out.snippet = String(m.text.prefix(100))
            out.payload = fullPayload(m)
        case .raw:
            out.raw = rawBytes(m).base64URL
        }
        return out
    }

    private static func fullPayload(_ m: Message) -> GmailPart {
        let text = Data(m.text.utf8)
        let textPart = GmailPart(partId: m.hasAttachment ? "0" : "", mimeType: "text/plain", filename: "",
                                 headers: [GmailHeader(name: "Content-Type", value: "text/plain; charset=UTF-8")],
                                 body: GmailPartBody(size: text.count, data: text.base64URL))
        guard m.hasAttachment else {
            var single = textPart
            single.headers = m.headers + (textPart.headers ?? [])
            return single
        }
        let attachment = GmailPart(partId: "1", mimeType: "application/pdf", filename: "attachment.pdf",
                                   headers: [GmailHeader(name: "Content-Type", value: "application/pdf; name=\"attachment.pdf\""),
                                             GmailHeader(name: "Content-Disposition", value: "attachment; filename=\"attachment.pdf\"")],
                                   body: GmailPartBody(attachmentId: attachmentID(m.ref.id), size: attachmentBytes(m.ref.id).count))
        return GmailPart(partId: "", mimeType: "multipart/mixed", filename: "",
                         headers: m.headers + [GmailHeader(name: "Content-Type", value: "multipart/mixed; boundary=b1")],
                         body: GmailPartBody(size: 0), parts: [textPart, attachment])
    }

    private static func rawBytes(_ m: Message) -> Data {
        if let raw = m.raw { return raw }
        let head = m.headers.map { "\($0.name): \($0.value)" }.joined(separator: "\r\n")
        return Data((head + "\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n" + m.text).utf8)
    }

    // MARK: - Search

    static func terms(_ q: String) -> [String] {
        FakeGmailMailbox.terms(q)
    }

    private func matches(_ m: Message, _ term: String) -> Bool {
        let lower = term.lowercased()
        // Gmail's search ignores case, so every comparison here is between lower-cased text.
        func value(_ prefix: String) -> String? {
            lower.hasPrefix(prefix) ? String(lower.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) : nil
        }
        func header(_ name: String) -> String {
            m.headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
        }
        func bytes(_ text: String) -> Int {
            let t = text.lowercased()
            if t.hasSuffix("m"), let n = Int(t.dropLast()) { return n * 1_000_000 }
            if t.hasSuffix("k"), let n = Int(t.dropLast()) { return n * 1_000 }
            return Int(t) ?? 0
        }
        if let v = value("before:"), let seconds = TimeInterval(v) { return m.date.timeIntervalSince1970 < seconds }
        if let v = value("after:"), let seconds = TimeInterval(v) { return m.date.timeIntervalSince1970 >= seconds }
        if let v = value("larger:") { return m.size > bytes(v) }
        if let v = value("smaller:") { return m.size < bytes(v) }
        if let v = value("rfc822msgid:") {
            let wanted = v.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            return header("Message-ID").trimmingCharacters(in: CharacterSet(charactersIn: "<>")).lowercased() == wanted
        }
        if lower == "has:attachment" { return m.hasAttachment }
        if let v = value("in:") {
            switch v {
            case "inbox": return m.labels.contains(.inbox)
            case "sent": return m.labels.contains(.sent)
            case "drafts": return m.labels.contains(.draft)
            case "spam": return m.labels.contains(.spam)
            case "trash": return m.labels.contains(.trash)
            default: return true
            }
        }
        if let v = value("is:") {
            switch v {
            case "unread": return m.labels.contains(.unread)
            case "starred": return m.labels.contains(.starred)
            case "important": return m.labels.contains(.important)
            default: return false
            }
        }
        if let v = value("label:") {
            return m.labels.contains { id in (_userLabels[id]?.name ?? id.value).lowercased() == v }
        }
        if let v = value("from:") { return header("From").lowercased().contains(v) }
        if let v = value("to:") { return header("To").lowercased().contains(v) }
        if let v = value("subject:") { return header("Subject").lowercased().contains(v) }
        let needle = lower.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return [header("Subject"), header("From"), m.text].contains { $0.lowercased().contains(needle) }
    }
}
