#!/usr/bin/env bash
#
# grok/mayhem/build.sh — build GrokImageCompression/grok's two OSS-Fuzz harnesses as sanitized
# libFuzzer targets (+ standalone reproducers), AND grok's core C++20 library WITH $SANITIZER_FLAGS
# so the fuzzed codec is instrumented.
#
# The fuzzed surface is grok's JPEG 2000 (JP2 / J2K / HTJ2K) core codec:
#   grk_decompress_fuzzer — feeds the raw fuzz bytes as a JPEG 2000 codestream to the decoder
#                           (grk_decompress_init -> read_header -> grk_decompress). Inputs ARE
#                           .jp2 / .j2k files. This is the primary parsing target.
#   grk_compress_fuzzer   — does NOT take an image file: a FuzzStream parses the input bytes into
#                           grk_cparameters (dims, precision, comps, codec fmt, progression,
#                           resolutions, code-block size/style, irreversible, layers, tiling, MCT,
#                           HTJ2K) plus pixel data, then drives grk_compress to a memory buffer.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN). We compile grok's core library ITSELF with $SANITIZER_FLAGS via CMake's
# CMAKE_C_FLAGS / CMAKE_CXX_FLAGS so the encoder/decoder (not just the harness) is instrumented.
#
# Only the CORE library is built (GRK_BUILD_CODEC=OFF): the fuzzers link libgrokj2k.a + libhwy.a +
# liblcms2.a and never touch the libpng/libtiff/libjpeg codec front-ends, which keeps the build lean.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS: DWARF ≤ 3 required (§6.2 item 10) — clang-19 plain -g emits DWARF-5; be explicit.
: "${DEBUG_FLAGS=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

SRC="${SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export SRC
cd "$SRC"

HARNESS_DIR="$SRC/mayhem/harnesses"
BUILD="$SRC/build"
# Stable pre-populated FetchContent cache for spdlog's fmtlib dep (so re-runs are offline/air-gapped).
# On first run cmake downloads fmt here; on re-runs FETCHCONTENT_SOURCE_DIR_FMT points cmake to the
# pre-downloaded source, bypassing the network fetch entirely (§6.5 air-gapped build requirement).
FMT_CACHE="${FMT_CACHE:-/mayhem/fmt-cache}"
# If the pre-populated fmt source cache exists, tell cmake to use it offline (§6.5).
FMT_CACHE_ARG=()
[ -d "$FMT_CACHE" ] && FMT_CACHE_ARG=(-DFETCHCONTENT_SOURCE_DIR_FMT="$FMT_CACHE" -DFETCHCONTENT_FULLY_DISCONNECTED=ON)

# ── 1) Build grok's CORE library WITH sanitizers (static) ──────────────────────────────────────────
# Static libs so the harnesses are self-contained; codec front-ends (png/tiff/jpeg) disabled — the
# fuzzers only need the core JPEG2000 engine + its lcms2/highway deps. SANITIZER_FLAGS instrument the
# fuzzed code. Examples/codec/tests OFF to keep the build minimal.
rm -rf "$BUILD"
mkdir -p "$BUILD"
cmake -S "$SRC" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DGRK_BUILD_CODEC=OFF \
  -DGRK_BUILD_CORE_EXAMPLES=OFF \
  -DGRK_BUILD_CORE_SWIG_BINDINGS=OFF \
  -DBUILD_TESTING=OFF \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  "${FMT_CACHE_ARG[@]}"
cmake --build "$BUILD" --target grokj2k --parallel "$MAYHEM_JOBS"

# Seed the stable fmt cache from this run's download so re-runs are offline (§6.5).
# cmake downloads fmt to $BUILD/_deps/fmt-src on first run; copy it to FMT_CACHE once.
if [ ! -d "$FMT_CACHE" ] && [ -d "$BUILD/_deps/fmt-src" ]; then
  mkdir -p "$(dirname "$FMT_CACHE")"
  cp -a "$BUILD/_deps/fmt-src" "$FMT_CACHE"
  echo "cached fmt source -> $FMT_CACHE (air-gapped re-runs will use this)"
fi

