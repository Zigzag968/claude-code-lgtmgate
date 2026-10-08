#!/usr/bin/env bash
# Self-test of scripts/capture-incident.cjs (+ its .sh wrapper), fully hermetic: the Workflow run
# is a SYNTHETIC one generated into a temp "projects" directory (CLAUDE_PROJECTS_DIR), the output
# goes to a temp git repo. The real Claude Code projects directory is never read.
#
# The generator composes only the key sets the reader whitelists (see the header of
# capture-incident.cjs). It proves the reader against that observed layout, not against Claude
# Code's live storage: the first real capture validates the layout, loudly.
#
# Cases: `ok: relaunch ...` (final pass identified by agentId, captured entries replayed),
# `ok: fail-closed ...` (each refusal names its cause and writes nothing), `ok: retried call ...` (a call the engine
# retried: folded under its engine label, or refused), `ok: usage ...`, `ok: buildStamp ...` (the run's own stamp decides which version-probe answer is tokenized).
# bash 3.2 compatible. Trailer: [test-capture-incident] status=<ok|fail> passed=<n> failed=<n>
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
TMP="${TMPDIR:-/tmp}/capture-incident-selftest.$$"
mkdir -p "$TMP"
TMP="$(cd "$TMP" && pwd -P)"
PROJ="$TMP/projects"
REPO="$TMP/repo"
OUTD="$REPO/captures"
CAP="$OUTD/181-t.json"
RUN=wf_test1

git init -q "$REPO"
printf '.pipeline/\ncaptures/\n' > "$REPO/.gitignore"
mkdir -p "$REPO/tracked"

cat > "$TMP/gen.cjs" <<'JS'
// node gen.cjs <projectsDir> <runId> <mutation> [session]
const fs = require('fs')
const path = require('path')
const [projectsDir, runId, mut, session = 'sess1'] = process.argv.slice(2)
const smoke = JSON.parse(fs.readFileSync(path.join(process.env.ROOT, 'fixtures/smoke/auto-lgtm.json'), 'utf8'))
const runDir = path.join(projectsDir, '-proj', session, 'subagents', 'workflows', runId)
const recFile = path.join(projectsDir, '-proj', session, 'workflows', runId + '.json')
fs.mkdirSync(runDir, { recursive: true })
fs.mkdirSync(path.dirname(recFile), { recursive: true })

// A real run journals the literal engine version in the plugin version probe answer (#195); the public smoke fixture
// quotes the token instead. liveversion: the run's engine is the repo's engine. oldrun: a run of an OLDER engine
// (root and answer 1.0.0-beta.3, cmd hash recomputed for that root). skewrun: a captured plugin-version-skew incident
// (the answer is the stale root's, the run ended on the skew). stamp*: the run record carries the engine's own
// `result.buildStamp` (#213) and a pluginRoot with no version segment: stampold (stamp and answer 1.0.0-beta.3), stampdiff (stamp
// 1.0.0-beta.7, the answer differs, result ready), stampskew (a skew incident: the answer 1.0.0-beta.3, stamp = this engine),
// stampbad (an unparseable stamp, root names 1.0.0-beta.3).
const VPROBE = 'probe-123-lines-plugin-version-r0'
const engineSrc = fs.readFileSync(path.join(process.env.ROOT, 'workflows/deliver-pipeline.js'), 'utf8')
const ENGINE = /const BUILD = \{[^}]*\bversion: '([^']+)'/.exec(engineSrc)[1]
const sha = (x) => require('crypto').createHash('sha256').update(x).digest('hex')
const cmdFor = (root) => {
  const blk = engineSrc.slice(engineSrc.indexOf('// --- pluginVersion:start ---'), engineSrc.indexOf('// --- pluginVersion:end ---'))
  return new Function(blk + '\nreturn pluginVersionCmd')()(root)
}
const OLDROOT = '/cache/lgtmgate/1.0.0-beta.3'
const live = {
  liveversion: [ENGINE, null], oldrun: ['1.0.0-beta.3', OLDROOT], skewrun: ['1.0.0-beta.3', OLDROOT],
  stampold: ['1.0.0-beta.3', '/main/checkout'], stampdiff: ['1.0.0-beta.3', '/main/checkout'],
  stampskew: ['1.0.0-beta.3', '/main/checkout'], stampbad: ['1.0.0-beta.3', OLDROOT],
}[mut]
const stampOf = (v) => '[pipeline] lgtmgate@' + v + ' cutFrom=abc1234 workflow=deliver-pipeline'
const STAMPS = { stampold: stampOf('1.0.0-beta.3'), stampdiff: stampOf('1.0.0-beta.7'), stampskew: stampOf(ENGINE), stampbad: 'garbage' }
if (live) {
  const [ver, root] = live
  const e = JSON.parse(JSON.stringify(smoke.calls[VPROBE]))
  for (const k of ['line', 'verify']) {
    e[k] = e[k].split('@@ENGINE_VERSION@@').join(ver)
    if (root) e[k] = e[k].replace(/cmd=[0-9a-f]{64}/, 'cmd=' + sha(cmdFor(root)))
  }
  smoke.calls[VPROBE] = e
  if (root) smoke.args.pluginRoot = root
}
const isSkew = mut === 'skewrun' || mut === 'stampskew'
if (isSkew) for (const l of Object.keys(smoke.calls)) if (l !== VPROBE) delete smoke.calls[l]

const rows = [{ type: 'launched' }]
const started = (agentId, key, label) => ({ type: 'started', agentId, key, label, phase: 'p' })
const result = (agentId, key, value) => ({ type: 'result', agentId, key, result: value })

// stale first pass (a relaunch): the same label with a DECOY value
rows.push(started('stale-1', 'v2:aaa111', 'diagnose-issue-123'))
rows.push(result('stale-1', 'v2:aaa111', { decoy: true }))
if (mut === 'earlierdied') rows.push(started('stale-2', 'v2:bbb222', 'scout-issue-123-1'))

