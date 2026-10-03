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

python3 - "$TMP" <<'PY'
import json,sys,os
f=json.load(open('fixtures/smoke/auto-lgtm.json'))
f['calls']['decoy-label']='never asked'
f['calls']['diagnose-issue-123']=[f['calls']['diagnose-issue-123'],'decoy second item']
json.dump(f,open(os.path.join(sys.argv[1],'extra-entries.json'),'w'))
PY
out=$(node scripts/run-offline.cjs "$TMP/extra-entries.json" --report-unused 2>&1)
case "$out" in
  *"unused: decoy-label"*"status=ok passed=1"*)
    case "$out" in *"unused: diagnose-issue-123[1]"*) ok "report-unused lists an unasked label and an unconsumed array item";; *) bad "report-unused misses the array tail: $out";; esac;;
  *) bad "report-unused output: $out";;
esac

out=$(node scripts/run-offline.cjs "$TMP/extra-entries.json" 2>&1)
case "$out" in *"unused:"*) bad "unused printed without the flag: $out";; *"status=ok passed=1"*) ok "report-unused is opt-in (silent without the flag, still passes)";; *) bad "extra-entries.json without flag: $out";; esac

out=$(node scripts/run-offline.cjs fixtures/smoke/auto-lgtm.json --report-unused 2>&1)
case "$out" in *"unused:"*) bad "committed smoke fixture reports unused entries: $out";; *"status=ok passed=1"*) ok "report-unused prints nothing on the committed smoke fixture";; *) bad "smoke with flag: $out";; esac

# expect.callLabels / expect.traceExact (opt-in exactness; trace stays a prefix match without traceExact).
# mk.cjs derives the real labels and trace by replaying the smoke fixture, then writes the variants.
cat > "$TMP/mk.cjs" <<'JS'
const fs = require('fs')
const path = require('path')
const root = process.cwd()
const o = require(path.join(root, 'scripts/run-offline.cjs'))
const run = o.buildPipelineRunner(o.stripExports(fs.readFileSync(path.join(root, 'workflows/deliver-pipeline.js'), 'utf8')))
const smoke = () => JSON.parse(fs.readFileSync(path.join(root, 'fixtures/smoke/auto-lgtm.json'), 'utf8'))
const w = (name, f) => fs.writeFileSync(path.join(process.argv[2], name), JSON.stringify(f))
o.replayFixture(smoke(), run).then((r) => {
  const labels = r.calls.map((c) => c.label)
  const trace = r.result.trace
  let f = smoke(); f.expect.callLabels = labels; w('labels-exact.json', f)
  f = smoke(); f.expect.callLabels = [labels[1], labels[0], ...labels.slice(2)]; w('labels-swapped.json', f)
  f = smoke(); f.expect.callLabels = labels.slice(0, -1); w('labels-short.json', f)
  f = smoke(); f.expect.trace = trace.slice(0, 3); w('trace-prefix.json', f)
  f = smoke(); f.expect.trace = trace.slice(0, 3); f.expect.traceExact = true; w('trace-truncated.json', f)
  f = smoke(); f.expect.trace = trace; f.expect.traceExact = true; w('trace-full.json', f)
  f = smoke(); f.expect.traceExact = true; w('trace-missing.json', f)
})
JS
node "$TMP/mk.cjs" "$TMP"

out=$(node scripts/run-offline.cjs "$TMP/labels-exact.json" 2>&1)
case "$out" in *"status=ok passed=1"*) pass1=1;; *) pass1=0;; esac
out=$(node scripts/run-offline.cjs "$TMP/labels-swapped.json" 2>&1)
case "$out" in *"FAIL:"*"callLabels: expected ["*"], got ["*) fail1=1;; *) fail1=0;; esac
out=$(node scripts/run-offline.cjs "$TMP/labels-short.json" 2>&1)
case "$out" in *"FAIL:"*"callLabels: expected ["*) fail2=1;; *) fail2=0;; esac
if [ "$pass1$fail1$fail2" = "111" ]; then ok "expect.callLabels pins the ordered labels (a swapped pair fails with a callLabels problem, the exact list passes)"; else bad "callLabels: exact=$pass1 swapped=$fail1 short=$fail2"; fi

out=$(node scripts/run-offline.cjs "$TMP/trace-prefix.json" 2>&1)
case "$out" in *"status=ok passed=1"*) prefix=1;; *) prefix=0;; esac
out=$(node scripts/run-offline.cjs "$TMP/trace-truncated.json" 2>&1)
case "$out" in *"FAIL:"*"trace: expected 3 entries, got "*) trunc=1;; *) trunc=0;; esac
out=$(node scripts/run-offline.cjs "$TMP/trace-full.json" 2>&1)
case "$out" in *"status=ok passed=1"*) full=1;; *) full=0;; esac
out=$(node scripts/run-offline.cjs "$TMP/trace-missing.json" 2>&1)
case "$out" in *"FAIL:"*"traceExact: requires expect.trace to be an array"*) miss=1;; *) miss=0;; esac
if [ "$prefix$trunc$full$miss" = "1111" ]; then ok "expect.traceExact rejects a truncated trace that prefix matching accepts (and accepts the full trace)"; else bad "traceExact: prefix=$prefix truncated=$trunc full=$full missing=$miss"; fi

# @@ENGINE_VERSION@@ (#195): a fixture quoting the engine version survives the merge-time bump. The incident fixture
# uses the token in its expected reason and replays green; against an engine with no BUILD version it is refused.
out=$(node scripts/run-offline.cjs fixtures/incidents/195-stale-plugin-root.json 2>&1 | tail -n 1)
case "$out" in *"status=ok passed=1"*) tok1=1;; *) tok1=0;; esac
printf 'return { status: "x" }\n' > "$TMP/no-build.js"
out=$(node scripts/run-offline.cjs fixtures/incidents/195-stale-plugin-root.json --fp "$TMP/no-build.js" 2>&1)
case "$out" in *"FAIL:"*"uses @@ENGINE_VERSION@@ but the engine under test has no BUILD version"*) tok2=1;; *) tok2=0;; esac
if [ "$tok1$tok2" = "11" ]; then ok "@@ENGINE_VERSION@@ resolves to the engine's BUILD version, and is refused against an engine without one"; else bad "engine version token: resolves=$tok1 refused=$tok2"; fi

# #195: the plugin root travels in its own result field, the reason carries no local path.
cat > "$TMP/rinfo.cjs" <<'JS'
const fs = require('fs')
const path = require('path')
const { stripExports, buildPipelineRunner, replayFixture } = require(path.resolve('scripts/run-offline.cjs'))
const run = buildPipelineRunner(stripExports(fs.readFileSync(path.resolve('workflows/deliver-pipeline.js'), 'utf8')))
const fx = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
replayFixture(fx, run).then((r) => { process.stdout.write(JSON.stringify({ root: r.result.pluginRoot, reasonHasRoot: String(r.result.reason).includes(fx.args.pluginRoot) })) })
JS
out=$(node "$TMP/rinfo.cjs" fixtures/incidents/195-stale-plugin-root.json 2>&1)
if [ "$out" = '{"root":"/old/cache/lgtmgate/1.0.0-beta.4","reasonHasRoot":false}' ]; then ok "the plugin version escalate carries pluginRoot in its own field and no path in the reason"; else bad "pluginRoot field: $out"; fi

rm -rf "$TMP"
STATUS=ok; [ "$FAIL" -gt 0 ] && STATUS=fail
echo "[test-run-offline] status=$STATUS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
