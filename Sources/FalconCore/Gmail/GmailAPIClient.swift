import Foundation

public struct GmailProfile: Decodable, Sendable, Hashable {
    public var emailAddress: String
    public var messagesTotal: Int?
    public var threadsTotal: Int?
    public var historyId: String?
}

public struct GmailLabel: Decodable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var type: String?
    /// `labelShow`, `labelShowIfUnread` or `labelHide`: whether Gmail lists it among the labels.
    public var labelListVisibility: String?
    /// `show` or `hide`: whether Gmail lists it on its messages.
    public var messageListVisibility: String?
    /// Counts, which only `labels.get` gives.
    public var messagesTotal: Int?
    public var messagesUnread: Int?
    public var threadsTotal: Int?
    public var threadsUnread: Int?
}

public struct GmailMessageRef: Decodable, Sendable, Hashable {
    public var id: String
    public var threadId: String
}

public struct GmailMessageList: Decodable, Sendable {
    public var messages: [GmailMessageRef]?
    public var nextPageToken: String?
    public var resultSizeEstimate: Int?
}

public struct GmailHeader: Decodable, Sendable, Hashable {
    public var name: String
    public var value: String
}

public struct GmailPartBody: Decodable, Sendable, Hashable {
    public var attachmentId: String?
    public var size: Int?
    public var data: String?
}

public struct GmailPart: Decodable, Sendable, Hashable {
    public var partId: String?
    public var mimeType: String?
    public var filename: String?
    public var headers: [GmailHeader]?
    public var body: GmailPartBody?
    public var parts: [GmailPart]?

