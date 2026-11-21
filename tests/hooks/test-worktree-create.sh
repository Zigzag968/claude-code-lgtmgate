#!/usr/bin/env bash
# Regression test for hooks/worktree-create.sh. Every replay input is the captured WorktreeCreate payload
# (fixtures/hooks/worktree-create--captured.raw) with only .name and .cwd overridden. Temp bare origin and
# clone under $TMPDIR, no network. Needs jq.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$ROOT_DIR/hooks/worktree-create.sh"
FIXTURE="$ROOT_DIR/fixtures/hooks/worktree-create--captured.raw"

command -v jq >/dev/null 2>&1 || { echo "FAIL - jq is required"; echo "passed=0 failed=1"; exit 1; }

TMP_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
WORK="$(mktemp -d "$TMP_BASE/worktree-create-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset LGTMGATE_WORKTREE_ROOT

ORIGIN="$WORK/origin.git"
REPO="$WORK/repo"
WTROOT="$WORK/trees"
PREFIX="feat/"
BASE="develop"
mkdir -p "$WTROOT"
git init -q --bare -b "$BASE" "$ORIGIN"
git clone -q "$ORIGIN" "$REPO" 2>/dev/null
git -C "$REPO" checkout -q -b "$BASE"
git -C "$REPO" commit -q --allow-empty -m init
git -C "$REPO" push -q origin "$BASE"
# a second commit on origin only, so HEAD of the new tree must follow origin/<base> after the hook's fetch
git -C "$REPO" commit -q --allow-empty -m second
git -C "$REPO" push -q origin "$BASE"
git -C "$REPO" reset -q --hard HEAD~1
mkdir -p "$REPO/.claude"
write_config() {
  printf '%s\n' "$1" >"$REPO/.claude/pipeline.config.json"
}
write_config "{\"baseBranch\":\"$BASE\",\"branchPrefix\":\"$PREFIX\",\"worktreeRoot\":\"$WTROOT\"}"

pass=0
fail=0
check() {
  if [ "$2" -eq 1 ]; then echo "PASS - $1"; pass=$((pass + 1))
  else echo "FAIL - $1"; fail=$((fail + 1)); fi
}

# run_hook <name> -> RC, STDOUT, STDERR (the captured payload, .name and .cwd overridden)
run_hook() {
  local payload
  payload="$(jq -c --arg n "$1" --arg c "$REPO" '.name = $n | .cwd = $c' "$FIXTURE")"
  STDOUT="$(printf '%s' "$payload" | bash "$HOOK" 2>"$WORK/stderr")"
  RC=$?
  STDERR="$(cat "$WORK/stderr")"
}

# The fixture keeps the shape of the real event
check "fixture is a WorktreeCreate event with issue-9" \
  "$([ "$(jq -r '.hook_event_name + ":" + .name' "$FIXTURE")" = "WorktreeCreate:issue-9" ] && echo 1 || echo 0)"

# 1. issue-9: path, branch, HEAD, no upstream
run_hook issue-9
EXPECT_PATH="$WTROOT/issue-9"
check "issue-9: exit 0 and the last stdout line is <worktreeRoot>/issue-9" \
  "$([ "$RC" -eq 0 ] && [ "$(printf '%s\n' "$STDOUT" | tail -n 1)" = "$EXPECT_PATH" ] && echo 1 || echo 0)"
check "issue-9: stdout holds only the path" \
  "$([ "$(printf '%s\n' "$STDOUT" | wc -l | tr -d ' ')" = "1" ] && echo 1 || echo 0)"
