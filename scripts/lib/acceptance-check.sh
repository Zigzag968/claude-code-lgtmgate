#!/usr/bin/env bash
# Shared acceptance-checklist check (#74). Sourced by hooks/block-merge-unchecked.sh and
# scripts/lead-merge.sh so both apply the SAME rule from .claude/rules/pr-acceptance.md.
# bash 3.2 safe. Defines functions only; no side effect on source.
#
#   acceptance_check_body   reads a PR body on stdin
#     rc 0  every box between <!-- acceptance:start --> / <!-- acceptance:end --> is checked
#     rc 1  at least one unchecked `- [ ]` box (each one listed on stderr)
#     rc 3  markers missing (no start marker, or start without end)
#   acceptance_has_markers  stdin body -> rc 0 iff the start marker is present (hook fail-open use)

_acc_start_re='<!--[[:space:]]*acceptance:start[[:space:]]*-->'
_acc_end_re='<!--[[:space:]]*acceptance:end[[:space:]]*-->'

acceptance_extract_block() {
  awk -v s="$_acc_start_re" -v e="$_acc_end_re" '
    $0 ~ e { inblock=0 }
    inblock { print }
    $0 ~ s { inblock=1 }
  '
}

acceptance_check_body() {
  local body block open
  body="$(cat)"
  if ! printf '%s\n' "$body" | grep -qE "$_acc_start_re" || ! printf '%s\n' "$body" | grep -qE "$_acc_end_re"; then
    echo "acceptance-check: acceptance markers missing (<!-- acceptance:start --> / <!-- acceptance:end -->)." >&2
    return 3
  fi
  block="$(printf '%s\n' "$body" | acceptance_extract_block)"
  open="$(printf '%s\n' "$block" | grep -E '^[[:space:]]*-[[:space:]]*\[ \]' || true)"
  if [ -n "$open" ]; then
    echo "acceptance-check: unchecked acceptance items:" >&2
    printf '%s\n' "$open" | sed 's/^/  /' >&2
    return 1
  fi
  return 0
}

acceptance_has_markers() {
  grep -qE "$_acc_start_re"
}
