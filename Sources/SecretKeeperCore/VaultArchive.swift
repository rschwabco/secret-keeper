import Foundation
import CryptoKit
import CommonCrypto
import Security

/// Portable, passphrase-encrypted vault archive.
///
/// The vault master key is device-bound (Keychain, `WhenUnlockedThisDeviceOnly`, and
/// regenerated per install), so it can never travel to a second Mac. An archive is
/// therefore sealed under a key derived from a passphrase the user carries out-of-band.
///
/// File layout is a JSON envelope: a cleartext `header` describing the KDF/cipher
/// parameters, plus the AES-GCM `ciphertext` of the payload. The security-critical
/// header fields are bound into the ciphertext as GCM additional authenticated data,
/// so an attacker cannot downgrade the iteration count or swap the salt.
public enum VaultArchive: Sendable {
    public static let magic = "secret-keeper-export"
    public static let currentVersion = 1
    public static let fileExtension = "skeeper"
    public static let cipherName = "AES-256-GCM"
    public static let kdfName = "PBKDF2-HMAC-SHA256"

    /// OWASP 2023 guidance for PBKDF2-HMAC-SHA256.
    public static let kdfIterations = 600_000
    public static let saltByteCount = 32
    public static let minimumPassphraseLength = 12

    // MARK: - File models

    public struct KDFParameters: Codable, Sendable, Equatable {
        public var algorithm: String
        public var iterations: Int
        /// Encodes as base64 in JSON.
        public var salt: Data

        public init(algorithm: String, iterations: Int, salt: Data) {
            self.algorithm = algorithm
            self.iterations = iterations
            self.salt = salt
        }
    }

    public struct Header: Codable, Sendable, Equatable {
        public var magic: String
        public var version: Int
        public var cipher: String
        public var kdf: KDFParameters
        /// Informational only — deliberately not part of the authenticated data.
        public var createdAt: Date
        /// Informational only. Number of apps in the archive, for a pre-unlock preview.
        public var appCount: Int

        public init(
            magic: String = VaultArchive.magic,
            version: Int = VaultArchive.currentVersion,
            cipher: String = VaultArchive.cipherName,
            kdf: KDFParameters,
            createdAt: Date,
            appCount: Int
        ) {
            self.magic = magic
            self.version = version
            self.cipher = cipher
            self.kdf = kdf
            self.createdAt = createdAt
            self.appCount = appCount
        }
    }

    struct Envelope: Codable, Sendable, Equatable {
        var header: Header
        var ciphertext: Data
    }

    /// Decrypted archive contents.
    ///
    /// Grants are intentionally excluded: they are machine-local materializations
    /// (worktree paths and session env files) and mean nothing on another Mac.
    public struct Payload: Codable, Sendable, Equatable {
        public var formatVersion: Int
        public var exportedAt: Date
        public var apps: [VaultApp]

        public init(formatVersion: Int = VaultArchive.currentVersion, exportedAt: Date, apps: [VaultApp]) {
            self.formatVersion = formatVersion
            self.exportedAt = exportedAt
            self.apps = apps
        }
    }

    // MARK: - Seal / open

    public static func seal(apps: [VaultApp], passphrase: String, now: Date = Date()) throws -> Data {
        try validatePassphrase(passphrase)

        let salt = try randomBytes(count: saltByteCount)
        let kdf = KDFParameters(algorithm: kdfName, iterations: kdfIterations, salt: salt)
        let header = Header(kdf: kdf, createdAt: now, appCount: apps.count)

        let payload = Payload(exportedAt: now, apps: apps)
        let plaintext = try encode(payload)

        let key = try deriveKey(passphrase: passphrase, kdf: kdf)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: authenticatedData(for: header))
        guard let combined = sealed.combined else {
            throw SecretKeeperError.cryptoFailure("Failed to combine sealed archive box")
        }

