#!/usr/bin/env bash
# Offline test of scripts/eval-preflight.sh (#234) with fake docker, security, claude and uname.
# No real docker, Keychain or network. bash 3.2 safe.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
P="$ROOT/scripts/eval-preflight.sh"
TMP_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
WORK="$(mktemp -d "$TMP_BASE/eval-preflight-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass_count=0
fail_count=0
check() {
  if [ "$2" -eq 1 ]; then echo "PASS - $1"; pass_count=$((pass_count + 1))
  else echo "FAIL - $1"; fail_count=$((fail_count + 1)); fi
}

FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN" "$WORK/home" "$WORK/cfg"
printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/docker"
printf '#!/bin/sh\nexit "${FAKE_SECURITY_RC:-0}"\n' > "$FAKEBIN/security"
printf '#!/bin/sh\necho called >> "$FAKE_CLAUDE_LOG"\nexit 0\n' > "$FAKEBIN/claude"
printf '#!/bin/sh\necho Darwin\n' > "$FAKEBIN/uname"
chmod +x "$FAKEBIN"/*
export FAKE_CLAUDE_LOG="$WORK/claude.log"
: > "$FAKE_CLAUDE_LOG"

# run <args...> sets OUT (stdout+stderr) and RC; env: no credential variable unless the case sets one
run() {
  OUT="$(env -u CLAUDE_CODE_OAUTH_TOKEN PATH="$FAKEBIN:$PATH" HOME="$WORK/home" DOCKER_CONFIG="$WORK/cfg" bash "$P" "$@" 2>&1)"
  RC=$?
}
has() { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

run docker
ok=0; [ "$RC" -eq 0 ] && has 'eval-preflight: ok (docker)' && ok=1
check "all prerequisites present -> exit 0" "$ok"

# a daemon that never answers: fails inside the 5 s probe, whole run under 10 s
cp "$FAKEBIN/docker" "$WORK/docker.ok"
printf '#!/bin/sh\nexec sleep 30\n' > "$FAKEBIN/docker"
t0="$(date +%s)"
run docker
t1="$(date +%s)"
ok=0; [ "$RC" -eq 1 ] && has 'Docker daemon' && has 'Fix:' && [ $((t1 - t0)) -lt 10 ] && ok=1
check "daemon not answering -> exit 1, names the daemon and the fix, under 10 s ($((t1 - t0)) s)" "$ok"
cp "$WORK/docker.ok" "$FAKEBIN/docker"

FAKE_SECURITY_RC=44 run docker
ok=0; [ "$RC" -eq 1 ] && has 'lgtmgate-eval-token' && has 'Fix:' && ok=1
check "missing Keychain item -> exit 1, names the item and the fix" "$ok"

# a credential already in the environment skips the Keychain probe
OUT="$(FAKE_SECURITY_RC=44 CLAUDE_CODE_OAUTH_TOKEN=x PATH="$FAKEBIN:$PATH" HOME="$WORK/home" bash "$P" docker 2>&1)"; RC=$?
ok=0; [ "$RC" -eq 0 ] && ok=1
check "credential env var set -> Keychain not required" "$ok"

# host refusal: a symbolic link in the Docker credential store
ln -s /nonexistent "$WORK/cfg/desktop.exe"
run host
ok=0; [ "$RC" -eq 3 ] && has 'eval-not-runnable' && has 'run-probe-evals-docker.sh' && [ ! -s "$FAKE_CLAUDE_LOG" ] && ok=1
check "symbolic link in the credential store -> eval-not-runnable, exit 3, claude never called" "$ok"

# the runner itself refuses on a Darwin host with that store, before any claude call
OUT="$(env PATH="$FAKEBIN:$PATH" HOME="$WORK/home" DOCKER_CONFIG="$WORK/cfg" PROBE_EVALS_RESULTS_DIR="$WORK/res" bash "$ROOT/scripts/run-probe-evals.sh" 2>&1)"; RC=$?
ok=0; [ "$RC" -eq 3 ] && case "$OUT" in *eval-not-runnable*) true ;; *) false ;; esac && [ ! -s "$FAKE_CLAUDE_LOG" ] && [ ! -e "$WORK/res" ] && ok=1
check "run-probe-evals.sh on a Darwin host with that store -> exit 3, no claude call, no results" "$ok"

rm "$WORK/cfg/desktop.exe"
run host
ok=0; [ "$RC" -eq 0 ] && has 'ok (host)' && ok=1
check "clean credential store -> host mode ok" "$ok"

run bogus
ok=0; [ "$RC" -eq 2 ] && ok=1
check "unknown mode -> usage, exit 2" "$ok"

echo "status=$([ "$fail_count" -eq 0 ] && echo pass || echo fail) pass=$pass_count fail=$fail_count"
[ "$fail_count" -eq 0 ]
