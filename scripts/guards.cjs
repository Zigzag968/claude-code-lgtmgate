#!/usr/bin/env node
'use strict'
// guards.cjs — mechanical repo guards (node, stdlib only). Run by templates/test-canonical-guards.sh
// and directly: `node scripts/guards.cjs`. Exit 0 iff every check is ok.
//
// Checks
//   R1 ratchet vs origin/main (scope: workflows/deliver-pipeline.js). Three counters, each is
//      red if it goes UP relative to `git show origin/main:<file>`:
//        agent-calls         `await agent(` outside the body of `async function callAgent`
//                            (all occurrences when callAgent does not exist).
//        simulate-seams      distinct `simulate.<key>` / `simulate?.<key>` keys.
//        agent-output-regex  regex applications (.match( .test( .exec( .matchAll( .replace(/
//                            .split(/ new RegExp() outside parser blocks. A parser block is
//                            delimited by the comment lines `// guards:parser-begin` and
//                            `// guards:parser-end`; occurrences inside it do not count, so moving
//                            a parser inside markers lowers the counter.
//      Whole-line `//` comments and `/* ... */` block comments are ignored by all three counters.
//      Parser markers must be balanced: an unclosed or nested `parser-begin`, or a `parser-end`
//      without `parser-begin`, FAILS. A malformed BRANCH fails the check; a malformed BASE
//      (origin/main) is only reported as a WARN (the branch cannot be blamed for it).
//      Known limits (out of scope): string-literal false positives (a "/*" or "await agent(" inside
//      a string), exotic regex forms (.search, split(re), simulate aliases).
//   Invariant 25 all-tests-wired: every test suite under hooks/ scripts/ templates/
//      plugins/backlog/tests (test-*.sh|cjs|js), plus scripts/run-offline.cjs, appears inside a
//      `run:` step (single-line or `run: |` body) of .github/workflows/guards.yml, YAML comments
//      excluded, except the documented exemptions below.
//   sam-parity (#75): agents/sam.md and samScoutPrompt (workflows/deliver-pipeline.js) both carry
//      the token `patch-avoided:` and the byte-identical LAYER_RULE sentence (defined once below),
//      and neither carries a `root-cause:` field (doctrine v3 has no LLM-filled field).
//   Invariant 1 (relaxed) version floor: .claude-plugin/plugin.json version >= origin/main's.
//      Since #74 (scripts/lead-merge.sh bumps at merge; bump-required is retired) this floor is
//      the only version check besides stamp-parity in templates/test-canonical-guards.sh.
//
// Env (test seams, all optional)
//   GUARDS_ONLY            comma list among r1,wired,version,parity (default: all)
//   GUARDS_BASE_FILE       workflow file used as the base for R1 (default: git show origin/main:<file>)
//   GUARDS_BRANCH_FILE     workflow file used as the branch for R1 (default: workflows/deliver-pipeline.js)
//   GUARDS_BASE_MANIFEST   base plugin.json path for the version floor (default: git show origin/main:...)
//   GUARDS_BRANCH_MANIFEST branch plugin.json path (default: .claude-plugin/plugin.json)
//   GUARDS_SAM_FILE        Sam persona for sam-parity (default: agents/sam.md)
//   GUARDS_SAM_JS_FILE     workflow file for sam-parity (default: workflows/deliver-pipeline.js)
//   GUARDS_ROOT            repo root (default: parent of scripts/)

const fs = require('fs')
const path = require('path')
const { execFileSync } = require('child_process')

const ROOT = process.env.GUARDS_ROOT || path.resolve(__dirname, '..')
const WORKFLOW = 'workflows/deliver-pipeline.js'
const MANIFEST = '.claude-plugin/plugin.json'
const GUARDS_YML = '.github/workflows/guards.yml'
const ONLY = process.env.GUARDS_ONLY ? process.env.GUARDS_ONLY.split(',') : ['r1', 'wired', 'version', 'parity']

// Suites that are NOT named in guards.yml, each with its reason. Add a suite here only if it is
// red on main (report it, do not wire it) or is run through another runner.
const EXEMPT = {
  'templates/test-deliver-pipeline.js': 'flow suite, loaded and run by scripts/run-flow-suite.cjs',
}
// plugins/backlog/tests/*.py are python unittest modules run by discovery: never matched here.

