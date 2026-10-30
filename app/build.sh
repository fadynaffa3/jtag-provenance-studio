#!/bin/zsh
# Builds a self-contained "JTag Provenance Studio.app" — no Homebrew or Python needed to run.
# Requires: Xcode, dylibbundler (brew install dylibbundler), and tools/.venv already set up.
#
# Signing modes (set SIGN_ID env var before running):
#   SIGN_ID=""                        → ad-hoc sign (default, local use only)
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)"  → notarized release build
#
# Notarization (only when SIGN_ID is set):
#   Also set NOTARY_PROFILE — an xcrun notarytool credential profile name.
#   One-time setup: xcrun notarytool store-credentials "jtag-notary" \
#     --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-password"
#   Then: SIGN_ID="Developer ID Application: ..." NOTARY_PROFILE="jtag-notary" zsh build.sh
set -euo pipefail
cd "$(dirname "$0")"
REPO="$(cd .. && pwd)"
VENV="$REPO/tools/.venv"
APP="JTag Provenance Studio.app"
RES="$APP/Contents/Resources"
BIN="$RES/bin"
FWK="$APP/Contents/Frameworks"

# Signing identity: default to ad-hoc if not set.
SIGN_ID="${SIGN_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

if [[ -n "$SIGN_ID" ]]; then
  echo "Signing with: $SIGN_ID"
  CODESIGN_ARGS=(--force --options runtime --sign "$SIGN_ID")
else
  echo "Ad-hoc signing (local use only). Set SIGN_ID for a notarized release build."
  CODESIGN_ARGS=(--force --sign -)
fi

rm -rf "$APP" "Provenance Studio.app"
mkdir -p "$APP/Contents/MacOS" "$RES" "$BIN" "$FWK"

# ── 1. Swift binary ──────────────────────────────────────────────────────────
swiftc -parse-as-library -O -target arm64-apple-macos14 \
  -o "$APP/Contents/MacOS/JTagProvenanceStudio" JTagProvenanceStudio.swift

# ── 2. Python engine and venv ─────────────────────────────────────────────────
cp "$REPO/tools/detect_ai_provenance.py" "$RES/"
PY_VER=$(ls /opt/homebrew/Cellar/python@3.14/ | tail -1)
PY_BASE="/opt/homebrew/Cellar/python@3.14/$PY_VER/Frameworks/Python.framework/Versions/3.14"
PY_FWK_SRC="$PY_BASE/Python"

echo "Copying venv (this may take a minute — ~1.4 GB)…"
cp -R "$VENV" "$RES/venv"

# Bundle the Python standard library (68 MB) — without it Python can't import anything.
# It lives in the framework, not the venv. Copy it alongside site-packages.
echo "Copying Python stdlib…"
cp -R "$PY_BASE/lib/python3.14" "$RES/python3.14-stdlib"

# Clear pyvenv.cfg home/executable — the Swift app rewrites these with correct absolute
# paths at every launch (since the app can be installed anywhere on the target machine).
cat > "$RES/venv/pyvenv.cfg" <<PYCFG
home = BUNDLE_PLACEHOLDER
include-system-site-packages = false
version = 3.14.6
executable = BUNDLE_PLACEHOLDER
PYCFG

# Replace venv python symlinks with real copies of the binary, then rewrite their install
# names to point at the bundled dylib. Without this the symlinks resolve to Homebrew on the
# build machine but are dead on any other machine.
PY_BIN_SRC="$PY_BASE/bin/python3.14"
for py_link in "$RES/venv/bin/python3" "$RES/venv/bin/python3.14" "$RES/venv/bin/python"; do
  rm -f "$py_link"
  cp "$PY_BIN_SRC" "$py_link"
  chmod +x "$py_link"
  # @loader_path is relative to the binary's own directory (venv/bin/), so
  # ../../../Frameworks/ walks: bin/ -> venv/ -> Resources/ -> Contents/Frameworks/
  # @executable_path would resolve relative to the app's main executable, not python3.
  install_name_tool \
    -change "$PY_FWK_SRC" "@loader_path/../../../Frameworks/Python.framework/Versions/3.14/Python" \
    -change "@executable_path/../Frameworks/Python.dylib" "@loader_path/../../../Frameworks/Python.framework/Versions/3.14/Python" \
    -change "@executable_path/../Frameworks/Python" "@loader_path/../../../Frameworks/Python.framework/Versions/3.14/Python" \
    "$py_link" 2>/dev/null || true
done

# ── 3. External binaries ──────────────────────────────────────────────────────
# c2patool (statically links most things, but needs openssl@4)
cp /opt/homebrew/bin/c2patool "$BIN/"

# pdfimages from poppler
cp /opt/homebrew/bin/pdfimages "$BIN/"

# openssl@3 (used by --create-identity for key/cert generation)
cp /opt/homebrew/opt/openssl@3/bin/openssl "$BIN/openssl3"
# Symlink as plain "openssl" so the engine's shutil.which("openssl") finds it via PATH.
ln -sf openssl3 "$BIN/openssl"

# exiftool: Perl script + its lib tree; macOS ships /usr/bin/perl
cp /opt/homebrew/bin/exiftool "$BIN/"
cp -R /opt/homebrew/Cellar/exiftool/$(ls /opt/homebrew/Cellar/exiftool/ | tail -1)/libexec/lib "$RES/exiftool-lib"
# Patch the shebang so it uses system perl (always present on macOS)
sed -i '' '1s|.*|#!/usr/bin/perl|' "$BIN/exiftool"

