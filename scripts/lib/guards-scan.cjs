'use strict'
// Pure text scanners of scripts/guards.cjs: no I/O, no globals, no output. guards.cjs requires them
// so that it stays under the max-lines ceiling; the checks, their messages and their order stay there.

// ---- JS scanning helpers -------------------------------------------------------------------
// Blank out every character of the given range set, keeping newlines, so line numbers stay stable.
function isCommentLine(line) { return /^\s*\/\//.test(line) }
const blankNonNl = (t) => t.replace(/[^\n]/g, ' ')
// Blank `/* ... */` block comments (an unterminated one runs to EOF); offsets and newlines kept.
const noBlock = (source) => source.replace(/\/\*[\s\S]*?(?:\*\/|$)/g, blankNonNl)
// Also blank whole-line `//` comments.
function stripComments(source) {
  return noBlock(source).split('\n').map((l) => (isCommentLine(l) ? blankNonNl(l) : l)).join('\n')
}

// Returns [start, end) offsets of the body `{...}` of `function callAgent`, or null.
function callAgentBody(source) {
  const m = /(?:async\s+)?function\s+callAgent\s*\(/.exec(source)
  if (!m) return null
  let index = m.index + m[0].length
  let depth = 1
  // walk the parameter list (may contain defaults, no braces expected)
  while (index < source.length && depth > 0) {
    const c = source[index]
    if (c === '(') depth++
    else if (c === ')') depth--
    index++
  }
  while (index < source.length && source[index] !== '{') index++
  const start = index
  let d = 0
  while (index < source.length) {
    const c = source[index]
    const n = source[index + 1]
    if (c === '/' && n === '/') { while (index < source.length && source[index] !== '\n') index++; continue }
    if (c === '/' && n === '*') { index = source.indexOf('*/', index + 2); if (index < 0) return null; index += 2; continue }
    if (c === '\'' || c === '"') {
      const q = c; index++
      while (index < source.length && source[index] !== q) { if (source[index] === '\\') index++; index++ }
      index++; continue
    }
    if (c === '`') { index = skipTemplate(source, index + 1); continue }
    if (c === '{') d++
    else if (c === '}') { d--; if (d === 0) return [start, index + 1] }
    index++
  }
  return null
}
function skipTemplate(source, index) {
  while (index < source.length && source[index] !== '`') {
    if (source[index] === '\\') { index += 2; continue }
    if (source[index] === '$' && source[index + 1] === '{') {
      let d = 1; index += 2
      while (index < source.length && d > 0) {
        if (source[index] === '`') { index = skipTemplate(source, index + 1); continue }
        if (source[index] === '{') d++
        else if (source[index] === '}') d--
        index++
      }
      continue
    }
    index++
  }
  return index + 1
}

function countAgentCalls(rawSource) {
  const source = stripComments(rawSource)
  const body = callAgentBody(source)
  const re = /await\s+agent\s*\(/g
  let n = 0
  let m
  while ((m = re.exec(source))) {
    if (!(body && m.index >= body[0] && m.index < body[1])) n++
  }
  return n
}

function countSimulateSeams(rawSource) {
  // One seam = one distinct key: `simulate.<key>` (key != probes) or `simulate.probes.<key>` /
  // `simulate.probes['key']` / `simulate?.probes?.<key>`. A dynamic `simulate.probes[role]` is not a key.
  const keys = new Set()
  for (const line of stripComments(rawSource).split('\n')) {
    const re = /simulate\??\.([A-Za-z_][A-Za-z0-9_]*)(?:\??\.([A-Za-z_][A-Za-z0-9_]*)|\??\.?\[\s*(['"])([A-Za-z_][A-Za-z0-9_]*)\3\s*\])?/g
    let m
    while ((m = re.exec(line))) {
      if (m[1] !== 'probes') keys.add(m[1])
      else if (m[2] || m[4]) keys.add('probes.' + (m[2] || m[4]))
    }
  }
  return keys.size
}

const REGEX_APPLICATIONS = /\.match\(|\.test\(|\.exec\(|\.matchAll\(|\.replace\(\/|\.split\(\/|new RegExp\(/g
function countRegexApps(rawSource) {
  let inParser = false
  let n = 0
  // marker lines are whole-line `//` comments: match them before those are blanked
  for (const line of noBlock(rawSource).split('\n')) {
    if (/^\s*\/\/\s*guards:parser-begin\b/.test(line)) { inParser = true; continue }
    if (/^\s*\/\/\s*guards:parser-end\b/.test(line)) { inParser = false; continue }
    if (inParser || isCommentLine(line)) continue
    const m = line.match(REGEX_APPLICATIONS)
    if (m) n += m.length
  }
  return n
}

// Problems with the parser markers (empty when balanced).
function parserMarkerErrors(rawSource) {
  const errs = []
  let openAt = 0
  const lines = noBlock(rawSource).split('\n')
  for (let index = 0; index < lines.length; index++) {
    if (/^\s*\/\/\s*guards:parser-begin\b/.test(lines[index])) {
      if (openAt) errs.push(`nested guards:parser-begin at line ${index + 1} (already open since line ${openAt})`)
      else openAt = index + 1
    } else if (/^\s*\/\/\s*guards:parser-end\b/.test(lines[index])) {
      if (!openAt) errs.push(`guards:parser-end at line ${index + 1} has no matching guards:parser-begin`)
      else openAt = 0
    }
  }
  if (openAt) errs.push(`unclosed guards:parser-begin at line ${openAt} (no guards:parser-end)`)
  return errs
}

// Concatenated text of every `run:` step (single-line value or `|`/`>` block body), YAML comments
// removed (whole-line `#` and trailing ` #...`).
function ymlRunText(yml) {
  const lines = yml.split('\n').filter((l) => !/^\s*#/.test(l)).map((l) => l.replace(/\s+#.*$/, ''))
  const parts = []
  for (let index = 0; index < lines.length; index++) {
    const m = /^(\s*(?:-\s+)?)run:\s*(.*)$/.exec(lines[index])
    if (!m) continue
    const keyIndent = m[1].length
    if (/^[|>][+-]?\d*$/.test(m[2].trim())) {
      for (index++; index < lines.length; index++) {
        const l = lines[index]
        if (l.trim() !== '' && l.length - l.trimStart().length <= keyIndent) { index--; break }
        parts.push(l)
      }
    } else parts.push(m[2])
  }
  return parts.join('\n')
}

// Run text of one job: lines from its 2-space-indent key up to the next 2-space-indent key (or EOF).
function jobRunText(yml, job) {
  const lines = yml.split('\n')
  const start = lines.findIndex((l) => new RegExp(`^  ${job}:\\s*$`).test(l))
  if (start < 0) return ''
  let end = lines.length
  for (let index = start + 1; index < lines.length; index++) {
    if (/^  [A-Za-z0-9_-]+:\s*$/.test(lines[index])) { end = index; break }
  }
  return ymlRunText(lines.slice(start, end).join('\n'))
}

// semver 2.0.0 precedence (section 11): build metadata ignored, a prerelease sorts below its release,
// numeric identifiers compare as numbers and sort below alphanumeric ones, more identifiers win a tie.
const SEMVER = /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/

function parseSemver(v) {
  const m = SEMVER.exec(String(v).trim())
  return m ? { str: String(v).trim(), core: [Number(m[1]), Number(m[2]), Number(m[3])], pre: m[4] ? m[4].split('.') : [] } : null
}

function cmp(a, b) {
  for (let index = 0; index < 3; index++) if (a.core[index] !== b.core[index]) return a.core[index] - b.core[index]
  if (!a.pre.length || !b.pre.length) return b.pre.length - a.pre.length
  for (let index = 0; index < Math.min(a.pre.length, b.pre.length); index++) {
    const x = a.pre[index], y = b.pre[index], xn = /^\d+$/.test(x), yn = /^\d+$/.test(y)
    if (xn && yn) { if (Number(x) !== Number(y)) return Number(x) - Number(y) } else if (xn !== yn) return xn ? -1 : 1
    else if (x !== y) return x < y ? -1 : 1
  }
  return a.pre.length - b.pre.length
}

// The lines of a Markdown text outside fenced code blocks, with inline code spans removed.
function proseLines(txt) {
  const lines = []
  let fence = null
  for (const raw of txt.split('\n')) {
    const l = raw.replace(/\r$/, '')
    const open = /^ {0,3}(`{3,}|~{3,})/.exec(l)
    if (fence) {
      const close = /^ {0,3}(`{3,}|~{3,})[ \t]*$/.exec(l)
      if (close && close[1][0] === fence[0] && close[1].length >= fence.length) fence = null
      continue
    }
    if (open) { fence = open[1]; continue }
    lines.push(l.replace(/(`+).*?\1/g, ''))
  }
  return lines
}

// Import references to `name` (`@name` at a line start or after whitespace) in prose lines.
const escapeRegExp = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

const importReferences = (lines, name) => lines.reduce((n, l) =>
  n + (l.match(new RegExp(`(?:^|\\s)@${escapeRegExp(name)}(?![\\w./-])`, 'g')) || []).length, 0)

// The registry is the top-level `const STATUS = Object.freeze({ ... })` closed by a `})` at column 0;
// agentDeathRouting()'s indented role -> status table is not it. Keys are the quoted entry names.
const STATUS_SECTION = '## 5. Handle the returned status'

function statusRegistryKeys(source) {
  const m = /^const STATUS = Object\.freeze\(\{\n([\s\S]*?)^\}\)/m.exec(source)
  return m ? [...m[1].matchAll(/^\s*'([^']+)':/gm)].map((x) => x[1]) : null
}

// Body rows of the first Markdown table after the §5 heading, each as its first cell and the
// backticked statuses in it (`a` / `b` groups several). Null when the heading or the table is absent.
function statusTableRows(md) {
  const lines = md.split('\n')
  const start = lines.findIndex((l) => l.trim() === STATUS_SECTION)
  if (start < 0) return null
  const rows = []
  for (let index = start + 1; index < lines.length; index++) {
    if (/^##/.test(lines[index])) break
    if (!lines[index].startsWith('|')) { if (rows.length) break; continue }
    rows.push(lines[index])
  }
  if (rows.length < 2) return null
  return rows.slice(2).map((l) => {
    const cell = l.split('|')[1].trim()
    return { cell, statuses: [...cell.matchAll(/`([^`]+)`/g)].map((x) => x[1]) }
  })
}

function declaredPhaseTitles(source) {
  const m = /^export const meta = \{\n([\s\S]*?)^\}/m.exec(source)
  if (!m) return null
  const at = m[1].search(/\bphases:\s*\[/)
  if (at < 0) return null
  const titles = [...m[1].slice(at).matchAll(/\btitle:\s*(['"`])((?:(?!\1).)*)\1/g)].map((x) => x[2])
  return titles.length ? titles : null
}

module.exports = {
  isCommentLine,
  blankNonNl,
  noBlock,
  stripComments,
  callAgentBody,
  skipTemplate,
  countAgentCalls,
  countSimulateSeams,
  REGEX_APPLICATIONS,
  countRegexApps,
  parserMarkerErrors,
  ymlRunText,
  jobRunText,
  SEMVER,
  parseSemver,
  cmp,
  proseLines,
  escapeRegExp,
  importReferences,
  STATUS_SECTION,
  statusRegistryKeys,
  statusTableRows,
  declaredPhaseTitles,
}
