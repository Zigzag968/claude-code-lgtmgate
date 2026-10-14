#!/usr/bin/env node
'use strict'

// Bounded helper of /lgtmgate:init (#267, epic #261): detects what a repo already says about itself and
// creates the project-specifics stubs under .claude/lgtmgate/. The script does the mechanical work (walk,
// detect, create-if-absent); the model only asks the owner and judges. Stdlib only, no network, no gh.
//
// Stubs are pointers: one HTML comment each, the owner completes them in their own words. Nothing is copied
// from the plugin (a copy drifts from the plugin, the owner's rules must survive plugin updates).
//
//        --lanes entries: 'ios' writes the three roles, 'ios:sam' writes that role only (sam|nick|morgan) (#481)
//        node scripts/runtime/init-specifics.cjs [--root <repo>] --config [--plugin-version <x.y.z>]   set projectSpecifics and minPluginVersion when absent or empty (#481)
// Usage: node scripts/runtime/init-specifics.cjs [--root <repo>]                           create the missing stubs
//        node scripts/runtime/init-specifics.cjs [--root <repo>] --detect                  what the repo already holds (JSON)
//        node scripts/runtime/init-specifics.cjs [--root <repo>] --propose [--plugin-version <x.y.z>] [--lanes a,b]   readable proposal, writes nothing
//        node scripts/runtime/init-specifics.cjs [--root <repo>] --lanes ios,web          create only sam|nick|morgan.<lane>.md (#271)
// Stdout (write mode): one JSON line {"created":[...],"kept":[...]} (relative paths, fixed role order; lane files after the role files).
// Exit:  0 ok · 2 usage (a lane name outside [a-z0-9-]{1,24} or a role outside sam|nick|morgan included), an absent or non-object config
//        for --config (file untouched), or a folder that cannot be created.
// Writes only inside <root>/.claude/lgtmgate/, only a file that does not exist (open flag wx): an existing
// path (file, symlink, directory) is kept and never opened.
// Lead allow rule: Bash(node */scripts/runtime/init-specifics.cjs:*)

const fs = require('fs')
const nodePath = require('path')
const { normalise, checkContent, parseFrontmatter } = require('../lib/agent-context-text.cjs')
const { classifyLanes, CONTEXT_FILE_HINT } = require('../lib/agent-context-lanes.cjs')

const DIR = '.claude/lgtmgate'
const ROLE_FILES = ['shared', 'sam', 'nick', 'morgan', 'theo', 'mia']
const SKIP = new Set(['.git', 'node_modules', '.pipeline', 'vendor', 'build', 'dist', 'target', 'Pods', '.venv'])
const MAX_DEPTH = 3
const STACK_FILES = {
  node: ['package.json'],
  xcode: ['Package.swift'],
  gradle: ['build.gradle', 'build.gradle.kts'],
  python: ['pyproject.toml', 'uv.lock'],
  rust: ['Cargo.toml'],
  go: ['go.mod'],
}
const SIGNAL_FILES = ['.nvmrc', 'nixpacks.toml', 'railpack.json', '.github/dependabot.yml']

const stub = (lines) => `<!-- ${lines.join('\n')}\n-->\n`

