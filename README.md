# Secret Keeper

Native macOS vault for project secrets, unlocked with Touch ID / Face ID / Apple Watch. Coding agents — Cursor, Claude Code, Claude Desktop, Codex — request a `.env.local` symlink for a worktree via a local MCP server, and secret **values are never returned** over MCP.

## How it works

1. Register an **App** in Secret Keeper: a name, a root folder on disk, and `KEY=VALUE` secrets.
2. Unlock the menu-bar app with biometrics (vault key lives in the Keychain with a biometric ACL; vault blob is AES-GCM encrypted under `~/Library/Application Support/SecretKeeper/`).
3. An agent calls MCP `grant_env` with a worktree path. Secret Keeper resolves the matching App (folder prefix or git worktree → main checkout), writes a `0600` env file under Application Support, and symlinks `<worktree>/.env.local` to it.
4. **Lock** wipes materialized env files and removes those symlinks.

```
Cursor / Claude Code / Codex  --stdio MCP-->  secret-keeper-mcp  --unix socket-->  Secret Keeper.app
                                                                                   |
                                                                                   +--> Keychain (biometric)
                                                                                   +--> vault.dat (AES-GCM)
                                                                                   +--> grants/*.env (session)
                                                                                   +--> worktree/.env.local  (symlink)
```

## Moving a vault to another Mac

Secret Keeper's master key is device-bound (Keychain, `WhenUnlockedThisDeviceOnly`, regenerated per install), so it can never travel. To move secrets, export a **passphrase-encrypted archive** and import it on the other Mac.

**Export** (toolbar `⋯` → Export Vault…) re-prompts for biometrics, then writes a single `.skeeper` file:

- AES-256-GCM over the whole payload, key derived by PBKDF2-HMAC-SHA256, 600,000 iterations, fresh 32-byte salt per export.
- The cleartext header carries only format/KDF parameters, a timestamp, and an app count. App names, key names, and values are all inside the ciphertext.
- The KDF parameters are bound into the ciphertext as GCM additional authenticated data, so editing the header (for example, dropping the iteration count) makes the file undecryptable rather than weaker.
- Grants are **not** exported — they are machine-local worktree symlinks and mean nothing elsewhere.
- The file is written `0600`.

**Import** (toolbar `⋯` → Import Vault…) previews the header before asking for the passphrase, then folds the archive in:

| Mode | Effect |
| --- | --- |
| `Merge` | Adds new apps and keys. On a key collision the archive wins; keys only present locally are kept. |
| `Replace` | The archive's apps become the whole list. Anything not in the archive is dropped, and its grants are revoked. |

Apps match on id first, then case-insensitive name, so the same project registered by hand on both Macs merges instead of duplicating. A matched app keeps its **local** id, so existing grants stay valid. Root folders come from the source Mac and usually will not exist on the target — the import summary lists those apps so you can repoint them.

The passphrase is the only thing protecting the archive and cannot be recovered. Send the file and the passphrase over different channels.

Export and import are **UI-only and biometric-gated**. They are deliberately absent from the MCP surface: an agent must never be able to pull the whole vault out in one call, encrypted or not.

## Requirements

- macOS 14 or newer (Apple silicon or Intel)
- Touch ID, Face ID, or Apple Watch enrolled for unlock
- Xcode 16+ / Swift 6 — only needed if you build from source

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/rschwabco/secret-keeper/main/Scripts/install.sh | bash
```

The installer:

1. Fetches the latest release manifest, downloads the universal build, and **verifies its SHA-256** before unpacking. A mismatch aborts the install.
2. Installs `Secret Keeper.app` into `/Applications`, or `~/Applications` when `/Applications` is not writable — updates need a writable install directory.
3. Falls back to building from source when no release asset is available and Swift is installed.
4. Adds a `secret-keeper` entry to every MCP client it finds — Cursor, Claude Code, Claude Desktop, and Codex — backing up each config first.
5. Registers a launchd agent that keeps the app current.

| Flag | Effect |
| --- | --- |
| `--prefix <dir>` | Install somewhere other than `/Applications` |
| `--from-source` | Build from source instead of downloading a release |
| `--local` | Build from the current checkout |
| `--release-only` | Fail instead of falling back to a source build |
| `--channel edge` | Track `main` instead of tagged releases |
| `--no-mcp-config` | Leave MCP client config files alone |
| `--no-auto-update` | Skip the background update agent |
| `--login-item` | Also start Secret Keeper at login |

Then open the app, add an app entry (name, root folder, `KEY=VALUE` secrets), unlock with Touch ID, and restart your MCP client so it picks up the new server.

## Updates

Pushing to the repo is what ships an update. `.github/workflows/release.yml` builds a universal bundle, verifies it, and publishes it:

- **Tag `v1.2.3`** → a stable release. This is what the default `stable` channel tracks.
- **Push to `main`** → refreshes the rolling `edge` prerelease, for anyone on `--channel edge`.

Installed copies run `secret-keeper-update` from a launchd agent. Each run:

1. Checks the channel manifest at most once a day (the agent ticks every 6h so a pending update lands promptly).
2. Downloads the new bundle, **verifies its SHA-256**, checks its signature, and stages it.
3. Applies it **only when the vault is idle** — locked, with no materialized grants.

That last step matters: replacing the app locks the vault, which wipes every materialized env file and removes the `.env.local` symlinks it created. So an update never yanks a live `.env.local` out from under a running agent. A staged update waits, and installs the moment you lock the vault or quit the app. Active grants block an install indefinitely; an unlocked-but-idle vault blocks it for at most 7 days, so a wedged status probe can't strip an install forever.

Check manually from the menu bar (**Check for Updates…**) or:

```bash
"$HOME/Library/Application Support/SecretKeeper/updater/secret-keeper-update" --user-initiated
```

Useful flags: `--check` (report only), `--force` (install even if the vault is unlocked), `--channel edge`.

Config lives at `~/Library/Application Support/SecretKeeper/updater/config.json`; the log is `~/Library/Logs/SecretKeeper/updater.log`. To stop automatic updates:

```bash
launchctl bootout "gui/$(id -u)/com.secretkeeper.updater"
rm ~/Library/LaunchAgents/com.secretkeeper.updater.plist
```

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/rschwabco/secret-keeper/main/Scripts/uninstall.sh | bash
```

