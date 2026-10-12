#!/usr/bin/env bash
# Offline test (#234): the token read from the Keychain by scripts/run-probe-evals-docker.sh reaches the
# container environment only. A fake token must appear in no file, no output, no docker argument list and
# no process command line. Fake docker and security; no real Keychain. bash 3.2 safe.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
W="$ROOT/scripts/run-probe-evals-docker.sh"
TMP_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
WORK="$(mktemp -d "$TMP_BASE/eval-credential-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass_count=0
fail_count=0
check() {
  if [ "$2" -eq 1 ]; then echo "PASS - $1"; pass_count=$((pass_count + 1))
  else echo "FAIL - $1"; fail_count=$((fail_count + 1)); fi
}

TOKEN="FAKE-$RANDOM-$RANDOM-$RANDOM-credential"
FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN" "$WORK/home"
cat > "$FAKEBIN/security" <<'SH'
#!/bin/sh
case "$*" in *" -w"*|*"-w") printf '%s\n' "$FAKE_EXPECTED" ;; esac
exit 0
SH
# fake docker: records argv and the parent command line, and only whether the env carried the token
cat > "$FAKEBIN/docker" <<'SH'
#!/bin/sh
echo "$@" >> "$FAKE_WORK/docker.argv"
# every process command line on the host at the time of the container call (empty when ps is not permitted)
ps -axo args= > "$FAKE_WORK/docker.ps.tmp" 2>/dev/null && cat "$FAKE_WORK/docker.ps.tmp" >> "$FAKE_WORK/docker.ps"
[ "${CLAUDE_CODE_OAUTH_TOKEN:-}" = "$FAKE_EXPECTED" ] && echo "token-passed=yes" >> "$FAKE_WORK/docker.flag"
exit 0
SH
chmod +x "$FAKEBIN"/*

OUT="$(env -u CLAUDE_CODE_OAUTH_TOKEN PATH="$FAKEBIN:$PATH" HOME="$WORK/home" FAKE_WORK="$WORK" FAKE_EXPECTED="$TOKEN" bash "$W" 2>&1)"
RC=$?
printf '%s\n' "$OUT" > "$WORK/runner.out"

ok=0; [ "$RC" -eq 0 ] && grep -q 'token-passed=yes' "$WORK/docker.flag" 2>/dev/null && ok=1
check "the container invocation receives the token in its environment (exit $RC)" "$ok"

ok=1; grep -rqF -- "$TOKEN" "$WORK" && ok=0
check "the fake token appears in no file under the work dir (output, argv, ps record, flag)" "$ok"

ok=1; case "$OUT" in *"$TOKEN"*) ok=0 ;; esac
check "the fake token is absent from the runner stdout+stderr" "$ok"

ok=0
grep -q -- '-e CLAUDE_CODE_OAUTH_TOKEN ' "$WORK/docker.argv" && ! grep -q -- '-e [A-Z_]*API_KEY' "$WORK/docker.argv" && ! grep -q -- 'CLAUDE_CODE_OAUTH_TOKEN=' "$WORK/docker.argv" && ok=1
check "docker run passes only the OAuth token by bare name (-e NAME), never NAME=value" "$ok"

ok=1; grep -q 'ANTHROPIC_API_KEY' "$W" && ok=0
check "the wrapper no longer names ANTHROPIC_API_KEY (runner is OAuth-only)" "$ok"

ok=0
grep -q -- "$ROOT:/workspace:ro" "$WORK/docker.argv" && grep -q -- "$ROOT/evals/results:/workspace/evals/results" "$WORK/docker.argv" && ok=1
check "the repo is mounted read-only, only evals/results writable" "$ok"

# ps can be denied by a tool sandbox; the token-free scan above covers docker.ps whenever it was recorded
if [ -s "$WORK/docker.ps" ]; then
  ok=1; grep -qF -- "$TOKEN" "$WORK/docker.ps" && ok=0
  check "no process command line on the host carries the token" "$ok"
else
  echo "SKIP - process command lines not readable here (ps denied); covered where ps is permitted (CI)"
fi

ok=1; grep -qE '(^|[^a-zA-Z])set +-[a-z]*x|set -o xtrace' "$W" && ok=0
check "the runner never enables shell tracing" "$ok"

ok=1; grep -qE 'env-file|--env-file' "$W" && ok=0
check "the runner writes no env file" "$ok"

echo "status=$([ "$fail_count" -eq 0 ] && echo pass || echo fail) pass=$pass_count fail=$fail_count"
[ "$fail_count" -eq 0 ]
