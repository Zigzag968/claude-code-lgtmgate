#!/usr/bin/env node
'use strict'

// Read-only audit of the agents context files a consumer keeps (`projectSpecifics` folder and
// `agentContext` lists), as committed at the BASE ref. It reuses `assemble()` of agent-context.cjs, so
// the files, roles, sizes, lanes and refusals are exactly what a launch sees; it only measures, prints
// and proposes. It never writes a file, never calls --accept-oversize, never runs a model.
//
// Usage: node scripts/runtime/context-audit.cjs [--root <repo>] [--ref origin/<base> | --sha <hex>] [--local <file>] [--json]
// Lead allow rule: Bash(node */scripts/runtime/context-audit.cjs:*)

const nodePath = require('path')
const { execFileSync } = require('child_process')
const { assemble } = require('./agent-context.cjs')
const { normalise, parseFrontmatter, trimBlank } = require('../lib/agent-context-text.cjs')

const ROLES = ['Mia', 'Sam', 'Nick', 'Morgan', 'Theo']
const CAP_ROLE = 6144
const CAP_SHARED = 2048
const CAP_TOTAL = 8192
const SIMILARITY = 0.7
const MIN_LINE = 8
const MIN_SECTION = 100

const HELP = `context-audit: read-only audit of the agents context files (projectSpecifics, agentContext).

Inputs:  --root <repo> (default: cwd) · --ref origin/<base> (default origin/main) or --sha <hex> (exclusive)
         --local <file> (read only, default <root>/.claude/pipeline.config.local.json) · --json · --help
Reads:   the files as committed at the ref, through the assembler of agent-context.cjs (git ls-tree / cat-file only).
Output:  stdout, sections in this order (--json prints the same data as one JSON object):
  [deterministic] duplicates       a path listed for 2+ roles, or one content under two paths; bytes x copies; saving if moved to agentContext["*"]
  [deterministic] near-identical   two files of different roles sharing >= 70 % of their lines (e.g. lane files; one lane file per role until #481)
  [deterministic] sizes            role / shared / total bytes against 6144 / 2048 / 8192, largest files of the roles over the cap, what to cut first
  [advisory] sections              heading sections labelled hard / procedure / mixed from text patterns: a heuristic, no model call
  [proposal] printed only          the split to consider; nothing is written, the owner applies it
Never:   writes a file, accepts an oversize, calls a model. Output is a pure function of the ref.
Exit:    0 ok · 2 args, config, bad ref · 3 file refusal · 4 hard ceiling (same codes as agent-context.cjs)
`

function usageError(message) {
  process.stderr.write(`context-audit: ${message}\n`)
  process.exit(2)
}

function parseArguments(argv) {
  const o = { root: process.cwd(), ref: null, sha: null, local: null, json: false, help: false }
  const value = (index, name) => {
    if (index + 1 >= argv.length || argv[index + 1].startsWith('--')) usageError(`${name} needs a value`)
    return argv[index + 1]
  }
  for (let index = 0; index < argv.length; index++) {
    const a = argv[index]
    if (a === '--help' || a === '-h') o.help = true
    else if (a === '--json') o.json = true
    else if (a === '--root') o.root = nodePath.resolve(value(index++, a))
    else if (a === '--ref') o.ref = value(index++, a)
    else if (a === '--sha') o.sha = value(index++, a)
    else if (a === '--local') o.local = nodePath.resolve(value(index++, a))
    else usageError(`unknown argument ${JSON.stringify(a)}; try --help`)
  }
  if (o.ref !== null && o.sha !== null) usageError('--ref and --sha are exclusive')
  if (o.sha === null && o.ref === null) o.ref = 'origin/main'
  if (o.local === null) o.local = nodePath.join(o.root, '.claude', 'pipeline.config.local.json')
  return o
}

// ---- text analysis (pure) ---------------------------------------------------------------------

const bytesOf = (text) => Buffer.byteLength(text, 'utf8')

function bodyOf(root, oid) {
  const text = normalise(execFileSync('git', ['-C', root, 'cat-file', 'blob', oid], { stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 16 * 1024 * 1024 }))
  return trimBlank(parseFrontmatter(text).body)
}

function lineSet(body) {
  const set = new Set()
  for (const line of body.split('\n')) {
    const t = line.trim()
    if (t.length >= MIN_LINE) set.add(t)
  }
  return set
}

function similarity(a, b) {
  if (a.size === 0 || b.size === 0) return { score: 0, shared: 0 }
  let common = 0
  let sharedBytes = 0
  for (const line of a) {
    if (b.has(line)) {
      common++
      sharedBytes += bytesOf(line) + 1
    }
  }
  return { score: common / (a.size + b.size - common), shared: sharedBytes }
}

function slug(heading) {
  return heading.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '')
}

