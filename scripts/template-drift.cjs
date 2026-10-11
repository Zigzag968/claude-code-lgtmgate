#!/usr/bin/env node
'use strict'

// Reports which files /lgtmgate:init copied into a consumer repo are gone stale, and states for each line the
// verdict and the gesture (#38, #426). Same family as scripts/config-check.cjs: a data table, read-only, stdlib
// only, no network, no model call, ALWAYS exit 0 (a failure is a line, never a throw). A deliberate customisation
// reads as "differs" and is never overwritten.
//
// Usage: node scripts/template-drift.cjs --root <consumer root>
// Stdout: zero or more `obsolete:` / `warn:` / `info:` lines, then either an `order:` block (some line asks for an
//         action) or the single `next:` line, then the last line
//         [template-drift] status=ok|warn read=<n> optional=<n> differs=<n> absent=<n>
//         status=warn exactly when one line asks for an action (fix before / remove before).

const fs = require('fs')
const path = require('path')
const crypto = require('crypto')

// One row per file a consumer may hold, relative to the consumer root and to the plugin root.
// role: obsolete (init no longer copies it and no code reads it: remove it), fallback (the engine runs the plugin's
//       own script when the Lead passes the plugin root, as /lgtmgate:deliver always does, and reads this copy only
//       on a run without one), optional (an install slot the engine does not read), legacy-name (an old spelling
//       compared with the new template, never counted as a copy).
const TARGETS = [
  { target: '.claude/rules/pr-acceptance.md', template: 'templates/pr-acceptance.md', role: 'obsolete', note: ' (an agent reads every rule file that exists, so a stale copy can contradict the plugin)', verdict: 'remove before the run' },
  { target: '.claude/scripts/gh-pipeline-status.sh', template: 'templates/gh-pipeline-status.sh', role: 'obsolete', note: '', verdict: 'no effect on the run' },
  { target: '.claude/workflows/test-deliver-pipeline.js', template: 'templates/test-deliver-pipeline.js', role: 'obsolete', note: '', verdict: 'no effect on the run' },
  { target: 'scripts/provision-worktree.sh', template: 'templates/provision-worktree.sh', role: 'fallback' },
  { target: '.claude/scripts/blocked-by-check.sh', template: 'templates/blocked-by-check.sh', role: 'optional' },
  { target: 'scripts/provision_worktree.sh', template: 'templates/provision-worktree.sh', role: 'legacy-name' }
]

const NONE = 'no effect on the run'
const ASKS = ['fix before the run', 'remove before the run']

const ORDER = [
  'order: 1. fix the config first (the config-check output above)',
  'order: 2. then act on the lines above that ask for it, keeping a deliberate customisation',
  'order: 3. commit and push on the base branch before the next run (the worktree reads the committed content)'
]
const NEXT = 'next: nothing to do before the run, the next run can start'

function digest(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')
}

function exists(file) {
  try {
    return fs.statSync(file).isFile()
  } catch (error) {
    return false
  }
}

function rootArgument(argv) {
  const index = argv.indexOf('--root')
  return index >= 0 ? argv[index + 1] : undefined
}

const earlyFailure = (line) => ({ lines: [line], read: 0, optional: 0, differs: 0, absent: 0, early: true })

function check(root, pluginRoot) {
  try {
    if (!fs.statSync(root).isDirectory()) throw new Error('not a directory')
    fs.readdirSync(root)
  } catch (error) {
    return earlyFailure(`warn: ${root} is not a readable directory (${error.message}); fix before the run: node scripts/template-drift.cjs --root <consumer root>`)
  }
  const lines = []
  const count = { read: 0, optional: 0, differs: 0, absent: 0 }
  for (const row of TARGETS) {
    const consumerFile = path.join(root, row.target)
    const templateFile = path.join(pluginRoot, row.template)
    const present = exists(consumerFile)
    const compare = `diff ${row.target} \${CLAUDE_PLUGIN_ROOT}/${row.template}`
    if (row.role === 'obsolete') {
      if (present) lines.push(`obsolete: ${row.target} is no longer copied by init and the engine does not read it; remove it: git rm ${row.target}, commit, push; ${row.verdict}${row.note}`)
      continue
    }
    if (row.role === 'legacy-name') {
      if (!present) continue
      const fix = exists(path.join(root, 'scripts/provision-worktree.sh'))
        ? `clean up: git rm ${row.target}`
        : `rename it when convenient: git mv ${row.target} scripts/provision-worktree.sh`
      const fallback = exists(path.join(root, 'scripts/provision-worktree.sh')) ? 'the new name wins' : 'when no plugin root is passed the engine falls back to it while scripts/provision-worktree.sh is absent (the fallback goes under #364)'
      lines.push(`info: ${row.target} [${row.role}] still present; ${fallback}; ${NONE}; ${fix}`)
      continue
    }
    if (!present) {
      count.absent++
      if (row.role === 'optional') lines.push(`info: ${row.target} [${row.role}] absent; the engine does not read it; ${NONE}`)
      continue
    }
    if (row.role === 'fallback') count.read++
    else count.optional++
    if (digest(consumerFile) === digest(templateFile)) continue
    count.differs++
    if (row.role === 'fallback') {
      lines.push(`info: ${row.target} [${row.role}] differs from the current template; the engine reads it only on a run without a plugin root; ${NONE} otherwise; compare: ${compare}`)
      continue
    }
    lines.push(`info: ${row.target} [${row.role}] differs from the current template; the engine does not read it; ${NONE}; compare: ${compare}`)
  }
  const asks = lines.some((line) => ASKS.some((ask) => line.includes(ask)))
  lines.push(...(asks ? ORDER : [NEXT]))
  return Object.assign({ lines, asks }, count)
}

function main() {
  let result
  try {
    const root = rootArgument(process.argv)
    result = root
      ? check(path.resolve(root), path.join(__dirname, '..'))
      : earlyFailure('warn: no --root given; fix before the run: node scripts/template-drift.cjs --root <consumer root>')
  } catch (error) {
    result = earlyFailure(`warn: template drift check failed (${error && error.message}); fix before the run: node scripts/template-drift.cjs --root <consumer root>`)
  }
  const status = result.early || result.asks ? 'warn' : 'ok'
  const trailer = `[template-drift] status=${status} read=${result.read} optional=${result.optional} differs=${result.differs} absent=${result.absent}`
  process.stdout.write(result.lines.concat(trailer).join('\n') + '\n')
  process.exitCode = 0
}

main()
