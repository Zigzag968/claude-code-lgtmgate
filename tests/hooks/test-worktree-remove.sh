#!/usr/bin/env bash
# Regression test for hooks/worktree-remove.sh. The input is the observed WorktreeRemove payload
# (fixtures/hooks/worktree-remove--observed.raw) with only .worktree_path and .cwd overridden. The hook is copied
# into a temp plugin dir next to a STUB scripts/cleanup-worktree.sh that records argv and cwd. No network. Needs jq.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK_SRC="$ROOT_DIR/hooks/worktree-remove.sh"
FIXTURE="$ROOT_DIR/fixtures/hooks/worktree-remove--observed.raw"

command -v jq >/dev/null 2>&1 || { echo "FAIL - jq is required"; echo "passed=0 failed=1"; exit 1; }

TMP_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
WORK="$(mktemp -d "$TMP_BASE/worktree-remove-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

PLUGIN="$WORK/plugin"
mkdir -p "$PLUGIN/hooks" "$PLUGIN/scripts"
cp "$HOOK_SRC" "$PLUGIN/hooks/worktree-remove.sh"
LOG="$WORK/stub.log"
cat >"$PLUGIN/scripts/cleanup-worktree.sh" <<'STUB'
#!/usr/bin/env bash
printf 'argc=%s argv1=%s cwd=%s\n' "$#" "$1" "$(pwd -P)" >>"$STUB_LOG"
exit "${STUB_EXIT:-0}"
STUB
export STUB_LOG="$LOG"

MAIN="$WORK/main"
WT="$WORK/trees/issue-5"
mkdir -p "$MAIN" "$WORK/trees"
git init -q -b main "$MAIN"
git -C "$MAIN" commit -q --allow-empty -m init
git -C "$MAIN" worktree add -q -b feat/issue-5 "$WT" main

pass=0
fail=0
check() {
  if [ "$2" -eq 1 ]; then echo "PASS - $1"; pass=$((pass + 1))
  else echo "FAIL - $1"; fail=$((fail + 1)); fi
}

# replay <exit of the stub> -> RC, with the observed payload and cwd = the worktree (as observed)
replay() {
  local payload
  payload="$(jq -c --arg p "$WT" '.worktree_path = $p | .cwd = $p' "$FIXTURE")"
  : >"$LOG"
  (cd "$WT" && printf '%s' "$payload" | STUB_EXIT="$1" bash "$PLUGIN/hooks/worktree-remove.sh" >"$WORK/out" 2>"$WORK/err")
  RC=$?
}

check "fixture is a WorktreeRemove event with a worktree_path and no name" \
  "$([ "$(jq -r '.hook_event_name' "$FIXTURE")" = "WorktreeRemove" ] && [ "$(jq -r 'has("name")' "$FIXTURE")" = "false" ] && [ "$(jq -r '.worktree_path // empty' "$FIXTURE")" != "" ] && echo 1 || echo 0)"

replay 0
check "cleanup accepts: hook exits 0" "$([ "$RC" -eq 0 ] && echo 1 || echo 0)"
check "stub called once with the worktree path" \
  "$([ "$(wc -l <"$LOG" | tr -d ' ')" = "1" ] && grep -q "^argc=1 argv1=$WT " "$LOG" && echo 1 || echo 0)"
check "stub runs from the main tree, not from the worktree" \
  "$(grep -q "cwd=$(cd "$MAIN" && pwd -P)\$" "$LOG" && echo 1 || echo 0)"
check "the hook removed nothing itself: worktree still on disk" "$([ -d "$WT" ] && echo 1 || echo 0)"

replay 1
check "cleanup refuses: hook exits 1 (never turned into 0)" "$([ "$RC" -eq 1 ] && echo 1 || echo 0)"
check "the worktree stays on disk after a refusal" "$([ -d "$WT" ] && echo 1 || echo 0)"

# payload without worktree_path
: >"$LOG"
jq -c 'del(.worktree_path)' "$FIXTURE" | (cd "$WT" && bash "$PLUGIN/hooks/worktree-remove.sh" >"$WORK/out" 2>"$WORK/err")
RC=$?
check "payload without worktree_path: exit 1, message names docs/consumer-reference.md, stub not called" \
  "$([ "$RC" -eq 1 ] && grep -q 'docs/consumer-reference.md' "$WORK/err" && [ ! -s "$LOG" ] && echo 1 || echo 0)"

# path already gone
: >"$LOG"
jq -c --arg p "$WORK/trees/gone" '.worktree_path = $p' "$FIXTURE" | (cd "$WORK" && STUB_EXIT=1 bash "$PLUGIN/hooks/worktree-remove.sh" >/dev/null 2>&1)
RC=$?
check "path no longer a directory: exit 0, stub not called" "$([ "$RC" -eq 0 ] && [ ! -s "$LOG" ] && echo 1 || echo 0)"

# the hook file removes nothing itself
check "hook file holds no worktree remove, rm or branch -d" \
  "$(grep -qE 'worktree remove|rm -|branch -d' "$HOOK_SRC" && echo 0 || echo 1)"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
