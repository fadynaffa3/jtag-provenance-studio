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

No Xcode or Python needed. The installer:
- Installs Homebrew if not already present
- `brew install exiftool c2patool poppler openssl@3`
- Downloads the latest notarized DMG from GitHub Releases
- Installs **JTag Provenance Studio.app** to `/Applications`
- Launches the app

The app is signed with a Developer ID and notarized by Apple — no Gatekeeper warnings.

### Option 2 — Build from source

Requires Xcode Command Line Tools and Homebrew. The installer:
- Clones the repo to `~/ai-provenance` (or pulls if it already exists)
- `brew install exiftool c2patool poppler openssl@3`
- Compiles and installs a lightweight `JTag Provenance Studio.app` to `/Applications`
- Launches the app

Watermark detection is optional and not installed automatically. To enable it after install:

```sh
python3 -m venv ~/ai-provenance/tools/.venv
~/ai-provenance/tools/.venv/bin/pip install pillow numpy invisible-watermark trustmark
```

> TrustMark model weights (~2 GB) download on first use — internet required once.

To use the CLI directly:

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
