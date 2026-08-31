import Foundation

public struct GrantResult: Sendable, Equatable {
    public var grant: Grant
    public var appName: String
    public var symlinkPath: String

    public init(grant: Grant, appName: String, symlinkPath: String) {
        self.grant = grant
        self.appName = appName
        self.symlinkPath = symlinkPath
    }
}

public struct GrantEngine: Sendable {
    public init() {}

    private var fileManager: FileManager { .default }

    public func grant(
        app: VaultApp,
        worktreePath: String,
        force: Bool,
        existingGrants: [Grant]
    ) throws -> (GrantResult, [Grant]) {
        try SecretKeeperPaths.ensureDirectoriesExist()
        let worktree = try AppResolver().normalizeDirectory(worktreePath)
        let symlinkURL = URL(fileURLWithPath: worktree).appendingPathComponent(".env.local")

        // fileExists follows symlinks and returns false for dangling ones — use
        // attributes so we still detect (and replace) Secret Keeper-owned links.
        if itemExists(at: symlinkURL) {
            if !isSecretKeeperSymlink(at: symlinkURL) && !force {
                throw SecretKeeperError.existingEnvFile(symlinkURL.path)
            }
            try removeItemIfPresent(at: symlinkURL)
        }

        // Revoke any previous grant for this worktree
        var grants = existingGrants
        grants = try revokeMatching(worktreePath: worktree, grants: grants, removeSymlink: false)

        let grantID = UUID()
        let envURL = SecretKeeperPaths.grantsDirectory
            .appendingPathComponent("\(grantID.uuidString).env")
        let contents = EnvFormatter.render(secrets: app.secrets)
        try contents.write(to: envURL, atomically: true, encoding: .utf8)
        try SecretKeeperPaths.setOwnerOnlyFilePermissions(at: envURL)

        try fileManager.createSymbolicLink(
            atPath: symlinkURL.path,
            withDestinationPath: envURL.path
        )

        let grant = Grant(
            id: grantID,
            appID: app.id,
            worktreePath: worktree,
            envPath: envURL.path
        )
        grants.append(grant)

        return (
            GrantResult(grant: grant, appName: app.name, symlinkPath: symlinkURL.path),
            grants
        )
    }

    public func revoke(worktreePath: String, grants: [Grant]) throws -> [Grant] {
        let worktree = (worktreePath as NSString).standardizingPath
        return try revokeMatching(worktreePath: worktree, grants: grants, removeSymlink: true)
    }

    public func wipeAllMaterializations(grants: [Grant]) throws {
        for grant in grants {
            try removeItemIfPresent(at: URL(fileURLWithPath: grant.envPath))
            let symlink = URL(fileURLWithPath: grant.worktreePath)
                .appendingPathComponent(".env.local")
            if isSecretKeeperSymlink(at: symlink) {
                try removeItemIfPresent(at: symlink)
            }
        }
        // Also clear any leftover grant files
        if let files = try? fileManager.contentsOfDirectory(
            at: SecretKeeperPaths.grantsDirectory,
            includingPropertiesForKeys: nil
        ) {
            for file in files where file.pathExtension == "env" {
                try? removeItemIfPresent(at: file)
            }
        }
    }

    /// True when `url` is a symlink whose destination is under the grants directory,
    /// including dangling links whose target file was deleted.
    public func isSecretKeeperSymlink(at url: URL) -> Bool {
        guard let dest = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return false
        }
        let destPath = URL(fileURLWithPath: dest, relativeTo: url.deletingLastPathComponent())
            .standardizedFileURL.path
        let grantsPath = SecretKeeperPaths.grantsDirectory.standardizedFileURL.path
        return destPath == grantsPath || destPath.hasPrefix(grantsPath + "/")
    }

    private func revokeMatching(
        worktreePath: String,
        grants: [Grant],
        removeSymlink: Bool
    ) throws -> [Grant] {
        var remaining: [Grant] = []
        for grant in grants {
            if grant.worktreePath == worktreePath {
                try removeItemIfPresent(at: URL(fileURLWithPath: grant.envPath))
                if removeSymlink {
                    let symlink = URL(fileURLWithPath: grant.worktreePath)
                        .appendingPathComponent(".env.local")
                    if isSecretKeeperSymlink(at: symlink) {
                        try removeItemIfPresent(at: symlink)
                    }
                }
            } else {
                remaining.append(grant)
            }
        }
        return remaining
    }

    /// True for regular files/dirs and for symlinks (including dangling).
    private func itemExists(at url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    private func removeItemIfPresent(at url: URL) throws {
        // attributesOfItem sees dangling symlinks; fileExists does not.
        if itemExists(at: url) {
            try fileManager.removeItem(at: url)
        }
    }
}
