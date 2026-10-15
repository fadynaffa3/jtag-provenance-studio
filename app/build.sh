#!/bin/zsh
# Builds "JTag Provenance Studio.app" next to this script. Needs Xcode; the app runs ../tools/detect_ai_provenance.py.
set -euo pipefail
cd "$(dirname "$0")"
APP="JTag Provenance Studio.app"
rm -rf "$APP" "Provenance Studio.app"  # also the build from before the rename
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -parse-as-library -O -target arm64-apple-macos14 -o "$APP/Contents/MacOS/JTagProvenanceStudio" JTagProvenanceStudio.swift

ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
swift make_icon.swift "$ICONSET/icon_512x512@2x.png" >/dev/null
for px in 16 32 128 256 512; do
  sips -z $px $px "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
  [[ $px != 512 ]] && sips -z $((px * 2)) $((px * 2)) "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

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
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
