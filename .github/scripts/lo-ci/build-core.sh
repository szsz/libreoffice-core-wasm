#!/usr/bin/env bash
# Build the LibreOffice WASM core inside the lo-wasm-ci docker container.
#
# Self-healing notes:
#   - Image tag is derived from the Dockerfile content hash, so any change to
#     .github/docker/Dockerfile triggers a one-time rebuild on the next run.
#   - core-build dir missing? autogen runs from scratch (slow; 1-3h).
#   - core-build present? incremental make.
#   - POCO with -fwasm-exceptions is now BAKED into the image (Dockerfile),
#     so we don't need to mount /usr/local — and crucially we DO NOT, because
#     mounting an empty host dir at /usr/local hides expat, zstd headers, etc.
#
# Layout on host (persistent across runs):
#   $GITHUB_WORKSPACE                  ← bind-mounted at /lo/core (this checkout, fresh per run)
#   $CI_STATE_DIR/lo-core-build/       ← bind-mounted at /lo/core-build (incremental)
#   $CI_STATE_DIR/ccache/              ← /root/.ccache
#   $CI_STATE_DIR/host.lock            ← flock — single CI build at a time
set -euo pipefail

BID="${BUILD_ID:?}"
STATE_DIR="${CI_STATE_DIR:?}"
WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"

CI_CONTAINER="lo-wasm-ci-build-core"
LOCK="$STATE_DIR/host.lock"

CORE_BUILD_HOST="$STATE_DIR/lo-core-build"
CCACHE_HOST="$STATE_DIR/ccache"
TARBALLS_HOST="$STATE_DIR/lo-tarballs"   # downloaded externals (zlib, libpng, ICU, …) — ~10 GB

mkdir -p "$STATE_DIR" "$CORE_BUILD_HOST" "$CCACHE_HOST" "$TARBALLS_HOST"

# ── Cleanup trap: container runs as root and writes into the bind-mounted
# workspace (autogen.sh updates m4/, autom4te.cache/, externals download,
# etc.), leaving root-owned files. The next run's actions/checkout cannot
# delete them and the whole job fails at the Checkout step. Always chown
# the workspace back to the runner user (UID 1000 = localadmin) on exit.
trap 'sudo chown -R 1000:1000 "$WORKSPACE" 2>/dev/null || true' EXIT

# ── Restore source-tree mtimes from git history ────────────────
# actions/checkout writes every file with `now` as the mtime, which makes
# `make` see all sources as newer than core-build artefacts and rebuild
# the entire LO core from scratch on every run (~3h). git-restore-mtime
# walks the git log and sets each file's mtime to its last commit time,
# so unchanged-since-last-build files end up with mtimes earlier than the
# core-build artefacts → make becomes truly incremental.
if ! command -v git-restore-mtime >/dev/null 2>&1; then
    echo "--- Installing git-restore-mtime ---"
    sudo apt-get install -y -qq git-restore-mtime 2>/dev/null || true
fi
if command -v git-restore-mtime >/dev/null 2>&1; then
    echo "--- Restoring source file mtimes from git history ---"
    (cd "$WORKSPACE" && git-restore-mtime --skip-missing --quiet 2>&1 | tail -3) || true
else
    echo "WARNING: git-restore-mtime unavailable; LO build will be from-scratch each run." >&2
fi

# ── Acquire host-wide lock ─────────────────────────────────────
exec 9>"$LOCK"
echo "Acquiring host build lock ($LOCK) …"
flock 9
echo "[OK] Lock acquired."

# ── Ensure CI image exists with current Dockerfile + patches content ─────
# Hash the WHOLE .github/docker/ directory (Dockerfile + COPY'd .patch / .diff
# files). Hashing only the Dockerfile missed patch edits, so a fix in the
# poco patch silently kept reusing the stale image.
DOCKER_CTX="$WORKSPACE/.github/docker"
if [[ ! -f "$DOCKER_CTX/Dockerfile" ]]; then
    echo "ERROR: $DOCKER_CTX/Dockerfile missing." >&2; exit 1
