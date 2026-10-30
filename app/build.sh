#!/bin/zsh
# Builds a self-contained "JTag Provenance Studio.app" — no Homebrew or Python needed to run.
# Requires: Xcode, Homebrew with dylibbundler exiftool c2patool poppler openssl@3 python@3.14,
# and tools/.venv set up from Homebrew's python3.14 (see AGENTS.md).
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
PY_FWK="$FWK/Python.framework/Versions/3.14"

# Two builds in this folder delete each other's bundle, so allow only one at a time.
LOCK=".build.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "Another build is running (or one crashed): $(pwd)/$LOCK exists. Remove it if no build is running." >&2
  exit 1
fi
WORK=$(mktemp -d)
trap 'rm -rf "$LOCK" "$WORK"' EXIT

# Signing identity: default to ad-hoc if not set.
SIGN_ID="${SIGN_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

if [[ -n "$SIGN_ID" ]]; then
  echo "Signing with: $SIGN_ID"
  CODESIGN_ARGS=(--force --options runtime --timestamp --sign "$SIGN_ID")
else
  echo "Ad-hoc signing (local use only). Set SIGN_ID for a notarized release build."
  CODESIGN_ARGS=(--force --sign -)
fi

# install_name_tool warns about every signature it invalidates; everything is re-signed
# in step 7, so drop that warning but keep real errors (and let set -e stop the build).
int_tool() {
  install_name_tool "$@" 2> >(grep -v 'will invalidate the code signature' >&2)
}

# Mach-O candidates: executables, dylibs and Python extensions (skips the ~100k data files).
macho_files() {
  find "$1" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) | while read -r f; do
    if [[ "$(file -b "$f")" == *Mach-O* ]]; then print -r -- "$f"; fi
  done
}

rm -rf "$APP" "Provenance Studio.app"
mkdir -p "$APP/Contents/MacOS" "$RES" "$BIN" "$FWK"

# ── 1. Swift binary ──────────────────────────────────────────────────────────
swiftc -parse-as-library -O -target arm64-apple-macos14 \
  -o "$APP/Contents/MacOS/JTagProvenanceStudio" JTagProvenanceStudio.swift

# ── 2. Python engine and venv ─────────────────────────────────────────────────
cp "$REPO/tools/detect_ai_provenance.py" "$RES/"
# brew --prefix follows the linked (current) keg; pwd -P resolves it to the Cellar path,
# which is the install name the Homebrew binaries record.
PY_BASE="$(cd "$(brew --prefix python@3.14)/Frameworks/Python.framework/Versions/3.14" && pwd -P)"
PY_FWK_SRC="$PY_BASE/Python"
PY_VER=$("$PY_BASE/bin/python3.14" -c 'import platform; print(platform.python_version())')
VENV_VER=$(awk -F' = ' '$1 == "version" {print $2}' "$VENV/pyvenv.cfg")
if [[ "$VENV_VER" != "$PY_VER" ]]; then
  echo "tools/.venv was made with Python $VENV_VER but Homebrew has $PY_VER. Recreate it:" >&2
  echo "  $PY_BASE/bin/python3.14 -m venv --clear $VENV && $VENV/bin/pip install trustmark invisible-watermark pillow numpy" >&2
  exit 1
fi

# TrustMark downloads its weights next to its own code on first use. In the app that
# would write into the signed bundle (breaking the seal, and failing for users who can't
# write to /Applications), so fetch them into the venv now and ship them. TrustMark checks
# each file's MD5 and only downloads what is missing or wrong.
echo "Checking TrustMark weights (first time downloads ~550 MB)…"
"$VENV/bin/python" -B -c '
from trustmark import TrustMark
for variant in ("Q", "P", "B", "C"):  # the variants detect_ai_provenance.py loads
    TrustMark(verbose=False, model_type=variant, loadRemover=True)
'

echo "Copying venv (this may take a minute — ~2 GB)…"
cp -R "$VENV" "$RES/venv"

# pyvenv.cfg keeps placeholders: nothing reads home/executable, because the bundled Python
# finds its stdlib inside Python.framework (step 4) and site-packages via PYTHONPATH.
cat > "$RES/venv/pyvenv.cfg" <<PYCFG
home = BUNDLE_PLACEHOLDER
include-system-site-packages = false
version = $PY_VER
executable = BUNDLE_PLACEHOLDER
PYCFG

