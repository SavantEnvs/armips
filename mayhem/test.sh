#!/usr/bin/env bash
#
# mayhem/test.sh — RUN the upstream armips functional test suite (built by mayhem/build.sh).
# The armipstests binary assembles every project in Tests/ and golden-diffs the produced bytes /
# error output against the committed expected.bin / expected.txt, returning nonzero on any mismatch.
# This is a behavioral oracle: an exit(0) sabotage of the assembler makes the golden diffs fail.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

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

RUNNER="$SRC/build-tests/armipstests"
if [ ! -x "$RUNNER" ]; then
  echo "test runner missing: $RUNNER (build.sh should have produced it)" >&2
  emit_ctrf "armipstests" 0 1
  exit 1
fi

out="$("$RUNNER" "$SRC/Tests" 2>&1)" ; rc=$?
echo "$out"

# The runner prints "<passed> out of <total> tests passed." (with ANSI color codes). Strip the
# escapes, then parse the counts.
summary=$(printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -oE '[0-9]+ out of [0-9]+ tests passed' | tail -1)
passed=$(printf '%s\n' "$summary" | awk '{print $1}')
total=$(printf '%s\n'  "$summary" | awk '{print $4}')

if [ -z "$total" ] || [ -z "$passed" ]; then
  echo "could not parse test summary from armipstests output" >&2
  emit_ctrf "armipstests" 0 1
  exit 1
fi

failed=$(( total - passed ))
# Reconcile with the runner's own exit status: a nonzero rc means at least one failure.
if [ "$rc" -ne 0 ] && [ "$failed" -eq 0 ]; then failed=1; fi

emit_ctrf "armipstests" "$passed" "$failed"
