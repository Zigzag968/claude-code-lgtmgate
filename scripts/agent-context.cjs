#!/usr/bin/env node
'use strict'

// Assembles the per-role project specifics a repo keeps in its own files (Mia, Sam, Nick, Morgan, Theo),
// from the BASE ref, never from the worktree: a PR cannot rewrite the rules that judge it. The script
// does the mechanical work (read, refuse, cap, digest); a model never runs here and nothing is asked.
//
// Source of truth: `.claude/pipeline.config.json` as committed at `origin/<base>` (read by sha):
//   projectSpecifics  folder holding shared.md, <role>.md, <role>.*.md (empty or absent = off)
//   agentContext      {"*": [paths], "<Role>": [paths]} extra files per role (Mia|Sam|Nick|Morgan|Theo)
// Per role, first wins, a path never repeats: shared.md (kept apart, in `shared`) -> <role>.md ->
// <role>.*.md (alphabetical, discovered with git ls-tree, never readdir) -> agentContext["*"] ->
// agentContext[Role]. A <role>.*.md file is a SUBJECT unless its frontmatter says `lane:` (lane
// filtering itself is #271; until then a lane file's body is part of the role text).
// Frontmatter (closed schema, no YAML library): `key: scalar` lines, keys lane|persona|hint|paths
// (paths = JSON array), at most 1024 bytes, persona|hint|paths only with lane.
//
// Caps: role text recommended 6144 B (warning, exit 0; `--accept-oversize <Role>` records the accepted
// size in the git-ignored .claude/pipeline.config.local.json, asked again above +25 %), shared 2048 B,
// per-agent total 8192 B (informational), hard ceiling 65536 B on the raw blobs (exit 4), <= 8 files
// per source. Digest = sha256(canonical JSON {refSha, role, text, lanes}) (same sha256 as the workflow).
//
// Usage: node scripts/agent-context.cjs [--root <repo>] [--ref origin/<base>] [--local <file>]
//        node scripts/agent-context.cjs --print [<role>|shared]
//        node scripts/agent-context.cjs --accept-oversize <Role>
// Stdout: one JSON line {ref, refSha, shared, roles, files, warnings} (a block = {text, digest, bytes, lanes}).
// Exit:  0 ok (empty payload when the switch is off) · 2 args, config schema, unknown role, bad ref,
//        frontmatter schema, nothing to accept · 3 file-level refusal (missing, symlink, submodule,
//        tree, `..`, absolute, not .md, `@` line, machine literal, invisible or control char, invalid
//        UTF-8, secret form, > 8 files per source, folder absent) · 4 hard ceiling.
//        Errors go to stderr, one per line, as `<path>: <rule> at line N` (never the value); stdout stays empty.
// Lead allow rule: Bash(node */scripts/agent-context.cjs:*)
// Scope: copy fidelity (the text the agents get is the text at the ref, screened for machine structure
// and secrets), not adversarial integrity: a maintainer who can write the base ref writes the rules.

const fs = require('fs')
const nodePath = require('path')
const crypto = require('crypto')
const { execFileSync } = require('child_process')
const { SECRET_REWRITES, PEM_RULE } = require('./lib/secret-rules.cjs')

const ROLES = ['Mia', 'Sam', 'Nick', 'Morgan', 'Theo']
const CAP_ROLE = 6144
const CAP_SHARED = 2048
const CAP_TOTAL = 8192
const CEILING = 65536
const MAX_FILES = 8
const FM_MAX = 1024
const FM_KEYS = ['lane', 'persona', 'hint', 'paths']

class Fail extends Error {
  constructor(code, errors) {
    super(errors[0])
    this.code = code
    this.errors = errors
  }
}

// ---- git (argv only: no shell string, literal pathspecs) -------------------------------------

