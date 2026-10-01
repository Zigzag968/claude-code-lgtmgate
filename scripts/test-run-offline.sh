#!/usr/bin/env bash
# Self-test of scripts/run-offline.cjs: the harness must (1) pass the committed smoke fixtures,
# (2) report FAIL on a status mismatch, (3) report FAIL on a missing label — never default.
# bash 3.2 compatible. Trailer: [test-run-offline] status=<ok|fail> passed=<n> failed=<n>
set -u
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
TMP="${TMPDIR:-/tmp}/run-offline-selftest.$$"; mkdir -p "$TMP"

out=$(node scripts/run-offline.cjs --all fixtures/smoke 2>&1 | tail -n 1)
case "$out" in *"status=ok"*) ok "smoke fixtures replay green ($out)";; *) bad "smoke fixtures: $out";; esac

sed 's/"status": "ready"/"status": "escalate"/' fixtures/smoke/auto-lgtm.json > "$TMP/wrong-status.json"
out=$(node scripts/run-offline.cjs "$TMP/wrong-status.json" 2>&1)
case "$out" in *"FAIL:"*"status: expected \"escalate\", got \"ready\""*) ok "status mismatch is reported";; *) bad "status mismatch not reported: $out";; esac

python3 - "$TMP" <<'PY'
import json,sys,os
f=json.load(open('fixtures/smoke/auto-lgtm.json')); del f['calls']['probe-123-pr-state-merge-r0']
json.dump(f,open(os.path.join(sys.argv[1],'missing-label.json'),'w'))
PY
out=$(node scripts/run-offline.cjs "$TMP/missing-label.json" 2>&1)
case "$out" in *"unanswered call"*"probe-123-pr-state-merge-r0"*) ok "missing label fails the fixture even on a fail-open path";; *) bad "missing label not reported: $out";; esac

out=$(OFFLINE_STRICT=1 node scripts/run-offline.cjs "$TMP/wrong-status.json" >/dev/null 2>&1; echo $?)
[ "$out" = "1" ] && ok "OFFLINE_STRICT=1 exits 1 on failure" || bad "OFFLINE_STRICT exit code: $out"

printf '{"name":"r","args":{"wtPath": "/Users/dev/wt"},"calls":{"a":"cd \\"/Users/dev\\" && x\\nPROVISION-EXIT:0\\n"},"expect":{"status":"x"}}\n' > "$TMP/redact.json"
node scripts/redact-fixture.cjs "$TMP/redact.json" >/dev/null
out=$(node -e 'const f=require(process.argv[1]);process.stdout.write(f.calls.a+"|"+f.args.wtPath)' "$TMP/redact.json")
case "$out" in 'cd "/Users/you" && x'$'\n''PROVISION-EXIT:0'$'\n''|/Users/you/wt') ok "redaction keeps JSON escapes and uses the invariant-safe home path";; *) bad "redaction output: $out";; esac

rm -rf "$TMP"
STATUS=ok; [ "$FAIL" -gt 0 ] && STATUS=fail
echo "[test-run-offline] status=$STATUS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
