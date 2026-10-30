#!/bin/sh
# JTag Provenance Studio — installer
#
# Downloads the latest notarized DMG from GitHub Releases and installs the app.
# Everything (Python, tools, ML packages) is bundled inside the app — no
# Homebrew or Python setup required.
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

# ── Install the latest notarized app from GitHub Releases ────────────────────
log "Downloading latest JTag Provenance Studio app…"

REPO_SLUG="fadynaffa3/jtag-provenance-studio"
ASSET_NAME="JTag Provenance Studio.dmg"
DOWNLOAD_URL=$(curl -fsSL "https://api.github.com/repos/$REPO_SLUG/releases/latest" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
for a in data.get('assets', []):
    if a['name'] == 'JTag Provenance Studio.dmg':
        print(a['browser_download_url'])
        break
")

if [ -z "$DOWNLOAD_URL" ]; then
    die "Could not find the DMG in the latest GitHub release. Check https://github.com/$REPO_SLUG/releases"
fi

ok "Found release: $DOWNLOAD_URL"
DMG_TMP=$(mktemp /tmp/jtag-XXXXXX.dmg)
curl -fL --progress-bar -o "$DMG_TMP" "$DOWNLOAD_URL"
ok "Downloaded DMG"

# Mount, copy app, unmount.
MOUNT_DIR=$(mktemp -d)
hdiutil attach "$DMG_TMP" -mountpoint "$MOUNT_DIR" -nobrowse -quiet
DEST="/Applications/JTag Provenance Studio.app"
rm -rf "$DEST"
cp -R "$MOUNT_DIR/JTag Provenance Studio.app" /Applications/
hdiutil detach "$MOUNT_DIR" -quiet
rm -f "$DMG_TMP"

# Clear quarantine so Gatekeeper doesn't block a notarized app on first open.
xattr -rd com.apple.quarantine "$DEST" 2>/dev/null || true
ok "App installed to /Applications"

# ── done ──────────────────────────────────────────────────────────────────────
printf '\n\033[1m✅ Done!\033[0m\n\n'
printf '  Launching JTag Provenance Studio…\n\n'
open -a "JTag Provenance Studio"