# Replace venv python symlinks with real copies of the binary, then rewrite their install
# names to point at the bundled dylib. Without this the symlinks resolve to Homebrew on the
# build machine but are dead on any other machine. (rm first: install_name_tool on the
# symlink would edit Homebrew's own binary and break its signature.)
PY_BIN_SRC="$PY_BASE/bin/python3.14"
for py_link in "$RES/venv/bin/python3" "$RES/venv/bin/python3.14" "$RES/venv/bin/python"; do
  rm -f "$py_link"
  cp "$PY_BIN_SRC" "$py_link"
  chmod +wx "$py_link"
  # @loader_path is relative to the binary's own directory (venv/bin/), so
  # ../../../Frameworks/ walks: bin/ -> venv/ -> Resources/ -> Contents/Frameworks/
  int_tool \
    -change "$PY_FWK_SRC" "@loader_path/../../../Frameworks/Python.framework/Versions/3.14/Python" \
    -change "@executable_path/../Frameworks/Python" "@loader_path/../../../Frameworks/Python.framework/Versions/3.14/Python" \
    "$py_link"
done

# ── 3. External binaries ──────────────────────────────────────────────────────
# c2patool (statically links most things, but needs openssl@4)
cp /opt/homebrew/bin/c2patool "$BIN/"

# pdfimages from poppler
cp /opt/homebrew/bin/pdfimages "$BIN/"

# openssl@3 (used by --create-identity for key/cert generation)
cp "$(brew --prefix openssl@3)/bin/openssl" "$BIN/openssl3"
# Symlink as plain "openssl" so the engine's shutil.which("openssl") finds it via PATH.
ln -sf openssl3 "$BIN/openssl"
chmod +w "$BIN/c2patool" "$BIN/pdfimages" "$BIN/openssl3"

# exiftool: Perl script + its lib tree; macOS ships /usr/bin/perl
cp /opt/homebrew/bin/exiftool "$BIN/"
cp -R "$(brew --prefix exiftool)/libexec/lib" "$RES/exiftool-lib"
# Patch the shebang so it uses system perl (always present on macOS)
sed -i '' '1s|.*|#!/usr/bin/perl|' "$BIN/exiftool"

# ── 4. Shared libraries (dylibbundler fixes install_names automatically) ──────
echo "Bundling shared libraries…"
HB=/opt/homebrew
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
mkdir -p "$PY_FWK/lib"
cp "$PY_FWK_SRC" "$PY_FWK/Python"
chmod +w "$PY_FWK/Python"
cp -R "$PY_BASE/Resources" "$PY_FWK/"
# Symlinks that complete the framework layout macOS expects.
ln -sf "Versions/3.14/Python"    "$FWK/Python.framework/Python"
ln -sf "Versions/3.14/Resources" "$FWK/Python.framework/Resources"
ln -sf "3.14"                     "$FWK/Python.framework/Versions/Current"
# Rewrite the dylib's own id.
int_tool -id "@executable_path/../Frameworks/Python.framework/Versions/3.14/Python" "$PY_FWK/Python"
# Also rewrite the Python.app wrapper binary — it links to the Homebrew absolute path.
PY_APP_BIN="$PY_FWK/Resources/Python.app/Contents/MacOS/Python"
chmod +w "$PY_APP_BIN"
int_tool -change "$PY_FWK_SRC" "@loader_path/../../../../Python" "$PY_APP_BIN"

# The standard library goes where Python looks for it: <framework>/lib/python3.14. Python
# finds that from the dylib's own location, so it never falls back to the compiled-in
# Homebrew prefix (which exists on the build Mac and would quietly be used instead).
echo "Copying Python stdlib…"
cp -R "$PY_BASE/lib/python3.14" "$PY_FWK/lib/python3.14"
# Drop parts that point back into Homebrew: site-packages is a symlink to
# /opt/homebrew/lib/python3.14/site-packages, and config-3.14-darwin holds symlinks to
# libpython (only needed to compile extensions). Dangling symlinks break codesign --verify.
rm -rf "$PY_FWK/lib/python3.14/site-packages" "$PY_FWK/lib/python3.14/config-3.14-darwin"
find "$PY_FWK/lib/python3.14" -type l ! -exec test -e {} \; -delete

