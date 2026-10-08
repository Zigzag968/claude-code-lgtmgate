#!/usr/bin/env node
'use strict'
// audit.cjs — code-quality ratchet (node, stdlib + child_process). Size, naming and suppression comments.
//
//   node scripts/audit.cjs --report   print the findings as { "<file>": { "<rule>": <count> } } (the baseline format)
//   node scripts/audit.cjs --check    compare them with <target>/scripts/audit-baseline.json: a (file, rule) count
//                                     above its baseline (absent = 0) is red, and so is a baseline count above the real
//                                     count (slack) or a key naming a path absent from the tree (stale; a folder is fine)
//
// Roots (no env var, no seam): the TOOL root is the repository holding this script (node_modules, eslint.config.js,
// ruff.toml, .ls-lint.yml); the TARGET is the git repository of the current directory. So a test lints a throwaway
// repository with the real tools and configs, and the baseline can be generated from any tree.
//
// Tools, run concurrently: ESLint (JS), ruff (Python, version pinned by ruff.toml `required-version`), ls-lint (file
// names), ShellCheck (shell). Two rules have no market tool and are counted here for .sh and .py: `max-lines`
// (> 600 lines) and, for .sh only, `max-lines-per-function` (> 80). A third, `suppression`, counts the lint-disable
// comments of each language (SUPPRESSION_PATTERNS). Files under a `fixtures/` segment are out of scope.
// The baseline only goes down: regenerate it never by hand, never to absorb new findings.

const fs = require('fs')
const path = require('path')
const childProcess = require('child_process')

const TOOL_ROOT = path.resolve(__dirname, '..')
const BASELINE_PATH = 'scripts/audit-baseline.json'
const MAX_LINES = 600
const MAX_FUNCTION_LINES = 80
const SCRIPT_EXTENSIONS = new Set(['.js', '.cjs', '.mjs'])
const SCOPE_EXTENSIONS = new Set([...SCRIPT_EXTENSIONS, '.sh', '.py'])
const FAIL = 'FAIL: audit:'

const toolBinary = (name) => path.join(TOOL_ROOT, 'node_modules', '.bin', name)

// ---- process helpers -----------------------------------------------------------------------
function runCommand(command, commandArguments, options) {
  return new Promise((resolve) => {
    const child = childProcess.spawn(command, commandArguments, { cwd: options.cwd, env: options.environment || process.env })
    const chunks = { stdout: [], stderr: [] }
    child.stdout.on('data', (chunk) => chunks.stdout.push(chunk))
    child.stderr.on('data', (chunk) => chunks.stderr.push(chunk))
    child.on('error', (error) => resolve({ code: null, spawnError: error, stdout: '', stderr: '' }))
    child.on('close', (code) => resolve({ code, stdout: Buffer.concat(chunks.stdout).toString('utf8'), stderr: Buffer.concat(chunks.stderr).toString('utf8') }))
  })
}

function addCount(counts, file, rule) {
  counts[file] = counts[file] || {}
  counts[file][rule] = (counts[file][rule] || 0) + 1
}

const emptyResult = () => ({ counts: {}, failures: [] })

// A tool that cannot run, or that exits with an unexpected code or output, is a named red.
function toolFailure(name, result, detail) {
  if (result.spawnError && result.spawnError.code === 'ENOENT') return `${FAIL} ${name} missing, run npm ci`
  return `${FAIL} ${name} failed (${detail})`
}

function parseJson(text) {
  try {
    return JSON.parse(text)
  } catch (_) {
    return null
  }
}

// ---- file listing --------------------------------------------------------------------------
function listFiles(target) {
  const listed = childProcess.execFileSync('git', ['ls-files', '-z', '--cached', '--others', '--exclude-standard'], { cwd: target, encoding: 'utf8', maxBuffer: 1 << 28 })
  const files = new Set()
  for (const file of listed.split('\0')) {
    if (file === '' || !SCOPE_EXTENSIONS.has(path.extname(file))) continue
    if (file.split('/').includes('fixtures')) continue
    files.add(file)
  }
  return [...files].sort()
}

