#!/bin/sh
# JTag Provenance Studio — installer
#
# Two modes:
#   download  — download the latest notarized DMG from GitHub Releases (default,
#               no prerequisites, fastest)
#   build     — clone the repo and build the app from source (requires Xcode +
#               Homebrew; builds the same self-contained app as the release)
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
[ "$(id -u)" = "0" ]        && die "Do not run this script as root (sudo). Run it as your normal user account."
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

# Install into /Applications when this user can write there; otherwise (a standard,
# non-admin account) into ~/Applications, which needs no password.
if [ -w /Applications ]; then
    INSTALL_DIR=/Applications
else
    INSTALL_DIR="$HOME/Applications"
    mkdir -p "$INSTALL_DIR"
fi
DEST="$INSTALL_DIR/JTag Provenance Studio.app"

WORKDIR=$(mktemp -d)
MOUNT_DIR="$WORKDIR/mnt"
cleanup() {
    [ -d "$MOUNT_DIR" ] && hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

# ══════════════════════════════════════════════════════════════════════════════
# MODE: download — fetch latest notarized DMG from GitHub Releases
# ══════════════════════════════════════════════════════════════════════════════
if [ "$MODE" = "download" ]; then

# The app bundles Python, exiftool, c2patool, pdfimages, openssl and the watermark models
# (tests/test_bundle.sh checks this), so nothing else is installed.
log "Downloading latest JTag Provenance Studio app…"

REPO_SLUG="fadynaffa3/jtag-provenance-studio"
DOWNLOAD_URL=$(curl -fsSL "https://api.github.com/repos/$REPO_SLUG/releases/latest" \
  | grep '"browser_download_url"' | grep -i '\.dmg' | head -1 \
  | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/')

if [ -z "$DOWNLOAD_URL" ]; then
    die "Could not find the DMG in the latest GitHub release. Check https://github.com/$REPO_SLUG/releases"
fi

ok "Found: $DOWNLOAD_URL"
DMG_TMP="$WORKDIR/JTag-Provenance-Studio.dmg"
printf '  Downloading (~1 GB, this will take a few minutes)…\n'
curl -fL --progress-bar -o "$DMG_TMP" "$DOWNLOAD_URL"
ok "Downloaded"

mkdir -p "$MOUNT_DIR"
hdiutil attach "$DMG_TMP" -mountpoint "$MOUNT_DIR" -nobrowse -readonly -quiet \
    || die "Could not open the downloaded DMG. Try again; if it keeps failing, download it from https://github.com/$REPO_SLUG/releases"
APP_IN_DMG=$(find "$MOUNT_DIR" -maxdepth 1 -name "*.app" | head -1)
[ -n "$APP_IN_DMG" ] || die "No app found inside the DMG."

# A release is signed with Developer ID and notarized. If the signature doesn't verify,
# the download is damaged or tampered with; don't install it.
codesign --verify --deep --strict "$APP_IN_DMG" 2>/dev/null \
    || die "The downloaded app's signature is invalid, so it was not installed. Please report this at https://github.com/$REPO_SLUG/issues"
ok "Signature verified"

rm -rf "$DEST"
ditto "$APP_IN_DMG" "$DEST"
# curl doesn't quarantine downloads; clear it anyway in case the DMG came from a browser.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
ok "App installed to $INSTALL_DIR"

fi  # end MODE=download

# ══════════════════════════════════════════════════════════════════════════════
# MODE: build — clone repo and build the self-contained app from source
# ══════════════════════════════════════════════════════════════════════════════
if [ "$MODE" = "build" ]; then

REPO="$HOME/ai-provenance"
log "Locating repository…"
if [ -d "$REPO/.git" ]; then
    git -C "$REPO" pull --ff-only
elif [ -e "$REPO" ]; then
    die "$REPO already exists but is not a git repo. Move or delete it, then re-run."
else
    git clone https://github.com/fadynaffa3/jtag-provenance-studio.git "$REPO"
fi
ok "Repo at $REPO"

xcode-select -p >/dev/null 2>&1 || die "Xcode is required to build. Install it from the App Store, then re-run."

log "Checking Homebrew…"
if ! command -v brew >/dev/null 2>&1; then
    log "Installing Homebrew (you may be prompted for your password)…"
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi
ok "Homebrew $(brew --version | head -1)"

log "Installing build dependencies…"
brew install dylibbundler exiftool c2patool poppler openssl@3 python@3.14
ok "dylibbundler, exiftool, c2patool, poppler, openssl@3, python@3.14"

# The venv must come from Homebrew's python3.14: build.sh bundles that same framework.
log "Setting up the Python environment…"
PY="$(brew --prefix python@3.14)/bin/python3.14"
"$PY" -m venv --clear "$REPO/tools/.venv"
"$REPO/tools/.venv/bin/pip" install -q trustmark invisible-watermark pillow numpy
ok "Python packages installed"

log "Building JTag Provenance Studio.app (downloads watermark models once; 5–10 minutes)…"
zsh "$REPO/app/build.sh" || die "Build failed; see the messages above."

rm -rf "$DEST"
ditto "$REPO/app/JTag Provenance Studio.app" "$DEST"
ok "App installed to $INSTALL_DIR"

fi  # end MODE=build

# ── done ──────────────────────────────────────────────────────────────────────
printf '\n\033[1m✅ Done!\033[0m\n\n'
printf '  Launching JTag Provenance Studio…\n\n'
# Use the full path so Launch Services doesn't need to search, and redirect
# stdio so open works even when stdin is piped from curl.
sleep 1
open "$DEST" </dev/tty >/dev/tty 2>&1 || open "$DEST"
