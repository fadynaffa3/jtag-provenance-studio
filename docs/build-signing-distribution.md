# Build, Signing & Distribution

This document covers how JTag Provenance Studio is built into a self-contained `.app`, signed, notarized, and distributed — and the non-obvious decisions made along the way.

---

## Overview

The app ships as a notarized DMG containing a fully self-contained `JTag Provenance Studio.app`. "Self-contained" means the user needs no Homebrew, no Python install, no Xcode and no internet — just the DMG. Everything (Python 3.14 and its standard library, the venv with the ML packages, the TrustMark model weights, `exiftool`, `c2patool`, `pdfimages`, `openssl`, and all their shared libraries) is inside `Contents/`.

Build script: `app/build.sh`
Bundle validation tests: `tests/test_bundle.sh`

Two rules everything below follows:

1. **Nothing may resolve outside the bundle.** The build Mac has Homebrew, so a library or module that quietly falls back to `/opt/homebrew` works here and fails on every other Mac. The tests run the bundle with Homebrew off `PATH` and fail on any outside load.
2. **Nothing may write into the bundle after signing.** A new or changed file inside a signed app breaks its seal, and macOS then reports a notarized app as "damaged". That rules out Python writing `.pyc` files, TrustMark downloading weights, and the app rewriting `pyvenv.cfg`.

---

## Build prerequisites

```sh
brew install dylibbundler exiftool c2patool poppler openssl@3 python@3.14
$(brew --prefix python@3.14)/bin/python3.14 -m venv tools/.venv
tools/.venv/bin/pip install trustmark invisible-watermark pillow numpy
```

The venv must be made from Homebrew's `python3.14`, because the build bundles that same framework; `build.sh` stops if the versions differ. Only one build can run at a time: `build.sh` takes a lock (`app/.build.lock`), because two builds in `app/` delete each other's bundle.

---

## Build steps (`app/build.sh`)

### 1. Swift binary
Compiled with `-O -target arm64-apple-macos14`. Outputs to `Contents/MacOS/JTagProvenanceStudio`.

