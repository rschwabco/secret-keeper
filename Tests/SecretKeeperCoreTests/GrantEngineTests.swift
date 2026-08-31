import XCTest
@testable import SecretKeeperCore

final class GrantEngineTests: XCTestCase {
    let engine = GrantEngine()
    var worktree: URL!
    var originalGrantsDir: URL?

    override func setUpWithError() throws {
        worktree = FileManager.default.temporaryDirectory
            .appendingPathComponent("sk-worktree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try SecretKeeperPaths.ensureDirectoriesExist()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: worktree)
    }

    func testGrantCreatesSymlinkAndEnvFile() throws {
        let app = VaultApp(
            name: "demo",
            rootFolder: worktree.path,
            secrets: [SecretItem(key: "TOKEN", value: "abc123")]
        )
        let (result, grants) = try engine.grant(
            app: app,
            worktreePath: worktree.path,
            force: false,
            existingGrants: []
        )
        XCTAssertEqual(grants.count, 1)
        let symlink = worktree.appendingPathComponent(".env.local")
        XCTAssertTrue(engine.isSecretKeeperSymlink(at: symlink))
        let contents = try String(contentsOf: URL(fileURLWithPath: result.grant.envPath), encoding: .utf8)
        XCTAssertTrue(contents.contains("TOKEN=abc123"))

        let remaining = try engine.revoke(worktreePath: worktree.path, grants: grants)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: symlink.path))
    }

    func testRefusesExistingRegularFileWithoutForce() throws {
        let env = worktree.appendingPathComponent(".env.local")
        try "EXISTING=1\n".write(to: env, atomically: true, encoding: .utf8)
        let app = VaultApp(name: "demo", rootFolder: worktree.path, secrets: [])
        XCTAssertThrowsError(
            try engine.grant(app: app, worktreePath: worktree.path, force: false, existingGrants: [])
        )
        let (result, _) = try engine.grant(
            app: app,
            worktreePath: worktree.path,
            force: true,
            existingGrants: []
        )
        XCTAssertTrue(engine.isSecretKeeperSymlink(at: URL(fileURLWithPath: result.symlinkPath)))
        _ = try engine.revoke(worktreePath: worktree.path, grants: [result.grant])
    }

    func testReplacesDanglingSecretKeeperSymlinkWithoutForce() throws {
        let app = VaultApp(
            name: "demo",
            rootFolder: worktree.path,
            secrets: [SecretItem(key: "TOKEN", value: "fresh")]
        )
        let (first, grants) = try engine.grant(
            app: app,
            worktreePath: worktree.path,
            force: false,
            existingGrants: []
        )
        let symlink = worktree.appendingPathComponent(".env.local")
        XCTAssertTrue(engine.isSecretKeeperSymlink(at: symlink))

        // Simulate lock wiping the grant file but leaving the symlink behind
        // (or wipe failing to remove a dangling link).
        try FileManager.default.removeItem(atPath: first.grant.envPath)
        XCTAssertTrue(engine.isSecretKeeperSymlink(at: symlink), "dangling SK symlink should still be recognized")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: symlink.path),
            "fileExists follows the dead target and should report false"
        )

        let (second, updated) = try engine.grant(
            app: app,
            worktreePath: worktree.path,
            force: false,
            existingGrants: grants
        )
        XCTAssertEqual(updated.count, 1)
        XCTAssertTrue(engine.isSecretKeeperSymlink(at: symlink))
        XCTAssertNotEqual(first.grant.envPath, second.grant.envPath)
        let contents = try String(contentsOf: URL(fileURLWithPath: second.grant.envPath), encoding: .utf8)
        XCTAssertTrue(contents.contains("TOKEN=fresh"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.grant.envPath))

        _ = try engine.revoke(worktreePath: worktree.path, grants: updated)
    }

    func testRefusesExternalSymlinkWithoutForce() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("sk-outside-\(UUID().uuidString).env")
        try "OUTSIDE=1\n".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        let symlink = worktree.appendingPathComponent(".env.local")
        try FileManager.default.createSymbolicLink(
            atPath: symlink.path,
            withDestinationPath: outside.path
        )
        XCTAssertFalse(engine.isSecretKeeperSymlink(at: symlink))

        let app = VaultApp(name: "demo", rootFolder: worktree.path, secrets: [])
        XCTAssertThrowsError(
            try engine.grant(app: app, worktreePath: worktree.path, force: false, existingGrants: [])
        )

        let (result, _) = try engine.grant(
            app: app,
            worktreePath: worktree.path,
            force: true,
            existingGrants: []
        )
        XCTAssertTrue(engine.isSecretKeeperSymlink(at: symlink))
        _ = try engine.revoke(worktreePath: worktree.path, grants: [result.grant])
    }

    func testWipeRemovesDanglingSymlinks() throws {
        let app = VaultApp(
            name: "demo",
            rootFolder: worktree.path,
            secrets: [SecretItem(key: "A", value: "1")]
        )
        let (result, grants) = try engine.grant(
            app: app,
            worktreePath: worktree.path,
            force: false,
            existingGrants: []
        )
        let symlink = worktree.appendingPathComponent(".env.local")

        // Delete grant file first so the symlink becomes dangling mid-wipe.
        try FileManager.default.removeItem(atPath: result.grant.envPath)
        try engine.wipeAllMaterializations(grants: grants)

        let attrs = try? FileManager.default.attributesOfItem(atPath: symlink.path)
        XCTAssertNil(attrs, "dangling SK symlink should be removed by wipe")
    }
}
