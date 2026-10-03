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

# #195: the death of the plugin version probe agent (the fixture answers nothing for its label, so every attempt throws) is the
# resumable provision-died of the stage that follows, after the one retry a side-effect-free probe gets; never an escalate.
cat > "$TMP/death.cjs" <<'JS'
const fs = require('fs')
const path = require('path')
const { stripExports, buildPipelineRunner, replayFixture } = require(path.resolve('scripts/run-offline.cjs'))
const run = buildPipelineRunner(stripExports(fs.readFileSync(path.resolve('workflows/deliver-pipeline.js'), 'utf8')))
const fx = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
fx.calls = {}
replayFixture(fx, run).then((r) => {
  const t = r.result.trace || []
  process.stdout.write(JSON.stringify({ status: r.result.status, resumable: r.result.resumable, reason: r.result.reason === undefined, attempts: r.missing.length, trace: t.filter((x) => x.startsWith('agent-died')) }))
})
JS
out=$(node "$TMP/death.cjs" fixtures/incidents/195-stale-plugin-root.json 2>&1)
if [ "$out" = '{"status":"provision-died","resumable":true,"reason":true,"attempts":2,"trace":["agent-died:probe:1","agent-died:probe:2"]}' ]; then ok "the death of the plugin version probe agent is the resumable provision-died after one retry"; else bad "version probe agent death: $out"; fi

# #212: the tick command the probe agent copies is ONE line without the block text (the block travels as a single base64
# token) and carries the digest of the very command the engine composed (--expect-cmd), before --cmd.
cat > "$TMP/tickcmd.cjs" <<'JS'
const fs = require('fs')
const path = require('path')
const crypto = require('crypto')
const { stripExports, buildPipelineRunner, replayFixture } = require(path.resolve('scripts/run-offline.cjs'))
const run = buildPipelineRunner(stripExports(fs.readFileSync(path.resolve('workflows/deliver-pipeline.js'), 'utf8')))
const fx = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
replayFixture(fx, run, { prompts: true }).then((r) => {
  const c = r.calls.find((x) => x.label === 'probe-185-pr-write-acceptance-tick-r0')
  const prompt = c ? c.prompt : ''
  const end = prompt.indexOf('\n2. cd ')
  const start = prompt.indexOf(' --cmd ')
  const q = start >= 0 && end > start ? prompt.slice(start + 7, end) : ''
  const cmd = q.slice(1, -1).split("'\\''").join("'")
  const m = prompt.slice(0, start).split(' --expect-cmd ')[1]
  process.stdout.write(JSON.stringify({
    oneLine: q.length > 2 && !q.includes('\n'),
    noBacktick: !q.includes('`'),
    b64: cmd.includes("'--text-b64'") && !cmd.includes("'--text'"),
    noBlockText: !cmd.includes('<!-- ac:') && !cmd.includes('- [ ]'),
    digest: m === crypto.createHash('sha256').update(cmd).digest('hex'),
  }))
})
JS
out=$(node "$TMP/tickcmd.cjs" fixtures/incidents/212-tick-cmd-mismatch.json 2>&1)
if [ "$out" = '{"oneLine":true,"noBacktick":true,"b64":true,"noBlockText":true,"digest":true}' ] ; then
  ok "tick-command is ONE line, no backtick, no block text, the block as --text-b64 ($out)"
else bad "tick-command shape: $out"; fi
case "$out" in *'"digest":true'*) ok "tick-command --expect-cmd equals the sha256 of the un-quoted command, placed before --cmd";; *) bad "tick-command digest: $out";; esac

