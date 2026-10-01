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
// Selects the LAST marker pair for the SAME reason the decision-log regexes do: a plan artifact
// (this very file's own doc comments included) can contain an earlier, illustrative/fenced copy
// of the marker pair.
const ACCEPTANCE_START = '<!-- acceptance:start -->'
const ACCEPTANCE_END = '<!-- acceptance:end -->'
const ACCEPTANCE_START_RE = /^<!-- acceptance:start -->[ \t]*$/gm
const ACCEPTANCE_END_RE = /^<!-- acceptance:end -->[ \t]*$/gm
// Pure. Replaces the acceptance-block CONTENTS (between the LAST marker pair) with `checklist`
// (the verbatim `- [ ] ...` lines Sam returns for an amendment round). Returns null — NEVER
// appends — when `checklist` is empty/blank or either marker is missing from `body`.
function spliceAcceptanceBlock(body, checklist) {
  const list = String(checklist ?? '').trim()
  if (!list) return null
  const src = String(body ?? '')
  let s = -1
  let sLen = ACCEPTANCE_START.length
  ACCEPTANCE_START_RE.lastIndex = 0
  let m
  while ((m = ACCEPTANCE_START_RE.exec(src))) { s = m.index; sLen = m[0].length }
  let e = -1
  ACCEPTANCE_END_RE.lastIndex = 0
  while ((m = ACCEPTANCE_END_RE.exec(src))) e = m.index
  if (s === -1 || e === -1 || e <= s) return null
  return src.slice(0, s + sLen) + '\n' + list + '\n' + src.slice(e)
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

module.exports = { spliceDecisionLogBlock, spliceAcceptanceBlock, bodyWriteGuardOk, composeDecisionLogBlock, upsertDecisionLog }
