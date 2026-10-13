#!/usr/bin/env bash
# Self-test of scripts/canary-launch.sh (#235): one fake `claude` (plugin list for the preflight, otherwise it
# records its cwd and argv), fake `git` and `gh` on PATH, no network, no real session.
# bash 3.2 compatible. Trailer: [test-canary-launch] status=<ok|fail> passed=<n> failed=<n>
set -u
cd "$(dirname "$0")/.." || exit 1
ENGINE="$PWD"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
TMP="$(cd "${TMPDIR:-/tmp}" && pwd -P)/canary-launch-selftest.$$"; mkdir -p "$TMP/bin" "$TMP/consumer/.claude"
CONSUMER="$TMP/consumer"
SCRIPT=scripts/canary-launch.sh

expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2], got [$3]"; fi; }
has() { if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1: [$3] not found in $2"; fi; }

echo '{"baseBranch":"main","repo":"acme/canary"}' > "$CONSUMER/.claude/pipeline.config.json"
echo '{"summary":"fake","result":{"status":"ready","buildStamp":"b1","rounds":1}}' > "$TMP/result-src.json"

cat > "$TMP/bin/git" <<'STUB'
#!/usr/bin/env bash
dir="."
if [ "$1" = "-C" ]; then dir="$2"; shift 2; fi
case "$1" in
  rev-parse) if [ "${2:-}" = "--show-toplevel" ]; then echo "$dir"; else echo .git; fi ;;
  fetch) exit 0 ;;
  rev-list) echo 0 ;;
  remote) echo "git@github.com:acme/canary.git" ;;
  show) echo '{"version":"1.4.0"}' ;;
  *) exit 1 ;;
esac
STUB
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "status:ready"
STUB
cat > "$TMP/bin/claude" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "plugin" ]; then
  printf '[{"id":"lgtmgate@beta","version":"1.4.0","scope":"local","enabled":true,"projectPath":"$CONSUMER"}]\n'
  exit 0
fi
echo called >> "$TMP/called"
pwd -P > "$TMP/cwd"
for a in "\$@"; do printf '%s\n' "\$a"; done > "$TMP/argv"
cat > "$TMP/prompt"
mkdir -p "\$PWD/.pipeline/probes"
echo '{"status":"ready"}' > "\$PWD/.pipeline/run1.json"
printf '{"type":"system","subtype":"task_notification","output_file":"$TMP/result-src.json"}\n'
printf '{"type":"result","permission_denials":[]}\n'
STUB
chmod +x "$TMP/bin/git" "$TMP/bin/gh" "$TMP/bin/claude"

# launch <name> <consumer> <out-dir> <brief>   -> exit code; stdout/stderr in $TMP/<name>.out/.err
launch() {
  name="$1"; cons="$2"; out="$3"; brief="$4"
  rm -f "$TMP/called" "$TMP/argv" "$TMP/cwd"
  PATH="$TMP/bin:$PATH" bash "$SCRIPT" --consumer "$cons" --issue 235 --brief "$brief" --out-dir "$out" \
    --max-turns 5 --max-budget-usd 1 </dev/null > "$TMP/$name.out" 2> "$TMP/$name.err"
  echo $?
}
not_called() { if [ -e "$TMP/called" ]; then bad "$1: claude was called"; else ok "$1: claude not called"; fi; }

# (a) refusal: the consumer is the engine checkout
rc=$(launch engine "$ENGINE" "$TMP/run-engine" "a brief")
expect "engine repo: exit 2" 2 "$rc"
has "engine repo: cause" "$TMP/engine.err" "refused engine-repo"
has "engine repo: fix" "$TMP/engine.err" "Fix:"
not_called "engine repo"

# (b) refusal: not configured
mkdir -p "$TMP/bare"
rc=$(launch bare "$TMP/bare" "$TMP/run-bare" "a brief")
expect "not configured: exit 2" 2 "$rc"
has "not configured: cause" "$TMP/bare.err" "refused not-configured"

