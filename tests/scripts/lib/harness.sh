#!/usr/bin/env bash
# Shared helper of the shell test scripts under tests/scripts (sourced, never executed).
# Holds the PASS/FAIL counters, the `ok`/`bad` reporters and `bumped_engine`.
# HARNESS_OK_PREFIX sets the word printed before an `ok` line (default `ok`); `bad` always prints `FAIL:`.
# The caller prints its own summary line.
PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); echo "${HARNESS_OK_PREFIX:-ok}: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
bumped_engine() { # <out file>: the engine with another BUILD version
  ROOT="$ROOT" node -e 'const fs=require("fs");const s=fs.readFileSync(process.env.ROOT+"/workflows/deliver-pipeline.js","utf8");fs.writeFileSync(process.argv[1],s.replace(/(const BUILD = \{[^}]*\bversion: \x27)[^\x27]+/,"$19.9.9-bumped"))' "$1"
}
