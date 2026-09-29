#!/usr/bin/env bash
# PreToolUse(Bash) — mechanically deny destructive git operations for all agent sessions,
# wherever they appear in the command (including inside a compound command).
#
# Theo (Diagnose stage, describe-only) has no `git`-scoped tool restriction of its own —
# it gets the same Bash access as any other pipeline agent. Three incidents (issues #33,
# #42, #43) showed scope creep: credential-path probing, an unauthorized `git clean -fd`,
# and an attempt to read the real SSH key while reproducing a bug. This hook closes the
# destructive-git gap deterministically, the same way deny-bare-rm.sh closes the bare-rm
# gap — see that hook for the compound-command matching rationale.
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
if printf '%s' "$normalized" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+reset([[:space:]]+[^[:space:]]+)*[[:space:]]+--hard([[:space:]]|$)'; then
  deny "git reset --hard is denied for agent sessions, including inside compound commands. The base is frozen — never reset it. See .claude/rules/pr-acceptance.md (Autonomy in unsupervised sessions)."
fi

# git checkout -- <path> (discard of tracked files). Deliberately does NOT match
# `git checkout -b <branch>` or `git checkout <branch>` (branch switches/creates) —
# only the `--` file-discard form.
if printf '%s' "$normalized" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+checkout[[:space:]]+.*--([[:space:]]|$)'; then
  deny "git checkout -- <path> (discard) is denied for agent sessions, including inside compound commands. Restoring a file via 'git checkout <branch> -- <path>' is not covered either — use a non-destructive approach or fail explicitly instead. See .claude/rules/pr-acceptance.md (Autonomy in unsupervised sessions)."
fi

# git worktree remove (any flags, including without --force). A shared worktree can be in
# use by a concurrent pipeline run — removing it out from under that run is destructive
# regardless of --force (issue #129: a read-only investigation agent ran `git worktree
# remove --force` on a worktree a concurrent run was using).
if printf '%s' "$normalized" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+worktree[[:space:]]+remove([[:space:]]|$)'; then
  deny "git worktree remove is denied for agent sessions, including inside compound commands. A shared worktree may be in use by a concurrent pipeline run — removing it is never an agent action. See .claude/rules/pr-acceptance.md (Autonomy in unsupervised sessions)."
fi

# git worktree prune (any flags). Same rationale as worktree remove (#129) — pruning can
# discard a worktree entry a concurrent run still depends on.
if printf '%s' "$normalized" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+worktree[[:space:]]+prune([[:space:]]|$)'; then
  deny "git worktree prune is denied for agent sessions, including inside compound commands. A shared worktree entry may still be in use by a concurrent pipeline run. See .claude/rules/pr-acceptance.md (Autonomy in unsupervised sessions)."
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

exit 0
