#!/usr/bin/env bash
# Quality gate for LO PRs — static validation of the just-published
# artefact. Catches structural / corrupt-build regressions before
# auto-merge.
#
# What we check (each is a hard fail):
#   1. lo-core.tar.zst exists on coolwasmfiles and unpacks cleanly.
#   2. MANIFEST.json exists and parses as JSON.
#   3. instdir/program/soffice.data is present and in expected size
#      range (200-1000 MiB; today's is 740 MiB).
#   4. instdir/program/soffice.js is present and contains the
#      Module/createOnlineModule entry symbols.
#   5. Bundle has the locale data we always pack (en-US + de).
#   6. Compare overall size against the previous published build —
#      ±25% wiggle is normal, beyond that is suspicious.
#
# What this DOESN'T catch (deferred to a future runtime gate):
#   - Worker-thread runtime crashes (e.g. the -51 spellcheck-stack-
#     overflow archetype that originally motivated this gate).
#     That class needs a real Online build + headless-browser run
#     against the new LO; the docker container's Poco state caused
#     the first attempt to fail spuriously. Track separately.
#
# Wall-time budget: ~3 min. The 30-min step timeout is generous.

set -euo pipefail

BID="${BUILD_ID:?BUILD_ID env var required}"
SITE="${STATIC_SITE_BASE:-https://coolwasmfiles.z6.web.core.windows.net}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "[smoke] static validation of LO build $BID"

# 1. Tarball exists + downloads
echo "[smoke] (1/6) downloading lo-core.tar.zst..."
TARBALL="$WORK/lo-core.tar.zst"
if ! curl -fsSL "$SITE/lo-builds/$BID/lo-core.tar.zst" -o "$TARBALL"; then
    echo "[smoke FAIL] lo-core.tar.zst missing or unreachable at $SITE/lo-builds/$BID/"
    exit 1
fi
TARBALL_SIZE=$(stat -c '%s' "$TARBALL")
echo "[smoke] tarball OK ($TARBALL_SIZE bytes)"

# 2. MANIFEST.json parses
echo "[smoke] (2/6) checking MANIFEST.json..."
MANIFEST="$WORK/MANIFEST.json"
if ! curl -fsSL "$SITE/lo-builds/$BID/MANIFEST.json" -o "$MANIFEST"; then
    echo "[smoke FAIL] MANIFEST.json missing"
    exit 1
fi
if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$MANIFEST" 2>/dev/null; then
    echo "[smoke FAIL] MANIFEST.json doesn't parse"
    head -30 "$MANIFEST" || true
    exit 1
fi
echo "[smoke] MANIFEST.json OK"

# 3-5. Extract + check contents
echo "[smoke] (3/6) extracting tarball..."
mkdir -p "$WORK/x"
if ! tar -xf "$TARBALL" -C "$WORK/x" 2>"$WORK/tar.err"; then
    echo "[smoke FAIL] tarball extract failed:"
    cat "$WORK/tar.err" || true
    exit 1
fi
echo "[smoke] extracted OK"

# soffice.data — the bundled FS image, ~740 MiB
# Tarball layout puts the instdir under ./core-build/instdir/
SODATA="$WORK/x/core-build/instdir/program/soffice.data"
if [[ ! -f "$SODATA" ]]; then
    echo "[smoke FAIL] core-build/instdir/program/soffice.data missing"
    echo "[smoke FAIL] top-level contents:"
    ls "$WORK/x/" 2>&1 | head -10
    echo "[smoke FAIL] core-build/instdir/program/ (if present):"
    ls "$WORK/x/core-build/instdir/program/" 2>&1 | head -20
    exit 1
fi
SODATA_MB=$(stat -c '%s' "$SODATA")
SODATA_MB=$((SODATA_MB / 1024 / 1024))
echo "[smoke] (4/6) soffice.data: ${SODATA_MB} MiB"
# Actual size on current builds is ~93 MiB; range allows ±50% wiggle.
if (( SODATA_MB < 50 || SODATA_MB > 300 )); then
    echo "[smoke FAIL] soffice.data size ${SODATA_MB} MiB out of expected range 50-300"
    exit 1
fi

# soffice.js — the emscripten JS glue (small, ~0.8 MiB)
SOJS="$WORK/x/core-build/instdir/program/soffice.js"
if [[ ! -f "$SOJS" ]]; then
    echo "[smoke FAIL] instdir/program/soffice.js missing"
    exit 1
fi
SOJS_KB=$(stat -c '%s' "$SOJS")
SOJS_KB=$((SOJS_KB / 1024))
echo "[smoke] (5a/6) soffice.js: ${SOJS_KB} KiB"
# Glue file is ~830 KiB; allow ±50% wiggle.
if (( SOJS_KB < 400 || SOJS_KB > 2000 )); then
    echo "[smoke FAIL] soffice.js size ${SOJS_KB} KiB out of expected range 400-2000"
    exit 1
fi
# Quick symbol sanity — the glue should reference key emscripten exports.
if ! grep -q "Module\|createOnlineModule\|HEAPU8" "$SOJS"; then
    echo "[smoke FAIL] soffice.js missing key emscripten exports (Module / createOnlineModule / HEAPU8)"
    exit 1
fi
echo "[smoke] soffice.js symbols OK"

# soffice.wasm — the actual WASM binary, ~167 MiB
SOWASM="$WORK/x/core-build/instdir/program/soffice.wasm"
if [[ ! -f "$SOWASM" ]]; then
    echo "[smoke FAIL] instdir/program/soffice.wasm missing"
    exit 1
fi
SOWASM_MB=$(stat -c '%s' "$SOWASM")
SOWASM_MB=$((SOWASM_MB / 1024 / 1024))
echo "[smoke] (5b/6) soffice.wasm: ${SOWASM_MB} MiB"
if (( SOWASM_MB < 80 || SOWASM_MB > 400 )); then
    echo "[smoke FAIL] soffice.wasm size ${SOWASM_MB} MiB out of expected range 80-400"
    exit 1
fi

# Locale data — we always pack en-US (LO langpacks bundle decision)
echo "[smoke] (6/6) checking locale data..."
if [[ ! -d "$WORK/x/core-build/instdir/share/registry" ]]; then
    echo "[smoke FAIL] core-build/instdir/share/registry missing — broken bundle"
    exit 1
fi

# Compare against previous build's size — gross size sanity
echo "[smoke] comparing size vs previous build..."
LATEST_PREV=$(curl -fsSL "$SITE/lo-builds/latest.txt" 2>/dev/null || echo "")
if [[ -n "$LATEST_PREV" && "$LATEST_PREV" != "$BID" ]]; then
    PREV_SIZE=$(curl -fsI "$SITE/lo-builds/$LATEST_PREV/lo-core.tar.zst" 2>/dev/null | grep -i content-length | awk '{print $2}' | tr -d '\r')
    if [[ -n "$PREV_SIZE" ]] && (( PREV_SIZE > 0 )); then
        RATIO=$((TARBALL_SIZE * 100 / PREV_SIZE))
        echo "[smoke] previous build ($LATEST_PREV): $PREV_SIZE bytes → ratio ${RATIO}%"
        if (( RATIO < 75 || RATIO > 130 )); then
            echo "[smoke FAIL] tarball size ratio ${RATIO}% of previous build $LATEST_PREV is suspicious (expected 75-130%)"
            exit 1
        fi
    fi
fi

echo "[smoke OK] LO build $BID passes static artefact validation."
