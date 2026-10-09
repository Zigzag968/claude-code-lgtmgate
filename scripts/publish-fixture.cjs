#!/usr/bin/env node
'use strict'

// Publish a PRIVATE raw capture as a minimized, redacted, public fixture (E3.10, #189).
//
// Input: a raw capture written by scripts/capture-incident.cjs (fixture format of run-offline.cjs:
// name, args, calls, expect). Output: fixtures/incidents/<issue>-<label>.json, written to a temporary file next to it,
// fsynced, then linked at its name (the link fails if the name exists: an existing file is never overwritten, and a kill
// never leaves a partial file at the final name), only after every step below held. SIGINT and SIGTERM remove the
// temporary files and end with `status=error`; SIGKILL cannot be handled and may leave a hidden `.<name>.json.tmp-*` file.
//
// Usage:
//   node scripts/publish-fixture.cjs <raw capture> [<out name>] [--out-dir DIR] [--fp FILE]
//     <out name>  [0-9]+-[a-z0-9-]+ (default: the capture's file name); the file is <out-dir>/<out name>.json
//     --out-dir   default <repo>/fixtures/incidents (must exist)
//     --fp        engine file to replay against (default workflows/deliver-pipeline.js, same flag as run-offline.cjs)
// Last stdout line (always): `[publish-fixture] status=<ok|refused|error|usage-error>` (ok adds `out=<path>`).
// Exit 0 ok, 1 refused or error, 2 usage. A refusal prints `refused: <cause>` on stderr (never a value) and writes nothing.
//
// What it does, in order (each failure is a refusal):
//   1. the output file must not exist; the capture must be a plain fixture (name, args, calls, expect only).
//   2. BASELINE: the capture is replayed three times in process against the real engine. The OUTCOME it must keep
//      is the status, the reason, the full trace, the ordered agent() call labels, the ordered engine call SITES
//      (every log(), phase() and agent() call, by line and column of the engine body), the FORM of the rest of the
//      result (its keys, array lengths, numbers, booleans and nulls exactly; a string only as empty or not) and the
//      number of log lines. Free text of the result stays
//      out of the oracle (nothing could be neutralized otherwise). The three replays must agree.
//   3. MINIMIZE: every string value of args and calls is replaced by a typed neutral token (zeros for a hash, `1`
//      for a number, `_` otherwise), one at a time in JSON order, and the replacement is kept only if the outcome
//      stays identical. Then, for a multi-line string that is still not neutral, each line to `_`. Passes repeat
//      to a fixpoint (3 at most). PROTECTED_ARGS are never neutralized; nothing else is exempt, a single-word value
//      included (a private first name or password can equal a literal of the engine file). A weak oracle (status plus trace) silently
//      drops behaviour (probes became placeholders and the engine took fail-open paths), hence the strict one.
//      The sites and the ordered labels pin the engine's path: every agent() call resolves to one site (callAgent),
//      so the labels carry the order of the agents, and the log and phase sites carry the path through the engine.
//   3b. ENGINE VERSION (#195): the answer of the plugin version probe that names the engine under test (its BUILD version)
//      is stored as the token `@@ENGINE_VERSION@@` before the baseline, and so is that version in a published
//      `plugin-version-*` reason: lead-merge bumps the version at every merge, a literal would go red at the next one. The
//      replay resolves the token to the same string, so the outcome is unchanged; the answer of a stale root stays literal.
//   4. COUPLED PROBES: a `probe-*` answer whose `cmd=` hash is the SHA-256 of the command the engine composed is
//      re-hashed after every change of args (the command is parsed from the prompt the engine already builds).
//   5. scripts/redact-fixture.cjs (exit 3 refuses on residue), re-hash, `--check`, a strict replay (in process, then
//      run-offline.cjs with OFFLINE_STRICT=1): the outcome must still be the baseline's.
//   6. the entries of `calls` the final replay never consumed are dropped, the file is written, and what remains is
//      printed as JSON paths and character counts, never values: kept strings (free text flagged: plan lines, paths,
//      protected fields with a path, PROBE / VERIFY lines whose `json=` payload holds a space or a path separator, and
//      the published expect.reason), then the number of key names and non-string scalars kept as they are (never
//      neutralized) and the number of entries pruned. The report counts what it flags; it does not judge it.
// The published `expect` is built from the baseline: status, reason (if any), trace with traceExact, callLabels.
// Nothing here calls a model, the network or the Claude Code projects directory.