// final pass
const final = Object.keys(smoke.calls).map((label, i) => ({ label, agentId: 'ag-' + i, key: 'v2:' + (1000 + i).toString(16), value: smoke.calls[label] }))
// A call the engine retried (#209), in the shape the engine really writes: the record holds ONE workflow_agent entry for the
// call, named '<label> (retry N)' and carrying the agentId of the LAST attempt; the journal holds N+1 `started` rows under
// ONE key, all labelled '<label>', the N earlier ones (died) without a result row. agentCount counts the record entries.
// Env: RDEAD = N, the died attempts journaled (default 1); RSFX = the suffix put on the record label (default ' (retry N)').
// retry: the scout call, retried. retrymulti: two retried calls (scout N, diagnose 2). retryrelaunch: an earlier pass of the
// run answered the same key with a decoy. retrynoid: the result row names no agentId. retryotherid: it names another one.
// retryalldied: no attempt answers. retryfailedlast: the key's last event is failed. retrydiff: the answering attempt's journal
// label is another call's. retrydeadlabel: a died attempt of the key has another label. retrylegit: a plain call whose engine
// label ends with '(retry 1)'. retrylegitfold: such a call, retried. retrytwin / retrytwinfirst: two calls of one engine
// label with their own keys, the second / the first retried. retrytwinshared: the same, the two calls share one key.
const extra = []
const SCOUT_LABEL = 'scout-issue-123-1'
if (mut.startsWith('retry')) {
  const nDead = Number(process.env.RDEAD || 1)
  const sfx = process.env.RSFX !== undefined ? process.env.RSFX : ' (retry ' + nDead + ')'
  const mark = (a, cnt, suffix) => {
    a.dead = Array.from({ length: cnt }, (_, i) => ({ agentId: 'ag-dead-' + a.agentId + '-' + i, key: a.key, label: a.label }))
    a.recLabel = a.label + suffix
  }
  const scout = final.find((a) => a.label === SCOUT_LABEL)
  if (!/^retry(legit|twin)/.test(mut)) mark(scout, nDead, sfx) // the legit and twin cases retry their own call only
  if (mut === 'retrymulti') mark(final.find((a) => a.label === 'diagnose-issue-123'), 2, ' (retry 2)')
  if (mut === 'retryrelaunch') rows.push(started('stale-r', scout.key, SCOUT_LABEL), result('stale-r', scout.key, { decoy: 'STALE' }))
  if (mut === 'retryalldied') scout.noResult = true
  if (mut === 'retrynoid') scout.resultNoId = true
  if (mut === 'retryotherid') scout.resultAgent = 'ag-other'
  if (mut === 'retryfailedlast') scout.failedAfter = true
  if (mut === 'retrydiff') scout.label = 'scout-issue-123-2'
  if (mut === 'retrydeadlabel') scout.dead[0].label = 'scout-issue-123-2'
  if (mut === 'retrylegit') extra.push({ label: 'decoy-retry (retry 1)', agentId: 'ag-l1', key: 'v2:l1', value: 'legit' })
  if (mut === 'retrylegitfold') {
    const l = { label: 'decoy-retry (retry 1)', agentId: 'ag-l1', key: 'v2:l1', value: 'legit' }
    mark(l, 1, ' (retry 1)')
    extra.push(l)
  }
  if (mut.startsWith('retrytwin')) {
    const t1 = { label: 'decoy-twin', agentId: 'ag-t1', key: 'v2:t1', value: 'first' }
    const t2 = { label: 'decoy-twin', agentId: 'ag-t2', key: mut === 'retrytwinshared' ? 'v2:t1' : 'v2:t2', value: 'second' }
    mark(mut === 'retrytwinfirst' || mut === 'retrytwinshared' ? t1 : t2, 1, ' (retry 1)')
    extra.push(t1, t2)
  }
}
if (mut === 'ordering') {
  extra.push({ label: 'decoy-repeat', agentId: 'ag-r1', key: 'v2:r1', value: 'first' })
  extra.push({ label: 'decoy-repeat', agentId: 'ag-r2', key: 'v2:r2', value: 'second' })
}
if (mut === 'arrayvalue') extra.push({ label: 'decoy-array', agentId: 'ag-a1', key: 'v2:a1', value: ['a', 'b'] })
const SCOUT = (final.find((a) => a.label === SCOUT_LABEL) || {}).agentId // by label: the smoke fixture's call order is not a contract
const progress = final.concat(extra)
const journalOrder = mut === 'ordering' ? final.concat(extra.slice().reverse()) : progress
for (const a of journalOrder) {
  for (const d of a.dead || []) rows.push(started(d.agentId, d.key, d.label)) // died attempts: no result row
  rows.push(started(a.agentId, a.key, a.label))
  if (a.failedOnly) rows.push({ type: 'failed', agentId: a.agentId, key: a.key })
  else if (!a.noResult) {
    const r = result(a.resultAgent || a.agentId, a.key, a.value)
    if (a.resultNoId) delete r.agentId
    rows.push(r)
    if (a.failedAfter) rows.push({ type: 'failed', agentId: a.agentId, key: a.key })
  }
}

const rec = {
  runId, status: 'completed', args: Object.assign({}, smoke.args, { simulate: { x: 1 } }),
  result: isSkew ? { status: 'escalate', reason: 'plugin-version-skew: the plugin root holds lgtmgate 1.0.0-beta.3 but this engine is ' + ENGINE + '; pass the current plugin root and relaunch' } : { status: 'ready' }, agentCount: progress.length,
  workflowProgress: [{ type: 'workflow_phase', title: 'p' }].concat(progress.map((a, i) => ({
    type: 'workflow_agent', index: i, label: a.recLabel || a.label, agentId: a.agentId, state: 'done',
  }))),
}
if (mut === 'cachedtrue') rec.workflowProgress[1].cached = true
if (STAMPS[mut]) rec.result.buildStamp = STAMPS[mut]

