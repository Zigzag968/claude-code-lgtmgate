#!/usr/bin/env node
'use strict'

// Redacts a fixture (JSON) or any text file before it is committed under fixtures/ — this
// repo is public. Fixed rule list, no options. JSON files are parsed and every string value
// is redacted on its DECODED form (so `\n`, `\"` inside JSON never confuse the patterns),
// then re-serialised; other files are treated as plain text.
// Replacement values are the ones the `no-private-refs` invariant whitelists
// (`/Users/you`, `/home/user`), so a redacted fixture never trips that invariant.
// Usage: node scripts/redact-fixture.cjs <file> [<file>...]   (rewrites in place)
//        node scripts/redact-fixture.cjs --check <file>...     (exit 1 if anything would change)

const fs = require('fs')

const RULES = [
  // GitHub tokens (classic, fine-grained, app), API keys (base64url: `_` included)
  [/\bgh[pousr]_[A-Za-z0-9]{20,}\b/g, 'gh*_REDACTED'],
  [/\bgithub_pat_[A-Za-z0-9_]{20,}\b/g, 'github_pat_REDACTED'],
  [/\b(sk|rk)-[A-Za-z0-9_-]{20,}\b/g, '$1-REDACTED'],
  // home directories and mounted volumes (case-insensitive, like the invariant), keep the tail
  [/\/users\/[^/\s"'`\\]+/gi, '/Users/you'],
  [/\/home\/[^/\s"'`\\]+/gi, '/home/user'],
  [/\/Volumes\/[^/\s"'`\\]+/g, '/Volumes/disk'],
  // emails, except the `git@` SSH remote form (`git@github.com:owner/repo.git` is not personal data)
  [/\b(?!git@)[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/g, 'redacted@example.com'],
  // signed / tokenized URLs
  [/([?&](?:token|sig|signature|X-Amz-Signature|access_token)=)[^&\s"'`\\]+/gi, '$1REDACTED'],
]

function redactText(text) {
  let out = text
  for (const [re, rep] of RULES) out = out.replace(re, rep)
  return out
}

function redactValue(v) {
  if (typeof v === 'string') return redactText(v)
  if (Array.isArray(v)) return v.map(redactValue)
  if (v && typeof v === 'object') {
    const out = {}
    for (const k of Object.keys(v)) out[redactText(k)] = redactValue(v[k])
    return out
  }
  return v
}

function redactFile(raw, isJson) {
  if (isJson) {
    let parsed
    try { parsed = JSON.parse(raw) } catch (e) { return redactText(raw) }
    return JSON.stringify(redactValue(parsed), null, 2) + '\n'
  }
  return redactText(raw)
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
  const after = redactFile(before, f.endsWith('.json'))
  // compare on content, not formatting: a JSON file is re-serialised by this script
  const same = f.endsWith('.json')
    ? (() => { try { return JSON.stringify(JSON.parse(before)) === JSON.stringify(JSON.parse(after)) } catch (e) { return before === after } })()
    : before === after
  if (!same) {
    dirty++
    if (check) process.stdout.write(`would redact: ${f}\n`)
    else { fs.writeFileSync(f, after); process.stdout.write(`redacted: ${f}\n`) }
  }
}
process.exit(check && dirty ? 1 : 0)
