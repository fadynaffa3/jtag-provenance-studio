#!/bin/sh
# JTag Provenance Studio — prerequisites installer
#
# Installs everything needed to run the app and CLI from a source checkout:
#   - Homebrew (if not already installed)
#   - exiftool, c2patool, poppler, openssl@3 via Homebrew
#   - Python 3 venv at tools/.venv with ML/watermark packages
#   - A lightweight Mac app that reads from the repo checkout (no giant DMG)
#
# The repo is checked out at ~/ai-provenance (cloned automatically if missing).
# macOS 14+, Apple silicon required.
#
# Usage (curl, one-liner):
#   curl -fsSL https://raw.githubusercontent.com/fadynaffa3/jtag-provenance-studio/main/install.sh | sh
#
# Or, if you already have the repo:
#   sh ~/ai-provenance/install.sh
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

# ── locate or clone the repo ──────────────────────────────────────────────────
REPO="$HOME/ai-provenance"
if [ ! -f "$REPO/tools/detect_ai_provenance.py" ]; then
    log "Cloning repository to ~/ai-provenance…"
    if [ -d "$REPO" ]; then
        # Directory exists but is not a complete checkout — try pulling inside it,
        # or remove and re-clone if it's not a git repo at all.
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

# ── 1. Homebrew ───────────────────────────────────────────────────────────────
log "Checking Homebrew…"
if ! command -v brew >/dev/null 2>&1; then
    log "Installing Homebrew (you may be prompted for your password)…"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Add brew to PATH for this shell session (Apple silicon installs to /opt/homebrew).
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi
ok "Homebrew $(brew --version | head -1)"

# ── 2. Homebrew packages ──────────────────────────────────────────────────────
log "Installing Homebrew packages…"
brew install exiftool c2patool poppler openssl@3
ok "exiftool, c2patool, poppler, openssl@3"

# ── 3. Python venv + packages ─────────────────────────────────────────────────
log "Setting up Python virtual environment (tools/.venv)…"
VENV="$REPO/tools/.venv"
if [ ! -d "$VENV" ]; then
    python3 -m venv "$VENV"
fi
"$VENV/bin/pip" install --quiet --upgrade pip
log "Installing Python packages…"
"$VENV/bin/pip" install trustmark invisible-watermark pillow numpy
ok "Python packages installed"
log "Note: TrustMark model weights (~2 GB total) download on first run — internet required once."

# ── 4. Install the latest notarized app from GitHub Releases ─────────────────
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
printf '  Open the app:  open -a "JTag Provenance Studio"\n\n'
printf '  CLI usage (uses the bundled Python inside the app):\n'
printf '    PY="%s/bin/python"\n' "$VENV"
printf '    T="%s/tools/detect_ai_provenance.py"\n' "$REPO"
# shellcheck disable=SC2016
printf '    $PY $T image.png                        # scan\n'
# shellcheck disable=SC2016
printf '    $PY $T image.png --strip --out output/  # strip AI tags\n\n'
