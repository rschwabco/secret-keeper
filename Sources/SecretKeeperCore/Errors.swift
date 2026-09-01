import Foundation

public enum SecretKeeperError: Error, LocalizedError, Sendable, Equatable {
    case vaultLocked
    case vaultUnavailable(String)
    case appNotRunning
    case appNotFound(String)
    case ambiguousAppMatch([String])
    case worktreeNotFound(String)
    case existingEnvFile(String)
    case grantNotFound(String)
    case cryptoFailure(String)
    case keychainFailure(String)
    case ipcFailure(String)
    case invalidRequest(String)
    case biometricRequired
    case authenticationCanceled
    case authenticationInterrupted
    case authenticationFailed(String)
    case notInitialized
    case vaultKeyMissing
    case archiveFormatInvalid(String)
    case archiveUnsupportedVersion(Int)
    case archiveAuthenticationFailed
    case archivePassphraseTooShort(Int)
    case archivePassphraseMismatch

    public var errorDescription: String? {
        switch self {
        case .vaultLocked:
            return "Vault is locked. Unlock Secret Keeper with Touch ID / Face ID / Apple Watch."
        case .vaultUnavailable(let message):
            return "Vault unavailable: \(message)"
        case .appNotRunning:
            return "Secret Keeper is not running. Open the Secret Keeper app and unlock it."
        case .appNotFound(let detail):
            return "No registered app matches: \(detail)"
        case .ambiguousAppMatch(let names):
            return "Multiple apps match this worktree (\(names.joined(separator: ", "))). Pass app explicitly."
        case .worktreeNotFound(let path):
            return "Worktree path is not a directory: \(path)"
        case .existingEnvFile(let path):
            return "\(path) already exists and is not a Secret Keeper symlink. Pass force=true to replace it."
        case .grantNotFound(let path):
            return "No active grant for worktree: \(path)"
        case .cryptoFailure(let message):
            return "Cryptography error: \(message)"
        case .keychainFailure(let message):
            return "Keychain error: \(message)"
        case .ipcFailure(let message):
            return "IPC error: \(message)"
        case .invalidRequest(let message):
            return "Invalid request: \(message)"
        case .biometricRequired:
            return "Authentication is required to unlock the vault (Touch ID, Face ID, or Apple Watch)."
        case .authenticationCanceled:
            return "Unlock canceled."
        case .authenticationInterrupted:
            return "Unlock was interrupted before it could finish. Bring the Secret Keeper window to the front and try again — if biometrics cannot run on this Mac, the prompt falls back to your login password."
        case .authenticationFailed(let detail):
            return "Unlock failed: \(detail)"
        case .notInitialized:
            return "Vault has not been created yet. Open Secret Keeper to finish setup."
        case .vaultKeyMissing:
            return "Vault data was found but the unlock key is missing from the Keychain. Reinstalling the app should not delete secrets — if this persists, the Keychain item may have been removed manually."
        case .archiveFormatInvalid(let detail):
            return "Archive is not readable: \(detail)"
        case .archiveUnsupportedVersion(let version):
            return "This archive was written by a newer Secret Keeper (format v\(version)). Update Secret Keeper to import it."
        case .archiveAuthenticationFailed:
            return "Could not decrypt the archive. The passphrase is wrong, or the file has been modified."
        case .archivePassphraseTooShort(let minimum):
            return "Archive passphrase must be at least \(minimum) characters."
        case .archivePassphraseMismatch:
            return "The two passphrases do not match."
        }
    }
}
