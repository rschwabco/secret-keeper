#!/usr/bin/env zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Secret Keeper.app"
DIST_DIR="$ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME"

CONFIGURATION="release"
UNIVERSAL=0
VERSION=""
BUILD=""
CHANNEL="stable"
REPO="${SECRET_KEEPER_REPO:-rschwabco/secret-keeper}"

usage() {
  cat <<'USAGE'
Usage: Scripts/package-app.sh [debug|release] [options]

Options:
  --universal          Build a fat arm64 + x86_64 bundle (used by CI releases).
  --version <x.y.z>    Marketing version. Default: contents of ./VERSION.
  --build <n>          Build number (CFBundleVersion). Default: git commit count.
  --channel <name>     Update channel baked into the bundle (stable|edge).
  --repo <owner/name>  GitHub repo the updater checks. Default: rschwabco/secret-keeper.
  -h, --help           Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    debug|release) CONFIGURATION="$1"; shift ;;
    -c|--configuration) CONFIGURATION="$2"; shift 2 ;;
    --universal) UNIVERSAL=1; shift ;;
    --version) VERSION="$2"; shift 2 ;;
    --build) BUILD="$2"; shift 2 ;;
    --channel) CHANNEL="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "package-app.sh: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  if [[ -f "$ROOT/VERSION" ]]; then
    VERSION="$(tr -d ' \t\n\r' < "$ROOT/VERSION")"
  else
    VERSION="0.0.0"
  fi
fi

if [[ -z "$BUILD" ]]; then
  if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"
  fi
  [[ -z "$BUILD" || "$BUILD" == "0" ]] && BUILD="$(date +%Y%m%d%H%M)"
fi

COMMIT="unknown"
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
fi

typeset -a ARCH_FLAGS
ARCH_FLAGS=()
if (( UNIVERSAL )); then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "Building ${VERSION} (${BUILD}) — ${CONFIGURATION}$( (( UNIVERSAL )) && echo ', universal' )…"
swift build -c "$CONFIGURATION" "${ARCH_FLAGS[@]}"

# Locating build products: `--show-bin-path` is not reliable across toolchains
# once --arch flags select the Xcode build system, so fall back to the known
# product directories rather than trusting it.
BIN_DIR=""
if try_dir="$(swift build -c "$CONFIGURATION" "${ARCH_FLAGS[@]}" --show-bin-path 2>/dev/null)"; then
  [[ -n "$try_dir" && -x "$try_dir/SecretKeeperApp" ]] && BIN_DIR="$try_dir"
fi
if [[ -z "$BIN_DIR" ]]; then
  conf_dir="${(C)CONFIGURATION}"   # release -> Release
  for cand in \
    "$ROOT/.build/apple/Products/$conf_dir" \
    "$ROOT/.build/$(uname -m)-apple-macosx/$CONFIGURATION"; do
    if [[ -x "$cand/SecretKeeperApp" ]]; then BIN_DIR="$cand"; break; fi
  done
fi
if [[ -z "$BIN_DIR" ]]; then
  echo "package-app.sh: could not locate build products under $ROOT/.build" >&2
  exit 1
fi
echo "Products: $BIN_DIR"

echo "Assembling ${APP_NAME}…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/SecretKeeperApp" "$APP_DIR/Contents/MacOS/SecretKeeperApp"
cp "$BIN_DIR/secret-keeper-mcp" "$APP_DIR/Contents/MacOS/secret-keeper-mcp"
cp "$ROOT/Scripts/Info.plist" "$APP_DIR/Contents/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# The bundle carries its own updater so an update also refreshes the update logic.
cp "$ROOT/Scripts/secret-keeper-update" "$APP_DIR/Contents/Resources/secret-keeper-update"
chmod +x "$APP_DIR/Contents/Resources/secret-keeper-update"

plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP_DIR/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$APP_DIR/Contents/Info.plist"

cat > "$APP_DIR/Contents/Resources/build-info.json" <<JSON
{
  "version": "$VERSION",
  "build": "$BUILD",
  "commit": "$COMMIT",
  "channel": "$CHANNEL",
  "repo": "$REPO"
}
JSON

chmod +x "$APP_DIR/Contents/MacOS/SecretKeeperApp"
chmod +x "$APP_DIR/Contents/MacOS/secret-keeper-mcp"

# Ad-hoc sign so Keychain biometric ACLs work for local builds.
codesign --force --deep --sign - "$APP_DIR" >/dev/null

echo "Built: $APP_DIR  (v$VERSION build $BUILD, channel $CHANNEL)"
echo "MCP binary: $APP_DIR/Contents/MacOS/secret-keeper-mcp"
echo ""
echo "Install locally:"
echo "  ./Scripts/install.sh --local"
