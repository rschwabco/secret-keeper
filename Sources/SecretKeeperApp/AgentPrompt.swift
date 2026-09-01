import Foundation
import AppKit

enum AgentPrompt: Sendable {
    static let mcpBinary = "/Applications/Secret Keeper.app/Contents/MacOS/secret-keeper-mcp"

    /// Shell-wrapped launch for clients that split `command` on whitespace.
    static let mcpShellCommand = "/bin/sh"
    static let mcpShellArgs = #"["-c", "exec '/Applications/Secret Keeper.app/Contents/MacOS/secret-keeper-mcp'"]"#

    static var text: String {
        """
        Use Secret Keeper for env secrets in this worktree. Do not ask me to paste secrets into chat, and never ask MCP for secret values.

        Setup (once per machine):
        1. Ensure Secret Keeper is installed at /Applications/Secret Keeper.app and is running.
        2. Unlock the vault (Touch ID / Face ID / Apple Watch) and keep it unlocked while you need grants.
        3. Register a local stdio MCP server in whatever MCP client you are using (Cursor, Claude Code, Claude Desktop, Codex, Windsurf, VS Code Copilot Chat, etc.). The config file location depends on the client — look up that client’s MCP server settings.
        4. Prefer `command` + `args` over putting the space-containing binary path in a single command string. If the MCP client splits `command` on spaces (Cursor does), register via a shell wrapper so the path stays intact:

           command: \(mcpShellCommand)
           args: \(mcpShellArgs)

           Example shape used by many clients:

           {
             "mcpServers": {
               "secret-keeper": {
                 "type": "stdio",
                 "command": "\(mcpShellCommand)",
                 "args": \(mcpShellArgs)
               }
             }
           }

           Codex uses TOML instead, in ~/.codex/config.toml:

           [mcp_servers.secret-keeper]
           command = "\(mcpShellCommand)"
           args = \(mcpShellArgs)

           Do not use a space-free symlink into the .app (that can break bundle path resolution). `exec` replaces the shell with the MCP binary so stdio stays clean.

           Binary path (for reference only): \(mcpBinary)

        5. Reload / restart MCP servers in your client after saving.

        How to use:
        - Call secret_keeper_status. If locked or not running, ask me to unlock/open Secret Keeper — do not invent secrets.
        - Call list_apps for registered apps (names, root folders, key names only). Values are never returned.
        - Call grant_env with worktree_path set to this worktree’s absolute path. Secret Keeper resolves the matching App (by folder / git worktree) and creates <worktree>/.env.local as a symlink to a managed env file.
        - If .env.local already exists and is not a Secret Keeper symlink, pass force: true only after confirming with me.
        - Use list_grants / revoke_env as needed. Never print, request, or echo secret values.

        MCP tools: secret_keeper_status, list_apps, grant_env, revoke_env, list_grants.
        """
    }

    @MainActor
    @discardableResult
    static func copyToPasteboard() -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