fi
DOCKERFILE_HASH="$( (cd "$DOCKER_CTX" && find . -type f -print0 | sort -z | xargs -0 sha256sum) | sha256sum | cut -c1-12 )"
CI_IMAGE="lo-wasm-ci:$DOCKERFILE_HASH"

if ! docker image inspect "$CI_IMAGE" >/dev/null 2>&1; then
    echo "--- Building $CI_IMAGE from .github/docker/ ---"
    docker build -t "$CI_IMAGE" -t lo-wasm-ci:latest "$DOCKER_CTX"
    echo "[OK] Built $CI_IMAGE"
else
    # Always update :latest to point at the current hash, in case a previous
    # run from a different (older) commit left :latest pointing elsewhere.
    docker tag "$CI_IMAGE" lo-wasm-ci:latest
    echo "[OK] CI image $CI_IMAGE present (Dockerfile+patches unchanged)."
fi

# ── Recreate the build container fresh ────────────────────────
docker rm -f "$CI_CONTAINER" >/dev/null 2>&1 || true

# Mount workspace at /lo/core RW (autogen writes autom4te.cache + configure
# script to the source tree). Runner checkout is recreated per job so any
# mess is cleaned up automatically. We do NOT mount /usr/local — the image's
# /usr/local has POCO + zstd + expat + … that the LO build links against.
docker run -d \
    --name "$CI_CONTAINER" \
    --memory=14g \
    -v "$WORKSPACE":/lo/core \
    -v "$CORE_BUILD_HOST":/lo/core-build \
    -v "$TARBALLS_HOST":/lo/core/external/tarballs \
    -v "$CCACHE_HOST":/root/.ccache \
    -e CCACHE_DIR=/root/.ccache \
    -e CCACHE_MAXSIZE=20G \
    "$CI_IMAGE" \
    sleep infinity

# external/tarballs/ overlay note: $WORKSPACE/external/tarballs/ is gitignored
# (only `download.lst` lists the URLs+hashes; the actual archives are not in
# git). actions/checkout deletes any leftovers from prior runs, so without
# this persistent mount the LO build re-downloads ~10 GB every run. The
# bind-mount overlays the empty source path with our state-dir cache.

# Sanity check: POCO with -fwasm-exceptions must be present (baked into image).
if ! docker exec "$CI_CONTAINER" test -f /usr/local/.poco-fwasm-exceptions.done; then
    echo "ERROR: image $CI_IMAGE missing baked POCO marker. Rebuild." >&2
    docker rm -f "$CI_CONTAINER" >/dev/null 2>&1 || true
    docker rmi "$CI_IMAGE" >/dev/null 2>&1 || true
    exit 1
fi

# ── Configure if needed, then incremental make ────────────────
docker exec "$CI_CONTAINER" bash -lc '
    set -euo pipefail
    git config --global --add safe.directory "*"
    update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-12 100 2>/dev/null || true
    update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-12 100 2>/dev/null || true
    source /home/builder/emsdk/emsdk_env.sh

    if [[ ! -f /lo/core-build/Makefile ]]; then
        echo "--- Configuring LibreOffice Core (first run / Makefile missing) ---"
        mkdir -p /lo/core-build
        cd /lo/core-build
        /lo/core/autogen.sh --with-distro=LibreOfficeWASM32 --with-wasm-module="writer calc impress"
    fi

    echo "--- make -rj$(nproc) (incremental if Makefile already present) ---"
    cd /lo/core-build
    make -rj$(nproc)
'

docker stop "$CI_CONTAINER" >/dev/null 2>&1 || true

if [[ ! -f "$CORE_BUILD_HOST/instdir/program/soffice.js" ]]; then
    echo "ERROR: build finished but instdir/program/soffice.js missing." >&2
    exit 1
fi
echo "[OK] LO core built: $CORE_BUILD_HOST/instdir/program/soffice.js ($(du -sh "$CORE_BUILD_HOST/instdir" | cut -f1))"
