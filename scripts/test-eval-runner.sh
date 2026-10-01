#!/usr/bin/env bash
# Offline test of scripts/eval-runner/ (#81). Fake `security`, fake `docker`, fake eval script in a temp
# worktree: no Docker, no Keychain, no network. bash 3.2 safe (macOS and Linux CI).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER="$ROOT/scripts/eval-runner/lgtmgate-eval-runner.sh"
TRIGGER="$ROOT/scripts/eval-runner/trigger.sh"
INSTALL="$ROOT/scripts/eval-runner/install.sh"
TMP_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
WORK="$(mktemp -d "$TMP_BASE/eval-runner-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

TOKEN="tok-SECRET-for-test-123"
pass_count=0
fail_count=0
check() {
  if [ "$2" -eq 1 ]; then echo "PASS - $1"; pass_count=$((pass_count + 1))
  else echo "FAIL - $1"; fail_count=$((fail_count + 1)); fi
}

FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/security" <<FAKE
#!/bin/bash
[ -n "\${FAKE_SECURITY_FAIL:-}" ] && exit 44
echo "$TOKEN"
FAKE
printf '#!/bin/bash\nexit 0\n' > "$FAKEBIN/docker"
chmod +x "$FAKEBIN/security" "$FAKEBIN/docker"

ALLOWED="$WORK/allowed"
mkdir -p "$ALLOWED"
ALLOWED="$(cd -P "$ALLOWED" && pwd -P)"
ORDER="$WORK/order.txt"

mk_worktree() { # mk_worktree <dir>: git worktree with a fake docker eval script
  mkdir -p "$1/scripts"
  git init -q "$1" >/dev/null 2>&1
  cat > "$1/scripts/run-probe-evals-docker.sh" <<FAKE
#!/usr/bin/env bash
echo "\$(basename "\$PWD")" >> "$ORDER"
echo "token_len=\${#CLAUDE_CODE_OAUTH_TOKEN}" >> "$WORK/seen-env.txt"
[ "\${CLAUDE_CODE_OAUTH_TOKEN:-}" = "$TOKEN" ] && echo present >> "$WORK/seen-token.txt"
echo "args=\$*" >> "$WORK/seen-args.txt"
echo "noise line"
echo "== probe-provision: exit=0"
echo "== probe-pr-state: exit=0"
exit \${FAKE_EVAL_RC:-0}
FAKE
}
mk_worktree "$ALLOWED/wt1"
mk_worktree "$ALLOWED/wt2"

new_spool() { SP="$WORK/spool-$1"; rm -rf "$SP"; mkdir -p "$SP/inbox" "$SP/running" "$SP/done"; }
run_runner() { SPOOL="$SP" ALLOWED_ROOT="$ALLOWED" PATH="$FAKEBIN:$PATH" bash "$RUNNER" >"$WORK/runner.out" 2>&1; }
rc_of() { cat "$SP/done/$1.rc" 2>/dev/null; }

# happy path
new_spool happy
echo "$ALLOWED/wt1" > "$SP/inbox/a1.trigger"
run_runner
ok=0; [ "$(rc_of a1)" = "0" ] && ok=1; check "happy path: rc 0" "$ok"
ok=0; grep -q '^== probe-provision: exit=0$' "$SP/done/a1.summary" && ! grep -q noise "$SP/done/a1.summary" && ok=1
check "happy path: summary holds only the score lines" "$ok"
ok=0; [ ! -e "$SP/inbox/a1.trigger" ] && [ ! -e "$SP/running/a1.trigger" ] && [ -f "$SP/done/a1.trigger" ] && ok=1
check "happy path: trigger moved out of inbox and running" "$ok"
ok=0; grep -q present "$WORK/seen-token.txt" 2>/dev/null && ok=1; check "token present in the eval's environment" "$ok"
ok=1; grep -rq "$TOKEN" "$SP" "$WORK/runner.out" && ok=0; check "token absent from log, summary and runner output" "$ok"
ok=0; [ ! -d "$SP/lock" ] && ok=1; check "lock released after run" "$ok"