### 2. Python engine and venv
- `tools/detect_ai_provenance.py` is copied to `Contents/Resources/`.
- **TrustMark weights are fetched first.** TrustMark downloads its weights next to its own code on first use, which inside the app would write into the signed bundle (and fail for users who can't write to `/Applications`). The build loads variants Q, P, B and C once in `tools/.venv`, which downloads anything missing (~550 MB, first build only), and then ships them.
- The entire `tools/.venv` is copied to `Contents/Resources/venv/`.
- `venv/pyvenv.cfg` keeps placeholder paths. Nothing reads them: Python finds its stdlib inside the framework (step 4) and the app adds site-packages through `PYTHONPATH`.
- The venv's `python3`/`python3.14`/`python` symlinks are replaced with real copies of the Python binary, with install names rewritten to `@loader_path/../../../Frameworks/Python.framework/...`. The symlink is deleted *before* `install_name_tool` runs: running it on the symlink edits Homebrew's own `python3.14` and breaks its signature, after which macOS kills every `python3` start.

Homebrew paths are found with `brew --prefix`, not by listing the Cellar (`ls | tail -1` sorts `3.14.10` before `3.14.9`).

### 3. External binaries
- `c2patool` — Content Credentials signer
- `pdfimages` — from Poppler, extracts images from PDFs
- `openssl3` — from OpenSSL 3, used for `--create-identity`; symlinked as `openssl` so `shutil.which("openssl")` finds it
- `exiftool` — Perl script; shebang patched to `#!/usr/bin/perl` (system Perl); its lib tree copied to `Contents/Resources/exiftool-lib/`

### 4. Shared libraries and the Python framework
`dylibbundler` copies the tools' Homebrew dylib dependencies into `Contents/Frameworks/`. It wipes `Frameworks/` first, so the Python framework is copied afterwards.

The standard library is copied to `Frameworks/Python.framework/Versions/3.14/lib/python3.14` — the framework's real layout. Python locates its stdlib from the framework dylib's own location, so it finds this one. With the stdlib anywhere else, Python falls back to its compiled-in prefix (`/opt/homebrew/...`): on the build Mac that silently loads Homebrew's stdlib, and on a clean Mac it prints "Could not find platform independent libraries". The stdlib's `site-packages` symlink and `config-3.14-darwin` (symlinks to libpython, only used to compile extensions) are removed, since they point back into Homebrew.

**How `@executable_path` and `@loader_path` resolve** — the cause of most of the breakage so far:
- `@executable_path` is the main executable of the *running process*, not the app. When the app runs `Resources/bin/c2patool`, it's `Resources/bin/`. When Python loads a library, it's `Resources/venv/bin/`.
- `@loader_path` is the folder of the binary that contains the reference. It's the same whoever loads it.

So:
- **4b.** Stdlib C extensions (`lib-dynload/*.so`) that link to Homebrew dylibs get those dylibs copied into `Frameworks/` and their references rewritten to `@loader_path/../../../../../../<dylib>` (six levels up from `lib-dynload/` is `Contents/Frameworks/`).
- **4c.** dylibbundler writes `@executable_path/../Frameworks/` into every bundled dylib. Dylib-to-dylib references are rewritten to `@loader_path/<name>`, since they all sit side by side in `Frameworks/`. (Without this, `libssl.4.dylib` loaded by Python looked for `libcrypto.4.dylib` relative to the venv's `python3`.)
- The tools in `Resources/bin/` are rewritten to `@executable_path/../../Frameworks/<dylib>`. With dylibbundler's `../Frameworks/` they looked in the nonexistent `Resources/Frameworks/` and could not start on any Mac; it went unnoticed because the app also had Homebrew on `PATH`.

### 4d. Build-machine leftovers
- Absolute `LC_RPATH`s (`/opt/homebrew/lib`, Cellar paths, CI paths inside wheels) are deleted, so a missing `@rpath` library can't resolve to Homebrew on Macs that have it.
- Static libraries (`*.a`, from numpy) and PyInstaller's bootloaders are deleted.

### 4e. Bytecode
`cp -R` doesn't keep file times, so every copied `.pyc` is stale and Python would rewrite it inside the bundle. All `__pycache__` folders are removed and the stdlib and site-packages are recompiled with `--invalidation-mode unchecked-hash`: Python uses those `.pyc` files as they are, without comparing them to the source. The app also sets `PYTHONDONTWRITEBYTECODE=1`.

### 5. App icon
Built from `make_icon.swift` → resized via `sips` → compiled to `AppIcon.icns` via `iconutil`.

### 6. Info.plist
Written inline. Key fields:
- `CFBundleIdentifier`: `com.jtag.provenance-studio`
- `CFBundleShortVersionString`: `0.1.0`
- `LSMinimumSystemVersion`: `14.0`

### 7. Signing
Every Mach-O file is signed individually, then the nested bundles (`Python.app`, then `Python.framework/Versions/3.14`), then the app. Any signing failure stops the build. `--deep` is not used for signing: it re-signs nested code with the outer bundle's options and would drop the Python entitlements.

**Ad-hoc** (`SIGN_ID` unset): `codesign --force --sign -`. For local use only.

**Developer ID** (`SIGN_ID="Developer ID Application: Fady Naffa (LQWP28E4S9)"`): `codesign --force --options runtime --timestamp --sign "$SIGN_ID"`. The Python executables (`venv/bin/python*` and `Python.app`) also get these entitlements, which Python needs under the hardened runtime:
- `com.apple.security.cs.allow-unsigned-executable-memory` — ctypes/cffi callbacks
- `com.apple.security.cs.disable-library-validation` — dylibs shipped inside wheels

### 8. Bundle validation tests
`tests/test_bundle.sh` runs on the signed app before anything is notarized or packaged; any failure stops the build. Its runtime checks use a clean environment (`PATH` = bundle `bin` + `/usr/bin:/bin`, the same variables the app sets, a throwaway `HOME`):
1. Every Mach-O is arm64, every dependency resolves inside the bundle or to the system, and there are no absolute rpaths. A library that uses `@executable_path` fails.
2. No dangling symlinks.
3. `c2patool`, `pdfimages`, `openssl` and `exiftool` start.
4. Python imports its C extensions and the watermark stack, and `sys.base_prefix`, `sys.path` and every loaded module are inside the bundle, with nothing on stderr.
5. dyld loads nothing from `/opt/homebrew` (`DYLD_PRINT_LIBRARIES`; hardened runtime suppresses this, so it only runs on ad-hoc builds).
6. TrustMark loads all four variants with downloads blocked.
7. End to end: a tagged JPEG is fully scanned (watermarks included) and stripped clean; images are extracted from a PDF; an identity is created and an output copy is signed and read back with `c2patool`.
8. Last: `codesign --verify --deep --strict` still passes after all of the above ran, which proves running the bundle doesn't write into it. On Developer ID builds every Mach-O must also carry the team ID and hardened runtime.

Run it on its own with `zsh tests/test_bundle.sh [path/to/app]`. Run an ad-hoc build first: check 5 only works there.

### 9. Notarize and staple the app
Only when both `SIGN_ID` and `NOTARY_PROFILE` are set. The app is zipped (`ditto -c -k --keepParent`), notarized and stapled on its own, so it carries its ticket after being copied out of the DMG and opens without a network check. On a rejection the build prints Apple's log and stops.

### 10. DMG
The app is copied with `ditto` (which keeps the stapled ticket), its signature is verified again, and it's packed with an `/Applications` symlink using `hdiutil create -format UDZO`. With `SIGN_ID` set the DMG is signed too.

### 11. Notarize and staple the DMG
The DMG is notarized and stapled, then checked with `spctl --assess` (both the DMG and the app).

---

## Signing identity

**Developer ID:** `Developer ID Application: Fady Naffa (LQWP28E4S9)`
**Team ID:** `LQWP28E4S9`
**Notarization keychain profile:** `jtag-notary`

One-time setup for the notarization profile:
```sh
xcrun notarytool store-credentials "jtag-notary" \
  --apple-id "<apple-id>" \
  --team-id "LQWP28E4S9" \
  --password "<app-specific-password>"
```

The app's own signing identity (for C2PA — separate from the build signing) lives in `~/Library/Application Support/JTag Provenance Studio/identity/` and is created via `--create-identity` or "Set Up Signing Identity…" in the app.

---

## Running a release build

```sh
# Ad-hoc first: all test checks run (including the dyld check), fast to iterate
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
gh release create v0.1.0 "app/JTag Provenance Studio.dmg" \
  --title "JTag Provenance Studio v0.1.0" \
  --notes "..."
```

---

## Install script (`install.sh`)

Run as the normal user (it refuses `sudo`). It installs into `/Applications` when the user can write there, otherwise into `~/Applications`, so standard accounts need no password. Two modes, prompted interactively:

**Option 1 — Download prebuilt DMG (recommended)**
- Downloads the latest DMG from GitHub Releases into a temporary folder
- Mounts it read-only and verifies the app's signature; a broken signature stops the install rather than being papered over
- Copies the app with `ditto` and unmounts (also on failure)
- Launches the app

No Homebrew or other tools are installed: the app is self-contained.

**Option 2 — Build from source**
- Clones the repo to `~/ai-provenance` (or pulls if present)
- Needs Xcode; installs Homebrew if missing, then `brew install dylibbundler exiftool c2patool poppler openssl@3 python@3.14`
- Creates `tools/.venv` from Homebrew's `python3.14` and installs the Python packages
- Runs `zsh app/build.sh` (ad-hoc signed, same self-contained app as the release) and installs it

---

## Environment the app gives the CLI

`makeProcess()` in `JTagProvenanceStudio.swift` sets:
- `PATH` = `Contents/Resources/bin`, then `/opt/homebrew/bin:/usr/local/bin` (only used by dev builds without bundled tools), then the inherited `PATH`
- `PERLLIB` = `Contents/Resources/exiftool-lib`
- `PYTHONPATH` = `Contents/Resources/venv/lib/python3.14/site-packages`
- `PYTHONDONTWRITEBYTECODE=1`, `PYTHONUNBUFFERED=1`

`--show-identity` is read from stdout only, so a warning on stderr can't corrupt its JSON and silently turn signing off.

---

## Known non-issues

- **Pillow loads `libfribidi` from Homebrew on the build Mac.** It's an optional `dlopen` for bidirectional text; on a clean Mac it isn't found and Pillow does without it. The dyld check allows exactly this library.
- **The engine loads all four TrustMark variants with their encoder and remover on every scan**, which is most of a scan's start-up time. Loading only the decoders would be faster; that's an engine change, not a packaging one.