const fs = require('fs')
const os = require('os')
const path = require('path')
const crypto = require('crypto')
const { spawnSync } = require('child_process')
const { stripExports, buildPipelineRunner, replayFixture, tokenizeVersionProbes, ENGINE_VERSION_TOKEN } = require('./run-offline.cjs')

const REPO = path.resolve(__dirname, '..')
const NAME_RE = /^[0-9]+-[a-z0-9][a-z0-9-]*(\.json)?$/
const USAGE = 'usage: node scripts/publish-fixture.cjs <raw capture> [<out name>] [--out-dir DIR] [--fp FILE]'
const MAX_REPLAYS = 50000
const MAX_PASSES = 3
const BASELINE_REPLAYS = 3
const MAX_REHASH = 8

// Args the engine validates or branches on as an enum or a switch. The oracle cannot always see them (a `_` in
// `proceedThrough` or `issueType` leaves a nominal run identical), so they are never neutralized. A new enum or
// switch arg in the engine must be added here. Dotted paths from the args root (a path protects its whole subtree,
// array elements included); anchors in workflows/deliver-pipeline.js:
const PROTECTED_ARGS = [
  'mode', // run mode, the flow selector
  'entryStage', // 'plan' | 'dev' | 'review', validated at the top of the body
  'proceedThrough', // gate(): the last stage the Lead authorized
  'issueType', // 'bug' selects the R2 fixture item
  'resumeReason', // null | 'mergeable-conflicting', validated
  'planFreshness', // 'advisory' | 'gate' | 'off', validated
  'config.planFreshness', // same, project default
  'config.preflight.envSymlink', // 'required' | 'forbidden' | 'ignore', validated
  'config.oneWayDoorKinds', // R3: the kinds (status|agent|hook|seam) Sam announces; read by oneWayDoorKindsOf
  'config.oneWayDoorPaths', // R3: the paths/globs of targetFiles that stop the run at the design step
  'probeOnly.name', // the probe-run parser the probe is routed to (`--parser <name>`)
]

class Refusal extends Error {
  constructor(message, detail) { super(message); this.detail = detail || [] }
}
class Usage extends Error {}

const refuse = (message, detail) => { throw new Refusal(message, detail) }
const usage = (message) => { throw new Usage(message) }
const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v)
const sha256 = (s) => crypto.createHash('sha256').update(s, 'utf8').digest('hex')

// ---- arguments ------------------------------------------------------------------------------

function parseArguments(argv) {
  const out = { positional: [], outDir: null, fp: null }
  for (let index = 0; index < argv.length; index++) {
    const a = argv[index]
    if (a === '--out-dir' || a === '--fp') {
      if (index + 1 >= argv.length || argv[index + 1].startsWith('--')) usage(`${a} needs a value`)
      out[a === '--fp' ? 'fp' : 'outDir'] = argv[++index]
    } else if (a.startsWith('--')) {
      usage(`unknown flag ${a}`)
    } else {
      out.positional.push(a)
    }
  }
  if (out.positional.length < 1 || out.positional.length > 2) usage('expected <raw capture> [<out name>]')
  const capture = path.resolve(out.positional[0])
  const rawName = out.positional[1] !== undefined ? out.positional[1] : path.basename(capture)
  if (!NAME_RE.test(rawName)) usage(`out name must match ${NAME_RE.source}`)
  return {
    capture,
    outName: rawName.replace(/\.json$/, ''),
    outDir: path.resolve(out.outDir || path.join(REPO, 'fixtures', 'incidents')),
    fp: path.resolve(out.fp || path.join(REPO, 'workflows', 'deliver-pipeline.js')),
  }
}

// ---- the capture ------------------------------------------------------------------------------