# Two-run fixtures (#185): runs[] replays each run against its own calls; carry hands run N-1's result to run N; phases and
# callLabelsAbsent are the relaunch assertions. mk2.cjs derives mutants of the committed relaunch fixture.
cat > "$TMP/mk2.cjs" <<'JS'
const fs = require('fs')
const base = () => JSON.parse(fs.readFileSync('fixtures/relaunch/dev-after-plan.json', 'utf8'))
const w = (n, f) => fs.writeFileSync(process.argv[2] + '/' + n, JSON.stringify(f))
let f = base(); f.runs[1].args.entryStage = 'plan'; w('relaunch-plan-entry.json', f)
f = base(); f.runs[1].expect.callLabelsAbsent = ['nick-']; w('relaunch-absent.json', f)
f = base(); f.runs[1].expect.phases = ['Setup', 'Diagnose', 'Dev']; w('relaunch-phases.json', f)
f = base(); f.runs[1].carry = { planText: 'nope' }; w('relaunch-carry.json', f)
f = base(); f.calls = {}; w('relaunch-mixed.json', f)
f = base(); delete f.runs[1].carry; w('relaunch-nocarry.json', f)
f = base(); f.runs[1].expect.phases = ['Setup', 'Dev', 'Review']; w('relaunch-phases-longer.json', f)
f = base(); f.runs[0].expect.status = 'ready'; f.runs[1].expect.status = 'ready'; delete f.runs[1].carry; w('relaunch-both-fail.json', f)
f = base(); f.runs = [f.runs[0]]; w('relaunch-one-run.json', f)
f = base(); f.runs[0].carry = {}; w('relaunch-carry-first.json', f)
f = base(); f.runs[1].expect.callLabelsAbsent = []; w('relaunch-absent-empty.json', f)
f = base(); f.runs[1].expect.callLabelsAbsent = 'diagnose-'; w('relaunch-absent-string.json', f)
f = base(); f.runs[1].carries = f.runs[1].carry; delete f.runs[1].carry; w('relaunch-carries.json', f)
JS
node "$TMP/mk2.cjs" "$TMP"

out=$(node scripts/run-offline.cjs fixtures/relaunch/dev-after-plan.json 2>&1 | tail -n 1)
case "$out" in *"status=ok passed=1 failed=0"*) g1=1;; *) g1=0;; esac
out=$(node scripts/run-offline.cjs "$TMP/relaunch-plan-entry.json" 2>&1)
case "$out" in *"FAIL:"*"run 2: phases: expected"*"run 2: callLabelsAbsent: call \"diagnose-issue-123\""*) g2=1;; *) g2=0;; esac
out=$(node scripts/run-offline.cjs "$TMP/relaunch-absent.json" 2>&1)
case "$out" in *"FAIL:"*"run 2: callLabelsAbsent: call \"nick-issue-123\" starts with \"nick-\""*) g3=1;; *) g3=0;; esac
out=$(node scripts/run-offline.cjs "$TMP/relaunch-phases.json" 2>&1)
case "$out" in *"FAIL:"*"run 2: phases: expected [\"Setup\",\"Diagnose\",\"Dev\"], got [\"Setup\",\"Dev\"]"*) g4=1;; *) g4=0;; esac
if [ "$g1$g2$g3$g4" = "1111" ]; then ok "two-run relaunch: the committed fixture replays green, and a relaunch that re-enters at plan, a present label prefix and a wrong phase list each fail"; else bad "two-run relaunch: green=$g1 plan-entry=$g2 absent=$g3 phases=$g4"; fi

out=$(node scripts/run-offline.cjs "$TMP/relaunch-carry.json" 2>&1)
case "$out" in *"FAIL:"*"run 2: carry \"planText\" <- result.nope"*) c1=1;; *) c1=0;; esac
[ "$(printf '%s\n' "$out" | /usr/bin/grep -c 'run 2:')" = "1" ] || c1=0
out=$(node scripts/run-offline.cjs "$TMP/relaunch-mixed.json" 2>&1)
case "$out" in *"FAIL:"*"sets \"runs\" and also a top-level args/calls/expect"*) c2=1;; *) c2=0;; esac
if [ "$c1$c2" = "11" ]; then ok "two-run carry: a field the previous run did not return fails the fixture, and runs mixed with top-level args/calls/expect is refused"; else bad "two-run carry: missing-field=$c1 mixed=$c2"; fi

