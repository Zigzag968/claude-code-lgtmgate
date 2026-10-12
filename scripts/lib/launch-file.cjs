'use strict'

// The launch file of a run (#520): a copy of workflows/deliver-pipeline.js whose `meta` literal and `PHASE_TITLES` line
// carry the issue number (`#<N> Setup` ... `#<N> Review`), so the progress view of two runs is told apart by its titles.
// Written by hooks/workflow-args-expand.sh under <project>/.pipeline/launch/ (gitignored). Pure functions plus one atomic write.
//
// retitle(source, issue) -> the expected bytes, or null when the source does not have the exact shape (then nothing is written
// and the launch keeps the plugin's own engine). Idempotent: retitle(retitle(x, n), n) === retitle(x, n).

const fs = require('fs')
const crypto = require('crypto')
const nodePath = require('path')

const BASE_TITLES = ['Setup', 'Diagnose', 'Plan', 'Dev', 'Review']
const PHASE_TITLE_CAP = 16 // scripts/guards.cjs checkPhaseTitles
const DIRECTORY = nodePath.join('.pipeline', 'launch')

const TITLE_RE = /(\{ title: ')(?:#\d+ )?([^']*)(')/g
const NAME_RE = /^(  name: ')deliver-pipeline(?: #\d+)?(',)$/m
const DESCRIPTION_RE = /^(  description: ')(?:#\d+ )?(.*)(',)$/m
const CONSTANT_RE = /^const PHASE_TITLES = \{ setup: '(?:#\d+ )?Setup', diagnose: '(?:#\d+ )?Diagnose', plan: '(?:#\d+ )?Plan', dev: '(?:#\d+ )?Dev', review: '(?:#\d+ )?Review' \}$/gm

function metaBounds(source) {
  const start = source.indexOf('export const meta = {\n')
  if (start !== 0) return null
  const end = source.indexOf('\n}\n', start)
  return end < 0 ? null : { start, end: end + 2 }
}

function retitle(source, issue) {
  if (typeof source !== 'string' || !Number.isInteger(issue) || issue < 1) return null
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
  let next = meta.replace(TITLE_RE, (all, open, title, close) => `${open}#${issue} ${title}${close}`)
  next = next.replace(NAME_RE, (all, open, close) => `${open}deliver-pipeline #${issue}${close}`)
  next = next.replace(DESCRIPTION_RE, (all, open, text, close) => `${open}#${issue} ${text}${close}`)
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