Removes the app, the update agent, and MCP client entries. **Your vault is kept** so a reinstall picks it up again. Add `--purge` to also delete the encrypted vault and its Keychain key — that is irreversible and prompts before it acts.

## Build from source

```bash
./Scripts/package-app.sh          # assembles dist/Secret Keeper.app
./Scripts/install.sh --local      # builds this checkout and installs it
```

Dev run without packaging:

```bash
swift run SecretKeeperApp
```

## Releasing

```bash
echo "1.2.3" > VERSION
git commit -am "Release 1.2.3"
git tag v1.2.3
git push origin main --tags
```

CI fails the release if the tag does not match `VERSION`. Every release runs `swift test`, verifies the bundle is universal and correctly signed, and rehearses the client-side unpack before publishing — a broken asset never reaches anyone's Mac.

## MCP config

The installer wires this up for every client it finds, backing up each config first. Do it by hand only if you passed `--no-mcp-config`, or for a client not listed here.

| Client | Config file | Format |
| --- | --- | --- |
| Cursor | `~/.cursor/mcp.json` | JSON — `mcpServers` |
| Claude Code | `~/.claude.json`, written via `claude mcp add-json … --scope user` | JSON — `mcpServers` |
| Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` | JSON — `mcpServers` |
| Codex | `~/.codex/config.toml` | TOML — `[mcp_servers.*]` |

Prefer `command` + `args` over putting the space-containing binary path in a single command string. Some clients (including Cursor) split `command` on whitespace, which turns `/Applications/Secret Keeper.app/...` into executable `/Applications/Secret` and fails with `ENOENT`.

Use a shell wrapper with `exec` so the path stays intact and the shell replaces itself with the binary (stdio stays clean). Do **not** use a space-free symlink into the `.app` (that can break bundle path resolution).

JSON clients — Cursor, Claude Code, Claude Desktop:

```json
{
  "mcpServers": {
    "secret-keeper": {
      "type": "stdio",
      "command": "/bin/sh",
      "args": ["-c", "exec '/Applications/Secret Keeper.app/Contents/MacOS/secret-keeper-mcp'"]
    }
  }
}
```

Codex, in `~/.codex/config.toml`:

```toml
[mcp_servers.secret-keeper]
command = "/bin/sh"
args = ["-c", "exec '/Applications/Secret Keeper.app/Contents/MacOS/secret-keeper-mcp'"]
```

Restart the client after editing, and keep Secret Keeper running and **unlocked** while agents need grants.

## MCP tools

| Tool | Purpose |
| --- | --- |
| `secret_keeper_status` | Running / locked / unlocked |
| `list_apps` | App names, root folders, secret **key names** only |
| `grant_env` | `{ worktree_path, app?, force? }` → symlink `.env.local` |
| `revoke_env` | `{ worktree_path }` → remove grant |
| `list_grants` | Active worktree → app mappings |

Example agent call: grant env for the current worktree after unlocking the app.

```
grant_env(worktree_path: "/Users/you/dev/myapp-feature-wt")
```

If `.env.local` already exists and is not a Secret Keeper symlink, pass `force: true` to replace it.

## Security notes

- Vault ciphertext alone cannot be decrypted without the Keychain key.
- The Keychain item uses `biometryCurrentSet` + `WhenUnlockedThisDeviceOnly`.
- MCP never returns secret values — only paths and metadata.
- Unix socket: `~/Library/Application Support/SecretKeeper/secret-keeper.sock` (`0600`).
- Stays unlocked until you explicitly Lock (menu/button) or quit the app.
- Biometric enrollment changes invalidate the vault key (`biometryCurrentSet`).
- Updates are verified by SHA-256 against the release manifest before anything is unpacked; a mismatch aborts and nothing is staged. A manifest with no checksum is refused outright.
- Replacing the app bundle does not cost you the vault: the Keychain item is not bound to the app's code signature, so an ad-hoc re-signed update still opens it.
- The updater only ever quits the app it is updating — it matches the running process by full install path, not by bundle name.
- Exported archives are protected only by the passphrase you choose — a weak passphrase is the weak link, so a minimum length is enforced and a strong one can be generated.

## Tests

```bash
swift test
```

## Layout

```
Sources/SecretKeeperCore/       # crypto, vault, archive export/import, grants, IPC
Sources/SecretKeeperApp/        # SwiftUI menu-bar app
Sources/secret-keeper-mcp/      # stdio MCP server
Scripts/package-app.sh          # assemble + version-stamp .app bundle into dist/
Scripts/install.sh              # installer (release download, source fallback)
Scripts/secret-keeper-update    # updater run by launchd and by the menu bar
Scripts/uninstall.sh            # uninstaller
.github/workflows/release.yml   # builds and publishes the stable / edge channels
VERSION                         # marketing version; CI checks the tag against it
```