function loadCapture(file) {
  let text
  try { text = fs.readFileSync(file, 'utf8') } catch (error) { refuse(`cannot read the raw capture (${(error && error.code) || 'error'})`) }
  let c
  try { c = JSON.parse(text) } catch (error) { refuse('the raw capture is not valid JSON') }
  if (!isObject(c)) refuse('the raw capture is not a JSON object')
  const extra = Object.keys(c).filter((k) => !['name', 'args', 'calls', 'expect'].includes(k))
  if (extra.length) refuse(`the raw capture has key(s) outside name, args, calls, expect: ${extra.join(', ')}`)
  if (!isObject(c.args)) refuse('the raw capture has no args object')
  if (Object.prototype.hasOwnProperty.call(c.args, 'simulate')) refuse('the raw capture sets args.simulate')
  if (!isObject(c.calls)) refuse('the raw capture has no calls object')
  if (!isObject(c.expect) || typeof c.expect.status !== 'string' || !c.expect.status) refuse('the raw capture has no expect.status')
  if (Object.prototype.hasOwnProperty.call(c.expect, 'throws')) refuse('the raw capture sets expect.throws (an arg-validation refusal has nothing to minimize)')
  return c
}

// ---- result shape ------------------------------------------------------------------------------

// The FORM of a value, with no free text: keys, array lengths, numbers, booleans and null exactly; a string only
// as empty / non-empty.
function shapeOf(v) {
  if (v === null) return ['0']
  if (v === undefined) return ['u']
  if (typeof v === 'string') return v === '' ? ['s', ''] : ['s', '~']
  if (typeof v === 'number') return ['n', String(v)]
  if (typeof v === 'boolean') return ['b', v]
  if (Array.isArray(v)) return ['a', v.map((x) => shapeOf(x))]
  if (isObject(v)) return ['o', Object.keys(v).sort().map((k) => [k, shapeOf(v[k])])]
  return ['?', typeof v]
}

// ---- probe prompts ------------------------------------------------------------------------------

// The command a probe prompt asks the probe agent to run: the text between ` --cmd ` and `\n2. cd `, un-quoted
// from `'...'` (`'\''` is one quote). Plain indexOf parsing of the prompt the engine builds (probeCommands).
function commandOfPrompt(prompt) {
  if (typeof prompt !== 'string') return null
  const end = prompt.indexOf('\n2. cd ')
  if (end < 0) return null
  // #338: the base64 form carries the same command as one bare token
  const b64 = prompt.indexOf(' --cmd-b64 ')
  if (b64 >= 0 && b64 < end) return Buffer.from(prompt.slice(b64 + 11, end), 'base64').toString('utf8')
  const start = prompt.indexOf(' --cmd ')
  if (start < 0 || start > end) return null
  const q = prompt.slice(start + 7, end)
  if (q.length < 2 || q[0] !== "'" || q[q.length - 1] !== "'") return null
  return q.slice(1, -1).split("'\\''").join("'")
}

// The fixed words of a PROBE / VERIFY answer line before its `json=` payload (see templates/probe-run.cjs).
const PROBE_ENVELOPE_TOKEN = /^(PROBE|VERIFY|ok|fail|line=PROBE|name=[A-Za-z0-9._-]+|exit=-?\d+|sha=[0-9a-f]+|cmd=[0-9a-f]+|reason=[A-Za-z0-9._-]+)$/

const CMD_RE = /cmd=([0-9a-f]{64})/
const firstCommandHash = (s) => { const m = CMD_RE.exec(s); return m ? m[1] : null }
const setCommandHash = (s, h) => s.replace(CMD_RE, `cmd=${h}`)

// ---- leaves and neutral tokens -------------------------------------------------------------

function collectLeaves(root, rootName) {
  const out = []
  const walk = (node, segs, parent, key) => {
    if (typeof node === 'string') out.push({ parent, key, segs })
    else if (Array.isArray(node)) node.forEach((v, index) => walk(v, [...segs, index], node, index))
    else if (isObject(node)) for (const k of Object.keys(node)) walk(node[k], [...segs, k], node, k)
  }
  walk(root, [rootName], null, null)
  return out
}

const pathOf = (segs) => segs.reduce((accumulator, s, index) => (index === 0 ? String(s) : typeof s === 'number' ? `${accumulator}[${s}]` : `${accumulator}.${s}`), '')

function neutralOf(v) {
  if (/^[0-9a-f]{32,}$/.test(v)) return '0'.repeat(v.length)
  if (/^-?\d+$/.test(v)) return '1'
  return '_'
}
const isNeutral = (v) => v === '' || neutralOf(v) === v

