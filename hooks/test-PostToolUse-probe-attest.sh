#!/usr/bin/env bash
# Regression test for hooks/PostToolUse-probe-attest.sh and hooks/SubagentStop-probe.sh (#80).
# Temp dir under $TMPDIR only, no network. Needs jq (skips with a PASS-less note otherwise).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATTEST="$SCRIPT_DIR/PostToolUse-probe-attest.sh"
STOP="$SCRIPT_DIR/SubagentStop-probe.sh"
REG="$SCRIPT_DIR/plugin-hooks.json"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP - jq not installed"
  echo "[probe-hooks] status=ok passed=0 failed=0"
  exit 0
fi

TMP_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
WORK="$(mktemp -d "$TMP_BASE/probe-hooks-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass_count=0
fail_count=0
check() {
  if [ "$2" -eq 1 ]; then echo "PASS - $1"; pass_count=$((pass_count + 1))
  else echo "FAIL - $1"; fail_count=$((fail_count + 1)); fi
}

PLINE='PROBE name=lines exit=0 sha=98ea6e4f216f2fb4b69fff9b3a44842c38686ca685f3f55dc48c5d3fb1107be4 json={"lines":["hi"]}'

# mk <agent_type|-> <command> [stdout] -> PostToolUse payload for cwd $CWD
mk() {
  jq -cn --arg at "$1" --arg cmd "$2" --arg so "${3-$PLINE}" --arg cwd "$CWD" '
    {cwd:$cwd, agent_id:"agent-1", tool_use_id:"tu-1", tool_name:"Bash",
     tool_input:{command:$cmd}, tool_response:{stdout:$so}}
    + (if $at == "-" then {} else {agent_type:$at} end)'
}

attest_lines() { [ -f "$CWD/.pipeline/probe-attest.jsonl" ] && wc -l < "$CWD/.pipeline/probe-attest.jsonl" | tr -d ' ' || echo 0; }

fresh() { CWD="$(mktemp -d "$WORK/c.XXXXXX")"; }

# (a) probe + probe-run command + PROBE stdout -> one jsonl line
fresh
mk lgtmgate:probe "node templates/probe-run.cjs --label x --round 0 --out /o --parser lines --cmd 'true'" | bash "$ATTEST"
RC=$?
ok=0
[ "$RC" -eq 0 ] && [ "$(attest_lines)" = "1" ] &&
  [ "$(jq -r '.agent_id + "|" + .tool_use_id + "|" + .line' "$CWD/.pipeline/probe-attest.jsonl")" = "agent-1|tu-1|$PLINE" ] && ok=1
check "probe + probe-run command -> attested (agent_id, tool_use_id, line)" "$ok"

# (a2) quoted absolute path is also accepted
fresh
mk lgtmgate:probe "node \"/abs/plugin/templates/probe-run.cjs\" --label x" | bash "$ATTEST"
[ "$(attest_lines)" = "1" ] && ok=1 || ok=0
check "quoted absolute probe-run path -> attested" "$ok"

# (b) other agent -> ignored
fresh
mk lgtmgate:Morgan "node templates/probe-run.cjs --label x" | bash "$ATTEST"; RC=$?
[ "$RC" -eq 0 ] && [ "$(attest_lines)" = "0" ] && ok=1 || ok=0
check "lgtmgate:Morgan -> ignored" "$ok"

# (c) no agent_type -> ignored
fresh
mk - "node templates/probe-run.cjs --label x" | bash "$ATTEST"; RC=$?
[ "$RC" -eq 0 ] && [ "$(attest_lines)" = "0" ] && ok=1 || ok=0
check "no agent_type -> ignored" "$ok"

# (d) probe + echo -> ignored
fresh
mk lgtmgate:probe "echo hi" "$PLINE" | bash "$ATTEST"; RC=$?
[ "$RC" -eq 0 ] && [ "$(attest_lines)" = "0" ] && ok=1 || ok=0
check "probe + echo hi -> ignored" "$ok"

# (e) probe + other node script -> ignored
fresh
mk lgtmgate:probe "node other.cjs" | bash "$ATTEST"; RC=$?
[ "$RC" -eq 0 ] && [ "$(attest_lines)" = "0" ] && ok=1 || ok=0
check "probe + node other.cjs -> ignored" "$ok"

