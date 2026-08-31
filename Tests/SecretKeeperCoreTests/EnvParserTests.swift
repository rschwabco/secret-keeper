import XCTest
@testable import SecretKeeperCore

final class EnvParserTests: XCTestCase {
    func testParsesBasicKeys() {
        let content = """
        # comment
        FOO=bar
        BAZ=qux

        export TOKEN=abc123
        """
        let items = EnvParser.parse(content)
        XCTAssertEqual(items.map(\.key), ["FOO", "BAZ", "TOKEN"])
        XCTAssertEqual(items.map(\.value), ["bar", "qux", "abc123"])
    }

    func testParsesQuotedValues() {
        let content = """
        A="hello world"
        B='keep # hash'
        C="line\\nbreak"
        """
        let items = EnvParser.parse(content)
        XCTAssertEqual(items.first { $0.key == "A" }?.value, "hello world")
        XCTAssertEqual(items.first { $0.key == "B" }?.value, "keep # hash")
        XCTAssertEqual(items.first { $0.key == "C" }?.value, "line\nbreak")
    }

    func testInlineCommentOnUnquoted() {
        let items = EnvParser.parse("KEY=value # note")
        XCTAssertEqual(items.first?.value, "value")
    }

    func testMergeUpdatesAndAppends() {
        let existing = [SecretItem(key: "A", value: "1"), SecretItem(key: "B", value: "2")]
        let parsed = [SecretItem(key: "B", value: "9"), SecretItem(key: "C", value: "3")]
        let merged = EnvParser.merge(existing: existing, parsed: parsed)
        XCTAssertEqual(merged.map(\.key), ["A", "B", "C"])
        XCTAssertEqual(merged.map(\.value), ["1", "9", "3"])
    }

    func testDuplicateKeysLastWins() {
        let items = EnvParser.parse("A=1\nA=2\n")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.value, "2")
    }
}
