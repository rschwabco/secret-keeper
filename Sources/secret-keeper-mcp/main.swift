import Foundation
import MCP
import SecretKeeperCore

@main
struct SecretKeeperMCP {
    static func main() async {
        let server = Server(
            name: "secret-keeper",
            version: "1.0.0",
            capabilities: .init(
                tools: .init(listChanged: false)
            )
        )

        let client = IPCClient()

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: Self.tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            await Self.callTool(name: params.name, arguments: params.arguments, client: client)
        }

        let transport = StdioTransport()
        try? await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    static let tools: [Tool] = [
        Tool(
            name: "secret_keeper_status",
            description: "Check whether Secret Keeper is running and whether the vault is unlocked.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ])
        ),
        Tool(
            name: "list_apps",
            description: "List registered apps (name, root folder, secret key names). Never returns secret values.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ])
        ),
        Tool(
            name: "grant_env",
            description: "Materialize secrets for the app matching a worktree and symlink worktree/.env.local to the managed env file. Does not return secret values.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "worktree_path": .object([
                        "type": .string("string"),
                        "description": .string("Absolute path to the worktree directory"),
                    ]),
                    "app": .object([
                        "type": .string("string"),
                        "description": .string("Optional app name or id if auto-resolve is ambiguous"),
                    ]),
                    "force": .object([
                        "type": .string("boolean"),
                        "description": .string("Replace an existing regular file or non-Secret-Keeper symlink at .env.local (Secret Keeper symlinks, including dangling ones, are replaced without force)"),
                    ]),
                ]),
                "required": .array([.string("worktree_path")]),
            ])
        ),
        Tool(
            name: "revoke_env",
            description: "Remove the Secret Keeper grant and .env.local symlink for a worktree.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "worktree_path": .object([
                        "type": .string("string"),
                        "description": .string("Absolute path to the worktree directory"),
                    ]),
                ]),
                "required": .array([.string("worktree_path")]),
            ])
        ),
        Tool(
            name: "list_grants",
            description: "List active worktree → app grants. Never returns secret values.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ])
        ),
    ]

    static func textResult(_ text: String, isError: Bool = false) -> CallTool.Result {
        .init(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            isError: isError
        )
    }

    static func callTool(
        name: String,
        arguments: [String: Value]?,
        client: IPCClient
    ) async -> CallTool.Result {
        do {
            switch name {
            case "secret_keeper_status":
                let response = try await client.send(IPCRequest(method: .status))
                try throwIfFailed(response)
                let status = response.status
                let text = """
                app_running: \(status?.appRunning ?? false)
                state: \(status?.state.rawValue ?? "unknown")
                needs_setup: \(status?.needsSetup ?? false)
                """
                return textResult(text)

            case "list_apps":
                let response = try await client.send(IPCRequest(method: .listApps))
                try throwIfFailed(response)
                let apps = response.apps ?? []
                if apps.isEmpty {
                    return textResult("No apps registered. Add an app in Secret Keeper.")
                }
                let lines = apps.map { app in
                    let keys = app.secretKeys.isEmpty ? "(no keys)" : app.secretKeys.joined(separator: ", ")
                    return "- \(app.name)\n  root: \(app.rootFolder)\n  keys: \(keys)"
                }
                return textResult(lines.joined(separator: "\n"))

            case "grant_env":
                guard let path = arguments?["worktree_path"]?.stringValue, !path.isEmpty else {
                    return textResult("worktree_path is required", isError: true)
                }
                let app = arguments?["app"]?.stringValue
                let force = arguments?["force"]?.boolValue ?? false
                let response = try await client.send(
                    IPCRequest(method: .grantEnv, worktreePath: path, app: app, force: force)
                )
                try throwIfFailed(response)
                guard let grant = response.grant else {
                    return textResult("Grant succeeded but response was empty", isError: true)
                }
                let text = """
                Granted env for app "\(grant.appName)"
                worktree: \(grant.worktreePath)
                symlink: \(grant.symlinkPath) -> \(grant.envPath)
                """
                return textResult(text)

            case "revoke_env":
                guard let path = arguments?["worktree_path"]?.stringValue, !path.isEmpty else {
                    return textResult("worktree_path is required", isError: true)
                }
                let response = try await client.send(IPCRequest(method: .revokeEnv, worktreePath: path))
                try throwIfFailed(response)
                return textResult("Revoked grant for \(path)")

            case "list_grants":
                let response = try await client.send(IPCRequest(method: .listGrants))
                try throwIfFailed(response)
                let grants = response.grants ?? []
                if grants.isEmpty {
                    return textResult("No active grants.")
                }
                let lines = grants.map { grant in
                    "- \(grant.appName) → \(grant.worktreePath)"
                }
                return textResult(lines.joined(separator: "\n"))

            default:
                return textResult("Unknown tool: \(name)", isError: true)
            }
        } catch {
            return textResult(error.localizedDescription, isError: true)
        }
    }

    static func throwIfFailed(_ response: IPCResponse) throws {
        if !response.ok {
            throw SecretKeeperError.ipcFailure(response.error ?? "Unknown IPC error")
        }
    }
}
