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
#   - it also reads the lib's reading from before #202: outside a fence, a pair opens on ANY line holding the start marker (indented, preceded
#     or followed by text, spaced) and closes on the next line holding the end marker; an open box between the two refuses;
#   - it does not copy the engine's Unicode-blank handling (trim()/trimStart()): a marker alone on its line with an unusual spacing, or a
#     fence/marker line holding a control byte or a blank the engine trims (no-break space, U+2028, U+3000, BOM...), makes the body AMBIGUOUS and
#     it is refused (rc 3 / 4, no body content quoted), never guessed. Accents, emoji, dashes and arrows are not ambiguous;
#   - a body holding a NUL byte is refused (rc 3): the shell drops it, the engine keeps it, and the two could read the fences differently;
#   - an empty block (markers with no line between) is accepted: the behaviour of the base, unchanged (no box = nothing unproven).
# Known limits, not handled here:
#   - a box prefixed by a Unicode blank (`<NBSP>- [ ] x`) is invisible to this C-locale grep, and it is not a checkbox on GitHub either;
#   - the python readers of scripts/lead-merge.sh (tick-from-review, exceptions) do not know fences (issue #203);
#   - callers that capture the body with `$(...)` before piping it here (hooks/block-merge-unchecked.sh, scripts/lead-merge.sh) lose a NUL byte
#     before this lib sees it: the NUL refusal only covers a body piped straight in;
#   - acceptance_has_markers is unchanged (a plain grep).
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
#   (a) outside a fence, a line that starts with `<!--` and holds nothing but a marker-like comment (`<!--`, optional blanks,
#       `acceptance:start` or `acceptance:end`, optional blanks, `-->`, blanks only around it) without being the exact marker line (trailing
#       space/tab and one `\r` allowed): a marker with an unusual spacing. A sentence that merely mentions the markers is not one;
#   (b) any line that holds 3+ backticks or tildes, or `acceptance:`, together with a sequence the engine trims or that may change how it reads a
#       fence or a marker: a control byte (\001-\010, \013-\037, \177; the one trailing `\r` is removed first, so a second one counts), a
#       no-break space or another Unicode blank (U+0085, U+00A0, U+1680, U+2000-U+200A, U+2028, U+2029, U+202F, U+205F, U+3000, U+FEFF) in UTF-8.
#       Accents, emoji, dashes and arrows are not touched: an ordinary body with them is read as is.
# Besides the engine's own block (the last exact pair), the gate reads, outside fences, every region a LAX marker opens: from any line holding
# `<!--[[:space:]]*acceptance:start[[:space:]]*-->` (indented, preceded or followed by text, spaced) to the next line holding the lax end marker, the
# reading the lib had before #202. An open box in such a region refuses; a lax marker inside a fence neither opens nor closes a region.
# Run with LC_ALL=C so every class is a byte class on BSD awk, mawk and gawk.
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
  # 1 when `line` holds a control byte or a UTF-8 blank the engine trims
  function risky(line,   i) {
    if (line ~ CTRL) return 1
    for (i = 1; i <= NRISK; i++) if (index(line, RISK[i])) return 1
    return 0
  }
  BEGIN {
    MSTART = "<!-- acceptance:start -->"; MEND = "<!-- acceptance:end -->"
    LAXS = "<!--[[:space:]]*acceptance:start[[:space:]]*-->"; LAXE = "<!--[[:space:]]*acceptance:end[[:space:]]*-->"
    LAXA = "<!--[[:space:]]*acceptance:(start|end)[[:space:]]*-->"
    CTRL = "[\001-\010\013-\037\177]"
    RISK[++NRISK] = "\302\240"; RISK[++NRISK] = "\302\205"; RISK[++NRISK] = "\341\232\200"
    RISK[++NRISK] = "\342\200\200"; RISK[++NRISK] = "\342\200\201"; RISK[++NRISK] = "\342\200\202"; RISK[++NRISK] = "\342\200\203"
    RISK[++NRISK] = "\342\200\204"; RISK[++NRISK] = "\342\200\205"; RISK[++NRISK] = "\342\200\206"; RISK[++NRISK] = "\342\200\207"
    RISK[++NRISK] = "\342\200\210"; RISK[++NRISK] = "\342\200\211"; RISK[++NRISK] = "\342\200\212"
    RISK[++NRISK] = "\342\200\250"; RISK[++NRISK] = "\342\200\251"; RISK[++NRISK] = "\342\200\257"; RISK[++NRISK] = "\342\201\237"
    RISK[++NRISK] = "\343\200\200"; RISK[++NRISK] = "\357\273\277"
  }
  { L[NR] = $0; line = $0; sub(/\r$/, "", line)
    if ((index(line, "```") || index(line, "~~~") || index(line, "acceptance:")) && risky(line)) amb = 1
    nxt = fence_after(line, fence); mark = 0
    if (fence == "" && nxt == "") {
      t = line; sub(/[ \t]+$/, "", t)
      if (t == MSTART) { ls = NR; mark = 1; inreg = 1 }
      else if (t == MEND) { le = NR; mark = 1; inreg = 0 }
      else if (line ~ /^<!--/ && line ~ LAXA) { r = line; gsub(LAXA, "", r); if (r ~ /^[[:space:]]*$/) amb = 1 }
    }
    if (!mark && inreg) U[NR] = 1
    if (fence == "" && nxt == "") { if (line ~ LAXE) oin = 0; else if (oin) U[NR] = 1; if (line ~ LAXS) oin = 1 }
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

# acceptance_check_body reads stdin into a temporary file first (removed by a trap in a subshell, so the caller's own traps are untouched):
# `$(cat)` drops NUL bytes, the engine keeps them, and a dropped NUL can glue two backtick runs into a fence the engine never sees. A body
# holding a NUL byte is refused (rc 3) before anything is captured. Callers that capture the body with `$(...)` themselves have lost it already.
_acc_check_stdin() {
  local body block open rc size kept
  _acc_tmp="$(mktemp "${TMPDIR:-/tmp}/acc-body.XXXXXX")" || { echo 'acceptance-check: cannot create a temporary file to read the body: refused (fail-closed).' >&2; return 3; }
  trap 'rm -f "${_acc_tmp:-}"' EXIT # a global, not a local: the trap runs after the function has returned
  cat > "$_acc_tmp" || { echo 'acceptance-check: cannot read the body: refused (fail-closed).' >&2; return 3; }
  size="$(wc -c < "$_acc_tmp" | tr -d ' ')"; kept="$(LC_ALL=C tr -d '\000' < "$_acc_tmp" | wc -c | tr -d ' ')"
  if [ "$size" != "$kept" ]; then
    echo 'acceptance-check: ambiguous acceptance block (NUL byte): the body holds a NUL character, which the shell drops and the engine keeps, so the two could read the fences differently. Remove it. Nothing is guessed.' >&2
    return 3
  fi
  body="$(cat "$_acc_tmp")"
  block="$(printf '%s\n' "$body" | _acc_gate_lines)"; rc=$?
  if [ "$rc" -eq 4 ]; then
    echo 'acceptance-check: ambiguous acceptance block: a marker has an unusual spacing, or a fence/marker line holds a control character or a Unicode blank (no-break space, U+2028, U+3000, BOM...); write the markers and fences as plain ASCII lines. Nothing is guessed.' >&2
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

acceptance_check_body() {
  ( _acc_check_stdin )
}

acceptance_has_markers() {
  grep -qE "$_acc_start_re"
}