function isProtected(segs) {
  if (segs[0] !== 'args') return false
  const dotted = segs.slice(1).join('.')
  return PROTECTED_ARGS.some((p) => dotted === p || dotted.startsWith(`${p}.`))
}

// ---- redaction and strict replay (the sanctioned spawns) --------------------------------------

function runNode(arguments_, environment) {
  return spawnSync(process.execPath, arguments_, { cwd: REPO, encoding: 'utf8', env: environment || process.env })
}

// ---- main -----------------------------------------------------------------------------------

let createdOut = null // set once the output name is linked, so an unexpected error can remove it
let temporaryOut = null // the temporary file next to the target, removed on any end
let temporaryDirectoryOut = null // the private directory of the redaction copy, removed on any end
let finished = false // the publication is complete: a late signal changes nothing

// One turn of the event loop, so that a pending SIGINT / SIGTERM is handled between two steps (the replays and the write
// are otherwise a single uninterrupted run of microtasks and synchronous calls).
const turn = () => new Promise((resolve) => setImmediate(resolve))

// SIGINT / SIGTERM: remove our temporary file and directory, end with the usual status line. A signal that arrives inside a
// synchronous step (a spawned redactor, the final link) is handled at the next turn, after that step. SIGKILL cannot be
// handled: a hidden `.<name>.json.tmp-*` file may remain in the output directory (never a partial file at the final name).
function onSignal(sig) {
  if (finished) return
  if (temporaryOut) { try { fs.unlinkSync(temporaryOut) } catch (error) { /* already gone */ } }
  if (temporaryDirectoryOut) { try { fs.rmSync(temporaryDirectoryOut, { recursive: true, force: true }) } catch (error) { /* best effort */ } }
  process.stderr.write(`error: interrupted by ${sig}\n`)
  process.stdout.write('[publish-fixture] status=error\n')
  process.exit(1)
}

// The comparable outcome of a replay; null when the replay is not a clean run. Status, reason and trace exactly,
// the ordered agent() labels, the engine call sites, the form of the rest of the result and the number of log lines.
const oracleOf = (r) => {
  if (r.error || r.missing.length || !r.result || typeof r.result !== 'object') return null
  const rest = {}
  for (const k of Object.keys(r.result)) if (!['status', 'reason', 'trace'].includes(k)) rest[k] = r.result[k]
  return JSON.stringify([
    r.result.status === undefined ? null : r.result.status,
    r.result.reason === undefined ? null : r.result.reason,
    Array.isArray(r.result.trace) ? r.result.trace : [],
    r.calls.map((c) => c.label),
    r.sites,
    shapeOf(rest),
    r.logs.length,
  ])
}

// The session holds what the steps share: the engine runner, the replay budget, the candidate, the baseline outcome, the coupled keys, the journal.
function newSession(run, raw, outName) {
  const cand = { name: outName, args: JSON.parse(JSON.stringify(raw.args)), calls: JSON.parse(JSON.stringify(raw.calls)), expect: { status: raw.expect.status } }
  tokenizeVersionProbes(cand.calls, [run.engineVersion])
  return { run, replays: 0, cand, base: null, coupled: new Set(), journal: null }
}

async function replay(session, fx) {
  if (++session.replays > MAX_REPLAYS) refuse(`replay budget of ${MAX_REPLAYS} exhausted before the minimization settled`)
  await turn()
  return replayFixture(fx, session.run, { sites: true, prompts: true })
}

// The output directory must exist and the output name must be free.
function checkOutput(outDirectory, outPath) {
  let directoryStat = null
  try { directoryStat = fs.statSync(outDirectory) } catch (error) { /* refused below */ }
  if (!directoryStat || !directoryStat.isDirectory()) refuse('the output directory does not exist')
  let existing = null
  try { existing = fs.lstatSync(outPath) } catch (error) { if (!error || error.code !== 'ENOENT') throw error }
  if (existing) refuse(`the output file ${outPath} exists; a published fixture is never overwritten`)
}

