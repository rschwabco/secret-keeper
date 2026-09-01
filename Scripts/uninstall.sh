#!/usr/bin/env bash
#
# Secret Keeper uninstaller.
#
#   curl -fsSL https://raw.githubusercontent.com/rschwabco/secret-keeper/main/Scripts/uninstall.sh | bash
#
# Removes the app, the update agent, and MCP client entries. Your vault is kept
# unless you pass --purge.
#
set -uo pipefail

APP_NAME="Secret Keeper.app"
LABEL="com.secretkeeper.updater"
LOGIN_LABEL="com.secretkeeper.app"
SUPPORT_DIR="$HOME/Library/Application Support/SecretKeeper"
LOG_DIR="$HOME/Library/Logs/SecretKeeper"
AGENT_DIR="$HOME/Library/LaunchAgents"
KEYCHAIN_SERVICE="com.secretkeeper.vault"

PURGE=0
ASSUME_YES=0

BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; RESET=""
if [ -t 1 ]; then
  BOLD="$(printf '\033[1m')"; DIM="$(printf '\033[2m')"
  RED="$(printf '\033[31m')"; GREEN="$(printf '\033[32m')"
  YELLOW="$(printf '\033[33m')"; RESET="$(printf '\033[0m')"
fi
info() { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
note() { printf '    %s%s%s\n' "$DIM" "$*" "$RESET"; }

usage() {
  cat <<'USAGE'
Usage: uninstall.sh [options]

  --purge   Also delete the encrypted vault, its Keychain key, and all grants.
            This destroys every secret stored in Secret Keeper. Not reversible.
  --yes     Do not prompt for confirmation.
  -h        Show this help.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --purge) PURGE=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'uninstall.sh: unknown option %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

# The installer records where it put the app, which may not be one of the two
# standard locations (install.sh --prefix).
CONFIG_APP=""
if [ -f "$SUPPORT_DIR/updater/config.json" ]; then
  CONFIG_APP="$(sed -n 's/.*"app_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$SUPPORT_DIR/updater/config.json" | head -1)"
fi

# ------------------------------------------------------------- stop the app
info "Stopping Secret Keeper"
if pgrep -f "$APP_NAME/Contents/MacOS/SecretKeeperApp" >/dev/null 2>&1; then
  # A clean quit locks the vault, which wipes materialized env files and the
  # .env.local symlinks it created.
  osascript -e 'tell application "Secret Keeper" to quit' >/dev/null 2>&1
  waited=0
  while pgrep -f "$APP_NAME/Contents/MacOS/SecretKeeperApp" >/dev/null 2>&1 && [ "$waited" -lt 10 ]; do
    sleep 1; waited=$((waited + 1))
  done
  pkill -TERM -f "$APP_NAME/Contents/MacOS/SecretKeeperApp" >/dev/null 2>&1
  ok "quit"
else
  note "not running"
fi

# ------------------------------------------------------------- launchd agents
info "Removing background agents"
for label in "$LABEL" "$LOGIN_LABEL"; do
  launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1
  launchctl unload -w "$AGENT_DIR/$label.plist" >/dev/null 2>&1
  if [ -f "$AGENT_DIR/$label.plist" ]; then
    rm -f "$AGENT_DIR/$label.plist" && ok "removed $label"
  fi
done

# ------------------------------------------------------------------ app bundle
info "Removing the app"
removed=0
seen=""
for candidate in "$CONFIG_APP" "/Applications/$APP_NAME" "$HOME/Applications/$APP_NAME"; do
  [ -n "$candidate" ] || continue
  case "$seen" in *"|$candidate|"*) continue ;; esac
  seen="$seen|$candidate|"
  [ -d "$candidate" ] || continue
  if rm -rf "$candidate" 2>/dev/null; then
    ok "removed $candidate"; removed=1
  else
    warn "could not remove $candidate (permission denied)"
  fi
done
[ "$removed" -eq 0 ] && note "no app bundle found"

