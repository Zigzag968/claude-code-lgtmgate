#!/usr/bin/env node
'use strict'

// Publish a PRIVATE raw capture as a minimized, redacted, public fixture (E3.10, #189).
//
// Input: a raw capture written by scripts/capture-incident.cjs (fixture format of run-offline.cjs:
// name, args, calls, expect). Output: fixtures/incidents/<issue>-<label>.json, written to a temporary file next to it,
// fsynced, then linked at its name (the link fails if the name exists: an existing file is never overwritten, and a kill
// never leaves a partial file at the final name), only after every step below held.
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
const { stripExports, buildPipelineRunner, replayFixture } = require('./run-offline.cjs')

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
  constructor(msg, detail) { super(msg); this.detail = detail || [] }
}
class Usage extends Error {}

const refuse = (msg, detail) => { throw new Refusal(msg, detail) }
const usage = (msg) => { throw new Usage(msg) }
const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v)
const sha256 = (s) => crypto.createHash('sha256').update(s, 'utf8').digest('hex')

// ---- arguments ------------------------------------------------------------------------------

function parseArgs(argv) {
  const out = { positional: [], outDir: null, fp: null }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === '--out-dir' || a === '--fp') {
      if (i + 1 >= argv.length || argv[i + 1].startsWith('--')) usage(`${a} needs a value`)
      out[a === '--fp' ? 'fp' : 'outDir'] = argv[++i]
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
  try { text = fs.readFileSync(file, 'utf8') } catch (e) { refuse(`cannot read the raw capture (${(e && e.code) || 'error'})`) }
  let c
  try { c = JSON.parse(text) } catch (e) { refuse('the raw capture is not valid JSON') }
  if (!isObj(c)) refuse('the raw capture is not a JSON object')
  const extra = Object.keys(c).filter((k) => !['name', 'args', 'calls', 'expect'].includes(k))
  if (extra.length) refuse(`the raw capture has key(s) outside name, args, calls, expect: ${extra.join(', ')}`)
  if (!isObj(c.args)) refuse('the raw capture has no args object')
  if (Object.prototype.hasOwnProperty.call(c.args, 'simulate')) refuse('the raw capture sets args.simulate')
  if (!isObj(c.calls)) refuse('the raw capture has no calls object')
  if (!isObj(c.expect) || typeof c.expect.status !== 'string' || !c.expect.status) refuse('the raw capture has no expect.status')
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
  if (isObj(v)) return ['o', Object.keys(v).sort().map((k) => [k, shapeOf(v[k])])]
  return ['?', typeof v]
}

// ---- probe prompts ------------------------------------------------------------------------------

// The command a probe prompt asks the probe agent to run: the text between ` --cmd ` and `\n2. cd `, un-quoted
// from `'...'` (`'\''` is one quote). Plain indexOf parsing of the prompt the engine builds (probeCommands).
function cmdOfPrompt(prompt) {
  if (typeof prompt !== 'string') return null
  const end = prompt.indexOf('\n2. cd ')
  if (end < 0) return null
  const start = prompt.indexOf(' --cmd ')
  if (start < 0 || start > end) return null
  const q = prompt.slice(start + 7, end)
  if (q.length < 2 || q[0] !== "'" || q[q.length - 1] !== "'") return null
  return q.slice(1, -1).split("'\\''").join("'")
}

// The fixed words of a PROBE / VERIFY answer line before its `json=` payload (see templates/probe-run.cjs).
const PROBE_ENVELOPE_TOKEN = /^(PROBE|VERIFY|ok|fail|line=PROBE|name=[A-Za-z0-9._-]+|exit=-?\d+|sha=[0-9a-f]+|cmd=[0-9a-f]+|reason=[A-Za-z0-9._-]+)$/

const CMD_RE = /cmd=([0-9a-f]{64})/
const firstCmdHash = (s) => { const m = CMD_RE.exec(s); return m ? m[1] : null }
const setCmdHash = (s, h) => s.replace(CMD_RE, `cmd=${h}`)

// ---- leaves and neutral tokens -------------------------------------------------------------

function collectLeaves(root, rootName) {
  const out = []
  const walk = (node, segs, parent, key) => {
    if (typeof node === 'string') out.push({ parent, key, segs })
    else if (Array.isArray(node)) node.forEach((v, i) => walk(v, [...segs, i], node, i))
    else if (isObj(node)) for (const k of Object.keys(node)) walk(node[k], [...segs, k], node, k)
  }
  walk(root, [rootName], null, null)
  return out
}

const pathOf = (segs) => segs.reduce((acc, s, i) => (i === 0 ? String(s) : typeof s === 'number' ? `${acc}[${s}]` : `${acc}.${s}`), '')

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

