# JTag Provenance Studio

Scans images and Illustrator/PDF files for AI-provenance signals, removes AI metadata tags, and signs output copies with Content Credentials (C2PA).

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

### Option A — self-contained DMG (nothing to install)

Everything is bundled: Python, ML model weights, exiftool, c2patool, pdfimages, and all shared libraries. No Homebrew, Python, or Xcode needed.

1. Download `JTag Provenance Studio.dmg` from the [latest release](https://github.com/fadynaffa3/jtag-provenance-studio/releases/latest)
2. Open the DMG and drag **JTag Provenance Studio** into your Applications folder
3. On first launch, macOS will say it cannot verify the app. To open it anyway:
   - **Right-click** (or Control-click) the app in Finder → **Open**
   - Click **Open** in the dialog that appears
   - You only need to do this once

> The app is ad-hoc signed for local use, not submitted to Apple's notarization service. It does not connect to the internet except to timestamp Content Credentials signatures (optional; offline fallback is built in).

### Option B — install prerequisites + run from source

A single script installs Homebrew (if needed), the required tools, a Python venv, and builds a lightweight Mac app that reads directly from the repo checkout:

```sh
curl -fsSL https://raw.githubusercontent.com/fadynaffa3/jtag-provenance-studio/main/install.sh | sh
```

What it does:
- Installs Homebrew if not already present
- `brew install exiftool c2patool poppler openssl@3`
- Creates `~/ai-provenance/tools/.venv` and installs `trustmark`, `invisible-watermark`, `pillow`, `numpy`
- Builds and installs a lightweight `JTag Provenance Studio.app` to `/Applications`

> TrustMark model weights (~2 GB total) are downloaded on the **first run**, not during install. Internet access is required once for that download.

After the script finishes you can also use the CLI directly:

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
brew install dylibbundler exiftool c2patool poppler openssl@3
python3 -m venv tools/.venv
tools/.venv/bin/pip install trustmark invisible-watermark pillow numpy
zsh app/build.sh
```

## License

For personal, non-commercial, and research use only.
