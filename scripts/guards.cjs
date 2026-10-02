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
//   sam-parity (#75, #163): agents/sam.md and samScoutPrompt (workflows/deliver-pipeline.js) both carry
//      the token `patch-avoided:` and the byte-identical neutral PLAN_RULE sentence (defined once below),
//      and neither carries a `root-cause:` field (doctrine v3 has no LLM-filled field). The engine's own
//      LAYER_RULE sentence lives in the workflow only (emitted for engineRepo:true); agents/sam.md, shipped
//      to every consumer, carries none of the engine vocabulary (ENGINE_WORDS_RE).
//   Invariant 1 (relaxed) version floor: .claude-plugin/plugin.json version >= origin/main's (semver 2.0.0
//      precedence, prerelease included: 1.0.0-beta.2 > 1.0.0-beta.1, 1.0.0-beta.9 < 1.0.0).
//      Since #74 (scripts/lead-merge.sh bumps at merge; bump-required is retired) this floor is
//      the only version check besides stamp-parity in templates/test-canonical-guards.sh.
//   doc-budgets (#77): the agent-read docs stay within the maintainer's budgets — VISION.md and
//      ARCHITECTURE.md (both imported for every agent through CLAUDE.md, see instructions-wired)
//      <= 20 lines each, and every line of both <= 160 characters, so a long line cannot dodge the
//      line budget. A missing file FAILS.
//   instructions-wired (#77): agents receive the two docs natively, never through an engine prompt.
//      FAILS unless CLAUDE.md holds exactly one line `@VISION.md` and one line `@ARCHITECTURE.md`
//      (outside fenced code blocks and code spans; no second import of either, no `@AGENTS.md`
//      import, which would load the docs twice); unless AGENTS.md (the agents.md pointer for other
//      tools) exists and names both files; or if any agents/*.md frontmatter sets
//      `omitClaudeMd: true` (a subagent that would skip the project instructions).
//   status-table (#180): the run's STATUS registry (top-level `const STATUS = Object.freeze({ ... })` in
//      workflows/deliver-pipeline.js) and the status table of commands/deliver.md §5 name the same set:
//      every registry key has a row (a row's first cell may group several statuses, each in backticks)
//      and every row names a registry key. A failure names the status.
//
// Env (test seams, all optional)
//   GUARDS_ONLY            comma list among r1,wired,version,parity,budgets,instructions,status (default: all)
//   GUARDS_BASE_FILE       workflow file used as the base for R1 (default: git show origin/main:<file>)
//   GUARDS_BRANCH_FILE     workflow file used as the branch for R1 (default: workflows/deliver-pipeline.js)
//   GUARDS_BASE_MANIFEST   base plugin.json path for the version floor (default: git show origin/main:...)
//   GUARDS_BRANCH_MANIFEST branch plugin.json path (default: .claude-plugin/plugin.json)
//   GUARDS_SAM_FILE        Sam persona for sam-parity (default: agents/sam.md)
//   GUARDS_SAM_JS_FILE     workflow file for sam-parity (default: workflows/deliver-pipeline.js)
//   GUARDS_STATUS_JS_FILE  workflow file for status-table (default: workflows/deliver-pipeline.js)
//   GUARDS_DELIVER_MD      Lead runbook for status-table (default: commands/deliver.md)
//   GUARDS_ROOT            repo root (default: parent of scripts/)

const fs = require('fs')
const path = require('path')
const { execFileSync } = require('child_process')

const ROOT = process.env.GUARDS_ROOT || path.resolve(__dirname, '..')
const WORKFLOW = 'workflows/deliver-pipeline.js'
const MANIFEST = '.claude-plugin/plugin.json'
const GUARDS_YML = '.github/workflows/guards.yml'
const DELIVER_MD = 'commands/deliver.md'
const ONLY = process.env.GUARDS_ONLY ? process.env.GUARDS_ONLY.split(',') : ['r1', 'wired', 'version', 'parity', 'budgets', 'instructions', 'status']

// Suites that are NOT named in guards.yml, each with its reason. Add a suite here only if it is
// red on main (report it, do not wire it) or is run through another runner.
const EXEMPT = {
  'templates/test-deliver-pipeline.js': 'flow suite, loaded and run by scripts/run-flow-suite.cjs',
}
// plugins/backlog/tests/*.py are python unittest modules run by discovery: never matched here.

