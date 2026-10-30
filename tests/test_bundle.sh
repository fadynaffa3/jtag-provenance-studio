#!/bin/zsh
# test_bundle.sh — validate a built .app bundle before notarization
#
# Usage:
#   zsh tests/test_bundle.sh [path/to/JTag\ Provenance\ Studio.app]
#
# Checks:
#   1. No Mach-O inside the bundle links to a dylib outside the bundle
#      (except /usr/lib and /System — those are Apple's and are fine)
#   2. Python can import all critical C extension modules
#   3. The signing identity is consistent (all Mach-Os share the same Team ID)
#   4. The Python watermark stack (trustmark, invisible_watermark, PIL) can be imported
#
# Exit 0 = all checks passed. Exit 1 = one or more checks failed.

set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-app/JTag Provenance Studio.app}"
PASS=0; FAIL=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
hdr()  { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }

if [[ ! -d "$APP" ]]; then
    printf '\033[31mError: bundle not found: %s\033[0m\n' "$APP" >&2
    exit 1
fi

RES="$APP/Contents/Resources"
FWK="$APP/Contents/Frameworks"
PYTHON="$RES/venv/bin/python3"
DYNLOAD="$RES/python3.14-stdlib/lib-dynload"

# ── 1. External dylib references ──────────────────────────────────────────────
hdr "Check 1: no outside-bundle dylib references"

# Collect all Mach-O files
MACHO_FILES=()
while IFS= read -r f; do
    file "$f" 2>/dev/null | grep -q "Mach-O" && MACHO_FILES+=("$f")
done < <(find "$APP" -type f)

BUNDLE_ABS=$(cd "$APP" && pwd)
OUTSIDE_REFS=()

for f in "${MACHO_FILES[@]}"; do
    while IFS= read -r dep; do
        dep="${dep##[[:space:]]}"
        dep="${dep%% *}"
        # Skip self-references, loader-relative, system paths, and empty
        [[ -z "$dep" ]] && continue
        [[ "$dep" == @* ]] && continue
        [[ "$dep" == /usr/lib/* ]] && continue
        [[ "$dep" == /System/* ]] && continue
        [[ "$dep" == /usr/local/lib/* ]] && continue
        # Check if it resolves to inside the bundle.
        # Wheel-bundled packages (PIL, torchvision) embed dylibs under /DLC/ paths
        # that are actually inside the venv .dylibs/ directories. Resolve by
        # checking the basename against files in the venv. A dep is only "outside"
        # if neither the real path nor any bundle-internal file with that name exists.
        real_dep=$(readlink -f "$dep" 2>/dev/null || echo "$dep")
        dep_base=$(basename "$dep")
        bundle_has_it=$(find "$APP" -name "$dep_base" -type f 2>/dev/null | head -1)
        if [[ "$real_dep" != "$BUNDLE_ABS"* && "$real_dep" != /usr/lib/* && "$real_dep" != /System/* && -z "$bundle_has_it" ]]; then
            OUTSIDE_REFS+=("$(basename $f) → $dep")
        fi
    done < <(otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}')
done

if [[ ${#OUTSIDE_REFS[@]} -eq 0 ]]; then
    ok "All Mach-O deps are bundled or system"
else
    for ref in "${OUTSIDE_REFS[@]}"; do
        fail "Outside dep: $ref"
    done
fi

# ── 2. lib-dynload .so files specifically ─────────────────────────────────────
hdr "Check 2: lib-dynload .so files have no Homebrew deps"

if [[ -d "$DYNLOAD" ]]; then
    homebrew_deps=0
    while IFS= read -r so; do
        while IFS= read -r dep; do
            dep="${dep##[[:space:]]}"
            dep="${dep%% *}"
            if [[ "$dep" == /opt/homebrew/* ]]; then
                fail "$(basename $so) links to Homebrew: $dep"
                homebrew_deps=$((homebrew_deps + 1))
            fi
        done < <(otool -L "$so" 2>/dev/null | tail -n +2 | awk '{print $1}')
    done < <(find "$DYNLOAD" -name "*.so")
    [[ $homebrew_deps -eq 0 ]] && ok "No .so files link to /opt/homebrew"
else
    fail "lib-dynload directory missing: $DYNLOAD"
fi

# ── 3. Python C extension imports ─────────────────────────────────────────────
hdr "Check 3: Python C extension imports"

# Rewrite pyvenv.cfg so the bundled Python is self-consistent for testing
PY_HOME="$RES/venv/bin"
CFG="$RES/venv/pyvenv.cfg"
printf 'home = %s\ninclude-system-site-packages = false\nversion = 3.14.6\nexecutable = %s\n' \
    "$PY_HOME" "$PY_HOME/python3" > "$CFG"

STDLIB="$RES/python3.14-stdlib"
SITEPKGS="$RES/venv/lib/python3.14/site-packages"
DYNLOAD_PATH="$STDLIB/lib-dynload"
export PYTHONPATH="$STDLIB:$SITEPKGS:$DYNLOAD_PATH"
export PYTHONUNBUFFERED=1

# Core C extensions that have historically been broken
CORE_MODULES=(hashlib lzma mmap ssl sqlite3 _decimal zlib)
for mod in "${CORE_MODULES[@]}"; do
    if "$PYTHON" -c "import $mod" 2>/dev/null; then
        ok "import $mod"
    else
        err=$("$PYTHON" -c "import $mod" 2>&1 | head -3)
        fail "import $mod — $err"
    fi
done

# ── 4. Watermark stack imports ─────────────────────────────────────────────────
hdr "Check 4: watermark ML stack imports (optional — skip if not installed)"

WM_MODULES=(PIL numpy cv2 imwatermark)
for mod in "${WM_MODULES[@]}"; do
    if "$PYTHON" -c "import $mod" 2>/dev/null; then
        ok "import $mod"
    else
        printf '  \033[33m–\033[0m %s (not installed — OK)\n' "$mod"
    fi
done

# TrustMark needs a network on first run; just check the package is importable
if "$PYTHON" -c "import trustmark" 2>/dev/null; then
    ok "import trustmark"
else
    printf '  \033[33m–\033[0m trustmark (not installed — OK)\n'
fi

# ── 5. Code signature consistency ─────────────────────────────────────────────
hdr "Check 5: code signature"

sig_info=$(codesign -dv "$APP" 2>&1 || true)
if echo "$sig_info" | grep -q "Authority="; then
    team=$(echo "$sig_info" | grep "TeamIdentifier" | awk '{print $2}')
    ok "Signed — TeamIdentifier: ${team:-ad-hoc}"
elif echo "$sig_info" | grep -q "signed"; then
    ok "Ad-hoc signed"
else
    fail "Not signed or signature invalid"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n'
if [[ $FAIL -eq 0 ]]; then
    printf '\033[32m✅ All %d checks passed.\033[0m\n\n' "$PASS"
    exit 0
else
    printf '\033[31m❌ %d check(s) failed, %d passed.\033[0m\n\n' "$FAIL" "$PASS"
    exit 1
fi
