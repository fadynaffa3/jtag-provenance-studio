#!/bin/zsh
# test_bundle.sh — validate a built .app bundle before packaging/notarization
#
# Usage:
#   zsh tests/test_bundle.sh [path/to/JTag\ Provenance\ Studio.app]
#
# The build Mac has Homebrew, so anything that silently falls back to /opt/homebrew
# still "works" here and breaks on a clean Mac. Every runtime check below therefore runs
# with a clean environment (PATH = bundle bin + /usr/bin:/bin, the same variables the
# app sets) and fails if Python or dyld picks up anything from outside the bundle.
#
# Checks:
#   1. Every Mach-O dependency resolves inside the bundle or to the system; no absolute rpaths
#   2. No dangling symlinks
#   3. Bundled tools (c2patool, pdfimages, openssl, exiftool) start
#   4. Python imports its C extensions and the watermark stack, all from inside the bundle
#   5. dyld loads nothing from /opt/homebrew (ad-hoc builds only; hardened runtime
#      ignores DYLD_PRINT_LIBRARIES — check 4 still covers Python)
#   6. TrustMark loads all four variants with downloads blocked (weights are bundled)
#   7. End to end: full scan + strip of a tagged JPEG, PDF image extraction, identity
#      creation and signing (in a throwaway HOME)
#   8. Code signature verifies after all of the above ran, so running the bundle doesn't
#      write into it; on Developer ID builds every Mach-O has the team ID and hardened runtime
#
# Exit 0 = all checks passed. Exit 1 = one or more checks failed.

set -uo pipefail
cd "$(dirname "$0")/.."

APP="${1:-app/JTag Provenance Studio.app}"
APP="$(cd "$APP" 2>/dev/null && pwd)" || { printf '\033[31mError: bundle not found: %s\033[0m\n' "${1:-app/JTag Provenance Studio.app}" >&2; exit 1; }
PASS=0; FAIL=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf '  \033[33m–\033[0m %s\n' "$*"; }
hdr()  { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }

RES="$APP/Contents/Resources"
BIN="$RES/bin"
PYTHON="$RES/venv/bin/python3"
SITEPKGS="$RES/venv/lib/python3.14/site-packages"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home"

# Run a command with only what the app provides — no Homebrew on PATH, no inherited env.
# Mirrors makeProcess() in JTagProvenanceStudio.swift. HOME is a throwaway folder so the
# identity test can't touch the real signing identity.
app_env() {
    env -i HOME="$TMP/home" TMPDIR="$TMP" PATH="$BIN:/usr/bin:/bin" \
        PERLLIB="$RES/exiftool-lib" PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 \
        PYTHONPATH="$SITEPKGS" "$@"
}

# ── 1. Static dependency resolution ───────────────────────────────────────────
hdr "Check 1: every Mach-O dependency resolves inside the bundle or to the system"

