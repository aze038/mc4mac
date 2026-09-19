import Foundation

public struct OAuthToken: Codable, Sendable, Hashable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var scope: String
    public var tokenType: String

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, scope: String, tokenType: String = "Bearer") {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.tokenType = tokenType
    }

    public var isExpiringSoon: Bool { expiresAt.timeIntervalSinceNow < 120 }
}

public struct OAuthClientConfig: Codable, Sendable, Hashable {
    public var clientID: String
    public var clientSecret: String?

    public init(clientID: String, clientSecret: String?) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}