    public func header(_ name: String) -> String? {
        headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public struct GmailMessage: Decodable, Sendable, Hashable {
    public var id: String
    public var threadId: String
    public var labelIds: [String]?
    public var snippet: String?
    public var historyId: String?
    public var internalDate: String?
    public var sizeEstimate: Int?
    public var payload: GmailPart?
    /// The whole message in base64url, in a `format=raw` answer only.
    public var raw: String?

    public func header(_ name: String) -> String? { payload?.header(name) }

    /// When Gmail received the message, which is what it orders search results by.
    public var receivedDate: Date? {
        internalDate.flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

/// Read-only calls to the Gmail API for one account. Every call books its units with the
/// account's `GmailQuotaLimiter` first and only ever throws `GoogleAPIError` or cancellation.
/// Made from a `GmailHTTPTransport`, it books through the Gmail engine's budget instead, so the
/// engine's opens and attachments count against the same account budget as everything else.
public struct GmailAPIClient: Sendable {
    public static let defaultBase = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!
    /// Headers a search row needs: enough to show it, match it to a stored message by
    /// Message-ID and reply to it.
    public static let rowHeaders = ["From", "To", "Cc", "Subject", "Date", "Message-ID", "In-Reply-To", "References", "Content-Type"]

    public let accountID: UUID
    public let limiter: GmailQuotaLimiter
    private let api: GoogleAPI
    private let base: URL
    /// How long a call may wait for the budget or a Retry-After before it gives up as rate-limited.
    private let maxWait: TimeInterval
    private let retries = 3
    /// Seconds without an answer before a call counts as timed out. It is retried once, so a
    /// search Gmail never answers falls back to this Mac within half a minute.
    private let timeout: TimeInterval = 15
    private let transport: GmailHTTPTransport?
    private let work: WorkClass

    public init(api: GoogleAPI, limiter: GmailQuotaLimiter = GmailQuotaLimiter(),
                base: URL = GmailAPIClient.defaultBase, maxWait: TimeInterval = 8) {
        self.accountID = api.accountID
        self.api = api
        self.limiter = limiter
        self.base = base
        self.maxWait = maxWait
        transport = nil
        work = .interactive
    }

    /// Calls go through `transport` as `work`: its budget, its byte meter and its retries.
    /// `limiter` is then not used.
    public init(transport: GmailHTTPTransport, work: WorkClass = .interactive) {
        accountID = transport.accountID
        api = transport.api
        limiter = GmailQuotaLimiter()
        base = transport.endpoints.base
        maxWait = transport.options.maxWait
        self.transport = transport
        self.work = work
    }

    public func profile() async throws -> GmailProfile {
        try await call(.profile, path: "profile")
    }

    public func labels() async throws -> [GmailLabel] {
        struct Reply: Decodable { var labels: [GmailLabel]? }
        let reply: Reply = try await call(.labelsList, path: "labels")
        return reply.labels ?? []
    }

    /// Message ids matching Gmail search syntax, newest first.
    public func list(query: String?, labelIDs: [String] = [], pageToken: String? = nil,
                     maxResults: Int = 100, includeSpamTrash: Bool = false) async throws -> GmailMessageList {
        var items: [URLQueryItem] = []
        if let query, !query.trimmed.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        items += labelIDs.map { URLQueryItem(name: "labelIds", value: $0) }
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        items.append(URLQueryItem(name: "maxResults", value: String(maxResults)))
        if includeSpamTrash { items.append(URLQueryItem(name: "includeSpamTrash", value: "true")) }
        return try await call(.messagesList, path: "messages", query: items)
    }

    public func metadata(id: String, headers: [String] = GmailAPIClient.rowHeaders) async throws -> GmailMessage {
        let items = [URLQueryItem(name: "format", value: "metadata")] + headers.map { URLQueryItem(name: "metadataHeaders", value: $0) }
        return try await call(.messagesGet, path: "messages/\(id.urlQueryEncoded)", query: items)
    }

    /// The message's structure with its text parts. Gmail leaves attachments out and gives each
    /// an attachment id instead, so a 20 MB message answers with only its text.
    public func full(id: String) async throws -> GmailMessage {
        try await call(.messagesGet, path: "messages/\(id.urlQueryEncoded)", query: [URLQueryItem(name: "format", value: "full")])
    }

    public func attachment(messageID: String, attachmentID: String) async throws -> Data {
        struct Reply: Decodable { var data: String?; var size: Int? }
        let reply: Reply = try await call(.attachmentsGet, path: "messages/\(messageID.urlQueryEncoded)/attachments/\(attachmentID.urlQueryEncoded)")
        guard let encoded = reply.data, let data = Data(base64URL: encoded) else {
            throw GoogleAPIError(kind: .other, detail: "attachment without data")
        }
        return data
    }

    private func call<T: Decodable>(_ method: GmailMethod, path: String, query: [URLQueryItem] = []) async throws -> T {
        let url = GoogleAPI.url(base.appendingPathComponent(path), queryItems: query)
        if let transport {
            let data = try await transport.perform(GmailHTTPTransport.Call(method, url: url, work: work)).data
            return try GmailWire.decode(T.self, from: data, method: method)
        }
        var refreshed = false
        var refreshNow = false
        var attempt = 0
        while true {
            let sentAt = try await limiter.acquire(method, maxWait: maxWait)
            let data: Data
            let http: HTTPURLResponse
            do {
                (data, http) = try await api.send("GET", url, timeout: timeout, refreshingToken: refreshNow)
                refreshNow = false
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                let parsed = GoogleErrorParser.parse(error)
                guard parsed.kind == .temporary, attempt < 1 else { throw parsed }
                attempt += 1
                continue
            } catch FalconError.http(let status, let body) {
                throw GoogleErrorParser.parse(status: status, body: Data(body.utf8))
            } catch FalconError.notAuthenticated {
                throw GoogleAPIError(kind: .needsSignIn, detail: "no token")
            } catch {
                throw GoogleAPIError(kind: .other, detail: String(describing: error))
            }
            if (200..<300).contains(http.statusCode) {
                do {
                    return try JSONDecoder().decode(T.self, from: data)
                } catch {
                    throw GoogleAPIError(kind: .other, httpStatus: http.statusCode, detail: "undecodable \(method.rawValue) reply")
                }
            }
            let refusal = GoogleErrorParser.parse(status: http.statusCode, body: data, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
            switch refusal.kind {
            case .needsSignIn where http.statusCode == 401 && !refreshed:
                refreshed = true
                refreshNow = true
                continue
            case .rateLimited:
                // The last refusal is recorded too, so the next call keeps to its Retry-After.
                await limiter.throttled(retryAfter: refusal.retryAfter ?? pow(2, Double(attempt)), sentAt: sentAt)
                guard attempt < retries else { throw refusal }
                attempt += 1
                continue
            case .temporary where attempt < retries:
                await limiter.backOff(pow(2, Double(attempt)) * 0.5)
                attempt += 1
                continue
            case .quotaExhausted, .apiDisabled:
                await limiter.hold(refusal)
                throw refusal
            default:
                throw refusal
            }
        }
    }
}

// MARK: - The Gmail engine's transport

/// Where the Gmail engine's requests go: Gmail's own addresses, or a fake's in tests.
public struct GmailEndpoints: Sendable, Equatable {
    /// `…/gmail/v1/users/me`, which every call's path follows.
    public var base: URL
    /// The same path under `/upload`, which takes whole messages.
    public var upload: URL
    /// The batch addresses to try, in order, until one answers. Google's batch guide gives
    /// `/batch/gmail/v1` and its discovery document `/batch`; G1's probe finds which answers, and
    /// until then the first that does is kept.
    public var batch: [URL]

    public init(base: URL = GmailAPIClient.defaultBase) {
        self.base = base
        var root = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        let path = root.path
        root.query = nil
        root.path = "/upload" + path
        upload = root.url ?? base
        var batch: [URL] = []
        for candidate in ["/batch/gmail/v1", "/batch"] {
            root.path = candidate
            if let url = root.url { batch.append(url) }
        }
        self.batch = batch
    }

    public static let google = GmailEndpoints()
}

public struct GmailTransportOptions: Sendable, Equatable {
    /// Seconds without an answer before a call counts as timed out.
    public var timeout: TimeInterval
    /// Uploads carry whole messages, so they may go quiet for longer.
    public var uploadTimeout: TimeInterval
    /// Tries in all for a call that may be tried again, as Google advises for reads.
    public var attempts: Int
    /// How long a check or a click may wait in the budget's queue before the transport gives up,
    /// so the engine can say it is waiting rather than hang. Bulk and background work waits for
    /// as long as it takes.
    public var maxWait: TimeInterval
    /// A pause Google asked for that runs longer than this is handed back at once, with its
    /// retry time, for the engine to wait out and report, rather than waited out here.
    public var maxPause: TimeInterval

    public init(timeout: TimeInterval = 30, uploadTimeout: TimeInterval = 120, attempts: Int = 5, maxWait: TimeInterval = 60,
                maxPause: TimeInterval = 60) {
        self.timeout = timeout
        self.uploadTimeout = uploadTimeout
        self.attempts = attempts
        self.maxWait = maxWait
        self.maxPause = maxPause
    }
}

/// Every Gmail API call the Gmail engine makes for one account, over HTTP.
///
/// Each request is admitted by the account's `GmailBudget` first, which books its units by class
/// of work and holds its place among the requests and batch parts in flight; its bytes are
/// counted when it is finished. Refusals are classified by `GoogleErrorParser` from the status,
/// the reason and the call. A read or a label change that may simply be tried again is, up to
/// `options.attempts` times; a send, an import or a new draft is never sent again once it may
/// have reached Gmail, since that could deliver it twice.
public final class GmailHTTPTransport: GmailTransport, @unchecked Sendable {
    public let accountID: UUID
    public let budget: GmailBudget
    public let endpoints: GmailEndpoints
    public let options: GmailTransportOptions
    let api: GoogleAPI
    private let lock = NSLock()
    private var batchAddress = 0

    public init(api: GoogleAPI, budget: GmailBudget, endpoints: GmailEndpoints = .google,
                options: GmailTransportOptions = GmailTransportOptions()) {
        accountID = api.accountID
        self.api = api
        self.budget = budget
        self.endpoints = endpoints
        self.options = options
    }

    /// The read helpers of `GmailAPIClient`, such as opening a message's text and then its
    /// pictures, booked through this transport as `work`.
    public func client(work: WorkClass = .interactive) -> GmailAPIClient {
        GmailAPIClient(transport: self, work: work)
    }

    /// The batch address in use: the first that has answered, or the first to try.
    public var batchURL: URL {
        lock.withLock { endpoints.batch[min(batchAddress, endpoints.batch.count - 1)] }
    }

    // MARK: The account

    public func profile(work: WorkClass) async throws -> GmailProfile {
        try await get(.profile, "profile", work: work)
    }

    public func labels(work: WorkClass) async throws -> [GmailLabel] {
        let reply: GmailLabelsReply = try await get(.labelsList, "labels", work: work)
        return reply.labels ?? []
    }

    public func label(_ id: GmailLabelID, work: WorkClass) async throws -> GmailLabel {
        try await get(.labelsGet, "labels/\(id.value.urlQueryEncoded)", work: work)
    }

    public func createLabel(named name: String, work: WorkClass) async throws -> GmailLabel {
        try await send(.labelsCreate, "POST", "labels", json: GmailWire.encode(GmailNewLabelBody(name: name)), work: work,
                       repeatable: false)
    }

    /// Deletes a label and takes it off every message. Only the probe deletes a label, and only
    /// the one it made.
    public func deleteLabel(_ id: GmailLabelID, work: WorkClass) async throws {
        _ = try await perform(Call(.labelsDelete, url: url("labels/\(id.value.urlQueryEncoded)"), work: work, httpMethod: "DELETE"))
    }

    public func sendAs(work: WorkClass) async throws -> [GmailSendAs] {
        let reply: GmailSendAsReply = try await get(.sendAsList, "settings/sendAs", work: work)
        return reply.sendAs ?? []
    }

    // MARK: Reading

    public func list(_ query: GmailListQuery, work: WorkClass) async throws -> GmailListPage {
        var items = query.labels.map { URLQueryItem(name: "labelIds", value: $0.value) }
        if let q = query.query, !q.trimmed.isEmpty { items.append(URLQueryItem(name: "q", value: q)) }
        if query.includeSpamTrash { items.append(URLQueryItem(name: "includeSpamTrash", value: "true")) }
        items.append(URLQueryItem(name: "maxResults", value: String(max(1, min(500, query.maxResults)))))
        if let token = query.pageToken { items.append(URLQueryItem(name: "pageToken", value: token)) }
        let reply: GmailMessageList = try await get(.messagesList, "messages", items, work: work)
        return GmailWire.listPage(reply)
    }

    public func history(since start: HistoryID, types: Set<GmailHistoryType>, label: GmailLabelID?,
                        pageToken: String?, work: WorkClass) async throws -> GmailHistoryPage {
        var items = [URLQueryItem(name: "startHistoryId", value: start.description)]
        items += types.map(\.rawValue).sorted().map { URLQueryItem(name: "historyTypes", value: $0) }
        if let label { items.append(URLQueryItem(name: "labelId", value: label.value)) }
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        items.append(URLQueryItem(name: "maxResults", value: "500"))
        let reply: GmailHistoryReply = try await get(.historyList, "history", items, work: work)
        return GmailWire.historyPage(reply, since: start)
    }

    public func message(_ id: GmailMessageID, format: GmailFormat, work: WorkClass) async throws -> GmailMessage {
        try await get(.messagesGet, "messages/\(id.hex)", GmailFormatQuery.items(format), work: work)
    }

    public func thread(_ id: GmailThreadID, format: GmailFormat, work: WorkClass) async throws -> GmailThread {
        try await get(.threadsGet, "threads/\(id.hex)", GmailFormatQuery.items(format), work: work)
    }

    public func attachment(_ attachmentID: String, of message: GmailMessageID, work: WorkClass) async throws -> Data {
        let reply: GmailAttachmentReply = try await get(.attachmentsGet, "messages/\(message.hex)/attachments/\(attachmentID.urlQueryEncoded)",
                                                        work: work)
        guard let encoded = reply.data, let data = Data(base64URL: encoded) else {
            throw GoogleAPIError(kind: .other, httpStatus: 200, reason: "undecodable", detail: "attachment without data")
        }
        return data
    }

    // MARK: Batches

    private enum PartOutcome {
        case answer(GmailBatchAnswer)
        case refused(GoogleAPIError, sentAt: Date)
    }

    public func batch(_ parts: [GmailBatchPart], work: WorkClass) async throws -> [GmailBatchPart: Result<GmailBatchAnswer, GoogleAPIError>] {
        var seen = Set<GmailBatchPart>()
        var pending = parts.filter { seen.insert($0).inserted }
        var results: [GmailBatchPart: Result<GmailBatchAnswer, GoogleAPIError>] = [:]
        var attempt = 0
        var refreshNext = false
        var refreshed = false
        while !pending.isEmpty {
            let limits = await budget.batchLimits(for: work)
            let batches = GmailBatchPlan.split(pending, work: work, maxParts: limits.parts, maxUnits: limits.units)
            let refresh = refreshNext
            refreshNext = false
            let answers = try await withThrowingTaskGroup(of: [GmailBatchPart: PartOutcome].self) { group in
                for batch in batches {
                    group.addTask { try await self.sendBatch(batch, work: work, refreshingToken: refresh) }
                }
                var all: [GmailBatchPart: PartOutcome] = [:]
                for try await answer in group { all.merge(answer) { first, _ in first } }
                return all
            }
            var again: [GmailBatchPart] = []
            var wait: TimeInterval = 0
            let now = budget.now()
            for part in pending {
                let outcome = answers[part]
                    ?? .refused(GoogleAPIError(kind: .temporary, httpStatus: 200, reason: "missingPart",
                                               detail: "the batch reply had no answer for a part", delivery: .unknown), sentAt: now)
                switch outcome {
                case .answer(let answer):
                    results[part] = .success(answer)
                case .refused(let refusal, let sentAt):
                    if refusal.kind == .needsSignIn, refusal.httpStatus == 401, !refreshed {
                        refreshNext = true
                        again.append(part)
                        continue
                    }
                    let retryAfter = await budget.note(refusal, sentAt: sentAt, attempt: attempt)
                    let repeatable = refusal.kind == .rateLimited || refusal.kind == .temporary
                    if repeatable, let retryAfter, attempt + 1 < options.attempts {
                        again.append(part)
                        // A plain rate refusal waits in the budget's pause; the others wait here.
                        if refusal.kind != .rateLimited || refusal.isConcurrencyLimit { wait = max(wait, retryAfter) }
                    } else {
                        results[part] = .failure(refusal)
                    }
                }
            }
            if refreshNext { refreshed = true }
            pending = again
            attempt += 1
            if !pending.isEmpty, wait > 0 { try await budget.sleep(wait) }
        }
        return results
    }

    /// One HTTP batch. The first batch address that answers is kept for every later batch.
    private func sendBatch(_ parts: [GmailBatchPart], work: WorkClass, refreshingToken: Bool) async throws -> [GmailBatchPart: PartOutcome] {
        let request = GmailBatchRequest(parts: parts, basePath: endpoints.base.path)
        var calls: [GmailMethod: Int] = [:]
        for part in parts { calls[part.method, default: 0] += 1 }
        let booking = GmailBooking(work: work, calls: calls, direction: .download)
        while true {
            let (address, index) = lock.withLock { (endpoints.batch[min(batchAddress, endpoints.batch.count - 1)], batchAddress) }
            var call = Call(parts[0].method, url: address, work: work, httpMethod: "POST", body: request.body,
                            contentType: request.contentType, booking: booking)
            call.refreshFirst = refreshingToken
            let reply: Reply
            do {
                reply = try await perform(call)
            } catch let refusal as GoogleAPIError where refusal.kind == .notFound && refusal.httpStatus == 404 {
                let moved = lock.withLock { () -> Bool in
                    guard batchAddress == index, index + 1 < endpoints.batch.count else { return batchAddress != index }
                    batchAddress = index + 1
                    return true
                }
                guard moved else { throw refusal }
                Log.info("gmail", "the batch address answered 404; using the next one")
                continue
            }
            let answers = try GmailBatchResponse.parse(reply.data, contentType: reply.response.value(forHTTPHeaderField: "Content-Type"))
            var out: [GmailBatchPart: PartOutcome] = [:]
            for (place, item) in request.parts.enumerated() {
                guard let answer = answers[item.contentID] ?? answers["#\(place)"] else { continue }
                if (200..<300).contains(answer.status) {
                    do {
                        out[item.part] = .answer(try GmailHTTPTransport.decode(item.part, answer.body))
                    } catch let refusal as GoogleAPIError {
                        out[item.part] = .refused(refusal, sentAt: reply.sentAt)
                    }
                } else {
                    let refusal = GoogleErrorParser.parse(status: answer.status, body: answer.body, retryAfter: answer.headers["retry-after"],
                                                          now: budget.now(), method: item.part.method)
                    out[item.part] = .refused(refusal, sentAt: reply.sentAt)
                }
            }
            return out
        }
    }

    private static func decode(_ part: GmailBatchPart, _ body: Data) throws -> GmailBatchAnswer {
        switch part {
        case .message: return .message(try GmailWire.decode(GmailMessage.self, from: body, method: .messagesGet))
        case .thread: return .thread(try GmailWire.decode(GmailThread.self, from: body, method: .threadsGet))
        case .label: return .label(try GmailWire.decode(GmailLabel.self, from: body, method: .labelsGet))
        }
    }

    // MARK: Changing

    public func modify(_ id: GmailMessageID, adding: Set<GmailLabelID>, removing: Set<GmailLabelID>,
                       work: WorkClass) async throws -> GmailMessage {
        let body = GmailModifyBody(addLabelIds: GmailWire.labelIDs(adding), removeLabelIds: GmailWire.labelIDs(removing))
        return try await send(.messagesModify, "POST", "messages/\(id.hex)/modify", json: GmailWire.encode(body), work: work)
    }

    public func batchModify(_ ids: [GmailMessageID], adding: Set<GmailLabelID>, removing: Set<GmailLabelID>,
                            work: WorkClass) async throws {
        guard !ids.isEmpty, !(adding.isEmpty && removing.isEmpty) else { return }
        try GmailHTTPTransport.checkBulk(ids)
        let body = GmailBatchModifyBody(ids: ids.map(\.hex), addLabelIds: GmailWire.labelIDs(adding),
                                        removeLabelIds: GmailWire.labelIDs(removing))
        _ = try await perform(Call(.messagesBatchModify, url: url("messages/batchModify"), work: work, httpMethod: "POST",
                                   body: GmailWire.encode(body), contentType: "application/json"))
    }

    public func batchDelete(_ ids: [GmailMessageID], work: WorkClass) async throws {
        guard !ids.isEmpty else { return }
        try GmailHTTPTransport.checkBulk(ids)
        _ = try await perform(Call(.messagesBatchDelete, url: url("messages/batchDelete"), work: work, httpMethod: "POST",
                                   body: GmailWire.encode(GmailIDsBody(ids: ids.map(\.hex))), contentType: "application/json"))
    }

    public func trash(_ id: GmailMessageID, work: WorkClass) async throws -> GmailMessage {
        try await send(.messagesTrash, "POST", "messages/\(id.hex)/trash", json: nil, work: work)
    }

    public func untrash(_ id: GmailMessageID, work: WorkClass) async throws -> GmailMessage {
        try await send(.messagesUntrash, "POST", "messages/\(id.hex)/untrash", json: nil, work: work)
    }

    /// Gmail takes at most 1,000 ids in one bulk call; more is refused here, before any cost.
    private static func checkBulk(_ ids: [GmailMessageID]) throws {
        guard ids.count <= 1_000 else {
            throw GoogleAPIError(kind: .other, reason: "tooManyIDs", detail: "\(ids.count) ids in one call; Gmail takes 1,000",
                                 delivery: .notSent)
        }
    }

    // MARK: Uploading

    public func send(_ raw: Data, threadID: GmailThreadID?, work: WorkClass) async throws -> GmailMessage {
        let metadata = GmailWire.encode(GmailUploadMetadata(threadId: threadID?.hex))
        return try await upload(.messagesSend, "POST", "messages/send", [], metadata: metadata, raw: raw, work: work, repeatable: false)
    }

    public func importMessage(_ raw: Data, labels: Set<GmailLabelID>, options: GmailImportOptions,
                              work: WorkClass) async throws -> GmailMessage {
        let query = [URLQueryItem(name: "internalDateSource", value: options.internalDateSource.rawValue),
                     URLQueryItem(name: "neverMarkSpam", value: String(options.neverMarkSpam)),
                     URLQueryItem(name: "processForCalendar", value: String(options.processForCalendar))]
        let metadata = GmailWire.encode(GmailUploadMetadata(labelIds: GmailWire.labelIDs(labels)))
        return try await upload(.messagesImport, "POST", "messages/import", query, metadata: metadata, raw: raw, work: work,
                                repeatable: false)
    }

    /// Files a message without Gmail's delivery scanning, as IMAP APPEND does. Only the probe uses
    /// it, for the one message its write part makes; imports use `messages.import`.
    public func insertMessage(_ raw: Data, labels: Set<GmailLabelID>, work: WorkClass) async throws -> GmailMessage {
        let metadata = GmailWire.encode(GmailUploadMetadata(labelIds: GmailWire.labelIDs(labels)))
        return try await upload(.messagesInsert, "POST", "messages", [URLQueryItem(name: "internalDateSource", value: "receivedTime")],
                                metadata: metadata, raw: raw, work: work, repeatable: false)
    }

    public func createDraft(_ raw: Data, threadID: GmailThreadID?, work: WorkClass) async throws -> GmailDraft {
        let metadata = GmailWire.encode(GmailDraftUploadMetadata(id: nil, message: .init(threadId: threadID?.hex)))
        return try await upload(.draftsCreate, "POST", "drafts", [], metadata: metadata, raw: raw, work: work, repeatable: false)
    }

    /// An update names the draft, so arriving twice leaves one draft: it may be tried again.
    public func updateDraft(_ draftID: String, raw: Data, threadID: GmailThreadID?, work: WorkClass) async throws -> GmailDraft {
        let metadata = GmailWire.encode(GmailDraftUploadMetadata(id: draftID, message: .init(threadId: threadID?.hex)))
        return try await upload(.draftsUpdate, "PUT", "drafts/\(draftID.urlQueryEncoded)", [], metadata: metadata, raw: raw,
                                work: work, repeatable: true)
    }

    public func deleteDraft(_ draftID: String, work: WorkClass) async throws {
        _ = try await perform(Call(.draftsDelete, url: url("drafts/\(draftID.urlQueryEncoded)"), work: work, httpMethod: "DELETE"))
    }

    public func drafts(pageToken: String?, work: WorkClass) async throws -> GmailDraftList {
        var items = [URLQueryItem(name: "maxResults", value: "500")]
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        return try await get(.draftsList, "drafts", items, work: work)
    }

    private func upload<T: Decodable>(_ method: GmailMethod, _ httpMethod: String, _ path: String, _ query: [URLQueryItem],
                                      metadata: Data, raw: Data, work: WorkClass, repeatable: Bool) async throws -> T {
        guard raw.count <= GmailUpload.maxBytes(for: method) else {
            throw GoogleAPIError(kind: .tooLarge, reason: "localLimit", detail: "\(raw.count) bytes to upload", delivery: .notSent)
        }
        let (body, contentType) = GmailUpload.body(metadata: metadata, message: raw)
        let url = GoogleAPI.url(endpoints.upload.appendingPathComponent(path),
                                queryItems: [URLQueryItem(name: "uploadType", value: "multipart")] + query)
        var call = Call(method, url: url, work: work, httpMethod: httpMethod, body: body, contentType: contentType,
                        booking: GmailBooking(method, work: work, uploadBytes: raw.count))
        call.repeatable = repeatable
        call.timeout = options.uploadTimeout
        return try GmailWire.decode(T.self, from: try await perform(call).data, method: method)
    }

    // MARK: The budget

    public func setFloodMode(_ on: Bool) async { await budget.setFloodMode(on) }
    public func noteOwnerActivity(at date: Date) async { await budget.noteOwnerActivity(at: date) }
    public func pause() async -> GmailPause? { await budget.pause() }
    public func usage() async -> GmailUsage { await budget.usage() }

    // MARK: Requests

    struct Call {
        var method: GmailMethod
        var url: URL
        var httpMethod: String
        var body: Data?
        var contentType: String?
        var booking: GmailBooking
        /// Whether a failure that may have come after Gmail acted can be tried again: true for
        /// reads and label changes, which come out the same however often they arrive; false
        /// for sends, imports, inserts and new drafts, which would arrive twice.
        var repeatable = true
        var timeout: TimeInterval?
        /// The token is refreshed before the first try, as after a batch part's 401.
        var refreshFirst = false

        init(_ method: GmailMethod, url: URL, work: WorkClass, httpMethod: String = "GET", body: Data? = nil,
             contentType: String? = nil, booking: GmailBooking? = nil) {
            self.method = method
            self.url = url
            self.httpMethod = httpMethod
            self.body = body
            self.contentType = contentType
            self.booking = booking ?? GmailBooking(method, work: work)
        }
    }

    struct Reply {
        var data: Data
        var response: HTTPURLResponse
        /// When the answered try was booked.
        var sentAt: Date
    }

    private func url(_ path: String, _ query: [URLQueryItem] = []) -> URL {
        GoogleAPI.url(endpoints.base.appendingPathComponent(path), queryItems: query)
    }

    private func get<T: Decodable>(_ method: GmailMethod, _ path: String, _ query: [URLQueryItem] = [], work: WorkClass) async throws -> T {
        try GmailWire.decode(T.self, from: try await perform(Call(method, url: url(path, query), work: work)).data, method: method)
    }

    private func send<T: Decodable>(_ method: GmailMethod, _ httpMethod: String, _ path: String, json: Data?, work: WorkClass,
                                    repeatable: Bool = true) async throws -> T {
        var call = Call(method, url: url(path), work: work, httpMethod: httpMethod, body: json,
                        contentType: json == nil ? nil : "application/json")
        call.repeatable = repeatable
        return try GmailWire.decode(T.self, from: try await perform(call).data, method: method)
    }

    private func maxWait(for work: WorkClass) -> TimeInterval {
        work.isDeferrable ? .infinity : options.maxWait
    }

    /// Sends one request through the budget, and tries it again while that can help: after a
    /// rate refusal once the budget's pause is over, after a concurrency refusal or a server
    /// error with Google's backoff, and once after a 401 with a fresh token.
    func perform(_ call: Call) async throws -> Reply {
        var attempt = 0
        var refreshed = call.refreshFirst
        var refreshNow = call.refreshFirst
        let up = call.body?.count ?? 0
        while true {
            let ticket = try await budget.admit(call.booking, maxWait: maxWait(for: call.booking.work), maxPause: options.maxPause)
            let answer: (Data, HTTPURLResponse)
            do {
                answer = try await api.send(call.httpMethod, call.url, body: call.body, contentType: call.contentType,
                                            timeout: call.timeout ?? options.timeout, refreshingToken: refreshNow)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    await budget.finish(ticket)
                    throw CancellationError()
                }
                let refusal = GmailHTTPTransport.refusal(for: error)
                // Bytes that may have gone count, so the upload budget errs on the safe side.
                await budget.finish(ticket, up: refusal.delivery == .unknown ? up : 0)
                guard refusal.kind == .temporary, call.repeatable, attempt + 1 < options.attempts else { throw refusal }
                let wait = await budget.note(refusal, sentAt: ticket.admittedAt, attempt: attempt) ?? budget.backoff(attempt)
                attempt += 1
                try await budget.sleep(wait)
                continue
            }
            refreshNow = false
            let (data, http) = answer
            await budget.finish(ticket, down: data.count, up: up)
            if (200..<300).contains(http.statusCode) { return Reply(data: data, response: http, sentAt: ticket.admittedAt) }
            let refusal = GoogleErrorParser.parse(status: http.statusCode, body: data, retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                                                  now: budget.now(), method: call.method)
            if refusal.kind == .needsSignIn, http.statusCode == 401, !refreshed {
                refreshed = true
                refreshNow = true
                continue
            }
            let wait = await budget.note(refusal, sentAt: ticket.admittedAt, attempt: attempt)
            let repeatable = refusal.kind == .rateLimited || (refusal.kind == .temporary && call.repeatable)
            guard repeatable, let wait, attempt + 1 < options.attempts else { throw refusal }
            attempt += 1
            // A plain rate refusal waits in the budget's pause, which every call shares.
            if refusal.kind != .rateLimited || refusal.isConcurrencyLimit { try await budget.sleep(wait) }
        }
    }

    /// What a failure that is not Gmail's answer means. None of these reached Gmail except a
    /// timeout or a dropped connection, which `GoogleErrorParser` marks as unknown.
    static func refusal(for error: Error) -> GoogleAPIError {
        switch error {
        case let refusal as GoogleAPIError:
            return refusal
        case let urlError as URLError:
            return GoogleErrorParser.parse(urlError)
        case FalconError.http(let status, let body):
            // The token could not be refreshed: Google's sign-in refused, and Gmail was never asked.
            var refusal = GoogleErrorParser.parse(status: status, body: Data(body.utf8))
            refusal.delivery = .notSent
            return refusal
        case FalconError.notAuthenticated:
            return GoogleAPIError(kind: .needsSignIn, detail: "no token", delivery: .notSent)
        default:
            return GoogleAPIError(kind: .other, detail: String(describing: type(of: error)), delivery: .notSent)
        }
    }
}
