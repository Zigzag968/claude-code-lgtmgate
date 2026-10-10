#!/usr/bin/env node
'use strict'

// Reports which files /lgtmgate:init copied into a consumer repo differ from the current plugin template (#38).
// Same family as scripts/config-check.cjs: a data table, read-only, stdlib only, no network, no model call,
// ALWAYS exit 0 (a failure is a warn line, never a throw). A deliberate customisation reads as "differs".
//
// Usage: node scripts/template-drift.cjs --root <consumer root>
// Stdout: zero or more `warn:` / `info:` lines, an `order:` block when something needs action, then the last line
//         [template-drift] status=ok|warn read=<n> optional=<n> differs=<n> absent=<n>

const fs = require('fs')
const path = require('path')
const crypto = require('crypto')

// One row per file init copies (skills/init/SKILL.md section 1), relative to the consumer root and to the plugin root.
// role: read-by-engine (the engine reads it: a gap is a warn), optional, unused-by-engine (info only),
//       legacy-name (an old spelling compared with the new template, never counted as a copy).
const TARGETS = [
  { target: '.claude/rules/pr-acceptance.md', template: 'templates/pr-acceptance.md', role: 'read-by-engine' },
  { target: 'scripts/provision-worktree.sh', template: 'templates/provision-worktree.sh', role: 'read-by-engine' },
  { target: '.claude/scripts/blocked-by-check.sh', template: 'templates/blocked-by-check.sh', role: 'optional' },
  { target: '.claude/scripts/gh-pipeline-status.sh', template: 'templates/gh-pipeline-status.sh', role: 'unused-by-engine' },
  { target: '.claude/workflows/test-deliver-pipeline.js', template: 'templates/test-deliver-pipeline.js', role: 'unused-by-engine' },
  { target: 'scripts/provision_worktree.sh', template: 'templates/provision-worktree.sh', role: 'legacy-name' }
]

const ORDER = [
  'order: 1. fix the config first (the config-check output above)',
  'order: 2. then the copies listed above, keeping a deliberate customisation',
  'order: 3. commit and push on the base branch before the next run (the worktree reads the committed content)'
]

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

function check(root, pluginRoot) {
  try {
    if (!fs.statSync(root).isDirectory()) throw new Error('not a directory')
    fs.readdirSync(root)
  } catch (error) {
    return { lines: [`warn: ${root} is not a readable directory (${error.message}); usage: node scripts/template-drift.cjs --root <consumer root>`], read: 0, optional: 0, differs: 0, absent: 0 }
  }
  const lines = []
  const count = { read: 0, optional: 0, differs: 0, absent: 0 }
  for (const row of TARGETS) {
    const consumerFile = path.join(root, row.target)
    const templateFile = path.join(pluginRoot, row.template)
    const legacy = row.role === 'legacy-name'
    const level = row.role === 'read-by-engine' ? 'warn' : 'info'
    if (!exists(consumerFile)) {
      if (legacy) continue
      count.absent++
      if (row.role === 'read-by-engine') lines.push(`warn: ${row.target} [${row.role}] absent; install it: /lgtmgate:init (choose "complete"), section 1 copies ${row.template}`)
      else lines.push(`info: ${row.target} [${row.role}] absent`)
      continue
    }
    if (legacy) {
      const fix = exists(path.join(root, 'scripts/provision-worktree.sh'))
        ? `git rm ${row.target}`
        : `git mv ${row.target} scripts/provision-worktree.sh`
      lines.push(`warn: ${row.target} [${row.role}] still present; the engine reads scripts/provision-worktree.sh first: ${fix}`)
      continue
    }
    if (row.role === 'read-by-engine') count.read++
    else count.optional++
    if (digest(consumerFile) !== digest(templateFile)) {
      count.differs++
      lines.push(`${level}: ${row.target} [${row.role}] differs from the current template; compare: diff ${row.target} \${CLAUDE_PLUGIN_ROOT}/${row.template}`)
    }
  }
  if (lines.length) lines.push(...ORDER)
  return Object.assign({ lines }, count)
}

function main() {
  let result
  try {
    const root = rootArgument(process.argv)
    result = root
      ? check(path.resolve(root), path.join(__dirname, '..'))
      : { lines: ['warn: no --root given; usage: node scripts/template-drift.cjs --root <consumer root>'], read: 0, optional: 0, differs: 0, absent: 0 }
  } catch (error) {
    result = { lines: [`warn: template drift check failed (${error && error.message})`], read: 0, optional: 0, differs: 0, absent: 0 }
  }
  const status = result.lines.some((line) => line.startsWith('warn:')) ? 'warn' : 'ok'
  const trailer = `[template-drift] status=${status} read=${result.read} optional=${result.optional} differs=${result.differs} absent=${result.absent}`
  process.stdout.write(result.lines.concat(trailer).join('\n') + '\n')
  process.exitCode = 0
}

main()
