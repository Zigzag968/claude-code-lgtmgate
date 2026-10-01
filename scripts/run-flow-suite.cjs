#!/usr/bin/env node
'use strict'

// Offline runner for templates/test-deliver-pipeline.js (claude-agent-pipeline#51).
// `templates/test-deliver-pipeline.js:2` states "Run by the Lead; agents have no
// Workflow tool" — without this runner no flow-suite acceptance item is
// Morgan-verifiable. Ported from an internal reference implementation's
// test-support harness (single-pipeline
// harness), extended with a `workflow(ref, args)` mock so it can run the SUITE
// (which itself calls `workflow(FP_REF, ...)` once per case), not just one pipeline
// invocation.
//
// Coupling to deliver-pipeline.js / test-deliver-pipeline.js (update this file if any
// of the four change):
//   1. The export-strip regex `/^export\s+/mg` — strips the leading `export` keyword
//      from any top-level `export const ...` / `export function ...` so each body can
//      be wrapped in a plain async function.
//   2. Pipeline-scope injected globals — `args`, `agent`, `log`, `phase`
//      (deliver-pipeline.js never consumes `workflow`, `parallel` or `bash`).
//   3. Suite-scope injected globals — `args`, `log`, `workflow`
//      (templates/test-deliver-pipeline.js:91-95 reads `args.fpScriptPath`; the suite
//      never consumes `agent` or `phase` directly — it drives the pipeline only
//      through `workflow()`).
//   4. `workflow(ref, args)` resolves `ref.scriptPath` ONLY — a bare-name `ref` is a
//      HARNESS-SIDE default (see buildWorkflowMock below), never registry resolution.
//      If a case starts passing a bare name expecting real registry behavior, this
//      mock and the suite's own resolution guard (`_probe` / `_gateProbe`,
//      templates/test-deliver-pipeline.js:98-132) will disagree — that is a suite bug
//      to fix in the suite, not in this runner.
//
// Usage: node scripts/run-flow-suite.cjs [--suite <path>] [--fp <path>]
//   Defaults: --suite templates/test-deliver-pipeline.js, --fp workflows/deliver-pipeline.js
//   (#54 — the canonical pipeline moved from templates/ to workflows/, the plugin's
//   default-scanned workflow-component directory; the suite stays under templates/.)
//   Passes args.fpScriptPath = <fp> to the suite so its own pin
//   (templates/test-deliver-pipeline.js:83-105) is exercised — NEVER name resolution
//   (the stale-name-resolved-copy-reads-as-broken trap).
//
// Last stdout line (always, trailing newline), fixed literal:
//   [flow-suite] status=<status> passed=<n> failed=<n>
// This repo has no run_trailer.py; this line is its run-completion equivalent and is
// what the acceptance items `tail -n 1`. It is a CAPTURE MARKER, never a threshold —
// callers diff FAIL-line NAME SETS against a baseline, they never gate on this number.
//
// Exit code: 0 whenever the suite RAN TO COMPLETION (regardless of how many cases
// failed — a capture-only baseline run must never read as a failed proof by exit code
// alone). Non-zero is reserved for a harness/load error (bad args, unreadable file,
// wrong-copy-resolved abort) — those are real tool failures, distinct from "the suite
// ran and some cases failed". This default is UNCHANGED and stays the default: a
// capture-only baseline run (agent/dev manual invocation, CONTRIBUTING.md) always
// exits 0 on completion.
//
// FLOW_SUITE_STRICT=1 (opt-in, set by .github/workflows/guards.yml only) turns the
// capture marker into a real CI gate: exit 1 if any case failed, exit 0 otherwise.
// This does not touch the harness-error path (already exit 1, unconditional).

const fs = require('fs')
const path = require('path')

function parseArgs(argv) {
  const out = { suite: 'templates/test-deliver-pipeline.js', fp: 'workflows/deliver-pipeline.js' }
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--suite' && argv[i + 1]) { out.suite = argv[++i]; continue }
    if (argv[i] === '--fp' && argv[i + 1]) { out.fp = argv[++i]; continue }
  }
  return out
}

function stripExports(src) {
  return src.replace(/^export\s+/mg, '')
}

// agent() throws — under `simulate` mode every agent() call site inside
// deliver-pipeline.js must be short-circuited by a simulate.* fixture (via
// callAgent -> simFixture). Reaching a real agent() call is a payload/harness
// coupling bug and must fail loudly, never silently mock a default response.
async function deadAgent() {
  throw new Error('agent() called — simulate fixture missing')
}
const noopPhase = () => {}

