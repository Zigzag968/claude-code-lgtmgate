#!/usr/bin/env bash
# launch-bytes cases (#527), sourced by tests/scripts/test-guards.sh (uses its ok/ko helpers, $T and $REPO_ROOT).
# The mutated builder lives only in a temp copy of scripts/ read through GUARDS_ROOT, never in the tracked tree.

LB_RE='^LB launch-bytes stage=(plan|review) size=(4k|22k|60k) mode=full base=[0-9]+ branch=[0-9]+ ok$'
LB_REF_RE='^LB launch-bytes stage=plan size=(4k|22k|60k) mode=ref budget=2048 branch=[0-9]+ ok$'
LB_FLAT_RE='^LB launch-bytes flat spread=[0-9]+ ok$'
# run_lb <root>: sets RC and OUT
run_lb() { OUT="$(GUARDS_ROOT="$1" GUARDS_ONLY=launch-bytes node "$REPO_ROOT/scripts/guards.cjs" 2>&1)"; RC=$?; }
# mklb <dir>: a copy of scripts/ (what the check measures) under <dir>
mklb() { mkdir -p "$1" && cp -R "$REPO_ROOT/scripts" "$1/scripts"; }
# lb_git <dir>: make <dir> a git root whose origin/main holds the files as they are now
lb_git() {
  git init -q "$1"
  git -C "$1" add -A
  git -C "$1" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m base
  git -C "$1" update-ref refs/remotes/origin/main HEAD
}

run_lb "$REPO_ROOT"
if [ "$RC" -eq 0 ] && [ "$(echo "$OUT" | grep -cE "$LB_RE")" = "6" ] && [ "$(echo "$OUT" | grep -cE "$LB_REF_RE")" = "3" ] && [ "$(echo "$OUT" | grep -cE "$LB_FLAT_RE")" = "1" ] && [ "$(echo "$OUT" | wc -l | tr -d ' ')" = "10" ]; then ok "launch-bytes: the real tree prints six full lines, three ref lines and the flat line, all ok, and exits 0"; else ko "launch-bytes real (rc=$RC) $OUT"; fi

if [ "$(grep -c "'launch-bytes'" scripts/guards.cjs)" -ge 2 ]; then ok "launch-bytes: the check is in the default list and in CHECKS"; else ko "launch-bytes not registered in scripts/guards.cjs"; fi

mklb "$T/lb-up"
sed "s/implement the issue/implement the issuex/" scripts/runtime/launch-args.cjs > "$T/lb-up/scripts/runtime/launch-args.cjs"
if cmp -s scripts/runtime/launch-args.cjs "$T/lb-up/scripts/runtime/launch-args.cjs"; then ko "launch-bytes: the mutated builder copy does not differ"; fi
run_lb "$T/lb-up"
LB_UP="$(echo "$OUT" | grep '^LB launch-bytes stage=plan size=22k mode=full ')"
LB_BASE="$(echo "$LB_UP" | sed -E 's/.* base=([0-9]+) .*/\1/')"
LB_BRANCH="$(echo "$LB_UP" | sed -E 's/.* branch=([0-9]+) .*/\1/')"
if [ "$RC" -eq 1 ] && echo "$LB_UP" | grep -q ' UP$' && [ -n "$LB_BASE" ] && [ "$LB_BRANCH" -eq $((LB_BASE + 1)) ]; then ok "launch-bytes: a builder emitting one more byte at 22k prints UP and exits 1"; else ko "launch-bytes UP (rc=$RC) $OUT"; fi

mklb "$T/lb-nobase"
rm -f "$T/lb-nobase/scripts/launch-bytes-baseline.json"
run_lb "$T/lb-nobase"
if [ "$RC" -eq 1 ] && echo "$OUT" | grep -q '^FAIL: launch-bytes'; then ok "launch-bytes: a missing baseline fails"; else ko "launch-bytes no baseline (rc=$RC) $OUT"; fi

