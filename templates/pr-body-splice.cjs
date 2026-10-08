#!/usr/bin/env node
'use strict'

// pr-body-splice: the PR-body splice/guard primitives of the engine as a CLI (E2.6a, #85).
//
// The block between the two `prBodySplice` markers below is a BYTE-IDENTICAL copy of the same block in
// workflows/deliver-pipeline.js (the engine copy stays: simulate previews and T87b/T113 probes use it).
// tests/templates/test-probe-run.sh checks the parity. Do not edit the block here without editing the engine.
//
// CLI (used by templates/pr-write.sh, op body-splice):
//   node pr-body-splice.cjs splice <decision-log|acceptance> <preFile> <textFile> <outFile>
//       exit 0 = spliced and written to outFile; 3 = acceptance markers absent / empty checklist
//       (NEVER appends); any other non-zero = failure. One trailing "\n" of the text file is stripped.
//   node pr-body-splice.cjs tick <preFile> <textFile> <outFile> <tickCsv> <keepCsv>
//       the acceptance block of preFile replaced by the rendered checklist in textFile with each box set by its
//       `<!-- ac:N -->` id (#183): ids of tickCsv `[x]`, ids of keepCsv keep the state preFile has, the others open.
//       Same exits as `splice acceptance` (3 = markers absent / empty checklist).
//   node pr-body-splice.cjs tick-ids <preFile> <outFile> <idsCsv>
//       (#257) only the boxes of idsCsv set `[x]` in the acceptance block of preFile, every other byte kept (no rendered text
//       needed). Exits: 3 = markers absent, 5 = an id has no box, 6 = an id is a `[human-gate]` box, 2 = bad ids.
//   node pr-body-splice.cjs checked <bodyFile|->
//       prints the ids of the boxes ticked in the acceptance block (comma-separated, ascending; empty when none or no
//       block); `-` reads the body from stdin. Exit 0.
//   node pr-body-splice.cjs entries <bodyFile|->
//       prints the round lines (`- round ...`, trimmed) of the real decision-log block as ONE JSON array line; [] with no
//       block; `-` reads the body from stdin. Exit 0.
//   node pr-body-splice.cjs guard <preLen> <postFile>
//       exit 0 = bodyWriteGuardOk (>= 90 % of the pre length and both acceptance markers), 1 = not ok.
// No network, no regex outside the block.

const fs = require('fs')

// --- prBodySplice:start --- (pure & self-contained: templates/pr-body-splice.cjs carries a byte-identical copy, parity-tested)
const DECISION_LOG_START = '<!-- decision-log:start -->'
const DECISION_LOG_END = '<!-- decision-log:end -->'
// Line-anchored (column 0 only) so an INDENTED/fenced illustrative copy of the markers — e.g.
// the example inside "## What this ships" — never matches; only the real, unindented,
// workflow-owned block does. Selects the LAST such pair as a second guard, since the real
// block is always appended/kept at the end of the body (observed in review: an
// un-anchored indexOf() matching the fenced example corrupted it, leaving the real
// trailing block empty forever).
const DECISION_LOG_START_RE = /^<!-- decision-log:start -->[ \t]*$/gm
const DECISION_LOG_END_RE = /^<!-- decision-log:end -->[ \t]*$/gm
// Composes the workflow-owned decision-log block from its entries. Pure.
function composeDecisionLogBlock(entries) {
  return `${DECISION_LOG_START}\n## Decision log\n${entries.join('\n')}\n${DECISION_LOG_END}`
}