function git(root, args, maxBuffer) {
  return execFileSync('git', ['-C', root, ...args], {
    encoding: 'buffer',
    maxBuffer: maxBuffer || 16 * 1024 * 1024,
    env: { ...process.env, GIT_LITERAL_PATHSPECS: '1' },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
}

function lsTree(root, treeish, p) {
  const args = ['ls-tree', '-z', '-l', treeish]
  if (p !== undefined) args.push('--', p)
  return git(root, args)
    .toString('utf8')
    .split('\0')
    .filter(Boolean)
    .map((rec) => {
      const t = rec.indexOf('\t')
      const m = rec.slice(0, t).trim().split(/\s+/)
      return { mode: m[0], type: m[1], oid: m[2], size: m[3] === '-' ? null : Number(m[3]), name: rec.slice(t + 1) }
    })
}

function resolveRef(root, ref) {
  if (!/^origin\/[A-Za-z0-9._\/-]+$/.test(ref) || ref.includes('..') || ref.split('/').some((s) => s === '' || s.startsWith('-'))) {
    throw new Fail(2, [`bad ref: ${JSON.stringify(ref)} (expected origin/<branch>)`])
  }
  let sha
  try {
    sha = git(root, ['rev-parse', '--verify', '--end-of-options', `refs/remotes/${ref}^{commit}`]).toString('utf8').trim()
  } catch (e) {
    throw new Fail(2, [`bad ref: ${ref} does not resolve to a commit`])
  }
  if (!/^[0-9a-f]{40}([0-9a-f]{24})?$/.test(sha)) throw new Fail(2, [`bad ref: ${ref} resolved to an unexpected value`])
  return sha
}

// ---- paths -------------------------------------------------------------------------------------

function validatePath(p, isDir) {
  if (typeof p !== 'string' || !/^[A-Za-z0-9._\/-]+$/.test(p)) return 'invalid-path'
  if (p.startsWith('/')) return 'absolute-path'
  const segs = p.split('/')
  if (segs.some((s) => s === '' || s === '.' || s === '..')) return 'bad-segment'
  if (!isDir && !p.endsWith('.md')) return 'not-md'
  return null
}

const REGULAR = { 100644: true, 100755: true }
function entryProblem(e) {
  if (e.type === 'blob' && REGULAR[e.mode]) return null
  if (e.mode === '120000') return 'symlink'
  if (e.mode === '160000') return 'submodule'
  if (e.type === 'tree') return 'tree'
  return 'not-regular-file'
}

// ---- content -----------------------------------------------------------------------------------

function normalise(buf) {
  let b = buf
  if (b.length >= 3 && b[0] === 0xef && b[1] === 0xbb && b[2] === 0xbf) b = b.subarray(3)
  const text = new TextDecoder('utf-8', { fatal: true }).decode(b)
  return text.replace(/\r\n?/g, '\n')
}

const trimBlank = (s) => s.replace(/^(?:[ \t]*\n)+/, '').replace(/(?:\n[ \t]*)+$/, '')
const stripComments = (s) => s.replace(/<!--[\s\S]*?-->/g, '')
const lineOf = (text, idx) => text.slice(0, idx).split('\n').length

// parseFrontmatter(text) -> {body, meta, errors}; meta = {lane, persona?, hint?, paths?} or null
function parseFrontmatter(text) {
  if (!text.startsWith('---\n') && text !== '---') return { body: text, meta: null, errors: [] }
  const lines = text.split('\n')
  let close = -1
  for (let i = 1; i < lines.length; i++) {
    if (lines[i].trimEnd() === '---') { close = i; break }
  }
  if (close < 0) return { body: text, meta: null, errors: ['frontmatter-unclosed at line 1'] }
  const errors = []
  const block = lines.slice(1, close).join('\n')
  if (Buffer.byteLength(block, 'utf8') > FM_MAX) errors.push('frontmatter-too-large at line 1')
  if (lines[close + 1] !== undefined && lines[close + 1].trimEnd() === '---') errors.push(`frontmatter-second-delimiter at line ${close + 2}`)
  const kv = {}
  for (let i = 1; i < close; i++) {
    const l = lines[i]
    if (l.trim() === '') continue
    const m = /^([A-Za-z]+):[ \t]*(.*)$/.exec(l)
    if (!m) { errors.push(`frontmatter-syntax at line ${i + 1}`); continue }
    const key = m[1]
    let val = m[2].trim()
    if (!FM_KEYS.includes(key)) { errors.push(`frontmatter-unknown-key at line ${i + 1}`); continue }
    if (Object.prototype.hasOwnProperty.call(kv, key)) { errors.push(`frontmatter-duplicate-key at line ${i + 1}`); continue }
    if (/^[&*!|>]/.test(val)) { errors.push(`frontmatter-forbidden-value at line ${i + 1}`); continue }
    if (key === 'paths') {
      let arr
      try { arr = JSON.parse(val) } catch (e) { arr = null }
      if (!Array.isArray(arr) || arr.some((x) => typeof x !== 'string')) { errors.push(`frontmatter-paths at line ${i + 1}`); continue }
      kv[key] = arr
      continue
    }
    if ((val.startsWith('"') && val.endsWith('"') && val.length >= 2) || (val.startsWith("'") && val.endsWith("'") && val.length >= 2)) val = val.slice(1, -1)
    if (val === '') { errors.push(`frontmatter-empty-value at line ${i + 1}`); continue }
    if (key === 'lane' && !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(val)) { errors.push(`frontmatter-lane-name at line ${i + 1}`); continue }
    kv[key] = val
  }
  if (!('lane' in kv) && Object.keys(kv).length > 0 && errors.length === 0) errors.push('frontmatter-needs-lane at line 1')
  const body = lines.slice(close + 1).join('\n')
  return { body, meta: 'lane' in kv ? kv : null, errors }
}

const MARKER_RE = /<!--\s*(acceptance:|ac:|pipeline-|decision-log)/i
const INVISIBLE_RE = /[\u00AD\u180E\u200B-\u200F\u2028-\u202E\u2060-\u206F\uFEFF]|[\u{E0000}-\u{E007F}]/u
const CONTROL_RE = /[\u0000-\u0008\u000B-\u001F\u007F-\u009F]/

// checkContent(text) -> ['<rule> at line N', ...]   (never the matched value)
function checkContent(text) {
  const out = []
  const hit = (rule, re) => {
    const m = re.exec(text)
    if (m) out.push(`${rule} at line ${lineOf(text, m.index)}`)
  }
  hit('control-char', CONTROL_RE)
  hit('invisible-char', INVISIBLE_RE)
  hit('machine-literal', /<\/?project_specifics/i)
  hit('machine-marker', MARKER_RE)
  hit('one-way-door-line', /^\s*one-way-door:/im)
  hit('at-line', /^[ \t]*@/m)
  const stripped = stripComments(text)
  if (stripped.includes('<!--')) {
    const idx = text.lastIndexOf('<!--')
    out.push(`unclosed-comment at line ${lineOf(text, idx)}`)
  }
  for (const r of SECRET_REWRITES) {
    if (text.replace(r.re, '') !== text) {
      const m = new RegExp(r.re.source, r.re.flags.replace('g', '')).exec(text)
      out.push(`secret-${r.id} at line ${lineOf(text, m ? m.index : 0)}`)
    }
  }
  const pem = PEM_RULE.re.exec(text)
  if (pem) out.push(`secret-${PEM_RULE.id} at line ${lineOf(text, pem.index)}`)
  return out
}

// ---- digest ------------------------------------------------------------------------------------

function canonicalJson(v) {
  if (Array.isArray(v)) return `[${v.map(canonicalJson).join(',')}]`
  if (v && typeof v === 'object') {
    return `{${Object.keys(v).filter((k) => v[k] !== undefined).sort().map((k) => `${JSON.stringify(k)}:${canonicalJson(v[k])}`).join(',')}}`
  }
  return JSON.stringify(v)
}

function digestOf(refSha, role, text, lanes) {
  return crypto.createHash('sha256').update(canonicalJson({ refSha, role, text, lanes }), 'utf8').digest('hex')
}

// ---- assembly ----------------------------------------------------------------------------------

function readBlobJson(root, sha, p, what) {
  const entries = lsTree(root, sha, p)
  if (entries.length === 0) return null
  const e = entries[0]
  if (entries.length !== 1 || e.name !== p || entryProblem(e)) throw new Fail(2, [`${p}: ${what} is not a regular file at the ref`])
  let cfg
  try {
    cfg = JSON.parse(git(root, ['cat-file', 'blob', e.oid]).toString('utf8'))
  } catch (err) {
    throw new Fail(2, [`${p}: not valid JSON at the ref`])
  }
  if (!cfg || typeof cfg !== 'object' || Array.isArray(cfg)) throw new Fail(2, [`${p}: not a JSON object`])
  return cfg
}

function readConfig(root, sha) {
  const cfg = readBlobJson(root, sha, '.claude/pipeline.config.json', 'config')
  const out = { dir: null, agentContext: null, accepted: {} }
  if (!cfg) return out
  const ps = cfg.projectSpecifics
  if (ps !== undefined && typeof ps !== 'string') throw new Fail(2, ['projectSpecifics must be a string'])
  if (typeof ps === 'string' && ps !== '') {
    const dir = ps.replace(/\/+$/, '')
    const bad = validatePath(dir, true)
    if (bad) throw new Fail(2, [`projectSpecifics: ${bad}`])
    out.dir = dir
  }
  const ac = cfg.agentContext
  if (ac !== undefined) {
    if (!ac || typeof ac !== 'object' || Array.isArray(ac)) throw new Fail(2, ['agentContext must be an object'])
    const errs = []
    for (const k of Object.keys(ac)) {
      if (k !== '*' && !ROLES.includes(k)) errs.push(`agentContext: unknown role ${JSON.stringify(k)}`)
      else if (!Array.isArray(ac[k]) || ac[k].some((x) => typeof x !== 'string')) errs.push(`agentContext.${k}: must be an array of path strings`)
    }
    if (errs.length) throw new Fail(2, errs)
    out.agentContext = ac
  }
  const acc = cfg.specifics && cfg.specifics.acceptOversize
  if (acc && typeof acc === 'object') Object.assign(out.accepted, numbersOnly(acc))
  return out
}

function numbersOnly(o) {
  const r = {}
  for (const k of Object.keys(o)) if (typeof o[k] === 'number' && Number.isFinite(o[k])) r[k] = o[k]
  return r
}

function readLocalAccepts(file) {
  try {
    const j = JSON.parse(fs.readFileSync(file, 'utf8'))
    const a = j && j.specifics && j.specifics.acceptOversize
    return a && typeof a === 'object' ? numbersOnly(a) : {}
  } catch (e) {
    return {}
  }
}

// Phase 2: which files, by name, from the ref's tree. Returns {files: Map, sharedPath, seqs: {role: [path]}}.
function resolveFiles(root, sha, cfg, errs) {
  const files = new Map()
  const reg = (p, e) => files.set(p, { path: p, oid: e.oid, bytes: e.size })
  const checked = (p, e) => {
    const pr = entryProblem(e)
    if (pr) { errs.push(`${p}: ${pr} at line 0`); return false }
    reg(p, e)
    return true
  }
  const byPath = (p) => {
    const bad = validatePath(p, false)
    if (bad) { errs.push(`${p}: ${bad} at line 0`); return null }
    const es = lsTree(root, sha, p)
    if (es.length !== 1 || es[0].name !== p) { errs.push(`${p}: missing at line 0`); return null }
    return checked(p, es[0]) ? p : null
  }
  let children = []
  let sharedPath = null
  if (cfg.dir) {
    const es = lsTree(root, sha, cfg.dir)
    if (es.length !== 1 || es[0].name !== cfg.dir || es[0].type !== 'tree') {
      errs.push(`${cfg.dir}: folder-absent at line 0`)
    } else {
      children = lsTree(root, `${sha}:${cfg.dir}`)
      const sh = children.find((c) => c.name === 'shared.md')
      if (sh && checked(`${cfg.dir}/shared.md`, sh)) sharedPath = `${cfg.dir}/shared.md`
    }
  }
  const star = cfg.agentContext && cfg.agentContext['*']
  const starPaths = []
  if (star) {
    if (star.length > MAX_FILES) errs.push(`agentContext.*: too-many-files at line 0`)
    else for (const p of star) { const r = byPath(p); if (r) starPaths.push(r) }
  }
  const seqs = {}
  for (const role of ROLES) {
    const lower = role.toLowerCase()
    const own = []
    const re = new RegExp(`^${lower}\\.[A-Za-z0-9._-]+\\.md$`)
    const names = children.filter((c) => c.name === `${lower}.md` || re.test(c.name)).sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))
    // role.md first, then role.*.md alphabetical
    names.sort((a, b) => (a.name === `${lower}.md` ? -1 : b.name === `${lower}.md` ? 1 : 0))
    if (names.length > MAX_FILES) errs.push(`${cfg.dir}/${lower}.*.md: too-many-files at line 0`)
    else for (const c of names) { const p = `${cfg.dir}/${c.name}`; if (checked(p, c)) own.push(p) }
    const rolePaths = []
    const list = cfg.agentContext && cfg.agentContext[role]
    if (list) {
      if (list.length > MAX_FILES) errs.push(`agentContext.${role}: too-many-files at line 0`)
      else for (const p of list) { const r = byPath(p); if (r) rolePaths.push(r) }
    }
    seqs[role] = [...own, ...starPaths, ...rolePaths]
  }
  return { files, sharedPath, seqs }
}