# (c) refusal: bad brief
rc=$(launch brief "$CONSUMER" "$TMP/run-brief" 'say "hi"')
expect "bad brief: exit 2" 2 "$rc"
has "bad brief: cause" "$TMP/brief.err" "refused bad-brief"
not_called "bad brief"

# (d) refusal: out dir already used
mkdir -p "$TMP/run-used"; echo '{}' > "$TMP/run-used/launch.json"
rc=$(launch used "$CONSUMER" "$TMP/run-used" "a brief")
expect "out dir used: exit 2" 2 "$rc"
has "out dir used: cause" "$TMP/used.err" "refused out-dir-used"

# (e) refusal while a run is in flight (state file)
mkdir -p "$CONSUMER/.pipeline"
echo '{"status":"dev"}' > "$CONSUMER/.pipeline/live.json"
rc=$(launch flight "$CONSUMER" "$TMP/run-flight" "a brief")
expect "run in flight: exit 2" 2 "$rc"
has "run in flight: cause" "$TMP/flight.err" "refused run-in-flight"
not_called "run in flight"
rm -f "$CONSUMER/.pipeline/live.json"

# (f) refusal while a live-pid lock exists
mkdir -p "$CONSUMER/.pipeline/canary-launch.lock"
sleep 30 & SLEEPER=$!
echo "$SLEEPER" > "$CONSUMER/.pipeline/canary-launch.lock/pid"
rc=$(launch lock "$CONSUMER" "$TMP/run-lock" "a brief")
expect "live lock: exit 2" 2 "$rc"
has "live lock: cause" "$TMP/lock.err" "refused run-in-flight"
not_called "live lock"
if [ -d "$CONSUMER/.pipeline/canary-launch.lock" ]; then ok "live lock: left in place"; else bad "live lock: removed by the refused launch"; fi
kill "$SLEEPER" 2>/dev/null; wait "$SLEEPER" 2>/dev/null
# (f2) a dead-pid lock is taken over: the happy path below runs on top of it
echo "$SLEEPER" > "$CONSUMER/.pipeline/canary-launch.lock/pid"

# (g) happy path
rc=$(launch happy "$CONSUMER" "$TMP/run-ok" "ship it")
expect "happy path: exit 0" 0 "$rc"
expect "happy path: verdict" "canary: PASS" "$(tail -n 1 "$TMP/happy.out")"
has "happy path: run line" "$TMP/happy.out" "canary-launch: run=$TMP/run-ok"
expect "happy path: cwd is the consumer" "$CONSUMER" "$(cat "$TMP/cwd" 2>/dev/null)"
argline="$(tr '\n' ' ' < "$TMP/argv" 2>/dev/null)"
case "$argline" in *"--permission-mode dontAsk "*) ok "happy path: --permission-mode dontAsk" ;; *) bad "happy path: no dontAsk in [$argline]" ;; esac
case "$argline" in *"--plugin-dir"*|*"--setting-sources"*|*"dangerously"*|*"bypass"*) bad "happy path: forbidden flag in [$argline]" ;; *) ok "happy path: no --plugin-dir, --setting-sources or bypass" ;; esac
expect "happy path: prompt" '/lgtmgate:deliver 235 "ship it"' "$(cat "$TMP/prompt" 2>/dev/null)"
[ -f "$TMP/run-ok/launch.json" ] && ok "happy path: launch.json" || bad "happy path: launch.json missing"
[ -f "$TMP/run-ok/result.json" ] && ok "happy path: result.json" || bad "happy path: result.json missing"
[ -f "$TMP/run-ok/stream.log" ] && ok "happy path: stream.log" || bad "happy path: stream.log missing"
has "happy path: wrapper status recorded" "$TMP/run-ok/launch.json" '"wrapperStatus": "ok"'
if [ -d "$CONSUMER/.pipeline/canary-launch.lock" ]; then bad "happy path: lock still present"; else ok "happy path: lock removed"; fi

rm -rf "$TMP"
if [ "$FAIL" -eq 0 ]; then st=ok; else st=fail; fi
echo "[test-canary-launch] status=$st passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
