#!/usr/bin/env node
'use strict'
// guards.cjs — mechanical repo guards (node, stdlib only). Run by tests/templates/test-canonical-guards.sh
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
//   Invariant 25 all-tests-wired: every test suite under tests/ hooks/ scripts/ templates/
//      plugins/backlog/tests (test-*.sh|cjs|js), plus scripts/run-offline.cjs, appears inside a
//      `run:` step (single-line or `run: |` body) of .github/workflows/guards.yml, YAML comments
//      excluded, except the documented exemptions below.
//   sam-parity (#75, #163): agents/sam.md and samScoutPrompt (workflows/deliver-pipeline.js) both carry
//      the token `patch-avoided:` and the byte-identical neutral PLAN_RULE sentence (defined once below),
//      and neither carries a `root-cause:` field (doctrine v3 has no LLM-filled field). The engine's own
//      LAYER_RULE sentence lives in the workflow only (emitted for engineRepo:true); agents/sam.md, shipped
//      to every consumer, carries none of the engine vocabulary (ENGINE_WORDS_RE).
//      Human-gate text bridge (#28): the workflow, agents/sam.md and the two pr-acceptance copies
//      (templates/pr-acceptance.md, .claude/rules/pr-acceptance.md) all carry the human-gate test
//      (GATE_TEST), none carries the retired definition (OLD_GATE_DEF, whitespace-normalised), the
//      workflow and the persona carry the proof-rule exemption (EXEMPTION_KEY), and the "when [human-gate]
//      applies" rule sentence (from "efore tagging an item" to the end of its line) is identical in the
//      workflow constant, the persona and both pr-acceptance copies, the case of its first letter aside.
//      Follow-up issue rule (#29): the workflow and the persona carry one identical "FOLLOW-UP ISSUE RULE:"
//      sentence that names sub_issues, and each file holds the hidden marker key (FOLLOWUP_MARKER_KEY) only inside it.
//   Invariant 1 (relaxed) version floor: .claude-plugin/plugin.json version >= origin/main's (semver 2.0.0
//      precedence, prerelease included: 1.0.0-beta.2 > 1.0.0-beta.1, 1.0.0-beta.9 < 1.0.0).
//      Since #74 (scripts/lead-merge.sh bumps at merge; bump-required is retired) this floor is
//      the only version check besides stamp-parity in tests/templates/test-canonical-guards.sh.
//   doc-budgets (#77): the agent-read docs stay within the maintainer's budgets — VISION.md and
//      ARCHITECTURE.md (both imported for every agent through .claude/CLAUDE.md, see instructions-wired)
//      <= 20 lines each, and every line of both <= 160 characters, so a long line cannot dodge the
//      line budget. A missing file FAILS.
//   instructions-wired (#77): agents receive the two docs natively, never through an engine prompt.
//      FAILS unless .claude/CLAUDE.md holds exactly one line `@../VISION.md` and one line `@../ARCHITECTURE.md`
//      (outside fenced code blocks and code spans; both targets must exist; a bare `@VISION.md` loads nothing
//      from .claude/ and FAILS; no second import of either, no `@AGENTS.md`
//      import, which would load the docs twice); unless AGENTS.md (the agents.md pointer for other
//      tools) exists and names both files; or if any agents/*.md frontmatter sets
//      `omitClaudeMd: true` (a subagent that would skip the project instructions).
//   status-table (#180): the run's STATUS registry (top-level `const STATUS = Object.freeze({ ... })` in
//      workflows/deliver-pipeline.js) and the status table of skills/deliver/SKILL.md §5 name the same set:
//      every registry key has a row (a row's first cell may group several statuses, each in backticks)
//      and every row names a registry key. A failure names the status.
//
//   phase-titles (#141): the titles declared in `export const meta = { ... phases: [ ... ] }` of
//      workflows/deliver-pipeline.js are each at most 16 characters (the progress view truncates longer ones)
//      and none is a case-insensitive prefix of another (the view merges them into one box; the run-time
//      numbered titles `Review 2`, `Plan 2` rely on this; titles are compared after trimming surrounding whitespace,
//      as the viewer does). Only the meta block is read. A failure names the title.
//   init-stubs (#267): the six stubs `/lgtmgate:init` creates under .claude/lgtmgate/ (STUBS of
//      scripts/init-specifics.cjs) carry none of the engine vocabulary (ENGINE_WORDS_RE) and are empty once
//      their comments are stripped (a stub injects nothing into an agent's prompt). Since #271 the lane stub
//      (laneStub of the same module, frontmatter and comments stripped) and the persona sentence
//      (laneSentence of scripts/agent-context.cjs) are held to the same vocabulary rule. A failure names the stub.
//   audit (#289): the code-quality ratchet. Rule 2 first (cheap): scripts/audit-baseline.json may never raise a
//      (file, rule) count above `git show origin/main:scripts/audit-baseline.json` (absent = 0); with no base baseline
//      (bootstrap) it prints `SKIP: baseline-vs-origin (no base baseline)`, and with an unresolvable origin/main it FAILS
//      like R1. Rule 2 is rename-aware (`git diff -M origin/main`: a renamed file keeps its budget, a copy does not)
//      and refuses a NEW-RULE: a rule absent from the origin baseline, unless eslint.config.js, .ls-lint.yml or
//      ruff.toml changes in the same branch (then the rule enters at its current level). Rule 1: `node scripts/audit.cjs --check` (size, naming, lint against that baseline); its lines are
//      printed verbatim and a nonzero exit fails. A missing baseline FAILS. Needs `npm ci` and the pinned ruff.
//
// Env (test seams, all optional)
//   GUARDS_ONLY            comma list among r1,wired,guard-steps,version,parity,budgets,instructions,status,phases,init-stubs,audit (default: all)
//   GUARDS_BASE_YML        guards.yml used as the base for guard-steps (default: git show origin/main:.github/workflows/guards.yml)
//   GUARDS_BASE_FILE       workflow file used as the base for R1 (default: git show origin/main:<file>)
//   GUARDS_BRANCH_FILE     workflow file used as the branch for R1 (default: workflows/deliver-pipeline.js)
//   GUARDS_BASE_MANIFEST   base plugin.json path for the version floor (default: git show origin/main:...)
//   GUARDS_BRANCH_MANIFEST branch plugin.json path (default: .claude-plugin/plugin.json)
//   GUARDS_SAM_FILE        Sam persona for sam-parity (default: agents/sam.md)
//   GUARDS_SAM_JS_FILE     workflow file for sam-parity (default: workflows/deliver-pipeline.js)
//   GUARDS_PRACC_FILE      templates/pr-acceptance.md for sam-parity (default: templates/pr-acceptance.md)
//   GUARDS_PRACC_COPY      its in-repo copy for sam-parity (default: .claude/rules/pr-acceptance.md)
//   GUARDS_STATUS_JS_FILE  workflow file for status-table (default: workflows/deliver-pipeline.js)
//   GUARDS_DELIVER_MD      Lead runbook for status-table (default: skills/deliver/SKILL.md)
//   GUARDS_PHASES_JS_FILE  workflow file for phase-titles (default: workflows/deliver-pipeline.js)
//   GUARDS_INIT_STUBS      module exporting STUBS for init-stubs (default: scripts/init-specifics.cjs)
//   GUARDS_ROOT            repo root (default: parent of scripts/)