        return try encode(Envelope(header: header, ciphertext: combined))
    }

    public static func open(_ fileData: Data, passphrase: String) throws -> Payload {
        let envelope = try decodeEnvelope(fileData)
        let header = envelope.header
        try validate(header: header)

        let key = try deriveKey(passphrase: passphrase, kdf: header.kdf)
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(combined: envelope.ciphertext)
            plaintext = try AES.GCM.open(box, using: key, authenticating: authenticatedData(for: header))
        } catch {
            // GCM cannot distinguish a wrong key from a modified file — both fail here.
            throw SecretKeeperError.archiveAuthenticationFailed
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Payload.self, from: plaintext)
        } catch {
            throw SecretKeeperError.archiveFormatInvalid("Archive contents could not be decoded.")
        }
    }

    /// Read the cleartext header without the passphrase, for a pre-import preview.
    public static func inspect(_ fileData: Data) throws -> Header {
        let envelope = try decodeEnvelope(fileData)
        try validate(header: envelope.header)
        return envelope.header
    }

    // MARK: - Passphrase

    public static func validatePassphrase(_ passphrase: String) throws {
        if passphrase.count < minimumPassphraseLength {
            throw SecretKeeperError.archivePassphraseTooShort(minimumPassphraseLength)
        }
    }

    /// Unambiguous alphabet (no 0/O/1/l/I), 4 groups of 5 → ~100 bits of entropy.
    public static func suggestPassphrase() -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        let groups = (0..<4).map { _ -> String in
            String((0..<5).compactMap { _ in randomElement(of: alphabet) })
        }
        return groups.joined(separator: "-")
    }

    // MARK: - Private

    /// Fixed-order canonical binding of the parameters an attacker could otherwise
    /// downgrade. Built by hand rather than by re-encoding JSON so it never depends on
    /// encoder key ordering or on fields a future version might add.
    static func authenticatedData(for header: Header) -> Data {
        let fields = [
            header.magic,
            String(header.version),
            header.cipher,
            header.kdf.algorithm,
            String(header.kdf.iterations),
            header.kdf.salt.base64EncodedString(),
        ]
        return Data(fields.joined(separator: "|").utf8)
    }

    private static func validate(header: Header) throws {
        guard header.magic == magic else {
            throw SecretKeeperError.archiveFormatInvalid("Not a Secret Keeper archive.")
        }
        guard header.version <= currentVersion else {
            throw SecretKeeperError.archiveUnsupportedVersion(header.version)
        }
        guard header.cipher == cipherName, header.kdf.algorithm == kdfName else {
            throw SecretKeeperError.archiveFormatInvalid(
                "Unsupported cipher or key derivation (\(header.cipher) / \(header.kdf.algorithm))."
            )
        }
        guard header.kdf.iterations >= 100_000 else {
            throw SecretKeeperError.archiveFormatInvalid(
                "Archive key derivation is too weak (\(header.kdf.iterations) iterations)."
            )
        }
        guard header.kdf.salt.count >= 16 else {
            throw SecretKeeperError.archiveFormatInvalid("Archive salt is too short.")
        }
    }

    private static func decodeEnvelope(_ fileData: Data) throws -> Envelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Envelope.self, from: fileData)
        } catch {
            throw SecretKeeperError.archiveFormatInvalid("File is not a Secret Keeper archive.")
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func deriveKey(passphrase: String, kdf: KDFParameters) throws -> SymmetricKey {
        var passBytes = Array(passphrase.utf8).map { Int8(bitPattern: $0) }
        let saltBytes = [UInt8](kdf.salt)
        var derived = [UInt8](repeating: 0, count: 32)

        guard !passBytes.isEmpty, !saltBytes.isEmpty else {
            throw SecretKeeperError.cryptoFailure("Empty passphrase or salt")
        }

        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passBytes,
            passBytes.count,
            saltBytes,
            saltBytes.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            UInt32(kdf.iterations),
            &derived,
            derived.count
        )
        guard status == kCCSuccess else {
            throw SecretKeeperError.cryptoFailure("PBKDF2 failed (\(status))")
        }

        let key = SymmetricKey(data: Data(derived))
        // Best-effort scrub of the intermediate buffers.
        for index in derived.indices { derived[index] = 0 }
        for index in passBytes.indices { passBytes[index] = 0 }
        return key
    }

    private static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw SecretKeeperError.cryptoFailure("SecRandomCopyBytes failed (\(status))")
        }
        return Data(bytes)
    }

    private static func randomElement(of alphabet: [Character]) -> Character? {
        guard let byte = try? randomBytes(count: 1).first else { return nil }
        // Rejection-free bias is negligible here because the alphabet size (32) divides 256.
        return alphabet[Int(byte) % alphabet.count]
    }
}