// Step 2: three replays that must agree; returns the first one and records the baseline outcome.
async function baseline(session, raw) {
  const r1 = await replay(session, session.cand)
  if (r1.error) refuse('baseline replay: the engine threw')
  if (r1.missing.length) refuse(`baseline replay: ${r1.missing.length} unanswered call(s)`)
  const base = oracleOf(r1)
  if (base === null) refuse('baseline replay: the engine returned no result object')
  for (let index = 0; index < BASELINE_REPLAYS - 1; index++) {
    const rn = await replay(session, session.cand)
    if (oracleOf(rn) !== base) refuse('baseline replay is not deterministic')
  }
  if (typeof r1.result.status !== 'string' || r1.result.status !== raw.expect.status) {
    refuse('the recorded expect.status is not reproduced by the replay')
  }
  const reason = r1.result.reason
  if (reason !== undefined && reason !== null && typeof reason !== 'string') refuse('baseline replay: result.reason is not a string')
  if (r1.sites.some((s) => /^[LPA]\?/.test(s))) refuse('baseline replay: an engine call site could not be resolved')
  session.base = base
  return r1
}

// Step 4: the `probe-*` calls whose answer hash is the SHA-256 of the command the engine composed.
function coupledProbes(session, r1) {
  const coupledKeys = new Map()
  const counts = new Map()
  for (const c of r1.calls) {
    if (typeof c.label !== 'string' || !c.label.startsWith('probe-')) continue
    const n = counts.get(c.label) || 0
    counts.set(c.label, n + 1)
    const array = Array.isArray(session.cand.calls[c.label])
    const key = array ? `${c.label}[${n}]` : c.label
    const entry = array ? session.cand.calls[c.label][n] : session.cand.calls[c.label]
    const command = commandOfPrompt(c.prompt)
    const good = !!(isObject(entry) && typeof entry.line === 'string' && command !== null && firstCommandHash(entry.line) === sha256(command))
    coupledKeys.set(key, (coupledKeys.has(key) ? coupledKeys.get(key) : true) && good)
  }
  session.coupled = new Set([...coupledKeys].filter(([, v]) => v).map(([k]) => k))
}

// Rewrites the coupled `cmd=` hashes of the entries a replay asked for to what the engine composed now.
function rehashPass(session, fx, r, put) {
  let changed = false
  const counts = new Map()
  const done = new Set()
  for (const c of r.calls) {
    if (typeof c.label !== 'string') continue
    const n = counts.get(c.label) || 0
    counts.set(c.label, n + 1)
    const array = Array.isArray(fx.calls[c.label])
    const key = array ? `${c.label}[${n}]` : c.label
    if (!session.coupled.has(key) || done.has(key)) continue
    done.add(key)
    const entry = array ? fx.calls[c.label][n] : fx.calls[c.label]
    if (!isObject(entry) || typeof entry.line !== 'string') continue
    const command = commandOfPrompt(c.prompt)
    if (command === null) continue
    const want = sha256(command)
    const current = firstCommandHash(entry.line)
    if (current === null || current === want) continue
    put(entry, 'line', setCommandHash(entry.line, want))
    if (typeof entry.verify === 'string' && firstCommandHash(entry.verify) === current) put(entry, 'verify', setCommandHash(entry.verify, want))
    changed = true
  }
  return changed
}

// The change helpers of one session: `put` journals every write, `rehash` replays and re-hashes until none changes
// (the last replay, or null when the hashes do not settle), `tryChange` keeps a change only if the outcome is the baseline's.
function makeMinimizer(session) {
  const put = (parent, key, value) => {
    if (session.journal) session.journal.push([parent, key, parent[key]])
    parent[key] = value
  }
  const rehash = async (fx) => {
    for (let pass = 0; pass < MAX_REHASH; pass++) {
      const r = await replay(session, fx)
      if (!rehashPass(session, fx, r, put)) return r
    }
    return null
  }
  const tryChange = async (parent, key, value) => {
    session.journal = []
    put(parent, key, value)
    const r = await rehash(session.cand)
    const good = r !== null && oracleOf(r) === session.base
    if (!good) for (let index = session.journal.length - 1; index >= 0; index--) session.journal[index][0][session.journal[index][1]] = session.journal[index][2]
    session.journal = null
    return good
  }
  return { rehash, tryChange }
}