const lastResult = () => rows.map((r, i) => (r.type === 'result' && r.agentId === 'ag-' + (final.length - 1)) ? i : -1).filter((i) => i >= 0)[0]
switch (mut) {
  case 'unlabeled': { const r = rows.find((x) => x.type === 'started' && x.agentId === SCOUT); delete r.label; break }
  case 'orphan': rows.push(result('ag-x', 'v2:zzz', 'x')); break
  case 'unfinished': rows.splice(lastResult(), 1); break
  case 'failedonly': rows[lastResult()] = { type: 'failed', agentId: 'ag-' + (final.length - 1), key: final[final.length - 1].key }; break
  case 'badkey': { const r = rows.find((x) => x.type === 'started' && x.agentId === 'ag-2'); r.key = 'abc123'; break }
  case 'noargs': delete rec.args; break
  case 'killed': rec.status = 'killed'; break
  case 'countmismatch': rec.agentCount += 1; break
  case 'noresultstatus': rec.result = {}; break
  case 'noagentid': delete rec.workflowProgress[2].agentId; break
  // SCOUT (scout-issue-123-1, key K): the LAST event of K among result/failed rows decides.
  case 'failedlast': { // started old-3 K, result K OLD, started SCOUT K, failed K
    const si = rows.findIndex((x) => x.type === 'started' && x.agentId === SCOUT)
    const K = rows[si].key
    rows.splice(si, 2, started('old-3', K, rows[si].label), result('old-3', K, { decoy: 'OLD' }), rows[si], { type: 'failed', agentId: SCOUT, key: K })
    break
  }
  case 'failedafter': { // started SCOUT K, result K, failed K
    const si = rows.findIndex((x) => x.type === 'started' && x.agentId === SCOUT)
    rows.splice(si + 2, 0, { type: 'failed', agentId: SCOUT, key: rows[si].key })
    break
  }
  case 'failedretry': { // started SCOUT K, failed K, result K (a retry)
    const si = rows.findIndex((x) => x.type === 'started' && x.agentId === SCOUT)
    rows.splice(si + 1, 0, { type: 'failed', agentId: SCOUT, key: rows[si].key })
    break
  }
  default: break
}
if (mut !== 'nojournal') fs.writeFileSync(path.join(runDir, 'journal.jsonl'), rows.map((r) => JSON.stringify(r)).join('\n') + '\n')
if (mut !== 'norecord') fs.writeFileSync(recFile, JSON.stringify(rec))
JS
export ROOT

# newrun <mutation> [runId] [session]: a fresh synthetic projects dir + empty output dir
newrun() {
  rm -rf "$PROJ" "$OUTD" "$REPO/.pipeline"
  node "$TMP/gen.cjs" "$PROJ" "${2:-$RUN}" "$1" "${3:-sess1}"
}
# cap [args...]: run the capture from inside the temp repo; sets OUT (stdout+stderr) and RC
cap() {
  OUT=$(cd "$REPO" && CLAUDE_PROJECTS_DIR="$PROJ" bash "$ROOT/scripts/capture-incident.sh" "$@" 2>&1); RC=$?
}
# jsq <js expression over f>: evaluates against the captured file, prints the result as JSON
jsq() {
  node -e 'const f=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(JSON.stringify(eval(process.argv[2])))' "$CAP" "$1"
}
expect_ok() { # name; asserts a successful capture
  [ "$RC" -eq 0 ] && return 0
  bad "$1: exit $RC: $OUT"; return 1
}

# ---- positive: a relaunched run ---------------------------------------------------------------

newrun base
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "relaunch base"; then
  want=$(node -e 'process.stdout.write(JSON.stringify(require(process.env.ROOT+"/fixtures/smoke/auto-lgtm.json").calls["diagnose-issue-123"]))')
  got=$(jsq 'f.calls["diagnose-issue-123"]')
  nosim=$(jsq '"simulate" in f.args')
  mode=$(node -e 'process.stdout.write((require("fs").statSync(process.argv[1]).mode & 0o777).toString(8))' "$CAP")
  if [ "$got" = "$want" ] && [ "$nosim" = "false" ] && [ "$mode" = "600" ]; then
    ok "relaunch kept the final-pass entry (not the stale decoy), dropped args.simulate, file mode 600"
  else
    bad "relaunch final-pass entry: got=$got nosim=$nosim mode=$mode"
  fi
  case "$OUT" in *"[offline] status=ok"*) ok "relaunch capture replays status=ok";; *) bad "relaunch replay: $OUT";; esac
  case "$OUT" in *"unanswered call"*) bad "relaunch has an unanswered call: $OUT";; *) ok "relaunch no unanswered call";; esac
  case "$OUT" in *"next: scripts/publish-fixture.sh"*) ok "next step printed";; *) bad "no next step: $OUT";; esac
  NCALLS=$(node -e 'process.stdout.write(String(Object.keys(require(process.env.ROOT+"/fixtures/smoke/auto-lgtm.json").calls).length))')
  case "$OUT" in *"calls=$NCALLS cached=0"*) ok "relaunch cached absent is false (cached=0, calls=$NCALLS)";; *) bad "cached count: $OUT";; esac
  case "$(cat "$CAP")" in *cached*) bad "relaunch capture carries a cached key";; *) ok "relaunch capture carries no run metadata";; esac
fi