// The real block of `src` as { s, e, eLen } (the block is src.slice(s, e + eLen)), null when there is none. s: the LAST
// column-0 start marker. e: the LAST column-0 end marker when one follows it; else the first end marker after s that is
// alone on its line, INDENTED (a block whose end marker lost its column: the column-0 reading found no end and appended a
// second block on every run, lgtmgate#164). A copy of the markers inside a fenced/indented example never starts a block
// (column 0 only), so the T44 shape is untouched. String operations for the fallback, no new regex.
function decisionLogSpan(src) {
  let s = -1
  let m
  DECISION_LOG_START_RE.lastIndex = 0
  while ((m = DECISION_LOG_START_RE.exec(src))) s = m.index
  if (s === -1) return null
  let e = -1
  let eLen = DECISION_LOG_END.length
  DECISION_LOG_END_RE.lastIndex = 0
  while ((m = DECISION_LOG_END_RE.exec(src))) { e = m.index; eLen = m[0].length }
  if (e > s) return { s, e, eLen }
  for (let at = src.indexOf(DECISION_LOG_END, s); at !== -1; at = src.indexOf(DECISION_LOG_END, at + 1)) {
    const lineStart = src.lastIndexOf('\n', at - 1) + 1
    if (lineStart > s && src.slice(lineStart, at).trim() === '') return { s, e: at, eLen: DECISION_LOG_END.length }
  }
  return null
}
// Every block of `src`, in body order, as { s, e, eLen } (the last one is the real block, see decisionLogSpan): a legacy body
// can hold several (lgtmgate#164, PR #146: three, each with an indented end marker). An earlier block runs from a column-0
// start marker to the first end marker alone on its line (column 0 or indented) before the next start marker; a start with no
// such end is not a block and is left alone. String operations only.
function decisionLogSpans(src) {
  const last = decisionLogSpan(src)
  if (last === null) return []
  const starts = []
  for (let at = src.indexOf(DECISION_LOG_START); at !== -1 && at < last.s; at = src.indexOf(DECISION_LOG_START, at + 1)) {
    const nl = src.indexOf('\n', at)
    if ((at === 0 || src[at - 1] === '\n') && src.slice(at + DECISION_LOG_START.length, nl === -1 ? src.length : nl).trim() === '') starts.push(at)
  }
  const spans = []
  starts.forEach((s, k) => {
    const bound = k + 1 < starts.length ? starts[k + 1] : last.s
    for (let at = src.indexOf(DECISION_LOG_END, s); at !== -1 && at < bound; at = src.indexOf(DECISION_LOG_END, at + 1)) {
      const lineStart = src.lastIndexOf('\n', at - 1) + 1
      const nl = src.indexOf('\n', at)
      const lineEnd = nl === -1 ? src.length : nl
      if (lineStart > s && src.slice(lineStart, at).trim() === '' && src.slice(at + DECISION_LOG_END.length, lineEnd).trim() === '') {
        spans.push({ s, e: at, eLen: lineEnd - at })
        break
      }
    }
  })
  return [...spans, last]
}
// The round lines (`- round ...`, trimmed) the blocks of `body` hold, those of every block in body order; [] when there is no
// block. Pure.
function decisionLogEntries(body) {
  const src = String(body ?? '')
  const out = []
  for (const span of decisionLogSpans(src)) {
    for (const l of src.slice(span.s + DECISION_LOG_START.length, span.e).split('\n')) if (l.trim().startsWith('- round ')) out.push(l.trim())
  }
  return out
}

// Idempotent splice of a pre-composed decision-log block into a body. Replaces the real block in place and removes every
// earlier block, line for line (their rounds are carried by the caller, from decisionLogEntries): the body ends with ONE pair,
// the text outside the blocks untouched and in its order; appends at the end when the markers are absent (legacy/resumed
// PRs). Pure — extracted from upsertDecisionLog (issue #87) so the SAME splice algorithm can be embedded (via .toString())
// into the single deterministic shell chain recordDecision runs, instead of being hand-duplicated there.
function spliceDecisionLogBlock(body, block) {
  const src = String(body ?? '')
  const spans = decisionLogSpans(src)
  if (spans.length === 0) return (src.endsWith('\n') ? src : src + '\n') + '\n' + block + '\n'
  let out = src
  for (let i = spans.length - 1; i >= 0; i--) {
    const { s, e, eLen } = spans[i]
    const to = e + eLen
    out = i === spans.length - 1 ? out.slice(0, s) + block + out.slice(to) : out.slice(0, s) + out.slice(out[to] === '\n' ? to + 1 : to)
  }
  return out
}

// Idempotent upsert of the workflow-owned decision-log block. Thin wrapper — external behavior
// unchanged (issue #87 step 1: composition/splice split into pure pieces below).
function upsertDecisionLog(body, entries) {
  return spliceDecisionLogBlock(body, composeDecisionLogBlock(entries))
}

