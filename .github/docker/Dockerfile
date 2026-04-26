# lo-wasm-ci — CI image for building LibreOffice WASM.
#
# Derived from the allotropia builder image (the same one wasm/build-wasm.sh
# uses for dev), but tagged separately so it never collides with a developer's
# local containers on the same host. The image bakes in the runtime fixes
# build-wasm.sh applies on first run (gcc-12, node 24, emsdk symlink) plus
# azure-cli for upload/download from coolwasmfiles.
#
# POCO with -fwasm-exceptions and ccache state are NOT baked in — they live
# in the persistent state volume on the runner host, so they survive across
# image rebuilds and don't bloat the layer cache.
FROM public.ecr.aws/allotropia/libo-builders/wasm:latest

ARG DEBIAN_FRONTEND=noninteractive

# gcc-12 default (LO core requires it), node 24 (online build), git-lfs (deploy
# touches large blobs), zstd (artefact archive format), jq (manifest scraping),
# python3 (snapshot patcher), azure-cli (artefact upload/download),
# ca-certificates (TLS for az + curl).
RUN set -eux; \
    apt-get update -qq; \
    apt-get install -y -qq --no-install-recommends \
        gcc-12 g++-12 \
        zstd jq python3 \
        ca-certificates curl gnupg lsb-release; \
    update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-12 100; \
    update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-12 100; \
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

# emsdk layout fix (build-wasm.sh applies this at runtime; bake it instead so
# the runtime path is silent).
RUN if [ ! -d /home/builder/emsdk/upstream ]; then \
        mkdir -p /home/builder/emsdk/upstream && \
        ln -sfn /home/builder/emsdk/emscripten/main /home/builder/emsdk/upstream/emscripten; \
    fi

# Mark this image so logs/inspections show what we're running on.
ENV LO_WASM_CI_IMAGE=lo-wasm-ci
LABEL org.opencontainers.image.title="lo-wasm-ci" \
      org.opencontainers.image.description="CI image for building LibreOffice WASM (separate from dev containers)"
