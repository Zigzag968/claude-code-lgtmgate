'use strict'
// count-tests.cjs — the offline test counts, taken from the suites' own summary lines (#159). stdlib only.
// README.md states these numbers and the `readme-contract` guard recomputes them; the Tests badge is produced from the same total.
// The canonical guard net (tests/templates/test-canonical-guards.sh) is NOT counted: it runs scripts/guards.cjs, which would recurse.

const { spawnSync } = require('child_process')

// pattern: first group = passed count; second group (when present) must equal the first. needsOk: the stream must also hold a line starting with OK.
const SUITES = [
  { label: 'scripts/run-flow-suite.cjs', argv: ['node', 'scripts/run-flow-suite.cjs'], stream: 'stdout', pattern: /^Results: (\d+)\/(\d+) passed/m },
  { label: 'plugins/backlog/tests/', argv: ['python3', '-B', '-m', 'unittest', 'discover', '-s', 'plugins/backlog/tests'], stream: 'stderr', pattern: /^Ran (\d+) tests? /m, needsOk: true },
  { label: 'tests/templates/test-blocked-by-check.sh', argv: ['bash', 'tests/templates/test-blocked-by-check.sh'], stream: 'stdout', pattern: /^(\d+)\/(\d+) PASS$/m },
  { label: 'tests/hooks/test-Stop-supervise-runs.sh', argv: ['bash', 'tests/hooks/test-Stop-supervise-runs.sh'], stream: 'stdout', pattern: /^(\d+)\/(\d+) PASS$/m },
  { label: 'tests/hooks/test-deny-destructive-git.sh', argv: ['bash', 'tests/hooks/test-deny-destructive-git.sh'], stream: 'stdout', pattern: /^(\d+)\/(\d+) PASS$/m },
]

// parse(suite, { status, stdout, stderr }) -> { count } or { error }
function parse(suite, result) {
  if (result.status !== 0) return { error: `exit status ${result.status}` }
  const text = String(result[suite.stream] || '')
  const match = suite.pattern.exec(text)
  if (!match) return { error: `no summary line in ${suite.stream}` }
  if (match[2] !== undefined && match[1] !== match[2]) return { error: `${match[1]} passed of ${match[2]}` }
  if (suite.needsOk && !/^OK/m.test(text)) return { error: 'no OK line' }
  return { count: Number(match[1]) }
}

// countAll(root) -> { counts: { <label>: n }, total }; throws Error('<label>: <reason>') on the first suite that fails.
function countAll(root) {
  const counts = {}
  let total = 0
  for (const suite of SUITES) {
    const [command, ...rest] = suite.argv
    const ran = spawnSync(command, rest, { cwd: root, encoding: 'utf8', timeout: 300000, maxBuffer: 1 << 26, env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' } })
    const parsed = parse(suite, { status: ran.error ? null : ran.status, stdout: ran.stdout, stderr: ran.stderr })
    if (parsed.error) throw new Error(`${suite.label}: ${parsed.error}`)
    counts[suite.label] = parsed.count
    total += parsed.count
  }
  return { counts, total }
}

// The Shields endpoint payload: the three required fields plus the optional color.
function endpointJson(total) {
  return { schemaVersion: 1, label: 'tests', message: `${total} offline`, color: 'brightgreen' }
}

module.exports = { SUITES, parse, countAll, endpointJson }
