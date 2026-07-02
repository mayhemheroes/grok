#!/usr/bin/env bash
#
# grok/mayhem/test.sh — RUN grok's self-contained round-trip golden test (built by mayhem/build.sh
# with NORMAL flags) and emit a CTRF summary. exit 0 iff the test passed.
#
# PATCH-grade oracle (anti-reward-hacking, §6.3): mayhem/harnesses/roundtrip_test.cpp decodes two
# small bundled golden JPEG 2000 images (mayhem/testdata/) through grok's real decode path and
# asserts the decoded width / height / component count / precision equal hard-coded known answers
# from each file's SIZ marker AND that grk_decompress() succeeds. The binary emits a distinct PASS
# line with exact dimension values for each golden file:
#
#   roundtrip_test PASS [basn4a08.jp2]: 32x32 x2 prec8
#   roundtrip_test PASS [p0_12.j2k]: 3x5 x1 prec8
#
# This script CAPTURES that output and checks for both golden strings — so a no-op / exit(0) /
# "always return 0 without parsing" patch FAILS: it exits 0 but produces no output, and the grep
# below does NOT find the expected dimension strings.
#
# This script only RUNS the prebuilt binary; it never compiles.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

SRC="${SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TBUILD="$SRC/mayhem-tests"
BIN="$TBUILD/roundtrip_test"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if [ ! -x "$BIN" ]; then
  echo "missing $BIN — run mayhem/build.sh first" >&2
  emit_ctrf "grok-roundtrip" 0 1 0; exit 2
fi

JP2="$SRC/mayhem/testdata/basn4a08.jp2"
J2K="$SRC/mayhem/testdata/p0_12.j2k"
if [ ! -f "$JP2" ] || [ ! -f "$J2K" ]; then
  echo "missing golden testdata ($JP2 / $J2K)" >&2
  emit_ctrf "grok-roundtrip" 0 1 0; exit 2
fi

echo "=== running $BIN ==="
# Capture output so we can assert the exact dimension strings, not just the exit code.
# A no-op / exit(0) patch exits 0 but produces NO output, so the grep below fails it.
OUT="$("$BIN" "$JP2" "$J2K" 2>&1)" || {
  rc=$?
  echo "$OUT"
  echo "round-trip test failed (exit $rc)" >&2
  emit_ctrf "grok-roundtrip" 0 1 0; exit 1
}
echo "$OUT"

# Assert both expected golden-decode PASS lines with their exact dimension values.
# basn4a08.jp2: 32x32, 2 components, 8-bit; p0_12.j2k: 3x5, 1 component, 8-bit.
fail=0
if ! printf '%s\n' "$OUT" | grep -qF "roundtrip_test PASS [basn4a08.jp2]: 32x32 x2 prec8"; then
  echo "FAIL: expected 'roundtrip_test PASS [basn4a08.jp2]: 32x32 x2 prec8' in output" >&2
  fail=1
fi
if ! printf '%s\n' "$OUT" | grep -qF "roundtrip_test PASS [p0_12.j2k]: 3x5 x1 prec8"; then
  echo "FAIL: expected 'roundtrip_test PASS [p0_12.j2k]: 3x5 x1 prec8' in output" >&2
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  emit_ctrf "grok-roundtrip" 1 0 0
else
  emit_ctrf "grok-roundtrip" 0 1 0; exit 1
fi