const fs = require('fs')
const path = require('path')
const { countAgentCalls, countSimulateSeams, countRegexApps, parserMarkerErrors, ymlRunText, jobRunText, parseSemver, cmp, proseLines, importReferences, STATUS_SECTION, statusRegistryKeys, statusTableRows, declaredPhaseTitles } = require('./lib/guards-scan.cjs')
const { execFileSync } = require('child_process')

const ROOT = process.env.GUARDS_ROOT || path.resolve(__dirname, '..')
const WORKFLOW = 'workflows/deliver-pipeline.js'
const MANIFEST = '.claude-plugin/plugin.json'
const GUARDS_YML = '.github/workflows/guards.yml'
const DELIVER_MD = 'skills/deliver/SKILL.md'
const ONLY = process.env.GUARDS_ONLY ? process.env.GUARDS_ONLY.split(',') : ['r1', 'wired', 'guard-steps', 'version', 'parity', 'budgets', 'instructions', 'status', 'phases', 'init-stubs', 'audit']

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

// Human-gate text bridge (#28): phrases every site must agree on (whitespace-normalised before comparing).
const GATE_TEST = 'a decision, an authorization or an action to perform, or a judgement no read-only command can confirm'
const OLD_GATE_DEF = 'an external system out of reach'
const EXEMPTION_KEY = 'read-only confirmation of an action that was already authorized and executed'
// The "when [human-gate] applies" rule sentence, from after its first letter to the end of its line.
const GATE_RULE_RE = /efore tagging an item[^\n']*/
// Follow-up issue rule (#29): the sentence from its label to the end of its line, and its hidden marker key.
// The sentence holds quotes (the jq filters): in the engine it sits in a quoted JS string, so its escaped quotes and closing quote are undone before comparing.
const FOLLOWUP_RULE_RE = /FOLLOW-UP ISSUE RULE:[^\n]*/
const FOLLOWUP_MARKER_KEY = 'pipeline-followup:issue-'

// Engine-only vocabulary a consumer-facing persona must not carry.
const ENGINE_WORDS_RE = /\bsimulate\b|\bseam\b|agent\(\)|fixtures\/incidents/

let failed = 0
const out =(s) => console.log(s)
const bad = (s) => { failed++; out(s) }

function gitShow(relativePath) {
  try {
    return execFileSync('git', ['show', `origin/main:${relativePath}`], { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] })
  } catch (_) {
    return null
  }
}
const readOr = (p) => (p && fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : null)

