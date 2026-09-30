#!/bin/bash
# Fires on SubagentStop. WARNING ONLY — never deletes the worktree.
# Only the Lead may delete a worktree, after explicit user confirmation or LGTM
# (sanctioned path: scripts/cleanup-worktree.sh <path>, merged + clean worktrees only).
# Reason: an interrupted session may have uncommitted work that must not be lost.
#
# The worktree root is DERIVED from config (LGTMGATE_WORKTREE_ROOT env >
# .claude/pipeline.config.local.json > .claude/pipeline.config.json, absolute only,
# fallback parent of a linked worktree) via hooks/lib-worktree-root.sh — it is not read
# from a caller-provided variable. Fail-safe: always exit 0.

# shellcheck source=hooks/lib-worktree-root.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-worktree-root.sh" 2>/dev/null || exit 0

CURRENT_TREE=$(git rev-parse --show-toplevel 2>/dev/null)
MAIN_TREE=$(git worktree list 2>/dev/null | head -1 | awk '{print $1}')
WORKTREES_ROOT="$(resolve_worktree_root)"

if [ -z "$WORKTREES_ROOT" ] || [ -z "$CURRENT_TREE" ] || [ "$CURRENT_TREE" = "$MAIN_TREE" ]; then
  exit 0
fi

if [[ "$CURRENT_TREE" == "$WORKTREES_ROOT"/* ]]; then
  echo "WARNING: subagent stopped inside worktree $CURRENT_TREE"
  echo "Last commit: $(git log --oneline -1 2>/dev/null)"
  echo "The Lead must clean up this worktree explicitly (after LGTM or user confirms abandon)."
fi

exit 0
