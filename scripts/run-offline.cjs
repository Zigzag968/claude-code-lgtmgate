#!/usr/bin/env node
'use strict'

// Offline record/replay harness for workflows/deliver-pipeline.js (milestone v1, E2.1).
//
// Runs the REAL pipeline body (no `simulate` mode) with `agent(prompt, opts)` served
// from a fixture keyed by `opts.label`. Where `run-flow-suite.cjs` exercises the loop
// logic through pre-parsed `simulate.*` seams, this harness feeds every agent() call
// the RAW value the harness would have returned (a string for a schema-less call, an
// object for a schema call), so the engine's own parsers run on what they would see
// in production. A recorded incident becomes a fixture file; replaying it in CI is
// the regression contract for that incident.
//
// Fixture format (JSON):
//   {
//     "name": "auto-lgtm",
//     "args": { ...pipeline args, never `simulate` },
//     "calls": {
//       "<label>": <value> | [<value>, <value>, ...]   // array = consumed in call order
//     },
//     "expect": {
//       "status": "ready",                 // required, unless "throws" is set
//       "throws": "config",                // optional: the run must THROW an error whose message contains this
//                                          // (arg-validation refusals; zero agent() call allowed) — replaces status
//       "reason": "nick-no-op",            // optional, exact match
//       "trace": ["Provision", "Diagnose"],// optional, PREFIX match on result.trace
//       "traceExact": true,                // optional (needs "trace" as an array): result.trace must have exactly
//                                          // as many entries as "trace" (the prefix match stays, nothing more may follow)
//       "callLabels": ["probe-1-...", "..."], // optional: the ordered labels of the agent() calls, EXACT equality
//       "logsInclude": ["..."],            // optional, each substring must appear in a log line
//       "phases": ["Setup", "Dev"],        // optional: the ordered phase() titles of the run, EXACT equality
//       "callLabelsAbsent": ["diagnose-"], // optional: no agent() call label may start with any of these (a non-empty list of non-empty strings)
//       "resultIncludes": { "retiredKeyPath": "x" }, // optional: a non-empty object; every key of the run result must equal its value (JSON string compare)
//       "promptIncludes": { "label": "<call label>", "nth": 0, "includes": ["..."] },
//                                          // optional (object or non-empty array of them): the prompt of the nth (0-based, default 0)
//                                          // call carrying that label must contain every string (non-empty list of non-empty strings)
//       "promptExcludes": { "label": "<call label>", "nth": 0, "excludes": ["..."] },
//                                          // optional (object or array): in that prompt none of the strings may appear (same shape as promptIncludes)
//       "promptOrder": { "label": "<call label>", "nth": 0, "order": ["a", "b"] }
//                                          // optional (object or array): in that prompt the first occurrence of each string
//                                          // (at least 2) must appear at strictly increasing offsets
//     }
//   Any other `expect` key is refused (the fixture fails), so a misspelled key cannot be dropped in silence.
//   }
// Multi-run format (#185), e.g. a relaunch: `runs` replaces the top-level args/calls/expect (mixing them is refused), at
// least 2 entries, each run replayed against its OWN calls and expect (a run holds only args, calls, expect and carry; any
// other key is refused, so a misspelled one cannot be dropped in silence):
//   { "name": "...", "runs": [ { "args": {...}, "calls": {...}, "expect": {...} },
//                              { "args": {...}, "calls": {...}, "expect": {...}, "carry": { "planText": "plan" } } ] }
// `carry` = { "<arg>": "<field>" }: arg of run N is set to that top-level field of run N-1's result (the way the Lead hands
// `plan` back as `planText`); a field the previous run did not return fails the fixture. Nothing else is shared between runs.
// The token `@@ENGINE_VERSION@@` anywhere in a fixture resolves to the engine's BUILD version (refused if it has none).
// A label absent from `calls` (or an exhausted array) throws with the label and the
// first 200 chars of the prompt, so the missing entry is obvious. Nothing is defaulted.
//
// Coupling to deliver-pipeline.js (same contract as run-flow-suite.cjs):
//   - export-strip regex `/^export\s+/mg`; injected globals `args`, `agent`, `log`, `phase`.
//   - every agent() call must carry a unique `opts.label` (round-suffixed where a call
//     repeats per round).
//
// Usage:
//   node scripts/run-offline.cjs <fixture.json> [--fp workflows/deliver-pipeline.js]
//   node scripts/run-offline.cjs --all <dir> [--fp ...]      # every *.json under <dir>, recursive
//   node scripts/run-offline.cjs <fixture.json> --report-unused   # also list fixture entries the run never consumed
//     (report only: an unused entry never changes pass/fail, the trailer or the exit code)
// Last stdout line (always): `[offline] status=<ok|fail|harness-error> passed=<n> failed=<n>`
// Exit 0 when the run(s) completed; OFFLINE_STRICT=1 (CI) turns failed>0 into exit 1.

