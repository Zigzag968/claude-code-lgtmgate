'use strict'

// The launch file of a run (#520, #553): a copy of workflows/deliver-pipeline.js whose `meta` literal differs from the engine so
// the run list tells two runs apart: the workflow name is the short issue title and the description reads `#<N>` (plus
// ` PR #<P>` when known) and the first line of the brief. Phase titles stay plain (`Setup` ... `Review`).
// Written by hooks/workflow-args-expand.sh under <project>/.pipeline/launch/ (gitignored). Pure functions plus one atomic write.
//
// retitle(source, issue, options?) -> the expected bytes, or null when the source does not have the exact shape (then nothing is
// written and the launch keeps the plugin's own engine). options = { title, brief, pr }, all optional. The name is `title`, else
// `#<N> <first brief line>`, else `#<N>`; computed from the inputs only, so retitle is idempotent and also normalizes a launch
// file of the previous shape (numbered phase titles).

const fs = require('fs')
const crypto = require('crypto')
const nodePath = require('path')

const BASE_TITLES = ['Setup', 'Diagnose', 'Plan', 'Dev', 'Review']
const NAME_BYTES = 80
const DESCRIPTION_CHARS = 120
const DIRECTORY = nodePath.join('.pipeline', 'launch')

const TITLE_RE = /(\{ title: ')(?:#\d+ )?([^']*)(')/g
const NAME_RE = /^(  name: ')((?:[^'\\\n]|\\.)*)(',)$/m
const DESCRIPTION_RE = /^(  description: ')(.*)(',)$/m
const CONSTANT_RE = /^const PHASE_TITLES = \{ setup: '(?:#\d+ )?Setup', diagnose: '(?:#\d+ )?Diagnose', plan: '(?:#\d+ )?Plan', dev: '(?:#\d+ )?Dev', review: '(?:#\d+ )?Review' \}$/gm

function metaBounds(source) {
  const start = source.indexOf('export const meta = {\n')
  if (start !== 0) return null
  const end = source.indexOf('\n}\n', start)
  return end < 0 ? null : { start, end: end + 2 }
}

// A title as the content of a single-quoted JS literal. Null for anything but a one-line string without control characters.
function escapeTitle(title) {
  if (typeof title !== 'string' || title.trim() === '' || /[\u0000-\u001f\u007f]/.test(title)) return null
  return title.split('\\').join('\\\\').split("'").join("\\'")
}

// First line of a brief, control characters to spaces, trimmed. '' when nothing is left.
function firstLine(brief) {
  if (typeof brief !== 'string') return ''
  return brief.split('\n')[0].replace(/[\u0000-\u001f\u007f]/g, ' ').trim()
}

function cutBytes(text, limit) {
  let out = ''
  let used = 0
  for (const character of text) {
    const size = Buffer.byteLength(character, 'utf8')
    if (used + size > limit) break
    out += character
    used += size
  }
  return out.trim()
}

function retitle(source, issue, options) {
  if (typeof source !== 'string' || !Number.isInteger(issue) || issue < 1) return null
  const given = typeof options === 'string' ? { title: options } : options || {}
  const line = firstLine(given.brief)
  let name
  if (given.title !== undefined) {
    name = escapeTitle(given.title)
    if (name === null) return null
  } else {
    name = escapeTitle(cutBytes(`#${issue}${line === '' ? '' : ` ${line}`}`, NAME_BYTES))
    if (name === null) return null
  }
  const pr = Number.isInteger(given.pr) && given.pr >= 1 ? ` PR #${given.pr}` : ''
  const short = escapeTitle([...line].slice(0, DESCRIPTION_CHARS).join('').trim())
  const description = `#${issue}${pr}${short === null ? '' : `: ${short}`}`
  const bounds = metaBounds(source)
  if (!bounds) return null
  const meta = source.slice(bounds.start, bounds.end)
  const found = [...meta.matchAll(TITLE_RE)].map((m) => m[2])
  if (found.length !== BASE_TITLES.length || found.some((t, index) => t !== BASE_TITLES[index])) return null
  if ((source.match(CONSTANT_RE) || []).length !== 1) return null
  if (!NAME_RE.test(meta) || !DESCRIPTION_RE.test(meta)) return null
  let next = meta.replace(TITLE_RE, (all, open, phase, close) => `${open}${phase}${close}`)
  next = next.replace(NAME_RE, (all, open, held, close) => `${open}${name}${close}`)
  next = next.replace(DESCRIPTION_RE, (all, open, text, close) => `${open}${description}${close}`)
  const constant = `const PHASE_TITLES = { ${BASE_TITLES.map((t) => `${t.toLowerCase()}: '${t}'`).join(', ')} }`
  return next + source.slice(bounds.end).replace(CONSTANT_RE, () => constant)
}

function launchPath(projectDirectory, issue, bytes) {
  const digest = crypto.createHash('sha256').update(bytes, 'utf8').digest('hex').slice(0, 12)
  return nodePath.join(projectDirectory, DIRECTORY, `issue-${issue}-${digest}.js`)
}

// Writes the file when absent (tmp + rename). Returns {path} (existing bytes equal, or just written) or {denied: <file name>}
// when a file of that name exists with other bytes (edited after it was written).
function ensureLaunchFile(projectDirectory, issue, bytes) {
  const file = launchPath(projectDirectory, issue, bytes)
  let held = null
  try { held = fs.readFileSync(file, 'utf8') } catch (error) { held = null }
  if (held !== null) return held === bytes ? { path: file } : { denied: nodePath.basename(file) }
  fs.mkdirSync(nodePath.dirname(file), { recursive: true })
  const temporary = `${file}.temporary-${process.pid}`
  fs.writeFileSync(temporary, bytes)
  fs.renameSync(temporary, file)
  return { path: file }
}

module.exports = { retitle, launchPath, ensureLaunchFile, DIRECTORY }