# The carry is observable (#185 F1): run 1's plan holds an acceptance id line, so a relaunch that received it logs the rebuilt
# items. The same fixture without `carry` fails on that log, and so does the harness when its carry assignment does nothing.
cat > "$TMP/mut.cjs" <<'JS'
const fs = require('fs')
const [, , out, from, to] = process.argv
const src = fs.readFileSync('scripts/run-offline.cjs', 'utf8')
const n = src.split(from).length - 1
if (n !== 1) { console.error('mutation target found ' + n + ' time(s): ' + from); process.exit(2) }
fs.writeFileSync(out, src.replace(from, () => to))
JS
out=$(node scripts/run-offline.cjs "$TMP/relaunch-nocarry.json" 2>&1)
case "$out" in *"FAIL:"*"run 2: logs: missing \"acceptance item(s) rebuilt from the ids of planText\""*) n1=1;; *) n1=0;; esac
if node "$TMP/mut.cjs" "$TMP/ro-m3.cjs" 'args[argName] = clone(prev.result[field])' 'void 0'; then
  out=$(node "$TMP/ro-m3.cjs" fixtures/relaunch/dev-after-plan.json 2>&1)
  case "$out" in *"FAIL:"*"run 2: logs: missing \"acceptance item(s) rebuilt from the ids of planText\""*) n2=1;; *) n2=0;; esac
else n2=0; fi
if [ "$n1$n2" = "11" ]; then ok "two-run carry is observable: the relaunch fixture without carry fails, and so does a harness whose carry assignment does nothing"; else bad "carry observable: no-carry=$n1 no-op-harness=$n2"; fi

# Harness gaps of the two-run path (#185 F2): each case below is the one that kills a mutant of runChain/check that the
# cases above let survive (a prefix of the expected phases, a first run whose problems vanish or whose failure does not
# end the chain, previous calls not aggregated, the 2-run minimum, `carry` on the first run).
out=$(node scripts/run-offline.cjs "$TMP/relaunch-phases-longer.json" 2>&1)
case "$out" in *"FAIL:"*"run 2: phases: expected [\"Setup\",\"Dev\",\"Review\"], got [\"Setup\",\"Dev\"]"*) ok "expect.phases rejects a list longer than the real phases (a strict prefix is not a match)";; *) bad "phases longer than real: $out";; esac

out=$(node scripts/run-offline.cjs "$TMP/relaunch-both-fail.json" 2>&1)
case "$out" in
  *"FAIL:"*"run 1: status: expected \"ready\", got \"plan-ready\""*)
    case "$out" in *"run 2:"*) bad "a failing run 1 did not end the chain (run 2 was reported): $out";; *) ok "a failing first run is reported with its run number and ends the chain (run 2 never runs)";; esac;;
  *) bad "failing first run not reported: $out";;
esac

out=$(node scripts/run-offline.cjs fixtures/relaunch/dev-after-plan.json 2>&1)
want=$(node -e 'const f=require(process.argv[1]);process.stdout.write(String(f.runs.reduce((n,r)=>n+Object.values(r.calls).reduce((m,v)=>m+(Array.isArray(v)?v.length:1),0),0)))' "$PWD/fixtures/relaunch/dev-after-plan.json")
case "$out" in *" calls=$want"$'\n'*) ok "the calls of every run are aggregated (calls=$want, the sum over both runs)";; *) bad "aggregated calls: expected calls=$want in: $out";; esac

out=$(node scripts/run-offline.cjs "$TMP/relaunch-one-run.json" 2>&1)
case "$out" in *"FAIL:"*"\"runs\" must be an array of at least 2 runs"*) ok "a multi-run fixture with a single run is refused";; *) bad "single run not refused: $out";; esac

out=$(node scripts/run-offline.cjs "$TMP/relaunch-carry-first.json" 2>&1)
case "$out" in *"FAIL:"*"run 1 \"carry\" must be an object and needs an earlier run"*) ok "carry on the first run is refused, even an empty one";; *) bad "carry on the first run not refused: $out";; esac