// Acceptance-block splice (issue #97) — same line-anchored-marker idiom as the decision log
// above, but FAIL-CLOSED rather than append-on-absent: the decision log is workflow-owned
// (creating it on a legacy/resumed PR is legitimate), the acceptance block is NICK-owned and
// MUST already exist (he copies it verbatim from Sam's checklist at PR-open time per
// pr-acceptance.md) — a missing pair means something upstream is already broken, and silently
// appending a second acceptance block would corrupt the gate block-merge-unchecked.sh reads.
// Selects the LAST marker pair OUTSIDE a fenced code block (#183): a plan artifact or a PR body (this very file's own
// doc comments included) can hold an illustrative copy of the marker pair, before or after the real block, and such a
// copy is always fenced.
const ACCEPTANCE_START = '<!-- acceptance:start -->'
const ACCEPTANCE_END = '<!-- acceptance:end -->'
// Pure. Replaces the acceptance-block CONTENTS (between the LAST unfenced marker pair) with `checklist`
// (the verbatim `- [ ] ...` lines Sam returns for an amendment round), joined with the line break the body uses.
// Returns null — NEVER appends — when `checklist` is empty/blank or either marker is missing from `body`.
function spliceAcceptanceBlock(body, checklist) {
  const list = String(checklist ?? '').trim()
  if (!list) return null
  const src = String(body ?? '')
  const span = acceptanceSpan(src)
  if (span === null) return null
  return src.slice(0, span.from) + span.eol + list.split('\r\n').join('\n').split('\n').join(span.eol) + span.eol + src.slice(span.to)
}
// The fence a line leaves open after `fence` (the fence open before it, '' for none): a line opening with 3+ backticks or
// tildes (up to 3 spaces of indent, no backtick in the info string of a backtick fence) opens one, a line closing it
// with the same character, at least as long, closes it. String operations only.
function fenceAfter(line, fence) {
  const t = line.trimStart()
  const c = t[0]
  let run = 0
  if ((c === '`' || c === '~') && line.length - t.length <= 3) while (t[run] === c) run += 1
  if (fence !== '') return run >= fence.length && c === fence[0] && t.slice(run).trim() === '' ? '' : fence
  return run >= 3 && !(c === '`' && t.slice(run).includes('`')) ? c.repeat(run) : ''
}
// The contents of the acceptance block of `src`, as { from, to, eol } (`from`: just after the start marker line, before its
// line break; `to`: the start of the end marker line; `eol`: the line break the body puts after the start marker, "\r\n"
// or "\n"): the LAST marker pair outside a fenced code block (see fenceAfter), null when a marker is missing or the end
// does not follow the start. String operations only.
function acceptanceSpan(src) {
  let s = -1
  let sEnd = -1
  let e = -1
  let fence = ''
  let pos = 0
  for (const raw of src.split('\n')) {
    const line = raw.endsWith('\r') ? raw.slice(0, -1) : raw
    const next = fenceAfter(line, fence)
    if (fence === '' && next === '') {
      let end = line.length
      while (end > 0 && (line[end - 1] === ' ' || line[end - 1] === '\t')) end -= 1
      const marker = line.slice(0, end)
      if (marker === ACCEPTANCE_START) { s = pos; sEnd = pos + line.length } else if (marker === ACCEPTANCE_END) e = pos
    }
    fence = next
    pos += raw.length + 1
  }
  if (s === -1 || e === -1 || e <= s) return null
  return { from: sEnd, to: e, eol: src.startsWith('\r\n', sEnd) ? '\r\n' : '\n' }
}
// The lines of the acceptance block text `text` (what acceptanceSpan delimits: it opens and closes with a line break):
// { checkedById: Map id -> ticked, for each `- [ ]` / `- [x]` line carrying a well-formed `<!-- ac:N -->` comment (an id
// box, the one kind of line the engine renders), foreign: every other line of the block, verbatim and in order (a box
// without an id, an `exception:` line, prose, a blank line, a fenced example and what it holds) }. String operations only.
function acceptanceBoxes(text) {
  const checkedById = new Map()
  const foreign = []
  const all = String(text).split('\n')
  if (all.length > 0 && all[0].split('\r').join('') === '') all.shift()
  if (all.length > 0 && all[all.length - 1] === '') all.pop()
  let fence = ''
  for (const raw of all) {
    const l = raw.endsWith('\r') ? raw.slice(0, -1) : raw
    const next = fenceAfter(l, fence)
    const fenced = fence !== '' || next !== ''
    fence = next
    const t = l.trimStart()
    const head = t.slice(0, 5)
    const ticked = head === '- [x]' || head === '- [X]'
    if (!fenced && (ticked || head === '- [ ]') && (t.length === 5 || t[5] === ' ' || t[5] === '\t')) {
      const rest = t.slice(5).trimStart()
      if (rest.startsWith('<!-- ac:')) {
        const end = rest.indexOf('-->')
        const digits = end > 0 ? rest.slice(8, end).trim() : ''
        if (digits !== '' && [...digits].every((d) => d >= '0' && d <= '9')) { checkedById.set(Number(digits), ticked); continue }
      }
    }
    foreign.push(l)
  }
  return { checkedById, foreign }
}
// The ids of the boxes of the acceptance block of `body` that are ticked, ascending (the LAST unfenced marker pair);
// [] when there is no block. Pure.
function checkedAcceptanceIds(body) {
  const src = String(body ?? '')
  const span = acceptanceSpan(src)
  if (span === null) return []
  const { checkedById } = acceptanceBoxes(src.slice(span.from, span.to))
  return [...checkedById].filter(([, ticked]) => ticked).map(([id]) => id).sort((a, b) => a - b)
}
// Ticks the acceptance block by id (#183). Pure. `rendered` is the canonical block (every box open, `<!-- ac:N -->` ids);
// the id boxes of the block of `body` (the LAST unfenced marker pair) are replaced by it with each box set by its id: `[x]`
// for an id of `tickIds`; an id of `keepIds` (a human gate, or a box nobody returned that a person ticked) keeps the state
// the body has, so a person's tick survives and the engine never writes a gate `[x]`; any other id is open, so a stale `[x]`
// is reopened. Every other line of the block (see acceptanceBoxes: the line a project's rule has Nick add, an `exception:`
// line, prose, a blank line) is kept as it stands, in its order, after the rendered lines, and never ticked. The line breaks
// are the body's. null, like spliceAcceptanceBlock, when `rendered` is blank or a marker is missing. String operations only.
function tickAcceptanceBlock(body, rendered, tickIds, keepIds) {
  const list = String(rendered ?? '').trim()
  const src = String(body ?? '')
  const span = acceptanceSpan(src)
  if (!list || span === null) return null
  const idOf = (rest) => {
    if (!rest.startsWith('<!-- ac:')) return null
    const end = rest.indexOf('-->')
    const digits = end > 0 ? rest.slice(8, end).trim() : ''
    return digits !== '' && [...digits].every((c) => c >= '0' && c <= '9') ? Number(digits) : null
  }
  const { checkedById, foreign } = acceptanceBoxes(src.slice(span.from, span.to))
  const tick = Array.isArray(tickIds) ? tickIds : []
  const keep = Array.isArray(keepIds) ? keepIds : []
  const lines = list.split('\r\n').join('\n').split('\n').map((line) => {
    if (!line.startsWith('- [ ] ')) return line
    const id = idOf(line.slice(6))
    if (id === null) return line
    const checked = keep.includes(id) ? checkedById.get(id) === true : tick.includes(id)
    return checked ? '- [x] ' + line.slice(6) : line
  })
  return src.slice(0, span.from) + span.eol + [...lines, ...foreign].join(span.eol) + span.eol + src.slice(span.to)
}

