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

# fresh <name> : a consumer directory whose five copies equal the templates
fresh() {
  local dir="$TMP/$1"
  mkdir -p "$dir/.claude/rules" "$dir/.claude/scripts" "$dir/.claude/workflows" "$dir/scripts"
  cp "$ROOT/templates/pr-acceptance.md" "$dir/.claude/rules/pr-acceptance.md"
  cp "$ROOT/templates/provision-worktree.sh" "$dir/scripts/provision-worktree.sh"
  cp "$ROOT/templates/blocked-by-check.sh" "$dir/.claude/scripts/blocked-by-check.sh"
  cp "$ROOT/templates/gh-pipeline-status.sh" "$dir/.claude/scripts/gh-pipeline-status.sh"
  cp "$ROOT/templates/test-deliver-pipeline.js" "$dir/.claude/workflows/test-deliver-pipeline.js"
  echo "$dir"
}

# T1 identical copies
D=$(fresh t1)
run --root "$D"
if [ "$rc" -eq 0 ] && [ "$(last)" = "[template-drift] status=ok read=2 optional=3 differs=0 absent=0" ] && ! has 'warn:'; then ok "T1 identical copies are quiet"; else bad "T1 rc=$rc $(cat "$TMP/out")"; fi

# T2 read-by-engine copy differs
D=$(fresh t2)
echo "local line" >> "$D/.claude/rules/pr-acceptance.md"
run --root "$D"
if [ "$rc" -eq 0 ] && has '.claude/rules/pr-acceptance.md' && has '[read-by-engine]' && has 'differs from the current template' && has 'diff .claude/rules/pr-acceptance.md' && ! has 'stale' && [ "$(last | cut -c1-26)" = "[template-drift] status=wa" ]; then ok "T2 differing engine-read copy warns with the diff command"; else bad "T2 rc=$rc $(cat "$TMP/out")"; fi

# T3 provision-worktree.sh absent
D=$(fresh t3)
rm "$D/scripts/provision-worktree.sh"
run --root "$D"
if [ "$rc" -eq 0 ] && has 'scripts/provision-worktree.sh' && has '/lgtmgate:init' && [ "$(last)" = "[template-drift] status=warn read=1 optional=3 differs=0 absent=1" ]; then ok "T3 absent engine-read copy names the install step"; else bad "T3 rc=$rc $(cat "$TMP/out")"; fi

# T4 legacy name alone
D=$(fresh t4)
mv "$D/scripts/provision-worktree.sh" "$D/scripts/provision_worktree.sh"
run --root "$D"
if [ "$rc" -eq 0 ] && has '[legacy-name]' && has 'git mv scripts/provision_worktree.sh' && [ "$(last | cut -c1-26)" = "[template-drift] status=wa" ]; then ok "T4 legacy name is flagged with git mv"; else bad "T4 rc=$rc $(cat "$TMP/out")"; fi

# T5 unreadable root
run --root "$TMP/does-not-exist"
if [ "$rc" -eq 0 ] && [ "$(grep -c '^warn:' "$TMP/out")" = 1 ] && [ "$(last | cut -c1-26)" = "[template-drift] status=wa" ]; then ok "T5 unreadable root is one warn line"; else bad "T5 rc=$rc $(cat "$TMP/out")"; fi

# T6 differing optional copy is info only
D=$(fresh t6)
echo "local line" >> "$D/.claude/scripts/blocked-by-check.sh"
run --root "$D"
if [ "$rc" -eq 0 ] && has 'info: .claude/scripts/blocked-by-check.sh [optional] differs' && ! has 'warn:' && [ "$(last)" = "[template-drift] status=ok read=2 optional=3 differs=1 absent=0" ]; then ok "T6 differing optional copy stays info"; else bad "T6 rc=$rc $(cat "$TMP/out")"; fi

# T7 nothing is written
D=$(fresh t7)
echo "local line" >> "$D/.claude/rules/pr-acceptance.md"
git -C "$D" init -q
BEFORE_STATUS=$(git -C "$D" status --porcelain)
BEFORE_LIST=$(find "$D" -not -path "$D/.git/*" | sort)
run --root "$D"
AFTER_STATUS=$(git -C "$D" status --porcelain)
AFTER_LIST=$(find "$D" -not -path "$D/.git/*" | sort)
if [ "$rc" -eq 0 ] && [ "$BEFORE_STATUS" = "$AFTER_STATUS" ] && [ "$BEFORE_LIST" = "$AFTER_LIST" ]; then ok "T7 the check writes nothing"; else bad "T7 rc=$rc"; fi

# T8 missing --root
run
if [ "$rc" -eq 0 ] && [ "$(grep -c '^warn:' "$TMP/out")" = 1 ] && [ "$(last | cut -c1-26)" = "[template-drift] status=wa" ]; then ok "T8 missing --root is one warn line"; else bad "T8 rc=$rc $(cat "$TMP/out")"; fi

RESULT=ok; [ "$FAIL" -eq 0 ] || RESULT=fail
echo "[test-template-drift] status=${RESULT} passed=${PASS} failed=${FAIL}"
[ "$FAIL" -eq 0 ]
