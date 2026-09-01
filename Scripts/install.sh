#!/usr/bin/env bash
#
# Secret Keeper installer.
#
#   curl -fsSL https://raw.githubusercontent.com/rschwabco/secret-keeper/main/Scripts/install.sh | bash
#
# Installs "Secret Keeper.app", wires up MCP clients, and registers a launchd
# agent that keeps the app up to date with the repo. Prefers a prebuilt release
# and falls back to building from source.
#
set -uo pipefail

APP_NAME="Secret Keeper.app"
LABEL="com.secretkeeper.updater"
LOGIN_LABEL="com.secretkeeper.app"
DEFAULT_REPO="rschwabco/secret-keeper"
DEFAULT_BRANCH="main"
DEFAULT_BASE_URL="https://github.com"
ASSET_NAME="SecretKeeper-macos-universal.zip"
MIN_MACOS="14.0"

REPO="${SECRET_KEEPER_REPO:-$DEFAULT_REPO}"
BASE_URL="${SK_UPDATER_BASE_URL:-$DEFAULT_BASE_URL}"
BRANCH="${SECRET_KEEPER_BRANCH:-$DEFAULT_BRANCH}"
CHANNEL="${SECRET_KEEPER_CHANNEL:-stable}"
PREFIX=""
SOURCE_MODE="auto"        # auto | release | source | local
CONFIGURE_MCP=1
AUTO_UPDATE=1
LOGIN_ITEM=0
CHECK_INTERVAL=86400
ASSUME_YES=0

SUPPORT_DIR="$HOME/Library/Application Support/SecretKeeper"
UPD_DIR="$SUPPORT_DIR/updater"
LOG_DIR="$HOME/Library/Logs/SecretKeeper"
AGENT_DIR="$HOME/Library/LaunchAgents"

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
die()  { printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage: install.sh [options]

  --prefix <dir>       Install into <dir> instead of /Applications (or
                       ~/Applications when /Applications is not writable).
  --from-source        Build from source instead of downloading a release.
  --local              Build from this checkout (implies --from-source).
  --release-only       Fail rather than falling back to a source build.
  --channel <name>     Update channel: stable (default) or edge.
  --repo <owner/name>  GitHub repo to install and update from.
  --branch <name>      Branch to build from for source installs. Default: main.
  --interval <secs>    How often to check for updates. Default: 86400 (daily).
  --no-mcp-config      Do not touch MCP client config files.
  --no-auto-update     Do not install the background update agent.
  --login-item         Also start Secret Keeper automatically at login.
  --yes                Do not prompt.
  -h, --help           Show this help.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="${2:-}"; shift 2 ;;
    --from-source) SOURCE_MODE="source"; shift ;;
    --local) SOURCE_MODE="local"; shift ;;
    --release-only) SOURCE_MODE="release"; shift ;;
    --channel) CHANNEL="${2:-stable}"; shift 2 ;;
    --repo) REPO="${2:-$DEFAULT_REPO}"; shift 2 ;;
    --branch) BRANCH="${2:-$DEFAULT_BRANCH}"; shift 2 ;;
    --interval) CHECK_INTERVAL="${2:-86400}"; shift 2 ;;
    --no-mcp-config) CONFIGURE_MCP=0; shift ;;
    --no-auto-update) AUTO_UPDATE=0; shift ;;
    --login-item) LOGIN_ITEM=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'install.sh: unknown option %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$CHECK_INTERVAL" in ''|*[!0-9]*) die "--interval must be a number of seconds" ;; esac

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK" 2>/dev/null; }
trap cleanup EXIT