const fs = require('fs')
const path = require('path')

function parseArgs(argv) {
  const out = { fp: 'workflows/deliver-pipeline.js', all: null, reportUnused: false, fixtures: [] }
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--fp' && argv[i + 1]) { out.fp = argv[++i]; continue }
    if (argv[i] === '--all' && argv[i + 1]) { out.all = argv[++i]; continue }
    if (argv[i] === '--report-unused') { out.reportUnused = true; continue }
    out.fixtures.push(argv[i])
  }
  return out
}

function stripExports(src) {
  return src.replace(/^export\s+/mg, '')
}

// `@@ENGINE_VERSION@@` anywhere in a fixture (args, calls, expect) stands for the version of the engine under
// test (the `version:` of its `const BUILD = { ... }` line, which scripts/lead-merge.sh bumps at every merge), so
// a fixture that quotes it (the plugin-version probe answer, a reason naming it) survives a bump. A fixture that
// uses the token against an engine with no BUILD version is refused, never run with the token left in.
const ENGINE_VERSION_TOKEN = '@@ENGINE_VERSION@@'
function engineVersionOf(src) {
  const m = /const BUILD = \{[^}]*\bversion: '([^']+)'/.exec(String(src))
  return m ? m[1] : null
}
// A version string as the engine writes it in BUILD (semver, optional pre-release).
const ENGINE_VERSION_RE = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/
// The engine's own declaration of its version: the run result's `buildStamp` (`BUILD_STAMP` in the workflow,
// `[pipeline] <plugin>@<version> cutFrom=<sha> workflow=<name>`). Returns the version, or null when the stamp is not a
// string or does not carry a well-formed version.
function engineVersionOfStamp(stamp) {
  if (typeof stamp !== 'string') return null
  const m = /^\[pipeline\] [^@\s]+@(\S+)(?: |$)/.exec(stamp)
  return m && ENGINE_VERSION_RE.test(m[1]) ? m[1] : null
}
function withEngineVersion(fixture, version) {
  const raw = JSON.stringify(fixture)
  if (!raw.includes(ENGINE_VERSION_TOKEN)) return fixture
  if (!version) throw new Error(`[offline] fixture "${fixture.name}" uses ${ENGINE_VERSION_TOKEN} but the engine under test has no BUILD version`)
  return JSON.parse(raw.split(ENGINE_VERSION_TOKEN).join(version))
}

// The answer of the plugin version probe (#195) is journaled with the LITERAL engine version, which lead-merge bumps at
// every merge. A capture or a published fixture therefore stores the token instead, wherever the answer names the engine
// of the run: `versions` lists the strings that are the run's engine version. Quote-delimited, so `1.0.0-beta.90` is not
// `1.0.0-beta.9`. Rewrites `line` and `verify` of every `probe-<issue>-lines-plugin-version-r<round>` entry in place;
// returns the number of strings rewritten. The PROBE `cmd=` hash is the hash of the command, which holds the root path and
// no version, so it stays valid.
const VERSION_PROBE_LABEL = /^probe-\d+-lines-plugin-version-r\d+$/
function tokenizeVersionProbes(calls, versions) {
  let n = 0
  for (const label of Object.keys(calls || {})) {
    if (!VERSION_PROBE_LABEL.test(label)) continue
    const entries = Array.isArray(calls[label]) ? calls[label] : [calls[label]]
    for (const e of entries) {
      if (e === null || typeof e !== 'object') continue
      for (const k of ['line', 'verify']) {
        if (typeof e[k] !== 'string') continue
        for (const v of versions) {
          if (!v) continue
          const from = `"PLUGIN-VERSION:${v}"`
          if (!e[k].includes(from)) continue
          e[k] = e[k].split(from).join(`"PLUGIN-VERSION:${ENGINE_VERSION_TOKEN}"`)
          n++
        }
      }
    }
  }
  return n
}

