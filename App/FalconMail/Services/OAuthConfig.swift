import Foundation
import FalconCore

enum OAuthConfigLoader {
    static let keychain = KeychainStore()
    static let keychainAccount = "google.oauth.client"

    static func load() -> OAuthClientConfig? {
        bundled ?? configFile ?? override
    }

    /// Every client this build can sign in with, the one `load` picks first. A token is
    /// refreshed by the client that issued it, which may be one sign-in no longer picks.
    static func all() -> [OAuthClientConfig] {
        [bundled, configFile, override].compactMap { $0 }
    }

    private static var bundled: OAuthClientConfig? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "FalconGoogleClientID") as? String, isUsable(id) else { return nil }
        return OAuthClientConfig(clientID: id, clientSecret: Bundle.main.object(forInfoDictionaryKey: "FalconGoogleClientSecret") as? String)
    }

    private static var configFile: OAuthClientConfig? {
        guard let url = Bundle.main.url(forResource: "GoogleOAuth", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url) as? [String: Any],
              let id = dict["ClientID"] as? String, isUsable(id) else { return nil }
        return OAuthClientConfig(clientID: id, clientSecret: dict["ClientSecret"] as? String)
    }

    private static var override: OAuthClientConfig? {
        guard let stored = try? keychain.loadCodable(OAuthClientConfig.self, account: keychainAccount), !stored.clientID.isEmpty else { return nil }
        return stored
    }

    static var isBuiltIn: Bool {
        if let id = Bundle.main.object(forInfoDictionaryKey: "FalconGoogleClientID") as? String, isUsable(id) { return true }
        return false
    }

    private static func isUsable(_ id: String) -> Bool {
        !id.isEmpty && !id.hasPrefix("YOUR_") && !id.hasPrefix("$")
    }

    static var registeredSchemes: [String] {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        return types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }.map { $0.lowercased() }
    }

    static func redirect(for config: OAuthClientConfig) -> GoogleSignInFlow.Redirect {
        if !config.hasSecret, let scheme = config.reversedClientScheme, registeredSchemes.contains(scheme.lowercased()) {
            return .customScheme(scheme)
        }
        return .loopback
    }

    static func save(_ config: OAuthClientConfig) throws {
        try keychain.saveCodable(config, account: keychainAccount)
    }

    static func clearOverride() {
        keychain.delete(account: keychainAccount)
    }
}