// A tracked file missing on disk is skipped; any other read error is a named red and the file is not handed to the tools.
function checkReadable(target, files) {
  const readable = []
  const failures = []
  for (const file of files) {
    try {
      fs.accessSync(path.join(target, file), fs.constants.R_OK)
      readable.push(file)
    } catch (error) {
      if (error.code !== 'ENOENT') failures.push(`${FAIL} ${file} unreadable (${error.code})`)
    }
  }
  return { readable, failures }
}

// ---- tools ---------------------------------------------------------------------------------
async function runEslint(target, files) {
  const found = emptyResult()
  if (files.length === 0) return found
  const configPath = path.join(TOOL_ROOT, 'eslint.config.js')
  const result = await runCommand(toolBinary('eslint'), ['--no-config-lookup', '-c', configPath, '-f', 'json', ...files], { cwd: target })
  const report = parseJson(result.stdout)
  if (!Array.isArray(report) || (result.code !== 0 && result.code !== 1)) {
    found.failures.push(toolFailure('eslint', result, result.stderr.trim().split('\n')[0] || `exit ${result.code}`))
    return found
  }
  for (const entry of report) {
    for (const message of entry.messages) addCount(found.counts, path.relative(target, entry.filePath), message.ruleId || 'parse-error')
  }
  return found
}

function requiredRuffVersion() {
  const match = /^required-version\s*=\s*"==([^"]+)"/m.exec(fs.readFileSync(path.join(TOOL_ROOT, 'ruff.toml'), 'utf8'))
  return match ? match[1] : null
}

// ruff is a Python tool, not in node_modules: it must be on PATH at the exact pinned version, even with no .py file.
async function checkRuffVersion(target, wanted) {
  const result = await runCommand('ruff', ['--version'], { cwd: target })
  if (result.spawnError) return `${FAIL} ruff not found, install it with: pip install ruff==${wanted}`
  const found = result.stdout.trim().split(/\s+/)[1]
  if (found !== wanted) return `${FAIL} ruff ${found} != required ${wanted}, install it with: pip install ruff==${wanted}`
  return null
}

async function runRuff(target, files) {
  const found = emptyResult()
  const wanted = requiredRuffVersion()
  const versionProblem = await checkRuffVersion(target, wanted)
  if (versionProblem) {
    found.failures.push(versionProblem)
    return found
  }
  if (files.length === 0) return found
  const configPath = path.join(TOOL_ROOT, 'ruff.toml')
  const result = await runCommand('ruff', ['check', '--config', configPath, '--no-cache', '--output-format', 'json', ...files], { cwd: target })
  const report = parseJson(result.stdout)
  if (!Array.isArray(report) || (result.code !== 0 && result.code !== 1)) {
    found.failures.push(toolFailure('ruff', result, result.stderr.trim().split('\n')[0] || `exit ${result.code}`))
    return found
  }
  for (const entry of report) addCount(found.counts, path.relative(target, entry.filename), entry.code)
  return found
}

async function runLsLint(target, files) {
  const found = emptyResult()
  if (files.length === 0) return found
  const configPath = path.join(TOOL_ROOT, '.ls-lint.yml')
  const result = await runCommand(toolBinary('ls-lint'), ['-config', configPath, '-error-output-format', 'json', ...files], { cwd: target })
  if (result.code === 0) return found
  // ls-lint prints its JSON report on stderr: { "<file>": { ".sh": ["kebabcase"] } }
  const report = result.code === 1 ? parseJson(result.stderr) : null
  if (report === null) {
    found.failures.push(toolFailure('ls-lint', result, result.stderr.trim().split('\n')[0] || `exit ${result.code}`))
    return found
  }
  for (const [file, byExtension] of Object.entries(report)) {
    for (const [extension, rules] of Object.entries(byExtension)) {
      for (const rule of rules) addCount(found.counts, file, `ls-lint:${extension}:${rule}`)
    }
  }
  return found
}