function listJson(dir) {
  const out = []
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, ent.name)
    if (ent.isDirectory()) out.push(...listJson(p))
    else if (ent.isFile() && ent.name.endsWith('.json')) out.push(p)
  }
  return out.sort()
}

// agent() served by label. Arrays are consumed in call order; a scalar is reusable.
// A missing entry throws AND is recorded in `missing`: the engine catches most agent()
// errors on purpose (fail-open probes, agent-death routing), so the harness must fail the
// fixture itself — a run that "passed" while a call went unanswered proves nothing.
function buildFixtureAgent(fixture, calls, missing, cursors, withPrompts = false) {
  return async (prompt, opts) => {
    const label = opts && opts.label
    const entry = { label: label || null, hasSchema: !!(opts && opts.schema) }
    if (withPrompts) entry.prompt = String(prompt)
    calls.push(entry)
    const head = String(prompt).slice(0, 200)
    if (!label) {
      missing.push(`agent() called without a label (prompt head: ${head})`)
      throw new Error(`[offline] agent() called without a label — every call must be addressable. Prompt head: ${head}`)
    }
    if (!Object.prototype.hasOwnProperty.call(fixture.calls, label)) {
      missing.push(`no fixture entry for label "${label}"`)
      throw new Error(`[offline] no fixture entry for label "${label}" (fixture "${fixture.name}"). Prompt head: ${head}`)
    }
    const value = fixture.calls[label]
    if (Array.isArray(value)) {
      const i = cursors.get(label) || 0
      if (i >= value.length) {
        missing.push(`fixture entry "${label}" exhausted after ${value.length} call(s)`)
        throw new Error(`[offline] fixture entry "${label}" exhausted after ${value.length} call(s) (fixture "${fixture.name}")`)
      }
      cursors.set(label, i + 1)
      return clone(value[i])
    }
    return clone(value)
  }
}

function clone(v) {
  return v === null || typeof v !== 'object' ? v : JSON.parse(JSON.stringify(v))
}

function buildPipelineRunner(fpSrcStripped) {
  // eslint-disable-next-line no-new-func
  const run = new Function(
    'args', 'agent', 'log', 'phase',
    'return (async () => {\n' + fpSrcStripped + '\n})()',
  )
  run.engineVersion = engineVersionOf(fpSrcStripped)
  return run
}

// Fixture entries the run never consumed: a label never asked, or the unconsumed tail of an array.
function findUnused(fixture, calls, cursors) {
  const unused = []
  for (const label of Object.keys(fixture.calls)) {
    if (!calls.some((c) => c.label === label)) { unused.push(label); continue }
    const value = fixture.calls[label]
    if (Array.isArray(value)) {
      for (let i = cursors.get(label) || 0; i < value.length; i++) unused.push(`${label}[${i}]`)
    }
  }
  return unused
}

// Every key `expect` may carry. Any other key is refused (an ignored key is a silent non-proof, the defect #185 closed for run keys).
const EXPECT_KEYS = ['status', 'throws', 'reason', 'trace', 'traceExact', 'callLabels', 'logsInclude', 'phases', 'callLabelsAbsent', 'promptIncludes', 'promptExcludes', 'promptOrder', 'resultIncludes']

function expectKeyProblems(exp) {
  if (exp === null || typeof exp !== 'object' || Array.isArray(exp)) return []
  return Object.keys(exp)
    .filter((k) => !EXPECT_KEYS.includes(k))
    .map((k) => `unknown expect key "${k}" (allowed: ${EXPECT_KEYS.join(', ')})`)
}

