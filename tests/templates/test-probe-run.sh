#!/usr/bin/env bash
# Regression test for templates/probe-run.cjs (E2.2, #80), templates/preflight.sh (#83) and templates/pr-state.sh (#84) and templates/pr-write.sh (#85): pure parsers replayed against
# fixtures/probes/*.raw, plus end-to-end runs of the CLI in a temp dir. No network. bash 3.2 safe.
set -uo pipefail

TMP_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
WORK="$(mktemp -d "$TMP_BASE/probe-run-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass_count=0
fail_count=0

check() {
  local name="$1" ok="$2"
  if [ "$ok" -eq 1 ]; then echo "PASS - $name"; pass_count=$((pass_count + 1))
  else echo "FAIL - $name"; fail_count=$((fail_count + 1)); fi
}

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"
. "$LIB/probe-run-core.sh"
. "$LIB/probe-run-pr-state.sh"
. "$LIB/probe-run-pr-write.sh"
. "$LIB/probe-run-engine-parity.sh"

if [ "$fail_count" -eq 0 ]; then st=ok; else st=fail; fi
echo "[probe-run] status=$st passed=$pass_count failed=$fail_count"
[ "$fail_count" -eq 0 ]