// The neutral Sam mandate sentence, byte-identical in agents/sam.md and in the workflow (every consumer gets it).
const PLAN_RULE = 'PLAN RULE: plan the smallest change that removes the cause class; list `patch-avoided:` with the patches you rejected.'
// The engine's own variant, in the workflow only (emitted when the project's config sets engineRepo:true).
const LAYER_RULE = 'LAYER RULE: plan the smallest change that removes the cause class; never a `simulate.*` seam; say in the plan if the diff adds a status, an `agent()`, a hook or a seam; list `patch-avoided:` with the patches you rejected.'

// Engine-only vocabulary a consumer-facing persona must not carry.
const ENGINE_WORDS_RE = /\bsimulate\b|\bseam\b|agent\(\)|fixtures\/incidents/

let failed = 0
const out =(s) => console.log(s)
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
// semver 2.0.0 precedence (section 11): build metadata ignored, a prerelease sorts below its release,
// numeric identifiers compare as numbers and sort below alphanumeric ones, more identifiers win a tie.
const SEMVER = /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/
function parseSemver(v) {
  const m = SEMVER.exec(String(v).trim())
  return m ? { str: String(v).trim(), core: [Number(m[1]), Number(m[2]), Number(m[3])], pre: m[4] ? m[4].split('.') : [] } : null
}
function cmp(a, b) {
  for (let i = 0; i < 3; i++) if (a.core[i] !== b.core[i]) return a.core[i] - b.core[i]
  if (!a.pre.length || !b.pre.length) return b.pre.length - a.pre.length
  for (let i = 0; i < Math.min(a.pre.length, b.pre.length); i++) {
    const x = a.pre[i], y = b.pre[i], xn = /^\d+$/.test(x), yn = /^\d+$/.test(y)
    if (xn && yn) { if (Number(x) !== Number(y)) return Number(x) - Number(y) } else if (xn !== yn) return xn ? -1 : 1
    else if (x !== y) return x < y ? -1 : 1
  }
  return a.pre.length - b.pre.length
}
function checkVersion() {
  const baseTxt = process.env.GUARDS_BASE_MANIFEST ? readOr(process.env.GUARDS_BASE_MANIFEST) : gitShow(MANIFEST)
  const branchTxt = readOr(process.env.GUARDS_BRANCH_MANIFEST || path.join(ROOT, MANIFEST))
  if (baseTxt === null) { bad(`FAIL: version-floor: cannot read base ${MANIFEST} (origin/main not resolvable) — run 'git fetch origin main' first`); return }
  if (branchTxt === null) { bad(`FAIL: version-floor: cannot read ${MANIFEST}`); return }
  let bv, nv
  try { bv = parseSemver(JSON.parse(baseTxt).version); nv = parseSemver(JSON.parse(branchTxt).version) } catch (e) { bad(`FAIL: version-floor: invalid JSON (${e.message})`); return }
  if (!bv || !nv) { bad('FAIL: version-floor: version is not semver'); return }
  if (cmp(nv, bv) < 0) bad(`FAIL: version-floor: branch version ${nv.str} < origin/main ${bv.str}`)
  else out(`PASS: version-floor: branch ${nv.str} >= origin/main ${bv.str}`)
}

// ---- sam-parity (#75, #163) ---------------------------------------------------------------------
function checkSamParity() {
  const sites = [
    ['agents/sam.md', readOr(process.env.GUARDS_SAM_FILE || path.join(ROOT, 'agents/sam.md')), false],
    [WORKFLOW, readOr(process.env.GUARDS_SAM_JS_FILE || path.join(ROOT, WORKFLOW)), true],
  ]
  const problems = []
  for (const [name, txt, isWorkflow] of sites) {
    if (txt === null) { problems.push(`${name} unreadable`); continue }
    if (!txt.includes('patch-avoided:')) problems.push(`${name} lacks the token patch-avoided:`)
    if (!txt.includes(PLAN_RULE)) problems.push(`${name} lacks the PLAN RULE sentence`)
    if (isWorkflow && !txt.includes(LAYER_RULE)) problems.push(`${name} lacks the LAYER RULE sentence`)
    if (!isWorkflow) {
      const engine = ENGINE_WORDS_RE.exec(txt)
      if (engine) problems.push(`${name} carries engine vocabulary (${engine[0]})`)
    }
    if (txt.includes('root-cause:')) problems.push(`${name} carries a root-cause: field`)
  }
  if (problems.length) bad(`FAIL: sam-parity: ${problems.join('; ')}`)
  else out('PASS: sam-parity: patch-avoided: and the PLAN RULE sentence on both sides, the LAYER RULE sentence in the workflow, no engine vocabulary in the persona, no root-cause: field')
}