function runNode(args, env) {
  return spawnSync(process.execPath, args, { cwd: REPO, encoding: 'utf8', env: env || process.env })
}

// ---- main -----------------------------------------------------------------------------------

let createdOut = null // set once the output name is linked, so an unexpected error can remove it
let tmpOut = null // the temporary file next to the target, removed on any end

async function main() {
  const { capture, outName, outDir, fp } = parseArgs(process.argv.slice(2))
  const outPath = path.join(outDir, `${outName}.json`)

  let dst = null
  try { dst = fs.statSync(outDir) } catch (e) { /* refused below */ }
  if (!dst || !dst.isDirectory()) refuse('the output directory does not exist')
  let existing = null
  try { existing = fs.lstatSync(outPath) } catch (e) { if (!e || e.code !== 'ENOENT') throw e }
  if (existing) refuse(`the output file ${outPath} exists; a published fixture is never overwritten`)

  const raw = loadCapture(capture)
  let run
  try { run = buildPipelineRunner(stripExports(fs.readFileSync(fp, 'utf8'))) } catch (e) { refuse(`cannot load the engine file (${(e && e.code) || 'error'})`) }

  let replays = 0
  const replay = async (fx) => {
    if (++replays > MAX_REPLAYS) refuse(`replay budget of ${MAX_REPLAYS} exhausted before the minimization settled`)
    return replayFixture(fx, run, { sites: true, prompts: true })
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

  const cand = { name: outName, args: JSON.parse(JSON.stringify(raw.args)), calls: JSON.parse(JSON.stringify(raw.calls)), expect: { status: raw.expect.status } }
  const totalChars = (fx) => [...collectLeaves(fx.args, 'args'), ...collectLeaves(fx.calls, 'calls')]
    .reduce((n, l) => n + l.parent[l.key].length, 0)
  const charsBefore = totalChars(cand)

  // ---- baseline ----
  const r1 = await replay(cand)
  if (r1.error) refuse('baseline replay: the engine threw')
  if (r1.missing.length) refuse(`baseline replay: ${r1.missing.length} unanswered call(s)`)
  const base = oracleOf(r1)
  if (base === null) refuse('baseline replay: the engine returned no result object')
  for (let i = 0; i < BASELINE_REPLAYS - 1; i++) {
    const rn = await replay(cand)
    if (oracleOf(rn) !== base) refuse('baseline replay is not deterministic')
  }
  if (typeof r1.result.status !== 'string' || r1.result.status !== raw.expect.status) {
    refuse('the recorded expect.status is not reproduced by the replay')
  }
  const reason = r1.result.reason
  if (reason !== undefined && reason !== null && typeof reason !== 'string') refuse('baseline replay: result.reason is not a string')
  if (r1.sites.some((s) => /^[LPA]\?/.test(s))) refuse('baseline replay: an engine call site could not be resolved')

  // ---- coupled probes ----
  const coupledKeys = new Map()
  {
    const counts = new Map()
    for (const c of r1.calls) {
      if (typeof c.label !== 'string' || !c.label.startsWith('probe-')) continue
      const n = counts.get(c.label) || 0
      counts.set(c.label, n + 1)
      const arr = Array.isArray(cand.calls[c.label])
      const key = arr ? `${c.label}[${n}]` : c.label
      const entry = arr ? cand.calls[c.label][n] : cand.calls[c.label]
      const cmd = cmdOfPrompt(c.prompt)
      const good = !!(isObj(entry) && typeof entry.line === 'string' && cmd !== null && firstCmdHash(entry.line) === sha256(cmd))
      coupledKeys.set(key, (coupledKeys.has(key) ? coupledKeys.get(key) : true) && good)
    }
  }
  const coupled = new Set([...coupledKeys].filter(([, v]) => v).map(([k]) => k))

  let journal = null
  const put = (parent, key, val) => {
    if (journal) journal.push([parent, key, parent[key]])
    parent[key] = val
  }
  // Replay, rewrite the coupled `cmd=` hashes to what the engine composed now, repeat until none changes.
  // Returns the last replay, or null when the hashes do not settle.
  const rehash = async (fx) => {
    for (let pass = 0; pass < MAX_REHASH; pass++) {
      const r = await replay(fx)
      let changed = false
      const counts = new Map()
      const done = new Set()
      for (const c of r.calls) {
        if (typeof c.label !== 'string') continue
        const n = counts.get(c.label) || 0
        counts.set(c.label, n + 1)
        const arr = Array.isArray(fx.calls[c.label])
        const key = arr ? `${c.label}[${n}]` : c.label
        if (!coupled.has(key) || done.has(key)) continue
        done.add(key)
        const entry = arr ? fx.calls[c.label][n] : fx.calls[c.label]
        if (!isObj(entry) || typeof entry.line !== 'string') continue
        const cmd = cmdOfPrompt(c.prompt)
        if (cmd === null) continue
        const want = sha256(cmd)
        const cur = firstCmdHash(entry.line)
        if (cur === null || cur === want) continue
        put(entry, 'line', setCmdHash(entry.line, want))
        if (typeof entry.verify === 'string' && firstCmdHash(entry.verify) === cur) put(entry, 'verify', setCmdHash(entry.verify, want))
        changed = true
      }
      if (!changed) return r
    }
    return null
  }
  // One candidate change: kept only if, after the coupled hashes follow, the outcome is the baseline's.
  const tryChange = async (parent, key, val) => {
    journal = []
    put(parent, key, val)
    const r = await rehash(cand)
    const good = r !== null && oracleOf(r) === base
    if (!good) for (let i = journal.length - 1; i >= 0; i--) journal[i][0][journal[i][1]] = journal[i][2]
    journal = null
    return good
  }

  // ---- minimize ----
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
      for (let i = 0; i < n; i++) {
        const lines = l.parent[l.key].split('\n')
        if (lines.length !== n || lines[i] === '_' || lines[i] === '') continue
        lines[i] = '_'
        await tryChange(l.parent, l.key, lines.join('\n'))
      }
    }
    if (JSON.stringify(cand) === before) break
  }

  const fin0 = await replay(cand)
  if (oracleOf(fin0) !== base) refuse('minimization ended on a different outcome (internal)')
  // Whatever the final replay did not consume (a label never asked, the tail of an array) is dropped: it is dead
  // weight whose label can still name a private branch.
  let pruned = 0
  {
    const asked = new Set(fin0.calls.map((c) => c.label))
    for (const label of Object.keys(cand.calls)) {
      if (!asked.has(label)) { delete cand.calls[label]; pruned++; continue }
      const entry = cand.calls[label]
      const used = fin0.cursors.get(label) || 0
      if (Array.isArray(entry) && used < entry.length) { pruned += entry.length - used; entry.length = used }
    }
  }
  const fin = pruned ? await replay(cand) : fin0
  if (oracleOf(fin) !== base) refuse('pruning the unconsumed entries changed the outcome (internal)')
  cand.expect = { status: fin.result.status }
  if (fin.result.reason !== undefined) cand.expect.reason = fin.result.reason
  cand.expect.trace = Array.isArray(fin.result.trace) ? fin.result.trace : []
  cand.expect.traceExact = true
  cand.expect.callLabels = fin.calls.map((c) => c.label)

  // ---- redact, re-hash, check, strict replay (a private 0600 copy, removed in `finally`) ----
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'publish-fixture-'))
  let text
  try {
    const tmp = path.join(tmpDir, 'candidate.json')
    const writeTmp = (fx) => fs.writeFileSync(tmp, `${JSON.stringify(fx, null, 2)}\n`, { mode: 0o600 })
    const scrub = (s) => String(s).split(tmp).join('<candidate>')
    writeTmp(cand)

    const red = runNode([path.join(__dirname, 'redact-fixture.cjs'), tmp])
    if (red.status === 3) {
      refuse('redact-fixture exited 3', String(red.stderr || '').split('\n').filter(Boolean).map(scrub))
    }
    if (red.status !== 0) refuse(`redact-fixture exited ${red.status === null ? 'abnormally' : red.status}`)

    const redacted = JSON.parse(fs.readFileSync(tmp, 'utf8'))
    const fx2 = { name: outName, args: redacted.args, calls: redacted.calls, expect: redacted.expect }
    const settled = await rehash(fx2)
    if (settled === null) refuse('coupled PROBE hashes did not settle after redaction')
    writeTmp(fx2)
    const chk = runNode([path.join(__dirname, 'redact-fixture.cjs'), '--check', tmp])
    if (chk.status !== 0) refuse(`redact-fixture --check exited ${chk.status === null ? 'abnormally' : chk.status} on the redacted candidate`)
    if (oracleOf(settled) !== base) refuse('outcome changed after redaction')
    const strict = runNode([path.join(__dirname, 'run-offline.cjs'), tmp, '--report-unused', '--fp', fp], { ...process.env, OFFLINE_STRICT: '1' })
    const sout = `${strict.stdout || ''}${strict.stderr || ''}`
    if (strict.status !== 0 || !sout.includes('passed=1 failed=0')) {
      refuse(`strict replay of the redacted candidate failed (exit ${strict.status === null ? 'abnormally' : strict.status})`)
    }
    text = fs.readFileSync(tmp, 'utf8')
    cand.args = fx2.args
    cand.calls = fx2.calls
    cand.expect = fx2.expect
  } finally {
    try { fs.rmSync(tmpDir, { recursive: true, force: true }) } catch (e) { /* best effort, the directory is ours */ }
  }

  // ---- write: a temporary file next to the target, then a link that fails if the name exists ----
  // A kill at any point leaves at worst a hidden `.<name>.json.tmp-*` file, never a partial file at the final name.
  tmpOut = path.join(outDir, `.${outName}.json.tmp-${process.pid}-${crypto.randomBytes(4).toString('hex')}`)
  let fd
  try {
    fd = fs.openSync(tmpOut, 'wx', 0o600)
  } catch (e) {
    tmpOut = null // never created by us: nothing to remove
    throw e
  }
  try {
    const buf = Buffer.from(text)
    let off = 0
    while (off < buf.length) {
      const n = fs.writeSync(fd, buf, off, buf.length - off)
      if (!(n > 0)) throw new Error('short write: no progress')
      off += n
    }
    fs.fchmodSync(fd, 0o644)
    fs.fsyncSync(fd)
  } finally {
    fs.closeSync(fd)
  }
  try {
    fs.linkSync(tmpOut, outPath)
  } catch (e) {
    if (e && e.code === 'EEXIST') refuse(`the output file ${outPath} exists; a published fixture is never overwritten`)
    throw e
  }
  createdOut = outPath
  fs.unlinkSync(tmpOut)
  tmpOut = null

  // ---- what remains: field names and counts, never a value ----
  // A kept string with a space, a newline or a path separator is free text (a plan line, a reason, a file path), protected
  // fields included. A PROBE / VERIFY answer line is judged on what is not its fixed envelope (`PROBE`, `VERIFY ok line=PROBE`,
  // `name=`, `exit=`, `sha=`, `cmd=`, `reason=`, whose spaces are delimiters): the part after `json=` is free text when it holds a
  // space or a path separator (a repository path, a folder name after `/Users/<name>`, a title), and so is any other token.
  const isFreeText = (v) => {
    if (!/^(PROBE|VERIFY) /.test(v)) return /[\s/\\]/.test(v)
    const i = v.indexOf(' json=')
    const head = i < 0 ? v : v.slice(0, i)
    const payload = i < 0 ? '' : v.slice(i + 6)
    return !head.split(' ').every((t) => PROBE_ENVELOPE_TOKEN.test(t)) || /[\s/\\]/.test(payload)
  }
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
    else if (isObj(v)) for (const k of Object.keys(v)) { keyNames++; tally(v[k]) }
    else if (typeof v !== 'string') scalars++
  }
  tally(cand.args)
  tally(cand.calls)
  out.push(`kept as is: ${keyNames} key names, ${scalars} non-string scalars (numbers, booleans, null); neither is ever neutralized`)
  out.push(`pruned: ${pruned} unconsumed call entries`)
  process.stdout.write(`${out.join('\n')}\n`)
  process.stdout.write(`[publish-fixture] status=ok out=${outPath}\n`)
}

