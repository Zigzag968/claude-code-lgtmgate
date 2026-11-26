#!/usr/bin/env bash
# worktree-create.sh — WorktreeCreate hook: creates the worktree and branch of `claude -w issue-<N>`
# (and of a subagent with worktree isolation, `agent-<id>`), the same layout the engine creates today
# (skills/deliver/SKILL.md section 3). Reads the event JSON on stdin (.name, .cwd).
#
#   issue-<N>   path <worktreeRoot>/issue-<N>, branch <branchPrefix>issue-<N>
#   agent-<id>  path <main tree>/.claude/worktrees/agent-<id>, branch <branchPrefix>agent-<id>
#   anything else is refused: no other name ever reaches a path or a ref.
#
# No lgtmgate config (no .claude/pipeline.config.json or .local.json, see in_pipeline_session): the hook
# reproduces Claude Code's default layout instead of refusing: path <main tree>/.claude/worktrees/<name>,
# branch worktree-<name>, from origin/HEAD else HEAD, no fetch, no config read. <name> must be a plain name.
#
# Config (hooks/lib-worktree-root.sh): worktreeRoot, branchPrefix (unset: features/), baseBranch (unset: refused;
# required only when a config exists).
# stdout carries the path of the worktree and nothing else; every git output goes to stderr.
# Exit 0 = path printed, non-zero = creation refused (one line on stderr).
set -uo pipefail

# shellcheck source=hooks/lib-worktree-root.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-worktree-root.sh" || exit 1

refuse() {
  echo "BLOCKED by worktree gate: $1. See docs/consumer-reference.md, section Hook messages, worktree-create.sh: BLOCKED by worktree gate." >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || refuse "jq is not installed"
payload="$(cat)"
name="$(printf '%s' "$payload" | jq -r '.name // empty' 2>/dev/null)"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$name" ] || refuse "the event carries no name"
[ -n "$cwd" ] || refuse "the event carries no cwd"
cd "$cwd" 2>/dev/null || refuse "cwd is not a directory: $cwd"

main_tree="$(git worktree list 2>/dev/null | head -1 | awk '{print $1}')"
[ -n "$main_tree" ] || refuse "cwd is not inside a git repository: $cwd"

if in_pipeline_session; then
  base="$(resolve_config_value baseBranch)"
  [ -n "$base" ] || refuse "baseBranch is not set in .claude/pipeline.config.json"
  prefix="$(resolve_config_value branchPrefix)"
  [ -n "$prefix" ] || prefix="features/"

  if [[ "$name" =~ ^issue-[0-9]+$ ]]; then
    root="$(resolve_worktree_root)"
    [ -n "$root" ] || refuse "the worktree root cannot be resolved (set worktreeRoot in .claude/pipeline.config.json)"
    path="$root/$name"
  elif [[ "$name" =~ ^agent-[A-Za-z0-9]+$ ]]; then
    path="$main_tree/.claude/worktrees/$name"
  else
    refuse "name '$name' is neither issue-<N> nor agent-<id>"
  fi
  branch="${prefix}${name}"
  ref="origin/$base"
  do_fetch=1
else
  # No lgtmgate config: reproduce Claude Code's default layout (a WorktreeCreate hook replaces it and
  # cannot decline). No config read, no fetch.
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$name" != *..* ]] \
    || refuse "name '$name' is not a plain worktree name (letters, digits, '.', '_', '-'; no slash, no '..')"
  path="$main_tree/.claude/worktrees/$name"
  branch="worktree-$name"
  ref="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  [ -n "$ref" ] || ref="HEAD"
  do_fetch=0
fi

# Idempotent: a path that is already a registered worktree is returned as is. git lists real paths, so the
# check compares the resolved path (a root reached through a symlink); the printed path stays as built.
real_path="$(cd "$path" 2>/dev/null && pwd -P)"
[ -n "$real_path" ] || real_path="$path"
if git worktree list --porcelain 2>/dev/null | grep -Fxq "worktree $real_path"; then
  printf '%s\n' "$path"
  exit 0
fi

# Best effort: a fetch failure never aborts (offline work, no remote).
if [ "$do_fetch" -eq 1 ]; then
  git fetch origin "$base" >&2 2>&1 || true
fi

if git show-ref --verify --quiet "refs/heads/$branch"; then
  git worktree add "$path" "$branch" >&2 2>&1 || refuse "git worktree add failed for branch $branch"
else
  git worktree add --no-track -b "$branch" "$path" "$ref" >&2 2>&1 \
    || refuse "git worktree add failed for $ref (fetch the base branch or fix baseBranch)"
fi

printf '%s\n' "$path"
exit 0