// ---- instructions-wired (#77) ------------------------------------------------------------------
// Claude Code loads CLAUDE.md and its `@path` imports for the session and its subagents; other tools
// read AGENTS.md. An import inside a fenced code block or a code span is inert, so both are skipped.
const IMPORTED_DOCS = ['VISION.md', 'ARCHITECTURE.md']
// The lines of a Markdown text outside fenced code blocks, with inline code spans removed.
function proseLines(txt) {
  const lines = []
  let fence = null
  for (const raw of txt.split('\n')) {
    const l = raw.replace(/\r$/, '')
    const open = /^ {0,3}(`{3,}|~{3,})/.exec(l)
    if (fence) {
      const close = /^ {0,3}(`{3,}|~{3,})[ \t]*$/.exec(l)
      if (close && close[1][0] === fence[0] && close[1].length >= fence.length) fence = null
      continue
    }
    if (open) { fence = open[1]; continue }
    lines.push(l.replace(/(`+).*?\1/g, ''))
  }
  return lines
}
// Import references to `name` (`@name` at a line start or after whitespace) in prose lines.
const escapeRegExp = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
const importRefs = (lines, name) => lines.reduce((n, l) =>
  n + (l.match(new RegExp(`(?:^|\\s)@${escapeRegExp(name)}(?![\\w./-])`, 'g')) || []).length, 0)
function checkInstructionsWired() {
  const problems = []
  const claude = readOr(path.join(ROOT, 'CLAUDE.md'))
  if (claude === null) problems.push('CLAUDE.md missing')
  else {
    const lines = proseLines(claude)
    for (const doc of IMPORTED_DOCS) {
      const own = lines.filter((l) => l.replace(/[ \t]+$/, '') === `@${doc}`).length
      const refs = importRefs(lines, doc)
      if (own === 0) problems.push(`CLAUDE.md has no line \`@${doc}\` outside code`)
      else if (refs > 1) problems.push(`CLAUDE.md imports ${doc} ${refs} times, keep exactly one \`@${doc}\` line`)
    }
    if (importRefs(lines, 'AGENTS.md') > 0) problems.push('CLAUDE.md imports AGENTS.md, which loads the docs twice')
  }
  const agentsMd = readOr(path.join(ROOT, 'AGENTS.md'))
  if (agentsMd === null) problems.push('AGENTS.md missing')
  else {
    const unnamed = IMPORTED_DOCS.filter((doc) => !agentsMd.includes(doc))
    if (unnamed.length) problems.push(`AGENTS.md does not name ${unnamed.join(', ')}`)
  }
  const agentsDir = path.join(ROOT, 'agents')
  const personas = fs.existsSync(agentsDir) ? fs.readdirSync(agentsDir).filter((f) => f.endsWith('.md')).sort() : []
  for (const f of personas) {
    const txt = fs.readFileSync(path.join(agentsDir, f), 'utf8').replace(/^\uFEFF/, '')
    const fm = /^---\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/.exec(txt)
    if (fm && /^omitClaudeMd[ \t]*:[ \t]*["']?true["']?[ \t]*(?:#.*)?$/im.test(fm[1])) problems.push(`agents/${f} sets omitClaudeMd: true`)
  }
  if (problems.length) bad(`FAIL: instructions-wired: ${problems.join('; ')}`)
  else out(`PASS: instructions-wired: CLAUDE.md imports ${IMPORTED_DOCS.map((d) => `@${d}`).join(' and ')} once each; AGENTS.md names both; ${personas.length} agents/*.md, none sets omitClaudeMd: true`)
}

// ---- doc-budgets (#77) --------------------------------------------------------------------------
const DOC_BUDGETS = [['VISION.md', 20], ['ARCHITECTURE.md', 20]]
// Per-line cap, so a long line cannot dodge the line budget. Counted in characters (code points).
const DOC_LINE_CAP = 160
// Same count as `wc -l` for a file ending with a newline; a last line without one still counts.
const lineCount = (t) => (t === '' ? 0 : t.split('\n').length - (t.endsWith('\n') ? 1 : 0))
function checkDocBudgets() {
  const problems = []
  const sizes = []
  for (const [rel, max] of DOC_BUDGETS) {
    const txt = readOr(path.join(ROOT, rel))
    if (txt === null) { problems.push(`${rel} missing`); continue }
    const n = lineCount(txt)
    const widths = txt.split('\n').map((l) => [...l.replace(/\r$/, '')].length)
    const longest = widths.reduce((a, w) => Math.max(a, w), 0)
    sizes.push(`${rel} ${n}/${max} lines, longest ${longest}/${DOC_LINE_CAP} chars`)
    if (n > max) problems.push(`${rel} has ${n} lines, budget ${max}`)
    const over = widths.map((w, i) => [i + 1, w]).filter(([, w]) => w > DOC_LINE_CAP)
    if (over.length) problems.push(`${rel} line ${over[0][0]} has ${over[0][1]} characters, cap ${DOC_LINE_CAP}` + (over.length > 1 ? ` (+${over.length - 1} more)` : ''))
  }
  if (problems.length) bad(`FAIL: doc-budgets: ${problems.join('; ')} — move detail to docs/ (never imported), never raise the budget`)
  else out(`PASS: doc-budgets: ${sizes.join('; ')}`)
}

// ---- status-table (#180) -----------------------------------------------------------------------
// The registry is the top-level `const STATUS = Object.freeze({ ... })` closed by a `})` at column 0;
// agentDeathRouting()'s indented role -> status table is not it. Keys are the quoted entry names.
const STATUS_SECTION = '## 5. Handle the returned status'
function statusRegistryKeys(src) {
  const m = /^const STATUS = Object\.freeze\(\{\n([\s\S]*?)^\}\)/m.exec(src)
  return m ? [...m[1].matchAll(/^\s*'([^']+)':/gm)].map((x) => x[1]) : null
}
// Body rows of the first Markdown table after the §5 heading, each as its first cell and the
// backticked statuses in it (`a` / `b` groups several). Null when the heading or the table is absent.
function statusTableRows(md) {
  const lines = md.split('\n')
  const start = lines.findIndex((l) => l.trim() === STATUS_SECTION)
  if (start < 0) return null
  const rows = []
  for (let i = start + 1; i < lines.length; i++) {
    if (/^##/.test(lines[i])) break
    if (!lines[i].startsWith('|')) { if (rows.length) break; continue }
    rows.push(lines[i])
  }
  if (rows.length < 2) return null
  return rows.slice(2).map((l) => {
    const cell = l.split('|')[1].trim()
    return { cell, statuses: [...cell.matchAll(/`([^`]+)`/g)].map((x) => x[1]) }
  })
}
function checkStatusTable() {
  const js = readOr(process.env.GUARDS_STATUS_JS_FILE || path.join(ROOT, WORKFLOW))
  const md = readOr(process.env.GUARDS_DELIVER_MD || path.join(ROOT, DELIVER_MD))
  if (js === null) { bad(`FAIL: status-table: cannot read ${WORKFLOW}`); return }
  if (md === null) { bad(`FAIL: status-table: cannot read ${DELIVER_MD}`); return }
  const keys = statusRegistryKeys(js)
  if (!keys || !keys.length) { bad(`FAIL: status-table: no top-level \`const STATUS = Object.freeze({ ... })\` registry in ${WORKFLOW}`); return }
  const rows = statusTableRows(md)
  if (!rows) { bad(`FAIL: status-table: no table under \`${STATUS_SECTION}\` in ${DELIVER_MD}`); return }
  const problems = []
  for (const k of keys.filter((k, i) => keys.indexOf(k) !== i)) problems.push(`STATUS key '${k}' is declared twice in ${WORKFLOW}`)
  const inRows = new Set()
  for (const r of rows) {
    if (!r.statuses.length) problems.push(`row '${r.cell}' of the status table (${DELIVER_MD} §5) names no \`status\``)
    for (const s of r.statuses) {
      if (inRows.has(s)) problems.push(`status '${s}' has two rows in the status table (${DELIVER_MD} §5)`)
      inRows.add(s)
      if (!keys.includes(s)) problems.push(`row '${s}' of the status table (${DELIVER_MD} §5) is not a STATUS key in ${WORKFLOW}`)
    }
  }
  for (const k of keys) if (!inRows.has(k)) problems.push(`STATUS key '${k}' (${WORKFLOW}) has no row in the status table of ${DELIVER_MD} §5`)
  if (problems.length) bad(`FAIL: status-table: ${problems.join('; ')}`)
  else out(`PASS: status-table: ${keys.length} STATUS keys, each with a row in ${DELIVER_MD} §5, no row without a key`)
}

if (ONLY.includes('r1')) checkR1()
if (ONLY.includes('wired')) checkWired()
if (ONLY.includes('version')) checkVersion()
if (ONLY.includes('parity')) checkSamParity()
if (ONLY.includes('budgets')) checkDocBudgets()
if (ONLY.includes('instructions')) checkInstructionsWired()
if (ONLY.includes('status')) checkStatusTable()
process.exit(failed ? 1 : 0)