# ── 4b. Patch stdlib .so files that link against Homebrew dylibs ──────────────
# Python's lib-dynload/ contains C extensions (_lzma, _ssl, _hashlib, etc.) that
# were built against Homebrew dylibs. Copy each such dylib into Frameworks/ (if
# dylibbundler hasn't already) and point the .so at it.
echo "Patching stdlib .so Homebrew dependencies…"
DYNLOAD_DIR="$PY_FWK/lib/python3.14/lib-dynload"
patch_so_dep() {
  local so="$1" old_dep="$2" dylib_name dylib_src
  dylib_name=$(basename "$old_dep")
  dylib_src=$(readlink -f "$old_dep" 2>/dev/null || echo "$old_dep")
  if [[ ! -f "$FWK/$dylib_name" ]]; then
    cp "$dylib_src" "$FWK/$dylib_name"
    chmod +w "$FWK/$dylib_name"
    int_tool -id "@executable_path/../Frameworks/$dylib_name" "$FWK/$dylib_name"
  fi
  # @loader_path is the .so's own folder. Six levels up reaches Contents/Frameworks/:
  #   lib-dynload/ -> python3.14/ -> lib/ -> 3.14/ -> Versions/ -> Python.framework/ -> Frameworks/
  int_tool -change "$old_dep" "@loader_path/../../../../../../$dylib_name" "$so"
}
while read -r so; do
  chmod +w "$so"
  { otool -L "$so" | tail -n +2 | awk '{print $1}' | grep '^/opt/homebrew' || true; } | while read -r dep; do
    patch_so_dep "$so" "$dep"
  done
done < <(find "$DYNLOAD_DIR" -name "*.so")

# ── 4c. Make dylib-to-dylib references in Frameworks/ loader-relative ─────────
# dylibbundler writes @executable_path/../Frameworks/ into every bundled dylib. That
# only resolves when the main app binary is the executable. When Python loads e.g.
# libssl.4.dylib from a lib-dynload .so, @executable_path is the venv's python3,
# so libssl can't find libcrypto. All these dylibs sit side by side in Frameworks/,
# so @loader_path/<name> resolves correctly whoever the executable is.
echo "Rewriting Frameworks/ dylib cross-references to @loader_path…"
for dylib in "$FWK"/*.dylib; do
  deps=("${(@f)$(otool -L "$dylib" | tail -n +3 | awk '{print $1}' | grep '^@executable_path/../Frameworks/' || true)}")
  [[ -z "${deps[1]}" ]] && continue
  chmod +w "$dylib"
  for dep in "${deps[@]}"; do
    int_tool -change "$dep" "@loader_path/${dep:t}" "$dylib"
  done
done

# The CLI tools run as their own processes, so for them @executable_path is
# Resources/bin/ and dylibbundler's ../Frameworks/ points at the nonexistent
# Resources/Frameworks/. Two levels up reaches Contents/Frameworks/.
for tool in "$BIN/c2patool" "$BIN/pdfimages" "$BIN/openssl3"; do
  deps=("${(@f)$(otool -L "$tool" | tail -n +2 | awk '{print $1}' | grep '^@executable_path/../Frameworks/' || true)}")
  [[ -z "${deps[1]}" ]] && continue
  for dep in "${deps[@]}"; do
    int_tool -change "$dep" "@executable_path/../../Frameworks/${dep:t}" "$tool"
  done
done

# ── 4d. Remove build-machine leftovers ────────────────────────────────────────
# Absolute LC_RPATHs (/opt/homebrew/lib, /opt/homebrew/Cellar/…, CI paths in wheels)
# would let a missing @rpath library resolve to Homebrew on Macs that have it.
echo "Removing absolute rpaths…"
macho_files "$APP" > "$WORK/macho.txt"
while read -r f; do
  { otool -l "$f" | awk '$1 == "cmd" && $2 == "LC_RPATH" {getline; getline; print $2}' \
    | grep '^/' || true; } | sort -u | while read -r rpath; do
      chmod +w "$f"
      int_tool -delete_rpath "$rpath" "$f"
    done
done < "$WORK/macho.txt"
# Static libraries (numpy ships two) are never loaded; notarization is happier without them.
find "$APP" -name '*.a' -delete
# PyInstaller bootloaders — unused and can't be signed without their own entitlements.
rm -rf "$RES/venv/lib/python3.14/site-packages/PyInstaller"

# ── 4e. Bytecode ──────────────────────────────────────────────────────────────
# cp -R doesn't keep file times, so every copied .pyc is stale and Python would rewrite
# it inside the bundle (breaking the seal). Replace them with unchecked-hash .pyc files,
# which Python uses as they are; the app also sets PYTHONDONTWRITEBYTECODE=1.
echo "Precompiling Python bytecode…"
find "$PY_FWK/lib/python3.14" "$RES/venv" -name __pycache__ -type d -prune -exec rm -rf {} +
# A few files in test folders are deliberately invalid Python, so compileall's exit
# status is ignored; anything that fails to compile is compiled in memory when imported.
env -u PYTHONPYCACHEPREFIX "$PY_BASE/bin/python3.14" -B -m compileall -q -j 0 \
  --invalidation-mode unchecked-hash \
  "$PY_FWK/lib/python3.14" "$RES/venv/lib/python3.14/site-packages" >/dev/null || true

# ── 5. App icon ───────────────────────────────────────────────────────────────
ICONSET="$WORK/AppIcon.iconset"
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
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# ── 7. Sign the full app ──────────────────────────────────────────────────────
# Notarization requires every Mach-O inside the app to be signed with Developer ID and
# hardened runtime. Sign leaf binaries first, then the nested bundles, then the app.
# No --deep: it would re-sign nested code with the app's options and drop the Python
# entitlements.
echo "Signing all binaries…"
# Under hardened runtime, Python needs these: ctypes/cffi callbacks map executable memory,
# and the venv's wheels carry dylibs that library validation would otherwise refuse.
PY_ENTITLEMENTS="$WORK/python.entitlements"
cat > "$PY_ENTITLEMENTS" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict>
</plist>
ENT
py_sign_args=()
[[ -n "$SIGN_ID" ]] && py_sign_args=(--entitlements "$PY_ENTITLEMENTS")

sign_failures=()
macho_files "$APP" > "$WORK/macho.txt"
while read -r f; do
  extra=()
  [[ "$f" == "$RES/venv/bin/python"* || "$f" == */Python.app/Contents/MacOS/Python ]] && extra=("${py_sign_args[@]}")
  codesign "${CODESIGN_ARGS[@]}" "${extra[@]}" "$f" 2>"$WORK/sign.err" \
    || sign_failures+=("$f: $(tail -1 "$WORK/sign.err")")