macho_count=0
bad_deps=()
while IFS= read -r f; do
    desc=$(file -b "$f")
    [[ "$desc" == *Mach-O* ]] || continue
    macho_count=$((macho_count + 1))
    [[ "$desc" == *arm64* ]] || bad_deps+=("${f#$APP/} has no arm64 code ($desc)")
    is_exec=0; [[ "$desc" == *executable* ]] && is_exec=1
    own_id=$(otool -D -arch arm64 "$f" 2>/dev/null | sed -n 2p)
    while IFS= read -r dep; do
        [[ -z "$dep" || "$dep" == "$own_id" ]] && continue
        case "$dep" in
            /usr/lib/*|/System/*) ;;
            @rpath/*) ;;   # resolved at runtime; covered by checks 4–7
            @loader_path/*)
                [[ -e "${f:h}/${dep#@loader_path/}" ]] || bad_deps+=("${f#$APP/} → $dep (missing)") ;;
            @executable_path/*)
                # Only meaningful for executables: for a library it depends on which
                # program loads it, which is how libssl ended up looking in the wrong place.
                if (( is_exec )); then
                    [[ -e "${f:h}/${dep#@executable_path/}" ]] || bad_deps+=("${f#$APP/} → $dep (missing)")
                else
                    bad_deps+=("${f#$APP/} → $dep (library uses @executable_path; use @loader_path)")
                fi ;;
            *) bad_deps+=("${f#$APP/} → $dep (outside bundle)") ;;
        esac
    done < <(otool -L -arch arm64 "$f" 2>/dev/null | tail -n +2 | awk '{print $1}')
    # An absolute rpath lets a missing @rpath library resolve from the build machine's paths.
    while IFS= read -r rpath; do
        [[ "$rpath" == /* ]] && bad_deps+=("${f#$APP/} has absolute rpath $rpath")
    done < <(otool -l -arch arm64 "$f" 2>/dev/null | awk '$1 == "cmd" && $2 == "LC_RPATH" {getline; getline; print $2}')
done < <(find "$APP" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \))

if (( ${#bad_deps[@]} == 0 )); then
    ok "$macho_count Mach-O files, all arm64, all dependencies resolve, no absolute rpaths"
else
    for d in "${bad_deps[@]}"; do fail "$d"; done
fi

# ── 2. Bundle integrity ───────────────────────────────────────────────────────
hdr "Check 2: no dangling symlinks"

dangling=("${(@f)$(find "$APP" -type l ! -exec test -e {} \; -print)}")
if [[ -z "${dangling[1]}" ]]; then
    ok "No dangling symlinks"
else
    for l in "${dangling[@]}"; do fail "Dangling symlink: ${l#$APP/} → $(readlink "$l")"; done
fi

# ── 3. Bundled tools start ────────────────────────────────────────────────────
hdr "Check 3: bundled tools run with no Homebrew on PATH"

check_tool() {
    local name="$1"; shift
    local out
    if out=$(app_env "$@" 2>&1); then
        ok "$name: $(print -r -- "$out" | head -1)"
    else
        fail "$name exited $?: $(print -r -- "$out" | grep -m1 -E 'Library not loaded|error|Error' || print -r -- "$out" | head -1)"
    fi
}
check_tool c2patool  "$BIN/c2patool" --version
check_tool pdfimages "$BIN/pdfimages" -v
check_tool openssl   openssl version
check_tool exiftool  exiftool -ver

# ── 4. Python imports ─────────────────────────────────────────────────────────
hdr "Check 4: Python imports, all from inside the bundle"

MODULES=(hashlib lzma mmap ssl sqlite3 _decimal zlib PIL numpy cv2 imwatermark trustmark)
for mod in "${MODULES[@]}"; do
    if err=$(app_env "$PYTHON" -c "import $mod" 2>&1); then
        ok "import $mod"
    else
        fail "import $mod — $(print -r -- "$err" | tail -1)"
    fi
done

# A clean Mac has no Homebrew Python to fall back on, so nothing may come from outside.
# stderr must be empty too: "Could not find platform libraries" means getpath fell back.
leaks=$(app_env "$PYTHON" -c "
import sys, ${(j:, :)MODULES}
app = sys.argv[1]
out = [f'sys.base_prefix {sys.base_prefix}'] if not sys.base_prefix.startswith(app) else []
out += [f'sys.path {p}' for p in sys.path if p and not p.startswith(app)]
# Absolute paths only: torch registers synthetic modules (torch.ops) whose __file__ is a bare name.
out += [f'module {m.__name__} {m.__file__}' for m in list(sys.modules.values())
        if (getattr(m, '__file__', None) or '').startswith('/') and not m.__file__.startswith(app)]
print('\n'.join(out))
" "$APP" 2>"$TMP/py.err")
if [[ -n "$leaks" ]]; then
    print -r -- "$leaks" | head -5 | while read -r l; do fail "Outside the bundle: $l"; done
elif [[ -s "$TMP/py.err" ]]; then
    fail "Python wrote to stderr: $(head -1 "$TMP/py.err")"
else
    ok "sys.base_prefix, sys.path and every loaded module are inside the bundle"
fi

# ── 5. Nothing loaded from Homebrew ───────────────────────────────────────────
hdr "Check 5: no library loaded from /opt/homebrew"

# Optional libraries that a package dlopen()s if present and does without otherwise.
# Pillow's ImageFont tries libfribidi (bidirectional text); on a clean Mac it's absent.
OPTIONAL_DLOPEN='/libfribidi\.'
dyld_log="$TMP/dyld.log"
{
    app_env DYLD_PRINT_LIBRARIES=1 "$PYTHON" -c "import ${(j:, :)MODULES}"
    app_env DYLD_PRINT_LIBRARIES=1 "$BIN/c2patool" --version
    app_env DYLD_PRINT_LIBRARIES=1 "$BIN/pdfimages" -v
    app_env DYLD_PRINT_LIBRARIES=1 "$BIN/openssl3" version
} > "$dyld_log" 2>&1
outside=("${(@f)$(grep -o '/opt/homebrew[^ ]*\|/usr/local/[^ ]*' "$dyld_log" | grep -v "$OPTIONAL_DLOPEN" | sort -u)}")
if ! grep -q 'dyld\[' "$dyld_log"; then
    skip "dyld output suppressed (hardened runtime) — run this test on an ad-hoc build"
elif [[ -n "${outside[1]}" ]]; then
    for lib in "${outside[@]}"; do
        fail "Loaded from outside the bundle: $lib"
    done
else
    ok "$(grep -c 'dyld\[' "$dyld_log") library loads, all from the bundle or the system"
fi

# ── 6. TrustMark weights are bundled ──────────────────────────────────────────
hdr "Check 6: TrustMark loads every variant without downloading"

if out=$(app_env "$PYTHON" -c "
import urllib.request
def no_download(url, *a, **k):
    raise RuntimeError(f'tried to download {url}')
urllib.request.urlretrieve = no_download
from trustmark import TrustMark
for variant in ('Q', 'P', 'B', 'C'):
    TrustMark(verbose=False, model_type=variant, loadRemover=True)
" 2>&1); then
    ok "Variants Q, P, B and C load offline"
else
    fail "TrustMark: $(print -r -- "$out" | grep -m1 -E 'download|Error' || print -r -- "$out" | tail -1)"
fi

# ── 7. End to end ─────────────────────────────────────────────────────────────
hdr "Check 7: CLI end to end"

CLI=(app_env "$PYTHON" "$RES/detect_ai_provenance.py")
app_env "$PYTHON" -c "
from PIL import Image
Image.new('RGB', (256, 256), 'red').save('$TMP/tagged.jpg')
Image.new('RGB', (300, 300), 'blue').save('$TMP/doc.pdf')
"
app_env exiftool -q -overwrite_original \
    -XMP-iptcExt:DigitalSourceType="http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia" \
    -EXIF:UserComment="Steps: 30, Sampler: Euler" -Comment="--ar 4:5 --v 6" "$TMP/tagged.jpg"

# Full scan (watermarks included, as the app runs it) plus strip.
if out=$("${CLI[@]}" "$TMP/tagged.jpg" --strip --rename \
        --out "$TMP/out" --json "$TMP/strip.json" 2>&1); then
    verdict=$(app_env "$PYTHON" -c "
import json
rows = json.load(open('$TMP/strip.json'))
inp = [r for r in rows if r['kind'] != 'output']
outp = [r for r in rows if r['kind'] == 'output']
if not inp or not inp[0]['metadata_hits']: print('input tags not detected')
elif not outp: print('no output copy written')
elif outp[0]['metadata_hits']: print('output still tagged: ' + ', '.join(outp[0]['metadata_hits']))
elif not inp[0].get('watermarks'): print('watermark check did not run')
else: print('ok')
")
    [[ "$verdict" == ok ]] && ok "Tagged JPEG scanned (with watermarks), stripped clean" || fail "Strip: $verdict"
else
    fail "CLI --strip exited non-zero: $(print -r -- "$out" | tail -2 | tr '\n' ' ')"
fi

if out=$("${CLI[@]}" "$TMP/doc.pdf" --no-watermarks --work "$TMP/work" --json "$TMP/pdf.json" 2>&1); then
    extracted=$(find "$TMP/work" -type f 2>/dev/null | wc -l | tr -d ' ')
    (( extracted > 0 )) && ok "PDF scanned, $extracted embedded image(s) extracted with pdfimages" \
                        || fail "PDF scanned but pdfimages extracted nothing"
else
    fail "CLI PDF scan exited non-zero: $(print -r -- "$out" | tail -2 | tr '\n' ' ')"
fi

# Signing: identity creation uses the bundled openssl, signing uses the bundled c2patool.
if out=$("${CLI[@]}" --create-identity "Bundle Test" 2>&1) \
   && ident=$("${CLI[@]}" --show-identity 2>/dev/null) && [[ "$ident" == *'"Bundle Test"'* ]]; then
    ok "Identity created with bundled openssl (throwaway HOME)"
    if out=$("${CLI[@]}" "$TMP/tagged.jpg" --no-watermarks --strip --sign \
            --out "$TMP/signed" --json "$TMP/sign.json" 2>&1) \
       && signed=$(find "$TMP/signed" -type f | head -1) && [[ -n "$signed" ]] \
       && manifest=$(app_env c2patool "$signed" 2>&1) && [[ "$manifest" == *"Bundle Test"* ]]; then
        ok "Output signed, manifest readable by c2patool"
    else
        fail "Signing: $(print -r -- "$out${manifest:-}" | tail -2 | tr '\n' ' ')"
    fi
else
    fail "Identity creation: $(print -r -- "$out" | tail -2 | tr '\n' ' ')"
fi

# ── 8. Signature, checked last ────────────────────────────────────────────────
# Last on purpose: everything above ran the bundle the way the app does, so this also
# proves running it doesn't write into the bundle (a stray .pyc or downloaded model
# breaks the seal, and a notarized app with a broken seal is "damaged" on other Macs).
hdr "Check 8: code signature still valid after running the bundle"

if verify_out=$(codesign --verify --deep --strict "$APP" 2>&1); then
    team=$(codesign -dv "$APP" 2>&1 | awk -F= '/^TeamIdentifier/ {print $2}')
    ok "codesign --verify --deep --strict passes (TeamIdentifier: ${team:-not set})"
else
    written=$(codesign --verify --deep --strict --verbose=4 "$APP" 2>&1 | grep -c 'file added')
    fail "codesign --verify failed ($written file(s) added inside the bundle): $(print -r -- "$verify_out" | tail -1)"
    team=""
fi

# Notarization rejects any Mach-O without the Developer ID team and hardened runtime.
if [[ -n "$team" && "$team" != "not set" ]]; then
    unsigned=()
    while IFS= read -r f; do
        [[ "$(file -b "$f")" == *Mach-O* ]] || continue
        info=$(codesign -dv "$f" 2>&1)
        [[ "$info" == *"TeamIdentifier=$team"* && "$info" == *"(runtime)"* ]] \
            || unsigned+=("${f#$APP/}")
    done < <(find "$APP" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \))
    if (( ${#unsigned[@]} == 0 )); then
        ok "Every Mach-O signed by team $team with hardened runtime"
    else
        fail "${#unsigned[@]} Mach-O file(s) lack team $team or hardened runtime, e.g. ${unsigned[1]}"
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n'
if (( FAIL == 0 )); then
    printf '\033[32m✅ All %d checks passed.\033[0m\n\n' "$PASS"
    exit 0
else
    printf '\033[31m❌ %d check(s) failed, %d passed.\033[0m\n\n' "$FAIL" "$PASS"
    exit 1
fi