# case names forwarded
new_spool cases
echo "$ALLOWED/wt1 probe-pr-state probe-pr-write" > "$SP/inbox/c1.trigger"
run_runner
ok=0; tail -1 "$WORK/seen-args.txt" | grep -qx 'args=probe-pr-state probe-pr-write' && ok=1
check "case names forwarded to the eval script" "$ok"

# refusals
new_spool outside
OUT="$(mktemp -d "$TMP_BASE/eval-runner-outside.XXXXXX")"; mk_worktree "$OUT"
echo "$OUT" > "$SP/inbox/o1.trigger"
run_runner
ok=0; [ "$(rc_of o1)" = "64" ] && grep -q 'not under ALLOWED_ROOT' "$SP/done/o1.log" && ok=1
check "path outside ALLOWED_ROOT: 64" "$ok"

new_spool dotdot
echo "$ALLOWED/wt1/../../$(basename "$OUT")" > "$SP/inbox/d1.trigger"
echo "$ALLOWED/../$(basename "$OUT")" > "$SP/inbox/d2.trigger"
run_runner
ok=0; [ "$(rc_of d1)" = "64" ] && [ "$(rc_of d2)" = "64" ] && ok=1
check "'..' escape: 64" "$ok"

new_spool symlink
ln -s "$OUT" "$ALLOWED/link-out"
echo "$ALLOWED/link-out" > "$SP/inbox/s1.trigger"
run_runner
ok=0; [ "$(rc_of s1)" = "64" ] && ok=1; check "symlink escape: 64" "$ok"
rm -f "$ALLOWED/link-out"

new_spool notgit
mkdir -p "$ALLOWED/plain/scripts"; : > "$ALLOWED/plain/scripts/run-probe-evals-docker.sh"
echo "$ALLOWED/plain" > "$SP/inbox/g1.trigger"
run_runner
ok=0; [ "$(rc_of g1)" = "64" ] && grep -q 'not a git worktree' "$SP/done/g1.log" && ok=1
check "not a git worktree: 64" "$ok"

new_spool noscript
mkdir -p "$ALLOWED/empty"; git init -q "$ALLOWED/empty" >/dev/null 2>&1
echo "$ALLOWED/empty" > "$SP/inbox/n1.trigger"
run_runner
ok=0; [ "$(rc_of n1)" = "64" ] && ok=1; check "missing run-probe-evals-docker.sh: 64" "$ok"

new_spool badcase
echo "$ALLOWED/wt1 ok-case bad\$case" > "$SP/inbox/b1.trigger"
run_runner
ok=0; [ "$(rc_of b1)" = "64" ] && ok=1; check "invalid case name: 64" "$ok"

# keychain
new_spool keychain
echo "$ALLOWED/wt1" > "$SP/inbox/k1.trigger"
FAKE_SECURITY_FAIL=1 run_runner
ok=0; [ "$(rc_of k1)" = "65" ] && grep -q 'Keychain item lgtmgate-eval-token not found or locked; see docs' "$SP/done/k1.log" && ok=1
check "missing keychain item: 65" "$ok"

# eval failure rc propagates
new_spool evalrc
echo "$ALLOWED/wt1" > "$SP/inbox/e1.trigger"
FAKE_EVAL_RC=3 run_runner
ok=0; [ "$(rc_of e1)" = "3" ] && ok=1; check "eval exit code propagates to the rc file" "$ok"

# config missing
ok=0; ( unset SPOOL ALLOWED_ROOT; bash "$RUNNER" >/dev/null 2>&1 ); [ "$?" -eq 2 ] && ok=1
check "unset SPOOL/ALLOWED_ROOT fails clearly" "$ok"

# ordering
new_spool order
: > "$ORDER"
echo "$ALLOWED/wt2" > "$SP/inbox/20260101T000001Z-1.trigger"
echo "$ALLOWED/wt1" > "$SP/inbox/20260101T000002Z-1.trigger"
run_runner
ok=0; [ "$(tr '\n' ' ' < "$ORDER")" = "wt2 wt1 " ] && ok=1; check "two triggers processed oldest first" "$ok"

