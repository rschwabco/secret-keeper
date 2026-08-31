import Foundation
import CryptoKit

public enum VaultCrypto: Sendable {
    public static func generateKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    public static func keyData(from key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    public static func key(from data: Data) throws -> SymmetricKey {
        guard data.count == 32 else {
            throw SecretKeeperError.cryptoFailure("Vault key must be 32 bytes")
        }
        return SymmetricKey(data: data)
    }

    public static func seal(_ plaintext: Data, using key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw SecretKeeperError.cryptoFailure("Failed to combine sealed box")
        }
        return combined
    }

    public static func open(_ ciphertext: Data, using key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key)
    }

    public static func encodePayload(_ payload: VaultPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    public static func decodePayload(_ data: Data) throws -> VaultPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VaultPayload.self, from: data)
    }
}
