#!/usr/bin/env bash
# worktree-remove.sh — WorktreeRemove hook: hands the removal to scripts/cleanup-worktree.sh, the only
# sanctioned way to remove a worktree (it holds every guard). This file removes nothing itself.
# Reads the event JSON on stdin (.worktree_path). The observed event carries cwd = the worktree, which
# cleanup refuses, so the hook leaves it for the main tree first.
# Exit code = the one of cleanup-worktree.sh: 0 removed, 1 refused (the worktree stays on disk).
set -uo pipefail

refuse() {
  echo "BLOCKED by worktree gate: $1. See docs/consumer-reference.md, section Hook messages, worktree-remove.sh: BLOCKED by worktree gate." >&2
  exit 1
}

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v jq >/dev/null 2>&1 || refuse "jq is not installed"
wt="$(jq -r '.worktree_path // empty' 2>/dev/null)"
[ -n "$wt" ] || refuse "the event carries no worktree_path"
[ -d "$wt" ] || exit 0

main_tree="$(git -C "$wt" worktree list --porcelain 2>/dev/null | awk '/^worktree /{sub(/^worktree /,""); print; exit}')"
[ -n "$main_tree" ] || refuse "cannot find the main tree of $wt"
cd "$main_tree" 2>/dev/null || refuse "cannot enter the main tree $main_tree"

exec bash "$HOOK_DIR/../scripts/cleanup-worktree.sh" "$wt"