// Step 3: every string leaf to its neutral token, then each line of a multi-line leaf, to a fixpoint (3 passes at most).
async function minimize(session, tryChange) {
  const { cand } = session
  const leaves = [...collectLeaves(cand.args, 'args'), ...collectLeaves(cand.calls, 'calls')]
  for (let pass = 0; pass < MAX_PASSES; pass++) {
    const before = JSON.stringify(cand)
    for (const l of leaves) {
      if (isProtected(l.segs)) continue
      const v = l.parent[l.key]
      if (isNeutral(v)) continue
      for (const t of [...new Set([neutralOf(v), '_'])]) {
        if (t === v) continue
        if (await tryChange(l.parent, l.key, t)) break
      }
    }
    for (const l of leaves) {
      if (isProtected(l.segs)) continue
      if (isNeutral(l.parent[l.key]) || !l.parent[l.key].includes('\n')) continue
      const n = l.parent[l.key].split('\n').length
      for (let index = 0; index < n; index++) {
        const lines = l.parent[l.key].split('\n')
        if (lines.length !== n || lines[index] === '_' || lines[index] === '') continue
        lines[index] = '_'
        await tryChange(l.parent, l.key, lines.join('\n'))
      }
    }
    if (JSON.stringify(cand) === before) break
  }
}

// Step 6, first half: drop what the final replay did not consume and build the published `expect`; returns the pruned count.
async function pruneAndExpect(session) {
  const { cand, run, base } = session
  const fin0 = await replay(session, cand)
  if (oracleOf(fin0) !== base) refuse('minimization ended on a different outcome (internal)')
  // Whatever the final replay did not consume (a label never asked, the tail of an array) is dropped: it is dead
  // weight whose label can still name a private branch.
  let pruned = 0
  const asked = new Set(fin0.calls.map((c) => c.label))
  for (const label of Object.keys(cand.calls)) {
    if (!asked.has(label)) { delete cand.calls[label]; pruned++; continue }
    const entry = cand.calls[label]
    const used = fin0.cursors.get(label) || 0
    if (Array.isArray(entry) && used < entry.length) { pruned += entry.length - used; entry.length = used }
  }
  const fin = pruned ? await replay(session, cand) : fin0
  if (oracleOf(fin) !== base) refuse('pruning the unconsumed entries changed the outcome (internal)')
  cand.expect = { status: fin.result.status }
  if (fin.result.reason !== undefined) cand.expect.reason = fin.result.reason
  if (typeof cand.expect.reason === 'string' && cand.expect.reason.startsWith('plugin-version-') && run.engineVersion) {
    cand.expect.reason = cand.expect.reason.split(`engine is ${run.engineVersion};`).join(`engine is ${ENGINE_VERSION_TOKEN};`)
  }
  cand.expect.trace = Array.isArray(fin.result.trace) ? fin.result.trace : []
  cand.expect.traceExact = true
  cand.expect.callLabels = fin.calls.map((c) => c.label)
  return pruned
}

// Step 5: redact, re-hash, check, strict replay (a private 0600 copy, removed in `finally`); returns the text to publish.
async function redactAndCheck(session, rehash, outName, fp) {
  const { cand, base } = session
  const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'publish-fixture-'))
  temporaryDirectoryOut = temporaryDirectory
  try {
    const temporary = path.join(temporaryDirectory, 'candidate.json')
    const writeTemporary = (fx) => fs.writeFileSync(temporary, `${JSON.stringify(fx, null, 2)}\n`, { mode: 0o600 })
    const scrub = (s) => String(s).split(temporary).join('<candidate>')
    writeTemporary(cand)

    const red = runNode([path.join(__dirname, 'redact-fixture.cjs'), temporary])
    if (red.status === 3) {
      refuse('redact-fixture exited 3', String(red.stderr || '').split('\n').filter(Boolean).map(scrub))
    }
    if (red.status !== 0) refuse(`redact-fixture exited ${red.status === null ? 'abnormally' : red.status}`)

    const redacted = JSON.parse(fs.readFileSync(temporary, 'utf8'))
    const fx2 = { name: outName, args: redacted.args, calls: redacted.calls, expect: redacted.expect }
    const settled = await rehash(fx2)
    if (settled === null) refuse('coupled PROBE hashes did not settle after redaction')
    writeTemporary(fx2)
    const chk = runNode([path.join(__dirname, 'redact-fixture.cjs'), '--check', temporary])
    if (chk.status !== 0) refuse(`redact-fixture --check exited ${chk.status === null ? 'abnormally' : chk.status} on the redacted candidate`)
    if (oracleOf(settled) !== base) refuse('outcome changed after redaction')
    const strict = runNode([path.join(__dirname, 'run-offline.cjs'), temporary, '--report-unused', '--fp', fp], { ...process.env, OFFLINE_STRICT: '1' })
    const strictOutput = `${strict.stdout || ''}${strict.stderr || ''}`
    if (strict.status !== 0 || !strictOutput.includes('passed=1 failed=0')) {
      refuse(`strict replay of the redacted candidate failed (exit ${strict.status === null ? 'abnormally' : strict.status})`)
    }
    const text = fs.readFileSync(temporary, 'utf8')
    cand.args = fx2.args
    cand.calls = fx2.calls
    cand.expect = fx2.expect
    return text
  } finally {
    try { fs.rmSync(temporaryDirectory, { recursive: true, force: true }) } catch (error) { /* best effort, the directory is ours */ }
    temporaryDirectoryOut = null
  }
}