// Phase 4: bytes -> processed file {body, meta, empty}
function processFile(root, f, errs) {
  let text
  try {
    text = normalise(git(root, ['cat-file', 'blob', f.oid], CEILING + 1))
  } catch (e) {
    errs.push({ code: 3, msg: `${f.path}: invalid-utf8 at line 0` })
    return null
  }
  let bad = false
  for (const r of checkContent(text)) { errs.push({ code: 3, msg: `${f.path}: ${r}` }); bad = true }
  const fm = parseFrontmatter(text)
  for (const r of fm.errors) { errs.push({ code: 2, msg: `${f.path}: ${r}` }); bad = true }
  if (bad) return null
  const body = trimBlank(fm.body)
  const empty = stripComments(body).trim() === ''
  return { body, meta: fm.meta, empty }
}

function assemble(opts) {
  const root = opts.root
  const sha = resolveRef(root, opts.ref)
  const cfg = readConfig(root, sha)
  const empty = { ref: opts.ref, refSha: sha, shared: null, roles: {}, files: [], warnings: [] }
  if (!cfg.dir && !cfg.agentContext) return empty

  const errs = []
  const { files, sharedPath, seqs } = resolveFiles(root, sha, cfg, errs)
  if (errs.length) throw new Fail(3, errs)
  let total = 0
  for (const f of files.values()) total += f.bytes
  if (total > CEILING) throw new Fail(4, [`ceiling: ${total} bytes of specifics exceed ${CEILING} at line 0`])

  const cerrs = []
  const done = new Map()
  for (const f of files.values()) done.set(f.path, processFile(root, f, cerrs))
  if (cerrs.length) throw new Fail(cerrs[0].code, cerrs.map((e) => e.msg))

  const warnings = []
  const info = new Map() // path -> {path, oid, bytes, roles, empty?}
  for (const f of files.values()) {
    const d = done.get(f.path)
    info.set(f.path, { path: f.path, oid: f.oid, bytes: f.bytes, roles: [], ...(d.empty ? { empty: true } : {}) })
    if (d.empty) warnings.push({ kind: 'empty-ignored', path: f.path })
  }

  let shared = null
  if (sharedPath && !done.get(sharedPath).empty) {
    const text = done.get(sharedPath).body
    shared = { text, digest: digestOf(sha, 'shared', text, []), bytes: Buffer.byteLength(text, 'utf8') }
    info.get(sharedPath).roles.push('shared')
    if (shared.bytes > CAP_SHARED) warnings.push({ kind: 'shared-oversize', bytes: shared.bytes, recommended: CAP_SHARED })
  }

  const accepted = { ...cfg.accepted, ...readLocalAccepts(opts.local) }
  const roles = {}
  let maxRole = 0
  for (const role of ROLES) {
    const seen = new Set(sharedPath ? [sharedPath] : [])
    const parts = []
    const lanes = []
    for (const p of seqs[role]) {
      if (seen.has(p)) continue
      seen.add(p)
      const d = done.get(p)
      if (d.empty) continue
      parts.push(d.body)
      info.get(p).roles.push(role)
      if (d.meta) lanes.push({ file: p, ...d.meta })
    }
    if (parts.length === 0) continue
    const text = parts.join('\n\n')
    const bytes = Buffer.byteLength(text, 'utf8')
    roles[role] = { text, digest: digestOf(sha, role, text, lanes), bytes, lanes }
    maxRole = Math.max(maxRole, bytes)
    if (bytes > CAP_ROLE) {
      const a = typeof accepted[role] === 'number' ? accepted[role] : null
      if (a === null || bytes > a * 1.25) warnings.push({ kind: 'oversize', role, bytes, recommended: CAP_ROLE, accepted: a, ask: true })
    }
  }
  const totalBytes = (shared ? shared.bytes : 0) + maxRole
  if (totalBytes > CAP_TOTAL) warnings.push({ kind: 'total-oversize', bytes: totalBytes, recommended: CAP_TOTAL })

  return { ref: opts.ref, refSha: sha, shared, roles, files: [...info.values()], warnings }
}

