#!/usr/bin/env node
'use strict'

// Redacts a fixture (JSON) or any text file before it is committed under fixtures/ — this
// repo is public. One fixed rule table (RULES), no options. JSON files are parsed and every
// string value and key is redacted on its DECODED form (so `\n`, `\"` inside JSON never
// confuse the patterns), then re-serialised; other files are treated as plain text.
// A rule has a `kind`: rewrite (each match of `re` becomes `to`), json-key (the string value of a
// JSON key whose whole name matches `key` becomes `to`, as a parsed key AND as a `"key":"value"` pair
// in any text: a string holding JSON, `\"key\":\"value\"` included, a .jsonl journal, a raw capture)
// or refuse (never rewritten: a match stops the run). After the rewrite pass the whole table runs again on the output: a rule that
// would still act on it is a hit, and any hit refuses. `refused: <file>: <rule> at <json path or
// line>` goes to stderr (never the value), the exit code is 3 and nothing is written, not even
// for the other files given.
// Every placeholder stays outside the `no-private-refs` pattern table (templates/test-canonical-guards.sh):
// `/Users/you` and `/home/user` are on its allow list, the others match none of its patterns.
// Only the shapes listed in RULES are guaranteed; private business content in a fixture is out of this script's reach (the capture and publish tooling minimizes it, #181 and #189).
// Usage: node scripts/redact-fixture.cjs <file> [<file>...]   (rewrites in place)
//        node scripts/redact-fixture.cjs --check <file>...     (exit 1 if anything would change)
// Exit:  0 done · 1 --check: something would change · 2 usage · 3 refused, nothing written

const fs = require('fs')

const { SECRET_REWRITES, PEM_RULE } = require('./lib/secret-rules.cjs')