# --------------------------------------------------------------- version tools
vfield() {
  local f; f="$(printf '%s' "$1" | cut -d. -f"$2")"
  case "$f" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$f" ;; esac
}
version_lt() {  # version_lt A B -> true when A < B
  local i x y
  i=1
  while [ "$i" -le 3 ]; do
    x="$(vfield "$1" "$i")"; y="$(vfield "$2" "$i")"
    [ "$x" -lt "$y" ] && return 0
    [ "$x" -gt "$y" ] && return 1
    i=$((i + 1))
  done
  return 1
}
json_str() {
  printf '%s' "$1" | tr ',{}' '\n\n\n' \
    | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

# -------------------------------------------------------------------- preflight
info "Checking this Mac"
[ "$(uname -s)" = "Darwin" ] || die "Secret Keeper is macOS only."
OS_VERSION="$(/usr/bin/sw_vers -productVersion)"
if version_lt "$OS_VERSION" "$MIN_MACOS"; then
  die "macOS $MIN_MACOS or newer is required (this Mac runs $OS_VERSION)."
fi
ok "macOS $OS_VERSION on $(uname -m)"

for tool in curl ditto shasum codesign plutil launchctl xattr defaults; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

# Locate a local checkout when the script is run from one.
LOCAL_ROOT=""
SCRIPT_SRC="${BASH_SOURCE[0]:-$0}"
if [ -f "$SCRIPT_SRC" ]; then
  d="$(cd "$(dirname "$SCRIPT_SRC")/.." 2>/dev/null && pwd)"
  if [ -n "$d" ] && [ -f "$d/Package.swift" ] && [ -f "$d/Scripts/package-app.sh" ]; then
    LOCAL_ROOT="$d"
  fi
fi
[ "$SOURCE_MODE" = "local" ] && [ -z "$LOCAL_ROOT" ] && \
  die "--local needs to run from a Secret Keeper checkout (Scripts/install.sh)."

# ---------------------------------------------------------------- install dir
if [ -n "$PREFIX" ]; then
  INSTALL_DIR="$PREFIX"
  mkdir -p "$INSTALL_DIR" 2>/dev/null || die "cannot create $INSTALL_DIR"
elif [ -w "/Applications" ]; then
  INSTALL_DIR="/Applications"
else
  INSTALL_DIR="$HOME/Applications"
  mkdir -p "$INSTALL_DIR" 2>/dev/null || die "cannot create $INSTALL_DIR"
  warn "/Applications is not writable — installing to $INSTALL_DIR"
  note "Updates need a writable install directory, so this is the better default anyway."
fi
[ -w "$INSTALL_DIR" ] || die "$INSTALL_DIR is not writable."
APP_PATH="$INSTALL_DIR/$APP_NAME"

WORK="$(mktemp -d -t secret-keeper-install)" || die "cannot create a temp directory"
STAGED_APP=""
INSTALL_KIND=""

# ------------------------------------------------------------ release download
try_release() {
  local manifest url version build tag asset sha actual
  if [ "$CHANNEL" = "stable" ]; then
    url="$BASE_URL/$REPO/releases/latest/download/latest.json"
  else
    url="$BASE_URL/$REPO/releases/download/$CHANNEL/latest.json"
  fi
  info "Looking for a published release"
  manifest="$(curl -fsSL --retry 3 --retry-delay 2 --max-time 60 "$url" 2>/dev/null)"
  if [ -z "$manifest" ]; then
    warn "no release manifest at $url"
    return 1
  fi
  version="$(json_str "$manifest" version)"
  build="$(json_str "$manifest" build)"
  tag="$(json_str "$manifest" tag)"
  asset="$(json_str "$manifest" asset)"
  sha="$(json_str "$manifest" sha256)"
  [ -n "$version" ] && [ -n "$asset" ] || { warn "release manifest is incomplete"; return 1; }
  [ -n "$sha" ] || { warn "release manifest has no checksum — refusing an unverifiable download"; return 1; }
  [ -n "$tag" ] || tag="v$version"

  ok "found $version (build ${build:-?})"
  info "Downloading $asset"
  if ! curl -fSL --progress-bar --retry 3 --retry-delay 2 --max-time 900 \
      -o "$WORK/$asset" "$BASE_URL/$REPO/releases/download/$tag/$asset"; then
    warn "download failed"
    return 1
  fi
  actual="$(shasum -a 256 "$WORK/$asset" | awk '{print $1}' | tr 'A-Z' 'a-z')"
  if [ "$actual" != "$(printf '%s' "$sha" | tr 'A-Z' 'a-z')" ]; then
    die "checksum mismatch for $asset — refusing to install."
  fi
  ok "checksum verified"

  mkdir -p "$WORK/x"
  ditto -x -k "$WORK/$asset" "$WORK/x" 2>/dev/null || { warn "could not expand $asset"; return 1; }
  local found
  found="$WORK/x/$APP_NAME"
  [ -d "$found" ] || found="$(find "$WORK/x" -maxdepth 3 -name "$APP_NAME" -type d 2>/dev/null | head -1)"
  [ -n "$found" ] && [ -d "$found" ] || { warn "no $APP_NAME inside the archive"; return 1; }
  STAGED_APP="$found"
  INSTALL_KIND="release $version"
  return 0
}

# --------------------------------------------------------------- source build
try_source() {
  local root="$1"
  command -v swift >/dev/null 2>&1 || {
    warn "swift not found — install Xcode 16+ or the Command Line Tools"
    return 1
  }
  info "Building from source"
  note "$root"
  ( cd "$root" && ./Scripts/package-app.sh release --channel "$CHANNEL" --repo "$REPO" ) \
    || { warn "build failed"; return 1; }
  [ -d "$root/dist/$APP_NAME" ] || { warn "build produced no bundle"; return 1; }
  STAGED_APP="$root/dist/$APP_NAME"
  INSTALL_KIND="source build"
  return 0
}

clone_and_build() {
  command -v git >/dev/null 2>&1 || { warn "git not found"; return 1; }
  info "Cloning $REPO ($BRANCH)"
  git clone --depth 1 --branch "$BRANCH" "https://github.com/$REPO.git" "$WORK/src" >/dev/null 2>&1 \
    || { warn "could not clone https://github.com/$REPO.git"; return 1; }
  try_source "$WORK/src"
}

case "$SOURCE_MODE" in
  local)
    try_source "$LOCAL_ROOT" || die "local build failed."
    ;;
  source)
    if [ -n "$LOCAL_ROOT" ]; then
      try_source "$LOCAL_ROOT" || clone_and_build || die "source install failed."
    else
      clone_and_build || die "source install failed."
    fi
    ;;
  release)
    try_release || die "no installable release found for $REPO ($CHANNEL)."
    ;;
  *)
    if ! try_release; then
      warn "falling back to building from source"
      if [ -n "$LOCAL_ROOT" ]; then
        try_source "$LOCAL_ROOT" || clone_and_build || die "install failed."
      else
        clone_and_build || die "install failed."
      fi
    fi
    ;;
