#!/usr/bin/env bash
# Regression test for templates/probe-run.cjs (E2.2, #80): pure parsers replayed against
# fixtures/probes/*.raw, plus end-to-end runs of the CLI in a temp dir. No network. bash 3.2 safe.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PR="$SCRIPT_DIR/probe-run.cjs"
TMP_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
WORK="$(mktemp -d "$TMP_BASE/probe-run-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

HI_SHA=98ea6e4f216f2fb4b69fff9b3a44842c38686ca685f3f55dc48c5d3fb1107be4

pass_count=0
fail_count=0

check() {
  local name="$1" ok="$2"
  if [ "$ok" -eq 1 ]; then echo "PASS - $name"; pass_count=$((pass_count + 1))
  else echo "FAIL - $name"; fail_count=$((fail_count + 1)); fi
}

# (a) every fixtures/probes/<parser>--<case>.raw through PARSERS deep-equals its .expected
n_raw=0
for raw in "$ROOT"/fixtures/probes/*.raw; do
  [ -f "$raw" ] || continue
  n_raw=$((n_raw + 1))
  base="$(basename "$raw" .raw)"
  parser="${base%%--*}"
  exp="$ROOT/fixtures/probes/$base.expected"
  ok=0
  if [ -f "$exp" ] && node -e '
    const fs = require("fs"), assert = require("assert")
    const { PARSERS } = require(process.argv[1])
    const got = PARSERS[process.argv[2]](fs.readFileSync(process.argv[3], "utf8"), "", 0)
    assert.deepStrictEqual(got, JSON.parse(fs.readFileSync(process.argv[4], "utf8")))
  ' "$PR" "$parser" "$raw" "$exp" 2>/dev/null; then ok=1; fi
  check "parser fixture $base" "$ok"
done
[ "$n_raw" -ge 8 ] && ok=1 || ok=0
check "at least 2 fixtures per parser (found $n_raw .raw files)" "$ok"

# (b) e2e: one PROBE line, exit=0, known sha, record with 8 keys
OUT1="$WORK/b"
LINE="$(node "$PR" --label t --round 0 --out "$OUT1" --parser lines --cmd "printf 'hi\n'")"
RC=$?
ok=0
[ "$RC" -eq 0 ] && [ "$(printf '%s\n' "$LINE" | wc -l | tr -d ' ')" = "1" ] &&
  [ "$LINE" = "PROBE name=lines exit=0 sha=$HI_SHA json={\"lines\":[\"hi\"]}" ] && ok=1
check "e2e printf hi: single PROBE line with expected sha" "$ok"
ok=0
[ "$(node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(Object.keys(r).length)' "$OUT1/t-r0.json")" = "8" ] && ok=1
check "record has 8 keys" "$ok"

# (c) failing command: exit=3 reported, script exits 0
LINE="$(node "$PR" --label f --round 1 --out "$WORK/c" --parser lines --cmd 'exit 3')"
RC=$?
ok=0
[ "$RC" -eq 0 ] && case "$LINE" in "PROBE name=lines exit=3 "*) ok=1 ;; esac
check "failing cmd: exit=3 in line, script exit 0" "$ok"

# (d) idempotence: same label/round with another cmd returns the same sha, file unchanged
BEFORE="$(cat "$OUT1/t-r0.json")"
LINE2="$(node "$PR" --label t --round 0 --out "$OUT1" --parser lines --cmd "printf 'other\n'")"
AFTER="$(cat "$OUT1/t-r0.json")"
ok=0
case "$LINE2" in *"sha=$HI_SHA "*) [ "$BEFORE" = "$AFTER" ] && ok=1 ;; esac
check "idempotent: existing record reused, bytes unchanged" "$ok"

# (e) 70000 bytes -> truncated, stored length 65536
node "$PR" --label big --round 0 --out "$WORK/e" --parser lines --cmd "head -c 70000 /dev/zero | tr '\\0' x" >/dev/null
ok=0
[ "$(node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(r.truncated+":"+Buffer.byteLength(r.stdout))' "$WORK/e/big-r0.json")" = "true:65536" ] && ok=1
check "70000-byte output: truncated true, stored 65536" "$ok"

# (f) invalid invocations exit 2
node "$PR" --label t --round 0 --out relative/dir --parser lines --cmd 'true' >/dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] && ok=1 || ok=0
check "relative --out exits 2" "$ok"
node "$PR" --label 'a b' --round 0 --out "$WORK/g" --parser lines --cmd 'true' >/dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] && ok=1 || ok=0
check "unsafe label exits 2" "$ok"

# unknown parser still prints a line
LINE="$(node "$PR" --label u --round 0 --out "$WORK/h" --parser nope --cmd 'true')"
case "$LINE" in *'json={"error":"unknown-parser"}') ok=1 ;; *) ok=0 ;; esac
check "unknown parser -> error json" "$ok"

# (g) agents/probe.md tools: lists exactly Bash
TOOLS="$(awk '/^---$/{f++; next} f==1 && /^tools:/{t=1; next} f==1 && t && /^  - /{sub(/^  - /,""); print; next} f==1 && t{t=0}' "$ROOT/agents/probe.md" | tr '\n' ',')"
[ "$TOOLS" = "Bash," ] && ok=1 || ok=0
check "agents/probe.md tools is exactly Bash (got '$TOOLS')" "$ok"

if [ "$fail_count" -eq 0 ]; then st=ok; else st=fail; fi
echo "[probe-run] status=$st passed=$pass_count failed=$fail_count"
[ "$fail_count" -eq 0 ]
