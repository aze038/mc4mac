import Foundation

/// Where Google API calls get their bearer token. `TokenStore` is the one the app uses; tests
/// supply their own so nothing reads the keychain.
public protocol GoogleAccessTokenSource: Sendable {
    func accessToken(for accountID: UUID) async throws -> String
    /// A token refreshed even though the current one has not expired, for when Google has just
    /// refused it with a 401.
    func refreshedAccessToken(for accountID: UUID) async throws -> String
}

extension TokenStore: GoogleAccessTokenSource {
    public func accessToken(for accountID: UUID) async throws -> String {
        try await validAccessToken(for: accountID)
    }

    /// Refreshed as the sync engine refreshes a token IMAP turned down: by the client that
    /// issued it, once however many ask at the same moment, and with nothing written to the
    /// keychain but the fresh token, so a sign-in saved meanwhile is kept.
    public func refreshedAccessToken(for accountID: UUID) async throws -> String {
        try await validAccessToken(for: accountID, forceRefresh: true)
    }
}

public struct GoogleAPI: Sendable {
    public let accountID: UUID
    private let tokens: any GoogleAccessTokenSource
    private let session: URLSession

    /// Keeps HTTP/2 connection reuse but writes no response cache, cookie or credential to disk,
    /// so nothing fetched from Google lands in `~/Library/Caches`.
    public static func ephemeralConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return configuration
    }

    public static let ephemeralSession = URLSession(configuration: ephemeralConfiguration())

    public init(tokens: TokenStore, accountID: UUID, session: URLSession = GoogleAPI.ephemeralSession) {
        self.init(tokenSource: tokens, accountID: accountID, session: session)
    }

    public init(tokenSource: any GoogleAccessTokenSource, accountID: UUID, session: URLSession = GoogleAPI.ephemeralSession) {
        self.tokens = tokenSource
        self.accountID = accountID
        self.session = session
    }

    /// The server's answer whatever its status, so a caller can read a refusal's reason and
    /// Retry-After instead of the truncated text `request` throws.
    public func send(_ method: String, _ url: URL, body: Data? = nil, contentType: String? = nil,
                     headers: [String: String] = [:], timeout: TimeInterval? = nil,
                     refreshingToken: Bool = false) async throws -> (Data, HTTPURLResponse) {
        let token = refreshingToken ? try await tokens.refreshedAccessToken(for: accountID) : try await tokens.accessToken(for: accountID)
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let timeout { req.timeoutInterval = timeout }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw FalconError.network("no HTTP response") }
        return (data, http)
    }

    public func request(_ method: String, _ url: URL, body: Data? = nil, contentType: String? = nil,
                        headers: [String: String] = [:], accept: Set<Int> = [200, 201, 204, 206]) async throws -> (Data, HTTPURLResponse) {
        let (data, http) = try await send(method, url, body: body, contentType: contentType, headers: headers)
        guard accept.contains(http.statusCode) else { throw FalconError.http(http.statusCode, String(data.utf8Lossy.prefix(500))) }
        return (data, http)
    }

    public func json<T: Decodable>(_ type: T.Type, _ method: String, _ url: URL, body: Encodable? = nil, query: [String: String] = [:]) async throws -> T {
        try await json(type, method, url, body: body, queryItems: query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) })
    }

    public func json<T: Decodable>(_ type: T.Type, _ method: String, _ url: URL, body: Encodable? = nil, queryItems: [URLQueryItem]) async throws -> T {
        let bodyData = try body.map { try JSONEncoder().encode(AnyEncodable($0)) }
        let (data, _) = try await request(method, GoogleAPI.url(url, queryItems: queryItems), body: bodyData,
                                          contentType: bodyData == nil ? nil : "application/json")
        return try GoogleAPI.makeDecoder().decode(T.self, from: data)
    }

    /// Appends query items with every reserved character percent-encoded. `URLComponents.queryItems`
    /// leaves "+" alone, which Google reads as a space, so `from:a+b@x.com` would search for
    /// `from:a b@x.com`.
    public static func url(_ url: URL, queryItems: [URLQueryItem]) -> URL {
        guard !queryItems.isEmpty, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let encoded = queryItems.map { URLQueryItem(name: $0.name.urlQueryEncoded, value: $0.value?.urlQueryEncoded) }
        comps.percentEncodedQueryItems = (comps.percentEncodedQueryItems ?? []) + encoded
        return comps.url ?? url
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.fractional.date(from: s) ?? ISO8601DateFormatter.archive.date(from: s) { return date }
            if let date = ISO8601DateFormatter.dateOnly.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(in: try d.singleValueContainer(), debugDescription: "bad date \(s)")
        }
        return decoder
    }
}

struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

extension ISO8601DateFormatter {
    static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let dateOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()
}
