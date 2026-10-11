#!/usr/bin/env bash
# Regression test of step 3 of skills/deliver/SKILL.md (issue #464): the documented worktree creation command
# must write no upstream configuration (`--no-track`), and the half-done recovery must work. The commands are
# extracted from the skill by their quoted text (never a line number), then run for real in a scratch repo.
# SKILL_FILE points the test at another copy of the skill (negative runs); the harness always comes from the repo.
# bash 3.2 compatible. Trailer: [test-deliver-worktree-step] passed=<n> failed=<n>
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ROOT="$REPO_ROOT"
# shellcheck source=lib/harness.sh
. "$REPO_ROOT/tests/scripts/lib/harness.sh"
SKILL="${SKILL_FILE:-$REPO_ROOT/skills/deliver/SKILL.md}"
[ -f "$SKILL" ] || { bad "skill file missing: $SKILL"; echo "[test-deliver-worktree-step] passed=$PASS failed=$FAIL"; exit 1; }

# fill <command text> <slug> <worktree path>: replace the skill placeholders by scratch values
fill() { printf '%s\n' "$1" | sed -e "s#<WORKTREE>#$3#g" -e "s#<branchPrefix>#feat/#g" -e "s#<slug>#$2#g" -e "s#<baseBranch>#main#g"; }

CREATE="$(grep -m1 -E '^ *git worktree add .*origin/<baseBranch>' "$SKILL" | sed -E 's/^ +//')"
RECOVER="$(sed -n 's/.*`\(git worktree add "<WORKTREE>" <branchPrefix><slug>\)`.*/\1/p' "$SKILL" | head -n 1)"

case "$CREATE" in
  *--no-track*) ok "creation command carries --no-track" ;;
  *) bad "creation command has no --no-track: '$CREATE'" ;;
esac
[ -n "$RECOVER" ] && ok "half-done recovery command is documented" || bad "half-done recovery command is not documented"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/wt464.XXXXXX")"
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q --bare "$SCRATCH/origin.git"
git clone -q "$SCRATCH/origin.git" "$SCRATCH/repo" 2>/dev/null
git -C "$SCRATCH/repo" checkout -q -b main
git -C "$SCRATCH/repo" commit -q --allow-empty -m init
git -C "$SCRATCH/repo" push -q origin main
git -C "$SCRATCH/repo" fetch -q origin main

# (c) the documented creation command, run for real, leaves no tracking config
if [ -n "$CREATE" ]; then
  CMD="$(fill "$CREATE" issue-1 "$SCRATCH/wt1")"
  if (cd "$SCRATCH/repo" && eval "$CMD") >/dev/null 2>&1 && [ -d "$SCRATCH/wt1" ]; then ok "creation command creates the worktree"
  else bad "creation command failed: $CMD"; fi
  if [ -z "$(git -C "$SCRATCH/repo" config --get branch.feat/issue-1.remote)" ]; then ok "no branch.feat/issue-1.remote written"
  else bad "branch.feat/issue-1.remote was written to the shared config"; fi
fi

# (d) the recovery command works on a branch that exists without a worktree
git -C "$SCRATCH/repo" branch --no-track feat/issue-2 origin/main
if [ -n "$RECOVER" ]; then
  CMD="$(fill "$RECOVER" issue-2 "$SCRATCH/wt2")"
  if (cd "$SCRATCH/repo" && eval "$CMD") >/dev/null 2>&1 && [ -d "$SCRATCH/wt2" ]; then ok "recovery command attaches the worktree"
  else bad "recovery command failed: $CMD"; fi
fi

echo "[test-deliver-worktree-step] passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