# ---- #195: the plugin version probe answer follows the engine version, never the version of the day ----
# A real run with a pluginRoot and no probeRunPath journals the LITERAL engine version in that answer; lead-merge bumps the
# version at every merge, so a literal kept in a fixture goes red at the next bump. The capture writes the token instead
# when the answer is the run's engine (the repo's BUILD, or the version the run's pluginRoot names).
bumped_engine() { # <out file>: the engine with another BUILD version
  node -e 'const fs=require("fs");const s=fs.readFileSync(process.env.ROOT+"/workflows/deliver-pipeline.js","utf8");fs.writeFileSync(process.argv[1],s.replace(/(const BUILD = \{[^}]*\bversion: \x27)[^\x27]+/,"$19.9.9-bumped"))' "$1"
}
BUMPED="$TMP/engine-bumped.js"
bumped_engine "$BUMPED"
vprobe() { # <js over the version probe entry e>: evaluates against the captured file
  node -e 'const f=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const e=f.calls["probe-123-lines-plugin-version-r0"];process.stdout.write(JSON.stringify(eval(process.argv[2])))' "$CAP" "$1"
}
newrun liveversion
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "live version"; then
  [ "$(vprobe 'e.line.includes("PLUGIN-VERSION:@@ENGINE_VERSION@@") && e.verify.includes("PLUGIN-VERSION:@@ENGINE_VERSION@@")')" = "true" ] && ok "live version: the version probe answer (line and verify) is the token in the capture" || bad "live version: token missing: $(vprobe 'e')"
  ENGV=$(node -e 'process.stdout.write(/const BUILD = \{[^}]*\bversion: \x27([^\x27]+)/.exec(require("fs").readFileSync(process.env.ROOT+"/workflows/deliver-pipeline.js","utf8"))[1])')
  case "$(cat "$CAP")" in *"PLUGIN-VERSION:$ENGV"*) bad "live version: the literal $ENGV is still in the capture";; *) ok "live version: no literal engine version left in the capture";; esac
  out=$(node scripts/run-offline.cjs "$CAP" --fp "$BUMPED" 2>&1 | tail -n 1)
  case "$out" in *"status=ok passed=1"*) ok "live version: the capture replays green against an engine whose version was bumped";; *) bad "live version: bumped replay: $out";; esac
  out=$(node scripts/run-offline.cjs "$CAP" 2>&1 | tail -n 1)
  case "$out" in *"status=ok passed=1"*) ok "live version: and against the engine of the repo";; *) bad "live version: replay: $out";; esac
  case "$OUT" in *" version-source=checkout retries="*) ok "buildStamp absent: the checkout BUILD rule still tokenizes (version-source=checkout)";; *) bad "no stamp, live version: summary: $OUT";; esac
fi

newrun oldrun
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "older run"; then
  [ "$(vprobe 'e.line.includes("PLUGIN-VERSION:@@ENGINE_VERSION@@")')" = "true" ] && ok "older run: the answer naming the run's pluginRoot version is the token (replays against today's engine)" || bad "older run: $(vprobe 'e')"
  case "$OUT" in *" version-source=pluginRoot retries="*) ok "buildStamp absent: the pluginRoot segment rule still tokenizes (version-source=pluginRoot)";; *) bad "no stamp, older run: summary: $OUT";; esac
fi

newrun skewrun
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "skew incident"; then
  [ "$(vprobe 'e.line.includes("PLUGIN-VERSION:1.0.0-beta.3") && !e.line.includes("@@")')" = "true" ] && ok "skew incident: the stale root's version stays literal (the incident is the difference)" || bad "skew incident: $(vprobe 'e')"
fi

# ---- #213: the run's own buildStamp decides which answer is the run's engine ----
# The run record's `result.buildStamp` is the engine's declaration of its version. When it carries one, it is the only
# authority: an answer equal to it is stored as the token (so a capture of an older engine's run replays against a later
# engine), an answer that differs stays literal (a real skew replays as a skew). Without a usable stamp, the checkout BUILD /
# pluginRoot rules above apply. The summary names the source, never an answer.
newrun stampold
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "stamp older run"; then
  [ "$(vprobe 'e.line.includes("PLUGIN-VERSION:@@ENGINE_VERSION@@") && e.verify.includes("PLUGIN-VERSION:@@ENGINE_VERSION@@")')" = "true" ] && ok "buildStamp equal to the answer: line and verify are the token (the root names no version)" || bad "stamp old: $(vprobe 'e')"
  case "$(cat "$CAP")" in *"1.0.0-beta.3"*) bad "buildStamp equal to the answer: the literal is still in the capture";; *) ok "buildStamp equal to the answer: no literal version left in the capture";; esac
  case "$OUT" in *"[offline] status=ok"*"version-source=stamp retries="*) ok "buildStamp equal to the answer: the capture replays its own capture, version-source=stamp";; *) bad "stamp old: summary: $OUT";; esac
  out=$(node scripts/run-offline.cjs "$CAP" --fp "$BUMPED" 2>&1 | tail -n 1)
  case "$out" in *"status=ok passed=1"*) ok "buildStamp older run replays green against a bumped engine";; *) bad "stamp old: bumped replay: $out";; esac
  out=$(node scripts/run-offline.cjs "$CAP" 2>&1 | tail -n 1)
  case "$out" in *"status=ok passed=1"*) ok "buildStamp older run replays green against the engine of the repo";; *) bad "stamp old: replay: $out";; esac
  summary=$(printf '%s\n' "$OUT" | grep '^\[capture-incident\] status=')
  ENGV=$(node -e 'process.stdout.write(/const BUILD = \{[^}]*\bversion: \x27([^\x27]+)/.exec(require("fs").readFileSync(process.env.ROOT+"/workflows/deliver-pipeline.js","utf8"))[1])')
  case "$summary" in *"1.0.0-beta.3"*|*"$ENGV"*|*"PLUGIN-VERSION"*) bad "buildStamp summary prints a version: $summary";; *"version-source=stamp"*) ok "buildStamp summary names the source and prints no answer";; *) bad "buildStamp summary: $summary";; esac
fi

newrun stampdiff
cap "$RUN" 181 t --out "$OUTD"
if [ "$RC" -eq 1 ] && [ -f "$CAP" ]; then
  case "$OUT" in *"[capture-incident] status=refused"*) ok "buildStamp different from the answer: the capture refuses its own replay (a skew vs the recorded ready)";; *) bad "stamp diff: no refusal: $OUT";; esac
  [ "$(vprobe 'e.line.includes("PLUGIN-VERSION:1.0.0-beta.3") && !e.line.includes("@@") && !e.verify.includes("@@")')" = "true" ] && ok "buildStamp different from the answer: the answer stays literal, the capture is kept" || bad "stamp diff: $(vprobe 'e')"
else
  bad "stamp diff: expected exit 1 with the capture kept, got exit $RC: $OUT"
fi

