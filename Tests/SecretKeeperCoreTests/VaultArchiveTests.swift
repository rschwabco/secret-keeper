import XCTest
@testable import SecretKeeperCore

final class VaultArchiveTests: XCTestCase {
    private let passphrase = "correct-horse-battery"

    private func sampleApps() -> [VaultApp] {
        [
            VaultApp(name: "Alpha", rootFolder: "/tmp/alpha", secrets: [
                SecretItem(key: "API_KEY", value: "super-secret-value"),
                SecretItem(key: "DB_URL", value: "postgres://localhost/alpha"),
            ]),
            VaultApp(name: "Beta", rootFolder: "/tmp/beta", secrets: [
                SecretItem(key: "TOKEN", value: "t0ken"),
            ]),
        ]
    }

    func testRoundTripPreservesEveryAppAndSecret() throws {
        let apps = sampleApps()
        let file = try VaultArchive.seal(apps: apps, passphrase: passphrase)
        let opened = try VaultArchive.open(file, passphrase: passphrase)
        XCTAssertEqual(opened.apps, apps)
        XCTAssertEqual(opened.formatVersion, VaultArchive.currentVersion)
    }

    func testArchiveBytesNeverContainPlaintextSecrets() throws {
        let file = try VaultArchive.seal(apps: sampleApps(), passphrase: passphrase)
        let text = String(decoding: file, as: UTF8.self)
        XCTAssertFalse(text.contains("super-secret-value"))
        XCTAssertFalse(text.contains("API_KEY"))
        XCTAssertFalse(text.contains("Alpha"))
        XCTAssertFalse(text.contains("/tmp/alpha"))
    }

    func testWrongPassphraseFails() throws {
        let file = try VaultArchive.seal(apps: sampleApps(), passphrase: passphrase)
        XCTAssertThrowsError(try VaultArchive.open(file, passphrase: "not-the-passphrase")) { error in
            XCTAssertEqual(error as? SecretKeeperError, .archiveAuthenticationFailed)
        }
    }

    func testShortPassphraseIsRejectedBeforeSealing() {
        XCTAssertThrowsError(try VaultArchive.seal(apps: sampleApps(), passphrase: "short")) { error in
            XCTAssertEqual(
                error as? SecretKeeperError,
                .archivePassphraseTooShort(VaultArchive.minimumPassphraseLength)
            )
        }
    }

    func testTamperedCiphertextFails() throws {
        let file = try VaultArchive.seal(apps: sampleApps(), passphrase: passphrase)
        var envelope = try XCTUnwrap(decodeEnvelope(file))
        var bytes = [UInt8](envelope.ciphertext)
        bytes[bytes.count / 2] ^= 0xFF
        envelope.ciphertext = Data(bytes)

        XCTAssertThrowsError(try VaultArchive.open(encode(envelope), passphrase: passphrase)) { error in
            XCTAssertEqual(error as? SecretKeeperError, .archiveAuthenticationFailed)
        }
    }

    /// The header is cleartext, so downgrading it must not be a way in.
    func testHeaderIterationDowngradeFails() throws {
        let file = try VaultArchive.seal(apps: sampleApps(), passphrase: passphrase)
        var envelope = try XCTUnwrap(decodeEnvelope(file))
        envelope.header.kdf.iterations = 120_000 // still above the floor, but not what we sealed

        XCTAssertThrowsError(try VaultArchive.open(encode(envelope), passphrase: passphrase)) { error in
            XCTAssertEqual(error as? SecretKeeperError, .archiveAuthenticationFailed)
        }
    }

    func testHeaderSaltSwapFails() throws {
        let file = try VaultArchive.seal(apps: sampleApps(), passphrase: passphrase)
        var envelope = try XCTUnwrap(decodeEnvelope(file))
        envelope.header.kdf.salt = Data(repeating: 0xAB, count: VaultArchive.saltByteCount)

        XCTAssertThrowsError(try VaultArchive.open(encode(envelope), passphrase: passphrase)) { error in
            XCTAssertEqual(error as? SecretKeeperError, .archiveAuthenticationFailed)
        }
    }

    func testBelowFloorIterationsRejectedAsMalformed() throws {
        let file = try VaultArchive.seal(apps: sampleApps(), passphrase: passphrase)
        var envelope = try XCTUnwrap(decodeEnvelope(file))
        envelope.header.kdf.iterations = 10

        XCTAssertThrowsError(try VaultArchive.open(encode(envelope), passphrase: passphrase)) { error in
            guard case .archiveFormatInvalid = error as? SecretKeeperError else {
                return XCTFail("Expected archiveFormatInvalid, got \(error)")
            }
        }
    }

    func testNewerFormatVersionIsRefused() throws {
        let file = try VaultArchive.seal(apps: sampleApps(), passphrase: passphrase)
        var envelope = try XCTUnwrap(decodeEnvelope(file))
        envelope.header.version = VaultArchive.currentVersion + 1

        XCTAssertThrowsError(try VaultArchive.open(encode(envelope), passphrase: passphrase)) { error in
            XCTAssertEqual(
                error as? SecretKeeperError,
                .archiveUnsupportedVersion(VaultArchive.currentVersion + 1)
            )
        }
    }

    func testForeignFileIsRejected() {
        let junk = Data(#"{"hello":"world"}"#.utf8)
        XCTAssertThrowsError(try VaultArchive.open(junk, passphrase: passphrase)) { error in
            guard case .archiveFormatInvalid = error as? SecretKeeperError else {
                return XCTFail("Expected archiveFormatInvalid, got \(error)")
            }
        }
    }

    func testInspectReadsHeaderWithoutPassphrase() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let file = try VaultArchive.seal(apps: sampleApps(), passphrase: passphrase, now: now)
        let header = try VaultArchive.inspect(file)
        XCTAssertEqual(header.magic, VaultArchive.magic)
        XCTAssertEqual(header.version, VaultArchive.currentVersion)
        XCTAssertEqual(header.appCount, 2)
        XCTAssertEqual(header.cipher, VaultArchive.cipherName)
        XCTAssertEqual(header.kdf.iterations, VaultArchive.kdfIterations)
        XCTAssertEqual(header.createdAt.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 1)
    }

    func testEverySealUsesAFreshSalt() throws {
        let first = try VaultArchive.inspect(VaultArchive.seal(apps: [], passphrase: passphrase))
        let second = try VaultArchive.inspect(VaultArchive.seal(apps: [], passphrase: passphrase))
        XCTAssertNotEqual(first.kdf.salt, second.kdf.salt)
    }

    func testSuggestedPassphraseMeetsItsOwnMinimum() {
        for _ in 0..<20 {
            XCTAssertNoThrow(try VaultArchive.validatePassphrase(VaultArchive.suggestPassphrase()))
        }
        XCTAssertNotEqual(VaultArchive.suggestPassphrase(), VaultArchive.suggestPassphrase())
    }

    // MARK: - Helpers

    private func decodeEnvelope(_ data: Data) -> VaultArchive.Envelope? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(VaultArchive.Envelope.self, from: data)
    }

    private func encode(_ envelope: VaultArchive.Envelope) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(envelope)) ?? Data()
    }
}
