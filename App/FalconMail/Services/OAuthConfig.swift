import Foundation
import FalconCore

enum OAuthConfigLoader {
    static let keychain = KeychainStore()
    static let keychainAccount = "google.oauth.client"

    static func load() -> OAuthClientConfig? {
        if let stored = try? keychain.loadCodable(OAuthClientConfig.self, account: keychainAccount), !stored.clientID.isEmpty {
            return stored
        }
        guard let url = Bundle.main.url(forResource: "GoogleOAuth", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url) as? [String: Any],
              let id = dict["ClientID"] as? String, !id.isEmpty, !id.hasPrefix("YOUR_") else { return nil }
        return OAuthClientConfig(clientID: id, clientSecret: dict["ClientSecret"] as? String)
    }

    static func save(_ config: OAuthClientConfig) throws {
        try keychain.saveCodable(config, account: keychainAccount)
    }
}
