#!/usr/bin/env bash
# PreToolUse(Bash) — mechanically deny destructive git operations for all agent sessions,
# wherever they appear in the command (including inside a compound command).
#
# Theo (Diagnose stage, describe-only) has no `git`-scoped tool restriction of its own —
# it gets the same Bash access as any other pipeline agent. Three incidents (issues #33,
# #42, #43) showed scope creep: credential-path probing, an unauthorized `git clean -fd`,
# and an attempt to read the real SSH key while reproducing a bug. This hook closes the
# destructive-git gap deterministically, the same way deny-bare-rm.sh closes the bare-rm
# gap — same whole-command matching approach. The bare recursive-rm rule (worktree
# directories) lives at the bottom of THIS file: there is no separate deny-bare-rm.sh
# in hooks/.
#
# See agents/theo.md (blast-radius interdits) and .claude/rules/pr-acceptance.md
# (Autonomy in unsupervised sessions).
#
# Output format: the ONLY PreToolUse deny format documented at
# https://code.claude.com/docs/en/hooks is the nested hookSpecificOutput one below (its own
# worked example uses exactly this shape). Belt-and-suspenders: also exit 2 with the reason
# on stderr — exit 2 blocks the tool call independently of JSON parsing (documented exit-code
# table), so a deny still lands even if the JSON path is ever mis-parsed.
set -uo pipefail

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  printf '%s\n' "$1" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || deny "jq is required to inspect tool_input but is not on PATH — fail-closed (a command that could not be checked is never silently allowed). Install jq: https://jqlang.github.io/jq/."

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || true)"

# Normalize `git -C <path> <subcommand>` to `git <subcommand>` so the patterns below match
# regardless of an explicit -C flag.
normalized="$(printf '%s' "$cmd" | sed -E 's/git([[:space:]]+-C[[:space:]]+[^[:space:]]+)/git/g')"

# git clean (any flags/variant).
if printf '%s' "$normalized" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+clean([[:space:]]|$)'; then
  deny "git clean is denied for agent sessions, including inside compound commands. Diagnose/repro work never resets the shared worktree's state — leave stray files, or note them in your summary instead. See .claude/rules/pr-acceptance.md (Autonomy in unsupervised sessions)."
fi

# git reset --hard.
if printf '%s' "$normalized" | grep -qE '(^|[;&|[:space:](]|["'"'"'])git[[:space:]]+reset([[:space:]]+[^[:space:];&|]+)*[[:space:]]+--hard([[:space:];&|)"'"'"']|$)'; then
  deny "git reset --hard is denied for agent sessions, including inside compound commands. The base is frozen — never reset it. See .claude/rules/pr-acceptance.md (Autonomy in unsupervised sessions)."
fi

# git checkout -- <path> (discard of tracked files). Deliberately does NOT match
# `git checkout -b <branch>` or `git checkout <branch>` (branch switches/creates) —
# only the `--` file-discard form.
if printf '%s' "$normalized" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+checkout[[:space:]]+.*--([[:space:]]|$)'; then
  deny "git checkout -- <path> (discard) is denied for agent sessions, including inside compound commands. Restoring a file via 'git checkout <branch> -- <path>' is not covered either — use a non-destructive approach or fail explicitly instead. See .claude/rules/pr-acceptance.md (Autonomy in unsupervised sessions)."
fi

# SANCTIONED PATH: `bash scripts/cleanup-worktree.sh <path>` removes a merged, clean worktree.
# It is deliberately NOT matched by anything below (this hook inspects command TEXT only; the
# script's internal git calls run in a subprocess it never sees) and there is NO name-based
# early exit for it: a compound `bash scripts/cleanup-worktree.sh x; <raw removal> y` must
# stay denied.
#
# git worktree remove (any flags, including without --force). A shared worktree can be in
# use by a concurrent pipeline run — removing it out from under that run is destructive
# regardless of --force (issue #129: a read-only investigation agent ran `git worktree
# remove --force` on a worktree a concurrent run was using).
if printf '%s' "$normalized" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+worktree[[:space:]]+remove([[:space:]]|$)'; then
  deny "git worktree remove is denied for agent sessions, including inside compound commands. A shared worktree may be in use by a concurrent pipeline run — removing it is never an agent action. Use scripts/cleanup-worktree.sh <path> for a merged, clean worktree. See .claude/rules/pr-acceptance.md (Autonomy in unsupervised sessions)."
fi