# -------------------------------------------------------------- MCP client entries
info "Removing MCP client entries"
for file in "$HOME/.cursor/mcp.json" \
            "$HOME/Library/Application Support/Claude/claude_desktop_config.json"; do
  [ -f "$file" ] || continue
  if plutil -extract 'mcpServers.secret-keeper' json -o /dev/null "$file" >/dev/null 2>&1; then
    cp -f "$file" "$file.secret-keeper.bak" 2>/dev/null
    if plutil -remove 'mcpServers.secret-keeper' "$file" >/dev/null 2>&1 \
      && plutil -convert json -r -o "$file" "$file" >/dev/null 2>&1; then
      ok "cleaned $file"
    else
      cp -f "$file.secret-keeper.bak" "$file" 2>/dev/null
      warn "could not edit $file — remove the secret-keeper entry by hand"
    fi
  fi
done
if command -v claude >/dev/null 2>&1; then
  claude mcp remove secret-keeper --scope user >/dev/null 2>&1 && ok "cleaned Claude Code"
fi

# Codex stores MCP servers as TOML tables.
CODEX="$HOME/.codex/config.toml"
if [ -f "$CODEX" ] && grep -q '^\[mcp_servers\.secret-keeper\]' "$CODEX" 2>/dev/null; then
  cp -f "$CODEX" "$CODEX.secret-keeper.bak" 2>/dev/null
  tmp="$(mktemp -t sk-codex)" || tmp=""
  if [ -n "$tmp" ] && awk '
      /^\[mcp_servers\.secret-keeper\]/  { skip = 1; next }
      /^\[mcp_servers\.secret-keeper\./  { skip = 1; next }
      /^\[/                              { skip = 0 }
      !skip                               { print }
    ' "$CODEX" > "$tmp" \
    && [ "$(grep -c '^\[' "$tmp")" -ge "$(( $(grep -c '^\[' "$CODEX") - 1 ))" ] \
    && mv -f "$tmp" "$CODEX"; then
    ok "cleaned $CODEX"
  else
    rm -f "$tmp" 2>/dev/null
    warn "could not edit $CODEX — remove the [mcp_servers.secret-keeper] table by hand"
  fi
fi

# ------------------------------------------------------------------ vault data
if [ "$PURGE" -eq 1 ]; then
  if [ "$ASSUME_YES" -eq 0 ]; then
    printf '\n%s%sThis deletes your encrypted vault and its Keychain key.%s\n' "$BOLD" "$RED" "$RESET"
    printf 'Every secret stored in Secret Keeper will be unrecoverable.\n'
    printf 'Type %sDELETE%s to continue: ' "$BOLD" "$RESET"
    read -r reply < /dev/tty || reply=""
    if [ "$reply" != "DELETE" ]; then
      printf '\nAborted — your vault was left in place.\n'
      printf 'Everything else was removed. Vault data: %s\n' "$SUPPORT_DIR"
      exit 0
    fi
  fi
  info "Deleting vault data"
  security delete-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1 \
    && ok "removed the Keychain key" || note "no Keychain key found"
  rm -rf "$SUPPORT_DIR" 2>/dev/null && ok "removed $SUPPORT_DIR"
  rm -rf "$LOG_DIR" 2>/dev/null && ok "removed $LOG_DIR"
  printf '\n%sSecret Keeper and all of its data are gone.%s\n\n' "$BOLD" "$RESET"
else
  # Keep the vault, but drop updater bookkeeping so a reinstall starts clean.
  rm -rf "$SUPPORT_DIR/updater" 2>/dev/null
  printf '\n%sSecret Keeper is uninstalled.%s\n\n' "$BOLD" "$RESET"
  printf 'Your vault was kept:\n'
  printf '  %s\n' "$SUPPORT_DIR"
  printf '  Keychain item "%s"\n\n' "$KEYCHAIN_SERVICE"
  printf 'Reinstalling picks it up again. To delete it, re-run with --purge.\n\n'
fi

printf 'Note: any .env.local symlinks in worktrees are removed when the vault locks.\n'
printf 'If you force-quit the app earlier, check your worktrees for dangling links.\n\n'