check "issue-9: branch is <branchPrefix>issue-9" \
  "$([ "$(git -C "$EXPECT_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "${PREFIX}issue-9" ] && echo 1 || echo 0)"
check "issue-9: HEAD equals origin/<baseBranch> (the fetched tip)" \
  "$([ "$(git -C "$EXPECT_PATH" rev-parse HEAD 2>/dev/null)" = "$(git -C "$REPO" rev-parse "origin/$BASE")" ] && echo 1 || echo 0)"
check "issue-9: no upstream configured (--no-track)" \
  "$(git -C "$EXPECT_PATH" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1 && echo 0 || echo 1)"

# 2. idempotent
run_hook issue-9
check "issue-9 again: exit 0 and the same path" \
  "$([ "$RC" -eq 0 ] && [ "$STDOUT" = "$EXPECT_PATH" ] && echo 1 || echo 0)"

# 2b. idempotent with a worktreeRoot reached through a symlink (git lists the real path)
REAL="$WORK/real-root"
LINK="$WORK/link-root"
mkdir -p "$REAL"
ln -s "$REAL" "$LINK"
write_config "{\"baseBranch\":\"$BASE\",\"branchPrefix\":\"$PREFIX\",\"worktreeRoot\":\"$LINK\"}"
run_hook issue-15
RC1=$RC
run_hook issue-15
check "symlinked root: second run exits 0 and prints the same path" \
  "$([ "$RC1" -eq 0 ] && [ "$RC" -eq 0 ] && [ "$STDOUT" = "$LINK/issue-15" ] && echo 1 || echo 0)"
write_config "{\"baseBranch\":\"$BASE\",\"branchPrefix\":\"$PREFIX\",\"worktreeRoot\":\"$WTROOT\"}"

# 3. branch exists without a worktree (half-done state)
git -C "$REPO" branch "${PREFIX}issue-11" "origin/$BASE"
run_hook issue-11
check "issue-11 with an existing branch: worktree added on that branch" \
  "$([ "$RC" -eq 0 ] && [ "$(git -C "$WTROOT/issue-11" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "${PREFIX}issue-11" ] && echo 1 || echo 0)"

# 4. agent-abc
run_hook agent-abc
check "agent-abc: path under <repo>/.claude/worktrees/ and a registered worktree" \
  "$([ "$RC" -eq 0 ] && case "$STDOUT" in "$REPO"/.claude/worktrees/*) git -C "$REPO" worktree list --porcelain | grep -Fxq "worktree $STDOUT" && echo 1 || echo 0 ;; *) echo 0 ;; esac)"

# 5. refused names
run_hook foo
check "name foo: non-zero exit and a message naming docs/consumer-reference.md" \
  "$([ "$RC" -ne 0 ] && printf '%s' "$STDERR" | grep -q 'docs/consumer-reference.md' && [ -z "$STDOUT" ] && echo 1 || echo 0)"
run_hook 'issue-9/../x'
check "name issue-9/../x: non-zero exit and a message naming docs/consumer-reference.md" \
  "$([ "$RC" -ne 0 ] && printf '%s' "$STDERR" | grep -q 'docs/consumer-reference.md' && [ -z "$STDOUT" ] && echo 1 || echo 0)"
run_hook $'issue-9\nx'
check "name with a newline: refused" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
check "no worktree was created for a refused name" \
  "$([ ! -e "$WTROOT/x" ] && [ ! -e "$WORK/x" ] && echo 1 || echo 0)"

# 6. baseBranch unset
write_config "{\"branchPrefix\":\"$PREFIX\",\"worktreeRoot\":\"$WTROOT\"}"
run_hook issue-12
check "baseBranch unset: refused, no worktree" \
  "$([ "$RC" -ne 0 ] && printf '%s' "$STDERR" | grep -q 'baseBranch' && [ ! -e "$WTROOT/issue-12" ] && echo 1 || echo 0)"

# 7. branchPrefix unset falls back to features/
write_config "{\"baseBranch\":\"$BASE\",\"worktreeRoot\":\"$WTROOT\"}"
run_hook issue-13
check "branchPrefix unset: branch is features/issue-13" \
  "$([ "$RC" -eq 0 ] && [ "$(git -C "$WTROOT/issue-13" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "features/issue-13" ] && echo 1 || echo 0)"

# 8. no worktree root for issue-N
write_config "{\"baseBranch\":\"$BASE\",\"branchPrefix\":\"$PREFIX\"}"
run_hook issue-14
check "no worktree root resolvable for issue-14: refused" \
  "$([ "$RC" -ne 0 ] && printf '%s' "$STDERR" | grep -q 'worktree root' && echo 1 || echo 0)"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