const STUBS = {
  shared: stub([
    'Owner notes read by every role. Complete this file in your own words; it is never rewritten.',
    '[ask] docs/issues language: the language of the docs and of the issues',
    '[ask] test policy: what must be tested, what may be skipped',
    '[ask] forbidden actions: what no role may ever do in this repo',
    'Keep it short: rules written here, no copy of a plugin file.',
  ]),
  sam: stub([
    'Owner notes read by the planner. Complete this file in your own words; it is never rewritten.',
    '[detect] the stacks, the CI workflows and the rule files the repo already holds',
    '[ask] rules to target: which rule files the planner must read',
  ]),
  nick: stub([
    'Owner notes read by the developer. Complete this file in your own words; it is never rewritten.',
    'build/test tools',
    '[detect] the build, test and format commands of the stack',
    '[ask] tools/CLI allowed: which tools and command line programs the developer may use',
    '[ask] rules to target: which rule files the developer must follow',
  ]),
  morgan: stub([
    'Owner notes read by the reviewer. Complete this file in your own words; it is never rewritten.',
    '[detect] the CI checks required before a merge',
    '[ask] branch protection: whether the base branch is protected and which checks it requires',
    '[ask] rules to target: which rule files the reviewer must apply',
  ]),
  theo: stub([
    'Owner notes read by the diagnostician. Complete this file in your own words; it is never rewritten.',
    '[ask] tools/CLI allowed: which tools and command line programs may be used to diagnose',
    '[ask] rules to target: which rule files the diagnostician must read',
  ]),
  mia: stub([
    'Owner notes read by the product manager. Complete this file in your own words; it is never rewritten.',
    '[ask] docs/issues language: the language of the issues she writes',
    '[ask] rules to target: which rule files she must read',
  ]),
}

// A lane stub (#271): the frontmatter declares the lane, the body is one comment the owner completes (persona, paths, hint).
const LANE_ROLES = ['sam', 'nick', 'morgan']
const LANE_NAME_RE = /^[a-z0-9-]{1,24}$/
const LANE_ROLE_NOUN = { sam: 'planner', nick: 'developer', morgan: 'reviewer' }
function laneStub(role, lane) {
  return `---\nlane: ${lane}\n---\n` + stub([
    `Owner notes read by the ${LANE_ROLE_NOUN[role] || 'agent'} when the ${lane} lane applies. Complete this file in your own words; it is never rewritten.`,
    '[ask] persona (optional): a single name',
    '[ask] paths: the globs of the files this lane covers',
    '[ask] hint (120 characters at most): one line on what this role is in this lane',
  ])
}

// ---- detect ------------------------------------------------------------------------------------

const byCode = (a, b) => (a < b ? -1 : a > b ? 1 : 0)

// Bounded walk, no symlink followed: every relative path (files and directories) found down to MAX_DEPTH.
function walk(root) {
  const out = []
  const visit = (relative, depth) => {
    let ents
    try { ents = fs.readdirSync(nodePath.join(root, relative), { withFileTypes: true }) } catch (error) { return }
    for (const entry of ents) {
      if (SKIP.has(entry.name)) continue
      const r = relative ? `${relative}/${entry.name}` : entry.name
      out.push({ rel: r, dir: entry.isDirectory() })
      if (entry.isDirectory() && depth < MAX_DEPTH) visit(r, depth + 1)
    }
  }
  visit('', 0)
  return out
}

function hasPathsKey(file) {
  let fd
  try {
    fd = fs.openSync(file, 'r')
    const buffer = Buffer.alloc(512)
    const n = fs.readSync(fd, buffer, 0, 512, 0)
    const text = buffer.subarray(0, n).toString('utf8')
    if (!text.startsWith('---\n')) return false
    const end = text.indexOf('\n---', 4)
    const fm = end < 0 ? text.slice(4) : text.slice(4, end)
    return /^paths:/m.test(fm)
  } catch (error) {
    return false
  } finally {
    if (fd !== undefined) try { fs.closeSync(fd) } catch (error) { /* ignore */ }
  }
}