esac

[ -n "$STAGED_APP" ] && [ -d "$STAGED_APP" ] || die "nothing to install."

# -------------------------------------------------------------------- install
info "Installing to $APP_PATH"

if pgrep -f "$APP_PATH/Contents/MacOS/SecretKeeperApp" >/dev/null 2>&1; then
  note "Secret Keeper is running — quitting it first"
  osascript -e 'tell application "Secret Keeper" to quit' >/dev/null 2>&1
  waited=0
  while pgrep -f "$APP_PATH/Contents/MacOS/SecretKeeperApp" >/dev/null 2>&1 && [ "$waited" -lt 10 ]; do
    sleep 1; waited=$((waited + 1))
  done
  pkill -TERM -f "$APP_PATH/Contents/MacOS/SecretKeeperApp" >/dev/null 2>&1
  sleep 1
fi

TMP_NEW="$INSTALL_DIR/.SecretKeeper-new-$$"
TMP_OLD="$INSTALL_DIR/.SecretKeeper-old-$$"
rm -rf "$TMP_NEW" "$TMP_OLD" 2>/dev/null
ditto "$STAGED_APP" "$TMP_NEW" || die "could not copy the bundle into $INSTALL_DIR"

if [ -d "$APP_PATH" ]; then
  mv "$APP_PATH" "$TMP_OLD" || { rm -rf "$TMP_NEW"; die "could not replace the existing install"; }