// Post-write byte/marker guard (issue #87) — protects a PR body read-modify-write against a
// lossy read (e.g. a model summarizing a large command's stdout in its own chat reply instead
// of relaying it verbatim). Pure, synchronous: newBody must be at least 90% of the pre-write
// byte length AND still carry both acceptance-block markers. Scoped to the acceptance block
// (the actual content lost in the #87 incident), not the decision-log markers the workflow
// itself owns and always regenerates correctly.
function bodyWriteGuardOk(preLen, newBody) {
  const b = String(newBody ?? '')
  if (!(b.length >= preLen * 0.9)) return false
  if (!b.includes('<!-- acceptance:start -->')) return false
  if (!b.includes('<!-- acceptance:end -->')) return false
  return true
}
// --- prBodySplice:end ---

function stripOneTrailingNewline(s) {
  return s.endsWith('\n') ? s.slice(0, -1) : s
}

// Ticks the boxes of `ids` in the acceptance block of `body` and nothing else (#257). Pure, outside the parity block. The
// block is the one of the LAST unfenced marker pair; a box is an unfenced `- [ ]` / `- [x]` line with a well-formed
// `<!-- ac:N -->` comment (as acceptanceBoxes). Returns { out } with only the character inside the brackets changed
// (indentation, the "\r" of a CRLF body and every other byte kept; an already ticked box stays), or { code }: 3 = markers
// absent, 5 = an id has no box in the block, 6 = an id is a `[human-gate]` box. Every id is validated before anything
// is changed. String operations only.
function tickIdsInBody(body, ids) {
  const src = String(body ?? '')
  const span = acceptanceSpan(src)
  if (span === null) return { code: 3 }
  const want = Array.isArray(ids) ? ids : []
  const boxes = new Map()
  let fence = ''
  let pos = span.from
  for (const raw of src.slice(span.from, span.to).split('\n')) {
    const l = raw.endsWith('\r') ? raw.slice(0, -1) : raw
    const next = fenceAfter(l, fence)
    const fenced = fence !== '' || next !== ''
    fence = next
    const t = l.trimStart()
    const head = t.slice(0, 5)
    if (!fenced && (head === '- [x]' || head === '- [X]' || head === '- [ ]') && (t.length === 5 || t[5] === ' ' || t[5] === '\t')) {
      const rest = t.slice(5).trimStart()
      if (rest.startsWith('<!-- ac:')) {
        const end = rest.indexOf('-->')
        const digits = end > 0 ? rest.slice(8, end).trim() : ''
        if (digits !== '' && [...digits].every((d) => d >= '0' && d <= '9')) {
          const id = Number(digits)
          const entry = { at: pos + (l.length - t.length) + 3, gate: rest.slice(end + 3).trimStart().startsWith('[human-gate]') }
          boxes.set(id, [...(boxes.get(id) ?? []), entry])
        }
      }
    }
    pos += raw.length + 1
  }
  for (const id of want) if (!boxes.has(id)) return { code: 5 }
  for (const id of want) if (boxes.get(id).some((b) => b.gate)) return { code: 6 }
  const chars = src.split('')
  for (const id of want) for (const b of boxes.get(id)) chars[b.at] = 'x'
  return { out: chars.join('') }
}

