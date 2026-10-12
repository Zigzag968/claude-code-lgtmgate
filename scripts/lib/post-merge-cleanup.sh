#!/usr/bin/env bash
# post-merge-cleanup.sh — sourced by scripts/lead-merge.sh (#168), never executed directly.
#
# lm_post_merge_cleanup <0|1>: called once, after the merge was read back as merged. The merged worktree is removed only
# on request (--cleanup), through the sanctioned scripts/cleanup-worktree.sh run from the main checkout; without the flag
# one offer line names the command. A refusal or failure only prints its reason: the exit code of a merged PR never changes.
# Needs $SCRIPT_DIR (the directory of lead-merge.sh, which holds cleanup-worktree.sh).

lm_post_merge_cleanup() {
  local flag="${1:-0}" here main offer out
  here="$(cd "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null && pwd -P)" || here=""
  main="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{sub(/^worktree /,""); print; exit}')"
  main="$(cd "$main" 2>/dev/null && pwd -P)" || main=""
  if [ -z "$here" ] || [ -z "$main" ] || [ "$here" = "$main" ]; then
    echo "lead-merge: worktree cleanup skipped (not a linked worktree)"
    return 0
  fi
  offer="lead-merge: to remove this merged worktree, sync the main checkout, then run from it: bash $SCRIPT_DIR/cleanup-worktree.sh \"$here\""
  if [ "$flag" != 1 ]; then
    echo "$offer"
    return 0
  fi
  if out="$(cd "$main" && bash "$SCRIPT_DIR/cleanup-worktree.sh" "$here" 2>&1)"; then
    printf '%s\n' "$out" | sed 's/^/lead-merge: /'
  else
    printf '%s\n' "$out" | sed 's/^/lead-merge: worktree cleanup: /'
    echo "$offer"
  fi
  return 0
}