fi
if ! mv "$TMP_NEW" "$APP_PATH"; then
  [ -d "$TMP_OLD" ] && mv "$TMP_OLD" "$APP_PATH"
  rm -rf "$TMP_NEW"
  die "could not move the new bundle into place (rolled back)"
fi
rm -rf "$TMP_OLD" 2>/dev/null

xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true
if ! codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_PATH" >/dev/null 2>&1
fi
codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1 \
  || warn "the installed bundle does not pass signature verification"

INSTALLED_VERSION="$(defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString 2>/dev/null)"
INSTALLED_BUILD="$(defaults read "$APP_PATH/Contents/Info" CFBundleVersion 2>/dev/null)"
ok "installed ${INSTALLED_VERSION:-?} (build ${INSTALLED_BUILD:-?}) from $INSTALL_KIND"

MCP_BIN="$APP_PATH/Contents/MacOS/secret-keeper-mcp"
[ -x "$MCP_BIN" ] || die "the installed bundle has no secret-keeper-mcp binary."

# ---------------------------------------------------------------- update agent
mkdir -p "$UPD_DIR" "$LOG_DIR" 2>/dev/null
chmod 700 "$SUPPORT_DIR" 2>/dev/null || true

cat > "$UPD_DIR/config.json" <<JSON
{
  "repo": "$REPO",
  "channel": "$CHANNEL",
  "base_url": "$BASE_URL",
  "app_path": "$APP_PATH",
  "check_interval_seconds": $CHECK_INTERVAL,
  "auto_install": true
}
JSON

if [ -f "$APP_PATH/Contents/Resources/secret-keeper-update" ]; then
  cp -f "$APP_PATH/Contents/Resources/secret-keeper-update" "$UPD_DIR/secret-keeper-update"
elif [ -n "$LOCAL_ROOT" ] && [ -f "$LOCAL_ROOT/Scripts/secret-keeper-update" ]; then
  cp -f "$LOCAL_ROOT/Scripts/secret-keeper-update" "$UPD_DIR/secret-keeper-update"
else
  curl -fsSL --max-time 60 \
    "https://raw.githubusercontent.com/$REPO/$BRANCH/Scripts/secret-keeper-update" \
    -o "$UPD_DIR/secret-keeper-update" 2>/dev/null || true
fi

if [ -s "$UPD_DIR/secret-keeper-update" ]; then
  chmod +x "$UPD_DIR/secret-keeper-update"
else
  rm -f "$UPD_DIR/secret-keeper-update"
  AUTO_UPDATE=0
  warn "could not install the updater script — auto-update is off"
fi

PLIST="$AGENT_DIR/$LABEL.plist"
if [ "$AUTO_UPDATE" -eq 1 ]; then
  info "Setting up automatic updates"
  mkdir -p "$AGENT_DIR"
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$UPD_DIR/secret-keeper-update</string>
		<string>--quiet</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StartInterval</key>
	<integer>21600</integer>
	<key>ThrottleInterval</key>
	<integer>300</integer>
	<key>LowPriorityIO</key>
	<true/>
	<key>Nice</key>
	<integer>5</integer>
	<key>StandardOutPath</key>
	<string>$LOG_DIR/launchd.log</string>
	<key>StandardErrorPath</key>
	<string>$LOG_DIR/launchd.log</string>
