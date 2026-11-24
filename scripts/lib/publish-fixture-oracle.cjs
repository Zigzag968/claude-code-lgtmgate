'use strict'
// The redaction check of scripts/publish-fixture.cjs: the baseline oracle is redacted like the fixture, then compared slot by slot.
// An engine that echoes a redactable string still matches; one that branches on it differs. Text it builds never holds a value.
const fs = require('fs')
const path = require('path')

const ORACLE_SLOTS = ['status', 'reason', 'trace', 'labels', 'sites', 'shape', 'logs', 'values', 'needles']
const getAt = (root, segs) => segs.reduce((node, s) => (node === undefined || node === null ? undefined : node[s]), root)

// The baseline parts run through redact-fixture.cjs; a redactor that refuses the copy leaves them as they are (unredacted comparison).
function redactedParts(runNode, redactor, directory, parts) {
  const file = path.join(directory, 'baseline-parts.json')
  fs.writeFileSync(file, JSON.stringify({ parts }), { mode: 0o600 })
  if (runNode([redactor, file]).status !== 0) return parts
  try { const out = JSON.parse(fs.readFileSync(file, 'utf8')).parts; return Array.isArray(out) ? out : parts } catch (error) { return parts }
}

// '' when the slots agree, else the refusal text: differing slot names and the rewritten leaves (path and length, never a value).
function refusalText(got, expected, leaves, fx2, pathOf) {
  const differing = got === null ? ORACLE_SLOTS : ORACLE_SLOTS.filter((_, index) => JSON.stringify(got[index]) !== JSON.stringify(expected[index]))
  if (!differing.length) return ''
  const changed = leaves.filter((l) => l.parent[l.key] !== getAt(fx2, l.segs)).map((l) => `${pathOf(l.segs)} (${l.parent[l.key].length} chars)`)
  return `outcome changed after redaction: ${differing.join(', ')}; rewritten leaves: ${changed.length ? changed.join(', ') : 'none'}`
}

// Refuses (through `refuse`) when the replay of the redacted candidate differs from the redacted baseline.
function redactionCheck({ refuse, runNode, redactor, directory, baseParts, got, leaves, fx2, pathOf }) {
  const why = refusalText(got, redactedParts(runNode, redactor, directory, baseParts), leaves, fx2, pathOf)
  if (why) refuse(why)
}

module.exports = { redactionCheck, ORACLE_SLOTS }
