# JTag Provenance Studio

Scans images and Illustrator/PDF files for AI-provenance signals, removes AI metadata tags, and signs
output copies with Content Credentials (C2PA). It has two parts:

| Path | What it is |
|---|---|
| `tools/detect_ai_provenance.py` | The engine and CLI. All the scanning, stripping and signing happens here. |
| `app/JTagProvenanceStudio.swift` | The SwiftUI Mac app: a window that runs the CLI and shows the results. |
| `app/make_icon.swift` | Draws the app icon. `build.sh` turns it into `AppIcon.icns`. |
| `app/build.sh` | Builds `app/JTag Provenance Studio.app`. |

The app finds the CLI at the fixed path `~/ai-provenance/tools`, so the repo must be checked out at
`~/ai-provenance`.

## Prerequisites (macOS, Apple silicon)

- **Xcode**, for `swiftc`, `swift` and `iconutil`.
- **Homebrew tools:**
  ```sh
  brew install exiftool c2patool poppler openssl@3   # poppler provides pdfimages
  ```
- **Python 3.12+ virtualenv** in `tools/.venv`. Watermark decoding needs these packages:
  ```sh
  python3 -m venv tools/.venv
  tools/.venv/bin/pip install trustmark invisible-watermark pillow numpy
  ```
  TrustMark downloads its decoder weights (variants Q, P, B, C) the first time it runs, so that
  first run needs internet.

## Build and run the app

```sh
zsh app/build.sh                                   # build.sh isn't executable, so call it through zsh
open app/"JTag Provenance Studio.app"
```

- To pick up changes to the Swift file or the icon, quit the app (⌘Q) and rebuild.
- Changes to the Python script take effect on the next run, with no rebuild.
- The build is ad-hoc signed (`codesign -s -`). That's fine for local use. Distributing the app
  would need a Developer ID and notarization.
- Closing the window doesn't quit the app. Use ⌘N to get a window back.
- Apps started from Finder get a minimal `PATH`, so the app prepends `/opt/homebrew/bin:/usr/local/bin`
  before it runs the CLI.

Before rebuilding, check that the Swift code compiles:
```sh
swiftc -parse-as-library -typecheck -target arm64-apple-macos14 app/JTagProvenanceStudio.swift
```

## Run the CLI directly

```sh
PY=tools/.venv/bin/python; T=tools/detect_ai_provenance.py
$PY $T INPUT...                                   # scan only (read-only)
$PY $T INPUT... --no-watermarks                   # metadata and C2PA only, fast
$PY $T INPUT... --strip --rename --out output     # cleaned copies in output/
$PY $T INPUT... --sign                            # signed copies (needs an identity)
$PY $T --create-identity "Full Name"              # one-time signing setup for this Mac's user
$PY $T --show-identity
$PY $T INPUT... --json report.json                # full machine-readable report (the app reads this)
```

The CLI never modifies its inputs. Output copies go to `--out`, which defaults to `~/ai-provenance/output`.
A `.ai` or `.pdf` input is scanned as a container, and its embedded images are extracted into
`--work` (default `~/ai-provenance/work/<name>/`) and scanned too. Extracted images are cached: to
re-extract, delete that folder.

## Behaviour that must stay as it is

- **Inputs are never overwritten.** `make_output` refuses when the output path is the input path.
- **`.ai` and `.pdf` files are cleaned in place, at the same length.** XMP entries and PDF Info
  values are blanked with spaces, so byte offsets and the xref table stay valid and the file isn't
  rewritten. This matters because these files can be over 2 GB.
- **Signing always declares AI content** that was detected, or flagged with `--ai`, as
  `compositeWithTrainedAlgorithmicMedia`. There's no option to sign AI content without declaring
  it. Keep it that way: a signed manifest that omits AI would be false provenance under the
  signer's name. To get an output without credentials, don't sign.
- **The signer is the person using this Mac.** The identity is created with `--create-identity`,
  or in the app via "Set Up Signing Identity…", and lives in
  `~/Library/Application Support/JTag Provenance Studio/identity/`. Only the signer key
  (`signer.p8`, mode 600) is kept; the root key is deleted after the signer certificate is issued.
  Don't create identities for other people.
- **Invisible watermarks are detected, never removed.** Output copies note any watermark that
  survives. SynthID, OpenAI and Meta marks have no public decoder, so the report says "not checkable"
  for those rather than "absent".
- **`.ai` and `.pdf` can't hold an embedded manifest.** Sign the exported images instead.

## Testing

There is no test suite yet. Test changes on throwaway files in a scratch folder:

- **Tagged image:** create a small PNG or JPEG with PIL, add tags with exiftool, then run
  `--strip --rename` and check that the output copy reports clean:
  ```sh
  exiftool -XMP-iptcExt:DigitalSourceType="http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia" \
           -EXIF:UserComment="Steps: 30, Sampler: Euler" -Comment="--ar 4:5 --v 6" test.jpg
  ```
- **Manifest format:** run `c2patool img.png -m manifest.json -o signed.png` with a manifest that
  has no `private_key` or `sign_cert`. It then uses c2patool's built-in test signer.
- **Large files:** run `--no-watermarks --strip` on a real `.ai`. It takes about 12 s for 2.4 GB.
  Afterwards, confirm with `cmp -l` that only the metadata bytes changed, and check that `pdfinfo`
  still reads the file.

## Repo hygiene

- **Never commit client material.** That means `input/`, `work/`, `output/`, `*.ai`, `*.pdf` and
  JSON reports. The scan reports contain designers' file paths and names. `.gitignore` covers
  these; stage files by name, not with `git add -A`.
- The remote is public: `github.com/fadynaffa3/jtag-provenance-studio`.