async function runShellcheck(target, files) {
  const found = emptyResult()
  if (files.length === 0) return found
  const environment = { ...process.env, SHELLCHECKJS_LOGGER_LEVEL: 'off' }
  const result = await runCommand(toolBinary('shellcheck'), ['-f', 'json1', '--severity=warning', ...files], { cwd: target, environment })
  const report = parseJson(result.stdout)
  if (report === null || !Array.isArray(report.comments) || (result.code !== 0 && result.code !== 1)) {
    found.failures.push(toolFailure('shellcheck', result, result.stderr.trim().split('\n')[0] || `exit ${result.code}`))
    return found
  }
  for (const comment of report.comments) addCount(found.counts, path.relative(target, path.resolve(target, comment.file)), `SC${comment.code}`)
  return found
}

// ---- own rules (shell and Python have no market tool for size) -------------------------------
const lineCount = (text) => (text === '' ? 0 : text.split('\n').length - (text.endsWith('\n') ? 1 : 0))
const FUNCTION_START = /^(?:function\s+[\w:.-]+(?:\s*\(\s*\))?|[\w:.-]+\s*\(\s*\))\s*\{/
const HEREDOC_START = /(?<!<)<<-?\s*(['"]?)([A-Za-z_]\w*)\1/

// A shell function starts at a column-0 `name() {` or `function name {` and ends at the next column-0 `}`; heredoc bodies
// are not matched against either pattern.
function shellFunctionLengths(text) {
  const lengths = []
  let heredocEnd = null
  let start = -1
  const lines = text.split('\n')
  for (const [index, line] of lines.entries()) {
    if (heredocEnd !== null) {
      if (line.replace(/^\t+/, '') === heredocEnd) heredocEnd = null
      continue
    }
    if (start < 0 && FUNCTION_START.test(line) && !/\}\s*$/.test(line.slice(line.indexOf('{') + 1))) start = index
    else if (start >= 0 && line.startsWith('}')) {
      lengths.push(index - start + 1)
      start = -1
    }
    const heredoc = HEREDOC_START.exec(line)
    if (heredoc) heredocEnd = heredoc[2]
  }
  return lengths
}

// One count per directive occurrence, by extension. The patterns do not match their own source.
const SUPPRESSION_PATTERNS = {
  '.js': /(?:\/\/|\/\*)\s*eslint-disable/g,
  '.cjs': /(?:\/\/|\/\*)\s*eslint-disable/g,
  '.mjs': /(?:\/\/|\/\*)\s*eslint-disable/g,
  '.py': /#\s*noqa/g,
  '.sh': /#\s*shellcheck\s+disable/g,
}

function countSuppressions(text, extension) {
  const pattern = SUPPRESSION_PATTERNS[extension]
  return pattern ? (text.match(pattern) || []).length : 0
}

function sizeRules(counts, file, text) {
  if (lineCount(text) > MAX_LINES) addCount(counts, file, 'max-lines')
  if (path.extname(file) !== '.sh') return
  for (const length of shellFunctionLengths(text)) {
    if (length > MAX_FUNCTION_LINES) addCount(counts, file, 'max-lines-per-function')
  }
}

function ownRules(target, files) {
  const counts = {}
  for (const file of files) {
    const extension = path.extname(file)
    const text = fs.readFileSync(path.join(target, file), 'utf8')
    for (let n = countSuppressions(text, extension); n > 0; n--) addCount(counts, file, 'suppression')
    if (extension === '.sh' || extension === '.py') sizeRules(counts, file, text)
  }
  return { counts, failures: [] }
}

// ---- aggregate and compare -------------------------------------------------------------------
function mergeCounts(results) {
  const merged = {}
  for (const result of results) {
    for (const [file, rules] of Object.entries(result.counts)) {
      for (const [rule, count] of Object.entries(rules)) {
        merged[file] = merged[file] || {}
        merged[file][rule] = (merged[file][rule] || 0) + count
      }
    }
  }
  return merged
}

function sortedCounts(counts) {
  const sorted = {}
  for (const file of Object.keys(counts).sort()) {
    sorted[file] = {}
    for (const rule of Object.keys(counts[file]).sort()) sorted[file][rule] = counts[file][rule]
  }
  return sorted
}

async function collect(target) {
  const { readable, failures } = checkReadable(target, listFiles(target))
  const byExtension = (extensions) => readable.filter((file) => extensions.has(path.extname(file)))
  const results = await Promise.all([
    runEslint(target, byExtension(SCRIPT_EXTENSIONS)),
    runRuff(target, byExtension(new Set(['.py']))),
    runLsLint(target, readable),
    runShellcheck(target, byExtension(new Set(['.sh']))),
    ownRules(target, readable),
  ])
  return { counts: sortedCounts(mergeCounts(results)), failures: [...failures, ...results.flatMap((result) => result.failures)] }
}

function overBaseline(current, baseline) {
  const gaps = []
  for (const [file, rules] of Object.entries(current)) {
    for (const [rule, count] of Object.entries(rules)) {
      const allowed = (baseline[file] && baseline[file][rule]) || 0
      if (count > allowed) gaps.push(`${FAIL} ${file} ${rule} ${count} > baseline ${allowed}`)
    }
  }
  return gaps
}

// A key naming a path absent from the tree is stale (a folder that exists is not); a count above the real one is slack.
function slackAndStale(current, baseline, target) {
  const gaps = []
  for (const [file, rules] of Object.entries(baseline)) {
    if (!fs.existsSync(path.join(target, file))) {
      gaps.push(`${FAIL} ${file} stale baseline key, no such file or folder in the tree`)
      continue
    }
    for (const [rule, allowed] of Object.entries(rules || {})) {
      const count = (current[file] && current[file][rule]) || 0
      if (typeof allowed === 'number' && count < allowed) gaps.push(`${FAIL} ${file} ${rule} slack ${count} < baseline ${allowed}`)
    }
  }
  return gaps
}

function compare(current, baseline, target) {
  return [...overBaseline(current, baseline), ...slackAndStale(current, baseline, target)].sort()
}

function totalFindings(counts) {
  return Object.values(counts).reduce((sum, rules) => sum + Object.values(rules).reduce((inner, count) => inner + count, 0), 0)
}

function printFailures(failures) {
  for (const failure of failures) console.log(failure)
}

async function main() {
  const mode = process.argv[2]
  if (mode !== '--report' && mode !== '--check') {
    console.error('usage: node scripts/audit.cjs --report | --check')
    return 2
  }
  const target = childProcess.execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim()
  const { counts, failures } = await collect(target)
  if (failures.length > 0) {
    printFailures(failures)
    return 1
  }
  if (mode === '--report') {
    process.stdout.write(`${JSON.stringify(counts, null, 2)}\n`)
    return 0
  }
  const baseline = parseJson(fs.existsSync(path.join(target, BASELINE_PATH)) ? fs.readFileSync(path.join(target, BASELINE_PATH), 'utf8') : '')
  if (baseline === null || typeof baseline !== 'object') {
    console.log(`${FAIL} ${BASELINE_PATH} missing or invalid`)
    return 1
  }
  const gaps = compare(counts, baseline, target)
  printFailures(gaps)
  if (gaps.length > 0) return 1
  console.log(`PASS: audit: ${totalFindings(counts)} findings, all under baseline`)
  return 0
}

main().then((code) => process.exit(code), (error) => {
  console.error(error)
  process.exit(2)
})