# Locate the three static archives the fuzzers link against.
LIBGROK="$(find "$BUILD" -name 'libgrokj2k.a' | head -1)"
LIBHWY="$(find "$BUILD" -name 'libhwy.a' | head -1)"
LIBLCMS="$(find "$BUILD" -name 'liblcms2.a' | head -1)"
echo "core libs: $LIBGROK | $LIBHWY | $LIBLCMS"
[ -f "$LIBGROK" ] && [ -f "$LIBHWY" ] && [ -f "$LIBLCMS" ] || { echo "ERROR: missing core static libs" >&2; exit 1; }

INC="-I$SRC/src/lib/core -I$(dirname "$LIBGROK")/../src/lib/core"
# grk_config.h is generated under build/src/lib/core — find its dir robustly.
GENINC="$(dirname "$(find "$BUILD" -name 'grk_config.h' | head -1)")"
[ -n "$GENINC" ] && INC="$INC -I$GENINC"

# Standalone driver (grok ships fuzzingengine.c: a single-file run-once driver reading one input file).
# Compile it once; no libFuzzer runtime. NB: the file uses `auto` type inference yet relies on C's
# implicit void* conversions (its LLVMFuzzerTestOneInput takes void*), so it only compiles cleanly as
# C23 (auto inference + lax void* rules) — not as C++ and not as pre-C23 C.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -std=c23 -c "$HARNESS_DIR/fuzzingengine.c" -o "$BUILD/fuzzingengine.o"

# ── 2) Build each OSS-Fuzz harness twice: libFuzzer (-> /mayhem/<name>) + standalone reproducer ─────
LINK_LIBS=("$LIBGROK" "$LIBHWY" "$LIBLCMS" -lm -lpthread)
for harness in grk_decompress_fuzzer grk_compress_fuzzer; do
  # libFuzzer target -> /mayhem/<name>
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++20 $INC \
      "$HARNESS_DIR/$harness.cpp" $LIB_FUZZING_ENGINE "${LINK_LIBS[@]}" \
      -o "/mayhem/$harness"

  # standalone reproducer (no libFuzzer runtime, reads one input file) -> /mayhem/<name>-standalone
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++20 $INC \
      "$HARNESS_DIR/$harness.cpp" "$BUILD/fuzzingengine.o" "${LINK_LIBS[@]}" \
      -o "/mayhem/$harness-standalone"

  echo "built $harness (+ standalone)"
done

# ── 3) Build grok's core library with NORMAL flags + the self-contained golden known-answer test ────
# Separate clean tree (no sanitizers / no fuzzer instrumentation) so mayhem/test.sh is an honest
# PATCH oracle: it RUNS this prebuilt binary (it never compiles). The test decodes two bundled golden
# JPEG2000 images and asserts their exact known dimensions/components/precision, so a no-op/exit(0)
# patch cannot pass.
TBUILD="$SRC/mayhem-tests"
rm -rf "$TBUILD"
mkdir -p "$TBUILD"
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  cmake -S "$SRC" -B "$TBUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DGRK_BUILD_CODEC=OFF \
    -DGRK_BUILD_CORE_EXAMPLES=OFF \
    -DGRK_BUILD_CORE_SWIG_BINDINGS=OFF \
    -DBUILD_TESTING=OFF \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    "${FMT_CACHE_ARG[@]}"
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  cmake --build "$TBUILD" --target grokj2k --parallel "$MAYHEM_JOBS"

T_LIBGROK="$(find "$TBUILD" -name 'libgrokj2k.a' | head -1)"
T_LIBHWY="$(find "$TBUILD" -name 'libhwy.a' | head -1)"
T_LIBLCMS="$(find "$TBUILD" -name 'liblcms2.a' | head -1)"
T_GENINC="$(dirname "$(find "$TBUILD" -name 'grk_config.h' | head -1)")"
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  $CXX -O2 -std=c++20 -I"$SRC/src/lib/core" -I"$T_GENINC" \
    "$HARNESS_DIR/roundtrip_test.cpp" \
    "$T_LIBGROK" "$T_LIBHWY" "$T_LIBLCMS" -lm -lpthread \
    -o "$TBUILD/roundtrip_test"
echo "built round-trip golden test -> $TBUILD/roundtrip_test"

echo "build.sh complete:"
ls -la /mayhem/grk_decompress_fuzzer /mayhem/grk_compress_fuzzer \
       /mayhem/grk_decompress_fuzzer-standalone /mayhem/grk_compress_fuzzer-standalone 2>&1 || true
