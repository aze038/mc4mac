import Foundation
import Security

public struct KeychainStore: Sendable {
    public let service: String

    public init(service: String = "com.falconmail.app") {
        self.service = service
    }

    public func save(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw FalconError.storage("Keychain add failed (\(addStatus))") }
            return
        }
        guard status == errSecSuccess else { throw FalconError.storage("Keychain update failed (\(status))") }
    }

    public func load(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw FalconError.storage("Keychain read failed (\(status))") }
        return result as? Data
    }

    public func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    public func saveCodable<T: Encodable>(_ value: T, account: String) throws {
        try save(try JSONEncoder().encode(value), account: account)
    }

    public func loadCodable<T: Decodable>(_ type: T.Type, account: String) throws -> T? {
        guard let data = try load(account: account) else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }
}
