'use strict'

// The launch file of a run (#520, #553, #580, #605): a copy of workflows/deliver-pipeline.js whose `meta` literal differs from
// the engine, written once per run by `scripts/runtime/launch-args.cjs --mode file` and launched by its `scriptPath`. The card in
// the conversation and the Background tasks pane label a `scriptPath` launch with the file name (Claude Code 2.1.317, measured,
// docs/consumer-reference.md, section Launch form), so the file name is the per-run label. Three more labels sit in `meta`:
//   meta.name         `#<N> - <issue name>`  run list, task-panel row (the file name is this text, sanitised)
//   meta.title        `#<N> - lgtmgate`      progress panel title
//   meta.description  `<issue name>`         progress panel description
// The issue name is the given title; without one it is the first line of the brief (a leading `Issue <n>:` / `#<n>:` is
// dropped), cut at 80 bytes in the name and at a word boundary with an ellipsis in the description. With neither, the name
// reads `#<N>` and the description `#<N>` (the runtime requires a non-empty description). The meta block declares no phases
// (#462): the progress view lists them in run order. The PR number is not shown.
// Shape: <project>/.pipeline/launch/<sha12>/<name>.js (gitignored). <sha12> = first 12 hex of the sha256 of the file bytes (the
// integrity check, verified by the PreToolUse hook), <name> = the copy's own meta.name, sanitised and cut at 80 bytes. The engine
// source holds one flag line, off; only `retitle` and `markGenerated` write it on, and the engine throws `engine-launch-form`
// while it is off, so a start that did not go through a generated copy stops before any agent call.
//
// retitle(source, issue, options?) -> the expected bytes, or null when the source does not have the exact shape (then nothing is
// written). options = { title, brief }, both optional. Computed from the inputs only, so retitle is idempotent and also
// normalizes a launch file of a previous shape (numbered run-time phase constants, no `title` line). Pure functions plus one atomic write.

const fs = require('fs')
const crypto = require('crypto')
const nodePath = require('path')
const { spawnSync } = require('child_process')

const BASE_TITLES = ['Setup', 'Diagnose', 'Plan', 'Dev', 'Review']
const NAME_BYTES = 80
const DESCRIPTION_CHARS = 120
const PANEL_WORD = 'lgtmgate'
const DIRECTORY = nodePath.join('.pipeline', 'launch')