# (f) probe-run.cjs.evil -> ignored
fresh
mk lgtmgate:probe "node templates/probe-run.cjs.evil --label x" | bash "$ATTEST"; RC=$?
[ "$RC" -eq 0 ] && [ "$(attest_lines)" = "0" ] && ok=1 || ok=0
check "probe-run.cjs.evil -> ignored" "$ok"

# (f2) probe-run command but stdout without a PROBE line -> nothing attested
fresh
mk lgtmgate:probe "node templates/probe-run.cjs --label x" "no probe here" | bash "$ATTEST"
[ "$(attest_lines)" = "0" ] && ok=1 || ok=0
check "no PROBE line in stdout -> ignored" "$ok"

# (g) garbage stdin -> exit 0
printf 'not json at all' | bash "$ATTEST"; RC=$?
[ "$RC" -eq 0 ] && ok=1 || ok=0
check "garbage stdin -> exit 0 (attest)" "$ok"
printf 'not json at all' | bash "$STOP"; RC=$?
[ "$RC" -eq 0 ] && ok=1 || ok=0
check "garbage stdin -> exit 0 (stop)" "$ok"

# SubagentStop: payload <agent_type> <stop_hook_active>
stop_in() {
  jq -cn --arg at "$1" --argjson sha "$2" --arg cwd "$CWD" \
    '{cwd:$cwd, agent_id:"agent-1", agent_type:$at, stop_hook_active:$sha}'
}

fresh
ERR="$(stop_in lgtmgate:probe false | bash "$STOP" 2>&1 >/dev/null)"; RC=$?
[ "$RC" -eq 2 ] && [ -n "$ERR" ] && ok=1 || ok=0
check "stop: probe without attestation -> exit 2 + reason on stderr" "$ok"

mkdir -p "$CWD/.pipeline"
printf '{"agent_id":"someone-else","tool_use_id":"x","line":"PROBE","ts":"t"}\n' > "$CWD/.pipeline/probe-attest.jsonl"
stop_in lgtmgate:probe false | bash "$STOP" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok=1 || ok=0
check "stop: attestation of ANOTHER agent does not count -> exit 2" "$ok"

printf '{"agent_id":"agent-1","tool_use_id":"x","line":"PROBE","ts":"t"}\n' >> "$CWD/.pipeline/probe-attest.jsonl"
stop_in lgtmgate:probe false | bash "$STOP" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok=1 || ok=0
check "stop: attestation present -> exit 0" "$ok"

fresh
stop_in lgtmgate:probe true | bash "$STOP" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok=1 || ok=0
check "stop: stop_hook_active true -> exit 0 (never loops)" "$ok"

stop_in lgtmgate:Morgan false | bash "$STOP" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok=1 || ok=0
check "stop: other agent_type -> exit 0" "$ok"

# Registration in plugin-hooks.json
jq -e '.hooks.PostToolUse[] | select(.matcher=="Bash") | .hooks[] | select(.command | contains("PostToolUse-probe-attest.sh"))' "$REG" >/dev/null 2>&1 && ok=1 || ok=0
check "plugin-hooks.json registers PostToolUse-probe-attest.sh" "$ok"
jq -e '.hooks.SubagentStop[] | select(.matcher=="") | .hooks[] | select(.command | contains("SubagentStop-probe.sh"))' "$REG" >/dev/null 2>&1 && ok=1 || ok=0
check "plugin-hooks.json registers SubagentStop-probe.sh" "$ok"
jq -e '.hooks.SubagentStop[] | select(.matcher=="Sam|Nick|Morgan|Mia|Theo")' "$REG" >/dev/null 2>&1 && ok=1 || ok=0
check "existing Sam|Nick|Morgan|Mia|Theo SubagentStop entry untouched" "$ok"

if [ "$fail_count" -eq 0 ]; then st=ok; else st=fail; fi
echo "[probe-hooks] status=$st passed=$pass_count failed=$fail_count"
[ "$fail_count" -eq 0 ]
