# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form) — builds ON TOP of the org C/C++ base image
# (ghcr.io/mayhemheroes/base). The base provides debian + clang/llvm + libFuzzer/afl++ + cmake/ninja
# + the identities + the build-contract ENV; this only adds the per-commit grok build.
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t grok-commit:test .

FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); never bake it as ENV — an empty value
# breaks clang. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default.
# Declare it WITHOUT a default so an unset arg lets the base ENV flow through; --build-arg overrides.
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# grok builds its CORE JPEG2000 library with CMake/Ninja, which the base already ships. The fuzzers
# link only the core (libgrokj2k.a + the vendored libhwy.a + liblcms2.a); the libpng/libtiff/libjpeg
# codec front-ends are NOT built (GRK_BUILD_CODEC=OFF), so no extra apt deps are required. The
# google/highway submodule is vendored in the build context (src/lib/core/highway).
# (If a future build re-enables the codec, add a `USER root` apt step here:
#   libtiff-dev liblcms2-dev libpng-dev libjpeg-dev zlib1g-dev.)

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git history and
# submodules) is copied to /mayhem as `mayhem`; build.sh builds in place.
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run grok's self-contained round-trip golden test at build time (a failing test fails the build).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