function splitSections(body) {
  const sections = []
  let current = { heading: '(intro)', lines: [] }
  let fenceMark = null
  for (const line of body.split('\n')) {
    const fence = /^\s*(`{3,}|~{3,})/.exec(line)
    if (fence) {
      if (fenceMark === null) fenceMark = fence[1][0]
      else if (fence[1][0] === fenceMark) fenceMark = null
    }
    const h = fenceMark === null && !fence ? /^#{1,6}\s+(.+?)\s*#*\s*$/.exec(line) : null
    if (h) {
      sections.push(current)
      current = { heading: h[1], lines: [line] }
    } else current.lines.push(line)
  }
  sections.push(current)
  return sections.map((s) => ({ heading: s.heading, text: s.lines.join('\n').trim() })).filter((s) => s.text !== '')
}

// Heuristic label from text patterns. `hard`: rule words; `procedure`: steps, a fenced block, a when/if lead-in.
function labelSection(section) {
  const lines = section.text.split('\n')
  const hardLines = lines.filter((l) => /\b(never|always|must|do not|forbidden|required)\b/i.test(l)).length
  const steps = lines.filter((l) => /^\s*(\d+[.)]|[-*])\s+\S/.test(l)).length
  const fenced = lines.some((l) => /^\s*(`{3,}|~{3,})/.test(l))
  const lead = /\b(when|if|in case|procedure|steps|checklist)\b/i.test(lines[0]) || /\b(when|if|in case|procedure|steps|checklist)\b[^\n]*:\s*$/im.test(section.text)
  const procedure = (steps >= 3 ? 1 : 0) + (fenced ? 1 : 0) + (lead ? 1 : 0)
  if (procedure >= 2) return hardLines > 0 ? 'mixed' : 'procedure'
  if (hardLines > 0) return procedure === 0 ? 'hard' : 'mixed'
  return 'mixed'
}

// ---- report (pure over the assembler payload and the bodies) ----------------------------------

function roleNames(f) {
  return f.roles.filter((r) => r !== 'shared').sort()
}

function findDuplicates(files) {
  const entries = []
  for (const f of files) {
    const roles = roleNames(f)
    if (roles.length < 2) continue
    entries.push({
      path: f.path,
      bytes: f.bytes,
      roles,
      copies: roles.length,
      saved: (roles.length - 1) * f.bytes,
      perAgentCost: roles.length < ROLES.length ? f.bytes : 0,
    })
  }
  const byOid = new Map()
  for (const f of files) {
    if (f.roles.length === 0) continue
    byOid.set(f.oid, [...(byOid.get(f.oid) || []), f])
  }
  const sameContent = []
  for (const group of byOid.values()) {
    if (group.length > 1) sameContent.push({ paths: group.map((g) => g.path).sort(), bytes: group[0].bytes })
  }
  entries.sort((a, b) => b.saved - a.saved || (a.path < b.path ? -1 : 1))
  sameContent.sort((a, b) => (a.paths[0] < b.paths[0] ? -1 : 1))
  return { entries, sameContent }
}

function findNearIdentical(files, sets) {
  const live = files.filter((f) => f.roles.length > 0 && !f.empty).sort((a, b) => (a.path < b.path ? -1 : 1))
  const pairs = []
  for (let first = 0; first < live.length; first++) {
    for (let second = first + 1; second < live.length; second++) {
      const a = live[first]
      const b = live[second]
      if (a.oid === b.oid) continue
      const ra = a.roles.join(',')
      if (ra === b.roles.join(',')) continue
      const s = similarity(sets.get(a.path), sets.get(b.path))
      if (s.score >= SIMILARITY) pairs.push({ a: a.path, b: b.path, similarity: Math.round(s.score * 100) / 100, sharedBytes: s.shared })
    }
  }
  return pairs
}

function sizeReport(payload, files, duplicates) {
  const largestOf = (role) => files.filter((f) => f.roles.includes(role)).sort((a, b) => b.bytes - a.bytes || (a.path < b.path ? -1 : 1))
  const roles = []
  let maxRole = null
  for (const r of ROLES) {
    const block = payload.roles[r]
    if (!block) continue
    const row = { role: r, bytes: block.bytes, cap: CAP_ROLE }
    if (block.bytes > CAP_ROLE) {
      row.over = block.bytes - CAP_ROLE
      row.largest = largestOf(r).slice(0, 3).map((f) => ({ path: f.path, bytes: f.bytes }))
    }
    roles.push(row)
    if (!maxRole || block.bytes > maxRole.bytes) maxRole = row
  }
  const sharedBytes = payload.shared ? payload.shared.bytes : 0
  const total = sharedBytes + (maxRole ? maxRole.bytes : 0)
  let cutFirst = null
  if (duplicates.entries.length > 0) cutFirst = duplicates.entries[0].path
  else if (maxRole && largestOf(maxRole.role).length > 0) cutFirst = largestOf(maxRole.role)[0].path
  return { roles, shared: { bytes: sharedBytes, cap: CAP_SHARED }, total: { bytes: total, cap: CAP_TOTAL }, cutFirst }
}