// ---- output ------------------------------------------------------------------------------------

function renderPrint(payload, which) {
  const out = []
  const block = (name, b) => {
    out.push(`== ${name} (${b.bytes} bytes, digest ${b.digest.slice(0, 12)})`)
    const srcs = payload.files.filter((f) => f.roles.includes(name === 'shared' ? 'shared' : name)).map((f) => f.path)
    out.push(`sources: ${srcs.join(', ') || '-'}`)
    out.push(b.text)
    out.push('')
  }
  if (!which || which === 'shared') if (payload.shared) block('shared', payload.shared)
  for (const r of ROLES) if ((!which || which === r) && payload.roles[r]) block(r, payload.roles[r])
  if (which && which !== 'shared' && !payload.roles[which]) out.push(`(no specifics for ${which})`)
  for (const w of payload.warnings) out.push(`warning: ${JSON.stringify(w)}`)
  return out.join('\n') + '\n'
}

function acceptOversize(payload, role, localFile) {
  if (!ROLES.includes(role)) throw new Fail(2, [`unknown role: ${role}`])
  const b = payload.roles[role]
  if (!b || b.bytes <= CAP_ROLE) throw new Fail(2, [`nothing to accept: ${role} is within ${CAP_ROLE} bytes`])
  let obj = {}
  if (fs.existsSync(localFile)) {
    try { obj = JSON.parse(fs.readFileSync(localFile, 'utf8')) } catch (e) { throw new Fail(2, [`${localFile}: not valid JSON`]) }
    if (!obj || typeof obj !== 'object' || Array.isArray(obj)) throw new Fail(2, [`${localFile}: not a JSON object`])
  }
  if (obj.specifics === undefined) obj.specifics = {}
  if (!obj.specifics || typeof obj.specifics !== 'object' || Array.isArray(obj.specifics)) throw new Fail(2, [`${localFile}: specifics is not an object`])
  if (obj.specifics.acceptOversize === undefined) obj.specifics.acceptOversize = {}
  if (!obj.specifics.acceptOversize || typeof obj.specifics.acceptOversize !== 'object' || Array.isArray(obj.specifics.acceptOversize)) throw new Fail(2, [`${localFile}: specifics.acceptOversize is not an object`])
  obj.specifics.acceptOversize[role] = b.bytes
  const tmp = `${localFile}.tmp-${process.pid}`
  fs.mkdirSync(nodePath.dirname(localFile), { recursive: true })
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2) + '\n')
  fs.renameSync(tmp, localFile)
  return { accepted: { [role]: b.bytes }, file: localFile }
}