function detect(root) {
  const all = walk(root)
  const relativeSet = new Set(all.map((x) => x.rel))
  const stacks = new Set()
  for (const x of all) {
    const segs = x.rel.split('/')
    const base = segs[segs.length - 1]
    if (!x.dir) {
      for (const k of Object.keys(STACK_FILES)) if (STACK_FILES[k].includes(base)) stacks.add(k)
    }
    if (segs.some((s) => s.endsWith('.xcodeproj'))) stacks.add('xcode')
  }
  const direct = (prefix, re) => all.filter((x) => !x.dir && x.rel.startsWith(prefix) && !x.rel.slice(prefix.length).includes('/') && re.test(x.rel.slice(prefix.length))).map((x) => x.rel).sort(byCode)
  const rules = direct('.claude/rules/', /\.md$/).map((p) => ({ path: p, paths: hasPathsKey(nodePath.join(root, p)) }))
  const existing = ROLE_FILES.map((r) => {
    const p = `${DIR}/${r}.md`
    let pristine = false
    let present = false
    try {
      const st = fs.lstatSync(nodePath.join(root, p))
      present = true
      if (st.isFile()) pristine = fs.readFileSync(nodePath.join(root, p), 'utf8') === STUBS[r]
    } catch (error) { /* absent */ }
    return { path: p, present, pristine }
  })
  const stackList = [...stacks].sort(byCode)
  const laneFiles = []
  let directoryEntries = []
  try { directoryEntries = fs.readdirSync(nodePath.join(root, DIR), { withFileTypes: true }) } catch (error) { /* no folder yet */ }
  for (const entry of directoryEntries.map((x) => x).sort((a, b) => byCode(a.name, b.name))) {
    const m = /^(sam|nick|morgan|theo|mia)\.([a-z0-9-]{1,24})\.md$/.exec(entry.name)
    if (!m || !entry.isFile()) continue
    let pristine = false
    try { pristine = LANE_ROLES.includes(m[1]) && fs.readFileSync(nodePath.join(root, DIR, entry.name), 'utf8') === laneStub(m[1], m[2]) } catch (error) { /* unreadable */ }
    laneFiles.push({ path: `${DIR}/${entry.name}`, role: m[1], lane: m[2], pristine })
  }
  return {
    stacks: stackList,
    signals: SIGNAL_FILES.filter((s) => relativeSet.has(s)).sort(byCode),
    ci: direct('.github/workflows/', /\.ya?ml$/),
    rules,
    agentsMd: relativeSet.has('AGENTS.md'),
    mcp: relativeSet.has('.mcp.json'),
    existing,
    projectAgents: direct('.claude/agents/', /\.md$/).length,
    laneCandidates: stackList.length >= 2 ? stackList : [],
    laneFiles,
  }
}

// ---- propose -----------------------------------------------------------------------------------

// The content screen of scripts/runtime/agent-context.cjs (the exported checkContent, no copy of its rules) run on the files the
// proposal lists, as '<path>: <rule> at line N' (an unreadable or invalid UTF-8 file as the engine reports it).
function screenRefusals(root, paths) {
  const out = []
  for (const p of paths) {
    let text
    try {
      const file = nodePath.join(root, p)
      if (!fs.lstatSync(file).isFile()) continue
      text = normalise(fs.readFileSync(file))
    } catch (error) {
      if (error instanceof TypeError) out.push(`${p}: invalid-utf8 at line 0`)
      continue
    }
    for (const r of checkContent(text)) out.push(`${p}: ${r}`)
  }
  return out
}

// The assembler's own check (classifyLanes, no copy of the rule) for files that would be listed under agentContext: a file
// with a frontmatter is refused there. Unreadable, invalid UTF-8 or unparsable files are left to the content screen.
function contextFileRefusals(root, paths) {
  const done = new Map()
  for (const p of paths) {
    try {
      const file = nodePath.join(root, p)
      if (!fs.lstatSync(file).isFile()) continue
      const parsed = parseFrontmatter(normalise(fs.readFileSync(file)))
      if (parsed.errors.length === 0 && parsed.meta) done.set(p, { meta: parsed.meta })
    } catch (error) { continue }
  }
  return classifyLanes(['Sam'], done, { Sam: paths }, { Sam: [] }, DIR).errors
}