</dict>
</plist>
PLISTEOF
  plutil -lint "$PLIST" >/dev/null 2>&1 || die "generated a malformed launchd plist"
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1
  if launchctl bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 \
    || launchctl load -w "$PLIST" >/dev/null 2>&1; then
    launchctl enable "gui/$(id -u)/$LABEL" >/dev/null 2>&1
    ok "update agent registered (checks every $((CHECK_INTERVAL / 3600))h, applies when the vault is idle)"
  else
    warn "could not register the launchd agent; run '$UPD_DIR/secret-keeper-update' manually"
  fi
else
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1
  rm -f "$PLIST" 2>/dev/null
  warn "automatic updates are off"
fi

# ----------------------------------------------------------------- login item
LOGIN_PLIST="$AGENT_DIR/$LOGIN_LABEL.plist"
if [ "$LOGIN_ITEM" -eq 1 ]; then
  mkdir -p "$AGENT_DIR"
  cat > "$LOGIN_PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LOGIN_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/open</string>
		<string>$APP_PATH</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
PLISTEOF
  launchctl bootout "gui/$(id -u)/$LOGIN_LABEL" >/dev/null 2>&1
  launchctl bootstrap "gui/$(id -u)" "$LOGIN_PLIST" >/dev/null 2>&1 \
    || launchctl load -w "$LOGIN_PLIST" >/dev/null 2>&1
  ok "Secret Keeper will start at login"
fi

# ------------------------------------------------------------- MCP client wiring
MCP_ENTRY="{\"type\":\"stdio\",\"command\":\"/bin/sh\",\"args\":[\"-c\",\"exec '$MCP_BIN'\"]}"

configure_mcp_file() {  # configure_mcp_file <label> <path>
  local label="$1" file="$2" dir existing
  dir="$(dirname "$file")"
  [ -d "$dir" ] || return 1

  if [ -f "$file" ]; then
    # plutil escapes forward slashes on output, so strip backslashes before matching.
    existing="$(plutil -extract 'mcpServers.secret-keeper' json -o - "$file" 2>/dev/null | tr -d '\\')"
    case "$existing" in
      *"$MCP_BIN"*) note "$label already points at this install"; return 0 ;;
    esac
    # Keep the first backup — it is the only copy of the pre-Secret-Keeper config.
    [ -f "$file.secret-keeper.bak" ] || cp -f "$file" "$file.secret-keeper.bak" 2>/dev/null
  else
    printf '{\n  "mcpServers": {\n  }\n}\n' > "$file" 2>/dev/null || return 1
  fi

  if ! plutil -extract mcpServers json -o /dev/null "$file" >/dev/null 2>&1; then
    if ! plutil -replace mcpServers -json '{}' "$file" >/dev/null 2>&1; then
      warn "$label: could not read $file — leaving it alone"
      return 1
    fi
  fi

  if plutil -replace 'mcpServers.secret-keeper' -json "$MCP_ENTRY" "$file" >/dev/null 2>&1 \
    && plutil -convert json -r -o "$file" "$file" >/dev/null 2>&1 \
    && plutil -extract 'mcpServers.secret-keeper.command' raw -o /dev/null "$file" >/dev/null 2>&1; then
    ok "$label configured"
    [ -f "$file.secret-keeper.bak" ] && note "backup: $file.secret-keeper.bak"
    return 0
  fi

  if [ -f "$file.secret-keeper.bak" ]; then
    cp -f "$file.secret-keeper.bak" "$file" 2>/dev/null
    warn "$label: edit failed, restored the original"
  else
    rm -f "$file" 2>/dev/null
    warn "$label: could not write $file"
  fi
  return 1
}

