import Foundation
import Network

public actor LoopbackRedirectServer {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<[String: String], Error>?
    public private(set) var port: UInt16 = 0

    public init() {}

    public var redirectURI: String { "http://127.0.0.1:\(port)/oauth2callback" }

    public func start() async throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let l = try NWListener(using: params, on: .any)
        listener = l
        let box = ResumeOnce()
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: .global())
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let request = data?.utf8Lossy ?? ""
                let params = LoopbackRedirectServer.parseQuery(request)
                let body = params["code"] != nil
                    ? "<html><body style='font-family:-apple-system;padding:40px'><h2>FalconMail is signed in.</h2><p>You can close this window.</p></body></html>"
                    : "<html><body style='font-family:-apple-system;padding:40px'><h2>Sign-in did not complete.</h2><p>Return to FalconMail and try again.</p></body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    conn.cancel()
                    Task { await self.deliver(params) }
                })
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: box.run { cont.resume() }
                case .failed(let err): box.run { cont.resume(throwing: FalconError.network(err.localizedDescription)) }
                case .cancelled: box.run { cont.resume(throwing: FalconError.cancelled) }
                default: break
                }
            }
            l.start(queue: .global())
        }
        guard let p = l.port?.rawValue, p != 0 else { throw FalconError.network("could not open loopback port") }
        port = p
    }

    public func waitForCallback() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            continuation = cont
        }
    }

    private func deliver(_ params: [String: String]) {
        continuation?.resume(returning: params)
        continuation = nil
        listener?.cancel()
        listener = nil
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        continuation?.resume(throwing: FalconError.cancelled)
        continuation = nil
    }

    static func parseQuery(_ request: String) -> [String: String] {
        guard let firstLine = request.split(separator: "\r\n").first ?? request.split(separator: "\n").first else { return [:] }
        let pieces = firstLine.split(separator: " ")
        guard pieces.count >= 2 else { return [:] }
        let path = String(pieces[1])
        guard let q = path.firstIndex(of: "?") else { return [:] }
        var out: [String: String] = [:]
        for pair in path[path.index(after: q)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            out[kv[0]] = kv[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? kv[1]
        }
        return out
    }
}

public struct GoogleSignInFlow: Sendable {
    public let oauth: GoogleOAuth

    public init(config: OAuthClientConfig) {
        self.oauth = GoogleOAuth(config: config)
    }

    public func run(openURL: @Sendable (URL) -> Void, loginHint: String? = nil) async throws -> (token: OAuthToken, email: String, name: String) {
        let server = LoopbackRedirectServer()
        try await server.start()
        let redirect = await server.redirectURI
        let pkce = PKCEPair.generate()
        let state = Data.random(count: 16).base64URL
        let url = oauth.authorizationURL(redirectURI: redirect, state: state, pkce: pkce, loginHint: loginHint)
        openURL(url)
        let params = try await server.waitForCallback()
        guard params["state"] == state, let code = params["code"] else {
            throw FalconError.invalidInput(params["error"] ?? "Sign-in was cancelled.")
        }
        let token = try await oauth.exchange(code: code, redirectURI: redirect, pkce: pkce)
        let who = try await oauth.userEmail(accessToken: token.accessToken)
        return (token, who.email, who.name)
    }
}
