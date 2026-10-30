# Build, Signing & Distribution

This document covers how JTag Provenance Studio is built into a self-contained `.app`, signed, notarized, and distributed — and all the non-obvious decisions made along the way.

---

## Overview

The app ships as a notarized DMG containing a fully self-contained `JTag Provenance Studio.app`. "Self-contained" means the user needs no Homebrew, no Python install, no Xcode — just the DMG. Everything (Python 3.14, its standard library, the venv with ML packages, `exiftool`, `c2patool`, `pdfimages`, all shared dylibs) is bundled inside `Contents/`.

Build script: `app/build.sh`
Bundle validation tests: `tests/test_bundle.sh`

---

## Build steps (`app/build.sh`)

### 1. Swift binary
Compiled with `-O -target arm64-apple-macos14`. Outputs to `Contents/MacOS/JTagProvenanceStudio`.

### 2. Python engine and venv
- `tools/detect_ai_provenance.py` is copied to `Contents/Resources/`.
- The entire `tools/.venv` is copied to `Contents/Resources/venv/`.
- The Python standard library from the Homebrew Python framework (`/opt/homebrew/Cellar/python@3.14/.../lib/python3.14`) is copied to `Contents/Resources/python3.14-stdlib/`. This is required because `venv` only contains site-packages, not stdlib.
- `venv/pyvenv.cfg` is blanked to `home = BUNDLE_PLACEHOLDER` — the Swift app rewrites it with correct absolute paths at every launch (since the app can be installed anywhere).
- The venv's `python3`/`python3.14`/`python` symlinks are replaced with real copies of the Python binary, with install names rewritten to `@loader_path/../../../Frameworks/Python.framework/...` so they resolve relative to the binary itself, not the main app executable.

### 3. External binaries
- `c2patool` — Content Credentials signer
- `pdfimages` — from Poppler, extracts images from PDFs
- `openssl3` — from OpenSSL 3, used for `--create-identity` (key/cert generation); symlinked as `openssl` so `shutil.which("openssl")` finds it
- `exiftool` — Perl script; shebang patched to `#!/usr/bin/perl` (system Perl, always present on macOS); its lib tree copied to `Contents/Resources/exiftool-lib/`

### 4. Shared libraries (dylibbundler)
`dylibbundler` crawls `c2patool`, `pdfimages`, and `openssl3`, copies their Homebrew dylib dependencies into `Contents/Frameworks/`, and rewrites install names to `@executable_path/../Frameworks/<lib>`.

**Why `@executable_path` here:** these binaries are in `Contents/Resources/bin/`, and `@executable_path` resolves relative to the main app executable in `Contents/MacOS/`. From `bin/`, the path is `../Frameworks/` — correct.

The Python framework is copied **after** dylibbundler, because dylibbundler wipes `Frameworks/` before writing. Python requires the full framework structure (`Python.framework/Versions/3.14/Python` + `Resources/Python.app/...`), not just the bare dylib.

### 4b. Patching stdlib `.so` Homebrew dependencies
Python's `lib-dynload/` contains C extensions (`_lzma`, `_ssl`, `_hashlib`, `_sqlite3`, `_decimal`, `_zstd`, etc.) that were compiled against Homebrew-signed dylibs. This caused "mapping process and mapped file have different Team IDs" errors on macOS — the Homebrew-signed dylibs have a different Team ID from the ad-hoc or Developer ID signature on the bundled app.

**Fix:** For every `.so` in `lib-dynload/` that links to `/opt/homebrew/`:
1. Copy the Homebrew dylib to `Contents/Frameworks/` (if not already there from dylibbundler).
2. Rewrite the dylib's own `-id` to `@executable_path/../Frameworks/<name>`.
3. **Rewrite the dylib's internal cross-dependencies** (other Homebrew dylibs it links to) from `@executable_path/../Frameworks/` to `@loader_path/<name>`. This matters because when `libssl.4.dylib` is loaded via `dlopen` from a `.so` in `lib-dynload/`, `@executable_path` resolves to `Python.app/Contents/MacOS/Python` (the inner Python.app wrapper), not the main app — so `libcrypto.4.dylib` wouldn't be found without this fix.
4. Rewrite the `.so`'s dependency to `@loader_path/../../../Frameworks/<name>`. From `lib-dynload/`, three levels up reaches `Contents/Frameworks/` (`lib-dynload/ → python3.14-stdlib/ → Resources/ → Contents/`).
5. Sign the `.so`.

### 5. App icon
Built from `make_icon.swift` → resized via `sips` → compiled to `AppIcon.icns` via `iconutil`.

### 6. Info.plist
Written inline. Key fields:
- `CFBundleIdentifier`: `com.jtag.provenance-studio`
- `CFBundleShortVersionString`: current version (e.g. `0.1.0`)
- `LSMinimumSystemVersion`: `14.0`

