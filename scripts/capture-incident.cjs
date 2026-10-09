#!/usr/bin/env node
'use strict'

// Capture a Workflow run as a PRIVATE raw fixture (E3.10, #181).
//
// Reads the run's journal (`journal.jsonl`) and run record (`<runId>.json`) that Claude Code
// persists, and writes `<issue>-<label>.json` in the fixture format of `run-offline.cjs`:
// one `calls[<label>]` entry per agent() call of the run's FINAL pass, holding exactly what the
// agent returned. The capture is raw (may hold private data): it is written ONLY to a path git
// ignores, and publishing it (redaction, `fixtures/incidents/`) is a separate step.
//
// Usage:
//   node scripts/capture-incident.cjs <runId> <issue> <label> [--out DIR] [--from DIR]
//     <runId>  wf_<id>                 <issue>  digits                <label>  [a-z0-9-]
//     --out    default <cwd>/.pipeline/captures   (must be git-ignored, inside a work tree)
//     --from   projects directory; default $CLAUDE_PROJECTS_DIR, else ~/.claude/projects
// Last stdout line (always): `[capture-incident] status=<ok|refused|error|usage-error>`
// (ok adds `out=<path> calls=<n> cached=<n> version-source=<stamp|checkout|pluginRoot|none> retries=<n>`). Detail goes to stderr. Exit 0 ok, 1 refused or error
// (error = an unexpected file-system failure, one `error: <code>: <message>` stderr line, stack only
// with CAPTURE_INCIDENT_DEBUG=1, nothing left written), 2 usage.
//
// The answer of the plugin version probe (#195) names the engine version, which lead-merge bumps at every merge: the
// capture stores the token `@@ENGINE_VERSION@@` there when the answer is the run's engine (see engineVersionsOfRun): the
// version in the run record's own `result.buildStamp` when it has one, else this checkout's BUILD / the pluginRoot segment.
//
// Observed layout (Claude Code does not document it; measured on real files by other users):
//   journal  <projects>/<project>/<session>/subagents/workflows/<runId>/journal.jsonl
//     rows: started {agentId,key,label}, result {key,result}, failed {key}; key = "v2:<hash>"
//   record   <projects>/<project>/<session>/workflows/<runId>.json
//     keys: status, args, agentCount, result{status,buildStamp?}, workflowProgress[{type:'workflow_agent',agentId,label,cached?}]
// Every key read is whitelisted and required: a missing one refuses with `layout: <file>: missing <key>`
// instead of guessing, so a change of layout is loud. `cached` and `result.buildStamp` are optional (absent = false / no stamp).
//
// The final pass of a relaunched run is the set of agentId values in the record's workflowProgress,
// never journal order. A result is joined to its start by `key`. A key whose LAST result/failed row
// is `failed` is refused (a `failed` followed by a later `result`, a retry, is accepted).
// A call the engine retried is ONE workflowProgress entry named `<label> (retry N)` that carries the agentId of its last
// attempt, while the journal holds `<label>` on every attempt: N+1 `started` rows under one key, the N earlier ones (died)
// without a result. It is captured once under `<label>` with the answer of that agentId (`retries=<n>` sums the N): N must
// equal the died attempts of the key ("retry count mismatch" otherwise), the key must not be shared by another entry, and a
// call with no result refuses. The suffix is exactly ` (retry N)` (N 1-999, case-sensitive, nothing after); the other engine
// suffixes `(throttle-retry)` and `(after usage limit)` are not folded and refuse as a label mismatch.

const fs = require('fs')
const os = require('os')
const path = require('path')
const { spawnSync } = require('child_process')
const { engineVersionOf, engineVersionOfStamp, ENGINE_VERSION_RE, tokenizeVersionProbes } = require('./run-offline.cjs')

class Refusal extends Error {}
class Usage extends Error {}

function usage(message) { throw new Usage(message) }
function refuse(message) { throw new Refusal(message) }

// ---- arguments ------------------------------------------------------------------------------

