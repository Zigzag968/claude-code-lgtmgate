#!/usr/bin/env bash
# SubagentStop — the probe agent may not stop without an attested PROBE line (#80).
# The ONLY blocking case: agent_type == lgtmgate:probe, stop_hook_active not true, and no
# <cwd>/.pipeline/probe-attest.jsonl line for this agent_id -> reason on stderr, exit 2
# (SubagentStop exit 2 = keep the subagent running, stderr fed back to it). Everything else,
# including any error or missing jq, exits 0 silently. Never loops: stop_hook_active short-circuits.
set -uo pipefail
trap 'exit 0' ERR

command -v jq >/dev/null 2>&1 || exit 0
INPUT="$(cat 2>/dev/null)" || exit 0
[ -n "$INPUT" ] || exit 0

[ "$(printf '%s' "$INPUT" | jq -r '.agent_type // empty' 2>/dev/null)" = "lgtmgate:probe" ] || exit 0
[ "$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ] && exit 0

AGENT_ID="$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null)"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$CWD" ] || CWD="$PWD"
FILE="$CWD/.pipeline/probe-attest.jsonl"

if [ -f "$FILE" ] && [ -n "$AGENT_ID" ] &&
   jq -e --arg a "$AGENT_ID" 'select(.agent_id == $a)' "$FILE" >/dev/null 2>&1 &&
   [ -n "$(jq -c --arg a "$AGENT_ID" 'select(.agent_id == $a)' "$FILE" 2>/dev/null)" ]; then
  exit 0
fi

echo "probe: no attested PROBE line for this agent. Run the given probe-run.cjs command once and answer with the PROBE line it printed, verbatim." >&2
exit 2
