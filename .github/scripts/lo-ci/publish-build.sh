#!/usr/bin/env bash
# Package the just-built LO core into a single zstd tarball, upload it to
# coolwasmfiles under lo-builds/<BUILD_ID>/, and refresh the listing pages.
#
# What we ship (everything the online build's emconfigure needs):
#   core-build/instdir/                                  ← --with-lo-path
#   core-build/workdir/CustomTarget/desktop/.../exports  ← exports file
#   core-build/workdir/LinkTarget/StaticLibrary/         ← linkable .a archives
#   core-build/workdir/Headers/                          ← generated headers
#   core/include/                                        ← public headers (LOK et al)
#   core/solenv/                                         ← rare but referenced by LO build glue
#
# This is a pragmatic "ship enough of the workdir" cut. If the online build
# fails with a missing path, add it here.
set -euo pipefail

# shellcheck source=_lib.sh
source "$(dirname "$0")/_lib.sh"
ensure_storage_key

BID="${BUILD_ID:?}"
ACCT="${AZURE_STORAGE_ACCOUNT:?}"
SITE="${STATIC_SITE_BASE:?}"
STATE_DIR="${CI_STATE_DIR:?}"
WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"

CORE_BUILD_HOST="$STATE_DIR/lo-core-build"
PACK_DIR="$(mktemp -d)"
TARBALL="$PACK_DIR/lo-core.tar.zst"
trap "rm -rf '$PACK_DIR'" EXIT

# Stage everything under /lo/-rooted paths so the online job can extract
# directly to its own /lo equivalent.
STAGE="$PACK_DIR/stage"
mkdir -p "$STAGE/core" "$STAGE/core-build"

echo "--- Staging artefacts ---"
# instdir
cp -a "$CORE_BUILD_HOST/instdir" "$STAGE/core-build/"

# workdir bits the online build needs at compile/link time. UnpackedTarball
# carries the unpacked external libraries (libpng, zlib, …) whose headers the
# online build #includes — without them the online compile fails with
# 'png.h not found'. UnpackedTarball is the largest contributor (~2-3 GB raw,
# ~600 MB zstd) but the alternative is shipping pre-built header bundles per
# tarball, which is more fragile.
mkdir -p "$STAGE/core-build/workdir"
for sub in CustomTarget LinkTarget Headers UnpackedTarball; do
    [[ -d "$CORE_BUILD_HOST/workdir/$sub" ]] && cp -a "$CORE_BUILD_HOST/workdir/$sub" "$STAGE/core-build/workdir/" || true
done

# Source-tree dirs the online configure / link references via
# --with-lo-sourcedir=/lo/core:
#   include/   — public LOK + module headers
#   solenv/    — build glue referenced by configure
#   static/    — emscripten/{environment,uno}.js used as --pre-js / --post-js
#   unotest/   — embindtest.js used at link time
for sub in include solenv static unotest; do
    [[ -d "$WORKSPACE/$sub" ]] && cp -a "$WORKSPACE/$sub" "$STAGE/core/" || true
done

echo "--- Compressing (zstd) ---"
( cd "$STAGE" && tar -I 'zstd -19 -T0' -cf "$TARBALL" . )
SIZE_HUMAN="$(du -sh "$TARBALL" | cut -f1)"
SHA="$(sha256sum "$TARBALL" | awk '{print $1}')"
echo "[OK] $SIZE_HUMAN  sha256=$SHA"

# ── Manifest ─────────────────────────────────────────────────────
cat > "$PACK_DIR/MANIFEST.json" <<JSON
{
  "build_id": "$BID",
  "git_sha": "${GIT_SHA:-}",
  "git_short_sha": "${GIT_SHA:0:12}",
  "git_ref": "${GIT_REF:-}",
  "completed_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "lo_core_tar_sha256": "$SHA",
  "lo_core_tar_size_human": "$SIZE_HUMAN"
}
JSON

# ── Per-build summary HTML ───────────────────────────────────────
cat > "$PACK_DIR/index.html" <<HTML
<!doctype html>
<meta charset="utf-8"><title>LO build $BID</title>
<style>body{font:14px system-ui;margin:2rem;max-width:60rem}
.box{border:1px solid #ddd;border-radius:6px;padding:1rem;margin:1rem 0}
a{color:#0066cc}.k{display:inline-block;min-width:11rem;color:#555}</style>
<h1>LibreOffice build <code>$BID</code></h1>
<div class="box">
  <div><span class="k">Git SHA:</span> <code>${GIT_SHA:-?}</code></div>
  <div><span class="k">Git ref:</span> <code>${GIT_REF:-?}</code></div>
  <div><span class="k">Completed (UTC):</span> $(date -u +%Y-%m-%dT%H:%M:%SZ)</div>
  <div><span class="k">Tarball size:</span> $SIZE_HUMAN</div>
  <div><span class="k">SHA-256:</span> <code>$SHA</code></div>
</div>
<div class="box">
  <h3>Artefacts</h3>
  <ul>
    <li><a href="lo-core.tar.zst">lo-core.tar.zst</a></li>
    <li><a href="MANIFEST.json">MANIFEST.json</a></li>
  </ul>
  <p>To consume in the online repo, set <code>wasm/LO_BUILD_ID</code> to <code>$BID</code>.</p>
</div>
<p><a href="../">← all LO builds</a> · <a href="../../">root</a></p>
HTML

# ── Upload ───────────────────────────────────────────────────────
upload() {
    local src="$1" name="$2" ctype="${3:-}"
    local args=(--account-name "$ACCT" --container-name '$web'
                --name "$name" --file "$src" --overwrite --no-progress)
    [[ -n "$ctype" ]] && args+=(--content-type "$ctype")
    az storage blob upload "${args[@]}" >/dev/null
}

echo "--- Uploading to coolwasmfiles \$web/lo-builds/$BID/ ---"
upload "$TARBALL"               "lo-builds/$BID/lo-core.tar.zst" "application/zstd"
upload "$PACK_DIR/MANIFEST.json" "lo-builds/$BID/MANIFEST.json"  "application/json"
upload "$PACK_DIR/index.html"   "lo-builds/$BID/index.html"     "text/html; charset=utf-8"

# Update latest pointer
LATEST_FILE="$(mktemp)"
echo -n "$BID" > "$LATEST_FILE"
upload "$LATEST_FILE" "lo-builds/latest.txt" "text/plain"
rm -f "$LATEST_FILE"

# Refresh listing pages (writes lo-builds/index.html, app-builds/index.html, root)
bash "$(dirname "$0")/regen-indexes.sh"

echo "Published: $SITE/lo-builds/$BID/"
echo "Updated:   $SITE/lo-builds/latest.txt → $BID"
