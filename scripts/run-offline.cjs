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
//       "logsInclude": ["..."]             // optional, each substring must appear in a log line
//     }
//   }
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
// Last stdout line (always): `[offline] status=<ok|fail|harness-error> passed=<n> failed=<n>`
// Exit 0 when the run(s) completed; OFFLINE_STRICT=1 (CI) turns failed>0 into exit 1.

const fs = require('fs')
const path = require('path')

function parseArgs(argv) {
  const out = { fp: 'workflows/deliver-pipeline.js', all: null, fixtures: [] }
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--fp' && argv[i + 1]) { out.fp = argv[++i]; continue }
    if (argv[i] === '--all' && argv[i + 1]) { out.all = argv[++i]; continue }
    out.fixtures.push(argv[i])
  }
  return out
}

function stripExports(src) {
  return src.replace(/^export\s+/mg, '')
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
function buildFixtureAgent(fixture, calls, missing) {
  const cursors = new Map()
  return async (prompt, opts) => {
    const label = opts && opts.label
    const entry = { label: label || null, hasSchema: !!(opts && opts.schema) }
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
  return new Function(
    'args', 'agent', 'log', 'phase',
    'return (async () => {\n' + fpSrcStripped + '\n})()',
  )
}

function check(fixture, result, logs) {
  const exp = fixture.expect || {}
  const problems = []
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
  if (Array.isArray(exp.logsInclude)) {
    for (const needle of exp.logsInclude) {
      if (!logs.some((l) => l.includes(needle))) problems.push(`logs: missing "${needle}"`)
    }
  }
  return problems
}

async function runOne(fixturePath, fpSrcStripped) {
  const fixture = JSON.parse(fs.readFileSync(fixturePath, 'utf-8'))
  if (!fixture.name) fixture.name = path.basename(fixturePath, '.json')
  if (!fixture.calls || typeof fixture.calls !== 'object') {
    throw new Error(`[offline] fixture "${fixture.name}" has no "calls" object`)
  }
  if (fixture.args && fixture.args.simulate) {
    throw new Error(`[offline] fixture "${fixture.name}" sets args.simulate — this harness runs the REAL parsers, never simulate mode`)
  }
  const logs = []
  const calls = []
  const missing = []
  const log = (m) => { logs.push(String(m)) }
  const agent = buildFixtureAgent(fixture, calls, missing)
  const run = buildPipelineRunner(fpSrcStripped)
  const expThrows = fixture.expect && fixture.expect.throws
  if (typeof expThrows === 'string') {
    let err = null
    try { await run({ ...(fixture.args || {}) }, agent, log, () => {}) } catch (e) { err = e }
    const problems = []
    if (!err) problems.push(`throws: expected an error containing "${expThrows}", but the run did not throw`)
    else if (!String(err.message).includes(expThrows)) problems.push(`throws: expected message containing "${expThrows}", got "${err.message}"`)
    if (calls.length) problems.push(`throws: ${calls.length} agent() call(s) happened before the refusal (${calls.map((c) => c.label || c).join(', ')})`)
    return { fixture, result: { status: 'threw' }, logs, calls, problems }
  }
  const result = await run({ ...(fixture.args || {}) }, agent, log, () => {})
  const problems = check(fixture, result, logs)
  for (const m of missing) problems.push(`unanswered call (engine swallowed the error): ${m}`)
  return { fixture, result, logs, calls, problems }
}

async function main() {
  const { fp, all, fixtures } = parseArgs(process.argv.slice(2))
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

main().catch((err) => {
  console.error(err && err.stack ? err.stack : String(err))
  process.stdout.write('[offline] status=harness-error passed=0 failed=0\n')
  process.exit(1)
})