const isNonEmptyString = (s) => typeof s === 'string' && s !== ''

// promptIncludes / promptExcludes / promptOrder: one entry object or a non-empty array of entries. A wrong shape or an unknown sub-key is a problem (fail closed).
function promptProblems(exp, calls) {
  const problems = []
  if (exp === null || typeof exp !== 'object') return problems
  const specs = [
    { key: 'promptIncludes', field: 'includes', minLen: 1 },
    { key: 'promptExcludes', field: 'excludes', minLen: 1 },
    { key: 'promptOrder', field: 'order', minLen: 2 },
  ]
  for (const { key, field, minLen } of specs) {
    if (exp[key] === undefined) continue
    const entries = Array.isArray(exp[key]) ? exp[key] : [exp[key]]
    if (entries.length === 0) { problems.push(`${key}: must be an entry or a non-empty array of entries`); continue }
    for (const e of entries) {
      if (e === null || typeof e !== 'object' || Array.isArray(e)) { problems.push(`${key}: each entry must be an object`); continue }
      const bad = Object.keys(e).find((k) => !['label', 'nth', field].includes(k))
      if (bad !== undefined) { problems.push(`${key}: unknown entry key "${bad}" (allowed: label, nth, ${field})`); continue }
      if (!isNonEmptyString(e.label)) { problems.push(`${key}: "label" must be a non-empty string`); continue }
      if (e.nth !== undefined && !(Number.isInteger(e.nth) && e.nth >= 0)) { problems.push(`${key}: "nth" must be an integer >= 0`); continue }
      if (!Array.isArray(e[field]) || e[field].length < minLen || e[field].some((s) => !isNonEmptyString(s))) {
        problems.push(`${key}: "${field}" must be an array of at least ${minLen} non-empty string(s)`)
        continue
      }
      const nth = e.nth === undefined ? 0 : e.nth
      const target = calls.filter((c) => c.label === e.label)[nth]
      if (target === undefined) {
        problems.push(`${key}: no call nth ${nth} of label "${e.label}" (calls: ${calls.map((c) => c.label).join(', ')})`)
        continue
      }
      const prompt = typeof target.prompt === 'string' ? target.prompt : ''
      if (key === 'promptIncludes') {
        for (const needle of e.includes) {
          if (!prompt.includes(needle)) problems.push(`promptIncludes: "${e.label}"[${nth}] prompt lacks "${needle}"`)
        }
      } else if (key === 'promptExcludes') {
        for (const needle of e.excludes) {
          if (prompt.includes(needle)) problems.push(`promptExcludes: "${e.label}"[${nth}] prompt holds "${needle}"`)
        }
      } else {
        let last = -1
        for (const s of e.order) {
          const at = prompt.indexOf(s)
          if (at === -1) { problems.push(`promptOrder: "${e.label}"[${nth}] prompt lacks "${s}"`); break }
          if (at <= last) { problems.push(`promptOrder: "${e.label}"[${nth}] "${s}" is not after the previous string`); break }
          last = at
        }
      }
    }
  }
  return problems
}

