import Foundation
import CryptoKit

public struct GoogleScopes {
    public static let mail = "https://mail.google.com/"
    public static let driveFile = "https://www.googleapis.com/auth/drive.file"
    public static let calendar = "https://www.googleapis.com/auth/calendar"
    public static let contacts = "https://www.googleapis.com/auth/contacts.readonly"
    public static let otherContacts = "https://www.googleapis.com/auth/contacts.other.readonly"
    public static let email = "https://www.googleapis.com/auth/userinfo.email"
    public static let gmailInsert = "https://www.googleapis.com/auth/gmail.insert"
    public static let gmailLabels = "https://www.googleapis.com/auth/gmail.labels"
    public static let all = [mail, driveFile, calendar, contacts, otherContacts, email, gmailInsert, gmailLabels]
}

public struct PKCEPair: Sendable {
    public let verifier: String
    public let challenge: String

    public static func generate() -> PKCEPair {
        let verifier = Data.random(count: 48).base64URL
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return PKCEPair(verifier: verifier, challenge: Data(digest).base64URL)
    }
}

public struct GoogleOAuth: Sendable {
    public let config: OAuthClientConfig
    private let session: URLSession

    public init(config: OAuthClientConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func authorizationURL(redirectURI: String, state: String, pkce: PKCEPair, scopes: [String] = GoogleScopes.all, loginHint: String? = nil) -> URL {
        var items: [String: String] = [
            "client_id": config.clientID,
            "redirect_uri": redirectURI,
            "response_type": "code",
            "scope": scopes.joined(separator: " "),
            "state": state,
            "code_challenge": pkce.challenge,
            "code_challenge_method": "S256",
            "access_type": "offline",
            "prompt": "consent"
        ]
        if let loginHint { items["login_hint"] = loginHint }
        let query = items.map { "\($0.key)=\($0.value.urlQueryEncoded)" }.joined(separator: "&")
        return URL(string: "https://accounts.google.com/o/oauth2/v2/auth?\(query)")!
    }

    public func exchange(code: String, redirectURI: String, pkce: PKCEPair) async throws -> OAuthToken {
        var form: [String: String] = [
            "client_id": config.clientID,
            "code": code,
            "code_verifier": pkce.verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ]
        if let secret = config.clientSecret, !secret.isEmpty { form["client_secret"] = secret }
        return try await tokenRequest(form, existingRefresh: nil)
    }

    public func refresh(_ token: OAuthToken) async throws -> OAuthToken {
        guard let refreshToken = token.refreshToken else { throw FalconError.notAuthenticated }
        var form: [String: String] = [
            "client_id": config.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        if let secret = config.clientSecret, !secret.isEmpty { form["client_secret"] = secret }
        return try await tokenRequest(form, existingRefresh: refreshToken)
    }

    private func tokenRequest(_ form: [String: String], existingRefresh: String?) async throws -> OAuthToken {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.formURLEncoded
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw FalconError.http(status, data.utf8Lossy) }
        struct Reply: Decodable {
            var access_token: String
            var refresh_token: String?
            var expires_in: Double
            var scope: String?
            var token_type: String?
        }
        let r = try JSONDecoder().decode(Reply.self, from: data)
        return OAuthToken(accessToken: r.access_token, refreshToken: r.refresh_token ?? existingRefresh,
                          expiresAt: Date().addingTimeInterval(r.expires_in), scope: r.scope ?? "", tokenType: r.token_type ?? "Bearer")
    }

    public func userEmail(accessToken: String) async throws -> (email: String, name: String) {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw FalconError.http(status, data.utf8Lossy) }
        struct Info: Decodable { var email: String; var name: String? }
        let info = try JSONDecoder().decode(Info.self, from: data)
        return (info.email, info.name ?? info.email)
    }
}

public actor TokenStore {
    private let keychain: KeychainStore
    private var cache: [UUID: OAuthToken] = [:]
    private var oauthByAccount: [UUID: GoogleOAuth] = [:]
    private let clientConfigProvider: @Sendable () -> OAuthClientConfig?

    public init(keychain: KeychainStore = KeychainStore(), clientConfigProvider: @escaping @Sendable () -> OAuthClientConfig?) {
        self.keychain = keychain
        self.clientConfigProvider = clientConfigProvider
    }

    public func save(_ token: OAuthToken, for accountID: UUID) throws {
        cache[accountID] = token
        try keychain.saveCodable(token, account: "oauth.\(accountID.uuidString)")
    }

    public func token(for accountID: UUID) throws -> OAuthToken? {
        if let t = cache[accountID] { return t }
        let t = try keychain.loadCodable(OAuthToken.self, account: "oauth.\(accountID.uuidString)")
        cache[accountID] = t
        return t
    }

    public func remove(accountID: UUID) {
        cache[accountID] = nil
        keychain.delete(account: "oauth.\(accountID.uuidString)")
        keychain.delete(account: "password.\(accountID.uuidString)")
    }

    public func savePassword(_ password: String, for accountID: UUID) throws {
        try keychain.save(Data(password.utf8), account: "password.\(accountID.uuidString)")
    }

    public func password(for accountID: UUID) throws -> String {
        guard let data = try keychain.load(account: "password.\(accountID.uuidString)") else { throw FalconError.notAuthenticated }
        return String(decoding: data, as: UTF8.self)
    }

    /// The account's access token, refreshed first when it is about to expire, or always when
    /// `forceRefresh`, as after the server turned down one that had not expired.
    public func validAccessToken(for accountID: UUID, forceRefresh: Bool = false) async throws -> String {
        guard var token = try token(for: accountID) else { throw FalconError.notAuthenticated }
        if forceRefresh || token.isExpiringSoon {
            guard let config = clientConfigProvider() else { throw FalconError.notAuthenticated }
            do {
                token = try await GoogleOAuth(config: config).refresh(token)
            } catch FalconError.http(let status, _) where status == 400 || status == 401 {
                throw FalconError.notAuthenticated
            }
            try save(token, for: accountID)
        }
        return token.accessToken
    }
}
