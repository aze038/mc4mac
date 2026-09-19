import Foundation
@preconcurrency import CryptoKit
import CommonCrypto

public struct ArchiveCrypto: Sendable {
    public static let iterations = 600_000
    static let checkPlaintext = "falconmail-archive-v1"
    private let key: SymmetricKey

    public init(password: String, salt: Data, iterations: Int = ArchiveCrypto.iterations) throws {
        var derived = [UInt8](repeating: 0, count: 32)
        let passwordBytes = Array(password.utf8)
        let saltBytes = [UInt8](salt)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.map { CChar(bitPattern: $0) }, passwordBytes.count,
                                          saltBytes, saltBytes.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                          UInt32(iterations), &derived, derived.count)
        guard status == Int32(kCCSuccess) else { throw FalconError.storage("key derivation failed") }
        key = SymmetricKey(data: Data(derived))
    }

    public static func create(password: String) throws -> (ArchiveCrypto, ArchiveEncryptionInfo) {
        let salt = Data.random(count: 16)
        let crypto = try ArchiveCrypto(password: password, salt: salt)
        let check = try crypto.seal(Data(checkPlaintext.utf8))
        let info = ArchiveEncryptionInfo(algorithm: "AES-256-GCM", kdf: "PBKDF2-HMAC-SHA256", iterations: iterations,
                                         salt: salt.base64EncodedString(), check: check.base64EncodedString())
        return (crypto, info)
    }

    public static func open(password: String, info: ArchiveEncryptionInfo) throws -> ArchiveCrypto {
        guard let salt = Data(base64Encoded: info.salt), let check = Data(base64Encoded: info.check) else {
            throw FalconError.storage("archive encryption metadata is invalid")
        }
        let crypto = try ArchiveCrypto(password: password, salt: salt, iterations: info.iterations)
        guard let plain = try? crypto.unseal(check), plain == Data(checkPlaintext.utf8) else {
            throw FalconError.invalidInput("Wrong archive password.")
        }
        return crypto
    }

    public func seal(_ data: Data) throws -> Data {
        let box = try AES.GCM.seal(data, using: key)
        guard let combined = box.combined else { throw FalconError.storage("encryption failed") }
        return combined
    }

    public func unseal(_ data: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: key)
    }
}
