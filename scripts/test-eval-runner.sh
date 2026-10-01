#!/usr/bin/env bash
# Offline test of scripts/eval-runner/ (#81). Fake `security`, `docker` and `git` (clone = copy of a fixture dir):
# no Docker, no Keychain, no network. bash 3.2 safe (macOS and Linux CI).

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

ORDER="$WORK/order.txt"
CLONES="$WORK/clones"
GITLOG="$WORK/git-calls.txt"

# fake git: "clones" by copying a local fixture dir; answers rev-parse with a fixed sha
cat > "$FAKEBIN/git" <<FAKE
#!/bin/bash
if [ "\$1" = "clone" ]; then
  echo "\$*" >> "$GITLOG"
  [ -n "\${FAKE_GIT_FAIL:-}" ] && { echo "fatal: Remote branch not found in upstream origin" >&2; exit 128; }
  args=("\$@"); n=\${#args[@]}
  dest="\${args[\$((n-1))]}"
  for ((i=0; i<n; i++)); do [ "\${args[\$i]}" = "--branch" ] && br="\${args[\$((i+1))]}"; done
  cp -R "$WORK/\${FAKE_GIT_FIXTURE:-fixture-ok}" "\$dest" || exit 1
  echo "\$br" > "\$dest/.branch"
  exit 0
fi
if [ "\$1" = "-C" ] && [ "\$3" = "rev-parse" ]; then echo "0123456789abcdef0123456789abcdef01234567"; exit 0; fi
exit 1
FAKE
chmod +x "$FAKEBIN/git"

mkdir -p "$WORK/fixture-ok/scripts" "$WORK/fixture-noscript/scripts"
cat > "$WORK/fixture-ok/scripts/run-probe-evals-docker.sh" <<FAKE
#!/usr/bin/env bash
cat .branch >> "$ORDER"
echo "token_len=\${#CLAUDE_CODE_OAUTH_TOKEN}" >> "$WORK/seen-env.txt"
[ "\${CLAUDE_CODE_OAUTH_TOKEN:-}" = "$TOKEN" ] && echo present >> "$WORK/seen-token.txt"
echo "args=\$*" >> "$WORK/seen-args.txt"
echo "noise line"
echo "== probe-provision: exit=0"
echo "== probe-pr-state: exit=0"
exit \${FAKE_EVAL_RC:-0}
FAKE

new_spool() { SP="$WORK/spool-$1"; rm -rf "$SP" "$CLONES"; mkdir -p "$SP/inbox" "$SP/running" "$SP/done"; }
run_runner() { SPOOL="$SP" WORK_DIR="$CLONES" REPO_URL="file:///fake/repo.git" PATH="$FAKEBIN:$PATH" bash "$RUNNER" >"$WORK/runner.out" 2>&1; }
rc_of() { cat "$SP/done/$1.rc" 2>/dev/null; }
clones_left() { ls -A "$CLONES" 2>/dev/null | wc -l | tr -d ' '; }

# happy path
new_spool happy
echo "feat/issue-81" > "$SP/inbox/a1.trigger"
run_runner
ok=0; [ "$(rc_of a1)" = "0" ] && ok=1; check "happy path: rc 0" "$ok"
ok=0; grep -q '^== probe-provision: exit=0$' "$SP/done/a1.summary" && ! grep -q noise "$SP/done/a1.summary" && ok=1
check "happy path: summary holds only the score lines" "$ok"
ok=0; [ "$(head -1 "$SP/done/a1.log")" = "== commit 0123456789abcdef0123456789abcdef01234567 branch feat/issue-81" ] && ok=1
check "first log line records commit sha and branch" "$ok"
ok=0; grep -q -- '--depth 1 --branch feat/issue-81 file:///fake/repo.git ' "$GITLOG" && ok=1
check "clone is shallow, on the requested branch, from REPO_URL" "$ok"
ok=0; [ "$(clones_left)" = "0" ] && ok=1; check "clone removed after the run" "$ok"
ok=0; [ ! -e "$SP/inbox/a1.trigger" ] && [ ! -e "$SP/running/a1.trigger" ] && [ -f "$SP/done/a1.trigger" ] && ok=1
check "happy path: trigger moved out of inbox and running" "$ok"
ok=0; grep -q present "$WORK/seen-token.txt" 2>/dev/null && ok=1; check "token present in the eval's environment" "$ok"
ok=1; grep -rq "$TOKEN" "$SP" "$WORK/runner.out" && ok=0; check "token absent from log, summary and runner output" "$ok"
ok=0; [ ! -d "$SP/lock" ] && ok=1; check "lock released after run" "$ok"

# case names forwarded
new_spool cases
echo "main probe-pr-state probe-pr-write" > "$SP/inbox/c1.trigger"
run_runner
ok=0; tail -1 "$WORK/seen-args.txt" | grep -qx 'args=probe-pr-state probe-pr-write' && ok=1
check "case names forwarded to the eval script" "$ok"

# branch validation: all refused with 64, no clone attempted
new_spool badbranch
: > "$GITLOG"
echo "feat/../x" > "$SP/inbox/d1.trigger"
echo "../x" > "$SP/inbox/d2.trigger"
echo "-delete" > "$SP/inbox/d3.trigger"
echo "--upload-pack=x" > "$SP/inbox/d4.trigger"
printf 'a;b\n' > "$SP/inbox/d5.trigger"
printf 'a\tb\n' > "$SP/inbox/d6.trigger"
echo "$(printf 'a%.0s' $(seq 1 101))" > "$SP/inbox/d7.trigger"
echo "a\$(touch $WORK/pwned)" > "$SP/inbox/d8.trigger"
echo "/abs/path" > "$SP/inbox/d9.trigger"
echo "" > "$SP/inbox/d10.trigger"
run_runner
ok=1
for i in d1 d2 d3 d4 d6 d7 d8 d10; do [ "$(rc_of $i)" = "64" ] || { ok=0; echo "  $i -> $(rc_of $i)"; }; done
check "branch with '..', leading '-', tab, over-long, \$(), empty: 64" "$ok"
# "a;b" splits on space only: branch is "a;b" (invalid charset); "/abs/path" is charset-valid but fails the clone/script checks
ok=0; [ "$(rc_of d5)" = "64" ] && ok=1; check "branch with ';': 64" "$ok"
ok=0; [ ! -s "$GITLOG" ] || ! grep -q -e 'branch \.\./x' -e 'branch -' -e 'branch a;b' "$GITLOG"; [ $? -eq 0 ] && ok=1
check "no clone attempted for refused branches" "$ok"
ok=0; echo "main" > "$SP/inbox/e5.trigger"; echo "a b;c" > "$SP/inbox/e6.trigger"; run_runner
[ "$(rc_of e6)" = "64" ] && ok=1; check "space splits branch from cases; bad case name 'b;c': 64" "$ok"
ok=1; [ -e "$WORK/pwned" ] && ok=0; check "shell metacharacters never executed" "$ok"
ok=0; [ "$(clones_left)" = "0" ] && ok=1; check "no clone left after refusals" "$ok"
ok=0; i100="$(printf 'a%.0s' $(seq 1 100))"; new_spool len100; echo "$i100" > "$SP/inbox/f1.trigger"; run_runner
[ "$(rc_of f1)" = "0" ] && ok=1; check "100-char branch accepted" "$ok"

# clone failure
new_spool clonefail
echo "feat/nope" > "$SP/inbox/g1.trigger"
FAKE_GIT_FAIL=1 run_runner
ok=0; [ "$(rc_of g1)" = "67" ] && grep -q 'Remote branch not found' "$SP/done/g1.log" && ok=1
check "failing clone: 67 with the git error in the log" "$ok"
ok=0; [ "$(clones_left)" = "0" ] && ok=1; check "failing clone leaves nothing behind" "$ok"

new_spool noscript
echo "feat/x" > "$SP/inbox/n1.trigger"
FAKE_GIT_FIXTURE=fixture-noscript run_runner
ok=0; [ "$(rc_of n1)" = "64" ] && grep -q 'run-probe-evals-docker.sh missing' "$SP/done/n1.log" && ok=1
check "missing run-probe-evals-docker.sh in the clone: 64" "$ok"
ok=0; [ "$(clones_left)" = "0" ] && ok=1; check "clone removed after a refusal" "$ok"

# keychain
new_spool keychain
echo "main" > "$SP/inbox/k1.trigger"
FAKE_SECURITY_FAIL=1 run_runner
ok=0; [ "$(rc_of k1)" = "65" ] && grep -q 'Keychain item lgtmgate-eval-token not found or locked; see docs' "$SP/done/k1.log" && ok=1
check "missing keychain item: 65" "$ok"
ok=0; [ "$(clones_left)" = "0" ] && ok=1; check "clone removed after a Keychain refusal" "$ok"

# eval failure rc propagates
new_spool evalrc
echo "main" > "$SP/inbox/e1.trigger"
FAKE_EVAL_RC=3 run_runner
ok=0; [ "$(rc_of e1)" = "3" ] && ok=1; check "eval exit code propagates to the rc file" "$ok"
ok=0; [ "$(clones_left)" = "0" ] && ok=1; check "clone removed after a failing eval" "$ok"

# config missing
ok=0; ( unset SPOOL; bash "$RUNNER" >/dev/null 2>&1 ); [ "$?" -eq 2 ] && ok=1
check "unset SPOOL fails clearly" "$ok"

# ordering
new_spool order
: > "$ORDER"
echo "branch-two" > "$SP/inbox/20260101T000001Z-1.trigger"
echo "branch-one" > "$SP/inbox/20260101T000002Z-1.trigger"
run_runner
ok=0; [ "$(tr '\n' ' ' < "$ORDER")" = "branch-two branch-one " ] && ok=1; check "two triggers processed oldest first" "$ok"

# lock
new_spool lock
sleep 30 & LP=$!
mkdir "$SP/lock"; echo "$LP" > "$SP/lock/pid"
echo "main" > "$SP/inbox/l1.trigger"
run_runner
ok=0; [ -f "$SP/inbox/l1.trigger" ] && [ ! -f "$SP/done/l1.rc" ] && [ -d "$SP/lock" ] && ok=1
check "live lock prevents a double run" "$ok"
kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null
run_runner
ok=0; [ "$(rc_of l1)" = "0" ] && ok=1; check "stale lock (dead owner) is reclaimed" "$ok"

# trigger.sh --wait
new_spool wait
export LGTMGATE_EVAL_SPOOL="$SP" LGTMGATE_EVAL_POLL=1
( sleep 2; run_runner ) &
BG=$!
ID="$(bash "$TRIGGER" --wait 20 main probe-pr-write | head -1)"
wait "$BG" 2>/dev/null
ok=0; [ -n "$ID" ] && [ "$(rc_of "$ID")" = "0" ] && ok=1; check "trigger.sh --wait: prints the id, result lands under that id" "$ok"

new_spool wait2
export LGTMGATE_EVAL_SPOOL="$SP"
( sleep 2; FAKE_EVAL_RC=7 run_runner ) &
BG=$!
bash "$TRIGGER" --wait 30 main > "$WORK/wait2.out" 2>&1
RC=$?
wait "$BG" 2>/dev/null
ok=0; [ "$RC" -eq 7 ] && grep -q '^== probe-provision: exit=0$' "$WORK/wait2.out" && ok=1
check "trigger.sh --wait returns the eval rc and prints the summary" "$ok"

new_spool wait3
export LGTMGATE_EVAL_SPOOL="$SP"
bash "$TRIGGER" --wait 2 main >/dev/null 2>&1
RC=$?
ok=0; [ "$RC" -eq 124 ] && ok=1; check "trigger.sh --wait times out with 124" "$ok"
ok=1; ls "$SP"/inbox/.*.tmp >/dev/null 2>&1 && ok=0; check "trigger.sh leaves no tmp file behind" "$ok"
unset LGTMGATE_EVAL_SPOOL LGTMGATE_EVAL_POLL

# install.sh --dry-run
PL="$(bash "$INSTALL" --dry-run "$WORK/sp" 2>&1)"
ok=1
for needle in 'dev.lgtmgate.eval-runner' '<key>WatchPaths</key>' "$WORK/sp/inbox" '<key>SPOOL</key>' '<key>REPO_URL</key>' 'Library/Logs/lgtmgate-eval-runner.log' 'Application Support/lgtmgate/eval-runner.sh'; do
  case "$PL" in *"$needle"*) ;; *) ok=0 ;; esac
done
check "install.sh --dry-run prints the plist" "$ok"
ok=0; [ ! -e "$WORK/sp" ] && ok=1; check "install.sh --dry-run writes nothing" "$ok"
ok=0; bash "$INSTALL" --dry-run /Volumes/x/spool >/dev/null 2>"$WORK/vol.err"; [ "$?" -eq 2 ] && grep -q TCC "$WORK/vol.err" && ok=1
check "install.sh refuses a /Volumes/ spool (TCC)" "$ok"
ok=0; bash "$INSTALL" --dry-run "$WORK/sp" /extra >/dev/null 2>&1; [ "$?" -eq 2 ] && ok=1; check "install.sh takes only the spool arg" "$ok"
ok=1; command -v plutil >/dev/null 2>&1 && { printf '%s\n' "$PL" | plutil -lint - >/dev/null 2>&1 || ok=0; }
check "install.sh --dry-run plist lints (plutil, when available)" "$ok"

echo "status=$([ "$fail_count" -eq 0 ] && echo pass || echo fail) pass=$pass_count fail=$fail_count"
[ "$fail_count" -eq 0 ]
