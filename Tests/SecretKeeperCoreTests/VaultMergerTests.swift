import XCTest
@testable import SecretKeeperCore

final class VaultMergerTests: XCTestCase {
    private let allFoldersExist: (String) -> Bool = { _ in true }

    func testMergeAddsUnknownApp() {
        let existing = [VaultApp(name: "Alpha", rootFolder: "/a", secrets: [SecretItem(key: "K", value: "1")])]
        let incoming = [VaultApp(name: "Beta", rootFolder: "/b", secrets: [SecretItem(key: "T", value: "2")])]

        let (apps, summary) = VaultMerger.apply(
            incoming: incoming, to: existing, mode: .merge, folderExists: allFoldersExist
        )

        XCTAssertEqual(apps.map(\.name), ["Alpha", "Beta"])
        XCTAssertEqual(summary.appsAdded, 1)
        XCTAssertEqual(summary.appsUpdated, 0)
        XCTAssertEqual(summary.secretsAdded, 1)
    }

    /// The same project registered by hand on two Macs has two different UUIDs;
    /// name matching must find it, and the local id must survive so grants stay valid.
    func testMergeMatchesByNameAndKeepsLocalAppID() {
        let localID = UUID()
        let existing = [
            VaultApp(id: localID, name: "Alpha", rootFolder: "/a", secrets: [SecretItem(key: "OLD", value: "1")])
        ]
        let incoming = [
            VaultApp(name: "alpha", rootFolder: "/a", secrets: [SecretItem(key: "NEW", value: "2")])
        ]

        let (apps, summary) = VaultMerger.apply(
            incoming: incoming, to: existing, mode: .merge, folderExists: allFoldersExist
        )

        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].id, localID)
        XCTAssertEqual(apps[0].secrets.map(\.key), ["NEW", "OLD"])
        XCTAssertEqual(summary.appsAdded, 0)
        XCTAssertEqual(summary.appsUpdated, 1)
        XCTAssertEqual(summary.secretsAdded, 1)
        XCTAssertEqual(summary.secretsUpdated, 0)
    }

    func testMergeArchiveWinsOnKeyCollision() {
        let existing = [VaultApp(name: "Alpha", rootFolder: "/a", secrets: [SecretItem(key: "K", value: "old")])]
        let incoming = [VaultApp(name: "Alpha", rootFolder: "/a", secrets: [SecretItem(key: "K", value: "new")])]

        let (apps, summary) = VaultMerger.apply(
            incoming: incoming, to: existing, mode: .merge, folderExists: allFoldersExist
        )

        XCTAssertEqual(apps[0].secrets.first?.value, "new")
        XCTAssertEqual(summary.secretsUpdated, 1)
        XCTAssertEqual(summary.secretsAdded, 0)
    }

    func testMergeIsIdempotent() {
        let existing = [VaultApp(name: "Alpha", rootFolder: "/a", secrets: [SecretItem(key: "K", value: "1")])]
        let incoming = [VaultApp(name: "Alpha", rootFolder: "/a", secrets: [SecretItem(key: "K", value: "1")])]

        let (apps, summary) = VaultMerger.apply(
            incoming: incoming, to: existing, mode: .merge, folderExists: allFoldersExist
        )

        XCTAssertEqual(apps, existing)
        XCTAssertTrue(summary.isEmpty)
    }

    func testMergeKeepsSecretsMissingFromArchive() {
        let existing = [
            VaultApp(name: "Alpha", rootFolder: "/a", secrets: [
                SecretItem(key: "LOCAL_ONLY", value: "keep"),
                SecretItem(key: "SHARED", value: "old"),
            ])
        ]
        let incoming = [
            VaultApp(name: "Alpha", rootFolder: "/a", secrets: [SecretItem(key: "SHARED", value: "new")])
        ]

        let (apps, _) = VaultMerger.apply(
            incoming: incoming, to: existing, mode: .merge, folderExists: allFoldersExist
        )

        XCTAssertEqual(apps[0].secrets.map(\.key), ["LOCAL_ONLY", "SHARED"])
        XCTAssertEqual(apps[0].secrets.first(where: { $0.key == "LOCAL_ONLY" })?.value, "keep")
        XCTAssertEqual(apps[0].secrets.first(where: { $0.key == "SHARED" })?.value, "new")
    }

    func testReplaceDropsAppsAbsentFromArchive() {
        let existing = [
            VaultApp(name: "Alpha", rootFolder: "/a", secrets: [SecretItem(key: "K", value: "1")]),
            VaultApp(name: "Gamma", rootFolder: "/g", secrets: [SecretItem(key: "G", value: "9")]),
        ]
        let incoming = [VaultApp(name: "Alpha", rootFolder: "/a", secrets: [SecretItem(key: "K", value: "2")])]

        let (apps, summary) = VaultMerger.apply(
            incoming: incoming, to: existing, mode: .replace, folderExists: allFoldersExist
        )

        XCTAssertEqual(apps.map(\.name), ["Alpha"])
        XCTAssertEqual(apps[0].secrets.map(\.value), ["2"])
        XCTAssertEqual(summary.appsRemoved, 1)
    }

    /// Replace means the archive's key set wins outright — no local leftovers.
    func testReplaceDropsLocalOnlySecrets() {
        let existing = [
            VaultApp(name: "Alpha", rootFolder: "/a", secrets: [
                SecretItem(key: "LOCAL_ONLY", value: "gone"),
                SecretItem(key: "SHARED", value: "old"),
            ])
        ]
        let incoming = [
            VaultApp(name: "Alpha", rootFolder: "/a", secrets: [SecretItem(key: "SHARED", value: "new")])
        ]

        let (apps, _) = VaultMerger.apply(
            incoming: incoming, to: existing, mode: .replace, folderExists: allFoldersExist
        )

        XCTAssertEqual(apps[0].secrets.map(\.key), ["SHARED"])
    }

    func testMissingRootFoldersAreReported() {
        let incoming = [
            VaultApp(name: "Alpha", rootFolder: "/Users/someone-else/alpha", secrets: []),
            VaultApp(name: "Beta", rootFolder: "/here", secrets: []),
        ]

        let (_, summary) = VaultMerger.apply(
            incoming: incoming,
            to: [],
            mode: .merge,
            folderExists: { $0 == "/here" }
        )

        XCTAssertEqual(summary.appsWithMissingFolders, ["Alpha"])
    }

    func testDuplicateKeysInArchiveCollapseWithLastWinning() {
        let incoming = [
            VaultApp(name: "Alpha", rootFolder: "/a", secrets: [
                SecretItem(key: "K", value: "first"),
                SecretItem(key: "K", value: "last"),
            ])
        ]

        let (apps, summary) = VaultMerger.apply(
            incoming: incoming, to: [], mode: .merge, folderExists: allFoldersExist
        )

        XCTAssertEqual(apps[0].secrets.count, 1)
        XCTAssertEqual(apps[0].secrets[0].value, "last")
        XCTAssertEqual(summary.secretsAdded, 1)
    }

    func testTwoArchiveAppsWithTheSameNameDoNotBothClaimOneLocalApp() {
        let existing = [VaultApp(name: "Alpha", rootFolder: "/a", secrets: [])]
        let incoming = [
            VaultApp(name: "Alpha", rootFolder: "/a1", secrets: [SecretItem(key: "A", value: "1")]),
            VaultApp(name: "Alpha", rootFolder: "/a2", secrets: [SecretItem(key: "B", value: "2")]),
        ]

        let (apps, summary) = VaultMerger.apply(
            incoming: incoming, to: existing, mode: .merge, folderExists: allFoldersExist
        )

        XCTAssertEqual(apps.count, 2)
        XCTAssertEqual(summary.appsAdded, 1)
        XCTAssertEqual(summary.appsUpdated, 1)
    }
}
