import Foundation

public struct GoogleAPI: Sendable {
    public let tokens: TokenStore
    public let accountID: UUID
    private let session: URLSession

    public init(tokens: TokenStore, accountID: UUID, session: URLSession = .shared) {
        self.tokens = tokens
        self.accountID = accountID
        self.session = session
    }

    public func request(_ method: String, _ url: URL, body: Data? = nil, contentType: String? = nil,
                        headers: [String: String] = [:], accept: Set<Int> = [200, 201, 204, 206]) async throws -> (Data, HTTPURLResponse) {
        let token = try await tokens.validAccessToken(for: accountID)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw FalconError.network("no HTTP response") }
        guard accept.contains(http.statusCode) else { throw FalconError.http(http.statusCode, String(data.utf8Lossy.prefix(500))) }
        return (data, http)
    }

    public func json<T: Decodable>(_ type: T.Type, _ method: String, _ url: URL, body: Encodable? = nil, query: [String: String] = [:]) async throws -> T {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = (comps.queryItems ?? []) + query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        let bodyData = try body.map { try JSONEncoder().encode(AnyEncodable($0)) }
        let (data, _) = try await request(method, comps.url!, body: bodyData, contentType: bodyData == nil ? nil : "application/json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.fractional.date(from: s) ?? ISO8601DateFormatter.archive.date(from: s) { return date }
            if let date = ISO8601DateFormatter.dateOnly.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(in: try d.singleValueContainer(), debugDescription: "bad date \(s)")
        }
        return try decoder.decode(T.self, from: data)
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
