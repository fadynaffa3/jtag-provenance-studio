#!/bin/zsh
# Builds "Provenance Studio.app" next to this script. Needs Xcode; the app runs ../tools/detect_ai_provenance.py.
set -euo pipefail
cd "$(dirname "$0")"
APP="Provenance Studio.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -parse-as-library -O -target arm64-apple-macos14 -o "$APP/Contents/MacOS/ProvenanceStudio" ProvenanceStudio.swift
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Provenance Studio</string>
  <key>CFBundleDisplayName</key><string>Provenance Studio</string>
  <key>CFBundleIdentifier</key><string>local.provenance-studio</string>
  <key>CFBundleExecutable</key><string>ProvenanceStudio</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