const RULES = [
  // GitHub tokens, API keys (shared with scripts/agent-context.cjs: scripts/lib/secret-rules.cjs)
  ...SECRET_REWRITES,
  // temp directories: the whole path goes (uid, project directory and run id are all session-private);
  // `/var/folders` may carry the `/private` of its real path
  { id: 'temp-private-tmp', kind: 'rewrite', re: /\/private\/tmp\/[^\s"'`\\]*/g, to: '/tmp/redacted' },
  { id: 'temp-var-folders', kind: 'rewrite', re: /(?:\/private)?\/var\/folders\/[^\s"'`\\]*/g, to: '/tmp/redacted' },
  // home directories, mounted volumes and /opt/<dir> (case-insensitive for the first two, like the invariant): keep the tail
  { id: 'home-users', kind: 'rewrite', re: /\/users\/[^/\s"'`\\]+/gi, to: '/Users/you' },
  { id: 'home-linux', kind: 'rewrite', re: /\/home\/[^/\s"'`\\]+/gi, to: '/home/user' },
  { id: 'volumes', kind: 'rewrite', re: /\/Volumes\/[^/\s"'`\\]+/g, to: '/Volumes/<disk>' },
  { id: 'opt-dir', kind: 'rewrite', re: /\/opt\/[^/\s"'`\\]+/g, to: '/opt/app' },
  // dash-encoded paths (a working directory as a directory name, `/` -> `-`): the whole name goes, the user
  // name cannot be told from the rest; only at a name start, so `smart-home-hub` stays
  { id: 'dash-users', kind: 'rewrite', re: /(?<![\w.~-])-Users-[\w.-]+/g, to: '-Users-you' },
  { id: 'dash-home', kind: 'rewrite', re: /(?<![\w.~-])-home-[\w.-]+/g, to: '-home-user' },
  { id: 'dash-volumes', kind: 'rewrite', re: /(?<![\w.~-])-Volumes-[\w.-]+/g, to: '-Volumes-disk' },
  // emails, except the `git@` SSH remote form (`git@github.com:owner/repo.git` is not personal data)
  { id: 'email', kind: 'rewrite', re: /\b(?!git@)[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/g, to: 'redacted@example.com' },
  // signed / tokenized URLs
  { id: 'signed-url', kind: 'rewrite', re: /([?&](?:token|sig|signature|X-Amz-Signature|access_token)=)[^&\s"'`\\]+/gi, to: '$1REDACTED' },
  // the string value of a secret-named JSON key (whole name, any case): `authSecurityBoundarySignal` is not one
  { id: 'secret-key-value', kind: 'json-key', names: ['apiKey', 'api_key', 'secret', 'password', 'passwd', 'token', 'access_token', 'refresh_token', 'client_secret', 'private_key', 'authorization'], to: 'REDACTED' },
  PEM_RULE,
]
// A json-key rule compiles once: `key` for a parsed key (whole name), `plain` and `head` for the text form. A pair is
// the whole key name between quotes, a colon, then a non-empty string value: plain (`"k":"v"`, value up to the
// first unescaped quote or the end of the line) or backslash-escaped (`\"k\":\"v\"`, as inside a string that
// holds JSON: `head` matches the part before the value, `escapedValueEnd` finds where the value really ends).
for (const r of RULES) {
  if (r.kind !== 'json-key') continue
  const names = r.names.join('|')
  r.key = new RegExp(`^(?:${names})$`, 'i')
  r.plain = new RegExp(`(")(${names})("\\s*:\\s*")((?:[^"\\\\\\n]|\\\\[^\\n])+)`, 'gi')
  r.head = new RegExp(`(\\\\")(${names})(\\\\"\\s*:\\s*\\\\")`, 'gi')
}
const REWRITES = RULES.filter((r) => r.kind === 'rewrite')
const KEY_RULES = RULES.filter((r) => r.kind === 'json-key')

// End (exclusive index) of the value of an escaped pair, from its first character. Inside a string that holds
// JSON a quote of the value is serialised `\\\"` (3 backslashes) and a backslash `\\\\` (4): they belong to the
// value, so a value ending in m backslashes is followed by 4m of them and the lone `\"` delimiter (a run of 4m+1:
// the delimiter is the last backslash). A bare quote, or a quote after an even run of backslashes, ends the
// outer string (truncated capture): the value stops before it, and so does a newline (a truncated line never
// swallows the next one). Only this one nesting level is handled.
function escapedValueEnd(t, i) {
  while (i < t.length) {
    if (t[i] === '"' || t[i] === '\n') return i
    if (t[i] !== '\\') { i++; continue }
    let j = i
    while (t[j] === '\\') j++
    if (t[j] === '"' && (j - i) % 4 === 1) return j - 1
    if (t[j] === '"' && (j - i) % 2 === 0) return i
    i = t[j] === '"' ? j + 1 : j
  }
  return i
}

// `"key":"value"` -> `"key":"<to>"` for the pairs of one json-key rule (the key keeps its spelling)
function redactPairs(text, r) {
  let out = text.replace(r.plain, (m, open, key, close) => open + key + close + r.to)
  let res = ''
  let last = 0
  r.head.lastIndex = 0
  for (let m; (m = r.head.exec(out)); ) {
    const start = m.index + m[0].length
    const end = escapedValueEnd(out, start)
    if (end === start) continue
    res += out.slice(last, start) + r.to
    last = end
    r.head.lastIndex = end
  }
  return res + out.slice(last)
}

function redactText(text) {
  let out = text
  for (const r of REWRITES) out = out.replace(r.re, r.to)
  for (const r of KEY_RULES) out = redactPairs(out, r)
  return out
}

// The json-key rule that acts on this key/value: a non-empty string under a secret-named key
// (null, numbers, booleans, objects, arrays and '' hold nothing to hide).
const keyRule = (k, v) => (typeof v === 'string' && v !== '' ? KEY_RULES.find((r) => r.key.test(k)) : undefined)

function redactValue(v) {
  if (typeof v === 'string') return redactText(v)
  if (Array.isArray(v)) return v.map(redactValue)
  if (v && typeof v === 'object') {
    const out = {}
    for (const k of Object.keys(v)) {
      const r = keyRule(k, v[k])
      out[redactText(k)] = r ? r.to : redactValue(v[k])
    }
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

// The ids of the rules that would still act on a string: a rewrite that would change it, a refuse that matches it.
// A placeholder its own rule matches again is not a hit (rewriting it gives the same string).
function stringHits(s) {
  const ids = []
  for (const r of RULES) {
    if (r.kind === 'rewrite' && s.replace(r.re, r.to) !== s) ids.push(r.id)
    else if (r.kind === 'json-key' && redactPairs(s, r) !== s) ids.push(r.id)
    else if (r.kind === 'refuse' && r.re.test(s)) ids.push(r.id)
  }
  return ids
}

// [rule id, location] for every hit in the output. Location: `$.a.b[0]` for a JSON value, `line N` for text.
// A hit inside a key is located at `<key>`: the key itself is never printed.
const step = (k) => (/^[A-Za-z_]\w*$/.test(k) ? `.${k}` : `[${JSON.stringify(k)}]`)
function jsonHits(v, at, found) {
  if (typeof v === 'string') for (const id of stringHits(v)) found.push([id, at])
  else if (Array.isArray(v)) v.forEach((x, i) => jsonHits(x, `${at}[${i}]`, found))
  else if (v && typeof v === 'object') {
    for (const k of Object.keys(v)) {
      const inKey = stringHits(k)
      const here = inKey.length ? `${at}.<key>` : at + step(k)
      for (const id of inKey) found.push([id, here])
      const r = keyRule(k, v[k])
      if (r && v[k] !== r.to) found.push([r.id, here])
      jsonHits(v[k], here, found)
    }
  }
  return found
}
function textHits(text) {
  const found = []
  text.split('\n').forEach((line, i) => { for (const id of stringHits(line)) found.push([id, `line ${i + 1}`]) })
  return found
}
function hitsOf(output, isJson) {
  if (isJson) { try { return jsonHits(JSON.parse(output), '$', []) } catch (e) { /* not JSON: scanned as text */ } }
  return textHits(output)
}

const argv = process.argv.slice(2)
const check = argv[0] === '--check'
const files = check ? argv.slice(1) : argv
if (!files.length) {
  process.stderr.write('usage: node scripts/redact-fixture.cjs [--check] <file>...\n')
  process.exit(2)
}
// Every file is redacted and re-scanned before any is written: one hit refuses the whole run.
const runs = files.map((f) => {
  const before = fs.readFileSync(f, 'utf-8')
  const isJson = f.endsWith('.json')
  const after = redactFile(before, isJson)
  return { f, isJson, before, after, hits: hitsOf(after, isJson) }
})
const refused = runs.flatMap((r) => r.hits.map(([id, at]) => `refused: ${r.f}: ${id} at ${at}`))
if (refused.length) {
  process.stderr.write(refused.join('\n') + '\n')
  process.exitCode = 3
} else {
  let dirty = 0
  for (const { f, isJson, before, after } of runs) {
    // compare on content, not formatting: a JSON file is re-serialised by this script
    const same = isJson
      ? (() => { try { return JSON.stringify(JSON.parse(before)) === JSON.stringify(JSON.parse(after)) } catch (e) { return before === after } })()
      : before === after
    if (!same) {
      dirty++
      if (check) process.stdout.write(`would redact: ${f}\n`)
      else { fs.writeFileSync(f, after); process.stdout.write(`redacted: ${f}\n`) }
    }
  }
  process.exitCode = check && dirty ? 1 : 0
}
