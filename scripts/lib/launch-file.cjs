'use strict'

// The launch file of a run (#520, #553, #580): a copy of workflows/deliver-pipeline.js whose `meta` literal differs from the
// engine so the run list and the progress panel tell two runs apart. Three labels, one per `meta` field (read from the Claude
// Code 2.1.303 bundle and the SDK Workflow reference, confirmed live by the human gate of #580):
//   meta.name         `#<N> - <issue name>`  run list, task-panel row
//   meta.title        `#<N> - lgtmgate`      progress panel title
//   meta.description  `<issue name>`         progress panel description
// The issue name is the given title; without one it is the first line of the brief (a leading `Issue <n>:` / `#<n>:` is
// dropped), cut at 80 bytes in the name and at a word boundary with an ellipsis in the description. With neither, the name
// reads `#<N>` and the description `#<N>` (the runtime requires a non-empty description). Phase titles stay plain (`Setup` ...
// `Review`). The PR number is not shown.
// Written by hooks/workflow-args-expand.sh under <project>/.pipeline/launch/ (gitignored). Pure functions plus one atomic write.
//
// retitle(source, issue, options?) -> the expected bytes, or null when the source does not have the exact shape (then nothing is
// written and the launch keeps the plugin's own engine). options = { title, brief }, both optional. Computed from the inputs
// only, so retitle is idempotent and also normalizes a launch file of a previous shape (numbered phase titles, no `title` line).

const fs = require('fs')
const crypto = require('crypto')
const nodePath = require('path')

const BASE_TITLES = ['Setup', 'Diagnose', 'Plan', 'Dev', 'Review']
const NAME_BYTES = 80
const DESCRIPTION_CHARS = 120
const PANEL_WORD = 'lgtmgate'
const DIRECTORY = nodePath.join('.pipeline', 'launch')

const TITLE_RE = /(\{ title: ')(?:#\d+ )?([^']*)(')/g
const NAME_RE = /^(  name: ')((?:[^'\\\n]|\\.)*)(',)$/m
const DESCRIPTION_RE = /^(  description: ')(.*)(',)$/m
const META_TITLE_RE = /^  title: '(?:[^'\\\n]|\\.)*',\n/m
const META_TITLE_ANY_RE = /^  title:/m
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

const PREFIX_RE = /^(?:issue\s+#?\d+|#\d+)\s*[:.–—-]\s*/i

// First line of a brief, control characters to spaces, trimmed, one leading `Issue <n>:` / `#<n>:` prefix dropped (the
// description adds `#<N>` itself). '' when nothing is left.
function firstLine(brief) {
  if (typeof brief !== 'string') return ''
  return brief.split('\n')[0].replace(/[\u0000-\u001f\u007f]/g, ' ').trim().replace(PREFIX_RE, '').trim()
}

// At most `limit` code points; a longer text is cut back to the last whole word and ends with an ellipsis.
function cutWords(text, limit) {
  const chars = [...text]
  if (chars.length <= limit) return text
  const head = chars.slice(0, limit - 1).join('')
  const space = head.search(/\s\S*$/)
  const cut = space > 0 ? head.slice(0, space) : head
  return `${cut.replace(/[\s,;:.–—-]+$/, '')}…`
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
  let issueName
  if (given.title !== undefined) {
    issueName = escapeTitle(given.title)
    if (issueName === null) return null
  } else {
    issueName = escapeTitle(cutBytes(line, NAME_BYTES)) || ''
  }
  const name = issueName === '' ? `#${issue}` : `#${issue} - ${issueName}`
  const panelTitle = `#${issue} - ${PANEL_WORD}`
  const description = given.title !== undefined ? issueName : escapeTitle(cutWords(line, DESCRIPTION_CHARS)) || `#${issue}`
  const bounds = metaBounds(source)
  if (!bounds) return null
  const meta = source.slice(bounds.start, bounds.end)
  const found = [...meta.matchAll(TITLE_RE)].map((m) => m[2])
  if (found.length !== BASE_TITLES.length || found.some((t, index) => t !== BASE_TITLES[index])) return null
  if ((source.match(CONSTANT_RE) || []).length !== 1) return null
  if (!NAME_RE.test(meta) || !DESCRIPTION_RE.test(meta)) return null
  if (META_TITLE_ANY_RE.test(meta) && !META_TITLE_RE.test(meta)) return null
  let next = meta.replace(TITLE_RE, (all, open, phase, close) => `${open}${phase}${close}`)
  next = next.replace(META_TITLE_RE, '')
  next = next.replace(NAME_RE, (all, open, held, close) => `${open}${name}${close}\n  title: '${panelTitle}',`)
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
