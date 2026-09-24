import XCTest
@testable import FalconCore

/// A token is refreshed by the client that issued it, once however many ask, and ahead of its
/// expiry, so that nothing the owner does waits for Google. Nothing here reads the keychain or
/// reaches Google: tokens stay in memory and refreshes are answered in the test.
final class TokenRefreshTests: XCTestCase {
    private let account = UUID()
    private let current = OAuthClientConfig(clientID: "current.apps.googleusercontent.com", clientSecret: "current-secret")
    private let earlier = OAuthClientConfig(clientID: "earlier.apps.googleusercontent.com", clientSecret: "earlier-secret")

    private final class Vault: @unchecked Sendable {
        private let lock = NSLock()
        private var tokens: [UUID: OAuthToken] = [:]

        init(_ tokens: [UUID: OAuthToken]) { self.tokens = tokens }

        var vault: TokenVault {
            TokenVault(load: { [self] id in lock.withLock { tokens[id] } },
                       save: { [self] token, id in lock.withLock { tokens[id] = token } },
                       forget: { [self] id in lock.withLock { tokens[id] = nil } })
        }

        func token(_ id: UUID) -> OAuthToken? { lock.withLock { tokens[id] } }
    }

    private func store(_ token: OAuthToken, known: [OAuthClientConfig], vault: Vault? = nil, refreshes: Recorder<String>,
                       delay: TimeInterval = 0, refusal: Error? = nil) -> (TokenStore, Vault) {
        let held = vault ?? Vault([account: token])
        let current = current
        let tokens = TokenStore(keychain: KeychainStore(service: "com.falconmail.tests.unused"), vault: held.vault,
                                clientConfigProvider: { current }, knownClientConfigs: { known }) { old, client in
            refreshes.append(client.clientID)
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            if let refusal { throw refusal }
            return OAuthToken(accessToken: "fresh-\(refreshes.all.count)", refreshToken: old.refreshToken,
                              expiresAt: Date().addingTimeInterval(3600), scope: old.scope, clientID: client.clientID)
        }
        return (tokens, held)
    }

    private func expiring(clientID: String?, in seconds: TimeInterval = 30) -> OAuthToken {
        OAuthToken(accessToken: "stale", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(seconds), scope: GoogleScopes.mail,
                   clientID: clientID)
    }

    func testATokenIsRefreshedByTheClientThatIssuedIt() async throws {
        let refreshes = Recorder<String>()
        let (tokens, vault) = store(expiring(clientID: earlier.clientID), known: [current, earlier], refreshes: refreshes)
        let access = try await tokens.validAccessToken(for: account)
        XCTAssertEqual(access, "fresh-1")
        XCTAssertEqual(refreshes.all, [earlier.clientID], "not the client sign-in uses now, which Google would refuse")
        XCTAssertEqual(vault.token(account)?.clientID, earlier.clientID)
    }

    func testATokenFromAClientThisBuildLacksAsksForSignInWithoutTrying() async throws {
        let refreshes = Recorder<String>()
        let (tokens, _) = store(expiring(clientID: "gone.apps.googleusercontent.com"), known: [current], refreshes: refreshes)
        for _ in 1...3 {
            do {
                _ = try await tokens.validAccessToken(for: account)
                XCTFail("the client that issued it is gone")
            } catch {
                XCTAssertEqual(MailServiceError.classify(error, email: "owner@example.com", isGoogle: true).kind, .needsSignIn)
            }
        }
        XCTAssertTrue(refreshes.all.isEmpty, "a refresh that cannot work is never sent")
    }

    func testATokenKeptByAnEarlierBuildIsRefreshedByTheCurrentClientAndRemembersIt() async throws {
        let refreshes = Recorder<String>()
        let (tokens, vault) = store(expiring(clientID: nil), known: [current], refreshes: refreshes)
        _ = try await tokens.validAccessToken(for: account)
        XCTAssertEqual(refreshes.all, [current.clientID])
        XCTAssertEqual(vault.token(account)?.clientID, current.clientID)
    }