// Writes `text` to a temporary file next to the target, then links it at its name (the link fails if the name exists).
// A kill leaves at worst a hidden `.<name>.json.tmp-*` file, never a partial file at the final name (SIGINT/SIGTERM remove it in onSignal).
async function writeAtomic(outDirectory, outName, outPath, text) {
  temporaryOut = path.join(outDirectory, `.${outName}.json.tmp-${process.pid}-${crypto.randomBytes(4).toString('hex')}`)
  let fd
  try {
    fd = fs.openSync(temporaryOut, 'wx', 0o600)
  } catch (error) {
    temporaryOut = null // never created by us: nothing to remove
    throw error
  }
  try {
    const buffer = Buffer.from(text)
    let off = 0
    while (off < buffer.length) {
      const n = fs.writeSync(fd, buffer, off, buffer.length - off)
      if (!(n > 0)) throw new Error('short write: no progress')
      off += n
    }
    await turn() // a pending SIGINT / SIGTERM is handled here, with the temporary file in place (onSignal removes it)
    fs.fchmodSync(fd, 0o644)
    fs.fsyncSync(fd)
  } finally {
    fs.closeSync(fd)
  }
  try {
    fs.linkSync(temporaryOut, outPath)
  } catch (error) {
    if (error && error.code === 'EEXIST') refuse(`the output file ${outPath} exists; a published fixture is never overwritten`)
    throw error
  }
  createdOut = outPath
  fs.unlinkSync(temporaryOut)
  temporaryOut = null
}

// A kept string with a space, a newline or a path separator is free text (a plan line, a reason, a file path), protected
// fields included. A PROBE / VERIFY answer line is judged on what is not its fixed envelope (`PROBE`, `VERIFY ok line=PROBE`,
// `name=`, `exit=`, `sha=`, `cmd=`, `reason=`, whose spaces are delimiters): the part after `json=` is free text when it holds a
// space or a path separator (a repository path, a folder name after `/Users/<name>`, a title), and so is any other token.
const isFreeText = (v) => {
  if (!/^(PROBE|VERIFY) /.test(v)) return /[\s/\\]/.test(v)
  const index = v.indexOf(' json=')
  const head = index < 0 ? v : v.slice(0, index)
  const payload = index < 0 ? '' : v.slice(index + 6)
  return !head.split(' ').every((t) => PROBE_ENVELOPE_TOKEN.test(t)) || /[\s/\\]/.test(payload)
}

