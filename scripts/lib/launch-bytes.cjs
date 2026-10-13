'use strict'

// Guard `launch-bytes` (#527, slice P-01 of epic #528): the bytes of the `args` object of a workflow launch
// (scripts/runtime/launch-args.cjs) are measured on synthetic project contexts of 4, 22 and 60 KB
// (scripts/gen-launch-fixtures.cjs) and ratcheted against scripts/launch-bytes-baseline.json.
//
// Output: six lines, stage plan then review, sizes 4k, 22k, 60k:
//   LB launch-bytes stage=<s> size=<z> mode=full base=<baseline> branch=<measured> ok|UP
// UP (branch > base) counts one failure. Then, for the launch in mode ref at stage plan (#520), three lines and one:
//   LB launch-bytes stage=plan size=<z> mode=ref budget=2048 branch=<measured> ok|UP
//   LB launch-bytes flat spread=<max - min> ok|UP
// Then the same for the launch in mode ref at stage review (#533), which carries a worst-case planRef (64 hex, 25 paths of
// 40 characters, designStep, two lanes): three `stage=review ... mode=ref` lines and `LB launch-bytes flat stage=review spread=<n> ok|UP`.
// A ref line over the budget and a spread over 64 each count one failure (the FAIL line below it is the same failure, not a second). A baseline number is never raised to turn a run green: the only
// exception is a `"debt": "DEBT(#N)"` key in the baseline file, which lets the file hold a number larger
// than origin/main's. When origin/main holds the file, a larger number without that key is a failure
// (skipped silently when git or the file on origin is absent: the PR that introduces the file).
//
// Budget (on by default since #520): for stage plan in mode ref only, a ceiling of 2048 bytes per size and a spread of
// at most 64 bytes between 4k and 60k. LAUNCH_BYTES_BUDGET=off turns it off; any other value, or none, leaves it on.
// Mode full has no budget. Selection is GUARDS_ONLY only; the files measured are the ones
// under the root given (a copy under GUARDS_ROOT is what the test mutates).
// Rule module of scripts/guards.cjs, which cannot grow (MAX_LINES).

const fs = require('fs')
const os = require('os')
const path = require('path')
const { execFileSync } = require('child_process')

const SIZES = ['4k', '22k', '60k']
const STAGES = ['plan', 'review']
const BASELINE = 'scripts/launch-bytes-baseline.json'
const BUDGET_BYTES = 2048
const BUDGET_SPREAD = 64
const FIXED = { worktreePath: '/wt', pluginRoot: '/pl', sessionRoot: '/ss' }
// The worst-case planRef the review launch is measured with.
const WORST_PLAN_REF = {
  issue: 9999, digest: 'f'.repeat(64), targets: Array.from({ length: 25 }, (_, index) => `${'d'.repeat(36)}/${String(index).padStart(2, '0')}`.slice(0, 40)),
  designStep: true, lanes: ['engine-lane', 'consumer-lane'],
}

function measure(root) {
  const generator = require(path.join(root, 'scripts', 'gen-launch-fixtures.cjs'))
  const launch = require(path.join(root, 'scripts', 'runtime', 'launch-args.cjs'))
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'launch-bytes-'))
  const result = { plan: {}, review: {}, ref: { plan: {}, review: {} } }
  try {
    for (const size of SIZES) {
      const tree = path.join(directory, size)
      generator.makeTree(tree, size)
      for (const stage of STAGES) {
        const arguments_ = launch.build({ root: tree, ref: 'origin/main', stage, mode: 'full', ...FIXED })
        result[stage][size] = Buffer.byteLength(JSON.stringify(arguments_))
      }
      const reference = launch.build({ root: tree, ref: 'origin/main', stage: 'plan', mode: 'ref', ...FIXED })
      result.ref.plan[size] = Buffer.byteLength(JSON.stringify(reference))
      const review = launch.build({ root: tree, ref: 'origin/main', stage: 'review', mode: 'ref', pr: 99999, planRef: WORST_PLAN_REF, ...FIXED })
      result.ref.review[size] = Buffer.byteLength(JSON.stringify(review))
    }
  } finally {
    fs.rmSync(directory, { recursive: true, force: true })
  }
  return result
}