function parseArguments(argv) {
  const out = { positional: [], out: null, from: null }
  for (let index = 0; index < argv.length; index++) {
    const a = argv[index]
    if (a === '--out' || a === '--from') {
      if (index + 1 >= argv.length || argv[index + 1].startsWith('--')) usage(`${a} needs a value`)
      out[a.slice(2)] = argv[++index]
    } else if (a.startsWith('--')) {
      usage(`unknown flag ${a}`)
    } else {
      out.positional.push(a)
    }
  }
  if (out.positional.length !== 3) usage('expected <runId> <issue> <label>')
  const [runId, issue, label] = out.positional
  if (!/^wf_[A-Za-z0-9-]+$/.test(runId)) usage(`runId "${runId}" must match ^wf_[A-Za-z0-9-]+$`)
  if (!/^[0-9]+$/.test(issue)) usage(`issue "${issue}" must be digits`)
  if (!/^[a-z0-9][a-z0-9-]*$/.test(label)) usage(`label "${label}" must match ^[a-z0-9][a-z0-9-]*$`)
  return { runId, issue, label, outDir: out.out, from: out.from }
}

// ---- output path: must be ignored by git ----------------------------------------------------

function git(cwd, arguments_) {
  return spawnSync('git', ['-C', cwd, ...arguments_], { encoding: 'utf8' })
}

// Returns the absolute file path once git proves it is ignored; refuses otherwise.
function resolveIgnoredOutput(outputDirectory, issue, label) {
  const abs = path.resolve(outputDirectory || path.join(process.cwd(), '.pipeline', 'captures'))
  let ancestor = abs
  const tail = []
  while (!fs.existsSync(ancestor)) {
    const parent = path.dirname(ancestor)
    if (parent === ancestor) break
    tail.unshift(path.basename(ancestor))
    ancestor = parent
  }
  const realAncestor = fs.realpathSync(ancestor)
  const file = path.join(realAncestor, ...tail, `${issue}-${label}.json`)
  const top = git(realAncestor, ['rev-parse', '--show-toplevel'])
  if (top.status !== 0) {
    refuse(`${abs} is not inside a git work tree, cannot prove it is ignored`)
  }
  const topDirectory = top.stdout.trim()
  const relative = path.relative(topDirectory, file)
  const ign = git(topDirectory, ['check-ignore', '-q', '--', relative])
  if (ign.status !== 0) {
    refuse(`${abs} is not ignored by git (a raw capture must never land in a tracked path)`)
  }
  return file
}

// ---- locate the run -------------------------------------------------------------------------

function subdirs(directory) {
  let names
  try { names = fs.readdirSync(directory) } catch (error) { return [] }
  return names.filter((n) => {
    try { return fs.statSync(path.join(directory, n)).isDirectory() } catch (error) { return false }
  }).sort()
}

function locateRun(base, runId) {
  const found = []
  for (const proj of subdirs(base)) {
    for (const sess of subdirs(path.join(base, proj))) {
      const d = path.join(base, proj, sess, 'subagents', 'workflows', runId)
      try { if (fs.statSync(d).isDirectory()) found.push(d) } catch (error) { /* not here */ }
    }
  }
  if (found.length === 0) refuse(`run ${runId} not found under ${base}`)
  if (found.length > 1) refuse(`run ${runId} is ambiguous (${found.length} directories: ${found.join(', ')})`)
  return found[0]
}

// The run record sits beside `subagents/`, named after the run id. One function: the only
// place that encodes where the record lives.
function recordPathFor(runDirectory) {
  return path.join(runDirectory, '..', '..', '..', 'workflows', `${path.basename(runDirectory)}.json`)
}

// ---- journal --------------------------------------------------------------------------------

function isString(v) { return typeof v === 'string' && v.length > 0 }

function readJournal(file) {
  let text
  try { text = fs.readFileSync(file, 'utf8') } catch (error) { refuse(`layout: ${file}: missing file`) }
  if (!text.trim()) refuse(`layout: ${file}: missing file (journal is empty)`)
  const rows = []
  text.split('\n').forEach((raw, index) => {
    if (!raw.trim()) return
    const line = index + 1
    let row
    try { row = JSON.parse(raw) } catch (error) { refuse(`layout: ${file}: invalid JSON [line ${line}]`) }
    if (row === null || typeof row !== 'object' || !isString(row.type)) refuse(`layout: ${file}: missing type [line ${line}]`)
    const need = row.type === 'started' ? ['agentId', 'key', 'label']
      : row.type === 'result' ? ['key']
        : row.type === 'failed' ? ['key'] : []
    for (const k of need) {
      if (!isString(row[k])) refuse(`layout: ${file}: missing ${k} [line ${line}]`)
    }
    if (row.type === 'result' && !Object.prototype.hasOwnProperty.call(row, 'result')) {
      refuse(`layout: ${file}: missing result [line ${line}]`)
    }
    if (need.includes('key') && !row.key.startsWith('v2:')) {
      refuse(`layout: ${file}: key "${row.key}" does not start with v2: [line ${line}]`)
    }
    rows.push({ line, row })
  })
  return rows
}

