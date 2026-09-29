#!/bin/bash
# Fires on SubagentStop. WARNING ONLY — never deletes the worktree.
# Only the Lead may delete a worktree, after explicit user confirmation or LGTM.
# Reason: an interrupted session may have uncommitted work that must not be lost.

CURRENT_TREE=$(git rev-parse --show-toplevel 2>/dev/null)
MAIN_TREE=$(git worktree list 2>/dev/null | head -1 | awk '{print $1}')

if [ -z "$WORKTREES_ROOT" ] || [ -z "$CURRENT_TREE" ] || [ "$CURRENT_TREE" = "$MAIN_TREE" ]; then
  exit 0
fi

if [[ "$CURRENT_TREE" == "$WORKTREES_ROOT"* ]]; then
  echo "WARNING: subagent stopped inside worktree $CURRENT_TREE"
  echo "Last commit: $(git log --oneline -1 2>/dev/null)"
  echo "The Lead must clean up this worktree explicitly (after LGTM or user confirms abandon)."
fi

exit 0
