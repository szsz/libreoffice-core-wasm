#!/usr/bin/env bash
# Build the LibreOffice WASM core inside the lo-wasm-ci docker container.
#
# Self-healing notes:
#   - Image missing? rebuild from .github/docker/Dockerfile in this checkout.
#   - core-build dir missing? configure runs from scratch (slow; 1-3h).
#   - core-build present? incremental make.
#   - POCO not yet rebuilt with -fwasm-exceptions? rebuild it once into the
#     persistent /usr/local volume (cached marker file).
#
# Layout on host (persistent across runs):
#   $GITHUB_WORKSPACE                  ← bind-mounted at /lo/core (this checkout, fresh per run)
#   $CI_STATE_DIR/lo-core-build/       ← bind-mounted at /lo/core-build (incremental)
#   $CI_STATE_DIR/poco-prefix/         ← /usr/local override carrying rebuilt POCO
#   $CI_STATE_DIR/ccache/              ← /root/.ccache
#   $CI_STATE_DIR/host.lock            ← flock — single CI build at a time
#
# Container is named lo-wasm-ci-build-core to keep it disjoint from the online
# CI container (lo-wasm-ci-build) and the developer's dev containers.
set -euo pipefail

BID="${BUILD_ID:?}"
STATE_DIR="${CI_STATE_DIR:?}"
WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"

CI_IMAGE="lo-wasm-ci:latest"
CI_CONTAINER="lo-wasm-ci-build-core"
LOCK="$STATE_DIR/host.lock"

CORE_BUILD_HOST="$STATE_DIR/lo-core-build"
POCO_PREFIX_HOST="$STATE_DIR/poco-prefix"
CCACHE_HOST="$STATE_DIR/ccache"

mkdir -p "$STATE_DIR" "$CORE_BUILD_HOST" "$POCO_PREFIX_HOST" "$CCACHE_HOST"

# ── Acquire host-wide lock ─────────────────────────────────────
exec 9>"$LOCK"
echo "Acquiring host build lock ($LOCK) …"
flock 9
echo "[OK] Lock acquired."

# ── Ensure CI image exists, build if missing ──────────────────
if ! docker image inspect "$CI_IMAGE" >/dev/null 2>&1; then
    echo "--- Building $CI_IMAGE from .github/docker/Dockerfile ---"
    docker build -t "$CI_IMAGE" "$WORKSPACE/.github/docker"
    echo "[OK] Built $CI_IMAGE"
else
    echo "[OK] CI image $CI_IMAGE present."
fi

# ── Recreate the build container fresh ────────────────────────
docker rm -f "$CI_CONTAINER" >/dev/null 2>&1 || true

# Mount workspace at /lo/core RW (autogen writes autom4te.cache + configure
# script to the source tree). Runner checkout is recreated per job so any
# mess is cleaned up automatically.
docker run -d \
    --name "$CI_CONTAINER" \
    --memory=14g \
    -v "$WORKSPACE":/lo/core \
    -v "$CORE_BUILD_HOST":/lo/core-build \
    -v "$POCO_PREFIX_HOST":/usr/local \
    -v "$CCACHE_HOST":/root/.ccache \
    -e CCACHE_DIR=/root/.ccache \
    -e CCACHE_MAXSIZE=20G \
    "$CI_IMAGE" \
    sleep infinity

# ── Rebuild POCO with -fwasm-exceptions (one-time / on cache miss) ────
docker exec "$CI_CONTAINER" bash -lc '
    set -euo pipefail
    if [[ -f /usr/local/.poco-fwasm-exceptions.done ]] && [[ -f /usr/local/lib/libPocoFoundation.a ]]; then
        echo "[OK] POCO with -fwasm-exceptions already installed."
        exit 0
    fi
    echo "--- Rebuilding POCO with -fwasm-exceptions ---"
    source /home/builder/emsdk/emsdk_env.sh
    cd /tmp
    POCO_VER=1.12.4
    if [[ ! -d poco-${POCO_VER}-all ]]; then
        wget -q https://pocoproject.org/releases/poco-${POCO_VER}/poco-${POCO_VER}-all.tar.bz2
        tar -xjf poco-${POCO_VER}-all.tar.bz2
    fi
    cd poco-${POCO_VER}-all
    [[ -f XML/src/xmlparse.cpp ]] && mv XML/src/xmlparse.cpp XML/src/xmlparse.c 2>/dev/null || true
    emconfigure ./configure --static --no-samples --no-tests \
        --omit=Crypto,NetSSL_OpenSSL,JWT,Data,Data/SQLite,Data/ODBC,Data/MySQL,Data/PostgreSQL,Zip,PageCompiler,PageCompiler/File2Page,MongoDB,Redis,ActiveRecord,ActiveRecord/Compiler,Prometheus
    emmake make -j$(nproc) \
        CC=$EMSDK/upstream/emscripten/emcc \
        CXX=$EMSDK/upstream/emscripten/em++ \
        LD=$EMSDK/upstream/emscripten/em++ \
        CXXFLAGS="-DPOCO_NO_LINUX_IF_PACKET_H -DPOCO_NO_INOTIFY -pthread -s USE_PTHREADS=1 -fwasm-exceptions"
    make -j$(nproc) install INSTALLDIR=/usr/local
    touch /usr/local/.poco-fwasm-exceptions.done
    echo "[OK] POCO installed at /usr/local."
'

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