newrun stampskew
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "stamp skew incident"; then
  [ "$(vprobe 'e.line.includes("PLUGIN-VERSION:1.0.0-beta.3") && !e.line.includes("@@")')" = "true" ] && ok "buildStamp with a skew incident: the answer stays literal (the incident is the difference)" || bad "stamp skew: $(vprobe 'e')"
  [ "$(jsq 'f.expect.status')" = '"escalate"' ] && ok "buildStamp with a skew incident: the capture replays as the recorded escalate" || bad "stamp skew: expect $(jsq 'f.expect')"
  case "$OUT" in *" version-source=none retries="*) ok "buildStamp with a skew incident: version-source=none";; *) bad "stamp skew: summary: $OUT";; esac
fi

newrun stampbad
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "stamp unparseable"; then
  [ "$(vprobe 'e.line.includes("PLUGIN-VERSION:@@ENGINE_VERSION@@")')" = "true" ] && ok "buildStamp unparseable: falls back to the pluginRoot segment (token)" || bad "stamp bad: $(vprobe 'e')"
  case "$OUT" in *" version-source=pluginRoot retries="*) ok "buildStamp unparseable: version-source=pluginRoot";; *) bad "stamp bad: summary: $OUT";; esac
fi

newrun ordering
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "relaunch ordering"; then
  got=$(jsq 'f.calls["decoy-repeat"]')
  [ "$got" = '["first","second"]' ] && ok "relaunch order follows workflowProgress, not the journal ($got)" || bad "relaunch order: $got"
fi

newrun arrayvalue
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "relaunch array"; then
  got=$(jsq 'f.calls["decoy-array"]')
  [ "$got" = '[["a","b"]]' ] && ok "relaunch array result wrapped ($got)" || bad "relaunch array wrap: $got"
fi

newrun cachedtrue
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "relaunch cached"; then
  case "$OUT" in *"cached=1"*) ok "relaunch cached agents are counted";; *) bad "cached=1 expected: $OUT";; esac
fi

newrun earlierdied
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "relaunch earlier-pass"; then
  case "$OUT" in *"note:"*"died call scout-issue-123-1"*) ok "relaunch earlier-pass died call tolerated (note only)";; *) bad "earlier-pass note missing: $OUT";; esac
fi

newrun base
cap "$RUN" 181 t
if expect_ok "default out" && [ -f "$REPO/.pipeline/captures/181-t.json" ]; then
  ok "default out lands in .pipeline/captures"
else
  bad "default out: $OUT"
fi

# ---- fail-closed: every refusal names its cause and writes nothing ---------------------------

# refusal <case name> <mutation> <expected substring> [capture args...]
refusal() {
  name="$1"; mut="$2"; want="$3"; shift 3
  newrun "$mut"
  if [ "$#" -gt 0 ]; then cap "$@"; else cap "$RUN" 181 t --out "$OUTD"; fi
  if [ "$RC" -eq 1 ]; then
    case "$OUT" in
      *"$want"*) if [ -e "$CAP" ]; then bad "${KIND:-fail-closed} $name: a capture was written"; else ok "${KIND:-fail-closed} $name"; fi;;
      *) bad "${KIND:-fail-closed} $name: output does not name '$want': $OUT";;
    esac
  else
    bad "${KIND:-fail-closed} $name: expected exit 1, got $RC: $OUT"
  fi
}

refusal "journal missing" nojournal "journal.jsonl: missing file"
refusal "record missing" norecord "$RUN.json: missing file"
refusal "unlabeled started" unlabeled "missing label"
refusal "orphan result" orphan "orphan result for key v2:zzz"
refusal "unfinished started" unfinished "died call"
refusal "failed without result" failedonly "died call"
refusal "key prefix not v2" badkey "does not start with v2:"
refusal "record without args" noargs "missing args"
refusal "killed record" killed "status is killed"
refusal "agentCount mismatch" countmismatch "agentCount"
refusal "record without result.status" noresultstatus "missing result.status"
refusal "workflowProgress entry without agentId" noagentid "agentId"
refusal "out not ignored" base "is not ignored by git" "$RUN" 181 t --out "$REPO/tracked"
refusal "run not found" base "not found" wf_nothere 181 t --out "$OUTD"

# out outside any work tree (the ceiling keeps git from discovering a repository above the temp dir)
newrun base
mkdir -p "$TMP/nogit"
OUT=$(cd "$REPO" && GIT_CEILING_DIRECTORIES="$TMP" CLAUDE_PROJECTS_DIR="$PROJ" bash "$ROOT/scripts/capture-incident.sh" "$RUN" 181 t --out "$TMP/nogit/out" 2>&1); RC=$?
case "$OUT" in
  *"not inside a git work tree"*) if [ "$RC" -eq 1 ] && [ ! -e "$TMP/nogit/out" ]; then ok "fail-closed out outside a work tree"; else bad "fail-closed out outside a work tree: rc=$RC or out dir created"; fi;;
  *) bad "fail-closed out outside a work tree: $OUT";;
esac

# the same run id under two sessions is never guessed
newrun base
node "$TMP/gen.cjs" "$PROJ" "$RUN" base sess2
cap "$RUN" 181 t --out "$OUTD"
case "$OUT" in
  *"ambiguous"*) if [ "$RC" -eq 1 ] && [ ! -e "$CAP" ]; then ok "fail-closed ambiguous run"; else bad "fail-closed ambiguous run: rc=$RC or capture written"; fi;;
  *) bad "fail-closed ambiguous run: $OUT";;
esac