// Runs the REAL deliver-pipeline.js body (already export-stripped source) under the
// pipeline-scope globals. Mirrors run_feature_pipeline_sim.cjs's `new Function` wrap.
function buildPipelineRunner(fpSrcStripped, log) {
  // eslint-disable-next-line no-new-func
  const fn = new Function(
    'args', 'agent', 'log', 'phase',
    'return (async () => {\n' + fpSrcStripped + '\n})()',
  )
  return async (args) => fn(args, deadAgent, log, noopPhase)
}

// workflow(ref, args) mock — resolves ref.scriptPath ONLY (harness-side default; see
// the header note above). Re-runs the pipeline body fresh on every call, matching real
// Workflow-tool semantics (no cross-call state leaks between cases).
function buildWorkflowMock(log) {
  return async (ref, args) => {
    const scriptPath = ref && typeof ref === 'object' ? ref.scriptPath : null
    if (!scriptPath) {
      throw new Error(
        `run-flow-suite workflow() mock: only { scriptPath } refs are resolved (harness-side ` +
        `default, never registry resolution) — got ${JSON.stringify(ref)}`)
    }
    const src = stripExports(fs.readFileSync(scriptPath, 'utf-8'))
    const run = buildPipelineRunner(src, log)
    return run(args)
  }
}

async function main() {
  const { suite, fp } = parseArgs(process.argv.slice(2))
  const suitePath = path.resolve(suite)
  const fpPath = path.resolve(fp)

  const lines = []
  const log = (msg) => { lines.push(String(msg)) }

  const suiteSrcStripped = stripExports(fs.readFileSync(suitePath, 'utf-8'))
  const workflow = buildWorkflowMock(log)
  // fpSource: raw pipeline text for source-anchored cases (#214) — agentDeathRouting table and
  // STRUCTURED_OUTPUT_MANDATE are unreachable through simulate-mode workflow() runs.
  // repoConfig: this repo's own `.claude/pipeline.config.json` (null if absent), for cases that pin the
  // repo's declared `oneWayDoorPaths`, `oneWayDoorKinds` and `engineRepo` flag (T77b, T77f, T77m, T163c); the
  // engine has no filesystem.
  let repoConfig = null
  try { repoConfig = JSON.parse(fs.readFileSync(path.resolve('.claude/pipeline.config.json'), 'utf-8')) } catch (_) { repoConfig = null }
  const suiteArgs = { fpScriptPath: fpPath, fpSource: fs.readFileSync(fpPath, 'utf-8'), repoConfig }

  // eslint-disable-next-line no-new-func
  const suiteFn = new Function(
    'args', 'log', 'workflow',
    'return (async () => {\n' + suiteSrcStripped + '\n})()',
  )

  let result
  try {
    result = await suiteFn(suiteArgs, log, workflow)
  } catch (e) {
    for (const l of lines) process.stderr.write(l + '\n')
    process.stderr.write((e && e.stack ? e.stack : String(e)) + '\n')
    process.stdout.write(`[flow-suite] status=harness-error passed=0 failed=0\n`)
    process.exit(1)
  }

  for (const l of lines) process.stdout.write(l + '\n')

  const status = result && result.status ? result.status : 'unknown'
  const passed = result && Number.isInteger(result.passed) ? result.passed : 0
  const failed = result && Number.isInteger(result.failed) ? result.failed : 0
  // Trailer written LAST with a trailing newline, and the suite's JSON result is never
  // dumped to stdout (advisory note 4) — the capture-only baseline item `tail -n 1`s
  // this line, and a raw JSON tail would make that assertion fail on a correct
  // implementation for a reason unrelated to the fold under test.
  process.stdout.write(`[flow-suite] status=${status} passed=${passed} failed=${failed}\n`)
  // Exit 0 whenever the suite ran to completion, regardless of `failed` — see the
  // header note. A capture-only baseline run must never read as a failed proof.
  // FLOW_SUITE_STRICT=1 (opt-in, guards.yml only) turns `failed > 0` into a real
  // non-zero exit — see the header note above.
  const strict = process.env.FLOW_SUITE_STRICT === '1'
  process.exit(strict && failed > 0 ? 1 : 0)
}

main().catch((err) => {
  console.error(err && err.stack ? err.stack : String(err))
  process.stdout.write(`[flow-suite] status=harness-error passed=0 failed=0\n`)
  process.exit(1)
})
