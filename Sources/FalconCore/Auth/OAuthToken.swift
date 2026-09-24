import Foundation

public struct OAuthToken: Codable, Sendable, Hashable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var scope: String
    public var tokenType: String
    /// The OAuth client the token was issued to, the only one Google lets refresh it. Nil for
    /// a token kept by an earlier build, which the previous release reads unchanged.
    public var clientID: String?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, scope: String, tokenType: String = "Bearer",
                clientID: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.tokenType = tokenType
        self.clientID = clientID
    }
}

public struct OAuthClientConfig: Codable, Sendable, Hashable {
    public var clientID: String
    public var clientSecret: String?

    public init(clientID: String, clientSecret: String?) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    public var reversedClientScheme: String? {
        let suffix = ".apps.googleusercontent.com"
        guard clientID.hasSuffix(suffix) else { return nil }
        return "com.googleusercontent.apps." + String(clientID.dropLast(suffix.count))
    }

    public var hasSecret: Bool { !(clientSecret ?? "").isEmpty }
}
