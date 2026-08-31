import Foundation
import CryptoKit

public actor VaultStore {
    private let keychain: KeychainStore
    private var masterKey: SymmetricKey?
    private var payload: VaultPayload?
    private let grantEngine = GrantEngine()
    private let resolver = AppResolver()

    public init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    public var isUnlocked: Bool { masterKey != nil && payload != nil }

    public var state: VaultState {
        if isUnlocked { return .unlocked }
        if vaultFileExists || keychain.hasStoredKey { return .locked }
        return .unavailable
    }

    public var vaultFileExists: Bool {
        FileManager.default.fileExists(atPath: SecretKeeperPaths.vaultURL.path)
    }

    /// True only when there is no vault yet (first launch).
    /// Never treat a missing Keychain key + existing vault.dat as "setup" — that would wipe config.
    public var needsSetup: Bool {
        !vaultFileExists
    }

    public var hasOrphanedVault: Bool {
        vaultFileExists && !keychain.hasStoredKey
    }

    // MARK: - Lifecycle

    public func setupIfNeeded() throws {
        try SecretKeeperPaths.ensureDirectoriesExist()

        // Existing vault must never be overwritten during setup/reinstall.
        if vaultFileExists {
            return
        }

        let key = VaultCrypto.generateKey()
        try keychain.storeKey(VaultCrypto.keyData(from: key))
        masterKey = key
        payload = VaultPayload()
        try persist()
        lock()
    }

    public func unlock(reason: String = "Unlock Secret Keeper") async throws {
        try SecretKeeperPaths.ensureDirectoriesExist()

        if !vaultFileExists {
            try setupIfNeeded()
        }

        guard keychain.hasStoredKey else {
            throw SecretKeeperError.vaultKeyMissing
        }

        let keyData = try await keychain.loadKey(reason: reason)
        let key = try VaultCrypto.key(from: keyData)
        let ciphertext = try Data(contentsOf: SecretKeeperPaths.vaultURL)
        let plaintext = try VaultCrypto.open(ciphertext, using: key)
        payload = try VaultCrypto.decodePayload(plaintext)
        masterKey = key
    }

    public func lock() {
        if let grants = payload?.grants {
            try? grantEngine.wipeAllMaterializations(grants: grants)
            payload?.grants = []
            try? persistUnlocked()
        }
        masterKey = nil
        payload = nil
    }

    // MARK: - Apps

    public func listApps() throws -> [VaultAppSummary] {
        try requireUnlocked().apps.map(VaultAppSummary.init)
    }

    public func apps() throws -> [VaultApp] {
        try requireUnlocked().apps
    }

    public func upsertApp(_ app: VaultApp) throws {
        var current = try requireUnlocked()
        if let index = current.apps.firstIndex(where: { $0.id == app.id }) {
            current.apps[index] = app
        } else {
            current.apps.append(app)
        }
        current.apps.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        payload = current
        try persist()
    }

    public func deleteApp(id: UUID) throws {
        var current = try requireUnlocked()
        // Revoke grants for this app
        let related = current.grants.filter { $0.appID == id }
        for grant in related {
            current.grants = try grantEngine.revoke(
                worktreePath: grant.worktreePath,
                grants: current.grants
            )
        }
        current.apps.removeAll { $0.id == id }
        payload = current
        try persist()
    }

    // MARK: - Grants

    public func listGrants() throws -> [GrantSummary] {
        let current = try requireUnlocked()
        return current.grants.map { grant in
            let name = current.apps.first(where: { $0.id == grant.appID })?.name ?? "Unknown"
            return GrantSummary(grant: grant, appName: name)
        }
    }

    public func grantEnv(
        worktreePath: String,
        app: String? = nil,
        force: Bool = false
    ) throws -> GrantResult {
        var current = try requireUnlocked()
        let resolved = try resolver.resolve(
            worktreePath: worktreePath,
            apps: current.apps,
            explicitApp: app
        )
        let (result, grants) = try grantEngine.grant(
            app: resolved,
            worktreePath: worktreePath,
            force: force,
            existingGrants: current.grants
        )
        current.grants = grants
        payload = current
        try persist()
        return result
    }

    public func revokeEnv(worktreePath: String) throws {
        var current = try requireUnlocked()
        let before = current.grants.count
        current.grants = try grantEngine.revoke(
            worktreePath: worktreePath,
            grants: current.grants
        )
        if current.grants.count == before {
            // Also try standardized path
            let standardized = (worktreePath as NSString).standardizingPath
            current.grants = try grantEngine.revoke(
                worktreePath: standardized,
                grants: current.grants
            )
            if current.grants.count == before {
                throw SecretKeeperError.grantNotFound(worktreePath)
            }
        }
        payload = current
        try persist()
    }

    // MARK: - Portable archive

    /// Seal every app + secret into a passphrase-encrypted archive.
    /// Grants are excluded — they are machine-local.
    public func exportArchive(passphrase: String) throws -> Data {
        let current = try requireUnlocked()
        return try VaultArchive.seal(apps: current.apps, passphrase: passphrase)
    }

    public func importArchive(
        _ fileData: Data,
        passphrase: String,
        mode: ImportMode
    ) throws -> ImportSummary {
        var current = try requireUnlocked()
        let archive = try VaultArchive.open(fileData, passphrase: passphrase)

        let (apps, summary) = VaultMerger.apply(
            incoming: archive.apps,
            to: current.apps,
            mode: mode
        )
        current.apps = apps

        // Replace mode can drop an app out from under a live grant; revoke those first
        // so no symlink keeps pointing at a materialized env file we no longer own.
        let liveAppIDs = Set(apps.map(\.id))
        for grant in current.grants where !liveAppIDs.contains(grant.appID) {
            current.grants = try grantEngine.revoke(
                worktreePath: grant.worktreePath,
                grants: current.grants
            )
        }

        payload = current
        try persist()
        return summary
    }

    // MARK: - Private

    private func requireUnlocked() throws -> VaultPayload {
        guard let payload else { throw SecretKeeperError.vaultLocked }
        return payload
    }

    private func persist() throws {
        try persistUnlocked()
    }

    private func persistUnlocked() throws {
        guard let masterKey, let payload else {
            throw SecretKeeperError.vaultLocked
        }
        try SecretKeeperPaths.ensureDirectoriesExist()
        let plaintext = try VaultCrypto.encodePayload(payload)
        let ciphertext = try VaultCrypto.seal(plaintext, using: masterKey)
        try ciphertext.write(to: SecretKeeperPaths.vaultURL, options: .atomic)
        try SecretKeeperPaths.setOwnerOnlyFilePermissions(at: SecretKeeperPaths.vaultURL)
    }
}