# Codex keeps MCP servers in TOML, not JSON: [mcp_servers.<name>] tables.
configure_codex() {
  local file="$HOME/.codex/config.toml" tmp before after ours
  [ -d "$HOME/.codex" ] || return 1

  if [ -f "$file" ] && grep -qF "exec '$MCP_BIN'" "$file" 2>/dev/null; then
    note "Codex already points at this install"
    return 0
  fi

  [ -f "$file" ] || : > "$file"
  [ -f "$file.secret-keeper.bak" ] || cp -f "$file" "$file.secret-keeper.bak" 2>/dev/null

  tmp="$(mktemp -t sk-codex)" || return 1
  # Drop any existing secret-keeper table (and its sub-tables), then append fresh.
  awk '
    /^\[mcp_servers\.secret-keeper\]/  { skip = 1; next }
    /^\[mcp_servers\.secret-keeper\./  { skip = 1; next }
    /^\[/                              { skip = 0 }
    !skip                               { print }
  ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }

  {
    printf '\n[mcp_servers.secret-keeper]\n'
    printf 'command = "/bin/sh"\n'
    printf 'args = ["-c", "exec '"'"'%s'"'"'"]\n' "$MCP_BIN"
  } >> "$tmp"

  # Never trade someone's config for ours: bail unless every other table survived.
  before="$(grep -c '^\[' "$file" 2>/dev/null || printf 0)"
  after="$(grep -c '^\[' "$tmp" 2>/dev/null || printf 0)"
  ours="$(grep -c '^\[mcp_servers\.secret-keeper\]$' "$tmp" 2>/dev/null || printf 0)"
  if [ "$ours" -ne 1 ] || [ "$after" -lt "$before" ]; then
    rm -f "$tmp"
    warn "Codex: could not edit $file safely — left it alone"
    return 1
  fi

  mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  ok "Codex configured"
  [ -f "$file.secret-keeper.bak" ] && note "backup: $file.secret-keeper.bak"
  return 0
}

if [ "$CONFIGURE_MCP" -eq 1 ]; then
  info "Wiring up MCP clients"
  configured=0
  configure_mcp_file "Cursor" "$HOME/.cursor/mcp.json" && configured=1
  configure_mcp_file "Claude Desktop" \
    "$HOME/Library/Application Support/Claude/claude_desktop_config.json" && configured=1
  if command -v claude >/dev/null 2>&1; then
    if claude mcp add-json secret-keeper "$MCP_ENTRY" --scope user >/dev/null 2>&1; then
      ok "Claude Code configured"
      configured=1
    fi
  fi
  configure_codex && configured=1
  [ "$configured" -eq 0 ] && note "no MCP clients detected — see the snippet below"
fi

# ----------------------------------------------------------------------- done
printf '\n%sSecret Keeper %s is installed.%s\n\n' "$BOLD" "${INSTALLED_VERSION:-}" "$RESET"
printf '  App        %s\n' "$APP_PATH"
printf '  MCP server %s\n' "$MCP_BIN"
if [ "$AUTO_UPDATE" -eq 1 ]; then
  printf '  Updates    %s channel, checked every %sh, installed when the vault is idle\n' \
    "$CHANNEL" "$((CHECK_INTERVAL / 3600))"
  printf '  Update log %s\n' "$LOG_DIR/updater.log"
fi
printf '\n%sNext:%s\n' "$BOLD" "$RESET"
printf '  1. open "%s"\n' "$APP_PATH"
printf '  2. Add an app (name, root folder, KEY=VALUE secrets) and unlock with Touch ID.\n'
printf '  3. Restart your MCP client so it picks up the new server.\n'
if [ "$CONFIGURE_MCP" -eq 0 ] || [ "${configured:-0}" -eq 0 ]; then
  printf '\n%sMCP config snippet:%s\n' "$BOLD" "$RESET"
  printf '  {\n    "mcpServers": {\n      "secret-keeper": {\n'
  printf '        "type": "stdio",\n        "command": "/bin/sh",\n'
  printf '        "args": ["-c", "exec '"'"'%s'"'"'"]\n' "$MCP_BIN"
  printf '      }\n    }\n  }\n'
fi
printf '\nCheck for updates any time:  %s/secret-keeper-update --user-initiated\n' "$UPD_DIR"
printf 'Uninstall:  curl -fsSL https://raw.githubusercontent.com/%s/%s/Scripts/uninstall.sh | bash\n\n' "$REPO" "$BRANCH"
