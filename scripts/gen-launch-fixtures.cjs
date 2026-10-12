#!/usr/bin/env node
'use strict'

// Seeded generator of synthetic project contexts (a docs/agent folder of per-role Markdown plus a config), used to
// measure the bytes of a launch (scripts/lib/launch-bytes.cjs, docs/bench/launch-speed.md). Nothing is read from
// a real consumer: the text comes from a fixed vocabulary and a seeded PRNG, so every run builds the same bytes.
//
// Usage: node scripts/gen-launch-fixtures.cjs --check
//        node scripts/gen-launch-fixtures.cjs --tree <dir> --size 4k|22k|60k
// --check exits 0 and prints `ratios within tolerance`, or prints `FAIL: ...` lines and exits 1.

const fs = require('fs')
const nodePath = require('path')
const { execFileSync } = require('child_process')
const { checkContent } = require('./lib/agent-context-text.cjs')

const SEED = 527
const SIZES = { '4k': 4, '22k': 22, '60k': 60 }
// Measured share of each file in the specifics of a real consumer, in percent (the six sum to 100).
const MEASURED = { shared: 9, sam: 26, nick: 28, morgan: 28, theo: 7, mia: 2 }
const CONFIG_BYTES = 3100
const FOLDER = 'docs/agent'
const CONFIG_PATH = '.claude/pipeline.config.json'

const WORDS = ['plan', 'review', 'check', 'scope', 'merge', 'branch', 'commit', 'test', 'guard', 'build', 'issue', 'config', 'worktree', 'proof', 'diff', 'rule', 'status', 'script', 'agent', 'stage', 'launch', 'result', 'folder', 'module', 'record', 'bounded', 'stable', 'explicit', 'small', 'clean', 'repeat', 'verify', 'report', 'ready', 'target', 'source', 'owner', 'change', 'limit', 'cache']
const CODE = ['run()', 'main', 'opts.root', 'ref', 'digest', 'args', 'build', 'lint']
const UTF8 = ['é', '—', '…']

