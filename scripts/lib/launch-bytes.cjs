'use strict'

// Guard `launch-bytes` (#527, slice P-01 of epic #528): the bytes of the `args` object of a workflow launch
// (scripts/runtime/launch-args.cjs) are measured on synthetic project contexts of 4, 22 and 60 KB
// (scripts/gen-launch-fixtures.cjs) and ratcheted against scripts/launch-bytes-baseline.json.
//
// Output: six lines, stage plan then review, sizes 4k, 22k, 60k:
//   LB launch-bytes stage=<s> size=<z> mode=full base=<baseline> branch=<measured> ok|UP
// UP (branch > base) counts one failure. A baseline number is never raised to turn a run green: the only
// exception is a `"debt": "DEBT(#N)"` key in the baseline file, which lets the file hold a number larger
// than origin/main's. When origin/main holds the file, a larger number without that key is a failure
// (skipped silently when git or the file on origin is absent: the PR that introduces the file).
//
// Budget (off by default): LAUNCH_BYTES_BUDGET=on turns on, for stage plan in mode ref only, a ceiling of
// 2048 bytes per size and a spread of at most 64 bytes between 4k and 60k. Mode full has no budget;
// #520 lands mode ref and switches this on. Selection is GUARDS_ONLY only; the files measured are the ones
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

function measure(root) {
  const generator = require(path.join(root, 'scripts', 'gen-launch-fixtures.cjs'))
  const launch = require(path.join(root, 'scripts', 'runtime', 'launch-args.cjs'))
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'launch-bytes-'))
  const result = { plan: {}, review: {} }
  try {
    for (const size of SIZES) {
      const tree = path.join(directory, size)
      generator.makeTree(tree, size)
      for (const stage of STAGES) {
        const arguments_ = launch.build({ root: tree, ref: 'origin/main', stage, mode: 'full', ...FIXED })
        result[stage][size] = Buffer.byteLength(JSON.stringify(arguments_))
      }
    }
  } finally {
    fs.rmSync(directory, { recursive: true, force: true })
  }
  return result
}

function budgetProblems(plan, mode, switchValue) {
  if (switchValue !== 'on' || mode !== 'ref') return []
  const out = []
  const values = SIZES.map((z) => plan[z])
  for (const z of SIZES) if (plan[z] > BUDGET_BYTES) out.push(`plan ${z} is ${plan[z]} bytes, over the budget of ${BUDGET_BYTES}`)
  const spread = Math.max(...values) - Math.min(...values)
  if (spread > BUDGET_SPREAD) out.push(`plan spread between 4k and 60k is ${spread} bytes, over ${BUDGET_SPREAD}`)
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
  for (const message of budgetProblems(measured.plan, 'full', process.env.LAUNCH_BYTES_BUDGET)) {
    out(`FAIL: launch-bytes: ${message}`)
    failed++
  }
  return failed
}

module.exports = { run, measure, budgetProblems }
