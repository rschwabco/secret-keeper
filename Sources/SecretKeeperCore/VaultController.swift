import Foundation
import Combine

/// Observable façade used by the SwiftUI app and as the IPC request handler.
@MainActor
public final class VaultController: ObservableObject {
    @Published public private(set) var state: VaultState = .unavailable
    @Published public private(set) var apps: [VaultApp] = []
    @Published public private(set) var grants: [GrantSummary] = []
    @Published public private(set) var needsSetup: Bool = true
    @Published public var lastError: String?

    private let store = VaultStore()
    private var server: IPCServer?
    private var didBootstrap = false
    private var unlockInFlight = false

    public init() {}

    public func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        // IPC should come up even if vault setup fails, so MCP can report status.
        await startIPC()
        do {
            try await store.setupIfNeeded()
            await refreshState()
        } catch {
            lastError = error.localizedDescription
            await refreshState()
        }
    }

    public func unlock() async {
        // Exactly one evaluatePolicy per Unlock click. Drop overlapping callers so a
        // second LA session cannot systemCancel / appCancel the first.
        guard !unlockInFlight else { return }
        unlockInFlight = true
        defer { unlockInFlight = false }

        // Stay on MainActor for the LA prompt; VaultStore then decrypts using the
        // key loaded after that single evaluatePolicy (no second password sheet).
        do {
            try await store.unlock()
            lastError = nil
            await reload()
        } catch let error as SecretKeeperError
            where error == .authenticationCanceled || error == .authenticationInterrupted
        {
            // Soft cancel / focus-race message — vault stays fully locked.
            lastError = error.localizedDescription
            await refreshState()
        } catch {
            lastError = error.localizedDescription
            await refreshState()
        }
    }

    public func lock() async {
        await store.lock()
        apps = []
        grants = []
        await refreshState()
    }

    public func upsertApp(_ app: VaultApp) async {
        do {
            try await store.upsertApp(app)
            await reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func deleteApp(id: UUID) async {
        do {
            try await store.deleteApp(id: id)
            await reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func revokeGrant(worktreePath: String) async {
        do {
            try await store.revokeEnv(worktreePath: worktreePath)
            await reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Portable archive
    //
    // Deliberately UI-only. These are never reachable over MCP: the IPC surface must
    // stay incapable of emitting secret material, encrypted or not.

    /// Write a passphrase-encrypted archive of every app to `url` (0600).
    ///
    /// Re-authenticates even though the vault is already unlocked: this is the one
    /// action that puts every secret into a single portable file, so it should not be
    /// available to someone who walks up to an unlocked Mac.
    @discardableResult
    public func exportArchive(to url: URL, passphrase: String) async -> Bool {
        do {
            _ = try await KeychainStore.authenticateOwner(reason: "Export the Secret Keeper vault")
            let data = try await store.exportArchive(passphrase: passphrase)
            try data.write(to: url, options: [.atomic])
            try? SecretKeeperPaths.setOwnerOnlyFilePermissions(at: url)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    public func importArchive(
        from url: URL,
        passphrase: String,
        mode: ImportMode
    ) async -> ImportSummary? {
        do {
            let data = try Data(contentsOf: url)
            let summary = try await store.importArchive(data, passphrase: passphrase, mode: mode)
            lastError = nil
            await reload()
            return summary
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Cleartext header preview (format version, creation date, app count) — no passphrase.
    public func inspectArchive(at url: URL) -> VaultArchive.Header? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? VaultArchive.inspect(data)
    }

    public func handleIPC(_ request: IPCRequest) async -> IPCResponse {
        do {
            switch request.method {
            case .status:
                let needs = await store.needsSetup
                let current = await store.state
                return .success(
                    id: request.id,
                    status: IPCStatus(state: current, appRunning: true, needsSetup: needs)
                )
            case .listApps:
                let apps = try await store.listApps()
                return .success(id: request.id, apps: apps)
            case .listGrants:
                let grants = try await store.listGrants()
                return .success(id: request.id, grants: grants)
            case .grantEnv:
                guard let path = request.worktreePath, !path.isEmpty else {
                    throw SecretKeeperError.invalidRequest("worktreePath is required")
                }
                let result = try await store.grantEnv(
                    worktreePath: path,
                    app: request.app,
                    force: request.force ?? false
                )
                await reload()
                return .success(id: request.id, grant: IPCGrantResponse(result: result))
            case .revokeEnv:
                guard let path = request.worktreePath, !path.isEmpty else {
                    throw SecretKeeperError.invalidRequest("worktreePath is required")
                }
                try await store.revokeEnv(worktreePath: path)
                await reload()
                return .success(id: request.id)
            }
        } catch {
            return .failure(id: request.id, error: error.localizedDescription)
        }
    }

    private func reload() async {
        do {
            apps = try await store.apps()
            grants = try await store.listGrants()
            await refreshState()
        } catch {
            apps = []
            grants = []
            await refreshState()
        }
    }

    private func refreshState() async {
        state = await store.state
        needsSetup = await store.needsSetup
    }

    private func startIPC() async {
        let server = IPCServer { [weak self] request in
            guard let self else {
                return .failure(
                    id: request.id,
                    error: SecretKeeperError.appNotRunning.localizedDescription
                )
            }
            return await self.handleIPC(request)
        }
        do {
            try await server.start()
            self.server = server
        } catch {
            lastError = "Failed to start IPC: \(error.localizedDescription)"
        }
    }
}
