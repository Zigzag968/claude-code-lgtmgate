#!/usr/bin/env bash
# Self-test of scripts/canary-measure.sh (#235): run directories built under $TMPDIR, no network, no git.
# A clean run passes; each broken one ends `canary: FAIL <cause>`.
# bash 3.2 compatible. Trailer: [test-canary-measure] status=<ok|fail> passed=<n> failed=<n>
set -u
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
TMP="${TMPDIR:-/tmp}/canary-measure-selftest.$$"; mkdir -p "$TMP"
SCRIPT=scripts/canary-measure.sh

expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2], got [$3]"; fi; }
has() { if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1: [$3] not found in $2"; fi; }

# mkrun <name> [status]  -> a clean run directory $TMP/<name>/run with consumer $TMP/<name>/consumer
mkrun() {
  d="$TMP/$1"; st="${2:-ready}"
  mkdir -p "$d/run" "$d/consumer/.pipeline/probes"
  printf '{"issue":235,"consumer":"%s","startedAt":"2026-10-13T00:00:00Z","wrapperStatus":"ok","wrapperExit":0}\n' "$d/consumer" > "$d/run/launch.json"
  printf '{"summary":"s","result":{"status":"%s","buildStamp":"abc123","rounds":2}}\n' "$st" > "$d/run/result.json"
  printf '%s\n' 'not json' '{"type":"system"}' '{"type":"result","permission_denials":[]}' > "$d/run/stream.log"
  echo '{"status":"ready"}' > "$d/consumer/.pipeline/run1.json"
}
measure() { bash "$SCRIPT" "$TMP/$1/run" > "$TMP/$1.out" 2> "$TMP/$1.err"; echo $?; }

# (a) clean run
mkrun clean
rc=$(measure clean)
expect "clean: exit 0" 0 "$rc"
expect "clean: verdict" "canary: PASS" "$(tail -n 1 "$TMP/clean.out")"
has "clean: build" "$TMP/clean.out" "canary-measure: build=abc123"
has "clean: rounds" "$TMP/clean.out" "canary-measure: rounds=2"
has "clean: probes" "$TMP/clean.out" "canary-measure: probes=present"

# (a2) clean run with a [human-gate] gesture only
mkrun gate
printf '2026-10-13T01:00:00Z [human-gate] ticked ac:5\n' > "$TMP/gate/run/gestures.log"
rc=$(measure gate)
expect "human-gate gesture: exit 0" 0 "$rc"
expect "human-gate gesture: verdict" "canary: PASS" "$(tail -n 1 "$TMP/gate.out")"
has "human-gate gesture: not counted" "$TMP/gate.out" "canary-measure: lead-gestures=0"

# (a3) ready-pending-human passes
mkrun pending ready-pending-human
rc=$(measure pending)
expect "ready-pending-human: exit 0" 0 "$rc"

# (b) non-terminal state file
mkrun state
echo '{"status":"dev"}' > "$TMP/state/consumer/.pipeline/run2.json"
rc=$(measure state)
expect "non-terminal: exit 1" 1 "$rc"
expect "non-terminal: verdict" "canary: FAIL non-terminal-state:1" "$(tail -n 1 "$TMP/state.out")"

# (c) missing probes
mkrun probes
rmdir "$TMP/probes/consumer/.pipeline/probes"
rc=$(measure probes)
expect "probes missing: exit 1" 1 "$rc"
expect "probes missing: verdict" "canary: FAIL probes-missing" "$(tail -n 1 "$TMP/probes.out")"

# (d) a Lead gesture without the tag
mkrun gesture
printf '2026-10-13T01:00:00Z restarted the session by hand\n' > "$TMP/gesture/run/gestures.log"
rc=$(measure gesture)
expect "lead gesture: exit 1" 1 "$rc"
expect "lead gesture: verdict" "canary: FAIL lead-gestures:1" "$(tail -n 1 "$TMP/gesture.out")"

# (e) missing result.json
mkrun nores
rm -f "$TMP/nores/run/result.json"
rc=$(measure nores)
expect "no result: exit 1" 1 "$rc"
expect "no result: verdict" "canary: FAIL no-result" "$(tail -n 1 "$TMP/nores.out")"
has "no result: status none" "$TMP/nores.out" "canary-measure: status=none"

# (f) non-ready status
mkrun esc escalate
rc=$(measure esc)
expect "escalate: exit 1" 1 "$rc"
expect "escalate: verdict" "canary: FAIL status-escalate" "$(tail -n 1 "$TMP/esc.out")"
has "escalate: escalations" "$TMP/esc.out" "canary-measure: escalations=1"

# (g) permission denials from the last result event
mkrun deny
printf '%s\n' '{"type":"result","permission_denials":[{"tool_name":"Bash"},{"tool_name":"Edit"}]}' > "$TMP/deny/run/stream.log"
rc=$(measure deny)
expect "denials: exit 1" 1 "$rc"
expect "denials: verdict" "canary: FAIL permission-denials:2" "$(tail -n 1 "$TMP/deny.out")"

# (h) several causes together
mkrun multi escalate
rmdir "$TMP/multi/consumer/.pipeline/probes"
rc=$(measure multi)
expect "several causes: verdict" "canary: FAIL status-escalate,probes-missing" "$(tail -n 1 "$TMP/multi.out")"

# (i) unreadable run directory
rc=$(bash "$SCRIPT" "$TMP/nope" </dev/null >/dev/null 2>&1; echo $?)
expect "unreadable run dir: exit 2" 2 "$rc"

rm -rf "$TMP"
if [ "$FAIL" -eq 0 ]; then st=ok; else st=fail; fi
echo "[test-canary-measure] status=$st passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
