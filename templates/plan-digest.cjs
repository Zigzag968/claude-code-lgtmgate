#!/usr/bin/env node
// #700: the plan-artifact probe command, as a short script run by path. argv[2] = the issue number (digits only);
// the run's worktree is the current directory (the probe line starts with `cd '<worktree>'`). Prints two lines:
// sha256 of the artifact bytes, then sha256 of its `proof-command `-prefixed lines (CR stripped, joined by LF; same
// rule as proofLinesOf). Any failure prints the single line PLAN-DIGEST-ERROR. Never prints a path.
'use strict'
const fs = require('fs')
const crypto = require('crypto')
try {
  const issue = String(process.argv[2] ?? '')
  const digits = '0123456789'
  if (issue === '' || !issue.split('').every((c) => digits.includes(c))) throw new Error('issue')
  const bytes = fs.readFileSync(`.pipeline/plans/issue-${issue}-sam.md`)
  const lines = bytes.toString('utf8').split('\n')
    .map((l) => (l.endsWith('\r') ? l.slice(0, -1) : l))
    .filter((l) => l.startsWith('proof-command '))
    .join('\n')
  console.log(crypto.createHash('sha256').update(bytes).digest('hex'))
  console.log(crypto.createHash('sha256').update(lines).digest('hex'))
} catch (error) {
  console.log('PLAN-DIGEST-ERROR')
}
