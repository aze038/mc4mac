import Foundation
import FalconCore

enum OAuthConfigLoader {
    static let keychain = KeychainStore()
    static let keychainAccount = "google.oauth.client"

    static func load() -> OAuthClientConfig? {
        if let stored = try? keychain.loadCodable(OAuthClientConfig.self, account: keychainAccount), !stored.clientID.isEmpty {
            return stored
        }
        if let id = Bundle.main.object(forInfoDictionaryKey: "FalconGoogleClientID") as? String, isUsable(id) {
            return OAuthClientConfig(clientID: id, clientSecret: Bundle.main.object(forInfoDictionaryKey: "FalconGoogleClientSecret") as? String)
        }
        if let url = Bundle.main.url(forResource: "GoogleOAuth", withExtension: "plist"),
           let dict = NSDictionary(contentsOf: url) as? [String: Any],
           let id = dict["ClientID"] as? String, isUsable(id) {
            return OAuthClientConfig(clientID: id, clientSecret: dict["ClientSecret"] as? String)
        }
        return nil
    }

    static var isBuiltIn: Bool {
        if let id = Bundle.main.object(forInfoDictionaryKey: "FalconGoogleClientID") as? String, isUsable(id) { return true }
        return false
    }

    private static func isUsable(_ id: String) -> Bool {
        !id.isEmpty && !id.hasPrefix("YOUR_") && !id.hasPrefix("$")
    }

    static func save(_ config: OAuthClientConfig) throws {
        try keychain.saveCodable(config, account: keychainAccount)
    }

    static func clearOverride() {
        keychain.delete(account: keychainAccount)
    }
}
