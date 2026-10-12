#!/usr/bin/env bash
# PreToolUse(Bash) — refuse a GitHub write or a commit whose text matches a pattern of the repository's
# `.pii-patterns` file (#167). Deterministic: scripts/runtime/pii-guard.sh does the matching, no model judges.
#
# Acts only on a write verb: `gh pr create|edit|comment|review`, `gh issue create|comment|edit`, `gh api` with a
# write method or body fields, `git commit`. The scanned text is the command text plus the content of the files the
# command names (--body-file X, -F key=@X, --input X). `pr-write.sh` and `lead-merge.sh` check their own text.
# A repository without `.pii-patterns` is untouched (exit 0 before jq is needed). The plugin ships no pattern.
# The message names the pattern, never the matched text. Known limits: docs/consumer-reference.md.
#
# Output format: nested hookSpecificOutput deny JSON, plus stderr and exit 2 (same as deny-destructive-git.sh).
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HOOK_DIR/../scripts/runtime/pii-guard.sh"
[ -f "$LIB" ] || LIB="${CLAUDE_PLUGIN_ROOT:-}/scripts/runtime/pii-guard.sh"

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  printf '%s\n' "$1" >&2
  exit 2
}

# No patterns file for this directory: no impact, even without jq.
bash "$LIB" exists --dir "$PWD" >/dev/null 2>&1 || exit 0

command -v jq >/dev/null 2>&1 || deny "BLOCKED by pii-guard gate: jq is required to inspect tool_input but is not on PATH — fail-closed. Install jq: https://jqlang.github.io/jq/."

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || true)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null || true)"
[ -n "$cwd" ] && [ -d "$cwd" ] || cwd="$PWD"

# The engine scripts check their own text.
if printf '%s' "$cmd" | grep -qE '^[[:space:]]*((bash|sh)[[:space:]]+)?([^[:space:];&|]*/)?(pr-write|lead-merge)\.sh([[:space:]]|$)'; then exit 0; fi

# Write verbs only.
verb='(^|[;&|(`[:space:]])(gh[[:space:]]+(pr[[:space:]]+(create|edit|comment|review)|issue[[:space:]]+(create|comment|edit))|git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+commit)([[:space:]]|$)'
api_write='(^|[;&|(`[:space:]])gh[[:space:]]+api[[:space:]]'
if ! printf '%s' "$cmd" | grep -qE "$verb"; then
  if printf '%s' "$cmd" | grep -qE "$api_write" \
    && printf '%s' "$cmd" | grep -qE '(-X|--method)[[:space:]]*(POST|PATCH|PUT|post|patch|put)|[[:space:]](-f|-F|--field|--raw-field|--input)([[:space:]=]|$)'; then
    :
  else
    exit 0
  fi
fi

# Text to scan: the command plus the files it names.
text="$cmd"
files="$(printf '%s' "$cmd" | grep -oE '(--body-file|--input)[[:space:]=]+[^[:space:];&|)]+|(-F|--field|-f|--raw-field)[[:space:]=]+[^[:space:]=]*=@[^[:space:];&|)]+|-F[[:space:]]+@[^[:space:];&|)]+' 2>/dev/null || true)"
while IFS= read -r tok; do
  [ -n "$tok" ] || continue
  f="${tok#*@}"
  [ "$f" = "$tok" ] && f="$(printf '%s' "$tok" | sed -E 's/^(--body-file|--input)[[:space:]=]+//')"
  f="${f%\"}"; f="${f#\"}"; f="${f%\'}"; f="${f#\'}"
  [ -n "$f" ] || continue
  case "$f" in /*) ;; *) f="$cwd/$f" ;; esac
  [ "$f" = "/dev/stdin" ] || [ "$f" = "$cwd/-" ] && continue
  if [ -f "$f" ]; then text="$text
$(cat "$f" 2>/dev/null)"; fi
done <<EOF
$files
EOF

res="$(printf '%s' "$text" | bash "$LIB" check --dir "$cwd" 2>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ]; then
  name="${res#pii-refused:}"
  case "$name" in ''|*[!A-Za-z0-9_-]*) name="unknown" ;; esac
  deny "BLOCKED by pii-guard gate: pattern $name matches the text of this write; rewrite it without the data (see docs/consumer-reference.md, .pii-patterns)"
fi
exit 0
