import Foundation
import LocalAuthentication
import Security

/// Keychain-backed vault key storage.
///
/// Uses `WhenUnlockedThisDeviceOnly` **without** a SecAccessControl ACL so the key
/// survives app reinstalls / ad-hoc re-signing. Unlock is gated by exactly one
/// LocalAuthentication `evaluatePolicy` (Touch ID / Apple Watch). The Keychain read
/// must not present a second sheet — after a successful unlock we rewrite the item so
/// the current app binary owns it (avoids the macOS “allow access” password prompt
/// that appears when an ad-hoc signature changes).
public struct KeychainStore: Sendable {
    private static let metaFileName = "vault.meta.json"
    public static let defaultUnlockReason = "Unlock Secret Keeper"
    private static let protectionTag = "accessibility-only+app-LA"

    public init() {}

    public var hasStoredKey: Bool {
        var query: [String: Any] = baseQuery()
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Do not attach an LAContext here. A parallel context (even with
        // interactionNotAllowed) can systemCancel (-4) an in-flight evaluatePolicy.

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
            || status == errSecInteractionNotAllowed
            || status == errSecAuthFailed
    }

    public func storeKey(_ keyData: Data) throws {
        try deleteKey()

        // Durable across reinstalls: no SecAccessControl / signature-bound ACL.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SecretKeeperPaths.keychainService,
            kSecAttrAccount as String: SecretKeeperPaths.keychainAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: keyData,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecretKeeperError.keychainFailure("SecItemAdd failed (\(status)).")
        }
        try writeMeta(
            requiresAppBiometricGate: true,
            protection: Self.protectionTag,
            ownerToken: Self.currentOwnerToken()
        )
    }

    /// Single-prompt unlock: one LA evaluatePolicy, then a Keychain read that must not
    /// show another auth sheet. Migrates legacy ACL / wrong-owner items after read.
    public func loadKey(reason: String = KeychainStore.defaultUnlockReason) async throws -> Data {
        let meta = readMeta()
        let requiresAppGate = meta?.requiresAppBiometricGate ?? true
        let unlockReason = reason.isEmpty ? Self.defaultUnlockReason : reason

        // Entire auth + read stays on the main actor so Watch/Touch ID UI can present,
        // and so we never "lose" the satisfied LAContext across actor hops.
        let data = try await Self.loadKeyOnMainActor(
            reason: unlockReason,
            requiresAppGate: requiresAppGate,
            reader: { context in
                try self.readSecretData(authenticationContext: context)
            }
        )

        // Drop biometric Keychain ACL / refresh app ownership so the next unlock is
        // LA-only (no second Keychain password sheet after re-sign/reinstall).
        try migrateToAccessibilityOnlyIfNeeded(data)
        return data
    }

    @MainActor
    private static func loadKeyOnMainActor(
        reason: String,
        requiresAppGate: Bool,
        reader: @MainActor (LAContext?) throws -> Data
    ) async throws -> Data {
        if requiresAppGate {
            let context = try await authenticateOwner(reason: reason)
            // Reuse the satisfied context for any legacy ACL item so Keychain does not
            // present a second biometric/password sheet. Accessibility-only items ignore it.
            return try reader(context)
        }
        return try reader(nil)
    }

    /// Present exactly one system unlock prompt (Touch ID and/or Apple Watch).
    @MainActor
    public static func authenticateOwner(reason: String) async throws -> LAContext {
        // First attempt. On systemCancel (-4) from a focus/menu race, settle and retry once.
        do {
            return try await evaluateUnlockPolicy(reason: reason)
        } catch SecretKeeperError.authenticationInterrupted {
            Self.log("systemCancel — retrying once after activation settle")
            try? await Task.sleep(nanoseconds: 250_000_000)
            return try await evaluateUnlockPolicy(reason: reason)
        }
    }

    @MainActor
    private static func evaluateUnlockPolicy(reason: String) async throws -> LAContext {
        let context = LAContext()
        context.localizedReason = reason
        context.localizedCancelTitle = "Cancel"
        context.interactionNotAllowed = false

        let policy = preferredUnlockPolicy(context: context)
        Self.log("evaluatePolicy rawValue=\(policy.rawValue)")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            context.evaluatePolicy(policy, localizedReason: reason) { success, error in
                if success {
                    continuation.resume()
                    return
                }
                continuation.resume(throwing: mapLocalAuthenticationError(error))
            }
        }

