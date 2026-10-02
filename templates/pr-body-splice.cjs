#!/usr/bin/env node
'use strict'

// pr-body-splice: the PR-body splice/guard primitives of the engine as a CLI (E2.6a, #85).
//
// The block between the two `prBodySplice` markers below is a BYTE-IDENTICAL copy of the same block in
// workflows/deliver-pipeline.js (the engine copy stays: simulate previews and T87b/T113 probes use it).
// templates/test-probe-run.sh checks the parity. Do not edit the block here without editing the engine.
//
// CLI (used by templates/pr-write.sh, op body-splice):
//   node pr-body-splice.cjs splice <decision-log|acceptance> <preFile> <textFile> <outFile>
//       exit 0 = spliced and written to outFile; 3 = acceptance markers absent / empty checklist
//       (NEVER appends); any other non-zero = failure. One trailing "\n" of the text file is stripped.
//   node pr-body-splice.cjs tick <preFile> <textFile> <outFile> <tickCsv> <keepCsv>
//       the acceptance block of preFile replaced by the rendered checklist in textFile with each box set by its
//       `<!-- ac:N -->` id (#183): ids of tickCsv `[x]`, ids of keepCsv keep the state preFile has, the others open.
//       Same exits as `splice acceptance` (3 = markers absent / empty checklist).
//   node pr-body-splice.cjs checked <bodyFile|->
//       prints the ids of the boxes ticked in the acceptance block (comma-separated, ascending; empty when none or no
//       block); `-` reads the body from stdin. Exit 0.
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

// Idempotent splice of a pre-composed decision-log block into a body. Replaces an existing
// block in place; appends at the end when the markers are absent (legacy/resumed PRs). Pure —
// extracted from upsertDecisionLog (issue #87) so the SAME splice algorithm can be embedded
// (via .toString()) into the single deterministic shell chain recordDecision runs, instead of
// being hand-duplicated there.
function spliceDecisionLogBlock(body, block) {
  const src = String(body ?? '')
  let s = -1
  let m
  DECISION_LOG_START_RE.lastIndex = 0
  while ((m = DECISION_LOG_START_RE.exec(src))) s = m.index
  let e = -1
  let eLen = DECISION_LOG_END.length
  DECISION_LOG_END_RE.lastIndex = 0
  while ((m = DECISION_LOG_END_RE.exec(src))) { e = m.index; eLen = m[0].length }
  if (s !== -1 && e !== -1 && e > s) {
    return src.slice(0, s) + block + src.slice(e + eLen)
  }
  return (src.endsWith('\n') ? src : src + '\n') + '\n' + block + '\n'
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
// The contents of the acceptance block of `src`, as { from, to, eol } (`from`: just after the start marker line, before its
// line break; `to`: the start of the end marker line; `eol`: the line break the body puts after the start marker, "\r\n"
// or "\n"): the LAST marker pair outside a fenced code block (a line opening with 3+ backticks or tildes, up to 3 spaces of
// indent, until a line closing it with the same character, at least as long), null when a marker is missing or the end
// does not follow the start. String operations only.
function acceptanceSpan(src) {
  let s = -1
  let sEnd = -1
  let e = -1
  let fence = ''
  let pos = 0
  for (const raw of src.split('\n')) {
    const line = raw.endsWith('\r') ? raw.slice(0, -1) : raw
    const t = line.trimStart()
    const c = t[0]
    let run = 0
    if ((c === '`' || c === '~') && line.length - t.length <= 3) while (t[run] === c) run += 1
    if (fence !== '') {
      if (run >= fence.length && c === fence[0] && t.slice(run).trim() === '') fence = ''
    } else if (run >= 3 && !(c === '`' && t.slice(run).includes('`'))) {
      fence = c.repeat(run)
    } else {
      let end = line.length
      while (end > 0 && (line[end - 1] === ' ' || line[end - 1] === '\t')) end -= 1
      const marker = line.slice(0, end)
      if (marker === ACCEPTANCE_START) { s = pos; sEnd = pos + line.length } else if (marker === ACCEPTANCE_END) e = pos
    }
    pos += raw.length + 1
  }
  if (s === -1 || e === -1 || e <= s) return null
  return { from: sEnd, to: e, eol: src.startsWith('\r\n', sEnd) ? '\r\n' : '\n' }
}
// The boxes of the acceptance block text `text`: { checkedById: Map id -> ticked (a `- [ ]` / `- [x]` line carrying a
// well-formed `<!-- ac:N -->` comment), extra: the checkbox lines without an id, verbatim }. String operations only.
function acceptanceBoxes(text) {
  const checkedById = new Map()
  const extra = []
  for (const raw of String(text).split('\n')) {
    const l = raw.endsWith('\r') ? raw.slice(0, -1) : raw
    const t = l.trimStart()
    const head = t.slice(0, 5)
    const ticked = head === '- [x]' || head === '- [X]'
    if (!(ticked || head === '- [ ]') || !(t.length === 5 || t[5] === ' ' || t[5] === '\t')) continue
    const rest = t.slice(5).trimStart()
    if (!rest.startsWith('<!-- ac:')) { extra.push(l); continue }
    const end = rest.indexOf('-->')
    const digits = end > 0 ? rest.slice(8, end).trim() : ''
    if (digits !== '' && [...digits].every((d) => d >= '0' && d <= '9')) checkedById.set(Number(digits), ticked)
    else extra.push(l)
  }
  return { checkedById, extra }
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
// the block of `body` (the LAST unfenced marker pair) is replaced by it with each box set by its id: `[x]` for an id of
// `tickIds`; an id of `keepIds` (a human gate, or a box nobody returned that a person ticked) keeps the state the body
// has, so a person's tick survives and the engine never writes a gate `[x]`; any other id is open, so a stale `[x]` is
// reopened. The checkbox lines of the block that carry no id (the line a project's rule has Nick add) are kept as they
// stand, after the rendered lines, and never ticked. null, like spliceAcceptanceBlock, when `rendered` is blank or a
// marker is missing. String operations only.
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
  const { checkedById, extra } = acceptanceBoxes(src.slice(span.from, span.to))
  const tick = Array.isArray(tickIds) ? tickIds : []
  const keep = Array.isArray(keepIds) ? keepIds : []
  const lines = list.split('\n').map((line) => {
    if (!line.startsWith('- [ ] ')) return line
    const id = idOf(line.slice(6))
    if (id === null) return line
    const checked = keep.includes(id) ? checkedById.get(id) === true : tick.includes(id)
    return checked ? '- [x] ' + line.slice(6) : line
  })
  return spliceAcceptanceBlock(src, [...lines, ...extra].join('\n'))
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

function cli(argv) {
  const mode = argv[0]
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

module.exports = { spliceDecisionLogBlock, spliceAcceptanceBlock, tickAcceptanceBlock, checkedAcceptanceIds, bodyWriteGuardOk, composeDecisionLogBlock, upsertDecisionLog }