// ---- run record -----------------------------------------------------------------------------

function readRecord(file) {
  let rec
  try { rec = JSON.parse(fs.readFileSync(file, 'utf8')) } catch (error) {
    if (error && error.code === 'ENOENT') refuse(`layout: ${file}: missing file`)
    refuse(`layout: ${file}: invalid JSON`)
  }
  const miss = (k) => refuse(`layout: ${file}: missing ${k}`)
  if (rec === null || typeof rec !== 'object') miss('status')
  if (!isString(rec.status)) miss('status')
  if (rec.args === null || typeof rec.args !== 'object' || Array.isArray(rec.args)) miss('args')
  if (!Number.isInteger(rec.agentCount)) miss('agentCount')
  if (!Array.isArray(rec.workflowProgress)) miss('workflowProgress')
  if (rec.status !== 'completed') refuse(`run record ${file}: status is ${rec.status}, no observed final status`)
  if (rec.result === null || typeof rec.result !== 'object' || !isString(rec.result.status)) miss('result.status')
  const agents = []
  rec.workflowProgress.forEach((entry, index) => {
    if (entry === null || typeof entry !== 'object' || entry.type !== 'workflow_agent') return // phases and logs are tolerated
    if (!isString(entry.agentId)) miss(`workflowProgress[${index}].agentId`)
    if (!isString(entry.label)) miss(`workflowProgress[${index}].label`)
    if (entry.cached !== undefined && typeof entry.cached !== 'boolean') miss(`workflowProgress[${index}].cached (boolean)`)
    agents.push({ agentId: entry.agentId, label: entry.label, cached: entry.cached === true })
  })
  if (rec.agentCount !== agents.length) {
    refuse(`${file}: agentCount ${rec.agentCount} does not match ${agents.length} workflow_agent entries`)
  }
  const seen = new Set()
  for (const a of agents) {
    if (seen.has(a.agentId)) refuse(`${file}: duplicate agentId ${a.agentId} in workflowProgress`)
    seen.add(a.agentId)
  }
  return {
    args: rec.args,
    status: rec.result.status,
    reason: typeof rec.result.reason === 'string' ? rec.result.reason : '',
    buildStamp: typeof rec.result.buildStamp === 'string' ? rec.result.buildStamp : '',
    agents,
  }
}

// ---- final pass -----------------------------------------------------------------------------

// The one suffix the engine puts on the record label of a retried call: a space, `(retry N)`, N from 1 to 999, nothing after.
// Case-sensitive on purpose; `(throttle-retry)` and `(after usage limit)` are other engine suffixes and are NOT folded.
const RETRY_SUFFIX = /^(.*) \(retry ([1-9][0-9]{0,2})\)$/

// Indexes the journal rows: starts per key and per agent, result rows per key, the last result/failed event per key,
// and how many workflowProgress entries journal each key. Refuses a result whose key has no start.
function indexJournal(journalFile, rows, agents) {
  const startsByKey = new Map() // key -> [{ row, line }] in journal order
  const startedByAgent = new Map()
  for (const { line, row } of rows) {
    if (row.type !== 'started') continue
    if (!startsByKey.has(row.key)) startsByKey.set(row.key, [])
    startsByKey.get(row.key).push({ row, line })
    startedByAgent.set(row.agentId, { row, line })
  }
  const resultRowsByKey = new Map() // key -> [{ row, line }]
  const resultByKey = new Map()
  const lastEventByKey = new Map() // key -> { type: 'result'|'failed', line } of its LAST such row
  for (const { line, row } of rows) {
    if (row.type !== 'result' && row.type !== 'failed') continue
    lastEventByKey.set(row.key, { type: row.type, line })
    if (row.type !== 'result') continue
    if (!startsByKey.has(row.key)) refuse(`${journalFile}: orphan result for key ${row.key} [line ${line}]`)
    if (!resultRowsByKey.has(row.key)) resultRowsByKey.set(row.key, [])
    resultRowsByKey.get(row.key).push({ row, line })
    resultByKey.set(row.key, row) // last wins
  }
  const agentsByKey = new Map() // key -> number of workflowProgress entries that journal it
  for (const a of agents) {
    const s = startedByAgent.get(a.agentId)
    if (s) agentsByKey.set(s.row.key, (agentsByKey.get(s.row.key) || 0) + 1)
  }
  return { startsByKey, startedByAgent, resultRowsByKey, resultByKey, lastEventByKey, agentsByKey }
}

