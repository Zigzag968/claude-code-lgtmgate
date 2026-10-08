#!/usr/bin/env bash
# Regression test for hooks/SubagentStop-worktree-cleanup.sh — the worktree root is DERIVED
# (env LGTMGATE_WORKTREE_ROOT > .claude/pipeline.config.local.json > .claude/pipeline.config.json,
# absolute only, fallback = parent of a linked worktree). Temp repo under $TMPDIR, no network.
# Needs jq for the config-layer cases (the resolver skips them without it).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../hooks" && pwd)"
HOOK="$SCRIPT_DIR/SubagentStop-worktree-cleanup.sh"

TMP_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
WORK="$(mktemp -d "$TMP_BASE/subagentstop-wt-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset LGTMGATE_WORKTREE_ROOT

MAIN="$WORK/main"
ROOT="$WORK/root"
WT="$ROOT/issue-1"
OTHER_ROOT="$WORK/elsewhere"
mkdir -p "$MAIN" "$ROOT" "$OTHER_ROOT" "$MAIN/.claude"
git -C "$MAIN" init -q -b main
git -C "$MAIN" commit -q --allow-empty -m init
git -C "$MAIN" worktree add -q -b feat/issue-1 "$WT" main

pass_count=0
fail_count=0
total=0

check() {
  local name="$1" ok="$2"
  total=$((total + 1))
  if [ "$ok" -eq 1 ]; then echo "PASS - $name"; pass_count=$((pass_count + 1))
  else echo "FAIL - $name"; fail_count=$((fail_count + 1)); fi
}

# run_hook <cwd> -> sets RC and OUT
run_hook() { OUT="$(cd "$1" && bash "$HOOK" 2>&1)"; RC=$?; }
warns() { printf '%s' "$OUT" | grep -q '^WARNING: subagent stopped inside worktree'; }

# 1. env root set -> WARNING
LGTMGATE_WORKTREE_ROOT="$ROOT" run_hook "$WT"
check "env root: warns inside a worktree under the root" $([ "$RC" -eq 0 ] && warns && echo 1 || echo 0)

# 2. env root elsewhere -> silent
LGTMGATE_WORKTREE_ROOT="$OTHER_ROOT" run_hook "$WT"
check "env root elsewhere: silent" $([ "$RC" -eq 0 ] && ! warns && echo 1 || echo 0)

# 3. config root (absolute) -> WARNING; then local config beats it
printf '{"worktreeRoot":"%s"}\n' "$ROOT" >"$MAIN/.claude/pipeline.config.json"
run_hook "$WT"
check "config root (absolute): warns" $([ "$RC" -eq 0 ] && warns && echo 1 || echo 0)

printf '{"worktreeRoot":"%s"}\n' "$OTHER_ROOT" >"$MAIN/.claude/pipeline.config.local.json"
run_hook "$WT"
check "local config beats config: silent when local points elsewhere" $([ "$RC" -eq 0 ] && ! warns && echo 1 || echo 0)

# 4. env beats local config
LGTMGATE_WORKTREE_ROOT="$ROOT" run_hook "$WT"
check "env beats local config: warns" $([ "$RC" -eq 0 ] && warns && echo 1 || echo 0)

# 5. relative config value is ignored -> fallback to the parent of the tree -> WARNING
rm -f "$MAIN/.claude/pipeline.config.local.json"
printf '{"worktreeRoot":"../worktrees/x"}\n' >"$MAIN/.claude/pipeline.config.json"
run_hook "$WT"
check "relative config falls back to parent of the tree: warns" $([ "$RC" -eq 0 ] && warns && echo 1 || echo 0)

# 6. main tree -> silent, exit 0
LGTMGATE_WORKTREE_ROOT="$ROOT" run_hook "$MAIN"
check "main tree: silent, exit 0" $([ "$RC" -eq 0 ] && ! warns && echo 1 || echo 0)

# 7. outside any repo -> silent, exit 0
LGTMGATE_WORKTREE_ROOT="$ROOT" run_hook "$WORK"
check "not a git repo: silent, exit 0" $([ "$RC" -eq 0 ] && [ -z "$OUT" ] && echo 1 || echo 0)

# 8. never deletes
check "worktree still present after all runs" $([ -d "$WT" ] && echo 1 || echo 0)

echo "${pass_count}/${total} PASS"
[ "$fail_count" -eq 0 ] || exit 1
exit 0
