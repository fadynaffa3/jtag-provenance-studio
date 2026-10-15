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

See [AGENTS.md](AGENTS.md) for build instructions, CLI usage, and technical invariants.

## Prerequisites

- macOS, Apple silicon
- Xcode (`swiftc`, `iconutil`)
- Homebrew: `brew install exiftool c2patool poppler openssl@3`
- Python 3.12+ virtualenv in `tools/.venv`:
  ```sh
  python3 -m venv tools/.venv
  tools/.venv/bin/pip install trustmark invisible-watermark pillow numpy
  ```

## Quick start

```sh
# Build and open the app
zsh app/build.sh
open app/"JTag Provenance Studio.app"

# Or use the CLI directly
PY=tools/.venv/bin/python; T=tools/detect_ai_provenance.py
$PY $T image.png                          # scan only
$PY $T image.png --strip --out output/   # strip AI tags, save clean copy
$PY $T image.png --no-watermarks         # metadata and C2PA only (fast)
```

## License

For personal, non-commercial, and research use only.
