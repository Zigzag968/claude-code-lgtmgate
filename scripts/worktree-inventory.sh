#!/usr/bin/env bash
# worktree-inventory.sh — read-only inventory of the pipeline worktrees of a repository (#168).
#
# Usage: worktree-inventory.sh [-C <dir>]
#
# <dir> (default: the current directory) is any checkout of the repository to inspect; the worktree root is resolved from it
# (hooks/lib-worktree-root.sh) and only linked worktrees under that root are listed. Prints a header, then one tab-separated
# line per worktree: CLASS ISSUE BRANCH PR TREE AHEAD RUN PATH, then a summary line. The class comes from
# scripts/lib/worktree-state.sh (the same one scripts/cleanup-worktree.sh removes by); nothing is written or removed.
# PR state is one REST call per worktree.
#
# Exit codes: 0 listed, 2 usage error.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/worktree-state.sh
. "$SCRIPT_DIR/lib/worktree-state.sh"

usage() { echo "usage: worktree-inventory.sh [-C <dir>]" >&2; exit 2; }

DIR="$PWD"
while [ $# -gt 0 ]; do
  case "$1" in
    -C) [ $# -ge 2 ] || usage; DIR="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -d "$DIR" ] || { echo "worktree-inventory: not a directory: $DIR" >&2; exit 2; }

main="$(wt_main_tree "$DIR")"
if [ -z "$main" ]; then echo "worktree-inventory: not inside a git repository: $DIR" >&2; exit 2; fi
if [ -z "$(wt_root "$DIR")" ]; then
  echo "worktree-inventory: worktree root cannot be resolved (set LGTMGATE_WORKTREE_ROOT or worktreeRoot in pipeline.config.json)" >&2
fi

printf 'CLASS\tISSUE\tBRANCH\tPR\tTREE\tAHEAD\tRUN\tPATH\n'
total=0; n_merged=0; n_closed=0; n_empty=0
while IFS="$(printf '\t')" read -r path branch; do
  [ -n "$path" ] || continue
  wt_classify "$main" "$path" "$branch"
  total=$((total + 1))
  case "$WT_CLASS" in
    merged) n_merged=$((n_merged + 1)) ;;
    closed-unmerged) n_closed=$((n_closed + 1)) ;;
    no-pr-empty) n_empty=$((n_empty + 1)) ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$WT_CLASS" "${WT_ISSUE:--}" "${branch:--}" "$WT_PR" "$WT_TREE" "$WT_AHEAD" "$WT_RUN" "$path"
done < <(wt_each "$DIR")

removable=$((n_merged + n_closed + n_empty))
printf '%s worktrees: %s removable (merged %s, closed-unmerged %s, no-pr-empty %s), %s kept\n' \
  "$total" "$removable" "$n_merged" "$n_closed" "$n_empty" "$((total - removable))"
exit 0