function budgetProblems(plan, mode, switchValue, stage = 'plan') {
  if (switchValue === 'off' || mode !== 'ref') return []
  const out = []
  const values = SIZES.map((z) => plan[z])
  for (const z of SIZES) if (plan[z] > BUDGET_BYTES) out.push(`${stage} ${z} is ${plan[z]} bytes, over the budget of ${BUDGET_BYTES}`)
  const spread = Math.max(...values) - Math.min(...values)
  if (spread > BUDGET_SPREAD) out.push(`${stage} spread between 4k and 60k is ${spread} bytes, over ${BUDGET_SPREAD}`)
  return out
}

function readBaseline(root) {
  try {
    const b = JSON.parse(fs.readFileSync(path.join(root, BASELINE), 'utf8'))
    for (const s of STAGES) for (const z of SIZES) if (!(b[s][z] > 0)) return null
    return b
  } catch (error) {
    return null
  }
}

function originBaseline(root) {
  try {
    const text = execFileSync('git', ['show', `origin/main:${BASELINE}`], { cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] })
    return JSON.parse(text)
  } catch (error) {
    return null
  }
}

// The mode ref lines of a stage (plan, then review) and the budget failures (each counted once); [] and no line when the switch is off.
function referenceLines(plan, out, stage = 'plan') {
  const problems = budgetProblems(plan, 'ref', process.env.LAUNCH_BYTES_BUDGET, stage)
  const off = process.env.LAUNCH_BYTES_BUDGET === 'off'
  for (const z of SIZES) out(`LB launch-bytes stage=${stage} size=${z} mode=ref budget=${off ? 'off' : BUDGET_BYTES} branch=${plan[z]} ${!off && plan[z] > BUDGET_BYTES ? 'UP' : 'ok'}`)
  const spread = Math.max(...SIZES.map((z) => plan[z])) - Math.min(...SIZES.map((z) => plan[z]))
  out(`LB launch-bytes flat${stage === 'plan' ? '' : ` stage=${stage}`} spread=${spread} ${!off && spread > BUDGET_SPREAD ? 'UP' : 'ok'}`)
  for (const message of problems) out(`FAIL: launch-bytes: ${message}`)
  return problems.length
}

function run(root, out) {
  const baseline = readBaseline(root)
  if (!baseline) {
    out(`FAIL: launch-bytes: ${BASELINE} is missing or invalid; see scripts/lib/launch-bytes.cjs`)
    return 1
  }
  let failed = 0
  let measured
  try {
    measured = measure(root)
  } catch (error) {
    out(`FAIL: launch-bytes: cannot measure (${String(error && error.message).split('\n')[0]})`)
    return 1
  }
  for (const s of STAGES) {
    for (const z of SIZES) {
      const up = measured[s][z] > baseline[s][z]
      if (up) failed++
      out(`LB launch-bytes stage=${s} size=${z} mode=full base=${baseline[s][z]} branch=${measured[s][z]} ${up ? 'UP' : 'ok'}`)
    }
  }
  const origin = originBaseline(root)
  if (origin && !/^DEBT\(#\d+\)$/.test(String(baseline.debt))) {
    for (const s of STAGES) {
      for (const z of SIZES) {
        if (origin[s] && origin[s][z] > 0 && baseline[s][z] > origin[s][z]) {
          out(`FAIL: launch-bytes: baseline ${s} ${z} ${baseline[s][z]} > origin/main ${origin[s][z]}`)
          failed++
        }
      }
    }
  }
  return failed + referenceLines(measured.ref.plan, out) + referenceLines(measured.ref.review, out, 'review')
}

module.exports = { run, measure, budgetProblems }
