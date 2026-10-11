#!/usr/bin/env bash
# Self-test of scripts/template-drift.cjs (#38). Everything runs in $TMPDIR; nothing is written in the repository.
# bash 3.2 compatible. Trailer: [test-template-drift] status=<ok|fail> passed=<n> failed=<n>
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
TD="$ROOT/scripts/template-drift.cjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/template-drift-selftest.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# run <args...> : output in $TMP/out, exit code in $rc
run() { node "$TD" "$@" > "$TMP/out" 2>&1; rc=$?; }
last() { tail -n 1 "$TMP/out"; }
has() { grep -qF -- "$1" "$TMP/out"; }

# fresh <name> : a consumer directory whose two copies equal the templates
fresh() {
  local dir="$TMP/$1"
  mkdir -p "$dir/.claude/scripts" "$dir/scripts"
  cp "$ROOT/templates/provision-worktree.sh" "$dir/scripts/provision-worktree.sh"
  cp "$ROOT/templates/blocked-by-check.sh" "$dir/.claude/scripts/blocked-by-check.sh"
  echo "$dir"
}

# T1 identical copies
D=$(fresh t1)
run --root "$D"
if [ "$rc" -eq 0 ] && [ "$(last)" = "[template-drift] status=ok read=1 optional=1 differs=0 absent=0" ] && has 'next: nothing to do before the run' && ! has 'order:' && ! has 'obsolete:' && ! has 'warn:'; then ok "T1 identical copies are quiet"; else bad "T1 rc=$rc $(cat "$TMP/out")"; fi

# T2 read-by-engine copy differs on a line that is not a parsed token
D=$(fresh t2)
echo "local line" >> "$D/scripts/provision-worktree.sh"
run --root "$D"
if [ "$rc" -eq 0 ] && has 'scripts/provision-worktree.sh [read-by-engine] differs from the current template' && has 'never overwrite' && has 'diff scripts/provision-worktree.sh' && has 'order: 1.' && [ "$(last | cut -c1-26)" = "[template-drift] status=wa" ]; then ok "T2 differing engine-read copy says decide, never overwrite, with the diff command"; else bad "T2 rc=$rc $(cat "$TMP/out")"; fi

# T3 provision-worktree.sh absent, no config
D=$(fresh t3)
rm "$D/scripts/provision-worktree.sh"
run --root "$D"
if [ "$rc" -eq 0 ] && has 'PROVISION-NO-SCRIPT' && has 'fix before the run' && has '/lgtmgate:init' && [ "$(last)" = "[template-drift] status=warn read=0 optional=1 differs=0 absent=1" ]; then ok "T3 absent engine-read copy names the effect and the install step"; else bad "T3 rc=$rc $(cat "$TMP/out")"; fi

# T4 legacy name alone
D=$(fresh t4)
mv "$D/scripts/provision-worktree.sh" "$D/scripts/provision_worktree.sh"
run --root "$D"
if [ "$rc" -eq 0 ] && has '[legacy-name]' && has 'no effect on the run' && has 'git mv scripts/provision_worktree.sh' && ! has 'order:' && [ "$(last | cut -c1-26)" = "[template-drift] status=ok" ]; then ok "T4 legacy name is info with git mv"; else bad "T4 rc=$rc $(cat "$TMP/out")"; fi

# T5 unreadable root
run --root "$TMP/does-not-exist"
if [ "$rc" -eq 0 ] && [ "$(grep -c '^warn:' "$TMP/out")" = 1 ] && has 'fix before the run' && ! has 'order:' && ! has 'next:' && [ "$(last | cut -c1-26)" = "[template-drift] status=wa" ]; then ok "T5 unreadable root is one warn line"; else bad "T5 rc=$rc $(cat "$TMP/out")"; fi

# T6 differing optional copy is info only
D=$(fresh t6)
echo "local line" >> "$D/.claude/scripts/blocked-by-check.sh"
run --root "$D"
if [ "$rc" -eq 0 ] && has 'info: .claude/scripts/blocked-by-check.sh [optional] differs' && has 'no effect on the run' && ! has 'warn:' && ! has 'order:' && [ "$(last)" = "[template-drift] status=ok read=1 optional=1 differs=1 absent=0" ]; then ok "T6 differing optional copy stays info"; else bad "T6 rc=$rc $(cat "$TMP/out")"; fi