done < <(sort -r "$WORK/macho.txt")   # reverse order: files inside a folder before the folder's own
if (( ${#sign_failures[@]} )); then
  printf 'Signing failed for %d file(s):\n' ${#sign_failures[@]} >&2
  printf '  %s\n' "${sign_failures[@]}" >&2
  exit 1
fi
codesign "${CODESIGN_ARGS[@]}" "${py_sign_args[@]}" "$PY_FWK/Resources/Python.app"
codesign "${CODESIGN_ARGS[@]}" "$PY_FWK"
codesign "${CODESIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $(pwd)/$APP"

# ── 8. Validate bundle before packaging ──────────────────────────────────────
echo "Running bundle validation tests…"
if zsh "$REPO/tests/test_bundle.sh" "$(pwd)/$APP"; then
    echo "All bundle checks passed."
else
    echo "Bundle validation FAILED. Fix the issues above before packaging." >&2
    exit 1
fi

# ── 9. Notarize and staple (only when SIGN_ID + NOTARY_PROFILE are set) ───────
notarize() {
  local out id
  echo "Submitting $1 to Apple notarization (this takes 1–15 minutes)…"
  out=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
  print -r -- "$out"
  if ! grep -q 'status: Accepted' <<< "$out"; then
    id=$(awk '/^  id:/ {print $2; exit}' <<< "$out")
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2
    echo "Notarization of $1 failed." >&2
    exit 1
  fi
}
NOTARIZE=0
[[ -n "$SIGN_ID" && -n "$NOTARY_PROFILE" ]] && NOTARIZE=1

# The app is notarized and stapled on its own first, so it carries its ticket after it is
# copied out of the DMG and opens without a network check.
if (( NOTARIZE )); then
  ditto -c -k --keepParent "$APP" "$WORK/app.zip"
  notarize "$WORK/app.zip"
  xcrun stapler staple "$APP"
fi

# ── 10. DMG installer ─────────────────────────────────────────────────────────
DMG="JTag Provenance Studio.dmg"
DMG_STAGE="$WORK/dmg"
mkdir -p "$DMG_STAGE"
ditto "$APP" "$DMG_STAGE/$APP"
codesign --verify --deep --strict "$DMG_STAGE/$APP"
ln -s /Applications "$DMG_STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "JTag Provenance Studio" \
  -srcfolder "$DMG_STAGE" \
  -ov -format UDZO \
  -o "$DMG" >/dev/null
if [[ -n "$SIGN_ID" ]]; then
  codesign "${CODESIGN_ARGS[@]}" "$DMG"
fi
echo "DMG: $(pwd)/$DMG"

if (( NOTARIZE )); then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
  spctl --assess --type execute -v "$APP"
  echo "Notarized and stapled: $DMG"
elif [[ -n "$SIGN_ID" ]]; then
  echo ""
  echo "Signed with Developer ID but not notarized."
  echo "Set NOTARY_PROFILE to notarize. See build.sh header for setup instructions."
fi
