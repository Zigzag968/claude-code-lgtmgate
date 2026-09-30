#!/usr/bin/env node
'use strict'

// Redacts a fixture (or any text/JSON file) before it is committed under fixtures/ —
// this repo is public. Fixed list, no options: tokens, home paths, emails, signed URLs.
// Usage: node scripts/redact-fixture.cjs <file> [<file>...]   (rewrites in place)
//        node scripts/redact-fixture.cjs --check <file>...     (exit 1 if anything would change)

const fs = require('fs')

const RULES = [
  // GitHub tokens (classic + fine-grained + app), generic bearer-looking secrets
  [/\bgh[pousr]_[A-Za-z0-9]{20,}\b/g, 'gh*_REDACTED'],
  [/\bgithub_pat_[A-Za-z0-9_]{20,}\b/g, 'github_pat_REDACTED'],
  [/\b(sk|rk)-[A-Za-z0-9-]{20,}\b/g, '$1-REDACTED'],
  // home directories (macOS / linux), keep the tail so paths stay readable
  [/\/Users\/[^/\s"'`]+/g, '/Users/REDACTED'],
  [/\/home\/[^/\s"'`]+/g, '/home/REDACTED'],
  // emails
  [/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/g, 'redacted@example.com'],
  // signed / tokenized URLs (query string carrying a token-like key)
  [/([?&](?:token|sig|signature|X-Amz-Signature|access_token)=)[^&\s"'`]+/gi, '$1REDACTED'],
]

function redact(text) {
  let out = text
  for (const [re, rep] of RULES) out = out.replace(re, rep)
  return out
}

const argv = process.argv.slice(2)
const check = argv[0] === '--check'
const files = check ? argv.slice(1) : argv
if (!files.length) {
  process.stderr.write('usage: node scripts/redact-fixture.cjs [--check] <file>...\n')
  process.exit(2)
}
let dirty = 0
for (const f of files) {
  const before = fs.readFileSync(f, 'utf-8')
  const after = redact(before)
  if (after !== before) {
    dirty++
    if (check) process.stdout.write(`would redact: ${f}\n`)
    else { fs.writeFileSync(f, after); process.stdout.write(`redacted: ${f}\n`) }
  }
}
process.exit(check && dirty ? 1 : 0)
