#!/usr/bin/env bash
# cleanup-worktree.sh — sanctioned removal of the pipeline worktrees that are done (merged, closed unmerged, or empty).
#
# Usage: cleanup-worktree.sh <worktree-path>
#        cleanup-worktree.sh --class <merged|closed-unmerged|no-pr-empty|all> [-C <dir>] [--dry-run]
#
# This is the only sanctioned way to remove a worktree: hooks/deny-destructive-git.sh denies the raw
# `git worktree remove|prune` and a bare recursive rm of a worktree (issue #129 — a concurrent run can be using it).
# For one path the script refuses (exit 1, named reason on stderr) unless ALL of these hold, checked cheapest first:
#   1. the path argument is present and is an existing directory
#   2. the worktree root is resolvable (hooks/lib-worktree-root.sh) and the path is under it
#   3. the path is a registered worktree and is not the main tree
#   4. the caller's cwd is neither the path nor inside it
#   5. its class (scripts/lib/worktree-state.sh, #168) is merged, closed-unmerged or no-pr-empty. Never removed: detached,
#      in-flight (a run in flight), dirty (uncommitted or untracked files), open-pr, unknown (PR lookup failed), ahead
#      (commits ahead of the base and no PR)
# Then: git worktree remove <path> (never --force) + git worktree prune; prints REMOVED <path>. The branch is then deleted
# with git branch -d (never -D) in the main tree when the class is merged or the branch has no commit ahead of the base;
# a refusal prints BRANCH-KEPT <branch> (<reason>), it is not an error. A closed-unmerged branch with commits is never touched.
#
# --class: every worktree of that class under the root of <dir>'s repository (default: the current directory) goes through
# the single-path run above, so every guard re-runs per path; `all` = the three removable classes. --dry-run prints
# WOULD-REMOVE <path> and removes nothing. The last line is `REMOVED n, REFUSED m`.
#
# Exit codes: 0 removed (--class: no candidate refused), 1 refused, 2 usage error.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/worktree-state.sh
. "$SCRIPT_DIR/lib/worktree-state.sh"

refuse() { printf 'cleanup-worktree: REFUSED - %s\n' "$1" >&2; exit 1; }
usage() {
  echo "usage: cleanup-worktree.sh <worktree-path> | --class <merged|closed-unmerged|no-pr-empty|all> [-C <dir>] [--dry-run]" >&2
  exit 2
}

CLASS=""; DIR=""; DRY=0; have_target=0; target_arg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --class) [ $# -ge 2 ] || usage; CLASS="$2"; shift 2 ;;
    -C) [ $# -ge 2 ] || usage; DIR="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -?*) usage ;;
    *) [ "$have_target" -eq 0 ] || usage; have_target=1; target_arg="$1"; shift ;;
  esac
done

if [ -n "$CLASS" ]; then
  case "$CLASS" in merged|closed-unmerged|no-pr-empty|all) ;; *) usage ;; esac
  [ "$have_target" -eq 0 ] || usage
  dir="${DIR:-$PWD}"
  [ -d "$dir" ] || { echo "cleanup-worktree: not a directory: $dir" >&2; exit 2; }
  main="$(wt_main_tree "$dir")"
  [ -n "$main" ] || { echo "cleanup-worktree: not inside a git repository: $dir" >&2; exit 2; }
  removed=0; refused=0
  while IFS="$(printf '\t')" read -r path branch; do
    [ -n "$path" ] || continue
    wt_classify "$main" "$path" "$branch"
    match=0
    case "$CLASS:$WT_CLASS" in
      all:merged|all:closed-unmerged|all:no-pr-empty) match=1 ;;
      "$CLASS:$CLASS") match=1 ;;
    esac
    [ "$match" -eq 1 ] || continue
    if [ "$DRY" -eq 1 ]; then printf 'WOULD-REMOVE %s\n' "$path"; continue; fi
    if out="$(bash "$0" "$path" 2>&1)"; then
      removed=$((removed + 1)); printf '%s\n' "$out"
    else
      refused=$((refused + 1)); printf '%s\n' "$out" >&2
    fi
  done < <(wt_each "$dir")
  if [ "$DRY" -eq 0 ]; then printf 'REMOVED %s, REFUSED %s\n' "$removed" "$refused"; fi
  [ "$refused" -eq 0 ] || exit 1
  exit 0
fi

[ "$have_target" -eq 1 ] && [ -z "$DIR" ] && [ "$DRY" -eq 0 ] || usage
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

# Class (local checks first, then one REST call for the PR state).
wt_classify "$main_phys" "$target" "$branch"
case "$WT_CLASS" in
  merged|closed-unmerged|no-pr-empty) ;;
  detached) refuse "class detached: worktree has no branch (detached HEAD) - cannot verify a PR" ;;
  in-flight) refuse "class in-flight: a pipeline run is in flight on branch $branch" ;;
  dirty) refuse "class dirty: worktree has uncommitted or untracked changes" ;;
  open-pr) refuse "class open-pr: the PR of branch $branch is still open" ;;
  ahead) refuse "class ahead: branch $branch has $WT_AHEAD commit(s) ahead of the base and no PR" ;;
  *) refuse "class $WT_CLASS: the PR state of branch $branch could not be read" ;;
esac

git -C "$main_phys" worktree remove "$target" || refuse "git worktree remove failed for $target"
git -C "$main_phys" worktree prune
printf 'REMOVED %s\n' "$target"

# Branch rule: git branch -d only (never -D), only for a merged branch or one with no commit of its own.
if [ "$WT_CLASS" = merged ] || [ "$WT_AHEAD" = 0 ]; then
  if err="$(git -C "$main_phys" branch -d "$branch" 2>&1)"; then
    printf 'BRANCH-DELETED %s\n' "$branch"
  else
    printf 'BRANCH-KEPT %s (%s)\n' "$branch" "$(printf '%s' "$err" | head -n 1)"
  fi
else
  printf 'BRANCH-KEPT %s (commits ahead of the base, PR closed unmerged)\n' "$branch"
fi
exit 0
