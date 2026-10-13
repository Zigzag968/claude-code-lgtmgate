'use strict'

// The launch file of a run (#520): a copy of workflows/deliver-pipeline.js whose `meta` literal and `PHASE_TITLES` line
// carry the issue number (`#<N> Setup` ... `#<N> Review`), so the progress view of two runs is told apart by its titles.
// Written by hooks/workflow-args-expand.sh under <project>/.pipeline/launch/ (gitignored). Pure functions plus one atomic write.
//
// retitle(source, issue, title?) -> the expected bytes, or null when the source does not have the exact shape (then nothing is
// written and the launch keeps the plugin's own engine). Idempotent: retitle(retitle(x, n, t), n, t) === retitle(x, n, t).
// With a `title` (#545) the workflow name reads `deliver-pipeline #<N> <title>` and the description `#<N> <title>: <base>`; the
// phase titles keep carrying the number only. Without one the bytes are what #520 wrote.

const fs = require('fs')
const crypto = require('crypto')
const nodePath = require('path')

const BASE_TITLES = ['Setup', 'Diagnose', 'Plan', 'Dev', 'Review']
const PHASE_TITLE_CAP = 16 // scripts/guards.cjs checkPhaseTitles
const DIRECTORY = nodePath.join('.pipeline', 'launch')

const TITLE_RE = /(\{ title: ')(?:#\d+ )?([^']*)(')/g
const NAME_RE = /^(  name: ')deliver-pipeline(?: #(\d+)(?: ((?:[^'\\\n]|\\.)*))?)?(',)$/m
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

function retitle(source, issue, title) {
  if (typeof source !== 'string' || !Number.isInteger(issue) || issue < 1) return null
  const escaped = title === undefined ? '' : escapeTitle(title)
  if (escaped === null) return null
  const bounds = metaBounds(source)
  if (!bounds) return null
  const meta = source.slice(bounds.start, bounds.end)
  const found = [...meta.matchAll(TITLE_RE)].map((m) => m[2])
  if (found.length !== BASE_TITLES.length || found.some((t, index) => t !== BASE_TITLES[index])) return null
  if ((source.match(CONSTANT_RE) || []).length !== 1) return null
  if (!NAME_RE.test(meta) || !DESCRIPTION_RE.test(meta)) return null
  const titled = BASE_TITLES.map((t) => `#${issue} ${t}`)
  const worst = Math.max(...titled.map((t) => [...t].length), [...`#${issue} Review 99`].length)
  if (worst > PHASE_TITLE_CAP) return null
  let next = meta.replace(TITLE_RE, (all, open, phase, close) => `${open}#${issue} ${phase}${close}`)
  const name = NAME_RE.exec(next)
  const previous = name[2] === undefined ? '' : name[3] === undefined ? `#${name[2]} ` : `#${name[2]} ${name[3]}: `
  next = next.replace(NAME_RE, (all, open, number, held, close) => `${open}deliver-pipeline #${issue}${escaped === '' ? '' : ` ${escaped}`}${close}`)
  next = next.replace(DESCRIPTION_RE, (all, open, text, close) => {
    const base = previous !== '' && text.startsWith(previous) ? text.slice(previous.length) : text.replace(/^#\d+ /, '')
    return `${open}#${issue} ${escaped === '' ? '' : `${escaped}: `}${base}${close}`
  })
  const line = `const PHASE_TITLES = { setup: '#${issue} Setup', diagnose: '#${issue} Diagnose', plan: '#${issue} Plan', dev: '#${issue} Dev', review: '#${issue} Review' }`
  return next + source.slice(bounds.end).replace(CONSTANT_RE, () => line)
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

module.exports = { retitle, launchPath, ensureLaunchFile, DIRECTORY, PHASE_TITLE_CAP }