// The one Sam mandate sentence, byte-identical in agents/sam.md and in samScoutPrompt.
const LAYER_RULE = 'LAYER RULE: plan the smallest change that removes the cause class; never a `simulate.*` seam; say in the plan if the diff adds a status, an `agent()`, a hook or a seam; list `patch-avoided:` with the patches you rejected.'

let failed = 0
const out = (s) => console.log(s)
const bad = (s) => { failed++; out(s) }

function gitShow(rel) {
  try {
    return execFileSync('git', ['show', `origin/main:${rel}`], { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] })
  } catch (_) {
    return null
  }
}
const readOr = (p) => (p && fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : null)

// ---- JS scanning helpers -------------------------------------------------------------------
// Blank out every character of the given range set, keeping newlines, so line numbers stay stable.
function isCommentLine(line) { return /^\s*\/\//.test(line) }
const blankNonNl = (t) => t.replace(/[^\n]/g, ' ')
// Blank `/* ... */` block comments (an unterminated one runs to EOF); offsets and newlines kept.
const noBlock = (src) => src.replace(/\/\*[\s\S]*?(?:\*\/|$)/g, blankNonNl)
// Also blank whole-line `//` comments.
function stripComments(src) {
  return noBlock(src).split('\n').map((l) => (isCommentLine(l) ? blankNonNl(l) : l)).join('\n')
}

// Returns [start, end) offsets of the body `{...}` of `function callAgent`, or null.
function callAgentBody(src) {
  const m = /(?:async\s+)?function\s+callAgent\s*\(/.exec(src)
  if (!m) return null
  let i = m.index + m[0].length
  let depth = 1
  // walk the parameter list (may contain defaults, no braces expected)
  while (i < src.length && depth > 0) {
    const c = src[i]
    if (c === '(') depth++
    else if (c === ')') depth--
    i++
  }
  while (i < src.length && src[i] !== '{') i++
  const start = i
  let d = 0
  while (i < src.length) {
    const c = src[i]
    const n = src[i + 1]
    if (c === '/' && n === '/') { while (i < src.length && src[i] !== '\n') i++; continue }
    if (c === '/' && n === '*') { i = src.indexOf('*/', i + 2); if (i < 0) return null; i += 2; continue }
    if (c === '\'' || c === '"') {
      const q = c; i++
      while (i < src.length && src[i] !== q) { if (src[i] === '\\') i++; i++ }
      i++; continue
    }
    if (c === '`') { i = skipTemplate(src, i + 1); continue }
    if (c === '{') d++
    else if (c === '}') { d--; if (d === 0) return [start, i + 1] }
    i++
  }
  return null
}
function skipTemplate(src, i) {
  while (i < src.length && src[i] !== '`') {
    if (src[i] === '\\') { i += 2; continue }
    if (src[i] === '$' && src[i + 1] === '{') {
      let d = 1; i += 2
      while (i < src.length && d > 0) {
        if (src[i] === '`') { i = skipTemplate(src, i + 1); continue }
        if (src[i] === '{') d++
        else if (src[i] === '}') d--
        i++
      }
      continue
    }
    i++
  }
  return i + 1
}

function countAgentCalls(rawSrc) {
  const src = stripComments(rawSrc)
  const body = callAgentBody(src)
  const re = /await\s+agent\s*\(/g
  let n = 0
  let m
  while ((m = re.exec(src))) {
    if (!(body && m.index >= body[0] && m.index < body[1])) n++
  }
  return n
}

function countSimulateSeams(rawSrc) {
  // One seam = one distinct key: `simulate.<key>` (key != probes) or `simulate.probes.<key>` /
  // `simulate.probes['key']` / `simulate?.probes?.<key>`. A dynamic `simulate.probes[role]` is not a key.
  const keys = new Set()
  for (const line of stripComments(rawSrc).split('\n')) {
    const re = /simulate\??\.([A-Za-z_][A-Za-z0-9_]*)(?:\??\.([A-Za-z_][A-Za-z0-9_]*)|\??\.?\[\s*(['"])([A-Za-z_][A-Za-z0-9_]*)\3\s*\])?/g
    let m
    while ((m = re.exec(line))) {
      if (m[1] !== 'probes') keys.add(m[1])
      else if (m[2] || m[4]) keys.add('probes.' + (m[2] || m[4]))
    }
  }
  return keys.size
}

const REGEX_APPLICATIONS = /\.match\(|\.test\(|\.exec\(|\.matchAll\(|\.replace\(\/|\.split\(\/|new RegExp\(/g
function countRegexApplications(rawSrc) {
  let inParser = false
  let n = 0
  // marker lines are whole-line `//` comments: match them before those are blanked
  for (const line of noBlock(rawSrc).split('\n')) {
    if (/^\s*\/\/\s*guards:parser-begin\b/.test(line)) { inParser = true; continue }
    if (/^\s*\/\/\s*guards:parser-end\b/.test(line)) { inParser = false; continue }
    if (inParser || isCommentLine(line)) continue
    const m = line.match(REGEX_APPLICATIONS)
    if (m) n += m.length
  }
  return n
}

// Problems with the parser markers (empty when balanced).
function parserMarkerErrors(rawSrc) {
  const errs = []
  let openAt = 0
  const lines = noBlock(rawSrc).split('\n')
  for (let i = 0; i < lines.length; i++) {
    if (/^\s*\/\/\s*guards:parser-begin\b/.test(lines[i])) {
      if (openAt) errs.push(`nested guards:parser-begin at line ${i + 1} (already open since line ${openAt})`)
      else openAt = i + 1
    } else if (/^\s*\/\/\s*guards:parser-end\b/.test(lines[i])) {
      if (!openAt) errs.push(`guards:parser-end at line ${i + 1} has no matching guards:parser-begin`)
      else openAt = 0
    }
  }
  if (openAt) errs.push(`unclosed guards:parser-begin at line ${openAt} (no guards:parser-end)`)
  return errs
}

// ---- R1 ---------------------------------------------------------------------------------------
function checkR1() {
  const base = process.env.GUARDS_BASE_FILE ? readOr(process.env.GUARDS_BASE_FILE) : gitShow(WORKFLOW)
  const branch = readOr(process.env.GUARDS_BRANCH_FILE || path.join(ROOT, WORKFLOW))
  if (base === null) {
    bad(`FAIL: R1 ratchet: cannot read base ${WORKFLOW} (origin/main not resolvable) — run 'git fetch origin main' first`)
    return
  }
  if (branch === null) { bad(`FAIL: R1 ratchet: cannot read branch ${WORKFLOW}`); return }
  for (const e of parserMarkerErrors(base)) out(`WARN: R1 parser markers: base (origin/main) ${WORKFLOW}: ${e}`)
  const branchErrs = parserMarkerErrors(branch)
  for (const e of branchErrs) bad(`FAIL: R1 parser markers: ${WORKFLOW}: ${e} — balance the markers (each parser-begin needs exactly one parser-end)`)
  if (branchErrs.length) return
  const counters = [
    ['agent-calls', countAgentCalls],
    ['simulate-seams', countSimulateSeams],
    ['agent-output-regex', countRegexApplications],
  ]
  for (const [name, fn] of counters) {
    const b = fn(base)
    const m = fn(branch)
    const ok = m <= b
    out(`R1 ${name} base=${b} branch=${m} ${ok ? 'ok' : 'UP'}`)
    if (!ok) failed++
  }
}

// ---- Invariant 25 -----------------------------------------------------------------------------
// Concatenated text of every `run:` step (single-line value or `|`/`>` block body), YAML comments
// removed (whole-line `#` and trailing ` #...`).
function ymlRunText(yml) {
  const lines = yml.split('\n').filter((l) => !/^\s*#/.test(l)).map((l) => l.replace(/\s+#.*$/, ''))
  const parts = []
  for (let i = 0; i < lines.length; i++) {
    const m = /^(\s*(?:-\s+)?)run:\s*(.*)$/.exec(lines[i])
    if (!m) continue
    const keyIndent = m[1].length
    if (/^[|>][+-]?\d*$/.test(m[2].trim())) {
      for (i++; i < lines.length; i++) {
        const l = lines[i]
        if (l.trim() !== '' && l.length - l.trimStart().length <= keyIndent) { i--; break }
        parts.push(l)
      }
    } else parts.push(m[2])
  }
  return parts.join('\n')
}

function checkWired() {
  const yml = readOr(path.join(ROOT, GUARDS_YML))
  if (yml === null) { bad(`FAIL: all-tests-wired: ${GUARDS_YML} missing`); return }
  const dirs = ['hooks', 'scripts', 'templates', 'plugins/backlog/tests']
  const suites = ['scripts/run-offline.cjs']
  for (const d of dirs) {
    const abs = path.join(ROOT, d)
    if (!fs.existsSync(abs)) continue
    for (const f of fs.readdirSync(abs)) {
      if (/^test-.*\.(sh|cjs|js)$/.test(f)) suites.push(`${d}/${f}`)
    }
  }
  const runText = ymlRunText(yml)
  const missing = suites.filter((s) => !EXEMPT[s] && !runText.includes(s))
  if (missing.length) bad(`FAIL: all-tests-wired: not referenced in a run: step of ${GUARDS_YML} (comments do not count): ${missing.join(', ')}`)
  else out(`PASS: all-tests-wired: ${suites.length} suites checked, ${Object.keys(EXEMPT).length} documented exemption(s)`)
}

// ---- Invariant 1 (relaxed) --------------------------------------------------------------------
function parseSemver(v) {
  const m = /^(\d+)\.(\d+)\.(\d+)/.exec(String(v).trim())
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null
}
function cmp(a, b) { for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] - b[i]; return 0 }
function checkVersion() {
  const baseTxt = process.env.GUARDS_BASE_MANIFEST ? readOr(process.env.GUARDS_BASE_MANIFEST) : gitShow(MANIFEST)
  const branchTxt = readOr(process.env.GUARDS_BRANCH_MANIFEST || path.join(ROOT, MANIFEST))
  if (baseTxt === null) { bad(`FAIL: version-floor: cannot read base ${MANIFEST} (origin/main not resolvable) — run 'git fetch origin main' first`); return }
  if (branchTxt === null) { bad(`FAIL: version-floor: cannot read ${MANIFEST}`); return }
  let bv, nv
  try { bv = parseSemver(JSON.parse(baseTxt).version); nv = parseSemver(JSON.parse(branchTxt).version) } catch (e) { bad(`FAIL: version-floor: invalid JSON (${e.message})`); return }
  if (!bv || !nv) { bad('FAIL: version-floor: version is not semver'); return }
  if (cmp(nv, bv) < 0) bad(`FAIL: version-floor: branch version ${nv.join('.')} < origin/main ${bv.join('.')}`)
  else out(`PASS: version-floor: branch ${nv.join('.')} >= origin/main ${bv.join('.')}`)
}

// ---- sam-parity (#75) ---------------------------------------------------------------------------
function checkSamParity() {
  const sites = [
    ['agents/sam.md', readOr(process.env.GUARDS_SAM_FILE || path.join(ROOT, 'agents/sam.md'))],
    [WORKFLOW, readOr(process.env.GUARDS_SAM_JS_FILE || path.join(ROOT, WORKFLOW))],
  ]
  const problems = []
  for (const [name, txt] of sites) {
    if (txt === null) { problems.push(`${name} unreadable`); continue }
    if (!txt.includes('patch-avoided:')) problems.push(`${name} lacks the token patch-avoided:`)
    if (!txt.includes(LAYER_RULE)) problems.push(`${name} lacks the LAYER RULE sentence`)
    if (txt.includes('root-cause:')) problems.push(`${name} carries a root-cause: field`)
  }
  if (problems.length) bad(`FAIL: sam-parity: ${problems.join('; ')}`)
  else out('PASS: sam-parity: patch-avoided: and the LAYER RULE sentence on both sides, no root-cause: field')
}

if (ONLY.includes('r1')) checkR1()
if (ONLY.includes('wired')) checkWired()
if (ONLY.includes('version')) checkVersion()
if (ONLY.includes('parity')) checkSamParity()
process.exit(failed ? 1 : 0)
