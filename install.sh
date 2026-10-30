#!/bin/sh
# JTag Provenance Studio — installer
#
# Two modes:
#   download  — download the latest notarized DMG from GitHub Releases (default,
#               no prerequisites, fastest)
#   build     — clone the repo and build the app from source (requires Xcode +
#               Homebrew; the built app reads tools from the checkout)
#
# macOS 14+, Apple silicon required.
#
# Usage (curl, one-liner):
#   curl -fsSL https://raw.githubusercontent.com/fadynaffa3/jtag-provenance-studio/main/install.sh | sh
set -e

# ── helpers ───────────────────────────────────────────────────────────────────
log()  { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
die()  { printf '\n\033[31mError: %s\033[0m\n' "$*" >&2; exit 1; }

# ── sanity checks ─────────────────────────────────────────────────────────────
[ "$(uname)" = "Darwin" ]   || die "macOS only."
[ "$(uname -m)" = "arm64" ] || die "Apple silicon (arm64) required."
os_ver=$(sw_vers -productVersion | cut -d. -f1)
[ "$os_ver" -ge 14 ] 2>/dev/null || die "macOS 14+ required (you have $(sw_vers -productVersion))."

# ── mode selection ────────────────────────────────────────────────────────────
printf '\n\033[1mJTag Provenance Studio — Installer\033[0m\n\n'
printf '  1) Download prebuilt app  (recommended — notarized, no prerequisites)\n'
printf '  2) Build from source      (requires Xcode + Homebrew; stays in ~/ai-provenance)\n\n'
printf 'Choose [1/2, default 1]: '
if [ -t 0 ]; then
    read -r MODE
elif [ -c /dev/tty ]; then
    read -r MODE </dev/tty
else
    MODE=""
fi
case "$MODE" in
    2) MODE=build ;;
    *) MODE=download ;;
esac

# ══════════════════════════════════════════════════════════════════════════════
# MODE: download — fetch latest notarized DMG from GitHub Releases
# ══════════════════════════════════════════════════════════════════════════════
if [ "$MODE" = "download" ]; then

log "Checking Homebrew…"
if ! command -v brew >/dev/null 2>&1; then
    log "Installing Homebrew (you may be prompted for your password)…"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi
ok "Homebrew $(brew --version | head -1)"

log "Installing required tools…"
brew install exiftool c2patool poppler openssl@3
ok "exiftool, c2patool, poppler, openssl@3"

log "Downloading latest JTag Provenance Studio app…"

REPO_SLUG="fadynaffa3/jtag-provenance-studio"
# GitHub replaces spaces with dots in uploaded asset filenames.
DOWNLOAD_URL=$(curl -fsSL "https://api.github.com/repos/$REPO_SLUG/releases/latest" \
  | grep '"browser_download_url"' | grep -i '\.dmg' | head -1 \
  | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/')

if [ -z "$DOWNLOAD_URL" ]; then
    die "Could not find the DMG in the latest GitHub release. Check https://github.com/$REPO_SLUG/releases"
fi

ok "Found: $DOWNLOAD_URL"
DMG_TMP=$(mktemp /tmp/jtag-XXXXXX.dmg)
printf '  Downloading (~1 GB, this will take a minute)…\n'
curl -fL --progress-bar -o "$DMG_TMP" "$DOWNLOAD_URL"
ok "Downloaded"

# Mount, copy app, unmount.
MOUNT_DIR=$(mktemp -d)
hdiutil attach "$DMG_TMP" -mountpoint "$MOUNT_DIR" -nobrowse -quiet
DEST="/Applications/JTag Provenance Studio.app"
rm -rf "$DEST"
# The app inside the DMG may have dots or spaces in the name — find it.
APP_IN_DMG=$(find "$MOUNT_DIR" -maxdepth 1 -name "*.app" | head -1)
cp -R "$APP_IN_DMG" /Applications/
hdiutil detach "$MOUNT_DIR" -quiet
rm -f "$DMG_TMP"

# Clear quarantine so the notarized app opens without Gatekeeper warnings.
xattr -rc "$DEST" 2>/dev/null || true
sudo xattr -rd com.apple.quarantine "$DEST" 2>/dev/null || true
ok "App installed to /Applications"

fi  # end MODE=download

# ══════════════════════════════════════════════════════════════════════════════
# MODE: build — clone repo and compile the app from source
# ══════════════════════════════════════════════════════════════════════════════
if [ "$MODE" = "build" ]; then

REPO="$HOME/ai-provenance"
log "Locating repository…"
if [ ! -f "$REPO/tools/detect_ai_provenance.py" ]; then
    if [ -d "$REPO" ]; then
        if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
            git -C "$REPO" pull --ff-only
        else
            die "$HOME/ai-provenance already exists but is not a git repo. Move or delete it, then re-run."
        fi
    else
        git clone https://github.com/fadynaffa3/jtag-provenance-studio.git "$REPO"
    fi
fi
ok "Repo at $REPO"

log "Checking Homebrew…"
if ! command -v brew >/dev/null 2>&1; then
    log "Installing Homebrew (you may be prompted for your password)…"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi
ok "Homebrew $(brew --version | head -1)"

log "Installing Homebrew packages…"
brew install exiftool c2patool poppler openssl@3
ok "exiftool, c2patool, poppler, openssl@3"

printf '\n'
printf '  \033[33mNote:\033[0m Watermark detection requires a Python venv with ML packages.\n'
printf '  To enable it, run after install:\n\n'
printf '    python3 -m venv %s/tools/.venv\n' "$REPO"
printf '    %s/tools/.venv/bin/pip install pillow numpy invisible-watermark trustmark\n\n' "$REPO"
printf '  The app works without them — watermark detection will be skipped.\n'

log "Building JTag Provenance Studio.app…"
APP_DIR="$REPO/app/JTag Provenance Studio.app"
CONTENTS="$APP_DIR/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

if ! swiftc -parse-as-library -O -target arm64-apple-macos14 \
        -o "$CONTENTS/MacOS/JTagProvenanceStudio" \
        "$REPO/app/JTagProvenanceStudio.swift" 2>&1; then
    die "Swift compile failed. Install Xcode Command Line Tools with: xcode-select --install"
fi

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>JTag Provenance Studio</string>
  <key>CFBundleDisplayName</key><string>JTag Provenance Studio</string>
  <key>CFBundleIdentifier</key><string>local.jtag-provenance-studio</string>
  <key>CFBundleExecutable</key><string>JTagProvenanceStudio</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>dev</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

codesign --force --sign - "$APP_DIR" 2>/dev/null || true

DEST="/Applications/JTag Provenance Studio.app"
rm -rf "$DEST"
cp -R "$APP_DIR" /Applications/
xattr -rd com.apple.quarantine "$DEST" 2>/dev/null || true
ok "App installed to /Applications"

fi  # end MODE=build

# ── done ──────────────────────────────────────────────────────────────────────
printf '\n\033[1m✅ Done!\033[0m\n\n'
printf '  Launching JTag Provenance Studio…\n\n'
# Use the full path so Launch Services doesn't need to search, and redirect
# stdio so open works even when stdin is piped from curl.
sleep 1
open "/Applications/JTag Provenance Studio.app" </dev/tty >/dev/tty 2>&1 || \
    open "/Applications/JTag Provenance Studio.app"
