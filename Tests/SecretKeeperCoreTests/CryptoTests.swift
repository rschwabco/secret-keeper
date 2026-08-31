import XCTest
@testable import SecretKeeperCore

final class CryptoTests: XCTestCase {
    func testSealOpenRoundTrip() throws {
        let key = VaultCrypto.generateKey()
        let payload = VaultPayload(apps: [
            VaultApp(name: "a", rootFolder: "/tmp/a", secrets: [
                SecretItem(key: "K", value: "V"),
            ])
        ])
        let plaintext = try VaultCrypto.encodePayload(payload)
        let sealed = try VaultCrypto.seal(plaintext, using: key)
        let opened = try VaultCrypto.open(sealed, using: key)
        let decoded = try VaultCrypto.decodePayload(opened)
        XCTAssertEqual(decoded, payload)
    }
}