// The number of died attempts the record label `a.label` claims (0 when it is the journal label as is); refuses any other difference.
function retriesClaimed(journalFile, a, label, s) {
  if (a.label === label) return 0
  const m = RETRY_SUFFIX.exec(a.label)
  if (!m || m[1] !== label) {
    refuse(`layout: ${journalFile}: label mismatch for agentId ${a.agentId} (journal "${label}", record "${a.label}") [line ${s.line}]`)
  }
  return Number(m[2])
}

// The answer of a retried call: the result of THIS agentId's attempt; a journal whose result rows name other agentIds only is not guessed.
function retriedAnswer(journalFile, a, s, key, results, answer, n) {
  const dead = s.starts.length - results.length
  if (dead !== n) {
    refuse(`layout: ${journalFile}: retry count mismatch for agentId ${a.agentId} (record "${a.label}" says ${n}, the journal holds ${dead} died attempt${dead === 1 ? '' : 's'} for key ${key}) [line ${s.line}]`)
  }
  if (!results.some((r) => isString(r.row.agentId))) return answer
  const own = results.filter((r) => r.row.agentId === a.agentId)
  if (own.length === 0) {
    refuse(`layout: ${journalFile}: retried call "${a.label}": no result row of agentId ${a.agentId} for key ${key} (the result rows name other attempts) [line ${s.line}]`)
  }
  return own[own.length - 1].row
}

// One workflowProgress entry to its outcome: { died }, { failed } (a text for the refusal) or { call, retries, note }.
// The engine keeps ONE entry per call: a retried call is the entry
// `<label> (retry N)` carrying the agentId of its LAST attempt, while the journal holds `<label>` on every attempt, all
// under one key, the N earlier ones without a result. The journal label wins: that exact suffix is folded, N is checked
// against the died attempts of the key, and any other difference between the two labels refuses.
function resolveAgent(journalFile, journal, a) {
  const s = journal.startedByAgent.get(a.agentId)
  if (!s) refuse(`layout: ${journalFile}: missing started for workflowProgress agentId ${a.agentId}`)
  const key = s.row.key
  const label = s.row.label
  const n = retriesClaimed(journalFile, a, label, s)
  const starts = journal.startsByKey.get(key)
  const results = journal.resultRowsByKey.get(key) || []
  if (n > 0) {
    for (const t of starts) {
      if (t.row.label !== label) {
        refuse(`layout: ${journalFile}: label mismatch on key ${key} (journal "${t.row.label}" [line ${t.line}], "${label}" [line ${s.line}])`)
      }
    }
    if (journal.agentsByKey.get(key) > 1) {
      refuse(`layout: ${journalFile}: ambiguous retried call "${a.label}": key ${key} is journaled by ${journal.agentsByKey.get(key)} workflowProgress entries, the died attempts cannot be attributed`)
    }
  }
  if (results.length === 0) { // no attempt of the key answered
    return { died: starts.map((t) => `${label} key ${key} [line ${t.line}]`).join(', ') }
  }
  let answer = journal.resultByKey.get(key)
  if (n > 0) answer = retriedAnswer(journalFile, a, { starts, line: s.line }, key, results, answer, n)
  const last = journal.lastEventByKey.get(key)
  if (last.type === 'failed') return { failed: `${label} key ${key} [line ${last.line}]` }
  let note = null
  if (n > 0) {
    const answeredIds = new Set(results.map((r) => r.row.agentId).filter(isString))
    const deadIds = starts.filter((t) => t.row.agentId !== a.agentId && !answeredIds.has(t.row.agentId)).map((t) => `${t.row.agentId} [line ${t.line}]`)
    note = `note: ${journalFile}: folded retried call ${label}: ${n + 1} attempts, answer of agentId ${a.agentId} used, died attempt${n === 1 ? '' : 's'} ${deadIds.join(', ')}`
  }
  return { call: { label, value: answer.result, cached: a.cached }, retries: n, note }
}