// What remains: field names and counts, never a value.
function report(cand, charsBefore, pruned, outPath) {
  const rem = [...collectLeaves(cand.args, 'args'), ...collectLeaves(cand.calls, 'calls')]
    .map((l) => ({ p: pathOf(l.segs), n: l.parent[l.key].length, v: l.parent[l.key], prot: isProtected(l.segs) }))
    .filter((x) => !isNeutral(x.v))
    .sort((a, b) => b.n - a.n || (a.p < b.p ? -1 : a.p > b.p ? 1 : 0))
  const out = [`remains: ${rem.length} strings, ${rem.reduce((n, x) => n + x.n, 0)} characters (was ${charsBefore})`]
  const free = []
  for (const x of rem) {
    const ft = isFreeText(x.v)
    if (ft) free.push(x.n)
    out.push(`  ${x.p} ${x.n} ${x.prot ? 'protected' : 'kept'}${ft ? ' free-text' : ''}`)
  }
  if (typeof cand.expect.reason === 'string' && cand.expect.reason !== '') {
    free.push(cand.expect.reason.length)
    out.push(`  expect.reason ${cand.expect.reason.length} free-text`)
  }
  out.push(`  expect.trace ${cand.expect.trace.reduce((n, t) => n + String(t).length, 0)}`)
  out.push(`free text: ${free.length} field(s), ${free.reduce((n, c) => n + c, 0)} characters (published as is, read them before publishing)`)
  let keyNames = 0
  let scalars = 0
  const tally = (v) => {
    if (Array.isArray(v)) v.forEach(tally)
    else if (isObject(v)) for (const k of Object.keys(v)) { keyNames++; tally(v[k]) }
    else if (typeof v !== 'string') scalars++
  }
  tally(cand.args)
  tally(cand.calls)
  out.push(`kept as is: ${keyNames} key names, ${scalars} non-string scalars (numbers, booleans, null); neither is ever neutralized`)
  out.push(`pruned: ${pruned} unconsumed call entries`)
  process.stdout.write(`${out.join('\n')}\n`)
  process.stdout.write(`[publish-fixture] status=ok out=${outPath}\n`)
}

async function main() {
  process.on('SIGINT', () => onSignal('SIGINT'))
  process.on('SIGTERM', () => onSignal('SIGTERM'))
  const { capture, outName, outDir, fp } = parseArguments(process.argv.slice(2))
  const outPath = path.join(outDir, `${outName}.json`)
  checkOutput(outDir, outPath)

  const raw = loadCapture(capture)
  let run
  try { run = buildPipelineRunner(stripExports(fs.readFileSync(fp, 'utf8'))) } catch (error) { refuse(`cannot load the engine file (${(error && error.code) || 'error'})`) }

  const session = newSession(run, raw, outName)
  const charsBefore = [...collectLeaves(session.cand.args, 'args'), ...collectLeaves(session.cand.calls, 'calls')]
    .reduce((n, l) => n + l.parent[l.key].length, 0)
  const r1 = await baseline(session, raw)
  coupledProbes(session, r1)
  const { rehash, tryChange } = makeMinimizer(session)
  await minimize(session, tryChange)
  const pruned = await pruneAndExpect(session)
  const text = await redactAndCheck(session, rehash, outName, fp)
  await writeAtomic(outDir, outName, outPath, text)
  report(session.cand, charsBefore, pruned, outPath)
  finished = true
}

main().catch((thrown) => {
  if (temporaryOut) { try { fs.unlinkSync(temporaryOut) } catch (u) { /* already gone */ } }
  if (thrown instanceof Usage) {
    process.stderr.write(`usage-error: ${thrown.message}\n${USAGE}\n`)
    process.stdout.write('[publish-fixture] status=usage-error\n')
    process.exitCode = 2
    return
  }
  if (thrown instanceof Refusal) {
    process.stderr.write(`refused: ${thrown.message}\n`)
    for (const d of thrown.detail) process.stderr.write(`  ${d}\n`)
    process.stdout.write('[publish-fixture] status=refused\n')
    process.exitCode = 1
    return
  }
  // Anything else (EACCES, ENOSPC...) still ends with a status line, no stack, and no file of ours left behind.
  if (createdOut) { try { fs.unlinkSync(createdOut) } catch (u) { /* already gone */ } }
  const error = thrown instanceof Error ? thrown : new Error(String(thrown))
  const code = error.code || error.name || 'Error'
  let message = String(error.message).replace(/\s*\n\s*/g, ' ')
  if (error.code && message.startsWith(`${error.code}: `)) message = message.slice(error.code.length + 2)
  process.stderr.write(`error: ${code}: ${message}\n`)
  if (process.env.PUBLISH_FIXTURE_DEBUG === '1') process.stderr.write(`${error.stack}\n`)
  process.stdout.write('[publish-fixture] status=error\n')
  process.exitCode = 1
})