# a symlink at the output FILE is never followed (the guard proved the link path ignored, not its target)
# capsep [args...]: like cap, but stdout and stderr kept apart (OUT = stdout, ERR = stderr)
capsep() {
  OUT=$(cd "$REPO" && CLAUDE_PROJECTS_DIR="$PROJ" bash "$ROOT/scripts/capture-incident.sh" "$@" 2>"$TMP/stderr.txt"); RC=$?
  ERR=$(cat "$TMP/stderr.txt")
}
VICTIM="$REPO/tracked/victim.txt"
OUTSIDE="$TMP/outside.txt"
printf 'tracked content\n' > "$VICTIM"
git -C "$REPO" add tracked/victim.txt
git -C "$REPO" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -q -m init tracked/victim.txt
printf 'outside content\n' > "$OUTSIDE"
symlink_case() { # name link-target
  name="$1"; target="$2"
  printf 'tracked content\n' > "$VICTIM"; printf 'outside content\n' > "$OUTSIDE"; rm -f "$TMP/does-not-exist.txt"
  newrun base
  mkdir -p "$OUTD"
  ln -s "$target" "$CAP"
  before=$(cksum < "$VICTIM")$(cksum < "$OUTSIDE")
  cap "$RUN" 181 t --out "$OUTD"
  after=$(cksum < "$VICTIM")$(cksum < "$OUTSIDE")
  case "$OUT" in
    *"refused:"*"$CAP"*"symlink"*"status=refused"*)
      if [ "$RC" -eq 1 ] && [ "$before" = "$after" ] && [ -L "$CAP" ]; then ok "fail-closed $name"; else bad "fail-closed $name: rc=$RC target changed or link replaced"; fi;;
    *) bad "fail-closed $name: output does not refuse the symlink: rc=$RC $OUT";;
  esac
}
symlink_case "output file symlinked to a tracked file" "../tracked/victim.txt"
symlink_case "output file symlinked outside the repo" "$OUTSIDE"
symlink_case "output file dangling symlink" "$TMP/does-not-exist.txt"
[ ! -e "$TMP/does-not-exist.txt" ] && ok "fail-closed dangling symlink target not created" || bad "fail-closed dangling symlink target was created"

# a HARD LINK at the output file is a regular file whose inode is shared: truncating it would
# overwrite the other path (a tracked file, a file outside the repo). The descriptor is checked
# (nlink === 1) before anything is written.
hardlink_case() { # name link-source
  name="$1"; source="$2"
  printf 'tracked content\n' > "$VICTIM"; printf 'outside content\n' > "$OUTSIDE"
  newrun base
  mkdir -p "$OUTD"
  ln "$source" "$CAP"
  before=$(cksum < "$VICTIM")$(cksum < "$OUTSIDE")
  cap "$RUN" 181 t --out "$OUTD"
  after=$(cksum < "$VICTIM")$(cksum < "$OUTSIDE")
  dirty=$(git -C "$REPO" status --porcelain -- tracked/victim.txt)
  last=$(printf '%s\n' "$OUT" | tail -n 1)
  case "$OUT" in
    *"refused:"*"$CAP"*"more than one hard link"*)
      if [ "$RC" -eq 1 ] && [ "$last" = "[capture-incident] status=refused" ] && [ "$before" = "$after" ] && [ -z "$dirty" ]; then
        ok "fail-closed $name"
      else
        bad "fail-closed $name: rc=$RC last='$last' target changed or git dirty='$dirty'"
      fi;;
    *) bad "fail-closed $name: output does not refuse the hard link: rc=$RC target-changed=$([ "$before" = "$after" ] && echo no || echo YES) $OUT";;
  esac
}
hardlink_case "output file hard link to a tracked file" "$VICTIM"
hardlink_case "output file hard link to a file outside the repo" "$OUTSIDE"

# a FIFO at the output file must not hang the script (open(O_WRONLY) blocks without a reader)
newrun base
mkdir -p "$OUTD"
mkfifo "$CAP"
rm -f "$TMP/fifo.rc"
( cd "$REPO" && CLAUDE_PROJECTS_DIR="$PROJ" bash "$ROOT/scripts/capture-incident.sh" "$RUN" 181 t --out "$OUTD" >"$TMP/fifo.out" 2>&1; echo $? > "$TMP/fifo.rc" ) &
FIFO_PID=$!
tries=0
while [ ! -f "$TMP/fifo.rc" ] && [ "$tries" -lt 50 ]; do sleep 0.2; tries=$((tries+1)); done
if [ -f "$TMP/fifo.rc" ]; then
  wait "$FIFO_PID" 2>/dev/null
  RC=$(cat "$TMP/fifo.rc"); OUT=$(cat "$TMP/fifo.out"); last=$(printf '%s\n' "$OUT" | tail -n 1)
  case "$OUT" in
    *"refused:"*"$CAP"*"not a regular file"*)
      if [ "$RC" -eq 1 ] && [ "$last" = "[capture-incident] status=refused" ]; then ok "fail-closed output file is a FIFO"; else bad "fail-closed output file is a FIFO: rc=$RC last='$last'"; fi;;
    *) bad "fail-closed output file is a FIFO: output does not refuse it: rc=$RC $OUT";;
  esac
else
  # hung: hold the FIFO open read-write for a moment (a stray blocked open succeeds against it) until the job ends
  tries=0
  while [ ! -f "$TMP/fifo.rc" ] && [ "$tries" -lt 10 ]; do ( exec 9<>"$CAP"; sleep 1 ); tries=$((tries+1)); done
  bad "fail-closed output file is a FIFO: the script was still blocked after 10 s (hang)"
fi

# a pre-existing REGULAR single-link ignored file is still overwritten (and fully truncated)
newrun base
mkdir -p "$OUTD"
node -e 'process.stdout.write("x".repeat(200000))' > "$CAP"
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "overwrite regular file" && [ "$(jsq 'f.name')" = '"181-t"' ]; then
  ok "output file regular single-link ignored file is overwritten and truncated"
else
  bad "output file regular overwrite: rc=$RC $OUT"
fi

# a failed call whose LAST event for its key is `failed` is refused, even with an earlier result for that key
SCOUT_KEY=$(node -e 'const l=Object.keys(require(process.env.ROOT+"/fixtures/smoke/auto-lgtm.json").calls);process.stdout.write("v2:"+(1000+l.indexOf("scout-issue-123-1")).toString(16))') # same key rule as gen.cjs
failed_refusal() { # name mutation
  refusal "$1" "$2" "failed call scout-issue-123-1 key $SCOUT_KEY"
}
failed_refusal "failed after an earlier pass result" failedlast
failed_refusal "failed after its own result" failedafter