### 7. Sign the full app
All Mach-O binaries inside the bundle are signed depth-first (leaf binaries before parent bundles). The Python.app sub-bundle is signed explicitly with `--deep`. Then the top-level app bundle is signed.

**Ad-hoc signing** (`SIGN_ID` unset): `codesign --force --sign -`. Fine for local use; no Gatekeeper clearance.

**Developer ID signing** (`SIGN_ID="Developer ID Application: Fady Naffa (LQWP28E4S9)"`): `codesign --force --options runtime --sign "$SIGN_ID"`. Required for notarization.

### 8. Bundle validation tests
`tests/test_bundle.sh` runs before DMG packaging. If any check fails, the build aborts. Checks:
1. No Mach-O inside the bundle links to a dylib outside the bundle (except `/usr/lib` and `/System`).
2. No `.so` files in `lib-dynload/` link to `/opt/homebrew/`.
3. Python can `import hashlib`, `lzma`, `mmap`, `ssl`, `sqlite3`, `_decimal`, `zlib`.
4. Watermark ML stack (`PIL`, `numpy`, `cv2`, `imwatermark`, `trustmark`) — optional, skipped if not installed.
5. Code signature is valid.

### 10. DMG
Staged into a temp dir with an `/Applications` symlink, then packed with `hdiutil create -format UDZO`.

### 11. Notarization and stapling
Only when both `SIGN_ID` and `NOTARY_PROFILE` are set:
```sh
xcrun notarytool submit "JTag Provenance Studio.dmg" \
  --keychain-profile "jtag-notary" --wait
xcrun stapler staple "JTag Provenance Studio.dmg"
```
Takes 1–5 minutes. The stapled ticket is embedded in the DMG so it works offline.

---

## Signing identity

**Developer ID:** `Developer ID Application: Fady Naffa (LQWP28E4S9)`
**Team ID:** `LQWP28E4S9`
**Notarization keychain profile:** `jtag-notary`

One-time setup for the notarization profile:
```sh
xcrun notarytool store-credentials "jtag-notary" \
  --apple-id "fadynaffa3@gmail.com" \
  --team-id "LQWP28E4S9" \
  --password "<app-specific-password>"
```

The app's own signing identity (for C2PA — separate from the build signing) lives in `~/Library/Application Support/JTag Provenance Studio/identity/` and is created via `--create-identity` or "Set Up Signing Identity…" in the app.

---

## Running a release build

```sh
# Ad-hoc (verify tests pass first, fast)
zsh app/build.sh

# Notarized release
SIGN_ID="Developer ID Application: Fady Naffa (LQWP28E4S9)" \
NOTARY_PROFILE="jtag-notary" \
zsh app/build.sh
```

After a successful notarized build:
```sh
git tag v0.1.0
git push origin v0.1.0
gh release create v0.1.0 \
  --title "JTag Provenance Studio v0.1.0" \
  --notes "..."
gh release upload v0.1.0 "app/JTag Provenance Studio.dmg" --clobber
```

---

## Install script (`install.sh`)

Two modes, prompted interactively:

**Option 1 — Download prebuilt DMG (recommended)**
- Installs Homebrew if absent
- `brew install exiftool c2patool poppler openssl@3`
- Downloads the latest DMG from GitHub Releases (`gh release download` or `curl` fallback)
- Mounts, copies app to `/Applications`, unmounts
- Runs `codesign --verify` and clears quarantine
- Launches the app

**Option 2 — Build from source**
- Clones repo to `~/ai-provenance` (or pulls if present)
- `brew install exiftool c2patool poppler openssl@3`
- `zsh app/build.sh` (ad-hoc signed)
- Copies app to `/Applications`

**After install, re-signing:**
The installer runs `codesign -s - --deep --force "/Applications/JTag Provenance Studio.app"` after copying, because the notarization staple doesn't survive `cp` — the quarantine attribute is cleared and the ad-hoc re-sign ensures macOS accepts the app without Gatekeeper warnings on machines that haven't downloaded it.

---

## PYTHONPATH in the app

The Swift app (`JTagProvenanceStudio.swift`, `makeProcess()`) sets:
```
PYTHONPATH = <stdlib>:<site-packages>:<lib-dynload>
```
where:
- `stdlib` = `Contents/Resources/python3.14-stdlib`
- `site-packages` = `Contents/Resources/venv/lib/python3.14/site-packages`
- `lib-dynload` = `Contents/Resources/python3.14-stdlib/lib-dynload`

`lib-dynload` must be explicit because Python doesn't add it automatically when running from a venv whose home points into a bundled framework rather than a standard Homebrew prefix.

---

## Known non-issues

- **`install_name_tool` warnings about invalidating code signature** — expected; the subsequent `codesign` step re-signs everything.
- **PyInstaller bootloaders removed** — `venv/lib/python3.14/site-packages/PyInstaller/` is deleted before signing because those bootloaders can't be signed without their own entitlements and are unused.
- **dylibbundler wipes `Frameworks/`** — this is why the Python framework is copied in a separate step after dylibbundler runs.
