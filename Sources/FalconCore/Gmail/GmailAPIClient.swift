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

    public func header(_ name: String) -> String? { payload?.header(name) }

    /// When Gmail received the message, which is what it orders search results by.
    public var receivedDate: Date? {
        internalDate.flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

/// Read-only calls to the Gmail API for one account. Every call books its units with the
/// account's `GmailQuotaLimiter` first and only ever throws `GoogleAPIError` or cancellation.
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

    public init(api: GoogleAPI, limiter: GmailQuotaLimiter = GmailQuotaLimiter(),
                base: URL = GmailAPIClient.defaultBase, maxWait: TimeInterval = 8) {
        self.accountID = api.accountID
        self.api = api
        self.limiter = limiter
        self.base = base
        self.maxWait = maxWait
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
