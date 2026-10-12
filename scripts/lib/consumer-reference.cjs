'use strict'
// consumer-reference.cjs — the rule behind the `consumer-reference` guard (#414). Pure functions, stdlib only:
// extract the names a consumer can meet, parse docs/consumer-reference.md, and compare both with the baseline.
// The extractors are patterns, not parsers: a name built at run time (`secret-${id}`, a reason carried by a
// helper object) is not extracted. Nothing here runs the engine or the assembler, and nothing reads git.

const fs = require('fs')
const path = require('path')
const { stripComments } = require('./guards-scan.cjs')

const WORKFLOW = 'workflows/deliver-pipeline.js'
const ASSEMBLER_FILES = ['scripts/runtime/agent-context.cjs', 'scripts/lib/agent-context-text.cjs', 'scripts/lib/agent-context-lanes.cjs']
const REFERENCE_PATH = 'docs/consumer-reference.md'

// Family keys of the baseline and of the extraction, with the `## ` heading of each family in the reference.
// Prerequisites have no extractor: their rows are only checked for an empty remedy.
const FAMILIES = [
  ['config', 'Configuration keys'],
  ['assembler', 'Assembler refusals'],
  ['warnings', 'Assembler warnings'],
  ['reasons', 'Run reasons'],
  ['hooks', 'Hook messages'],
]
const PREREQUISITES_HEADING = 'Prerequisites'

const readText = (root, relativePath) => fs.readFileSync(path.join(root, relativePath), 'utf8')
const sorted = (set) => [...set].sort()

