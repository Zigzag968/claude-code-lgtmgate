#!/usr/bin/env bash
# PostToolUse(Bash) — attest that a PROBE line really came out of templates/probe-run.cjs (#80).
# Only for the lgtmgate:probe agent (spike #79: agent_type is namespaced) AND a probe-run command.
# Appends {agent_id, tool_use_id, line, ts} to <cwd>/.pipeline/probe-attest.jsonl. The command may be
# prefixed by `cd <dir> &&` (bare, single- or double-quoted dir, #82): the attestation then goes to
# <dir>/.pipeline/probe-attest.jsonl (where probe-run.cjs --verify reads it) AND, if different, to
# <cwd>/.pipeline/probe-attest.jsonl (where SubagentStop-probe.sh looks). Only PROBE lines are
# attested, never a VERIFY line. Never blocks: any other case, and any error, is a silent exit 0
# (fail-open).
set -uo pipefail
trap 'exit 0' ERR

command -v jq >/dev/null 2>&1 || exit 0
INPUT="$(cat 2>/dev/null)" || exit 0
[ -n "$INPUT" ] || exit 0

AGENT_TYPE="$(printf '%s' "$INPUT" | jq -r '.agent_type // empty' 2>/dev/null)" || exit 0
[ "$AGENT_TYPE" = "lgtmgate:probe" ] || exit 0
[ "$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)" = "Bash" ] || exit 0

CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
CDRE='^cd[[:space:]]+("([^"]*)"|'"'"'([^'"'"']*)'"'"'|([^[:space:]"'"'"']+))[[:space:]]+&&[[:space:]]+(.*)$'
RE='^node[[:space:]]+["'"'"']?([^[:space:]"'"'"']*/)?probe-run\.cjs["'"'"']?([[:space:]]|$)'
CDDIR=""
REST="$CMD"
if [[ "$CMD" =~ $CDRE ]]; then
  CDDIR="${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[4]}"
  REST="${BASH_REMATCH[5]}"
fi
[[ "$REST" =~ $RE ]] || exit 0

STDOUT="$(printf '%s' "$INPUT" | jq -r '.tool_response.stdout // empty' 2>/dev/null)"
LINE="$(printf '%s\n' "$STDOUT" | grep '^PROBE ' | tail -1)"
[ -n "$LINE" ] || exit 0

CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$CWD" ] || CWD="$PWD"
ENTRY="$(jq -cn --arg a "$(printf '%s' "$INPUT" | jq -r '.agent_id // empty')" \
       --arg t "$(printf '%s' "$INPUT" | jq -r '.tool_use_id // empty')" \
       --arg l "$LINE" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '{agent_id:$a, tool_use_id:$t, line:$l, ts:$ts}' 2>/dev/null)" || exit 0
[ -n "$ENTRY" ] || exit 0
TARGETS="$CWD"
if [ -n "$CDDIR" ]; then
  case "$CDDIR" in /*) ;; *) CDDIR="$CWD/$CDDIR" ;; esac
  TARGETS="$CDDIR"
  [ "$CDDIR" = "$CWD" ] || TARGETS="$CDDIR
$CWD"
fi
while IFS= read -r d; do
  [ -n "$d" ] || continue
  mkdir -p "$d/.pipeline" 2>/dev/null || continue
  printf '%s\n' "$ENTRY" >> "$d/.pipeline/probe-attest.jsonl" 2>/dev/null
done <<EOF
$TARGETS
EOF
exit 0