function adviseSections(files, bodies) {
  const out = []
  for (const f of files) {
    if (f.empty || !bodies.has(f.path)) continue
    for (const s of splitSections(bodies.get(f.path))) {
      const size = bytesOf(s.text)
      if (size < MIN_SECTION) continue
      out.push({ path: f.path, heading: s.heading, bytes: size, label: labelSection(s) })
    }
  }
  return out
}

function buildReport(payload, bodies) {
  const files = payload.files
  const duplicates = findDuplicates(files)
  const sets = new Map()
  for (const f of files) if (bodies.has(f.path)) sets.set(f.path, lineSet(bodies.get(f.path)))
  return {
    ref: payload.ref,
    refSha: payload.refSha,
    duplicates,
    nearIdentical: findNearIdentical(files.filter((f) => sets.has(f.path)), sets),
    sizes: sizeReport(payload, files, duplicates),
    sections: adviseSections(files, bodies),
  }
}

// ---- text rendering ---------------------------------------------------------------------------

function renderText(report) {
  const out = [`context-audit ref ${report.ref} @ ${report.refSha.slice(0, 12)}`]
  out.push('[deterministic] duplicates')
  for (const d of report.duplicates.entries) {
    const tail = d.perAgentCost === 0 ? '(no per-agent cost)' : `(roles not listing it gain ${d.perAgentCost} B)`
    out.push(`  ${d.path}  ${d.bytes} B  roles ${d.roles.join(', ')}  copies ${d.copies}  payload saved ${d.saved} B if moved to agentContext["*"]  ${tail}`)
  }
  for (const s of report.duplicates.sameContent) out.push(`  ${s.paths.join(' = ')}  ${s.bytes} B  same content under different paths`)
  if (report.duplicates.entries.length + report.duplicates.sameContent.length === 0) out.push('  none')

  out.push('[deterministic] near-identical')
  for (const p of report.nearIdentical) out.push(`  ${p.a} ~ ${p.b}  similarity ${p.similarity.toFixed(2)}  shared lines ${p.sharedBytes} B`)
  if (report.nearIdentical.length === 0) out.push('  none')

  out.push('[deterministic] sizes')
  for (const r of report.sizes.roles) {
    let line = `  ${r.role}  ${r.bytes} B  cap ${r.cap}`
    if (r.over !== undefined) line += `  over by ${r.over} B  largest: ${r.largest.map((f) => `${f.path} ${f.bytes} B`).join(', ')}`
    out.push(line)
  }
  out.push(`  shared ${report.sizes.shared.bytes} B  cap ${report.sizes.shared.cap}`)
  out.push(`  total ${report.sizes.total.bytes} B  cap ${report.sizes.total.cap}`)
  out.push(`  cut first: ${report.sizes.cutFirst || 'nothing to cut'}`)

  out.push('[advisory] sections (text patterns, no model call)')
  for (const s of report.sections) {
    out.push(`  ${s.path}#${s.heading}  ${s.bytes} B  ${s.label}`)
    if (s.label === 'procedure') out.push(`    pointer: - ${s.heading}: see ${s.path}#${slug(s.heading)}; read it when ${s.heading.toLowerCase()}`)
  }
  if (report.sections.length === 0) out.push('  none')

  out.push('[proposal] printed only, nothing is written')
  for (const d of report.duplicates.entries) out.push(`  move to agentContext["*"]: ${d.path}`)
  for (const p of report.nearIdentical) out.push(`  keep one lane file per role until #481: ${p.a} ~ ${p.b}`)
  for (const s of report.sections) if (s.label === 'procedure') out.push(`  replace by pointer: ${s.path}#${s.heading}`)
  return out.join('\n') + '\n'
}

// ---- main -------------------------------------------------------------------------------------

function main() {
  const options = parseArguments(process.argv.slice(2))
  if (options.help) {
    process.stdout.write(HELP)
    return 0
  }
  let payload
  try {
    payload = assemble({ root: options.root, ref: options.ref, sha: options.sha, local: options.local })
  } catch (error) {
    if (typeof error.code === 'number' && Array.isArray(error.errors)) {
      for (const message of error.errors) process.stderr.write(`context-audit: ${message}\n`)
      return error.code
    }
    process.stderr.write(`context-audit: ${error.message}\n`)
    return 2
  }
  const bodies = new Map()
  try {
    for (const f of payload.files) if (!f.empty) bodies.set(f.path, bodyOf(options.root, f.oid))
  } catch (error) {
    process.stderr.write(`context-audit: ${error.message}\n`)
    return 2
  }
  const report = buildReport(payload, bodies)
  process.stdout.write(options.json ? JSON.stringify(report) + '\n' : renderText(report))
  return 0
}

process.exitCode = main()
