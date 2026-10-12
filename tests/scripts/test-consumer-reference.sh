#!/usr/bin/env bash
# Self-test of the `consumer-reference` rule of scripts/guards.cjs (#414): each failure condition makes the
# guard exit non-zero and name the rule and the name. Everything runs on scratch copies under $TMPDIR; nothing is
# written in the repository. bash 3.2 compatible.
# Trailer: [test-consumer-reference] status=<ok|fail> passed=<n> failed=<n>
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
GUARDS="$ROOT/scripts/guards.cjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/consumer-reference-selftest.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# fresh <name> : a scratch root with the files the rule reads, in $TMP/<name>; the base baseline in $TMP/<name>.base.json
fresh() {
  local scratch="$TMP/$1"
  mkdir -p "$scratch/workflows" "$scratch/scripts/lib" "$scratch/hooks" "$scratch/docs"
  cp "$ROOT/workflows/deliver-pipeline.js" "$scratch/workflows/"
  cp "$ROOT/scripts/runtime/agent-context.cjs" "$scratch/scripts/"
  cp "$ROOT/scripts/lib/agent-context-text.cjs" "$ROOT/scripts/lib/agent-context-lanes.cjs" "$scratch/scripts/lib/"
  cp "$ROOT"/hooks/*.sh "$scratch/hooks/"
  cp "$ROOT/docs/consumer-reference.md" "$scratch/docs/"
  cp "$ROOT/scripts/consumer-reference-baseline.json" "$scratch/scripts/"
  cp "$ROOT/scripts/consumer-reference-baseline.json" "$TMP/$1.base.json"
}

# run <name> : the guard on a scratch root, output in $TMP/out, exit code in $rc
run() {
  GUARDS_ROOT="$TMP/$1" GUARDS_ONLY=consumer-reference GUARDS_CONSUMER_BASELINE_BASE="$TMP/$1.base.json" node "$GUARDS" > "$TMP/out" 2>&1
  rc=$?
}
has() { grep -qF -- "$1" "$TMP/out"; }

# edit_json <file> <js statement on b> : rewrite a baseline file
edit_json() {
  node -e 'const fs=require("fs");const b=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));eval(process.argv[2]);fs.writeFileSync(process.argv[1],JSON.stringify(b,null,2)+"\n")' "$1" "$2"
}
# drop_row <name> <row name> : delete the reference row of a name
drop_row() { grep -vF -- "| \`$2\` |" "$TMP/$1/docs/consumer-reference.md" > "$TMP/rows" && cp "$TMP/rows" "$TMP/$1/docs/consumer-reference.md"; }

# 1 clean run
fresh c1; run c1
gaps=$(node -e 'const b=require(process.argv[1]);console.log(Object.values(b).flat().length)' "$ROOT/scripts/consumer-reference-baseline.json")
if [ "$rc" -eq 0 ] && has 'PASS: consumer-reference: ' && has ", $gaps baseline gaps"; then ok "1 clean run passes"; else bad "1 rc=$rc $(cat "$TMP/out")"; fi

# 2 a code name without a row and not in the baseline
fresh c2; drop_row c2 folder-absent; run c2
if [ "$rc" -ne 0 ] && has "FAIL: consumer-reference: Assembler refusals 'folder-absent' has no row and is not in the baseline"; then ok "2 a name without a row fails and is named"; else bad "2 rc=$rc $(cat "$TMP/out")"; fi

# 3 a row for a name the code does not emit
fresh c3
node -e 'const fs=require("fs");const p=process.argv[1];const t=fs.readFileSync(p,"utf8");fs.writeFileSync(p,t.replace("## Other reasons","| `ghost-reason` | nowhere | nothing | nothing to do |\n\n## Other reasons"))' "$TMP/c3/docs/consumer-reference.md"
run c3
if [ "$rc" -ne 0 ] && has "'ghost-reason' has a row but the code no longer emits it"; then ok "3 a stale row fails"; else bad "3 rc=$rc $(cat "$TMP/out")"; fi

# 4 an empty remedy
fresh c4
node -e 'const fs=require("fs");const p=process.argv[1];const t=fs.readFileSync(p,"utf8");fs.writeFileSync(p,t.replace(/(\| `gh` \|[^\n]*\|)[^|\n]*\|\s*$/m,"$1 |"))' "$TMP/c4/docs/consumer-reference.md"
run c4
if [ "$rc" -ne 0 ] && has "Prerequisites 'gh' has an empty remedy"; then ok "4 an empty remedy fails"; else bad "4 rc=$rc $(cat "$TMP/out")"; fi

# 5 a baseline entry added versus the base baseline
fresh c5; drop_row c5 folder-absent; edit_json "$TMP/c5/scripts/consumer-reference-baseline.json" 'b.assembler.push("folder-absent");b.assembler.sort()'; run c5
if [ "$rc" -ne 0 ] && has "'folder-absent' is not in the baseline of origin/main, the baseline may not grow"; then ok "5 a baseline entry that is added fails"; else bad "5 rc=$rc $(cat "$TMP/out")"; fi

# 6 a baseline name that already has a row
fresh c6
edit_json "$TMP/c6/scripts/consumer-reference-baseline.json" 'b.assembler.push("folder-absent")'
edit_json "$TMP/c6.base.json" 'b.assembler.push("folder-absent")'
run c6
if [ "$rc" -ne 0 ] && has "'folder-absent' is in the baseline but already has a row"; then ok "6 a baseline name with a row fails"; else bad "6 rc=$rc $(cat "$TMP/out")"; fi

# 7 a baseline name the code no longer emits
fresh c7
edit_json "$TMP/c7/scripts/consumer-reference-baseline.json" 'b.config.push("ghostKey")'
edit_json "$TMP/c7.base.json" 'b.config.push("ghostKey")'
run c7
if [ "$rc" -ne 0 ] && has "'ghostKey' is in the baseline but the code no longer emits it"; then ok "7 a gone baseline name fails"; else bad "7 rc=$rc $(cat "$TMP/out")"; fi

# 8 no base baseline and origin/main not resolvable (the scratch root is not a git repository)
fresh c8
GUARDS_ROOT="$TMP/c8" GUARDS_ONLY=consumer-reference node "$GUARDS" > "$TMP/out" 2>&1; rc=$?
if [ "$rc" -ne 0 ] && has 'FAIL: consumer-reference: cannot read base'; then ok "8 an unreadable base fails"; else bad "8 rc=$rc $(cat "$TMP/out")"; fi

# 9 the reference is missing
fresh c9; rm "$TMP/c9/docs/consumer-reference.md"; run c9
if [ "$rc" -ne 0 ] && has 'FAIL: consumer-reference: docs/consumer-reference.md missing'; then ok "9 a missing reference fails"; else bad "9 rc=$rc $(cat "$TMP/out")"; fi

# 10 the real tree, base seam pointing at the committed baseline
GUARDS_ONLY=consumer-reference GUARDS_CONSUMER_BASELINE_BASE="$ROOT/scripts/consumer-reference-baseline.json" node "$GUARDS" > "$TMP/out" 2>&1; rc=$?
if [ "$rc" -eq 0 ] && has 'PASS: consumer-reference:'; then ok "10 the real tree passes"; else bad "10 rc=$rc $(cat "$TMP/out")"; fi

# 11 an assembler warning row deleted
fresh c11; drop_row c11 not-on-base-ref; run c11
if [ "$rc" -ne 0 ] && has "FAIL: consumer-reference: Assembler warnings 'not-on-base-ref' has no row and is not in the baseline"; then ok "11 a deleted warning row fails and is named"; else bad "11 rc=$rc $(cat "$TMP/out")"; fi

# 12 a warning row for a warning the code does not emit
fresh c12
node -e 'const fs=require("fs");const p=process.argv[1];const t=fs.readFileSync(p,"utf8");fs.writeFileSync(p,t.replace("## Run reasons","| `ghost-warning` | nowhere | nothing | nothing to do |\n\n## Run reasons"))' "$TMP/c12/docs/consumer-reference.md"
run c12
if [ "$rc" -ne 0 ] && has "Assembler warnings 'ghost-warning' has a row but the code no longer emits it"; then ok "12 a stale warning row fails"; else bad "12 rc=$rc $(cat "$TMP/out")"; fi

if [ "$FAIL" -eq 0 ]; then status=ok; else status=fail; fi
echo "[test-consumer-reference] status=$status passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
