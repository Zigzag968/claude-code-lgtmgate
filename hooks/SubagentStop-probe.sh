#!/usr/bin/env bash
# SubagentStop — the probe agent may not stop without an attested PROBE and VERIFY pair (#80, #83).
# The ONLY blocking case: agent_type == lgtmgate:probe, stop_hook_active not true, and
# <cwd>/.pipeline/probe-attest.jsonl does not hold, for this agent_id, a kind=probe entry P and a
# kind=verify entry V of the same label and round (P.label not null), V being either a failing
# VERIFY line, or exactly "VERIFY ok linesha=" + sha256(P.line), or the former form
# "VERIFY ok line=" + P.line -> reason on stderr, exit 2
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

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
  else return 1; fi
}

PAIRED=""
if [ -f "$FILE" ] && [ -n "$AGENT_ID" ]; then
  # sha256 of each PROBE line of this agent, keyed by the line (same bytes as probe-run.cjs sha256(v.line))
  SHAS="{}"
  while IFS= read -r enc; do
    [ -n "$enc" ] || continue
    pl="$(printf '%s' "$enc" | jq -r .)"
    sha="$(sha_of "$pl")" || exit 0
    [ -n "$sha" ] || exit 0
    SHAS="$(printf '%s' "$SHAS" | jq -c --arg k "$pl" --arg v "$sha" '. + {($k): $v}')"
  done < <(jq -nR --arg a "$AGENT_ID" '
    inputs | fromjson? | select(type == "object")
    | select(.agent_id == $a and .kind == "probe" and .label != null and ((.line | type) == "string"))
    | .line' -c "$FILE" 2>/dev/null)
  PAIRED="$(jq -nR --arg a "$AGENT_ID" --argjson shas "$SHAS" '
    [inputs | fromjson? | select(type == "object") | select(.agent_id == $a)] as $es
    | any($es[] | select(.kind == "probe" and .label != null) as $p
          | $es[] | select(.kind == "verify" and .label == $p.label and .round == $p.round
                           and ((.line | type) == "string")
                           and (if (.line | startswith("VERIFY ok linesha="))
                                then .line == ("VERIFY ok linesha=" + ($shas[$p.line] // "-"))
                                elif (.line | startswith("VERIFY ok line="))
                                then .line == ("VERIFY ok line=" + $p.line)
                                else true end)); true)
  ' "$FILE" 2>/dev/null)" || PAIRED=""
fi
[ "$PAIRED" = "true" ] && exit 0

echo "probe: no attested PROBE and VERIFY pair for this agent. Run BOTH given commands once each, in order, and answer each printed line (PROBE, then VERIFY) verbatim." >&2
exit 2