function check(fixture, result, logs, calls = [], phases = []) {
  const exp = fixture.expect || {}
  const problems = []
  problems.push(...expectKeyProblems(exp), ...promptProblems(exp, calls))
  if (typeof exp.status !== 'string') {
    problems.push('expect.status is required (a fixture without an expected status proves nothing)')
  }
  if (exp.status !== undefined && result.status !== exp.status) {
    problems.push(`status: expected "${exp.status}", got "${result.status}"` +
      (result.reason ? ` (reason "${result.reason}")` : ''))
  }
  if (exp.reason !== undefined && result.reason !== exp.reason) {
    problems.push(`reason: expected "${exp.reason}", got "${result.reason}"`)
  }
  if (Array.isArray(exp.trace)) {
    const got = Array.isArray(result.trace) ? result.trace : []
    exp.trace.forEach((t, i) => {
      if (got[i] !== t) problems.push(`trace[${i}]: expected "${t}", got "${got[i]}"`)
    })
  }
  if (exp.traceExact !== undefined) {
    if (exp.traceExact !== true && exp.traceExact !== false) problems.push('traceExact: must be true or false')
    else if (exp.traceExact) {
      if (!Array.isArray(exp.trace)) problems.push('traceExact: requires expect.trace to be an array')
      else {
        const got = Array.isArray(result.trace) ? result.trace : []
        if (got.length !== exp.trace.length) problems.push(`trace: expected ${exp.trace.length} entries, got ${got.length}`)
      }
    }
  }
  if (exp.callLabels !== undefined) {
    if (!Array.isArray(exp.callLabels)) problems.push('callLabels: must be an array')
    else {
      const got = calls.map((c) => c.label)
      if (got.length !== exp.callLabels.length || got.some((l, i) => l !== exp.callLabels[i])) {
        problems.push(`callLabels: expected ${JSON.stringify(exp.callLabels)}, got ${JSON.stringify(got)}`)
      }
    }
  }
  if (exp.phases !== undefined) {
    if (!Array.isArray(exp.phases)) problems.push('phases: must be an array')
    else if (phases.length !== exp.phases.length || phases.some((p, i) => p !== exp.phases[i])) {
      problems.push(`phases: expected ${JSON.stringify(exp.phases)}, got ${JSON.stringify(phases)}`)
    }
  }
  if (exp.resultIncludes !== undefined) {
    const ri = exp.resultIncludes
    if (ri === null || typeof ri !== 'object' || Array.isArray(ri) || Object.keys(ri).length === 0) {
      problems.push('resultIncludes: must be a non-empty object')
    } else {
      for (const k of Object.keys(ri)) {
        if (JSON.stringify(result[k]) !== JSON.stringify(ri[k])) {
          problems.push(`resultIncludes: result.${k} expected ${JSON.stringify(ri[k])}, got ${JSON.stringify(result[k])}`)
        }
      }
    }
  }
  if (exp.callLabelsAbsent !== undefined) {
    if (!Array.isArray(exp.callLabelsAbsent) || exp.callLabelsAbsent.length === 0 || exp.callLabelsAbsent.some((p) => typeof p !== 'string' || p === '')) {
      problems.push('callLabelsAbsent: must be a non-empty array of non-empty label prefixes')
    } else {
      for (const c of calls) {
        const hit = exp.callLabelsAbsent.find((p) => String(c.label).startsWith(p))
        if (hit !== undefined) problems.push(`callLabelsAbsent: call "${c.label}" starts with "${hit}"`)
      }
    }
  }
  if (Array.isArray(exp.logsInclude)) {
    for (const needle of exp.logsInclude) {
      if (!logs.some((l) => l.includes(needle))) problems.push(`logs: missing "${needle}"`)
    }
  }
  return problems
}

// The engine frame of the current call stack as `<line>:<col>` (the body runs inside `new Function`, whose
// frames read `<anonymous>:L:C`), or `?` when none can be read.
function engineSite() {
  const lines = String(new Error().stack).split('\n')
  for (const l of lines) {
    const m = /<anonymous>:(\d+):(\d+)/.exec(l)
    if (m) return `${m[1]}:${m[2]}`
  }
  return '?'
}