function extractReasons(root) {
  const source = stripComments(readText(root, WORKFLOW))
  const names = new Set()
  for (const line of source.split('\n')) {
    if (!/finish\(|code: '|action: 'escalate'|^\s*reason:/.test(line)) continue
    for (const match of line.matchAll(/\breason:\s*[`'"]([A-Za-z][A-Za-z0-9]*(?:-[A-Za-z0-9]+)+)(?=[:'"`])/g)) names.add(match[1])
  }
  return sorted(names)
}

function extractAssembler(root) {
  const names = new Set()
  for (const file of ASSEMBLER_FILES) {
    const source = stripComments(readText(root, file))
    for (const match of source.matchAll(/(?<![A-Za-z0-9${}-])([a-z][a-z0-9]*(?:-[a-z0-9]+)*) at line/g)) names.add(match[1])
    for (const match of source.matchAll(/\bhit\('([a-z][a-z0-9-]*)'/g)) names.add(match[1])
  }
  return sorted(names)
}

// Warnings: the keys of WARNING_REMEDY are the only kinds `warningLines` prints. `oversize`, `shared-oversize` and
// `total-oversize` have no remedy entry and print no warning line, so they are not names. A text pattern over one object literal.
function extractWarnings(root) {
  const source = stripComments(readText(root, 'scripts/lib/agent-context-lanes.cjs'))
  const start = source.indexOf('const WARNING_REMEDY = {')
  if (start < 0) return []
  const body = source.slice(start, source.indexOf('\n}\n', start))
  return sorted(new Set([...body.matchAll(/^\s*'([a-z][a-z0-9-]*)':/gm)].map((match) => match[1])))
}

// Engine: `config.<key>` / `config?.<key>` outside comments. Assembler: inside `readConfig` only, elsewhere its
// `config` is its own normalised object.
function extractConfig(root) {
  const names = new Set()
  const workflow = stripComments(readText(root, WORKFLOW))
  for (const match of workflow.matchAll(/(?<![.\w])config\??\.([A-Za-z]+)/g)) names.add(match[1])
  const assembler = stripComments(readText(root, 'scripts/runtime/agent-context.cjs'))
  const start = assembler.indexOf('function readConfig(')
  if (start >= 0) {
    const body = assembler.slice(start, assembler.indexOf('\n}\n', start))
    for (const match of body.matchAll(/(?<![.\w])config\.([A-Za-z]+)/g)) names.add(match[1])
  }
  return sorted(names)
}

// Hook messages: name = `<script>: <prefix>`, comment lines skipped, test files skipped.
function extractHooks(root) {
  const names = new Set()
  const folder = path.join(root, 'hooks')
  const files = fs.readdirSync(folder).filter((file) => file.endsWith('.sh') && !file.startsWith('test-')).sort()
  for (const file of files) {
    for (const line of readText(root, `hooks/${file}`).split('\n')) {
      if (/^\s*#/.test(line)) continue
      for (const match of line.matchAll(/(?:echo|deny) "(BLOCKED by [a-z-]+ gate|BLOCKED|WARNING|probe)(?=:)/g)) names.add(`${file}: ${match[1]}`)
      for (const match of line.matchAll(/deny "(.+?) is denied for agent sessions/g)) names.add(`${file}: ${match[1]}`)
      for (const match of line.matchAll(/deny "(jq) is required/g)) names.add(`${file}: ${match[1]} is required`)
      for (const match of line.matchAll(/\$\{msg\}(.+?)(?: \(|:)/g)) names.add(`${file}: ${match[1]}`)
    }
  }
  return sorted(names)
}

function extractNames(root) {
  return { config: extractConfig(root), assembler: extractAssembler(root), warnings: extractWarnings(root), reasons: extractReasons(root), hooks: extractHooks(root) }
}

// Rows of one table: the first code span of the first cell is the name, the fourth cell is the remedy.
function parseRow(line) {
  const cells = line.trim().replace(/^\|/, '').replace(/\|$/, '').split(/(?<!\\)\|/).map((cell) => cell.trim())
  if (cells.length < 2 || /^:?-{3,}:?$/.test(cells[0])) return null
  const span = /`([^`]+)`/.exec(cells[0])
  if (!span) return null
  return { name: span[1], remedy: (cells[3] || '').trim() }
}

// Per `## ` heading, the rows of the tables under it: { heading: [{ name, remedy }] }.
function parseReference(markdown) {
  const families = {}
  let current = null
  for (const line of markdown.split('\n')) {
    const heading = /^## (.+?)\s*$/.exec(line)
    if (heading) { current = heading[1]; families[current] = []; continue }
    if (current === null || !line.trim().startsWith('|')) continue
    const row = parseRow(line)
    if (row) families[current].push(row)
  }
  return families
}

// One message per failure. `names` and `baseline` map a family key to a list; `rows` maps a heading to its rows;
// `baseBaseline` is the baseline on origin/main (null when it does not exist there yet: nothing to compare with).
function problems({ names, rows, baseline, baseBaseline }) {
  const found = []
  const fail = (heading, name, reason) => found.push(`FAIL: consumer-reference: ${heading} '${name}' ${reason} (${REFERENCE_PATH})`)
  for (const [key, heading] of FAMILIES) {
    const rowNames = new Set((rows[heading] || []).map((row) => row.name))
    const baselineNames = new Set(baseline[key] || [])
    const emitted = new Set(names[key])
    const baseNames = baseBaseline ? new Set(baseBaseline[key] || []) : null
    for (const name of emitted) if (!rowNames.has(name) && !baselineNames.has(name)) fail(heading, name, 'has no row and is not in the baseline')
    for (const name of rowNames) if (!emitted.has(name)) fail(heading, name, 'has a row but the code no longer emits it')
    for (const name of baselineNames) {
      if (!emitted.has(name)) fail(heading, name, 'is in the baseline but the code no longer emits it')
      else if (rowNames.has(name)) fail(heading, name, 'is in the baseline but already has a row, remove it from the baseline')
      if (baseNames && !baseNames.has(name)) fail(heading, name, 'is not in the baseline of origin/main, the baseline may not grow')
    }
  }
  for (const heading of [...FAMILIES.map(([, title]) => title), PREREQUISITES_HEADING]) {
    for (const row of rows[heading] || []) if (row.remedy === '') fail(heading, row.name, 'has an empty remedy')
  }
  return found
}

module.exports = { REFERENCE_PATH, FAMILIES, PREREQUISITES_HEADING, extractNames, parseReference, problems }
