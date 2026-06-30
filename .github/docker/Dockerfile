# lo-wasm-ci — CI image for building LibreOffice WASM.
#
# Derived from the allotropia builder image (the same one wasm/build-wasm.sh
# uses for dev), but tagged separately so it never collides with a developer's
# local containers on the same host. The image bakes in:
#   - the runtime fixes wasm/build-wasm.sh applies on first run (gcc-12, node 24,
#     emsdk symlink),
#   - azure-cli (artefact upload/download from coolwasmfiles),
#   - POCO 1.12.4 rebuilt with -fwasm-exceptions, installed to /usr/local
#     (the dev script does this at runtime; baking it makes CI deterministic
#     and removes the need to volume-mount /usr/local — which masks all the
#     other libraries the image ships).
#
# The two .patch / .diff files in this directory are copies of the ones in
# the online repo's wasm/ dir (originals at szsz/online wasm/poco-*). Keeping
# them here lets the LO repo build the image without depending on the online
# repo's checkout being available.
# syntax=docker/dockerfile:1.6
FROM public.ecr.aws/allotropia/libo-builders/wasm:latest

ARG DEBIAN_FRONTEND=noninteractive

# gcc-13 (LibreOffice master requires >= GCC 13 for the build side since
# ~2026-05; the old snapshot built with gcc-12). node 24, jq/zstd/python3
# (orchestration), azure-cli (upload), patch (POCO patches).
RUN set -eux; \
    apt-get update -qq; \
    apt-get install -y -qq --no-install-recommends software-properties-common; \
    add-apt-repository -y ppa:ubuntu-toolchain-r/test || true; \
    apt-get update -qq; \
    apt-get install -y -qq --no-install-recommends \
        gcc-13 g++-13 \
        zstd jq python3 python3-dev patch \
        ca-certificates curl gnupg lsb-release; \
    update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-13 100; \
    update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-13 100; \
    apt-get remove -y -qq libnode-dev || true; \
    curl -fsSL https://deb.nodesource.com/setup_24.x | bash -; \
    apt-get install -y -qq nodejs; \
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | \
        gpg --dearmor -o /etc/apt/trusted.gpg.d/microsoft.gpg; \
    AZ_REPO="$(lsb_release -cs)"; \
    echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ $AZ_REPO main" \
        > /etc/apt/sources.list.d/azure-cli.list; \
    apt-get update -qq; \
    apt-get install -y -qq azure-cli; \
    rm -rf /var/lib/apt/lists/*

# emsdk layout fix — bake the symlink so the runtime path is silent.
RUN if [ ! -d /home/builder/emsdk/upstream ]; then \
        mkdir -p /home/builder/emsdk/upstream && \
        ln -sfn /home/builder/emsdk/emscripten/main /home/builder/emsdk/upstream/emscripten; \
    fi

# Rebuild POCO 1.12.4 with -fwasm-exceptions and install to /usr/local.
# Slow (10-15 min), but only happens once per Dockerfile change.
COPY poco-1.12.4-emscripten.patch poco-no-special-expat-sauce.diff /tmp/

RUN <<'BUILDPOCO'
#!/usr/bin/env bash
set -eux
source /home/builder/emsdk/emsdk_env.sh
cd /tmp
POCO_VER=1.12.4
wget -q https://pocoproject.org/releases/poco-${POCO_VER}/poco-${POCO_VER}-all.tar.bz2
tar -xjf poco-${POCO_VER}-all.tar.bz2
rm -f poco-${POCO_VER}-all.tar.bz2
cd poco-${POCO_VER}-all
# Patches mirror what wasm/build-wasm.sh applies; both have malformed hunks
# at the tail (one for Application.cpp's snapshot helper, one harmless in
# the expat one) that dev silently swallows with `|| true`. Keep the same
# tolerance here so we install the parts that DO apply.
patch -p1 -N < /tmp/poco-1.12.4-emscripten.patch || true
if [ -f XML/src/xmlparse.cpp ]; then mv XML/src/xmlparse.cpp XML/src/xmlparse.c; fi
patch -p0 -N < /tmp/poco-no-special-expat-sauce.diff || true
emconfigure ./configure --static --no-samples --no-tests \
    --omit=Crypto,NetSSL_OpenSSL,JWT,Data,Data/SQLite,Data/ODBC,Data/MySQL,Data/PostgreSQL,Zip,PageCompiler,PageCompiler/File2Page,MongoDB,Redis,ActiveRecord,ActiveRecord/Compiler,Prometheus
emmake make -j"$(nproc)" \
    CC="$EMSDK/upstream/emscripten/emcc" \
    CXX="$EMSDK/upstream/emscripten/em++" \
    LD="$EMSDK/upstream/emscripten/em++" \
    CXXFLAGS="-DPOCO_NO_LINUX_IF_PACKET_H -DPOCO_NO_INOTIFY -pthread -s USE_PTHREADS=1 -fwasm-exceptions"
make -j"$(nproc)" install INSTALLDIR=/usr/local
touch /usr/local/.poco-fwasm-exceptions.done
cd /
rm -rf /tmp/poco-${POCO_VER}-all /tmp/poco-1.12.4-emscripten.patch /tmp/poco-no-special-expat-sauce.diff
BUILDPOCO

ENV LO_WASM_CI_IMAGE=lo-wasm-ci
LABEL org.opencontainers.image.title="lo-wasm-ci" \
      org.opencontainers.image.description="CI image for building LibreOffice WASM (separate from dev containers)"
