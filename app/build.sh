#!/bin/zsh
# Builds a self-contained "JTag Provenance Studio.app" — no Homebrew or Python needed to run.
# Requires: Xcode, dylibbundler (brew install dylibbundler), and tools/.venv already set up.
set -euo pipefail
cd "$(dirname "$0")"
REPO="$(cd .. && pwd)"
VENV="$REPO/tools/.venv"
APP="JTag Provenance Studio.app"
RES="$APP/Contents/Resources"
BIN="$RES/bin"
FWK="$APP/Contents/Frameworks"

rm -rf "$APP" "Provenance Studio.app"
mkdir -p "$APP/Contents/MacOS" "$RES" "$BIN" "$FWK"

# ── 1. Swift binary ──────────────────────────────────────────────────────────
swiftc -parse-as-library -O -target arm64-apple-macos14 \
  -o "$APP/Contents/MacOS/JTagProvenanceStudio" JTagProvenanceStudio.swift

# ── 2. Python engine and venv ─────────────────────────────────────────────────
cp "$REPO/tools/detect_ai_provenance.py" "$RES/"
echo "Copying venv (this may take a minute — ~1.4 GB)…"
cp -R "$VENV" "$RES/venv"
# Fix the venv's internal symlinks so they work from the new location
"$RES/venv/bin/python3" -m venv --upgrade "$RES/venv" 2>/dev/null || true

# ── 3. External binaries ──────────────────────────────────────────────────────
# c2patool (statically links most things, but needs openssl@4)
cp /opt/homebrew/bin/c2patool "$BIN/"

# pdfimages from poppler
cp /opt/homebrew/bin/pdfimages "$BIN/"

# openssl@3 (used by --create-identity for key/cert generation)
cp /opt/homebrew/opt/openssl@3/bin/openssl "$BIN/openssl3"

# exiftool: Perl script + its lib tree; macOS ships /usr/bin/perl
cp /opt/homebrew/bin/exiftool "$BIN/"
cp -R /opt/homebrew/Cellar/exiftool/$(ls /opt/homebrew/Cellar/exiftool/ | tail -1)/libexec/lib "$RES/exiftool-lib"
# Patch the shebang so it uses system perl (always present on macOS)
sed -i '' '1s|.*|#!/usr/bin/perl|' "$BIN/exiftool"

# ── 4. Shared libraries (dylibbundler fixes install_names automatically) ──────
echo "Bundling shared libraries…"
# Build the list of Homebrew lib dirs to search so dylibbundler never prompts.
HB=/opt/homebrew
# Fix rpath-based dylib refs before dylibbundler runs, so it can resolve them.
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
  <key>CFBundleIdentifier</key><string>local.jtag-provenance-studio</string>
  <key>CFBundleExecutable</key><string>JTagProvenanceStudio</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>CFBundleShortVersionString</key><string>1.2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - --deep "$APP"
echo "Built $(pwd)/$APP"

# ── 7. DMG installer ──────────────────────────────────────────────────────────
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
