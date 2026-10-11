#!/usr/bin/env bash
# Self-test of scripts/config-check.cjs (#398) and of the config warning of
# hooks/SessionStart/inject_stub.py. Everything runs in $TMPDIR; nothing is written in the repository.
# bash 3.2 compatible. Trailer: [test-config-check] status=<ok|fail> passed=<n> failed=<n>
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
CC="$ROOT/scripts/config-check.cjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/config-check-selftest.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# run <file> : output in $TMP/out, exit code in $rc
run() { node "$CC" "$1" > "$TMP/out" 2>&1; rc=$?; }
last() { tail -n 1 "$TMP/out"; }
has() { grep -qF -- "$1" "$TMP/out"; }

# S1 complete
printf '{"minPluginVersion":"1.3.0","projectSpecifics":".claude/lgtmgate"}' > "$TMP/s1.json"
run "$TMP/s1.json"
if [ "$rc" -eq 0 ] && [ "$(last)" = "[config-check] status=ok retired=0 missing=0" ] && ! has 'warn:'; then ok "S1 complete config is quiet"; else bad "S1 rc=$rc $(cat "$TMP/out")"; fi

# S2 complete via agentContext
printf '{"minPluginVersion":"1.3.0","agentContext":{"*":["a.md"]}}' > "$TMP/s2.json"
run "$TMP/s2.json"
if [ "$rc" -eq 0 ] && [ "$(last)" = "[config-check] status=ok retired=0 missing=0" ] && ! has 'warn:'; then ok "S2 agentContext counts as the conventions key"; else bad "S2 rc=$rc $(cat "$TMP/out")"; fi

# S3 stale
printf '{"conventionsRule":"x.md"}' > "$TMP/s3.json"
run "$TMP/s3.json"
if [ "$rc" -eq 0 ] && has 'conventionsRule' && has 'agentContext or projectSpecifics' && has 'minPluginVersion' && has '/lgtmgate:init' && [ "$(last)" = "[config-check] status=warn retired=1 missing=2" ]; then ok "S3 stale config names the retired and missing keys"; else bad "S3 rc=$rc $(cat "$TMP/out")"; fi

# S4 only minPluginVersion missing
printf '{"projectSpecifics":".claude/lgtmgate"}' > "$TMP/s4.json"
run "$TMP/s4.json"
if [ "$rc" -eq 0 ] && has 'minPluginVersion' && ! has 'agentContext or projectSpecifics' && [ "$(last)" = "[config-check] status=warn retired=0 missing=1" ]; then ok "S4 one missing key"; else bad "S4 rc=$rc $(cat "$TMP/out")"; fi

# S5 unreadable JSON
printf '{not json' > "$TMP/s5.json"
run "$TMP/s5.json"
if [ "$rc" -eq 0 ] && [ "$(grep -c '^warn:' "$TMP/out")" = 1 ] && [ "$(last)" = "[config-check] status=warn retired=0 missing=0" ]; then ok "S5 unreadable JSON is one warn line"; else bad "S5 rc=$rc $(cat "$TMP/out")"; fi

# S6 absent file
run "$TMP/does-not-exist.json"
if [ "$rc" -eq 0 ] && [ "$(grep -c '^warn:' "$TMP/out")" = 1 ] && [ "$(last)" = "[config-check] status=warn retired=0 missing=0" ]; then ok "S6 absent file is one warn line"; else bad "S6 rc=$rc $(cat "$TMP/out")"; fi

# S7 blank values count as missing; an array is not an object
printf '{"agentContext":{},"projectSpecifics":"","minPluginVersion":"  "}' > "$TMP/s7a.json"
run "$TMP/s7a.json"
A=$(last); RA=$rc
printf '[]' > "$TMP/s7b.json"
run "$TMP/s7b.json"
if [ "$RA" -eq 0 ] && [ "$rc" -eq 0 ] && [ "$A" = "[config-check] status=warn retired=0 missing=2" ] && [ "$(last)" = "[config-check] status=warn retired=0 missing=0" ] && has 'not a readable JSON object'; then ok "S7 blank values are missing, [] is not an object"; else bad "S7 [$A] [$(cat "$TMP/out")]"; fi

# S8 retired key states its effect and its gesture
printf '{"conventionsRule":"x.md","minPluginVersion":"1.3.0","projectSpecifics":".claude/lgtmgate"}' > "$TMP/s8.json"
run "$TMP/s8.json"
if [ "$rc" -eq 0 ] && has 'reaches no agent' && has 'fix before the run: replace it with agentContext["*"]' && [ "$(last)" = "[config-check] status=warn retired=1 missing=0" ]; then ok "S8 retired key says effect and gesture"; else bad "S8 rc=$rc $(cat "$TMP/out")"; fi

# S9 both recommended keys missing: the conventions line asks for a fix
printf '{}' > "$TMP/s9.json"
run "$TMP/s9.json"
if [ "$rc" -eq 0 ] && grep -F 'agentContext or projectSpecifics' "$TMP/out" | grep -qF 'fix before the run' && has '/lgtmgate:init' && ! has 'warn: run /lgtmgate:init and choose'; then ok "S9 missing conventions key asks for a fix before the run"; else bad "S9 rc=$rc $(cat "$TMP/out")"; fi

# S10 only minPluginVersion missing: no effect on the run
run "$TMP/s4.json"
if [ "$rc" -eq 0 ] && grep -F 'minPluginVersion' "$TMP/out" | grep -qF 'no effect on the run' && ! has 'fix before the run'; then ok "S10 missing minPluginVersion has no effect on the run"; else bad "S10 rc=$rc $(cat "$TMP/out")"; fi

