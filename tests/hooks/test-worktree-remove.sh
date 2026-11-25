#!/usr/bin/env bash
# Regression test for hooks/worktree-remove.sh. The input is the observed WorktreeRemove payload
# (fixtures/hooks/worktree-remove--observed.raw) with only .worktree_path and .cwd overridden. The hook is copied
# into a temp plugin dir next to a STUB scripts/cleanup-worktree.sh that records argv and cwd (handoff section), then
# into a second plugin dir with the REAL cleanup-worktree.sh and a PATH-local gh stub (agent worktrees, #726).
# No network. Needs jq.
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

# --- real cleanup-worktree.sh (no stub): sub-agent worktrees under <main>/.claude/worktrees (#726) ---------
REAL_PLUGIN="$WORK/real-plugin"
mkdir -p "$REAL_PLUGIN/hooks" "$REAL_PLUGIN/scripts/lib"
cp "$HOOK_SRC" "$REAL_PLUGIN/hooks/worktree-remove.sh"
cp "$ROOT_DIR/hooks/lib-worktree-root.sh" "$REAL_PLUGIN/hooks/lib-worktree-root.sh"
cp "$ROOT_DIR/scripts/cleanup-worktree.sh" "$REAL_PLUGIN/scripts/cleanup-worktree.sh"
cp "$ROOT_DIR/scripts/lib/worktree-state.sh" "$REAL_PLUGIN/scripts/lib/worktree-state.sh"
BIN="$WORK/bin"
mkdir -p "$BIN"
cat >"$BIN/gh" <<'GHSTUB'
#!/usr/bin/env bash
[ "$1" = "api" ] || { echo "stub gh: unexpected: $*" >&2; exit 99; }
echo NONE
GHSTUB
chmod +x "$BIN/gh"

AGENTS="$MAIN/.claude/worktrees"
mkdir -p "$AGENTS"

# real_replay <worktree path> -> RC, observed payload, cwd = the worktree, real scripts, stub gh first on PATH
real_replay() {
  local payload
  payload="$(jq -c --arg p "$1" '.worktree_path = $p | .cwd = $p' "$FIXTURE")"
  (cd "$1" && printf '%s' "$payload" | PATH="$BIN:$PATH" bash "$REAL_PLUGIN/hooks/worktree-remove.sh" >"$WORK/out" 2>"$WORK/err")
  RC=$?
}
registered() { git -C "$MAIN" worktree list --porcelain | grep -Fq "worktree $(cd "$1" 2>/dev/null && pwd -P || echo "$1")"; }

git -C "$MAIN" worktree add -q -b features/agent-abc "$AGENTS/agent-abc" main
A1="$(cd "$AGENTS/agent-abc" && pwd -P)"
real_replay "$A1"
check "real cleanup-worktree.sh: agent worktree with no commit ahead is removed (exit 0, dir gone)" \
  "$([ "$RC" -eq 0 ] && [ ! -d "$A1" ] && echo 1 || echo 0)"
check "real cleanup-worktree.sh: the removed agent worktree is no longer registered and its branch is deleted" \
  "$(git -C "$MAIN" worktree list --porcelain | grep -Fq "agent-abc" && echo 0 || { git -C "$MAIN" show-ref --verify --quiet refs/heads/features/agent-abc && echo 0 || echo 1; })"

git -C "$MAIN" worktree add -q -b features/agent-def "$AGENTS/agent-def" main
A2="$(cd "$AGENTS/agent-def" && pwd -P)"
git -C "$A2" commit -q --allow-empty -m work
real_replay "$A2"
check "real cleanup-worktree.sh: agent worktree with a commit ahead is refused (exit 1), dir and branch stay" \
  "$([ "$RC" -eq 1 ] && [ -d "$A2" ] && git -C "$MAIN" show-ref --verify --quiet refs/heads/features/agent-def && echo 1 || echo 0)"

git -C "$MAIN" worktree add -q -b features/foo "$AGENTS/foo" main
A3="$(cd "$AGENTS/foo" && pwd -P)"
# (a configured worktree root elsewhere: without one the parent-dir fallback of the script would own .claude/worktrees)
LGTMGATE_WORKTREE_ROOT="$WORK/trees" real_replay "$A3"
check "real cleanup-worktree.sh: a non-agent name under .claude/worktrees is refused (exit 1), dir stays" \
  "$([ "$RC" -eq 1 ] && [ -d "$A3" ] && echo 1 || echo 0)"

# the hook file removes nothing itself
check "hook file holds no worktree remove, rm or branch -d" \
  "$(grep -qE 'worktree remove|rm -|branch -d' "$HOOK_SRC" && echo 0 || echo 1)"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
