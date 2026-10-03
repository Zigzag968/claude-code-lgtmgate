#!/usr/bin/env bash
# Shared acceptance-checklist check (#74). Sourced by hooks/block-merge-unchecked.sh and
# scripts/lead-merge.sh so both apply the SAME rule from .claude/rules/pr-acceptance.md.
# bash 3.2 safe. Defines functions only; no side effect on source.
#
# The engine writes (ticks) only the LAST marker pair outside a fence (acceptanceSpan / fenceAfter in templates/pr-body-splice.cjs, #202):
# the last start and the last end marker, each alone on its line (trailing space/tab and one \r allowed), outside a ``` or ~~~ fence
# (3+ chars, up to 3 spaces of indent, closed by the same character at least as long with nothing but blanks after; a fence never closed
# runs to the end of the body). This lib finds that block the same way, so the engine, the merge hook and lead-merge agree on it.
# The GATE is stricter than the engine, on purpose (fail-closed, it is the last net before a merge):
#   - it reads EVERY start..end pair outside a fence, not only the last: an unticked box in an earlier pair refuses, as the lib did before #202
#     (pairs inside a fence are ignored; an unticked box in a fence inside a block still refuses);
#   - it does not copy the engine's Unicode-blank handling (trim()/trimStart()): a marker look-alike outside a fence, or a fence/marker line
#     holding a byte outside printable ASCII, makes the body AMBIGUOUS and it is refused (rc 3 / 4, no body content quoted), never guessed;
#   - an empty block (markers with no line between) is accepted: the behaviour of the base, unchanged (no box = nothing unproven).
#
#   acceptance_extract_block  reads a PR body on stdin, prints the lines between the engine's (last) pair
#     rc 0  block found (printed)
#     rc 3  no block (no start, no end, end not after start, or the markers hidden in a fence); prints nothing
#     rc 4  ambiguous body (see above); prints nothing
#   acceptance_check_body   reads a PR body on stdin
#     rc 0  every box in the block(s) between <!-- acceptance:start --> / <!-- acceptance:end --> is checked
#     rc 1  at least one unchecked `- [ ]` box (each one listed on stderr)
#     rc 3  no block, or an ambiguous body (the reason is on stderr)
#   acceptance_has_markers  stdin body -> rc 0 iff the start marker is present (hook fail-open use);
#     a plain grep, fenced or not, on purpose: a body whose real block is hidden by a fence is checked and
#     refused rather than waved through (fail-closed)

_acc_start_re='<!--[[:space:]]*acceptance:start[[:space:]]*-->'
_acc_end_re='<!--[[:space:]]*acceptance:end[[:space:]]*-->'

# One scan for both readers. A line is "ambiguous" when it could be read differently by this awk (bytes, ASCII blanks only) and by the
# engine (JS trim()/trimStart(): Unicode blanks), and then the whole body is refused, never guessed (exit 4):
#   (a) outside a fence, a line that looks like a marker (`<!--`, optional blanks, `acceptance:start` or `acceptance:end`) without being the
#       exact marker line (trailing space/tab and one `\r` allowed);
#   (b) any line that holds 3+ backticks or tildes, or `acceptance:`, together with a byte outside printable ASCII and tab (after one
#       trailing `\r`): a fence or marker line the engine may read through a blank this awk does not know.
# An ordinary body with accents or emoji elsewhere is not touched. Run with LC_ALL=C so [^\t -~] is a byte class on BSD awk, mawk and gawk.
_acc_awk='
  # the fence open after `line`, given the fence open before it ("" for none): same rule as fenceAfter in pr-body-splice.cjs
  function fence_after(line, fence,   t, c, run, rest, out, i) {
    t = line; sub(/^[ \t]+/, "", t); c = substr(t, 1, 1); run = 0
    if ((c == "`" || c == "~") && length(line) - length(t) <= 3) while (substr(t, run + 1, 1) == c) run++
    rest = substr(t, run + 1)
    if (fence != "") return (run >= length(fence) && c == substr(fence, 1, 1) && rest ~ /^[ \t]*$/) ? "" : fence
    if (run >= 3 && !(c == "`" && index(rest, "`") > 0)) { out = ""; for (i = 0; i < run; i++) out = out c; return out }
    return ""
  }
  BEGIN { MSTART = "<!-- acceptance:start -->"; MEND = "<!-- acceptance:end -->" }
  { L[NR] = $0; line = $0; sub(/\r$/, "", line)
    if ((index(line, "```") || index(line, "~~~") || index(line, "acceptance:")) && line ~ /[^\t -~]/) amb = 1
    nxt = fence_after(line, fence); mark = 0
    if (fence == "" && nxt == "") {
      t = line; sub(/[ \t]+$/, "", t)
      if (t == MSTART) { ls = NR; mark = 1; inreg = 1 }
      else if (t == MEND) { le = NR; mark = 1; inreg = 0 }
      else if (line ~ /^<!--[[:space:]]*acceptance:(start|end)/) amb = 1
    }
    if (!mark && inreg) U[NR] = 1
    fence = nxt }
  END {
    if (amb) exit 4
    if (!ls || !le || le <= ls) exit 3
    if (mode == "block") { for (i = ls + 1; i < le; i++) print L[i]; exit 0 }
    for (i = ls + 1; i < le; i++) U[i] = 1
    for (i = 1; i <= NR; i++) if (U[i]) print L[i]
  }
'

acceptance_extract_block() {
  LC_ALL=C awk -v mode=block "$_acc_awk"
}

# the lines the gate reads: the engine's block (the last pair) plus every other start..end pair outside a fence, so a
# box left open in an earlier pair still refuses (never less strict than the lib before #202, which read every pair)
_acc_gate_lines() {
  LC_ALL=C awk -v mode=gate "$_acc_awk"
}

acceptance_check_body() {
  local body block open rc
  body="$(cat)"
  block="$(printf '%s\n' "$body" | _acc_gate_lines)"; rc=$?
  if [ "$rc" -eq 4 ]; then
    echo 'acceptance-check: ambiguous acceptance block: a line looks like an acceptance marker without being the exact line, or a fence/marker line holds a character outside printable ASCII; write the markers and fences as plain ASCII lines (no look-alike marker, no blank other than space/tab). Nothing is guessed.' >&2
    return 3
  elif [ "$rc" -ne 0 ]; then
    echo 'acceptance-check: acceptance markers missing (<!-- acceptance:start --> / <!-- acceptance:end -->) outside fenced code blocks; a marker pair inside a ``` or ~~~ fence is ignored, and a fence never closed hides the rest of the body.' >&2
    return 3
  fi
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