    func testEveryoneAskingAtOnceSharesOneRefresh() async throws {
        let refreshes = Recorder<String>()
        let (tokens, _) = store(expiring(clientID: current.clientID), known: [current], refreshes: refreshes, delay: 0.2)
        let account = account
        let got = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 1...6 { group.addTask { try await tokens.validAccessToken(for: account) } }
            var out: [String] = []
            for try await token in group { out.append(token) }
            return out
        }
        XCTAssertEqual(refreshes.all.count, 1)
        XCTAssertEqual(Set(got), ["fresh-1"])
        let forced = try await tokens.validAccessToken(for: account, forceRefresh: true)
        XCTAssertEqual(forced, "fresh-2", "a forced refresh after the server turned a token down is a new one")
    }

    func testATokenIsRefreshedAheadOfItsExpiry() async throws {
        let refreshes = Recorder<String>()
        let soon = expiring(clientID: current.clientID, in: TokenStore.refreshLead + 0.3)
        let (tokens, vault) = store(soon, known: [current], refreshes: refreshes)
        await tokens.keepFresh(account)
        let account = account
        await assertEventually(within: 3) { vault.token(account)?.accessToken == "fresh-1" }
        let access = try await tokens.validAccessToken(for: account)
        XCTAssertEqual(access, "fresh-1", "nothing waits: the token was already fresh")
        XCTAssertEqual(refreshes.all.count, 1)
        await tokens.stopKeepingFresh(account)
    }

    func testASignInSavedDuringARefreshIsKept() async throws {
        let refreshes = Recorder<String>()
        let (tokens, vault) = store(expiring(clientID: current.clientID), known: [current], refreshes: refreshes, delay: 0.3)
        let account = account
        let asking = Task { try await tokens.validAccessToken(for: account) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let signIn = OAuthToken(accessToken: "signed-in", refreshToken: "new-refresh", expiresAt: Date().addingTimeInterval(3600),
                                scope: GoogleScopes.mail, clientID: current.clientID)
        try await tokens.save(signIn, for: account)
        let access = try await asking.value
        XCTAssertEqual(access, "signed-in", "a refresh of the grant it replaced is not handed out")
        XCTAssertEqual(vault.token(account)?.refreshToken, "new-refresh", "nor saved over it")
        XCTAssertEqual(vault.token(account)?.accessToken, "signed-in")
        XCTAssertEqual(refreshes.all.count, 1)
    }

    func testAnAccountRemovedDuringARefreshKeepsNoToken() async throws {
        let refreshes = Recorder<String>()
        let (tokens, vault) = store(expiring(clientID: current.clientID), known: [current], refreshes: refreshes, delay: 0.3)
        let account = account
        let asking = Task { try await tokens.validAccessToken(for: account) }
        try await Task.sleep(nanoseconds: 50_000_000)
        await tokens.remove(accountID: account)
        do {
            _ = try await asking.value
            XCTFail("the account is gone")
        } catch {
            XCTAssertEqual(MailServiceError.classify(error, email: "owner@example.com", isGoogle: true).kind, .needsSignIn)
        }
        XCTAssertNil(vault.token(account), "the refresh did not write the token back")
    }

    func testEveryoneWaitingOnARefusedRefreshIsAskedToSignIn() async throws {
        let refreshes = Recorder<String>()
        let (tokens, _) = store(expiring(clientID: current.clientID), known: [current], refreshes: refreshes, delay: 0.2,
                                refusal: FalconError.http(400, #"{"error": "invalid_grant"}"#))
        let account = account
        let kinds = await withTaskGroup(of: MailServiceError.Kind.self) { group in
            for _ in 1...4 {
                group.addTask {
                    do {
                        _ = try await tokens.validAccessToken(for: account)
                        return .local
                    } catch {
                        return MailServiceError.classify(error, email: "owner@example.com", isGoogle: true).kind
                    }
                }
            }
            var out: [MailServiceError.Kind] = []
            for await kind in group { out.append(kind) }
            return out
        }
        XCTAssertEqual(refreshes.all.count, 1)
        XCTAssertEqual(kinds, Array(repeating: .needsSignIn, count: 4), "those who joined the refresh hear the same as the one who began it")
    }

    // MARK: Stored tokens

    /// What the previous release reads of a token in the keychain.
    private struct EarlierToken: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date
        var scope: String
        var tokenType: String
    }

    func testTheEarlierReleaseReadsATokenWithItsClientAndThisBuildReadsOneWithout() throws {
        let token = OAuthToken(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 1_790_000_000), scope: "s",
                               clientID: current.clientID)
        let earlier = try JSONDecoder().decode(EarlierToken.self, from: JSONEncoder().encode(token))
        XCTAssertEqual(earlier.refreshToken, "r")
        XCTAssertEqual(earlier.expiresAt, token.expiresAt)

        let kept = try JSONEncoder().encode(EarlierToken(accessToken: "a", refreshToken: "r", expiresAt: token.expiresAt, scope: "s",
                                                         tokenType: "Bearer"))
        let read = try JSONDecoder().decode(OAuthToken.self, from: kept)
        XCTAssertNil(read.clientID)
        XCTAssertEqual(read.refreshToken, "r")
    }

    func testARefreshRecordsTheClientThatMadeIt() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TokenEndpoint.self]
        let oauth = GoogleOAuth(config: current, session: URLSession(configuration: config))
        let fresh = try await oauth.refresh(expiring(clientID: nil))
        XCTAssertEqual(fresh.clientID, current.clientID)
        XCTAssertEqual(fresh.refreshToken, "refresh", "Google sends no new refresh token; the old one is kept")
        XCTAssertEqual(fresh.accessToken, "from-the-endpoint")
    }
}

/// Answers the token endpoint in-process, so no request leaves the Mac.
private final class TokenEndpoint: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Data(#"{"access_token":"from-the-endpoint","expires_in":3599,"scope":"https://mail.google.com/","token_type":"Bearer"}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