// One replay of a fixture through `run` (see buildPipelineRunner). Never throws: an engine error lands in `error`.
//   sites:   each log(), phase() and agent() call appends its engine call site (`L<line>:<col>`, `P...`,
//            `A<line>:<col>:<label>`) to `sites`. In-process only: sites shift on any engine edit and are never
//            written to a fixture.
//   prompts: each `calls[]` entry also carries the `prompt` string it was called with.
// The fixture is not modified (args are deep-copied, a replay of the same object can be repeated).
async function replayFixture(fixture, run, { sites = false, prompts = false } = {}) {
  fixture = withEngineVersion(fixture, run.engineVersion)
  const logs = []
  const calls = []
  const missing = []
  const cursors = new Map()
  const siteList = []
  const phases = []
  let log = (m) => { logs.push(String(m)) }
  let phase = (title) => { phases.push(String(title)) }
  let agent = buildFixtureAgent(fixture, calls, missing, cursors, prompts)
  if (sites) {
    const logInner = log
    const phaseInner = phase
    const agentInner = agent
    log = (m) => { siteList.push(`L${engineSite()}`); return logInner(m) }
    phase = (...a) => { siteList.push(`P${engineSite()}`); return phaseInner(...a) }
    agent = (prompt, opts) => { siteList.push(`A${engineSite()}:${(opts && opts.label) || ''}`); return agentInner(prompt, opts) }
  }
  let result
  let error = null
  try { result = await run(clone(fixture.args || {}), agent, log, phase) } catch (e) { error = e }
  return { result, error, logs, calls, missing, cursors, sites: siteList, phases }
}

async function runOne(fixturePath, fpSrcStripped) {
  const fixture = JSON.parse(fs.readFileSync(fixturePath, 'utf-8'))
  if (!fixture.name) fixture.name = path.basename(fixturePath, '.json')
  if (fixture.runs !== undefined) return runChain(fixture, fpSrcStripped)
  return runSingle(fixture, fpSrcStripped)
}

// A multi-run fixture replays its runs in order, each against its own calls and expect, through runSingle. What a later run
// sees of the earlier one is only what its `carry` names: { "<arg>": "<field>" } sets that arg of run N to that top-level
// field of run N-1's result (the way the Lead hands `plan` back as `planText` on a relaunch). A failing run ends the chain.
const RUN_KEYS = ['args', 'calls', 'expect', 'carry']
async function runChain(fixture, fpSrcStripped) {
  const problems = []
  const logs = []
  const unused = []
  const allCalls = []
  let prev = null
  let result = { status: 'none' }
  if (fixture.args !== undefined || fixture.calls !== undefined || fixture.expect !== undefined) {
    throw new Error(`[offline] fixture "${fixture.name}" sets "runs" and also a top-level args/calls/expect — a multi-run fixture keeps them inside each run`)
  }
  if (!Array.isArray(fixture.runs) || fixture.runs.length < 2) {
    throw new Error(`[offline] fixture "${fixture.name}": "runs" must be an array of at least 2 runs`)
  }
  for (let i = 0; i < fixture.runs.length; i++) {
    const spec = fixture.runs[i]
    const tag = `run ${i + 1}`
    if (spec === null || typeof spec !== 'object') throw new Error(`[offline] fixture "${fixture.name}": ${tag} is not an object`)
    for (const key of Object.keys(spec)) {
      if (!RUN_KEYS.includes(key)) throw new Error(`[offline] fixture "${fixture.name}": ${tag} has unknown key "${key}" (allowed: ${RUN_KEYS.join(', ')})`)
    }
    const args = JSON.parse(JSON.stringify(spec.args || {}))
    if (spec.carry !== undefined) {
      if (i === 0 || spec.carry === null || typeof spec.carry !== 'object') {
        throw new Error(`[offline] fixture "${fixture.name}": ${tag} "carry" must be an object and needs an earlier run`)
      }
      for (const [argName, field] of Object.entries(spec.carry)) {
        if (prev.result[field] === undefined) {
          problems.push(`${tag}: carry "${argName}" <- result.${field}, but run ${i} returned no "${field}" (status ${prev.result.status})`)
        } else args[argName] = clone(prev.result[field])
      }
      if (problems.length) break
    }
    const r = await runSingle({ name: `${fixture.name}#${i + 1}`, args, calls: spec.calls, expect: spec.expect }, fpSrcStripped)
    for (const p of r.problems) problems.push(`${tag}: ${p}`)
    for (const u of r.unused) unused.push(`${tag}: ${u}`)
    logs.push(...r.logs)
    allCalls.push(...r.calls)
    result = r.result
    prev = r
    if (r.problems.length) break
  }
  return { fixture, result, logs, calls: allCalls, problems, unused }
}