# lock
new_spool lock
sleep 30 & LP=$!
mkdir "$SP/lock"; echo "$LP" > "$SP/lock/pid"
echo "$ALLOWED/wt1" > "$SP/inbox/l1.trigger"
run_runner
ok=0; [ -f "$SP/inbox/l1.trigger" ] && [ ! -f "$SP/done/l1.rc" ] && [ -d "$SP/lock" ] && ok=1
check "live lock prevents a double run" "$ok"
kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null
run_runner
ok=0; [ "$(rc_of l1)" = "0" ] && ok=1; check "stale lock (dead owner) is reclaimed" "$ok"

# shell metacharacters never executed
new_spool meta
PWNED="$WORK/pwned"
echo "$ALLOWED/wt1; touch $PWNED" > "$SP/inbox/m1.trigger"
echo "$ALLOWED/wt1 \$(touch $PWNED)" > "$SP/inbox/m2.trigger"
echo "\`touch $PWNED\`" > "$SP/inbox/m3.trigger"
run_runner
ok=1; [ -e "$PWNED" ] && ok=0; [ -e "$ALLOWED/wt1; touch $PWNED" ] && ok=0
[ "$(rc_of m1)" = "64" ] && [ "$(rc_of m2)" = "64" ] && [ "$(rc_of m3)" = "64" ] || ok=0
check "trigger with shell metacharacters is refused, never executed" "$ok"

# trigger.sh --wait
new_spool wait
export LGTMGATE_EVAL_SPOOL="$SP" LGTMGATE_EVAL_POLL=1
( sleep 2; run_runner ) &
BG=$!
ID="$(bash "$TRIGGER" --wait 20 "$ALLOWED/wt1" probe-pr-write | head -1)"
wait "$BG" 2>/dev/null
ok=0; [ -n "$ID" ] && [ "$(rc_of "$ID")" = "0" ] && ok=1; check "trigger.sh --wait: prints the id, result lands under that id" "$ok"

new_spool wait2
export LGTMGATE_EVAL_SPOOL="$SP"
( sleep 2; FAKE_EVAL_RC=7 run_runner ) &
BG=$!
bash "$TRIGGER" --wait 30 "$ALLOWED/wt1" > "$WORK/wait2.out" 2>&1
RC=$?
wait "$BG" 2>/dev/null
ok=0; [ "$RC" -eq 7 ] && grep -q '^== probe-provision: exit=0$' "$WORK/wait2.out" && ok=1
check "trigger.sh --wait returns the eval rc and prints the summary" "$ok"

new_spool wait3
export LGTMGATE_EVAL_SPOOL="$SP"
bash "$TRIGGER" --wait 2 "$ALLOWED/wt1" >/dev/null 2>&1
RC=$?
ok=0; [ "$RC" -eq 124 ] && ok=1; check "trigger.sh --wait times out with 124" "$ok"
ok=1; ls "$SP"/inbox/.*.tmp >/dev/null 2>&1 && ok=0; check "trigger.sh leaves no tmp file behind" "$ok"
unset LGTMGATE_EVAL_SPOOL LGTMGATE_EVAL_POLL

# install.sh --dry-run
PL="$(bash "$INSTALL" --dry-run "$WORK/sp" "$WORK/root" 2>&1)"
ok=1
for needle in 'dev.lgtmgate.eval-runner' '<key>WatchPaths</key>' "$WORK/sp/inbox" '<key>SPOOL</key>' '<key>ALLOWED_ROOT</key>' 'Library/Logs/lgtmgate-eval-runner.log' 'Application Support/lgtmgate/eval-runner.sh'; do
  case "$PL" in *"$needle"*) ;; *) ok=0 ;; esac
done
check "install.sh --dry-run prints the plist" "$ok"
ok=0; [ ! -e "$WORK/sp" ] && ok=1; check "install.sh --dry-run writes nothing" "$ok"
ok=1; command -v plutil >/dev/null 2>&1 && { printf '%s\n' "$PL" | plutil -lint - >/dev/null 2>&1 || ok=0; }
check "install.sh --dry-run plist lints (plutil, when available)" "$ok"

echo "status=$([ "$fail_count" -eq 0 ] && echo pass || echo fail) pass=$pass_count fail=$fail_count"
[ "$fail_count" -eq 0 ]
