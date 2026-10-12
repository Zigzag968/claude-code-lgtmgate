#!/usr/bin/env bash
# Self-test of scripts/run-metrics.cjs (#44): fixture-driven, no network, no gh.
# Checks the per-run table, the not-measured cases, the aggregates, the CSV, anonymization and usage errors.
# bash 3.2 compatible. Trailer: [test-run-metrics] status=<ok|fail> passed=<n> failed=<n>
set -u
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
TMP="${TMPDIR:-/tmp}/run-metrics-selftest.$$"; mkdir -p "$TMP"
RM=scripts/run-metrics.cjs
FX=fixtures/metrics

# expect <label> <expected> <actual>
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2], got [$3]"; fi; }
# row <n>   the table row of run-n in $TMP/out.md
row() { grep "^| run-$1 |" "$TMP/out.md"; }

node "$RM" --input "$FX" --csv "$TMP/out.csv" > "$TMP/out.md"; rc=$?
expect "run on the fixtures exits 0" 0 "$rc"

n=$(grep -c '^| run-' "$TMP/out.md")
if [ "$n" -ge 20 ]; then ok "at least 20 run rows ($n)"; else bad "only $n run rows"; fi
labels=$(grep '^| run-' "$TMP/out.md" | sed 's/^| run-\([0-9]*\) .*/\1/' | tr '\n' ' ')
want=$(i=1; while [ "$i" -le "$n" ]; do printf '%s ' "$i"; i=$((i+1)); done)
expect "labels run-1..run-N are contiguous" "$want" "$labels"

expect "3-round row"            "| run-16 | 3 | 4.5 | 30 | merged |" "$(row 16)"
expect "2-round row"            "| run-13 | 2 | 3 | 6 | merged |" "$(row 13)"
expect "no decision-log block"  "| run-17 | not measured | 2 | 5 | merged |" "$(row 17)"
expect "block without LGTM"     "| run-18 | not measured | 2.5 | 7 | merged |" "$(row 18)"
expect "closed-unmerged row"    "| run-19 | not measured | 3 | not measured | closed-unmerged |" "$(row 19)"
expect "open row"               "| run-20 | not measured | 1 | not measured | open |" "$(row 20)"
expect "PR without a Closes link" "| run-21 | not measured | not measured | 4 | merged |" "$(row 21)"
expect "Closes pointing to an absent issue" "| run-22 | not measured | not measured | 3 | merged |" "$(row 22)"

expect "run count"        "Runs: 22" "$(grep '^Runs:' "$TMP/out.md")"
expect "1 round count"    "- 1 round: 12" "$(grep '^- 1 round' "$TMP/out.md")"
expect "2 rounds count"   "- 2 rounds: 3" "$(grep '^- 2 rounds' "$TMP/out.md")"
expect "3 rounds count"   "- 3 rounds: 1" "$(grep '^- 3 rounds' "$TMP/out.md")"
expect "PR to merge aggregate" "PR to merge (h): median 7.0, max 30.0" "$(grep '^PR to merge (h):' "$TMP/out.md")"
expect "issue to PR max"  ", max 6.5" "$(grep '^Issue to PR (h):' "$TMP/out.md" | sed 's/.*\(, max .*\)/\1/')"
expect "rounds not-measured count" "Rounds to LGTM: 6 runs not measured (excluded from aggregates)" "$(grep '^Rounds to LGTM:' "$TMP/out.md")"
expect "tokens line"      "tokens per run and agent: not measured" "$(grep '^tokens' "$TMP/out.md")"
expect "takeover line"    "merged without manual takeover: not measured" "$(grep '^merged without' "$TMP/out.md")"

expect "CSV header" "run,rounds_to_lgtm,issue_to_pr_hours,pr_to_merge_hours,outcome" "$(sed -n 1p "$TMP/out.csv")"
expect "CSV line count" "$((n+1))" "$(wc -l < "$TMP/out.csv" | tr -d ' ')"
expect "CSV closed-unmerged row" "run-19,not measured,3,not measured,closed-unmerged" "$(grep '^run-19,' "$TMP/out.csv")"

leaks=$(cat "$TMP/out.md" "$TMP/out.csv" | grep -ciE 'lgtmgate|/(Volumes|Users|home)/|#[0-9]')
expect "no repo name, path or issue number in the outputs" 0 "$leaks"

# usage errors
node "$RM" 2>/dev/null; expect "no mode exits 2" 2 "$?"
node "$RM" --input "$FX" --repo a/b 2>/dev/null; expect "both modes exit 2" 2 "$?"
node "$RM" --input "$FX" --bogus 2>/dev/null; expect "unknown flag exits 2" 2 "$?"
node "$RM" --input 2>/dev/null; expect "missing value exits 2" 2 "$?"
node "$RM" --repo 'not a repo' 2>/dev/null; expect "bad --repo shape exits 2" 2 "$?"

# missing pulls.json
mkdir -p "$TMP/half"; cp "$FX/issues.json" "$TMP/half/"
node "$RM" --input "$TMP/half" >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then ok "missing pulls.json fails (exit $rc)"; else bad "missing pulls.json: exit $rc"; fi

# a modified copy changes only the affected rows
mkdir -p "$TMP/mod"; cp "$FX/issues.json" "$TMP/mod/"
node -e '
const fs=require("fs");const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
p[0].merged_at=null;p[0].state="open";
p[1].body=p[1].body.replace(/- round 1 — LGTM/,"- round 1 — REQUIRED_CHANGES (1 blocker)");
fs.writeFileSync(process.argv[2],JSON.stringify(p));' "$FX/pulls.json" "$TMP/mod/pulls.json"
node "$RM" --input "$TMP/mod" > "$TMP/mod.md"
diffrows=$(diff "$TMP/out.md" "$TMP/mod.md" | grep -c '^>.*| run-')
expect "modified copy changes exactly 2 rows" 2 "$diffrows"
expect "dropped merged_at gives an open row" "| run-1 | 1 | 1 | not measured | open |" "$(grep '^| run-1 |' "$TMP/mod.md")"
expect "LGTM-less body gives rounds not measured" "| run-2 | not measured | 1.5 | 3 | merged |" "$(grep '^| run-2 |' "$TMP/mod.md")"

rm -rf "$TMP"
RESULT=ok; [ "$FAIL" -gt 0 ] && RESULT=fail
echo "[test-run-metrics] status=$RESULT passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