# T7 nothing is written
D=$(fresh t7)
mkdir -p "$D/.claude/rules"
cp "$ROOT/templates/pr-acceptance.md" "$D/.claude/rules/pr-acceptance.md"
git -C "$D" init -q
BEFORE_STATUS=$(git -C "$D" status --porcelain)
BEFORE_LIST=$(find "$D" -not -path "$D/.git/*" | sort)
run --root "$D"
AFTER_STATUS=$(git -C "$D" status --porcelain)
AFTER_LIST=$(find "$D" -not -path "$D/.git/*" | sort)
if [ "$rc" -eq 0 ] && has 'obsolete:' && [ "$BEFORE_STATUS" = "$AFTER_STATUS" ] && [ "$BEFORE_LIST" = "$AFTER_LIST" ]; then ok "T7 the check writes nothing"; else bad "T7 rc=$rc"; fi

# T8 missing --root
run
if [ "$rc" -eq 0 ] && [ "$(grep -c '^warn:' "$TMP/out")" = 1 ] && has 'fix before the run' && [ "$(last | cut -c1-26)" = "[template-drift] status=wa" ]; then ok "T8 missing --root is one warn line"; else bad "T8 rc=$rc $(cat "$TMP/out")"; fi

# T9 the acceptance rule is still there: obsolete, remove it
D=$(fresh t9)
mkdir -p "$D/.claude/rules"
cp "$ROOT/templates/pr-acceptance.md" "$D/.claude/rules/pr-acceptance.md"
run --root "$D"
if [ "$rc" -eq 0 ] && has 'obsolete: .claude/rules/pr-acceptance.md' && has 'remove before the run' && has 'git rm .claude/rules/pr-acceptance.md' && has 'order: 1.' && [ "$(last)" = "[template-drift] status=warn read=1 optional=1 differs=0 absent=0" ]; then ok "T9 obsolete acceptance rule is removed before the run"; else bad "T9 rc=$rc $(cat "$TMP/out")"; fi

# T10 the status helper and the flow suite are still there: obsolete, no effect
D=$(fresh t10)
mkdir -p "$D/.claude/workflows"
cp "$ROOT/templates/gh-pipeline-status.sh" "$D/.claude/scripts/gh-pipeline-status.sh"
cp "$ROOT/templates/test-deliver-pipeline.js" "$D/.claude/workflows/test-deliver-pipeline.js"
run --root "$D"
if [ "$rc" -eq 0 ] && [ "$(grep -c '^obsolete:' "$TMP/out")" = 2 ] && has 'no effect on the run' && ! has 'order:' && has 'next:' && [ "$(last | cut -c1-26)" = "[template-drift] status=ok" ]; then ok "T10 unused copies are obsolete with no effect on the run"; else bad "T10 rc=$rc $(cat "$TMP/out")"; fi

# T11 provision copy lacks a token the engine parses
D=$(fresh t11)
grep -v 'MISSING-SRC ' "$ROOT/templates/provision-worktree.sh" > "$D/scripts/provision-worktree.sh"
run --root "$D"
if [ "$rc" -eq 0 ] && has "lacks 'MISSING-SRC '" && has 'fix before the run: port the new rules' && has 'order: 1.' && [ "$(last | cut -c1-26)" = "[template-drift] status=wa" ]; then ok "T11 a copy lacking a parsed token must be ported"; else bad "T11 rc=$rc $(cat "$TMP/out")"; fi

# T12 provision script absent and no required link configured: skipped by the engine
D=$(fresh t12)
rm "$D/scripts/provision-worktree.sh"
printf '{"provision":{"extraLinks":[]}}' > "$D/.claude/pipeline.config.json"
run --root "$D"
if [ "$rc" -eq 0 ] && has 'PROVISION-SKIPPED-NO-SCRIPT' && has 'no effect on the run' && ! has 'order:' && [ "$(last | cut -c1-26)" = "[template-drift] status=ok" ]; then ok "T12 absent script with no required link is skipped"; else bad "T12 rc=$rc $(cat "$TMP/out")"; fi

RESULT=ok; [ "$FAIL" -eq 0 ] || RESULT=fail
echo "[test-template-drift] status=${RESULT} passed=${PASS} failed=${FAIL}"
[ "$FAIL" -eq 0 ]
