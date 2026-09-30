#!/usr/bin/env bash
# cleanup-worktree.sh — sanctioned removal of a MERGED, clean pipeline worktree.
#
# Usage: cleanup-worktree.sh <worktree-path>
#
# This is the only sanctioned way to remove a worktree: hooks/deny-destructive-git.sh
# denies the raw `git worktree remove|prune` and a bare recursive rm of a worktree
# (issue #129 — a concurrent run can be using it). The script refuses (exit 1, named
# reason on stderr) unless ALL of these hold, checked cheapest first:
#   1. the path argument is present and is an existing directory
#   2. the worktree root is resolvable (hooks/lib-worktree-root.sh) and the path is under it
#   3. the path is a registered worktree and is not the main tree
#   4. the caller's cwd is neither the path nor inside it
#   5. the worktree is clean (git status --porcelain empty)
#   6. the PR of the worktree's branch is MERGED (gh pr view <branch> --json state)
# Then: git worktree remove <path> (never --force) + git worktree prune; prints REMOVED <path>.
#
# Exit codes: 0 removed, 1 refused, 2 usage error.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hooks/lib-worktree-root.sh
source "$SCRIPT_DIR/../hooks/lib-worktree-root.sh"

refuse() { printf 'cleanup-worktree: REFUSED - %s\n' "$1" >&2; exit 1; }

[ $# -eq 1 ] || { echo "usage: cleanup-worktree.sh <worktree-path>" >&2; exit 2; }
target_arg="$1"
[ -n "$target_arg" ] || refuse "empty path argument"
[ -d "$target_arg" ] || refuse "not an existing directory: $target_arg"
target="$(cd "$target_arg" && pwd -P)" || refuse "cannot resolve path: $target_arg"

# Root resolved from the target's own repo context (its config, or the parent fallback).
root="$(cd "$target" && resolve_worktree_root)"
[ -n "$root" ] || refuse "worktree root cannot be resolved (set LGTMGATE_WORKTREE_ROOT or worktreeRoot in pipeline.config.json)"
root_phys="$(cd "$root" 2>/dev/null && pwd -P || printf '%s' "$root")"
case "$target" in
  "$root_phys"/*) ;;
  *) refuse "$target is not under the worktree root $root_phys" ;;
esac

# Registered + not main. Always query from the target itself (any tree of the repo works).
porcelain="$(git -C "$target" worktree list --porcelain 2>/dev/null)" || refuse "not inside a git repository: $target"
main_tree="$(printf '%s\n' "$porcelain" | awk '/^worktree /{sub(/^worktree /,""); print; exit}')"
[ -n "$main_tree" ] || refuse "cannot determine the main tree"
main_phys="$(cd "$main_tree" 2>/dev/null && pwd -P || printf '%s' "$main_tree")"
[ "$target" != "$main_phys" ] || refuse "$target is the main tree"

branch=""
found=0
cur_match=0
while IFS= read -r line; do
  case "$line" in
    "worktree "*)
      cur="${line#worktree }"
      cur_phys="$(cd "$cur" 2>/dev/null && pwd -P || printf '%s' "$cur")"
      if [ "$cur_phys" = "$target" ]; then cur_match=1; found=1; else cur_match=0; fi
      ;;
    "branch "*)
      [ "$cur_match" -eq 1 ] && branch="${line#branch refs/heads/}"
      ;;
  esac
done <<EOF_PORCELAIN
$porcelain
EOF_PORCELAIN
[ "$found" -eq 1 ] || refuse "$target is not a registered worktree"

# Caller cwd must not be the target or inside it.
here="$(pwd -P)"
case "$here" in
  "$target"|"$target"/*) refuse "current directory is inside the worktree to remove ($here)" ;;
esac

# Clean tree.
status="$(git -C "$target" status --porcelain 2>/dev/null)" || refuse "cannot read git status of $target"
[ -z "$status" ] || refuse "worktree has uncommitted or untracked changes"

# Merged PR (gh only after the cheap local guards pass).
[ -n "$branch" ] || refuse "worktree has no branch (detached HEAD) - cannot verify a merged PR"
state="$(cd "$main_phys" && gh pr view "$branch" --json state --jq .state 2>/dev/null)" || state=""
[ "$state" = "MERGED" ] || refuse "PR of branch $branch is not MERGED (state: ${state:-unknown})"

git -C "$main_phys" worktree remove "$target" || refuse "git worktree remove failed for $target"
git -C "$main_phys" worktree prune
printf 'REMOVED %s\n' "$target"
exit 0