# S11 absent file: one warn line with the gesture
run "$TMP/does-not-exist.json"
if [ "$rc" -eq 0 ] && [ "$(grep -c '^warn:' "$TMP/out")" = 1 ] && has 'fix before the run: run /lgtmgate:init'; then ok "S11 absent file asks for init before the run"; else bad "S11 rc=$rc $(cat "$TMP/out")"; fi

# hook cases
hook() { CLAUDE_PLUGIN_ROOT="$2" CLAUDE_PROJECT_DIR="$1" python3 "$ROOT/hooks/SessionStart/inject_stub.py" > "$TMP/hook.json" 2>/dev/null; hrc=$?; }
P="$TMP/proj"; mkdir -p "$P/.claude"
printf '{"conventionsRule":"x.md"}' > "$P/.claude/pipeline.config.json"
hook "$P" "$ROOT"
if [ "$hrc" -eq 0 ] && grep -q 'conventionsRule' "$TMP/hook.json" && ! grep -q 'pipeline ready to use' "$TMP/hook.json"; then ok "H1 hook names the retired key"; else bad "H1 rc=$hrc"; fi

printf '{"minPluginVersion":"1.3.0","projectSpecifics":".claude/lgtmgate"}' > "$P/.claude/pipeline.config.json"
hook "$P" "$ROOT"
if [ "$hrc" -eq 0 ] && ! grep -q 'conventionsRule' "$TMP/hook.json" && ! grep -q 'out of date' "$TMP/hook.json" && grep -q 'pipeline ready to use' "$TMP/hook.json"; then ok "H2 hook is quiet on a complete config"; else bad "H2 rc=$hrc"; fi

printf '{"conventionsRule":"x.md"}' > "$P/.claude/pipeline.config.json"
mkdir -p "$TMP/empty-root"
hook "$P" "$TMP/empty-root"
if [ "$hrc" -eq 0 ] && grep -q 'pipeline ready to use' "$TMP/hook.json"; then ok "H3 missing script fails silently"; else bad "H3 rc=$hrc"; fi

# H4-H6: loaded plugin version and marketplace (fixture root laid out like the plugin cache)
CR="$TMP/data/plugins/cache/market-stable-beta/lgtmgate/9.9.9"
mkdir -p "$CR/.claude-plugin"
printf '{"name":"lgtmgate","version":"9.9.9"}' > "$CR/.claude-plugin/plugin.json"
printf '{"minPluginVersion":"1.3.0","projectSpecifics":".claude/lgtmgate"}' > "$P/.claude/pipeline.config.json"
rm -f "$P/.claude/settings.json" "$P/.claude/settings.local.json"
hook "$P" "$CR"
if [ "$hrc" -eq 0 ] && grep -qF 'Loaded plugin: lgtmgate 9.9.9 from marketplace market-stable-beta.' "$TMP/hook.json" && ! grep -q 'WARNING' "$TMP/hook.json"; then ok "H4 hook names the loaded version and marketplace"; else bad "H4 rc=$hrc $(cat "$TMP/hook.json")"; fi

printf '{"enabledPlugins":{"lgtmgate@market-stable":true}}' > "$P/.claude/settings.json"
hook "$P" "$CR"
W1=0; grep -qF 'enable lgtmgate@market-stable but this session loaded lgtmgate from market-stable-beta' "$TMP/hook.json" && W1=1
rm -f "$P/.claude/settings.json"
printf '{"enabledPlugins":{"lgtmgate@market-stable":true}}' > "$P/.claude/settings.local.json"
hook "$P" "$CR"
W2=0; grep -qF 'enable lgtmgate@market-stable but' "$TMP/hook.json" && W2=1
printf '{"enabledPlugins":{"lgtmgate@market-stable-beta":true,"lgtmgate@market-stable":false}}' > "$P/.claude/settings.local.json"
hook "$P" "$CR"
W3=0; grep -q 'WARNING' "$TMP/hook.json" && W3=1
if [ "$W1" -eq 1 ] && [ "$W2" -eq 1 ] && [ "$W3" -eq 0 ] && [ "$hrc" -eq 0 ]; then ok "H5 warning only for another marketplace"; else bad "H5 W1=$W1 W2=$W2 W3=$W3"; fi

mkdir -p "$TMP/nomanifest"
printf '{not json' > "$P/.claude/settings.json"
printf '[1,2]' > "$P/.claude/settings.local.json"
hook "$P" "$TMP/nomanifest"
R1=$hrc; M1=0; grep -q 'pipeline ready to use' "$TMP/hook.json" && grep -qF 'version unknown' "$TMP/hook.json" && M1=1
printf '{"enabledPlugins":["x"]}' > "$P/.claude/settings.json"
hook "$P" "$CR"
if [ "$R1" -eq 0 ] && [ "$M1" -eq 1 ] && [ "$hrc" -eq 0 ] && grep -q 'pipeline ready to use' "$TMP/hook.json" && ! grep -q 'WARNING' "$TMP/hook.json"; then ok "H6 hook stays fail-open on odd manifest and settings"; else bad "H6 R1=$R1 M1=$M1 hrc=$hrc"; fi

RESULT=ok; [ "$FAIL" -eq 0 ] || RESULT=fail
echo "[test-config-check] status=${RESULT} passed=${PASS} failed=${FAIL}"
[ "$FAIL" -eq 0 ]