function cli(argv) {
  const mode = argv[0]
  if (mode === 'tick-ids') {
    const pre = fs.readFileSync(argv[1], 'utf8')
    const parts = String(argv[3] ?? '').split(',')
    if (parts.length === 0 || parts.some((p) => p === '' || ![...p].every((d) => d >= '0' && d <= '9'))) return 2
    const res = tickIdsInBody(pre, parts.map(Number))
    if (res.code !== undefined) return res.code
    fs.writeFileSync(argv[2], res.out)
    return 0
  }
  if (mode === 'splice') {
    const kind = argv[1]
    const pre = fs.readFileSync(argv[2], 'utf8')
    const text = stripOneTrailingNewline(fs.readFileSync(argv[3], 'utf8'))
    if (kind === 'decision-log') {
      fs.writeFileSync(argv[4], spliceDecisionLogBlock(pre, text))
      return 0
    }
    if (kind === 'acceptance') {
      const out = spliceAcceptanceBlock(pre, text)
      if (out === null) return 3
      fs.writeFileSync(argv[4], out)
      return 0
    }
    return 2
  }
  if (mode === 'tick') {
    const pre = fs.readFileSync(argv[1], 'utf8')
    const text = stripOneTrailingNewline(fs.readFileSync(argv[2], 'utf8'))
    const ids = (csv) => (csv ? String(csv).split(',').map(Number) : [])
    const out = tickAcceptanceBlock(pre, text, ids(argv[4]), ids(argv[5]))
    if (out === null) return 3
    fs.writeFileSync(argv[3], out)
    return 0
  }
  if (mode === 'checked') {
    const body = fs.readFileSync(argv[1] === '-' ? 0 : argv[1], 'utf8')
    process.stdout.write(checkedAcceptanceIds(body).join(',') + '\n')
    return 0
  }
  if (mode === 'entries') {
    const body = fs.readFileSync(argv[1] === '-' ? 0 : argv[1], 'utf8')
    process.stdout.write(JSON.stringify(decisionLogEntries(body)) + '\n')
    return 0
  }
  if (mode === 'guard') {
    const preLen = Number(argv[1])
    const post = fs.readFileSync(argv[2], 'utf8')
    return bodyWriteGuardOk(preLen, post) ? 0 : 1
  }
  return 2
}

if (require.main === module) {
  let rc = 2
  try { rc = cli(process.argv.slice(2)) } catch (_) { rc = 4 }
  process.exit(rc)
}

module.exports = { tickIdsInBody, decisionLogEntries, spliceDecisionLogBlock, spliceAcceptanceBlock, tickAcceptanceBlock, checkedAcceptanceIds, bodyWriteGuardOk, composeDecisionLogBlock, upsertDecisionLog }
