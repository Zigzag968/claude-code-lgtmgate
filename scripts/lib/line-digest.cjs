'use strict'
// #699: the digest form of a VERIFY answer, `VERIFY ok linesha=<sha256 of the PROBE line>`, follows its PROBE line in a recorded
// fixture entry: any rewrite of the line (a neutral token, a redaction, a re-hashed `cmd=`) leaves the digest stale, and the
// engine then refuses the copy as a line-mismatch. Shared by publish-fixture.cjs and rehash-fixtures.cjs (run-offline.cjs stays one file).
const crypto = require('crypto')

const LINE_DIGEST = /^VERIFY ok linesha=[0-9a-f]{64}$/
const digestAnswer = (line) => `VERIFY ok linesha=${crypto.createHash('sha256').update(String(line), 'utf8').digest('hex')}`
const isDigestAnswer = (entry) => !!entry && typeof entry.line === 'string' && typeof entry.verify === 'string' && LINE_DIGEST.test(entry.verify)

// Rewrites entry.verify to the digest of entry.line (through `put(parent, key, value)` when given); true when it changed.
function syncLineDigest(entry, put) {
  if (!isDigestAnswer(entry) || entry.verify === digestAnswer(entry.line)) return false
  if (put) put(entry, 'verify', digestAnswer(entry.line))
  else entry.verify = digestAnswer(entry.line)
  return true
}

// Every call entry of a fixture's `calls` (a value or an array of values), synced; returns the number rewritten.
function syncCalls(calls) {
  let n = 0
  for (const value of Object.values(calls || {})) for (const entry of Array.isArray(value) ? value : [value]) if (syncLineDigest(entry)) n++
  return n
}

module.exports = { LINE_DIGEST, digestAnswer, syncLineDigest, syncCalls }
