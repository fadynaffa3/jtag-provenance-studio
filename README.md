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

## Requirements

- macOS 14+, Apple silicon
- No other prerequisites — everything is bundled in the app

## Install

1. Download `JTag Provenance Studio.dmg` from the [latest release](https://github.com/fadynaffa3/jtag-provenance-studio/releases/latest)
2. Open the DMG and drag **JTag Provenance Studio** into your Applications folder
3. On first launch, macOS will say it cannot verify the app because it is not notarized by Apple. To open it anyway:
   - **Right-click** (or Control-click) the app in Finder and choose **Open**
   - Click **Open** in the dialog that appears
   - You only need to do this once — subsequent launches work normally

> This warning appears because the app is ad-hoc signed for local use, not submitted to Apple's notarization service. The app does not connect to the internet except to timestamp Content Credentials signatures (optional, offline fallback is built in).

## What it does not need

The DMG bundles everything: Python, all ML model weights (TrustMark Q/P/B/C), exiftool, c2patool, pdfimages, and all shared libraries. You do not need Homebrew, Python, or Xcode installed.

## For developers: build from source

See [AGENTS.md](AGENTS.md) for build instructions, CLI usage, and technical invariants.

```sh
# Prerequisites for building (not for running the distributed app)
brew install dylibbundler exiftool c2patool poppler openssl@3
python3 -m venv tools/.venv
tools/.venv/bin/pip install trustmark invisible-watermark pillow numpy pyinstaller

# Build the app and DMG
zsh app/build.sh

# Or use the CLI directly from the repo
PY=tools/.venv/bin/python; T=tools/detect_ai_provenance.py
$PY $T image.png                         # scan only
$PY $T image.png --strip --out output/  # strip AI tags, save clean copy
$PY $T image.png --no-watermarks        # metadata and C2PA only (fast)
```

## License

For personal, non-commercial, and research use only.
