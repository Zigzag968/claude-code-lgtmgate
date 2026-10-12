'use strict'
// readme-contract.cjs — the rule behind the `readme-contract` guard (#159). stdlib only, reads files, never git.
// README.md keeps its status and limitations sections, its dynamic badges, a row for every configuration key,
// every environment variable the scripts read, and the test numbers the suites report.

const fs = require('fs')
const path = require('path')
const { extractConfig } = require('./consumer-reference.cjs')
const countTests = require('./count-tests.cjs')

const SECTIONS = ['Status', 'Known limitations', 'Use at your own risk', 'Local overrides and environment variables']
const ENV_SECTION = 'Local overrides and environment variables'
const BADGES = [
  'actions/workflows/guards.yml/badge.svg',
  'actions/workflows/dynamic/github-code-scanning/codeql/badge.svg',
  'img.shields.io/github/v/release/',
  'img.shields.io/github/last-commit/',
  'img.shields.io/github/license/',
  'img.shields.io/endpoint?url=',
  'img.shields.io/badge/maturity-',
]
const ENV_FOLDERS = ['scripts', 'hooks', 'templates']
const ENV_EXTENSIONS = new Set(['.sh', '.cjs', '.js', '.py'])
const ENV_NAME = /\b(?:LGTMGATE|LEAD_MERGE|PROBE_EVALS)_[A-Z0-9_]+/g
const FAIL = 'FAIL: readme-contract:'

const readOr = (file) => (fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null)

// Text of the `## <title>` section, up to the next `## ` heading; null when absent.
function section(readme, title) {
  const lines = readme.split('\n')
  const at = lines.findIndex((line) => line.replace(/\s+$/, '') === `## ${title}`)
  if (at === -1) return null
  const next = lines.findIndex((line, index) => index > at && /^## /.test(line))
  return lines.slice(at + 1, next === -1 ? lines.length : next).join('\n')
}

// Config keys documented: the leading identifier of every code span in the first cell of every table row.
function documentedKeys(readme) {
  const keys = new Set()
  for (const line of readme.split('\n')) {
    if (!line.startsWith('|')) continue
    const first = line.replace(/^\|/, '').split(/(?<!\\)\|/)[0]
    for (const span of first.matchAll(/`([^`]+)`/g)) {
      const identifier = /^[A-Za-z][A-Za-z0-9]*/.exec(span[1])
      if (identifier) keys.add(identifier[0])
    }
  }
  return keys
}

function walk(folder) {
  if (!fs.existsSync(folder)) return []
  const found = []
  for (const entry of fs.readdirSync(folder, { withFileTypes: true })) {
    const child = path.join(folder, entry.name)
    if (entry.isDirectory()) found.push(...walk(child))
    else if (entry.isFile() && !entry.name.startsWith('test-') && ENV_EXTENSIONS.has(path.extname(entry.name))) found.push(child)
  }
  return found.sort()
}

// Environment variables of the guarded families read by the code (whole-line comments skipped): name -> first file.
function environmentNames(root) {
  const files = ENV_FOLDERS.flatMap((folder) => walk(path.join(root, folder)))
  const engine = path.join(root, 'workflows/deliver-pipeline.js')
  if (fs.existsSync(engine)) files.push(engine)
  const names = new Map()
  for (const file of files) {
    for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
      if (/^\s*(#|\/\/)/.test(line)) continue
      for (const match of line.matchAll(ENV_NAME)) if (!names.has(match[0])) names.set(match[0], path.relative(root, file))
    }
  }
  return names
}

function escapeRegex(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

function countProblems(readme, counts) {
  const found = []
  const claim = /(\d+) offline test cases across (\d+) suites/.exec(readme)
  if (!claim) return [`${FAIL} README.md has no "<n> offline test cases across <k> suites" statement`]
  const total = Object.values(counts).reduce((sum, n) => sum + n, 0)
  if (Number(claim[1]) !== total) found.push(`${FAIL} README.md states ${claim[1]} offline test cases, the suites report ${total}`)
  if (Number(claim[2]) !== countTests.SUITES.length) found.push(`${FAIL} README.md states ${claim[2]} suites, there are ${countTests.SUITES.length}`)
  for (const suite of countTests.SUITES) {
    const stated = new RegExp('`' + escapeRegex(suite.label) + '` \\((\\d+)').exec(readme)
    if (!stated) found.push(`${FAIL} README.md does not state the count of suite ${suite.label}`)
    else if (Number(stated[1]) !== counts[suite.label]) found.push(`${FAIL} README.md states ${stated[1]} for suite ${suite.label}, the suite reports ${counts[suite.label]}`)
  }
  return found
}

// problems(root, countsFile) -> FAIL messages (empty when clean). countsFile: JSON map label -> count; absent, the suites run.
function problems(root, countsFile) {
  const readme = readOr(path.join(root, 'README.md'))
  if (readme === null) return [`${FAIL} README.md is missing`]
  const found = []
  for (const title of SECTIONS) if (section(readme, title) === null) found.push(`${FAIL} README.md has no section '## ${title}'`)
  const status = section(readme, 'Status')
  if (status !== null) for (const word of ['stable', 'beta']) if (!status.includes(word)) found.push(`${FAIL} the Status section does not name the channel '${word}'`)
  for (const badge of BADGES) if (!readme.includes(badge)) found.push(`${FAIL} README.md has no dynamic badge '${badge}'`)
  for (const match of readme.matchAll(/img\.shields\.io\/badge\/[^)\s"]*/g)) {
    if (/\d/.test(match[0])) found.push(`${FAIL} hand-written number in badge URL: ${match[0]}`)
  }
  const documented = documentedKeys(readme)
  const required = new Map(extractConfig(root).map((key) => [key, 'workflows/deliver-pipeline.js']))
  const template = readOr(path.join(root, 'templates/pipeline.config.template.json'))
  if (template !== null) {
    try { for (const key of Object.keys(JSON.parse(template))) if (!required.has(key)) required.set(key, 'top-level key of templates/pipeline.config.template.json') } catch (_) { found.push(`${FAIL} templates/pipeline.config.template.json is not valid JSON`) }
  }
  for (const [key, source] of required) if (!documented.has(key)) found.push(`${FAIL} the configuration table has no row for config key '${key}' (${source})`)
  const environmentText = section(readme, ENV_SECTION) || ''
  for (const [name, file] of environmentNames(root)) if (!environmentText.includes('`' + name + '`')) found.push(`${FAIL} the section '${ENV_SECTION}' does not document environment variable ${name} (read in ${file})`)
  let counts
  try {
    counts = countsFile ? JSON.parse(fs.readFileSync(countsFile, 'utf8')) : countTests.countAll(root).counts
  } catch (error) {
    return [...found, `${FAIL} cannot get the test counts: ${error.message}`]
  }
  return [...found, ...countProblems(readme, counts)]
}

module.exports = { problems, section, documentedKeys, environmentNames }