function propose(root, versionToWrite, lanes = []) {
  const d = detect(root)
  const list = (a) => (a.length ? a.join(', ') : 'none')
  const lines = [
    'lgtmgate init proposal',
    'detected',
    `  stacks: ${list(d.stacks)}`,
    `  signals: ${list(d.signals)}`,
    `  ci: ${list(d.ci)}`,
    `  rules: ${list(d.rules.map((r) => `${r.path} (${r.paths ? 'paths' : 'no paths'})`))}`,
    `  agents-md: ${d.agentsMd ? 'yes' : 'no'}`,
    `  mcp: ${d.mcp ? 'yes' : 'no'}`,
    `  project agents: ${d.projectAgents}`,
    `  lane candidates: ${list(d.laneCandidates)}`,
    'files',
  ]
  for (const entry of d.existing) {
    if (!entry.present) lines.push(`  create ${entry.path}`)
    else if (entry.pristine) lines.push(`  keep ${entry.path} (stub unchanged)`)
    else lines.push(`  keep ${entry.path} (edited by the owner, never touched)`)
  }
  for (const [l, r] of lanes) {
    const p = `${DIR}/${r}.${l}.md`
    const f = d.laneFiles.find((x) => x.path === p)
    if (!f) lines.push(`  create ${p}`)
    else if (f.pristine) lines.push(`  keep ${p} (stub unchanged)`)
    else lines.push(`  keep ${p} (edited by the owner, never touched)`)
  }
  const owned = [...d.rules.map((r) => r.path), ...d.existing.filter((entry) => entry.present && !entry.pristine).map((entry) => entry.path), ...d.laneFiles.filter((f) => !f.pristine).map((f) => f.path)]
  const refused = screenRefusals(root, owned)
  if (refused.length > 0) lines.push('refused by the content screen (/lgtmgate:deliver stops with exit 3 on these)', ...refused.map((r) => `  ${r}`))
  const listed = contextFileRefusals(root, d.rules.map((r) => r.path))
  if (listed.length > 0) lines.push('refused if listed under agentContext (/lgtmgate:deliver stops with exit 2 on these)', ...listed.map((r) => `  ${r}`), `  ${CONTEXT_FILE_HINT}`)
  lines.push(
    'config (.claude/pipeline.config.json, a key is set only when absent or empty)',
    `  projectSpecifics: ${JSON.stringify(DIR)}`,
    `  minPluginVersion: ${JSON.stringify(versionToWrite)}`,
    '  agentContext: unchanged (rules to target are asked per role)',
  )
  return lines.join('\n') + '\n'
}

// ---- write -------------------------------------------------------------------------------------

function writeStubs(root, lanes = []) {
  const directory = nodePath.join(root, DIR)
  fs.mkdirSync(directory, { recursive: true })
  const created = []
  const kept = []
  // With --lanes only the lane files are written (the role stubs come from the plain run); the plain run writes the role stubs.
  const targets = lanes.length > 0 ? [] : ROLE_FILES.map((r) => [`${DIR}/${r}.md`, STUBS[r]])
  for (const [l, r] of lanes) targets.push([`${DIR}/${r}.${l}.md`, laneStub(r, l)])
  for (const [relative, body] of targets) {
    let fd
    try {
      fd = fs.openSync(nodePath.join(root, relative), 'wx', 0o644)
    } catch (error) {
      if (error && error.code === 'EEXIST') { kept.push(relative); continue }
      throw error
    }
    try { fs.writeSync(fd, body) } finally { fs.closeSync(fd) }
    created.push(relative)
  }
  return { created, kept }
}

// ---- cli ---------------------------------------------------------------------------------------

function pluginVersion() {
  try {
    return JSON.parse(fs.readFileSync(nodePath.join(__dirname, '..', '..', '.claude-plugin', 'plugin.json'), 'utf8')).version
  } catch (error) {
    return '0.0.0'
  }
}