newrun failedretry
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "relaunch failed-then-result"; then
  want=$(node -e 'process.stdout.write(JSON.stringify(require(process.env.ROOT+"/fixtures/smoke/auto-lgtm.json").calls["scout-issue-123-1"]))')
  got=$(jsq 'f.calls["scout-issue-123-1"]')
  [ "$got" = "$want" ] && ok "relaunch failed then a later result (retry) keeps the later result" || bad "relaunch retry: got=$got"
fi

# ---- #209: a call the engine retried is captured once, under its engine label ----------------------------
# The engine's real shape (see the generator): ONE record entry '<label> (retry N)' with the agentId of the last attempt; the
# journal holds N+1 `started` rows '<label>' under one key, the N earlier ones without a result. The capture holds one entry per
# engine label with the answer of the record's agentId, retries=<sum of N>, and refuses everything it cannot attribute.
SMOKE_SC=$(node -e 'process.stdout.write(JSON.stringify(require(process.env.ROOT+"/fixtures/smoke/auto-lgtm.json").calls["scout-issue-123-1"]))')
SMOKE_DG=$(node -e 'process.stdout.write(JSON.stringify(require(process.env.ROOT+"/fixtures/smoke/auto-lgtm.json").calls["diagnose-issue-123"]))')
SMOKE_N=$(node -e 'process.stdout.write(String(Object.keys(require(process.env.ROOT+"/fixtures/smoke/auto-lgtm.json").calls).length))')
retry_fold() { # name mutation expected-retries expected-note-substring
  newrun "$2"
  cap "$RUN" 181 t --out "$OUTD"
  if expect_ok "retried call $1"; then
    got=$(jsq 'f.calls["scout-issue-123-1"]')
    n=$(jsq 'Object.keys(f.calls).filter((k) => k.indexOf("scout-issue-123") === 0).length')
    nwant=$(node -e 'process.stdout.write(String(Object.keys(require(process.env.ROOT+"/fixtures/smoke/auto-lgtm.json").calls).filter((k) => k.indexOf("scout-issue-123") === 0).length))')
    last=$(printf '%s\n' "$OUT" | /usr/bin/grep 'status=ok out=')
    if [ "$got" = "$SMOKE_SC" ] && [ "$n" = "$nwant" ] && ! /usr/bin/grep -q '(retry' "$CAP" \
       && case "$last" in *" retries=$3") true;; *) false;; esac \
       && case "$OUT" in *"$4"*"[offline] status=ok"*) true;; *) false;; esac; then
      ok "retried call $1: captured once under its engine label, retries=$3, replays"
    else
      bad "retried call $1: got=$got entries=$n/$nwant last='$last' out=$OUT"
    fi
  fi
}
retry_fold "one retry (two journal starts under one key, one result)" retry 1 "folded retried call scout-issue-123-1: 2 attempts, answer of agentId ag-"
# the answering attempt is the record's agentId, the died one is named in the note
newrun retry
cap "$RUN" 181 t --out "$OUTD"
SCA=$(node -e 'const l=Object.keys(require(process.env.ROOT+"/fixtures/smoke/auto-lgtm.json").calls);process.stdout.write("ag-"+l.indexOf("scout-issue-123-1"))')
case "$OUT" in
  *"answer of agentId $SCA used, died attempt ag-dead-$SCA-0 [line "*) ok "retried call: the note names the answering agentId (the record's) and the died attempt";;
  *) bad "retried call note attribution: want answer $SCA died ag-dead-$SCA-0: $OUT";;
esac
RDEAD=3 retry_fold "three retries (retry 3: three died starts)" retry 3 "4 attempts"
RDEAD=12 retry_fold "two-digit N (retry 12)" retry 12 "folded retried call"
RDEAD=999 retry_fold "N at the upper bound (retry 999)" retry 999 "folded retried call"
retry_fold "an earlier pass answered the same key with a decoy, the record's agentId decides" retryrelaunch 1 "answer of agentId ag-"
case "$OUT" in
  *"stale-r [line"*) bad "retried call: the note names an earlier pass's ANSWERED attempt as died: $OUT";;
  *"died attempt ag-dead-$SCA-0 [line "*) ok "retried call: an earlier pass's answered attempt on the same key is not named as died";;
  *) bad "retried call: died attempt not named in the relaunch case: $OUT";;
esac
retry_fold "the result row names no agentId (joined by key)" retrynoid 1 "folded retried call"
# two retried calls in one run: retries sums N (1 + 2), one entry per call
newrun retrymulti
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "retried call two calls"; then
  last=$(printf '%s\n' "$OUT" | /usr/bin/grep 'status=ok out=')
  if [ "$(jsq 'f.calls["scout-issue-123-1"]')" = "$SMOKE_SC" ] && [ "$(jsq 'f.calls["diagnose-issue-123"]')" = "$SMOKE_DG" ] \
     && [ "$(jsq 'Object.keys(f.calls).length')" = "$SMOKE_N" ] && case "$last" in *" calls=$SMOKE_N "*" retries=3") true;; *) false;; esac; then
    ok "retried call two retried calls in one run: retries=3 (N summed, not one per call), one entry each"
  else
    bad "retried call two calls: last='$last'"
  fi
fi
# a legitimate engine label ending with (retry 1), in journal and record alike, is captured as is (the journal is the authority)
newrun retrylegit
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "retried call legit label"; then
  last=$(printf '%s\n' "$OUT" | /usr/bin/grep 'status=ok out=')
  if [ "$(jsq 'f.calls["decoy-retry (retry 1)"]')" = '"legit"' ] && [ "$(jsq '"decoy-retry" in f.calls')" = "false" ] \
     && case "$last" in *" retries=0") true;; *) false;; esac; then
    ok "retried call: a label that ends with (retry 1) in journal and record is kept as is, retries=0"
  else
    bad "retried call legit label: last='$last' keys=$(jsq 'Object.keys(f.calls).filter((k) => k.indexOf("decoy") === 0)')"
  fi