async function runSingle(fixture, fpSrcStripped) {
  if (!fixture.calls || typeof fixture.calls !== 'object') {
    throw new Error(`[offline] fixture "${fixture.name}" has no "calls" object`)
  }
  if (fixture.args && fixture.args.simulate) {
    throw new Error(`[offline] fixture "${fixture.name}" sets args.simulate — this harness runs the REAL parsers, never simulate mode`)
  }
  const run = buildPipelineRunner(fpSrcStripped)
  fixture = withEngineVersion(fixture, run.engineVersion)
  const r = await replayFixture(fixture, run, { prompts: true })
  const { logs, calls, missing, cursors } = r
  const expThrows = fixture.expect && fixture.expect.throws
  if (typeof expThrows === 'string') {
    const err = r.error
    const problems = expectKeyProblems(fixture.expect)
    if (!err) problems.push(`throws: expected an error containing "${expThrows}", but the run did not throw`)
    else if (!String(err.message).includes(expThrows)) problems.push(`throws: expected message containing "${expThrows}", got "${err.message}"`)
    if (calls.length) problems.push(`throws: ${calls.length} agent() call(s) happened before the refusal (${calls.map((c) => c.label || c).join(', ')})`)
    return { fixture, result: { status: 'threw' }, logs, calls, problems, unused: findUnused(fixture, calls, cursors) }
  }
  if (r.error) throw r.error
  const result = r.result
  const problems = check(fixture, result, logs, calls, r.phases)
  for (const m of missing) problems.push(`unanswered call (engine swallowed the error): ${m}`)
  return { fixture, result, logs, calls, problems, unused: findUnused(fixture, calls, cursors) }
}

async function main() {
  const { fp, all, fixtures, reportUnused } = parseArgs(process.argv.slice(2))
  const files = all ? listJson(path.resolve(all)) : fixtures.map((f) => path.resolve(f))
  if (!files.length) {
    process.stderr.write('usage: node scripts/run-offline.cjs <fixture.json>... | --all <dir> [--fp <pipeline.js>]\n')
    process.stdout.write('[offline] status=harness-error passed=0 failed=0\n')
    process.exit(1)
  }
  const fpSrcStripped = stripExports(fs.readFileSync(path.resolve(fp), 'utf-8'))

  let passed = 0
  let failed = 0
  for (const f of files) {
    const rel = path.relative(process.cwd(), f)
    try {
      const r = await runOne(f, fpSrcStripped)
      if (r.problems.length) {
        failed++
        process.stdout.write(`FAIL: ${rel} (${r.fixture.name}) status=${r.result.status}\n`)
        for (const p of r.problems) process.stdout.write(`  - ${p}\n`)
        if (process.env.OFFLINE_VERBOSE === '1') for (const l of r.logs) process.stdout.write(`  | ${l}\n`)
      } else {
        passed++
        process.stdout.write(`ok: ${rel} (${r.fixture.name}) status=${r.result.status} calls=${r.calls.length}\n`)
      }
      if (reportUnused) for (const u of r.unused) process.stdout.write(`  unused: ${u}\n`)
    } catch (e) {
      failed++
      process.stdout.write(`FAIL: ${rel} — ${e && e.message ? e.message : String(e)}\n`)
    }
  }
  const status = failed === 0 ? 'ok' : 'fail'
  process.stdout.write(`[offline] status=${status} passed=${passed} failed=${failed}\n`)
  const strict = process.env.OFFLINE_STRICT === '1'
  process.exit(strict && failed > 0 ? 1 : 0)
}

// Required by scripts/publish-fixture.cjs; run as a CLI otherwise (spawned or direct use is unchanged).
module.exports = { stripExports, buildPipelineRunner, replayFixture, engineVersionOf, engineVersionOfStamp, ENGINE_VERSION_RE, tokenizeVersionProbes, ENGINE_VERSION_TOKEN }

if (require.main === module) {
  main().catch((err) => {
    console.error(err && err.stack ? err.stack : String(err))
    process.stdout.write('[offline] status=harness-error passed=0 failed=0\n')
    process.exit(1)
  })
}