const TITLE_RE = /\{ title: '/
const PHASES_RE = /^  phases:/m
const NAME_RE = /^(  name: ')((?:[^'\\\n]|\\.)*)(',)$/m
const DESCRIPTION_RE = /^(  description: ')(.*)(',)$/m
const META_TITLE_RE = /^  title: '(?:[^'\\\n]|\\.)*',\n/m
const META_TITLE_ANY_RE = /^  title:/m
const FLAG_RE = /^const LAUNCH_FILE_GENERATED = (?:false|true)$/gm
const ENGINE_MARKER_RE = /^const PHASE_TITLES = \{ setup: /m
const LABEL_BYTES = 80
const HOSTILE_RE = /[/\\:*?"<>|]/g
const BLANKING_RE = /[\p{Cc}\p{Zl}\p{Zp}]/gu
const INVISIBLE_RE = /[\p{Cf}\p{Cs}\p{Co}\p{Cn}\u{FE00}-\u{FE0F}\u{180B}-\u{180D}\u{180F}\u{E0100}-\u{E01EF}]/gu
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

// A run title of at most `maxBytes` UTF-8 bytes: control characters to spaces, whitespace collapsed, a longer text cut at a
// word boundary with an ellipsis (the ellipsis is 3 bytes, so the character limit shrinks until the bytes fit). '' if empty.
function cutTitle(text, maxBytes) {
  if (typeof text !== 'string') return ''
  const clean = text.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim()
  if (Buffer.byteLength(clean, 'utf8') <= maxBytes) return clean
  for (let limit = [...clean].length; limit >= 1; limit--) {
    const cut = cutWords(clean, limit)
    if (cut !== '' && cut !== '…' && Buffer.byteLength(cut, 'utf8') <= maxBytes) return cut
  }
  return ''
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
  if (TITLE_RE.test(meta) || PHASES_RE.test(meta)) return null
  if ((source.match(CONSTANT_RE) || []).length !== 1) return null
  if (!NAME_RE.test(meta) || !DESCRIPTION_RE.test(meta)) return null
  if (META_TITLE_ANY_RE.test(meta) && !META_TITLE_RE.test(meta)) return null
  let next = meta.replace(META_TITLE_RE, '')
  next = next.replace(NAME_RE, (all, open, held, close) => `${open}${name}${close}\n  title: '${panelTitle}',`)
  next = next.replace(DESCRIPTION_RE, (all, open, text, close) => `${open}${description}${close}`)
  const constant = `const PHASE_TITLES = { ${BASE_TITLES.map((t) => `${t.toLowerCase()}: '${t}'`).join(', ')} }`
  return markGenerated(next + source.slice(bounds.end).replace(CONSTANT_RE, () => constant))
}

// The flag line of the engine set on. A source with no flag line (an old engine copy) is returned unchanged; more than one
// flag line is ambiguous and gives null. Idempotent.
function markGenerated(source) {
  if (typeof source !== 'string') return null
  const found = source.match(FLAG_RE) || []
  if (found.length > 1) return null
  return found.length === 0 ? source : source.replace(FLAG_RE, () => 'const LAUNCH_FILE_GENERATED = true')
}

function sha12(bytes) {
  return crypto.createHash('sha256').update(bytes, 'utf8').digest('hex').slice(0, 12)
}

// The text of the `meta.name` literal of a copy of the engine, unescaped; null when there is none.
function metaName(bytes) {
  const bounds = typeof bytes === 'string' ? metaBounds(bytes) : null
  const found = bounds ? NAME_RE.exec(bytes.slice(bounds.start, bounds.end)) : null
  return found ? found[2].replace(/\\(.)/g, '$1') : null
}

// The file name of a launch file: its own meta.name made safe for every file system and for the eye. Path-hostile ASCII
// becomes `-`, controls and line separators a space, format, surrogate, private-use, unassigned and variation-selector
// characters vanish; whitespace collapses, the result is cut at 80 bytes (whole code points) and ends in `.js`. Null when the
// source has no meta name.
function labelFileName(bytes) {
  const held = metaName(bytes)
  if (held === null) return null
  const clean = (text) => text.replace(/\s+/g, ' ').trim().replace(/[. ]+$/, '')
  const name = held.replace(HOSTILE_RE, '-').replace(BLANKING_RE, ' ').replace(INVISIBLE_RE, '')
  const cut = clean(cutBytes(clean(name), LABEL_BYTES))
  return `${cut === '' ? 'launch' : cut}.js`
}

function launchPath(projectDirectory, bytes) {
  const label = labelFileName(bytes)
  return label === null ? null : nodePath.join(projectDirectory, DIRECTORY, sha12(bytes), label)
}

// `{digest, issue}` for a path of the generated shape `.pipeline/launch/<12 hex>/#<N>[ - <title>].js`, else null. String only.
function parseLaunchPath(path) {
  if (typeof path !== 'string') return null
  const base = /^#([0-9]+)(?: - .*)?\.js$/.exec(nodePath.basename(path))
  const digestDirectory = nodePath.dirname(path)
  const digest = nodePath.basename(digestDirectory)
  const launchDirectory = nodePath.dirname(digestDirectory)
  if (!base || !/^[0-9a-f]{12}$/.test(digest) || nodePath.basename(launchDirectory) !== 'launch') return null
  if (nodePath.basename(nodePath.dirname(launchDirectory)) !== '.pipeline') return null
  const issue = Number(base[1])
  return Number.isSafeInteger(issue) && issue >= 1 ? { digest, issue } : null
}

// 'ignored' (git check-ignore exit 0), 'not-ignored' (exit 1), 'git-failed' (anything else: no git, not a repository, 128).
function ignoredState(projectDirectory, relative) {
  const result = spawnSync('git', ['-C', projectDirectory, 'check-ignore', '-q', '--', relative], { stdio: 'ignore' })
  if (result.status === 0) return 'ignored'
  return result.status === 1 ? 'not-ignored' : 'git-failed'
}

// Writes the file when absent (tmp + rename). Returns {path} (existing bytes equal, or just written) or {denied: <file name>}
// when a file of that name exists with other bytes (edited after it was written).
function ensureLaunchFile(projectDirectory, bytes) {
  const file = launchPath(projectDirectory, bytes)
  if (file === null) throw new Error('the launch copy has no meta name')
  let held = null
  try { held = fs.readFileSync(file) } catch (error) { held = null }
  if (held !== null) return held.equals(Buffer.from(bytes, 'utf8')) ? { path: file } : { denied: nodePath.basename(file) }
  fs.mkdirSync(nodePath.dirname(file), { recursive: true })
  const temporary = `${file}.temporary-${process.pid}`
  fs.writeFileSync(temporary, bytes)
  fs.renameSync(temporary, file)
  return { path: file }
}

module.exports = { retitle, markGenerated, cutTitle, metaName, labelFileName, launchPath, parseLaunchPath, ignoredState, ensureLaunchFile, sha12, ENGINE_MARKER_RE, DIRECTORY }