function parseArgs(argv) {
  const o = { root: process.cwd(), ref: 'origin/main', local: null, print: null, accept: null }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    const val = () => {
      if (i + 1 >= argv.length) throw new Fail(2, [`${a} needs a value`])
      return argv[++i]
    }
    if (a === '--root') o.root = val()
    else if (a === '--ref') o.ref = val()
    else if (a === '--local') o.local = val()
    else if (a === '--accept-oversize') o.accept = val()
    else if (a === '--print') o.print = i + 1 < argv.length && !argv[i + 1].startsWith('--') ? argv[++i] : ''
    else throw new Fail(2, [`unknown argument: ${a}`, 'usage: agent-context.cjs [--root <repo>] [--ref origin/<base>] [--local <file>] [--print [role]] [--accept-oversize <Role>]'])
  }
  if (!o.local) o.local = nodePath.join(o.root, '.claude', 'pipeline.config.local.json')
  return o
}

function main(argv) {
  try {
    const o = parseArgs(argv)
    const payload = assemble(o)
    if (o.accept !== null) {
      process.stdout.write(JSON.stringify(acceptOversize(payload, o.accept, o.local)) + '\n')
    } else if (o.print !== null) {
      if (o.print && o.print !== 'shared' && !ROLES.includes(o.print)) throw new Fail(2, [`unknown role: ${o.print}`])
      process.stdout.write(renderPrint(payload, o.print))
    } else {
      process.stdout.write(JSON.stringify(payload) + '\n')
    }
    return 0
  } catch (e) {
    if (e instanceof Fail) {
      for (const m of e.errors) process.stderr.write(`agent-context: ${m}\n`)
      return e.code
    }
    process.stderr.write(`agent-context: ${String(e && e.message ? e.message : e).split('\n')[0]}\n`)
    return 2
  }
}

module.exports = { canonicalJson, normalise, parseFrontmatter, checkContent, validatePath, assemble, digestOf, renderPrint }

if (require.main === module) process.exitCode = main(process.argv.slice(2))