fi
# ... and when that same call was retried, only the engine suffix is folded
newrun retrylegitfold
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "retried call legit label retried"; then
  last=$(printf '%s\n' "$OUT" | /usr/bin/grep 'status=ok out=')
  if [ "$(jsq 'f.calls["decoy-retry (retry 1)"]')" = '"legit"' ] && case "$last" in *" retries=1") true;; *) false;; esac; then
    ok "retried call: a retried call whose label ends with (retry 1) folds the last suffix only (retries=1)"
  else
    bad "retried call legit label retried: last='$last'"
  fi
fi
# two calls of one engine label: attributed by agentId and key, in record order, never guessed
twin_case() { # name mutation
  newrun "$2"
  cap "$RUN" 181 t --out "$OUTD"
  if expect_ok "retried call $1"; then
    last=$(printf '%s\n' "$OUT" | /usr/bin/grep 'status=ok out=')
    if [ "$(jsq 'f.calls["decoy-twin"]')" = '["first","second"]' ] && case "$last" in *" retries=1") true;; *) false;; esac; then
      ok "retried call $1: both answers kept in record order, the retry attributed by agentId and key"
    else
      bad "retried call $1: twin=$(jsq 'f.calls["decoy-twin"]') last='$last'"
    fi
  fi
}
twin_case "two calls of one label, the second retried" retrytwin
twin_case "two calls of one label, the first retried" retrytwinfirst
KIND="retried call"
refusal "two calls of one label sharing a key, one retried (ambiguous)" retrytwinshared "ambiguous retried call"
refusal "journal label of the answer is another call's" retrydiff 'journal "scout-issue-123-2", record "scout-issue-123-1 (retry 1)"'
refusal "a died attempt of the key has another label" retrydeadlabel "label mismatch on key $SCOUT_KEY"
refusal "no attempt answers" retryalldied "died call scout-issue-123-1 key $SCOUT_KEY"
refusal "the key's last event is failed" retryfailedlast "failed call scout-issue-123-1 key $SCOUT_KEY"
refusal "result rows name other attempts only" retryotherid "no result row of agentId"
# N is checked against the died attempts of the key, never guessed
RDEAD=1 RSFX=' (retry 2)' refusal "N above the died attempts (retry 2, one died)" retry "retry count mismatch"
RDEAD=2 RSFX=' (retry 1)' refusal "N below the died attempts (retry 1, two died)" retry "retry count mismatch"
RDEAD=0 RSFX=' (retry 1)' refusal "retry suffix on a call with no died attempt" retry "retry count mismatch"
# the suffix is exactly ' (retry N)': N 1-999 without leading zero, one space before, nothing after, case-sensitive
sfx_refusal() { # suffix
  RDEAD=1 RSFX="$1" refusal "suffix <$(printf '%q' "$1")>" retry "label mismatch for agentId"
}
sfx_refusal ' (retry)'
sfx_refusal ' (retry )'
sfx_refusal ' (retry 0)'
sfx_refusal ' (retry 01)'
sfx_refusal ' (retry -1)'
sfx_refusal ' (retry +1)'
sfx_refusal ' (retry 1.0)'
sfx_refusal ' (retry 1e0)'
sfx_refusal ' (retry  1)'
sfx_refusal ' (Retry 1)'
sfx_refusal ' (RETRY 1)'
sfx_refusal ' (retried 1)'
sfx_refusal ' (retry 1) '
sfx_refusal $' (retry 1)\t'
sfx_refusal $' (retry 1)\n'
sfx_refusal '  (retry 1)'
sfx_refusal '(retry 1)'
sfx_refusal ' (retry 1) (retry 1)'
sfx_refusal ' (retry 1000)'
sfx_refusal ' (retry 99999999999999999999)'
# the other retry suffixes of the engine are not folded (out of #209): they refuse as a label mismatch
sfx_refusal ' (throttle-retry)'
sfx_refusal ' (after usage limit)'
KIND=

# unexpected file-system errors end as a status line, never a stack trace
error_case() { # name; asserts the result of the last capsep
  name="$1"
  last=$(printf '%s\n' "$OUT" | tail -n 1)
  stack=$(printf '%s\n' "$ERR" | grep -cE '^[[:space:]]+at |node:internal' || true)
  left=$(ls -A "$OUTD" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$RC" -eq 1 ] && [ "$last" = "[capture-incident] status=error" ] && [ "$stack" = "0" ] && [ "$left" = "0" ] \
     && printf '%s\n' "$ERR" | grep -q '^error: [A-Z]'; then
    ok "error $name: status=error, one stderr line, no stack, nothing written"
  else
    bad "error $name: rc=$RC last='$last' stack=$stack left=$left err=$ERR"
  fi
}
newrun base
mkdir -p "$OUTD"; chmod 500 "$OUTD"
capsep "$RUN" 181 t --out "$OUTD"
chmod 700 "$OUTD"
error_case "read-only output directory"
LONG=$(printf 'a%.0s' $(seq 1 300))
newrun base
mkdir -p "$OUTD"
capsep "$RUN" 181 "$LONG" --out "$OUTD"
error_case "300-character label"

# ---- usage errors (exit 2, before any filesystem access) ---------------------------------------

usage_case() { # name expected-substring args...
  name="$1"; want="$2"; shift 2
  cap "$@"
  case "$OUT" in
    *"$want"*"status=usage-error"*) [ "$RC" -eq 2 ] && ok "usage $name" || bad "usage $name: exit $RC";;
    *) bad "usage $name: $OUT";;
  esac
}
usage_case "bad runId" "runId" '../x' 181 t --out "$OUTD"
usage_case "bad issue" "issue" "$RUN" 12a t --out "$OUTD"
usage_case "bad label" "label" "$RUN" 181 Up --out "$OUTD"
usage_case "unknown flag" "--force" "$RUN" 181 t --force
usage_case "flag without value" "--out" "$RUN" 181 t --out

rm -rf "$TMP"
STATUS=ok; [ "$FAIL" -gt 0 ] && STATUS=fail
echo "[test-capture-incident] status=$STATUS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
