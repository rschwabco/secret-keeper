import Foundation

public enum SecretKeeperPaths: Sendable {
    public static let applicationSupportName = "SecretKeeper"
    public static let vaultFileName = "vault.dat"
    public static let socketFileName = "secret-keeper.sock"
    public static let grantsDirectoryName = "grants"
    public static let keychainService = "com.secretkeeper.vault"
    public static let keychainAccount = "vault-master-key"
    public static let symlinkMarkerPrefix = "secret-keeper://"

    public static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(applicationSupportName, isDirectory: true)
    }

    public static var vaultURL: URL {
        applicationSupportDirectory.appendingPathComponent(vaultFileName)
    }

    public static var socketURL: URL {
        applicationSupportDirectory.appendingPathComponent(socketFileName)
    }

    public static var grantsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent(grantsDirectoryName, isDirectory: true)
    }

    public static func ensureDirectoriesExist() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: grantsDirectory, withIntermediateDirectories: true)
        try setOwnerOnlyPermissions(at: applicationSupportDirectory)
        try setOwnerOnlyPermissions(at: grantsDirectory)
    }

    public static func setOwnerOnlyPermissions(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    public static func setOwnerOnlyFilePermissions(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}