        return context
    }

    /// Map LA NSErrors. Note: `error as? LAError` is unreliable on current macOS —
    /// always inspect domain + code. Code -4 is **systemCancel**, not userCancel (-2).
    static func mapLocalAuthenticationError(_ error: Error?) -> SecretKeeperError {
        let ns = error as NSError?
        let domain = ns?.domain ?? "?"
        let code = ns?.code ?? 0
        let description = ns?.localizedDescription ?? "failed"
        let detail = "LA domain=\(domain) code=\(code) \(description)"
        Self.log(detail)

        let isLA = domain == LAErrorDomain || domain == "com.apple.LocalAuthentication"
        if isLA {
            switch code {
            case LAError.Code.userCancel.rawValue: // -2
                return .authenticationCanceled
            case LAError.Code.systemCancel.rawValue: // -4 — focus / menu / activation race
                return .authenticationInterrupted
            case LAError.Code.appCancel.rawValue: // -9 — another auth invalidated this one
                return .authenticationInterrupted
            case LAError.Code.authenticationFailed.rawValue:
                return .authenticationFailed(detail)
            case LAError.Code.biometryNotAvailable.rawValue,
                 LAError.Code.biometryNotEnrolled.rawValue,
                 LAError.Code.biometryLockout.rawValue:
                return .biometricRequired
            default:
                break
            }
        }
        return .authenticationFailed(detail)
    }

    /// Touch ID / Face ID **with** Apple Watch. Never `.deviceOwnerAuthentication`
    /// (that policy adds a password fallback sheet).
    static func preferredUnlockPolicy(context: LAContext) -> LAPolicy {
        var error: NSError?

        if #available(macOS 15.0, *) {
            if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometricsOrCompanion, error: &error) {
                return .deviceOwnerAuthenticationWithBiometricsOrCompanion
            }
            error = nil
            if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithCompanion, error: &error) {
                return .deviceOwnerAuthenticationWithCompanion
            }
            error = nil
        } else {
            if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometricsOrWatch, error: &error) {
                return .deviceOwnerAuthenticationWithBiometricsOrWatch
            }
            error = nil
            if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithWatch, error: &error) {
                return .deviceOwnerAuthenticationWithWatch
            }
            error = nil
        }

        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            return .deviceOwnerAuthenticationWithBiometrics
        }

        // Last resort still avoids password-capable deviceOwnerAuthentication when
        // companion APIs exist but canEvaluate failed transiently — try companion raw.
        if #available(macOS 15.0, *) {
            return .deviceOwnerAuthenticationWithBiometricsOrCompanion
        } else {
            return .deviceOwnerAuthenticationWithBiometricsOrWatch
        }
    }

    public func deleteKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretKeeperError.keychainFailure("SecItemDelete failed (\(status))")
        }
    }

    // MARK: - Private Keychain I/O

    private func readSecretData(authenticationContext: LAContext?) throws -> Data {
        // Happy path: accessibility-only item, no Keychain UI.
        if let data = try? copyMatchingData(authenticationContext: nil, allowInteraction: false) {
            return data
        }
        // Legacy biometric ACL: reuse the already-satisfied LAContext without a new sheet.
        if let authenticationContext {
            if let data = try? copyMatchingData(
                authenticationContext: authenticationContext,
                allowInteraction: false
            ) {
                return data
            }
            // Biometric SecAccessControl only — same context should satisfy without a
            // second password dialog. Never fall back to a nil-context interactive read
            // (that is the macOS Keychain "allow access" password sheet).
            return try copyMatchingData(
                authenticationContext: authenticationContext,
                allowInteraction: true
            )
        }
        throw SecretKeeperError.keychainFailure(
            "Vault key is unreadable after authentication (status blocked without Keychain UI)."
        )
    }

    private func copyMatchingData(authenticationContext: LAContext?, allowInteraction: Bool) throws -> Data {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        if let authenticationContext {
            // Never mutate interactionNotAllowed on a satisfied context — that can
            // invalidate the LA session. Pass it through as-is for legacy ACL items.
            query[kSecUseAuthenticationContext as String] = authenticationContext
            _ = allowInteraction
        } else if !allowInteraction {
            // Fresh context only, and only after evaluatePolicy has finished.
            // Blocks Keychain UI without touching the auth context we just used.
            let probe = LAContext()
            probe.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = probe
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status == errSecItemNotFound {
                throw SecretKeeperError.notInitialized
            }
            if status == errSecUserCanceled {
                throw SecretKeeperError.authenticationCanceled
            }
            if status == errSecAuthFailed || status == errSecInteractionNotAllowed {
                throw SecretKeeperError.keychainFailure(
                    "Keychain read needed extra auth (status \(status)). The vault key will be migrated after a successful unlock."
                )
            }
            throw SecretKeeperError.keychainFailure("SecItemCopyMatching failed (\(status))")
        }
        return data
    }

    private func migrateToAccessibilityOnlyIfNeeded(_ data: Data) throws {
        let token = Self.currentOwnerToken()
        let meta = readMeta()
        let alreadyCurrent = meta?.protection == Self.protectionTag && meta?.ownerToken == token
        let hasACL = itemHasAccessControl()

        guard !alreadyCurrent || hasACL else { return }

        Self.log("Migrating vault key to accessibility-only ownership token=\(token) hasACL=\(hasACL)")
        try storeKey(data)
    }

    private func itemHasAccessControl() -> Bool {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // No LAContext — avoid interfering with any auth session.

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let attrs = item as? [String: Any] else {
            return false
        }
        return attrs[kSecAttrAccessControl as String] != nil
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SecretKeeperPaths.keychainService,
            kSecAttrAccount as String: SecretKeeperPaths.keychainAccount,
        ]
    }

    // MARK: - Sidecar meta

    private struct VaultKeyMeta: Codable {
        var requiresAppBiometricGate: Bool
        var protection: String
        var ownerToken: String?
    }

    private var metaURL: URL {
        SecretKeeperPaths.applicationSupportDirectory.appendingPathComponent(Self.metaFileName)
    }

    private func writeMeta(
        requiresAppBiometricGate: Bool,
        protection: String,
        ownerToken: String
    ) throws {
        try SecretKeeperPaths.ensureDirectoriesExist()
        let meta = VaultKeyMeta(
            requiresAppBiometricGate: requiresAppBiometricGate,
            protection: protection,
            ownerToken: ownerToken
        )
        let data = try JSONEncoder().encode(meta)
        try data.write(to: metaURL, options: .atomic)
        try SecretKeeperPaths.setOwnerOnlyFilePermissions(at: metaURL)

        UserDefaults.standard.set(requiresAppBiometricGate, forKey: "secretKeeper.requiresAppBiometricGate")
        UserDefaults.standard.set(protection, forKey: "secretKeeper.keyProtection")
        UserDefaults.standard.set(ownerToken, forKey: "secretKeeper.keyOwnerToken")
    }

    private func readMeta() -> VaultKeyMeta? {
        if let data = try? Data(contentsOf: metaURL),
           let meta = try? JSONDecoder().decode(VaultKeyMeta.self, from: data) {
            return meta
        }
        if UserDefaults.standard.object(forKey: "secretKeeper.requiresAppBiometricGate") != nil {
            return VaultKeyMeta(
                requiresAppBiometricGate: UserDefaults.standard.bool(forKey: "secretKeeper.requiresAppBiometricGate"),
                protection: UserDefaults.standard.string(forKey: "secretKeeper.keyProtection") ?? "unknown",
                ownerToken: UserDefaults.standard.string(forKey: "secretKeeper.keyOwnerToken")
            )
        }
        return VaultKeyMeta(requiresAppBiometricGate: true, protection: "default", ownerToken: nil)
    }

    /// Changes whenever the app binary is replaced (ad-hoc re-sign / reinstall).
    static func currentOwnerToken() -> String {
        let path = Bundle.main.executablePath
            ?? CommandLine.arguments.first
            ?? "unknown"
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        return "\(path)|\(Int(modified))"
    }

    private static func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = SecretKeeperPaths.applicationSupportDirectory.appendingPathComponent("debug.log")
        try? SecretKeeperPaths.ensureDirectoriesExist()
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            if let data = line.data(using: .utf8) {
                handle.write(data)
            }
        } else {
            try? line.data(using: .utf8)?.write(to: url)
        }
    }
}
