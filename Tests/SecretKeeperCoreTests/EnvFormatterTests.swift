import XCTest
@testable import SecretKeeperCore

final class EnvFormatterTests: XCTestCase {
    func testRendersSortedKeys() {
        let secrets = [
            SecretItem(key: "B", value: "2"),
            SecretItem(key: "A", value: "1"),
        ]
        XCTAssertEqual(EnvFormatter.render(secrets: secrets), "A=1\nB=2\n")
    }

    func testQuotesValuesWithSpaces() {
        XCTAssertEqual(EnvFormatter.escapeValue("hello world"), "\"hello world\"")
        XCTAssertEqual(EnvFormatter.escapeValue("plain"), "plain")
    }
}
