#!/usr/bin/env node
// Content digest of the paths a probe eval depends on (issue #454): freshness of eval results is judged by
// what the eval ran on, not by file times. A merge of the base branch that touches none of PATHS keeps a
// recorded summary fresh; a change under any of them makes it stale. No git needed (the eval container
// mounts the repo read-only and may have no usable git), so it also survives squash merges and fresh clones.
//
// Usage: node scripts/eval-digest.cjs [--root DIR] [--write FILE --gate PASS|FAIL --line TEXT] [--check FILE]
//   (none)        print the 64-hex digest, exit 0
//   --write FILE  write the JSON summary {schemaVersion, digest, sha, paths, gate, line, writtenAt}
//   --check FILE  exit 0 + `fresh: digest <12>`; exit 1 + `stale: recorded <12> current <12>`;
//                 exit 2 + `unreadable: <reason>` (absent, not JSON, no 64-hex digest)
'use strict'
const fs = require('fs')
const path = require('path')
const crypto = require('crypto')
const cp = require('child_process')

const PATHS = ['evals', 'templates', 'hooks', 'agents', 'scripts']
const SKIP_SUBTREE = 'evals/results'

const sha256 = (buffer) => crypto.createHash('sha256').update(buffer).digest('hex')

function walk(root, relative, out) {
  const abs = path.join(root, relative)
  let entries
  try { entries = fs.readdirSync(abs, { withFileTypes: true }) } catch (error) { return }
  for (const ent of entries) {
    const r = relative + '/' + ent.name
    if (ent.name === '.DS_Store' || r === SKIP_SUBTREE) continue
    if (ent.isDirectory()) walk(root, r, out)
    else if (ent.isSymbolicLink()) out.push([r, sha256(Buffer.from(fs.readlinkSync(path.join(root, r))))])
    else if (ent.isFile()) out.push([r, sha256(fs.readFileSync(path.join(root, r)))])
  }
}

function digest(root) {
  const files = []
  for (const p of PATHS) walk(root, p, files)
  files.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0))
  const h = crypto.createHash('sha256')
  for (const [r, d] of files) h.update(r + '\0' + d + '\n')
  return h.digest('hex')
}

function headSha(root) {
  try {
    return cp.execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim()
  } catch (error) { return '' }
}

function main(argv) {
  let root = path.resolve(__dirname, '..')
  let write = null, check = null, gate = '', line = ''
  for (let index = 0; index < argv.length; index++) {
    const a = argv[index]
    if (a === '--root') root = path.resolve(argv[++index])
    else if (a === '--write') write = argv[++index]
    else if (a === '--check') check = argv[++index]
    else if (a === '--gate') gate = argv[++index]
    else if (a === '--line') line = argv[++index]
    else { console.error('usage: eval-digest.cjs [--root DIR] [--write FILE --gate PASS|FAIL --line TEXT] [--check FILE]'); return 2 }
  }
  const current = digest(root)
  if (check !== null) {
    let rec
    try { rec = JSON.parse(fs.readFileSync(check, 'utf8')) } catch (error) {
      console.log('unreadable: ' + (error && error.code === 'ENOENT' ? check + ' not found' : check + ' is not valid JSON'))
      return 2
    }
    if (!rec || typeof rec.digest !== 'string' || !/^[0-9a-f]{64}$/.test(rec.digest)) {
      console.log('unreadable: ' + check + ' has no 64-hex digest')
      return 2
    }
    if (rec.digest === current) { console.log('fresh: digest ' + current.slice(0, 12)); return 0 }
    console.log('stale: recorded ' + rec.digest.slice(0, 12) + ' current ' + current.slice(0, 12))
    return 1
  }
  if (write !== null) {
    const rec = { schemaVersion: 1, digest: current, sha: headSha(root), paths: PATHS, gate, line, writtenAt: new Date().toISOString() }
    fs.mkdirSync(path.dirname(path.resolve(write)), { recursive: true })
    fs.writeFileSync(write, JSON.stringify(rec, null, 2) + '\n')
    return 0
  }
  console.log(current)
  return 0
}

if (require.main === module) process.exit(main(process.argv.slice(2)))
module.exports = { PATHS, digest }
