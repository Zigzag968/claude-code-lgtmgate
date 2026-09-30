#!/usr/bin/env bash
# lib-worktree-root.sh — sourced helper (never executed directly, never exits the caller).
#
# resolve_worktree_root: prints the worktree root, or nothing when none can be derived.
# Mirrors workflows/deliver-pipeline.js:resolveWorktreeRoot. Precedence:
#   1. env LGTMGATE_WORKTREE_ROOT
#   2. .claude/pipeline.config.local.json  .worktreeRoot
#   3. .claude/pipeline.config.json        .worktreeRoot
# A winning value counts only if ABSOLUTE (a relative value is ignored, like the JS
# resolver); trailing slashes are stripped. Fallback: parent dir of the current tree,
# used only when the current tree is a linked worktree (not the main tree).
# jq missing -> config layers are skipped (env + fallback still work).

_lwr_strip() {
  local p="$1"
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  printf '%s' "$p"
}

_lwr_read_key() {
  # $1 = json file ; prints .worktreeRoot or nothing
  [ -f "$1" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r '.worktreeRoot // empty' "$1" 2>/dev/null || true
}

resolve_worktree_root() {
  local top main cand dir v
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  main="$(git worktree list 2>/dev/null | head -1 | awk '{print $1}')"

  cand="${LGTMGATE_WORKTREE_ROOT:-}"
  cand="$(printf '%s' "$cand" | awk '{$1=$1};1')"
  if [ -z "$cand" ]; then
    for name in pipeline.config.local.json pipeline.config.json; do
      for dir in "$top" "$main"; do
        [ -n "$dir" ] || continue
        v="$(_lwr_read_key "$dir/.claude/$name")"
        v="$(printf '%s' "$v" | awk '{$1=$1};1')"
        if [ -n "$v" ]; then cand="$v"; break 2; fi
      done
    done
  fi

  case "$cand" in
    /*) _lwr_strip "$cand"; return 0 ;;
  esac

  if [ -n "$top" ] && [ -n "$main" ] && [ "$top" != "$main" ]; then
    dir="${top%/*}"
    printf '%s' "${dir:-/}"
  fi
  return 0
}