# git worktree prune (any flags). Same rationale as worktree remove (#129) — pruning can
# discard a worktree entry a concurrent run still depends on.
if printf '%s' "$normalized" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+worktree[[:space:]]+prune([[:space:]]|$)'; then
  deny "git worktree prune is denied for agent sessions, including inside compound commands. A shared worktree entry may still be in use by a concurrent pipeline run. Use scripts/cleanup-worktree.sh <path> for a merged, clean worktree. See .claude/rules/pr-acceptance.md (Autonomy in unsupervised sessions)."
fi

# git push --force / -f / --force-with-lease.
if printf '%s' "$normalized" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+push([[:space:]]+[^[:space:];&|]+)*[[:space:]]+(--force(-with-lease)?|-f)([[:space:]=]|$)'; then
  deny "git push --force (any form, including --force-with-lease/-f) is denied for agent sessions, including inside compound commands. Merges/force-pushes are an external gesture, never an agent action. See .claude/rules/pr-acceptance.md (Autonomy in unsupervised sessions)."
fi

# git push --delete / -d (remote-branch/ref deletion via the delete flag).
if printf '%s' "$normalized" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+push([[:space:]]+[^[:space:];&|]+)*[[:space:]]+(--delete|-d)([[:space:]]|$)'; then
  deny "git push --delete/-d (remote-ref deletion) is denied for agent sessions, including inside compound commands. Deleting a remote branch is an external gesture, never an agent action. See .claude/rules/pr-acceptance.md (Autonomy in unsupervised sessions)."
fi

# git push <remote> :<ref> (colon-refspec delete — empty source means delete the ref).
if printf '%s' "$normalized" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+push([[:space:]]+[^[:space:];&|]+)*[[:space:]]+:[^[:space:]]+'; then
  deny "git push <remote> :<ref> (colon-refspec delete) is denied for agent sessions, including inside compound commands. Deleting a remote branch is an external gesture, never an agent action. See .claude/rules/pr-acceptance.md (Autonomy in unsupervised sessions)."
fi

# gh api -X DELETE / --method DELETE on git/refs/heads/* (remote-branch deletion via the API).
if printf '%s' "$normalized" | grep -qE '(^|[;&|[:space:]])gh[[:space:]]+api([[:space:]]|$)' \
  && printf '%s' "$normalized" | grep -qiE '(^|[;&|[:space:]])(-X|--method)[[:space:]]+delete([[:space:]]|$)' \
  && printf '%s' "$normalized" | grep -qE 'git/refs/heads/'; then
  deny "gh api -X DELETE / --method DELETE on git/refs/heads/* (remote-branch deletion) is denied for agent sessions, including inside compound commands. Deleting a remote branch is an external gesture, never an agent action. See .claude/rules/pr-acceptance.md (Autonomy in unsupervised sessions)."
fi

# Bare recursive rm of a worktree: a DIRECT child of the worktree root (or the root itself).
# A deeper path (e.g. <root>/issue-1/node_modules) stays allowed. Whole-command matching like
# the sibling rules (accepted approximation). Root derived via hooks/lib-worktree-root.sh,
# sourced after the jq fail-closed check above. Sanctioned path: scripts/cleanup-worktree.sh.
# shellcheck source=hooks/lib-worktree-root.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-worktree-root.sh" 2>/dev/null || true
if declare -F resolve_worktree_root >/dev/null 2>&1; then
  wt_root="$(resolve_worktree_root)"
  if [ -n "$wt_root" ]; then
    wt_root_re="$(printf '%s' "$wt_root" | sed -E 's/[][\.*^$+?(){}|/]/\\&/g')"
    wt_lead='(^|[[:space:]"'"'"'=])'
    wt_tail='([[:space:];&|)"'"'"']|$)'
    if printf '%s' "$normalized" | grep -qE '(^|[;&|[:space:](])rm[[:space:]]' \
      && printf '%s' "$normalized" | grep -qE '[[:space:]](-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)([[:space:]]|$)' \
      && printf '%s' "$normalized" | grep -qE "${wt_lead}${wt_root_re}(/[^/[:space:];&|)\"']+)?/?${wt_tail}"; then
      deny "A bare recursive rm of a worktree (a direct child of the worktree root) is denied for agent sessions, including inside compound commands. A shared worktree may be in use by a concurrent pipeline run. Use scripts/cleanup-worktree.sh <path> for a merged, clean worktree. See .claude/rules/pr-acceptance.md (Autonomy in unsupervised sessions)."
    fi
  fi
fi

exit 0
