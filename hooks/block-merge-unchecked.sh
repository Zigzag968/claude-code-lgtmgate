#!/usr/bin/env bash
# PreToolUse(Bash) — refuse `gh pr merge` while the PR's acceptance section still has unchecked `- [ ]`.
# Enforces .claude/rules/pr-acceptance.md. Known limit (like pre-push): only catches `gh` merges
# in a hooked session; a merge via the GitHub UI is not intercepted.
#
# Also matches `scripts/lead-merge.sh <pr>` (#74): the merge script re-checks itself, but the hook
# refuses earlier so a bump commit is never pushed for a PR that cannot merge.
#
# Adapted for this repo: only the block delimited by <!-- acceptance:start --> ... <!-- acceptance:end -->
# is inspected. The PR template carries other `- [ ]` boxes (remoteconfig section) that must NOT
# block merge. Fail-open when there is no acceptance section (PRs without an acceptance checklist).
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "BLOCKED: jq is required to inspect the PR body but is not on PATH — fail-closed (a merge that could not be checked is never silently allowed). Install jq: https://jqlang.github.io/jq/." >&2; exit 2; }

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || true)"

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HOOK_DIR/../scripts/lib/acceptance-check.sh"
[ -f "$LIB" ] || LIB="${CLAUDE_PLUGIN_ROOT:-}/scripts/lib/acceptance-check.sh"
# shellcheck source=../scripts/lib/acceptance-check.sh
. "$LIB" 2>/dev/null || { echo "BLOCKED: cannot source scripts/lib/acceptance-check.sh — fail-closed." >&2; exit 2; }

# Act on `gh pr merge` and on `lead-merge.sh <pr>`.
prnum=""; repoflag=""
if printf '%s' "$cmd" | grep -qE 'gh[[:space:]]+pr[[:space:]]+merge'; then
  # Explicit PR number (gh pr merge 39) if present, else the current branch's PR.
  prnum="$(printf '%s' "$cmd" | grep -oE 'gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+[0-9]+' | grep -oE '[0-9]+$' || true)"
# Only an executed call counts (command position, optionally after bash/sh): `grep ... lead-merge.sh`
# or `cat scripts/lead-merge.sh` merely name the file.
elif printf '%s' "$cmd" | grep -qE '(^|[;&|(])[[:space:]]*((bash|sh)[[:space:]]+)?([^[:space:];&|]*/)?lead-merge\.sh([[:space:]]|$)'; then
  # --tick-from-review (#9) exists to tick the boxes Morgan proved: the script ticks, re-checks the
  # body and refuses the merge if any box is still open, so the pre-check here would only block it.
  if printf '%s' "$cmd" | grep -qE 'lead-merge\.sh[^;&|]*--tick-from-review'; then exit 0; fi
  prnum="$(printf '%s' "$cmd" | grep -oE 'lead-merge\.sh[[:space:]]+[0-9]+' | grep -oE '[0-9]+$' || true)"
else
  exit 0
fi
# Propagate -R/--repo from the merge command so the body is read from the SAME repo as the
# merge target (cross-repo false-block fix, #13): `gh pr merge 61 -R owner/repo` must inspect
# owner/repo's PR #61 — not a same-numbered PR resolved from the hook's cwd repo.
repoflag="$(printf '%s' "$cmd" | grep -oE '(-R|--repo)[[:space:]]+[^[:space:]]+' | head -1 || true)"
if [ -n "${prnum:-}" ]; then
  body="$(gh pr view "$prnum" $repoflag --json body -q .body 2>/dev/null || true)"
else
  body="$(gh pr view $repoflag --json body -q .body 2>/dev/null || true)"
fi

# Fail-open if the body can't be read (don't wedge merges on a network/auth hiccup).
[ -n "${body:-}" ] || exit 0

# No acceptance section in the body -> nothing to gate (fail-open).
printf '%s' "$body" | acceptance_has_markers || exit 0

# Refuse merge only if an unchecked box remains INSIDE the acceptance block.
if ! printf '%s' "$body" | acceptance_check_body 2>/dev/null; then
  echo "BLOCKED by pr-acceptance gate: the PR acceptance checklist still has unchecked items (- [ ])." >&2
  echo "Morgan must verify + tick every box (with proof) before merge — see .claude/rules/pr-acceptance.md." >&2
  exit 2
fi
exit 0
