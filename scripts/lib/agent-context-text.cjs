'use strict'

// Text rules of scripts/agent-context.cjs, moved out unchanged to keep that file under the line limit: normalisation,
// frontmatter parsing, the content screen and the digest. Pure functions, no git, no file system.

const crypto = require('crypto')
const { SECRET_REWRITES, PEM_RULE } = require('./redaction-rules.cjs')

const FM_MAX = 1024
const FM_KEYS = ['lane', 'persona', 'hint', 'paths']
const FM_PERSONA_LEN = 80
const FM_HINT_LEN = 120
const FM_PATHS_MAX = 8
const FM_PATH_LEN = 80

function normalise(buffer) {
  let b = buffer
  if (b.length >= 3 && b[0] === 0xef && b[1] === 0xbb && b[2] === 0xbf) b = b.subarray(3)
  const text = new TextDecoder('utf-8', { fatal: true }).decode(b)
  return text.replace(/\r\n?/g, '\n')
}

const trimBlank = (s) => s.replace(/^(?:[ \t]*\n)+/, '').replace(/(?:\n[ \t]*)+$/, '')
// Repeat until stable so a comment opener rebuilt by a removal (`<!<!-- x -->--`) is stripped too.
const stripComments = (s) => {
  let previous
  let current = s
  do {
    previous = current
    current = current.replace(/<!--[\s\S]*?-->/g, '')
  } while (current !== previous)
  return current
}
const lineOf = (text, index) => text.slice(0, index).split('\n').length

// parseFrontmatter(text) -> {body, meta, errors}; meta = {lane?, persona?, hint?, paths?} or null (no key)
const LANE_RE = /^[a-z0-9-]{1,24}$/
function parseFrontmatter(text) {
  if (!text.startsWith('---\n') && text !== '---') return { body: text, meta: null, errors: [] }
  const lines = text.split('\n')
  let close = -1
  for (let index = 1; index < lines.length; index++) {
    if (lines[index].trimEnd() === '---') { close = index; break }
  }
  if (close < 0) return { body: text, meta: null, errors: ['frontmatter-unclosed at line 1'] }
  const errors = []
  const block = lines.slice(1, close).join('\n')
  if (Buffer.byteLength(block, 'utf8') > FM_MAX) errors.push('frontmatter-too-large at line 1')
  if (lines[close + 1] !== undefined && lines[close + 1].trimEnd() === '---') errors.push(`frontmatter-second-delimiter at line ${close + 2}`)
  const kv = {}
  for (let index = 1; index < close; index++) {
    const l = lines[index]
    if (l.trim() === '') continue
    const m = /^([A-Za-z]+):[ \t]*(.*)$/.exec(l)
    if (!m) { errors.push(`frontmatter-syntax at line ${index + 1}`); continue }
    const key = m[1]
    let value = m[2].trim()
    if (!FM_KEYS.includes(key)) { errors.push(`frontmatter-unknown-key at line ${index + 1}`); continue }
    if (Object.prototype.hasOwnProperty.call(kv, key)) { errors.push(`frontmatter-duplicate-key at line ${index + 1}`); continue }
    if (/^[&*!|>]/.test(value)) { errors.push(`frontmatter-forbidden-value at line ${index + 1}`); continue }
    if (key === 'paths') {
      let array
      try { array = JSON.parse(value) } catch (error) { array = null }
      if (!Array.isArray(array) || array.some((x) => typeof x !== 'string')) { errors.push(`frontmatter-paths at line ${index + 1}`); continue }
      if (array.length > FM_PATHS_MAX) { errors.push(`frontmatter-paths-too-many at line ${index + 1}`); continue }
      if (array.some((x) => x.length > FM_PATH_LEN)) { errors.push(`frontmatter-paths-entry-too-long at line ${index + 1}`); continue }
      kv[key] = array
      continue
    }
    if ((value.startsWith('"') && value.endsWith('"') && value.length >= 2) || (value.startsWith("'") && value.endsWith("'") && value.length >= 2)) value = value.slice(1, -1)
    if (value === '') { errors.push(`frontmatter-empty-value at line ${index + 1}`); continue }
    if (key === 'lane' && !LANE_RE.test(value)) { errors.push(`frontmatter-lane-name at line ${index + 1}`); continue }
    if (key === 'persona' && /\s/.test(value)) { errors.push(`frontmatter-persona-not-one-token at line ${index + 1}`); continue }
    if (key === 'persona' && value.length > FM_PERSONA_LEN) { errors.push(`frontmatter-persona-too-long at line ${index + 1}`); continue }
    if (key === 'hint' && value.length > FM_HINT_LEN) { errors.push(`frontmatter-hint-too-long at line ${index + 1}`); continue }
    kv[key] = value
  }
  const body = lines.slice(close + 1).join('\n')
  return { body, meta: Object.keys(kv).length > 0 ? kv : null, errors }
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
    const index = text.lastIndexOf('<!--')
    out.push(`unclosed-comment at line ${lineOf(text, index)}`)
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

function canonicalJson(v) {
  if (Array.isArray(v)) return `[${v.map(canonicalJson).join(',')}]`
  if (v && typeof v === 'object') {
    return `{${Object.keys(v).filter((k) => v[k] !== undefined).sort().map((k) => `${JSON.stringify(k)}:${canonicalJson(v[k])}`).join(',')}}`
  }
  return JSON.stringify(v)
}

function digestOf(referenceSha, role, text, lanes) {
  return crypto.createHash('sha256').update(canonicalJson({ refSha: referenceSha, role, text, lanes }), 'utf8').digest('hex')
}

module.exports = { normalise, trimBlank, stripComments, parseFrontmatter, checkContent, canonicalJson, digestOf }
