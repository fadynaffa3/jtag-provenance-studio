# JTag Provenance Studio · v0.1.0

Scans images and Illustrator/PDF files for AI-provenance signals, removes AI metadata tags, and signs output copies with Content Credentials (C2PA).

*Last updated: October 2026*

## Disclaimer

**This tool is experimental.** It is provided as-is, without warranty of any kind. All usage is entirely at your own risk and responsibility — including any legal, regulatory, or ethical consequences that may arise from its use.

This tool is **not intended for commercial use**.

The authors make no representations about the accuracy or completeness of detected or removed provenance signals. Watermark detection depends on publicly available decoders and may produce false positives or miss marks entirely. Stripping metadata or watermarks from images may implicate copyright law, platform terms of service, or content authenticity regulations in your jurisdiction. You are solely responsible for ensuring your use complies with applicable laws.

## What it does

- Detects AI-provenance signals: EXIF/XMP/IPTC metadata, C2PA Content Credentials manifests, and invisible watermarks (Adobe TrustMark, Stable Diffusion marks)
- Strips flagged metadata and C2PA tags from output copies without modifying the originals
- Attempts pixel-level TrustMark watermark removal on detected marks
- Signs cleaned copies with Content Credentials under your own identity

## Install

Run the one-line installer — it will ask whether to download the prebuilt app or build from source:

```sh
curl -fsSL https://raw.githubusercontent.com/fadynaffa3/jtag-provenance-studio/main/install.sh | sh
```

### Option 1 — Download prebuilt app (recommended)

No Homebrew, Xcode or Python needed — the app is self-contained, watermark models included, and works offline. The installer:
- Downloads the latest notarized DMG from GitHub Releases
- Checks its signature, then installs **JTag Provenance Studio.app** to `/Applications` (or `~/Applications` on a standard, non-admin account)
- Launches the app

The app is signed with a Developer ID and notarized by Apple — no Gatekeeper warnings. You can also download the DMG from the [Releases page](https://github.com/fadynaffa3/jtag-provenance-studio/releases) and drag the app to Applications.

### Option 2 — Build from source

Requires Xcode. The installer:
- Clones the repo to `~/ai-provenance` (or pulls if it already exists)
- Installs Homebrew if needed, then `brew install dylibbundler exiftool c2patool poppler openssl@3 python@3.14`
- Creates the Python environment and runs `app/build.sh` (5–10 minutes; downloads the watermark models once)
- Installs the same self-contained app and launches it

To use the CLI directly (after a source install):

```sh
PY=~/ai-provenance/tools/.venv/bin/python
T=~/ai-provenance/tools/detect_ai_provenance.py
$PY $T image.png                        # scan only
$PY $T image.png --strip --out output/  # strip AI tags
$PY $T image.png --no-watermarks        # fast scan (no watermark check)
```

## For developers: build the self-contained DMG

See [AGENTS.md](AGENTS.md) for build instructions, CLI usage, and technical invariants.

```sh
brew install dylibbundler exiftool c2patool poppler openssl@3 python@3.14
# Use Homebrew's python3.14 explicitly: plain python3 may be a different install.
$(brew --prefix python@3.14)/bin/python3.14 -m venv tools/.venv
tools/.venv/bin/pip install trustmark invisible-watermark pillow numpy
zsh app/build.sh
```

## License

For personal, non-commercial, and research use only.