// ---- R1 ---------------------------------------------------------------------------------------
function checkR1() {
  const base = process.env.GUARDS_BASE_FILE ? readOr(process.env.GUARDS_BASE_FILE) : gitShow(WORKFLOW)
  const branch = readOr(process.env.GUARDS_BRANCH_FILE || path.join(ROOT, WORKFLOW))
  if (base === null) {
    bad(`FAIL: R1 ratchet: cannot read base ${WORKFLOW} (origin/main not resolvable) — run 'git fetch origin main' first`)
    return
  }
  if (branch === null) { bad(`FAIL: R1 ratchet: cannot read branch ${WORKFLOW}`); return }
  for (const error of parserMarkerErrors(base)) out(`WARN: R1 parser markers: base (origin/main) ${WORKFLOW}: ${error}`)
  const branchErrs = parserMarkerErrors(branch)
  for (const error of branchErrs) bad(`FAIL: R1 parser markers: ${WORKFLOW}: ${error} — balance the markers (each parser-begin needs exactly one parser-end)`)
  if (branchErrs.length) return
  const counters = [
    ['agent-calls', countAgentCalls],
    ['simulate-seams', countSimulateSeams],
    ['agent-output-regex', countRegexApps],
  ]
  for (const [name, function_] of counters) {
    const b = function_(base)
    const m = function_(branch)
    const ok = m <= b
    out(`R1 ${name} base=${b} branch=${m} ${ok ? 'ok' : 'UP'}`)
    if (!ok) failed++
  }
}

// ---- Invariant 25 -----------------------------------------------------------------------------

// Every test-*.sh|cjs|js file of the tree (relative path), whatever its depth. Symlinks are not followed.
const TEST_FOLDERS = ['tests', 'hooks', 'scripts', 'templates', 'plugins/backlog/tests']
const SKIPPED_FOLDERS = new Set(['.git', 'node_modules', '.venv', '.pipeline', '.probes', 'fixtures', '__pycache__'])
function walkTestFiles(relative) {
  const found = []
  for (const entry of fs.readdirSync(path.join(ROOT, relative), { withFileTypes: true })) {
    const child = relative === '' ? entry.name : `${relative}/${entry.name}`
    if (entry.isDirectory() && !SKIPPED_FOLDERS.has(entry.name)) found.push(...walkTestFiles(child))
    else if (entry.isFile() && /^test-.*\.(sh|cjs|js)$/.test(entry.name)) found.push(child)
  }
  return found.sort()
}

function checkWired() {
  const yml = readOr(path.join(ROOT, GUARDS_YML))
  if (yml === null) { bad(`FAIL: all-tests-wired: ${GUARDS_YML} missing`); return }
  const suites = ['scripts/run-offline.cjs']
  const stray = []
  for (const relativePath of walkTestFiles('')) {
    if (TEST_FOLDERS.some((folder) => relativePath.startsWith(`${folder}/`))) suites.push(relativePath)
    else stray.push(relativePath)
  }
  if (stray.length) { bad(`FAIL: all-tests-wired: test file outside every known test folder (${TEST_FOLDERS.join(', ')}): ${stray.join(', ')}`); return }
  const runText = ymlRunText(yml)
  const missing = suites.filter((s) => !EXEMPT[s] && !runText.includes(s))
  if (missing.length) bad(`FAIL: all-tests-wired: not referenced in a run: step of ${GUARDS_YML} (comments do not count): ${missing.join(', ')}`)
  else out(`PASS: all-tests-wired: ${suites.length} suites checked, ${Object.keys(EXEMPT).length} documented exemption(s)`)
}

