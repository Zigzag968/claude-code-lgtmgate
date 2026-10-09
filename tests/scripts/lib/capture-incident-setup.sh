#!/usr/bin/env bash
# temp repo, run generator and the newrun/cap/jsq/expect_ok helpers (sourced by tests/scripts/test-capture-incident.sh, never executed).
. "$ROOT/tests/scripts/lib/harness.sh"
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