function finalPass(journalFile, rows, agents) {
  const journal = indexJournal(journalFile, rows, agents)
  const calls = []
  const died = []
  const failedLast = []
  const finalIds = new Set(agents.map((a) => a.agentId))
  let retries = 0
  const notes = []
  // One call per workflowProgress entry, in record order.
  for (const a of agents) {
    const outcome = resolveAgent(journalFile, journal, a)
    if (outcome.died !== undefined) { died.push(outcome.died); continue }
    if (outcome.failed !== undefined) { failedLast.push(outcome.failed); continue }
    retries += outcome.retries
    if (outcome.note) notes.push(outcome.note)
    calls.push(outcome.call)
  }
  const causes = []
  if (died.length) causes.push(`died call ${died.join('; died call ')}`)
  if (failedLast.length) causes.push(`failed call ${failedLast.join('; failed call ')} (the key's last event is failed, an earlier result is not used)`)
  if (causes.length) refuse(`${journalFile}: ${causes.join('; ')}`)
  for (const [agentId, { row, line }] of journal.startedByAgent) {
    if (!finalIds.has(agentId) && !journal.resultByKey.has(row.key)) {
      notes.push(`note: ${journalFile}: died call ${row.label} key ${row.key} [line ${line}] belongs to an earlier pass, not captured`)
    }
  }
  return { calls, notes, retries }
}

// The plugin version probe answer (#195) names the engine version of the run, which lead-merge bumps at every merge: it is
// stored as the token `@@ENGINE_VERSION@@`, so the capture still replays after the next bump. Returns the
// `{ source, version }` pairs that are the run's engine:
// - the run record's own `buildStamp` (#213) when it carries a version: the engine's declaration is the sole authority, an
//   answer that differs from it (a real skew) stays literal and replays as a skew, no proxy is consulted;
// - else (no stamp, or an unparseable one) the two proxies: the BUILD version of this checkout's engine, or the version the
//   run's pluginRoot names (the last segment of the plugin cache path) - a run that went past the version check proves the
//   two were equal. Not for a run that ended on a plugin-version-* reason: there the answer differs from the engine, and
//   the difference is the incident.
function engineVersionsOfRun(record) {
  const stamped = engineVersionOfStamp(record.buildStamp)
  if (stamped) return [{ source: 'stamp', version: stamped }]
  if (record.reason.startsWith('plugin-version-')) return []
  const out = []
  try { out.push({ source: 'checkout', version: engineVersionOf(fs.readFileSync(path.resolve(__dirname, '..', 'workflows', 'deliver-pipeline.js'), 'utf8')) }) } catch (error) { /* no engine file: only the pluginRoot rule */ }
  const root = typeof record.args.pluginRoot === 'string' ? record.args.pluginRoot.replace(/\/+$/, '') : ''
  const last = root.slice(root.lastIndexOf('/') + 1)
  if (ENGINE_VERSION_RE.test(last)) out.push({ source: 'pluginRoot', version: last })
  return out.filter((o) => o.version)
}

function buildFixture(issue, label, record, calls) {
  const byLabel = new Map()
  for (const c of calls) {
    if (!byLabel.has(c.label)) byLabel.set(c.label, [])
    byLabel.get(c.label).push(c.value)
  }
  const out = {}
  for (const [lab, values] of byLabel) {
    // run-offline reads any array as a call-order list: wrap a value that is itself an array.
    out[lab] = values.length > 1 || Array.isArray(values[0]) ? values : values[0]
  }
  const fixtureArguments = JSON.parse(JSON.stringify(record.args))
  delete fixtureArguments.simulate
  const versionSources = [] // which source tokenized at least one answer (a name, never an answer)
  for (const { source, version } of engineVersionsOfRun(record)) {
    if (tokenizeVersionProbes(out, [version]) > 0) versionSources.push(source)
  }
  return { fixture: { name: `${issue}-${label}`, args: fixtureArguments, calls: out, expect: { status: record.status } }, versionSources }
}

// ---- private write --------------------------------------------------------------------------

let createdFile = null // set once the output file is open, so an unexpected error can remove it