// ---- Guard steps (#308) -----------------------------------------------------------------------
// The `guards` job must keep running the three suites that judge every PR, compared with origin/main's guards.yml:
// a step the base runs and the branch no longer runs fails (the command text counts, not the step name; comments do not).
const GUARD_STEPS = ['templates/test-canonical-guards.sh', 'scripts/run-flow-suite.cjs', 'scripts/run-offline.cjs']
function checkGuardSteps() {
  const branch = readOr(path.join(ROOT, GUARDS_YML))
  if (branch === null) { bad(`FAIL: guard-steps: ${GUARDS_YML} missing`); return }
  const base = process.env.GUARDS_BASE_YML ? readOr(process.env.GUARDS_BASE_YML) : gitShow(GUARDS_YML)
  if (base === null) { bad(`FAIL: guard-steps: cannot read base ${GUARDS_YML} (origin/main not resolvable) - run 'git fetch origin main' first`); return }
  const baseRun = jobRunText(base, 'guards')
  const branchRun = jobRunText(branch, 'guards')
  const lost = GUARD_STEPS.filter((s) => baseRun.includes(s) && !branchRun.includes(s))
  if (lost.length) { bad(`FAIL: guard-steps: the guards job of ${GUARDS_YML} no longer runs, compared with origin/main: ${lost.join(', ')}`); return }
  const n = GUARD_STEPS.filter((s) => baseRun.includes(s)).length
  out(`PASS: guard-steps: ${n} protected step(s) still run in the guards job (${GUARD_STEPS.join(', ')})`)
}

