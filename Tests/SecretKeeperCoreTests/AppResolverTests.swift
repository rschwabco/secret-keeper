import XCTest
@testable import SecretKeeperCore

final class AppResolverTests: XCTestCase {
    let resolver = AppResolver()
    var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sk-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testPrefixMatchPrefersLongerRoot() throws {
        let appA = tempRoot.appendingPathComponent("app", isDirectory: true)
        let nested = appA.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let apps = [
            VaultApp(name: "root", rootFolder: tempRoot.path),
            VaultApp(name: "app", rootFolder: appA.path),
        ]
        let resolved = try resolver.resolve(worktreePath: nested.path, apps: apps)
        XCTAssertEqual(resolved.name, "app")
    }

    func testExplicitAppName() throws {
        let folder = tempRoot.appendingPathComponent("pinecone", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let apps = [VaultApp(name: "pinecone", rootFolder: folder.path)]
        let resolved = try resolver.resolve(
            worktreePath: folder.path,
            apps: apps,
            explicitApp: "pinecone"
        )
        XCTAssertEqual(resolved.name, "pinecone")
    }
}