// Writes `text` to `file` (mode 600) without ever following a symlink at `file` and without
// touching a file that is not ours alone: git proved the PATH ignored, not the inode behind it.
// The file is opened WITHOUT truncation and checked on the descriptor (a regular file with a single
// link) before anything is written; O_NONBLOCK makes a FIFO fail with ENXIO instead of hanging.
// A pre-existing regular single-link file is overwritten.
function writePrivate(file, text) {
  let st = null
  try { st = fs.lstatSync(file) } catch (error) { if (!error || error.code !== 'ENOENT') throw error }
  if (st && st.isSymbolicLink()) refuse(`output file ${file} is a symlink; refusing to write through it`)
  const C = fs.constants
  let fd
  try {
    fd = fs.openSync(file, C.O_WRONLY | C.O_CREAT | (C.O_NOFOLLOW || 0) | (C.O_NONBLOCK || 0), 0o600)
  } catch (error) {
    if (error && error.code === 'ELOOP') refuse(`output file ${file} is a symlink; refusing to write through it`)
    if (error && error.code === 'ENXIO') refuse(`output file ${file} is not a regular file`)
    throw error
  }
  try {
    const fst = fs.fstatSync(fd)
    if (!fst.isFile()) refuse(`output file ${file} is not a regular file`)
    if (fst.nlink !== 1) refuse(`output file ${file} has more than one hard link; refusing to overwrite a shared file`)
    createdFile = file
    fs.ftruncateSync(fd, 0)
    fs.fchmodSync(fd, 0o600)
    const buffer = Buffer.from(text)
    let off = 0
    while (off < buffer.length) {
      const n = fs.writeSync(fd, buffer, off, buffer.length - off)
      if (!(n > 0)) throw new Error(`short write to ${file}: no progress after ${off} of ${buffer.length} bytes`)
      off += n
    }
  } finally {
    fs.closeSync(fd)
  }
}

// ---- replay ---------------------------------------------------------------------------------

function replay(file) {
  const r = spawnSync(process.execPath, ['scripts/run-offline.cjs', file, '--report-unused'], {
    cwd: path.resolve(__dirname, '..'),
    env: { ...process.env, OFFLINE_STRICT: '1' },
    encoding: 'utf8',
  })
  const text = `${r.stdout || ''}${r.stderr || ''}`
  process.stdout.write(text.endsWith('\n') || !text ? text : `${text}\n`)
  if (r.status !== 0 || text.includes('unanswered call')) refuse(`replay failed (capture kept at ${file})`)
}

// ---- main -----------------------------------------------------------------------------------

function main() {
  const { runId, issue, label, outDir, from } = parseArguments(process.argv.slice(2))
  const file = resolveIgnoredOutput(outDir, issue, label)
  const base = from || process.env.CLAUDE_PROJECTS_DIR || path.join(os.homedir(), '.claude', 'projects')
  const runDirectory = locateRun(base, runId)
  const journalFile = path.join(runDirectory, 'journal.jsonl')
  const rows = readJournal(journalFile)
  const record = readRecord(recordPathFor(runDirectory))
  const { calls, notes, retries } = finalPass(journalFile, rows, record.agents)
  for (const n of notes) process.stderr.write(`${n}\n`)
  const { fixture, versionSources } = buildFixture(issue, label, record, calls)
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 })
  writePrivate(file, `${JSON.stringify(fixture, null, 2)}\n`)
  replay(file)
  process.stdout.write(`next: scripts/publish-fixture.sh ${file}\n`)
  const cached = calls.filter((c) => c.cached).length
  process.stdout.write(`[capture-incident] status=ok out=${file} calls=${calls.length} cached=${cached} version-source=${versionSources.join(',') || 'none'} retries=${retries}\n`)
}

try {
  main()
} catch (thrown) {
  if (thrown instanceof Usage) {
    process.stderr.write(`usage-error: ${thrown.message}\nusage: node scripts/capture-incident.cjs <runId> <issue> <label> [--out DIR] [--from DIR]\n`)
    process.stdout.write('[capture-incident] status=usage-error\n')
    process.exit(2)
  }
  if (thrown instanceof Refusal) {
    process.stderr.write(`refused: ${thrown.message}\n`)
    process.stdout.write('[capture-incident] status=refused\n')
    process.exit(1)
  }
  // Anything else (EACCES, ENAMETOOLONG, ENOSPC...) still ends with a status line, no stack.
  if (createdFile) { try { fs.unlinkSync(createdFile) } catch (u) { /* already gone or not ours */ } }
  const error = thrown instanceof Error ? thrown : new Error(String(thrown))
  const code = error.code || error.name || 'Error'
  let message = String(error.message).replace(/\s*\n\s*/g, ' ')
  if (error.code && message.startsWith(`${error.code}: `)) message = message.slice(error.code.length + 2)
  if (error.path && !message.includes(error.path)) message += ` (${error.path})`
  process.stderr.write(`error: ${code}: ${message}\n`)
  if (process.env.CAPTURE_INCIDENT_DEBUG === '1') process.stderr.write(`${error.stack}\n`)
  process.stdout.write('[capture-incident] status=error\n')
  process.exit(1)
}