// ---- Invariant 1 (relaxed) --------------------------------------------------------------------
function checkVersion() {
  const baseTxt = process.env.GUARDS_BASE_MANIFEST ? readOr(process.env.GUARDS_BASE_MANIFEST) : gitShow(MANIFEST)
  const branchTxt = readOr(process.env.GUARDS_BRANCH_MANIFEST || path.join(ROOT, MANIFEST))
  if (baseTxt === null) { bad(`FAIL: version-floor: cannot read base ${MANIFEST} (origin/main not resolvable) — run 'git fetch origin main' first`); return }
  if (branchTxt === null) { bad(`FAIL: version-floor: cannot read ${MANIFEST}`); return }
  let bv, nv
  try { bv = parseSemver(JSON.parse(baseTxt).version); nv = parseSemver(JSON.parse(branchTxt).version) } catch (error) { bad(`FAIL: version-floor: invalid JSON (${error.message})`); return }
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
  // Human-gate text bridge (#28): one definition, one exemption, one rule sentence across the sites.
  const norm = (t) => t.replace(/\s+/g, ' ')
  const gateSites = [
    ...sites.map(([name, txt]) => [name, txt, true]),
    ['templates/pr-acceptance.md', readOr(process.env.GUARDS_PRACC_FILE || path.join(ROOT, 'templates/pr-acceptance.md')), false],
    ['.claude/rules/pr-acceptance.md', readOr(process.env.GUARDS_PRACC_COPY || path.join(ROOT, '.claude/rules/pr-acceptance.md')), false],
  ]
  const ruleSentences = []
  for (const [name, txt, carriesExemption] of gateSites) {
    if (txt === null) { if (!sites.some(([n]) => n === name)) problems.push(`${name} unreadable`); continue }
    const flat = norm(txt)
    if (!flat.includes(GATE_TEST)) problems.push(`${name} lacks the human-gate test`)
    if (flat.includes(OLD_GATE_DEF)) problems.push(`${name} still carries the retired human-gate definition`)
    if (carriesExemption && !flat.includes(EXEMPTION_KEY)) problems.push(`${name} lacks the proof-rule exemption`)
    const m = GATE_RULE_RE.exec(txt)
    if (!m) problems.push(`${name} lacks the human-gate rule sentence`)
    else ruleSentences.push([name, norm(m[0])])
  }
  for (const [name, sentence] of ruleSentences.slice(1)) {
    if (sentence !== ruleSentences[0][1]) problems.push(`${name} human-gate rule sentence differs from ${ruleSentences[0][0]}`)
  }
  // Follow-up issue rule (#29): one sentence, naming sub_issues, with the marker key once, on both sides.
  const followupSentences = []
  for (const [name, txt] of sites) {
    if (txt === null) continue
    const m = FOLLOWUP_RULE_RE.exec(txt)
    if (!m) { problems.push(`${name} lacks the follow-up issue rule`); continue }
    if (!m[0].includes('sub_issues')) problems.push(`${name} follow-up issue rule lacks sub_issues`)
    const sentence = norm(m[0].replace(/\\'/g, "'").replace(/'\s*;?\s*$/, ''))
    // The marker key lives in the rule only: the filing marker and the prefix scan.
    const keyCount = txt.split(FOLLOWUP_MARKER_KEY).length - 1
    const ruleKeyCount = sentence.split(FOLLOWUP_MARKER_KEY).length - 1
    if (ruleKeyCount < 1 || keyCount !== ruleKeyCount) problems.push(`${name} carries the follow-up marker ${keyCount} times, expected ${ruleKeyCount} (inside the rule only)`)
    followupSentences.push([name, sentence])
  }
  if (followupSentences.length === 2 && followupSentences[0][1] !== followupSentences[1][1]) {
    problems.push(`${followupSentences[1][0]} follow-up issue rule differs from ${followupSentences[0][0]}`)
  }
  if (problems.length) bad(`FAIL: sam-parity: ${problems.join('; ')}`)
  else out('PASS: sam-parity: patch-avoided: and the PLAN RULE sentence on both sides, the LAYER RULE sentence in the workflow, no engine vocabulary in the persona, no root-cause: field, one human-gate test, exemption and rule sentence across the workflow, the persona and both pr-acceptance copies, one follow-up issue rule across the workflow and the persona')
}

// ---- instructions-wired (#77) ------------------------------------------------------------------
// Claude Code loads CLAUDE.md and its `@path` imports for the session and its subagents; other tools
// read AGENTS.md. An import inside a fenced code block or a code span is inert, so both are skipped.
const IMPORTED_DOCS = ['VISION.md', 'ARCHITECTURE.md']
function checkInstructionsWired() {
  const problems = []
  const claude = readOr(path.join(ROOT, '.claude', 'CLAUDE.md'))
  if (claude === null) problems.push('.claude/CLAUDE.md missing')
  else {
    const lines = proseLines(claude)
    for (const document of IMPORTED_DOCS) {
      const target = `../${document}`
      const own = lines.filter((l) => l.replace(/[ \t]+$/, '') === `@${target}`).length
      const references = importReferences(lines, target)
      if (own === 0) problems.push(`.claude/CLAUDE.md has no line \`@${target}\` outside code`)
      else if (references > 1) problems.push(`.claude/CLAUDE.md imports ${document} ${references} times, keep exactly one \`@${target}\` line`)
      else if (!fs.existsSync(path.resolve(ROOT, '.claude', target))) problems.push(`.claude/CLAUDE.md imports @${target} but ${document} does not exist there`)
      // Imports resolve relative to the importing file: a bare `@VISION.md` looks inside .claude/ and loads nothing.
      if (importReferences(lines, document) > 0) problems.push(`.claude/CLAUDE.md has a bare \`@${document}\` import, which loads nothing from .claude/, use \`@${target}\``)
    }
    if (importReferences(lines, 'AGENTS.md') > 0) problems.push('.claude/CLAUDE.md imports AGENTS.md, which loads the docs twice')
  }
  const agentsMd = readOr(path.join(ROOT, 'AGENTS.md'))
  if (agentsMd === null) problems.push('AGENTS.md missing')
  else {
    const unnamed = IMPORTED_DOCS.filter((document) => !agentsMd.includes(document))
    if (unnamed.length) problems.push(`AGENTS.md does not name ${unnamed.join(', ')}`)
  }
  const agentsDirectory = path.join(ROOT, 'agents')
  const personas = fs.existsSync(agentsDirectory) ? fs.readdirSync(agentsDirectory).filter((f) => f.endsWith('.md')).sort() : []
  for (const f of personas) {
    const txt = fs.readFileSync(path.join(agentsDirectory, f), 'utf8').replace(/^\uFEFF/, '')
    const fm = /^---\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/.exec(txt)
    if (fm && /^omitClaudeMd[ \t]*:[ \t]*["']?true["']?[ \t]*(?:#.*)?$/im.test(fm[1])) problems.push(`agents/${f} sets omitClaudeMd: true`)
  }
  if (problems.length) bad(`FAIL: instructions-wired: ${problems.join('; ')}`)
  else out(`PASS: instructions-wired: .claude/CLAUDE.md imports ${IMPORTED_DOCS.map((d) => `@../${d}`).join(' and ')} once each, targets exist; AGENTS.md names both; ${personas.length} agents/*.md, none sets omitClaudeMd: true`)
}

// ---- doc-budgets (#77) --------------------------------------------------------------------------
const DOC_BUDGETS = [['VISION.md', 20], ['ARCHITECTURE.md', 20]]
// Per-line cap, so a long line cannot dodge the line budget. Counted in characters (code points).
const DOC_LINE_CAP = 160
// Same count as `wc -l` for a file ending with a newline; a last line without one still counts.
const lineCount = (t) => (t === '' ? 0 : t.split('\n').length - (t.endsWith('\n') ? 1 : 0))
function checkDocumentBudgets() {
  const problems = []
  const sizes = []
  for (const [relativePath, max] of DOC_BUDGETS) {
    const txt = readOr(path.join(ROOT, relativePath))
    if (txt === null) { problems.push(`${relativePath} missing`); continue }
    const n = lineCount(txt)
    const widths = txt.split('\n').map((l) => [...l.replace(/\r$/, '')].length)
    const longest = widths.reduce((a, w) => Math.max(a, w), 0)
    sizes.push(`${relativePath} ${n}/${max} lines, longest ${longest}/${DOC_LINE_CAP} chars`)
    if (n > max) problems.push(`${relativePath} has ${n} lines, budget ${max}`)
    const over = widths.map((w, index) => [index + 1, w]).filter(([, w]) => w > DOC_LINE_CAP)
    if (over.length) problems.push(`${relativePath} line ${over[0][0]} has ${over[0][1]} characters, cap ${DOC_LINE_CAP}` + (over.length > 1 ? ` (+${over.length - 1} more)` : ''))
  }
  if (problems.length) bad(`FAIL: doc-budgets: ${problems.join('; ')} — move detail to docs/ (never imported), never raise the budget`)
  else out(`PASS: doc-budgets: ${sizes.join('; ')}`)
}

// ---- status-table (#180) -----------------------------------------------------------------------
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
  for (const k of keys.filter((key, index) => keys.indexOf(key) !== index)) problems.push(`STATUS key '${k}' is declared twice in ${WORKFLOW}`)
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

// ---- phase-titles (#141) -----------------------------------------------------------------------
// The declared titles are the `title: '...'` entries of the `phases: [` list inside the top-level
// `export const meta = { ... }` block (closed by a `}` at column 0); anything after the block is ignored.
const PHASE_TITLE_CAP = 16
function checkPhaseTitles() {
  const js = readOr(process.env.GUARDS_PHASES_JS_FILE || path.join(ROOT, WORKFLOW))
  if (js === null) { bad(`FAIL: phase-titles: cannot read ${WORKFLOW}`); return }
  const titles = declaredPhaseTitles(js)
  if (!titles) { bad(`FAIL: phase-titles: no \`phases: [ { title: '...' } ]\` list in the \`export const meta\` block of ${WORKFLOW}`); return }
  const problems = []
  for (const t of [...new Set(titles)]) {
    const n = [...t].length
    if (n > PHASE_TITLE_CAP) problems.push(`title '${t}' has ${n} characters, cap ${PHASE_TITLE_CAP}`)
  }
  // Each pair once; the shorter title (the first one when equal) is named as the prefix.
  for (let index = 0; index < titles.length; index++) {
    for (let index_ = index + 1; index_ < titles.length; index_++) {
      const [short, long] = titles[index].trim().length <= titles[index_].trim().length ? [titles[index], titles[index_]] : [titles[index_], titles[index]]
      if (long.trim().toLowerCase().startsWith(short.trim().toLowerCase())) problems.push(`title '${short}' is a prefix of '${long}' (case-insensitive), the progress view merges them`)
    }
  }
  if (problems.length) { for (const pr of problems) bad(`FAIL: phase-titles: ${pr}`); return }
  out(`PASS: phase-titles: ${titles.length} declared titles, longest ${Math.max(...titles.map((t) => [...t].length))}/${PHASE_TITLE_CAP} characters, none a prefix of another`)
}

function checkInitStubs() {
  let module_
  try {
    module_ = require(process.env.GUARDS_INIT_STUBS || path.join(ROOT, 'scripts/init-specifics.cjs'))
  } catch (_) {
    bad('FAIL: init-stubs: cannot load the stubs module')
    return
  }
  const stubs = module_.STUBS
  const names = stubs && typeof stubs === 'object' ? Object.keys(stubs) : []
  if (names.length === 0) { bad('FAIL: init-stubs: no stub exported'); return }
  const problems = []
  const emptyOnceStripped = (txt) => {
    let previous
    let current = txt
    do { previous = current; current = current.replace(/<!--[\s\S]*?-->/g, '') } while (current !== previous)
    return current.trim() === ''
  }
  for (const n of names) {
    const txt = String(stubs[n])
    const w = ENGINE_WORDS_RE.exec(txt)
    if (w) problems.push(`stub '${n}' carries the engine word '${w[0]}'`)
    if (!emptyOnceStripped(txt)) problems.push(`stub '${n}' is not empty once comments are stripped`)
  }
  // Lane stub (#271): the frontmatter is stripped with the comments; a module without laneStub (the test seam) is tolerated.
  let laneStubs = 0
  if (typeof module_.laneStub === 'function') {
    const txt = String(module_.laneStub('sam', 'ios'))
    const w = ENGINE_WORDS_RE.exec(txt)
    if (w) problems.push(`lane stub carries the engine word '${w[0]}'`)
    const body = txt.startsWith('---\n') && txt.indexOf('\n---\n', 3) > 0 ? txt.slice(txt.indexOf('\n---\n', 3) + 5) : txt
    if (!emptyOnceStripped(body)) problems.push('lane stub is not empty once its frontmatter and comments are stripped')
    laneStubs = 1
  }
  let laneSentences = 0
  try {
    const sentence = require(path.join(ROOT, 'scripts/agent-context.cjs')).laneSentence('Ivy', 'senior iOS engineer')
    const w = ENGINE_WORDS_RE.exec(sentence)
    if (w) problems.push(`lane sentence carries the engine word '${w[0]}'`)
    if (sentence === '') problems.push('lane sentence is empty for a persona')
    laneSentences = 1
  } catch (_) {
    problems.push('cannot load laneSentence from scripts/agent-context.cjs')
  }
  if (problems.length) { for (const pr of problems) bad(`FAIL: init-stubs: ${pr}`); return }
  out(`PASS: init-stubs: ${names.length} stubs, ${laneStubs} lane stub, ${laneSentences} lane sentence, no engine vocabulary, empty once comments are stripped`)
}

// ---- audit (#289) -------------------------------------------------------------------------------
const AUDIT_BASELINE = 'scripts/audit-baseline.json'
function parseJsonOr(text) {
  try { return JSON.parse(text) } catch (_) { return null }
}
function originResolves() {
  try {
    execFileSync('git', ['rev-parse', '--verify', '--quiet', 'origin/main'], { cwd: ROOT, stdio: 'ignore' })
    return true
  } catch (_) {
    return false
  }
}
// A new rule may enter the baseline only when a tool config changes in the same branch.
const AUDIT_TOOL_CONFIGS = ['eslint.config.js', '.ls-lint.yml', 'ruff.toml']
// Working tree vs origin/main with rename detection: renames maps new path -> old path, changed holds every path touched
// (both sides of a rename). Null when git fails.
function auditDiffAgainstOrigin() {
  let raw
  try {
    raw = execFileSync('git', ['diff', '-M', '--name-status', '-z', 'origin/main', '--'], { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 1 << 28 })
  } catch (_) {
    return null
  }
  const tokens = raw.split('\0')
  const renames = new Map()
  const changed = new Set()
  for (let index = 0; index < tokens.length && tokens[index] !== ''; index++) {
    const status = tokens[index]
    if (status.startsWith('R') || status.startsWith('C')) {
      const [oldPath, newPath] = [tokens[index + 1], tokens[index + 2]]
      index += 2
      changed.add(oldPath)
      changed.add(newPath)
      if (status.startsWith('R')) renames.set(newPath, oldPath)
    } else {
      index += 1
      changed.add(tokens[index])
    }
  }
  return { renames, changed }
}
function auditNewRules(branchBaseline, originBaseline, changed) {
  const originRules = new Set(Object.values(originBaseline).flatMap((rules) => Object.keys(rules || {})))
  const unlocked = AUDIT_TOOL_CONFIGS.some((config) => changed.has(config))
  const entering = new Set()
  for (const rules of Object.values(branchBaseline)) {
    for (const rule of Object.keys(rules || {})) if (!originRules.has(rule)) entering.add(rule)
  }
  if (unlocked) return { entering, held: true }
  for (const rule of [...entering].sort()) {
    bad(`FAIL: audit: NEW-RULE ${rule} absent from origin/main ${AUDIT_BASELINE} and no tool config file (${AUDIT_TOOL_CONFIGS.join(', ')}) changed in this branch`)
  }
  return { entering, held: entering.size === 0 }
}
// Rule 2: the baseline only goes down (a renamed file keeps its budget), and a rule enters only with a tool config change.
// Returns false (after printing the named reds) when it was raised vs origin/main.
function auditBaselineHolds(branchText) {
  const branchBaseline = parseJsonOr(branchText)
  if (branchBaseline === null || typeof branchBaseline !== 'object') { bad(`FAIL: audit: ${AUDIT_BASELINE} missing or invalid`); return false }
  const originText = gitShow(AUDIT_BASELINE)
  if (originText === null) {
    if (!originResolves()) { bad(`FAIL: audit: baseline-vs-origin: cannot read base ${AUDIT_BASELINE} (origin/main not resolvable) — run 'git fetch origin main' first`); return false }
    out('SKIP: baseline-vs-origin (no base baseline)')
    return true
  }
  const originBaseline = parseJsonOr(originText) || {}
  const diff = auditDiffAgainstOrigin()
  if (diff === null) { bad('FAIL: audit: baseline-vs-origin: cannot run git diff -M origin/main'); return false }
  const newRules = auditNewRules(branchBaseline, originBaseline, diff.changed)
  let held = newRules.held
  for (const [file, rules] of Object.entries(branchBaseline)) {
    const origin = originBaseline[diff.renames.get(file) || file] || {}
    for (const [rule, count] of Object.entries(rules)) {
      if (newRules.entering.has(rule)) continue
      const allowed = origin[rule] || 0
      if (count > allowed) { bad(`FAIL: audit: baseline-vs-origin ${file} ${rule} ${count} > origin/main ${allowed}`); held = false }
    }
  }
  return held
}
// Rule 1: the audit ratchet (size, naming, lint) of scripts/audit.cjs, run as the CI and the pre-commit run it.
function checkAudit() {
  const branchText = readOr(path.join(ROOT, AUDIT_BASELINE))
  if (branchText === null) { bad(`FAIL: audit: ${AUDIT_BASELINE} missing`); return }
  if (!auditBaselineHolds(branchText)) return
  const printLines = (text) => { for (const line of String(text || '').split('\n')) if (line !== '') out(line) }
  try {
    printLines(execFileSync(process.execPath, [path.join(__dirname, 'audit.cjs'), '--check'], { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }))
  } catch (failure) {
    failed++
    printLines(failure.stdout)
    printLines(failure.stderr)
  }
}

if (ONLY.includes('r1')) checkR1()
if (ONLY.includes('wired')) checkWired()
if (ONLY.includes('guard-steps')) checkGuardSteps()
if (ONLY.includes('version')) checkVersion()
if (ONLY.includes('parity')) checkSamParity()
if (ONLY.includes('budgets')) checkDocumentBudgets()
if (ONLY.includes('instructions')) checkInstructionsWired()
if (ONLY.includes('status')) checkStatusTable()
if (ONLY.includes('phases')) checkPhaseTitles()
if (ONLY.includes('init-stubs')) checkInitStubs()
if (ONLY.includes('audit')) checkAudit()
process.exit(failed ? 1 : 0)