mklb "$T/lb-raise"
lb_git "$T/lb-raise"
node -e 'const fs = require("fs"), f = process.argv[1], b = JSON.parse(fs.readFileSync(f, "utf8")); b.plan["22k"] += 100; fs.writeFileSync(f, JSON.stringify(b, null, 2) + "\n")' "$T/lb-raise/scripts/launch-bytes-baseline.json"
run_lb "$T/lb-raise"
if [ "$RC" -eq 1 ] && echo "$OUT" | grep -q '^FAIL: launch-bytes: baseline plan 22k'; then ok "launch-bytes: a baseline raised over origin/main fails"; else ko "launch-bytes raise (rc=$RC) $OUT"; fi
node -e 'const fs = require("fs"), f = process.argv[1], b = JSON.parse(fs.readFileSync(f, "utf8")); b.debt = "DEBT(#9)"; fs.writeFileSync(f, JSON.stringify(b, null, 2) + "\n")' "$T/lb-raise/scripts/launch-bytes-baseline.json"
run_lb "$T/lb-raise"
if [ "$RC" -eq 0 ]; then ok "launch-bytes: the same raise with a DEBT(#N) key passes"; else ko "launch-bytes debt (rc=$RC) $OUT"; fi

# budgetProblems <plan json> <mode> <switch> -> number of messages
lb_budget() { node -e 'process.stdout.write(String(require(process.argv[1]).budgetProblems(JSON.parse(process.argv[2]), process.argv[3], process.argv[4]).length))' "$REPO_ROOT/scripts/lib/launch-bytes.cjs" "$1" "$2" "$3"; }
if [ "$(lb_budget '{"4k":9999,"22k":1,"60k":1}' ref off)" = "0" ]; then ok "launch-bytes budget: off reports nothing"; else ko "launch-bytes budget off"; fi
if [ "$(lb_budget '{"4k":9999,"22k":1,"60k":1}' full on)" = "0" ]; then ok "launch-bytes budget: mode full has no budget"; else ko "launch-bytes budget full"; fi
if [ "$(lb_budget '{"4k":2049,"22k":2049,"60k":2049}' ref on)" = "3" ]; then ok "launch-bytes budget: on + ref reports each size over 2048"; else ko "launch-bytes budget over"; fi
if [ "$(lb_budget '{"4k":1000,"22k":1000,"60k":1065}' ref on)" = "1" ]; then ok "launch-bytes budget: a spread of 65 reports one message"; else ko "launch-bytes budget spread 65"; fi
if [ "$(lb_budget '{"4k":1000,"22k":1030,"60k":1064}' ref on)" = "0" ]; then ok "launch-bytes budget: a spread of 64 under 2048 reports nothing"; else ko "launch-bytes budget spread 64"; fi
if [ "$(lb_budget '{"4k":9999,"22k":1,"60k":1}' ref '')" = "2" ]; then ok "launch-bytes budget: an empty switch is active"; else ko "launch-bytes budget empty switch"; fi
if [ "$(node -e 'process.stdout.write(String(require(process.argv[1]).budgetProblems({"4k":9999,"22k":1,"60k":1}, "ref", undefined).length))' "$REPO_ROOT/scripts/lib/launch-bytes.cjs")" = "2" ]; then ok "launch-bytes budget: an unset switch is active (default on)"; else ko "launch-bytes budget unset switch"; fi

# the live guard: a ref builder that grows past the budget fails once per size over, and LAUNCH_BYTES_BUDGET=off silences it
mklb "$T/lb-ref"
sed "s/arguments_.sessionRoot = options.sessionRoot === undefined ? root : options.sessionRoot/arguments_.sessionRoot = options.sessionRoot === undefined ? root : options.sessionRoot; if (mode === 'ref') arguments_.brief = 'x'.repeat(3000)/" scripts/runtime/launch-args.cjs > "$T/lb-ref/scripts/runtime/launch-args.cjs"
if cmp -s scripts/runtime/launch-args.cjs "$T/lb-ref/scripts/runtime/launch-args.cjs"; then ko "launch-bytes: the mutated ref builder copy does not differ"; fi
run_lb "$T/lb-ref"
if [ "$RC" -eq 1 ] && [ "$(echo "$OUT" | grep -c 'mode=ref budget=2048 .* UP$')" = "3" ] && [ "$(echo "$OUT" | grep -c '^FAIL: launch-bytes: plan ')" = "3" ]; then ok "launch-bytes: a ref launch over the budget prints UP three times, one FAIL line per size and exits 1"; else ko "launch-bytes ref over (rc=$RC) $OUT"; fi
OUT="$(LAUNCH_BYTES_BUDGET=off GUARDS_ROOT="$T/lb-ref" GUARDS_ONLY=launch-bytes node "$REPO_ROOT/scripts/guards.cjs" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && ! echo "$OUT" | grep -q ' UP$'; then ok "launch-bytes: LAUNCH_BYTES_BUDGET=off silences the ref budget"; else ko "launch-bytes budget off live (rc=$RC) $OUT"; fi