# ── 4. Shared libraries (dylibbundler fixes install_names automatically) ──────
echo "Bundling shared libraries…"
HB=/opt/homebrew
for BIN_FILE in "$BIN/c2patool" "$BIN/pdfimages" "$BIN/openssl3"; do
  install_name_tool -rpath /opt/homebrew/lib "$HB/lib" "$BIN_FILE" 2>/dev/null || true
  install_name_tool -rpath /opt/homebrew/opt/poppler/lib "$HB/opt/poppler/lib" "$BIN_FILE" 2>/dev/null || true
done
dylibbundler -od -b \
  -x "$BIN/c2patool" -x "$BIN/pdfimages" -x "$BIN/openssl3" \
  -s "$HB/lib" -s "$HB/opt/openssl@3/lib" -s "$HB/opt/openssl@4/lib" \
  -s "$HB/opt/poppler/lib" -s "$HB/opt/freetype/lib" -s "$HB/opt/fontconfig/lib" \
  -s "$HB/opt/jpeg-turbo/lib" -s "$HB/opt/gpgmepp/lib" -s "$HB/opt/openjpeg/lib" \
  -s "$HB/opt/little-cms2/lib" -s "$HB/opt/libpng/lib" -s "$HB/opt/libtiff/lib" \
  -s "$HB/opt/nss/lib" -s "$HB/opt/nspr/lib" -s "$HB/opt/gpgme/lib" \
  -s "$HB/opt/libassuan/lib" -s "$HB/opt/libgpg-error/lib" \
  -s "$HB/opt/xz/lib" -s "$HB/opt/zstd/lib" -s "$HB/opt/webp/lib" \
  -d "$FWK" -p "@executable_path/../Frameworks/"

# Copy Python framework AFTER dylibbundler (which wipes Frameworks/).
# Python looks for Resources/Python.app/Contents/MacOS/Python next to the dylib,
# so we must copy the full framework structure, not just the bare dylib.
PY_FWK="$FWK/Python.framework/Versions/3.14"
mkdir -p "$PY_FWK"
cp "$PY_FWK_SRC" "$PY_FWK/Python"
chmod +w "$PY_FWK/Python"
cp -R "$PY_BASE/Resources" "$PY_FWK/"
# Symlinks that complete the framework layout macOS expects.
ln -sf "Versions/3.14/Python"    "$FWK/Python.framework/Python"
ln -sf "Versions/3.14/Resources" "$FWK/Python.framework/Resources"
ln -sf "3.14"                     "$FWK/Python.framework/Versions/Current"
# Rewrite the dylib's own id to match where we placed it.
install_name_tool -id "@executable_path/../Frameworks/Python.framework/Versions/3.14/Python" "$PY_FWK/Python"

# ── 5. App icon ───────────────────────────────────────────────────────────────
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
swift make_icon.swift "$ICONSET/icon_512x512@2x.png" >/dev/null
for px in 16 32 128 256 512; do
  sips -z $px $px "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
  [[ $px != 512 ]] && sips -z $((px * 2)) $((px * 2)) "$ICONSET/icon_512x512@2x.png" \
    --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"

# ── 6. Info.plist ─────────────────────────────────────────────────────────────
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>JTag Provenance Studio</string>
  <key>CFBundleDisplayName</key><string>JTag Provenance Studio</string>
  <key>CFBundleIdentifier</key><string>com.jtag.provenance-studio</string>
  <key>CFBundleExecutable</key><string>JTagProvenanceStudio</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>6</string>
  <key>CFBundleShortVersionString</key><string>1.5</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# ── 7. Sign the full app ──────────────────────────────────────────────────────
# Notarization requires every Mach-O binary and bundle inside the app to be
# signed with Developer ID + hardened runtime. Sign all leaf binaries first
# (depth-first), then sign the app bundle itself.
echo "Signing all binaries…"
# Find every Mach-O file (executables, dylibs, .so, .bundle) — skip symlinks.
find "$APP" -type f \( \
    -name "*.dylib" -o -name "*.so" -o -name "*.bundle" -o \
    -name "python3" -o -name "python3.*" -o -name "python" \
  \) | while read -r f; do
  # Confirm it's actually a Mach-O before signing (some .so are text stubs).
  file "$f" 2>/dev/null | grep -q "Mach-O" || continue
  codesign "${CODESIGN_ARGS[@]}" "$f" 2>/dev/null || true
done
# Sign standalone executables in bin/.
find "$BIN" -type f | while read -r f; do
  file "$f" 2>/dev/null | grep -q "Mach-O" || continue
  codesign "${CODESIGN_ARGS[@]}" "$f" 2>/dev/null || true
done
# Finally sign the app bundle (covers the main executable and the bundle itself).
codesign "${CODESIGN_ARGS[@]}" --deep "$APP"
echo "Built $(pwd)/$APP"

# ── 8. DMG installer ──────────────────────────────────────────────────────────
DMG="JTag Provenance Studio.dmg"
DMG_STAGE=$(mktemp -d)
cp -R "$APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "JTag Provenance Studio" \
  -srcfolder "$DMG_STAGE" \
  -ov -format UDZO \
  -o "$DMG" >/dev/null
rm -rf "$DMG_STAGE"
echo "DMG: $(pwd)/$DMG"

# ── 9. Notarize and staple (only when SIGN_ID + NOTARY_PROFILE are set) ───────
if [[ -n "$SIGN_ID" && -n "$NOTARY_PROFILE" ]]; then
  echo "Submitting to Apple notarization (this takes 1–5 minutes)…"
  xcrun notarytool submit "$DMG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
  echo "Stapling notarization ticket to DMG…"
  xcrun stapler staple "$DMG"
  echo "Notarized and stapled: $DMG"
elif [[ -n "$SIGN_ID" ]]; then
  echo ""
  echo "Signed with Developer ID but not notarized."
  echo "Set NOTARY_PROFILE to notarize. See build.sh header for setup instructions."
fi