main().catch((e) => {
  if (tmpOut) { try { fs.unlinkSync(tmpOut) } catch (u) { /* already gone */ } }
  if (e instanceof Usage) {
    process.stderr.write(`usage-error: ${e.message}\n${USAGE}\n`)
    process.stdout.write('[publish-fixture] status=usage-error\n')
    process.exitCode = 2
    return
  }
  if (e instanceof Refusal) {
    process.stderr.write(`refused: ${e.message}\n`)
    for (const d of e.detail) process.stderr.write(`  ${d}\n`)
    process.stdout.write('[publish-fixture] status=refused\n')
    process.exitCode = 1
    return
  }
  // Anything else (EACCES, ENOSPC...) still ends with a status line, no stack, and no file of ours left behind.
  if (createdOut) { try { fs.unlinkSync(createdOut) } catch (u) { /* already gone */ } }
  const err = e instanceof Error ? e : new Error(String(e))
  const code = err.code || err.name || 'Error'
  let msg = String(err.message).replace(/\s*\n\s*/g, ' ')
  if (err.code && msg.startsWith(`${err.code}: `)) msg = msg.slice(err.code.length + 2)
  process.stderr.write(`error: ${code}: ${msg}\n`)
  if (process.env.PUBLISH_FIXTURE_DEBUG === '1') process.stderr.write(`${err.stack}\n`)
  process.stdout.write('[publish-fixture] status=error\n')
  process.exitCode = 1
})