// #481: sets the two recommended keys of the owner's config when absent or empty; a present value is never touched.
function setConfigKeys(root, version) {
  const file = nodePath.join(root, '.claude', 'pipeline.config.json')
  let config
  try {
    config = JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch (error) {
    throw new Error('--config needs a readable .claude/pipeline.config.json holding JSON')
  }
  if (config === null || typeof config !== 'object' || Array.isArray(config)) throw new Error('--config needs a pipeline.config.json holding a JSON object')
  const set = []
  const kept = []
  for (const [key, value] of [['projectSpecifics', DIR], ['minPluginVersion', version]]) {
    if (config[key] === undefined || config[key] === '') { config[key] = value; set.push(key) } else kept.push(key)
  }
  if (set.length > 0) fs.writeFileSync(file, JSON.stringify(config, null, 2) + '\n')
  return { set, kept }
}

// A --lanes entry is 'lane' (the three roles) or 'lane:role' (that role only); deduplicated on the (lane, role) pair.
function expandLanes(entries) {
  const pairs = []
  for (const entry of entries) {
    const parts = entry.split(':')
    if (parts.length > 2) throw new Error('bad lane entry (expected lane or lane:role)')
    const [lane, role] = parts
    if (!LANE_NAME_RE.test(lane)) throw new Error('bad lane name (expected [a-z0-9-], 1 to 24 characters)')
    if (role !== undefined && !LANE_ROLES.includes(role)) throw new Error(`bad lane role (expected ${LANE_ROLES.join('|')})`)
    for (const r of role === undefined ? LANE_ROLES : [role]) {
      if (!pairs.some(([l, x]) => l === lane && x === r)) pairs.push([lane, r])
    }
  }
  return pairs
}

const USAGE = 'usage: init-specifics.cjs [--root <repo>] [--detect | --propose [--plugin-version <x.y.z>] | --config [--plugin-version <x.y.z>]] [--lanes a,b | a:sam,b:nick]'

function main(argv) {
  const o = { root: process.cwd(), mode: 'write', version: null, lanes: [] }
  for (let index = 0; index < argv.length; index++) {
    const a = argv[index]
    const value = () => {
      if (index + 1 >= argv.length) throw new Error(`${a} needs a value`)
      return argv[++index]
    }
    try {
      if (a === '--root') o.root = value()
      else if (a === '--detect') o.mode = 'detect'
      else if (a === '--propose') o.mode = 'propose'
      else if (a === '--plugin-version') o.version = value()
      else if (a === '--lanes') {
        o.lanes = expandLanes(value().split(','))
      }
      else if (a === '--config') o.mode = 'config'
      else throw new Error(`unknown argument: ${a}`)
    } catch (error) {
      process.stderr.write(`init-specifics: ${error.message}\n${USAGE}\n`)
      return 2
    }
  }
  if (o.version !== null && !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(o.version)) {
    process.stderr.write(`init-specifics: bad --plugin-version\n${USAGE}\n`)
    return 2
  }
  try {
    if (o.mode === 'detect') process.stdout.write(JSON.stringify(detect(o.root)) + '\n')
    else if (o.mode === 'config') process.stdout.write(JSON.stringify(setConfigKeys(o.root, o.version || pluginVersion())) + '\n')
    else if (o.mode === 'propose') process.stdout.write(propose(o.root, o.version || pluginVersion(), o.lanes))
    else process.stdout.write(JSON.stringify(writeStubs(o.root, o.lanes)) + '\n')
    return 0
  } catch (error) {
    process.stderr.write(`init-specifics: ${String(error && error.message ? error.message : error).split('\n')[0]}\n`)
    return 2
  }
}

// True when text is byte-equal to what init writes for relativePath (an unmodified stub).
function isInitStub(relativePath, text) {
  const name = nodePath.basename(relativePath, '.md')
  if (Object.prototype.hasOwnProperty.call(STUBS, name)) return STUBS[name] === text
  const m = /^(sam|nick|morgan)\.([a-z0-9-]{1,24})$/.exec(name)
  return m !== null && LANE_ROLES.includes(m[1]) && laneStub(m[1], m[2]) === text
}

module.exports = { STUBS, ROLE_FILES, laneStub, isInitStub, detect, propose, writeStubs }

if (require.main === module) process.exitCode = main(process.argv.slice(2))