# Fail closed on the two-run path (#185 F3): an empty or non-array callLabelsAbsent is a vacuous assertion, and a misspelled
# run key (`carries`) would silently drop the carry. Unknown `expect` keys are left as they are (36 fixtures rely on that).
out=$(node scripts/run-offline.cjs "$TMP/relaunch-absent-empty.json" 2>&1)
case "$out" in *"FAIL:"*"callLabelsAbsent: must be a non-empty array of non-empty label prefixes"*) f1=1;; *) f1=0;; esac
out=$(node scripts/run-offline.cjs "$TMP/relaunch-absent-string.json" 2>&1)
case "$out" in *"FAIL:"*"callLabelsAbsent: must be a non-empty array of non-empty label prefixes"*) f2=1;; *) f2=0;; esac
if [ "$f1$f2" = "11" ]; then ok "callLabelsAbsent refuses an empty list and a non-array (a vacuous absence assertion proves nothing)"; else bad "callLabelsAbsent refusal: empty=$f1 string=$f2"; fi

out=$(node scripts/run-offline.cjs "$TMP/relaunch-carries.json" 2>&1)
case "$out" in *"FAIL:"*"run 2 has unknown key \"carries\" (allowed: args, calls, expect, carry)"*) ok "a misspelled run key is refused with the allowed keys listed";; *) bad "unknown run key not refused: $out";; esac

# ---- #213: the version tokenizer is quote-delimited and touches only the answer of the version probe ----
tv=$(node -e '
const { tokenizeVersionProbes, ENGINE_VERSION_TOKEN } = require("./scripts/run-offline.cjs")
const mk = (v) => ({
  "probe-1-lines-plugin-version-r0": { line: "PROBE name=lines json=[\"PLUGIN-VERSION:" + v + "\"]", verify: "VERIFY ok line=[\"PLUGIN-VERSION:" + v + "\"]", note: "see \"PLUGIN-VERSION:" + v + "\"" },
  "probe-1-lines-other-r0": { line: "PLUGIN-VERSION:" + v, verify: "\"PLUGIN-VERSION:" + v + "\"" },
  "scout-issue-1-1": { text: "\"PLUGIN-VERSION:" + v + "\"" },
})
const out = []
const a = mk("1.0.0-beta.30"); const n1 = tokenizeVersionProbes(a, ["1.0.0-beta.3"])
out.push(n1 === 0 && a["probe-1-lines-plugin-version-r0"].line.includes("beta.30\"") ? "prefix-ok" : "prefix-bad")
const b = mk("1.0.0-beta.3"); const n2 = tokenizeVersionProbes(b, ["1.0.0-beta.30"])
out.push(n2 === 0 ? "reverse-ok" : "reverse-bad")
const c = mk("1.0.0-beta.3"); const n3 = tokenizeVersionProbes(c, ["1.0.0-beta.3"]); const e = c["probe-1-lines-plugin-version-r0"]
out.push(n3 === 2 && e.line.includes("\"PLUGIN-VERSION:" + ENGINE_VERSION_TOKEN + "\"") && e.verify.includes("\"PLUGIN-VERSION:" + ENGINE_VERSION_TOKEN + "\"") ? "exact-ok" : "exact-bad:" + n3)
out.push(e.note === "see \"PLUGIN-VERSION:1.0.0-beta.3\"" && c["probe-1-lines-other-r0"].line === "PLUGIN-VERSION:1.0.0-beta.3" && c["probe-1-lines-other-r0"].verify.includes("beta.3\"") && c["scout-issue-1-1"].text.includes("beta.3\"") ? "fields-ok" : "fields-bad")
const n4 = tokenizeVersionProbes(c, ["1.0.0-beta.3"]); out.push(n4 === 0 ? "idem-ok" : "idem-bad")
console.log(out.join(" "))
' 2>&1)
case "$tv" in "prefix-ok reverse-ok exact-ok fields-ok idem-ok") ok "tokenizeVersionProbes is quote-delimited, rewrites only line and verify of the version probe, and is idempotent";; *) bad "tokenizeVersionProbes unit: $tv";; esac

rm -rf "$TMP"
STATUS=ok; [ "$FAIL" -gt 0 ] && STATUS=fail
echo "[test-run-offline] status=$STATUS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
