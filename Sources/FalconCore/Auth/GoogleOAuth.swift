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
                          expiresAt: Date().addingTimeInterval(r.expires_in), scope: r.scope ?? "", tokenType: r.token_type ?? "Bearer",
                          clientID: config.clientID)
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

/// Where the account tokens are kept: the keychain, or memory in the tests.
struct TokenVault: Sendable {
    var load: @Sendable (UUID) throws -> OAuthToken?
    var save: @Sendable (OAuthToken, UUID) throws -> Void
    /// Removes the account's token and its password, if it had one.
    var forget: @Sendable (UUID) -> Void

    static func keychain(_ keychain: KeychainStore) -> TokenVault {
        TokenVault(load: { try keychain.loadCodable(OAuthToken.self, account: "oauth.\($0.uuidString)") },
                   save: { try keychain.saveCodable($0, account: "oauth.\($1.uuidString)") },
                   forget: { id in
                       keychain.delete(account: "oauth.\(id.uuidString)")
                       keychain.delete(account: "password.\(id.uuidString)")
                   })
    }
}

public actor TokenStore {
    private let keychain: KeychainStore
    private let vault: TokenVault
    private var cache: [UUID: OAuthToken] = [:]
    private let clientConfigProvider: @Sendable () -> OAuthClientConfig?
    private let knownClientConfigs: @Sendable () -> [OAuthClientConfig]
    private let refresher: @Sendable (OAuthToken, OAuthClientConfig) async throws -> OAuthToken
    private let now: @Sendable () -> Date
    /// The refresh under way for each account, which every caller who needs one waits for.
    private var refreshing: [UUID: Task<OAuthToken, Error>] = [:]
    private var keepers: [UUID: Task<Void, Never>] = [:]
    /// Accounts whose token was issued to a client this build does not have, already logged.
    private var clientMissing: Set<UUID> = []
    /// A token is refreshed this long before it expires, so that nothing the owner does waits.
    static let refreshLead: TimeInterval = 5 * 60

    /// `knownClientConfigs` lists every OAuth client this build can use: a token is refreshed
    /// by the client that issued it, which need not be the one sign-in uses now.
    public init(keychain: KeychainStore = KeychainStore(), clientConfigProvider: @escaping @Sendable () -> OAuthClientConfig?,
                knownClientConfigs: @escaping @Sendable () -> [OAuthClientConfig] = { [] }) {
        self.init(keychain: keychain, vault: .keychain(keychain), clientConfigProvider: clientConfigProvider,
                  knownClientConfigs: knownClientConfigs, refresher: { token, config in try await GoogleOAuth(config: config).refresh(token) })
    }

    /// Tests keep tokens in memory and refresh them without Google.
    init(keychain: KeychainStore, vault: TokenVault, clientConfigProvider: @escaping @Sendable () -> OAuthClientConfig?,
         knownClientConfigs: @escaping @Sendable () -> [OAuthClientConfig],
         refresher: @escaping @Sendable (OAuthToken, OAuthClientConfig) async throws -> OAuthToken,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.keychain = keychain
        self.vault = vault
        self.clientConfigProvider = clientConfigProvider
        self.knownClientConfigs = knownClientConfigs
        self.refresher = refresher
        self.now = now
    }

    public func save(_ token: OAuthToken, for accountID: UUID) throws {
        cache[accountID] = token
        try vault.save(token, accountID)
    }

    public func token(for accountID: UUID) throws -> OAuthToken? {
        if let t = cache[accountID] { return t }
        let t = try vault.load(accountID)
        cache[accountID] = t
        return t
    }

    public func remove(accountID: UUID) {
        stopKeepingFresh(accountID)
        cache[accountID] = nil
        vault.forget(accountID)
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
        guard let token = try token(for: accountID) else { throw FalconError.notAuthenticated }
        guard forceRefresh || token.expiresAt.timeIntervalSince(now()) < 120 else { return token.accessToken }
        return try await refreshed(accountID).accessToken
    }

    /// A fresh token for the account. However many ask at once, one refresh is made and all
    /// of them get its result, a refusal included.
    private func refreshed(_ accountID: UUID) async throws -> OAuthToken {
        if let running = refreshing[accountID] { return try await running.value }
        guard let token = try token(for: accountID) else { throw FalconError.notAuthenticated }
        let client = try issuer(of: token, accountID: accountID)
        let refresher = refresher
        let running = Task { () throws -> OAuthToken in
            let fresh: OAuthToken
            do {
                fresh = try await refresher(token, client)
            } catch FalconError.http(let status, let text) where status == 400 || status == 401 {
                Log.warning("OAuth", "Google refused to renew the sign-in (HTTP \(status)): \(text)", error: FalconError.notAuthenticated)
                throw FalconError.notAuthenticated
            }
            return try self.keep(fresh, refreshing: token, for: accountID)
        }
        refreshing[accountID] = running
        defer { refreshing[accountID] = nil }
        return try await running.value
    }

    /// Saves a refreshed token, unless the account's sign-in changed while it was refreshed:
    /// a new sign-in is kept rather than overwritten by a refresh of the grant it replaced, and
    /// an account removed meanwhile gets nothing back.
    private func keep(_ fresh: OAuthToken, refreshing old: OAuthToken, for accountID: UUID) throws -> OAuthToken {
        guard let stored = try token(for: accountID) else { throw FalconError.notAuthenticated }
        guard stored.refreshToken == old.refreshToken, stored.clientID == old.clientID else { return stored }
        try save(fresh, for: accountID)
        return fresh
    }

    /// The client to refresh `token` with: the one that issued it. Google refuses a refresh
    /// token from any other as unauthorized_client, so a token from a client this build no
    /// longer has means signing in again, said once, never a refresh that cannot work.
    private func issuer(of token: OAuthToken, accountID: UUID) throws -> OAuthClientConfig {
        guard let current = clientConfigProvider() else { throw FalconError.notAuthenticated }
        guard let issuer = token.clientID, issuer != current.clientID else { return current }
        if let known = knownClientConfigs().first(where: { $0.clientID == issuer }) { return known }
        if clientMissing.insert(accountID).inserted {
            Log.warning("OAuth", "account \(accountID.uuidString): its sign-in came from an OAuth client this build does not have; it must sign in again",
                        code: "unknownClient", logAs: "auth")
        }
        throw FalconError.notAuthenticated
    }

    /// Refreshes the account's token about five minutes before it expires, from now until
    /// `stopKeepingFresh`, so that no message opened or sent waits for Google.
    public func keepFresh(_ accountID: UUID) {
        keepers[accountID]?.cancel()
        keepers[accountID] = Task { [weak self] in await self?.refreshAhead(accountID) }
    }

    public func stopKeepingFresh(_ accountID: UUID) {
        keepers.removeValue(forKey: accountID)?.cancel()
    }

    private func refreshAhead(_ accountID: UUID) async {
        while !Task.isCancelled {
            guard let token = try? token(for: accountID), token.refreshToken != nil else { return }
            let wait = token.expiresAt.timeIntervalSince(now()) - TokenStore.refreshLead
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                continue
            }
            do {
                _ = try await refreshed(accountID)
            } catch FalconError.notAuthenticated {
                // The owner has to sign in again; the sync loop says so.
                return
            } catch {
                // Offline or Google busy: the next request refreshes on its own, or this tries again.
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
    }
}