// mulberry32: a tiny seeded PRNG (32-bit state), enough for a stable vocabulary walk.
function mulberry32(seed) {
  let a = seed >>> 0
  return () => {
    a = (a + 0x6d2b79f5) >>> 0
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

const bytes = (s) => Buffer.byteLength(s, 'utf8')

function words(rand, count) {
  const out = []
  for (let k = 0; k < count; k++) out.push(WORDS[Math.floor(rand() * WORDS.length)])
  return out.join(' ')
}

function line(rand) {
  const kind = Math.floor(rand() * 5)
  if (kind === 0) return `## ${words(rand, 2 + Math.floor(rand() * 2))}`
  if (kind === 1) return `- ${words(rand, 4 + Math.floor(rand() * 5))}`
  if (kind === 2) return `- ${words(rand, 2)} \`${CODE[Math.floor(rand() * CODE.length)]}\` ${words(rand, 3)}`
  if (kind === 3) return `${words(rand, 6 + Math.floor(rand() * 6))}.`
  return `- ${words(rand, 3)} ${UTF8[Math.floor(rand() * UTF8.length)]} ${words(rand, 3)}`
}

// A text of exactly `target` bytes: whole lines, then one filler line that takes the remaining bytes.
function text(rand, title, target) {
  let out = `# ${title} é — …\n`
  for (;;) {
    const next = line(rand) + '\n'
    if (bytes(out) + bytes(next) > target) break
    out += next
  }
  const left = target - bytes(out)
  if (left >= 2) {
    let filler = ''
    while (filler.length < left - 1) filler += words(rand, 3) + ' '
    out += filler.slice(0, left - 1).trimEnd().padEnd(left - 1, 'x') + '\n'
  }
  return out
}

function config(rand) {
  const base = {
    projectSpecifics: FOLDER,
    baseBranch: 'main',
    branchPrefix: 'feat/',
    commands: { build: 'make build', test: 'make test', format: 'make format' },
    ciChecks: ['build', 'test', 'lint'],
    notes: '',
  }
  const empty = JSON.stringify(base, null, 2) + '\n'
  let pad = ''
  while (pad.length < CONFIG_BYTES - bytes(empty)) pad += words(rand, 4) + ' '
  base.notes = pad.slice(0, CONFIG_BYTES - bytes(empty)).trimEnd().padEnd(CONFIG_BYTES - bytes(empty), 'x')
  return JSON.stringify(base, null, 2) + '\n'
}

// files(size) -> { path: text }; pure and deterministic.
function files(size) {
  if (!SIZES[size]) throw new Error(`unknown size: ${size}`)
  const total = SIZES[size] * 1024
  const rand = mulberry32(SEED)
  const out = {}
  for (const name of Object.keys(MEASURED)) {
    out[`${FOLDER}/${name}.md`] = text(rand, name, Math.round((total * MEASURED[name]) / 100))
  }
  out[CONFIG_PATH] = config(rand)
  return out
}

function gitRun(dir, arguments_) {
  execFileSync('git', ['-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@example.com', '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null', ...arguments_], { stdio: 'ignore' })
}

// makeTree(dir, size): a git tree with one commit and refs/remotes/origin/main on it.
function makeTree(dir, size) {
  fs.mkdirSync(dir, { recursive: true })
  gitRun(dir, ['init', '-q'])
  for (const [p, body] of Object.entries(files(size))) {
    fs.mkdirSync(nodePath.join(dir, nodePath.dirname(p)), { recursive: true })
    fs.writeFileSync(nodePath.join(dir, p), body)
  }
  gitRun(dir, ['add', '-A'])
  gitRun(dir, ['commit', '-q', '-m', 'fixture'])
  gitRun(dir, ['update-ref', 'refs/remotes/origin/main', 'HEAD'])
}

function check() {
  const fails = []
  for (const size of Object.keys(SIZES)) {
    const a = files(size)
    if (JSON.stringify(a) !== JSON.stringify(files(size))) fails.push(`FAIL: ${size}: two runs differ`)
    const mdTotal = Object.keys(MEASURED).reduce((s, n) => s + bytes(a[`${FOLDER}/${n}.md`]), 0)
    const nominal = SIZES[size] * 1024
    if (Math.abs(mdTotal - nominal) > nominal * 0.03) fails.push(`FAIL: ${size}: total ${mdTotal} is not within 3% of ${nominal}`)
    for (const n of Object.keys(MEASURED)) {
      const body = a[`${FOLDER}/${n}.md`]
      const share = (bytes(body) / mdTotal) * 100
      if (Math.abs(share - MEASURED[n]) > 1.5) fails.push(`FAIL: ${size}: ${n} share ${share.toFixed(2)} is not within 1.5 of ${MEASURED[n]}`)
      if (!/[^\x00-\x7f]/.test(body)) fails.push(`FAIL: ${size}: ${n} holds no non-ASCII char`)
      for (const r of checkContent(body)) fails.push(`FAIL: ${size}: ${n}: ${r}`)
    }
    const c = bytes(a[CONFIG_PATH])
    if (Math.abs(c - CONFIG_BYTES) > CONFIG_BYTES * 0.05) fails.push(`FAIL: ${size}: config ${c} bytes is not within 5% of ${CONFIG_BYTES}`)
    try { JSON.parse(a[CONFIG_PATH]) } catch (error) { fails.push(`FAIL: ${size}: config is not valid JSON`) }
  }
  if (fails.length) { for (const f of fails) console.log(f); return 1 }
  console.log('ratios within tolerance')
  return 0
}

function main(argv) {
  const get = (flag) => { const i = argv.indexOf(flag); return i >= 0 ? argv[i + 1] : undefined }
  if (argv.includes('--check')) return check()
  const dir = get('--tree')
  const size = get('--size')
  if (!dir || !SIZES[size]) {
    process.stderr.write('usage: gen-launch-fixtures.cjs --check | --tree <dir> --size 4k|22k|60k\n')
    return 2
  }
  makeTree(dir, size)
  return 0
}

module.exports = { files, makeTree, MEASURED, SIZES }

if (require.main === module) process.exitCode = main(process.argv.slice(2))
