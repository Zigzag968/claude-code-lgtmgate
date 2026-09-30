#!/usr/bin/env node
'use strict'

// probe-run: the single gate to the world for engine probes (E2.2, #80).
//
// A script EXECUTES the command and keeps the RAW output on disk; an LLM (agents/probe.md) only
// copies ONE line; a hook (hooks/PostToolUse-probe-attest.sh) attests that the line came out of this
// script. Parsing lives here, as pure functions replayed against fixtures/probes/*.raw.
//
// Usage:
//   node probe-run.cjs --label L --round N --out /abs/dir --parser NAME [--model M] --cmd '<shell cmd>'
//
// Record: <out>/<label>-r<round>.json = { label, cmd, exit, stdout, stderr, ts, model, truncated }.
// Idempotent: an existing record is reused, the command is NOT re-run.
// Output (exactly one line, exit 0 whenever it is printed):
//   PROBE name=<parser> exit=<cmd exit> sha=<sha256 of record.stdout> json=<compact JSON>
// Exit 2 + usage on stderr for an invalid invocation. No network, nothing read outside --out.

const fs = require('fs')
const path = require('path')
const crypto = require('crypto')
const { spawnSync } = require('child_process')

const MAX_BYTES = 65536
const TOKEN = /^[A-Za-z0-9._-]+$/
const USAGE =
  "usage: node probe-run.cjs --label L --round N --out /abs/dir --parser NAME [--model M] --cmd '<shell cmd>'\n"

// ---- pure PARSERS: (stdout, stderr, exit) -> JSON-able value ----------------------------------
const PARSERS = {
  lines(stdout) {
    const ls = String(stdout).split('\n')
    if (ls.length && ls[ls.length - 1] === '') ls.pop()
    return { lines: ls }
  },
  'git-status-porcelain'(stdout) {
    const entries = String(stdout).split('\n').filter((l) => l.length >= 3)
      .map((l) => ({ xy: l.slice(0, 2), path: l.slice(3) }))
    return { clean: entries.length === 0, entries }
  },
  'git-rev-list-count'(stdout) {
    const t = String(stdout).trim()
    return /^\d+$/.test(t) ? { count: Number(t) } : { error: 'bad-count' }
  },
  'gh-pr-view-json'(stdout) {
    try {
      const v = JSON.parse(String(stdout))
      return v !== null && typeof v === 'object' && !Array.isArray(v) ? v : { error: 'bad-json' }
    } catch (_) {
      return { error: 'bad-json' }
    }
  },
}

const sha256 = (s) => crypto.createHash('sha256').update(s).digest('hex')

function cut(buf) {
  if (buf.length <= MAX_BYTES) return { text: buf.toString('utf8'), cut: false }
  return { text: buf.subarray(0, MAX_BYTES).toString('utf8'), cut: true }
}

function buildRecord({ label, cmd, model }) {
  const r = spawnSync('sh', ['-c', cmd], { maxBuffer: 256 * 1024 * 1024 })
  const o = cut(r.stdout || Buffer.alloc(0))
  const e = cut(r.stderr || Buffer.alloc(0))
  return {
    label,
    cmd,
    exit: typeof r.status === 'number' ? r.status : -1,
    stdout: o.text,
    stderr: e.text,
    ts: new Date().toISOString(),
    model: model || null,
    truncated: o.cut || e.cut,
  }
}

function probeLine(parser, record) {
  const fn = Object.prototype.hasOwnProperty.call(PARSERS, parser) ? PARSERS[parser] : null
  const json = fn ? fn(record.stdout, record.stderr, record.exit) : { error: 'unknown-parser' }
  return `PROBE name=${parser} exit=${record.exit} sha=${sha256(record.stdout)} json=${JSON.stringify(json)}`
}

function parseArgs(argv) {
  const out = {}
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i]
    if (['--label', '--round', '--out', '--parser', '--model', '--cmd'].includes(k) && i + 1 < argv.length) {
      out[k.slice(2)] = argv[++i]
    } else return null
  }
  return out
}

function main() {
  const a = parseArgs(process.argv.slice(2))
  const bad = !a || !a.label || !a.parser || a.cmd === undefined || !a.out || a.round === undefined ||
    !TOKEN.test(a.label) || !TOKEN.test(a.parser) || !/^\d+$/.test(a.round) || !path.isAbsolute(a.out)
  if (bad) {
    process.stderr.write(USAGE)
    process.exit(2)
  }
  const file = path.join(a.out, `${a.label}-r${Number(a.round)}.json`)
  let record = null
  if (fs.existsSync(file)) {
    try { record = JSON.parse(fs.readFileSync(file, 'utf8')) } catch (_) { record = null }
  }
  if (!record) {
    record = buildRecord({ label: a.label, cmd: a.cmd, model: a.model })
    fs.mkdirSync(a.out, { recursive: true })
    const tmp = `${file}.${process.pid}.tmp`
    fs.writeFileSync(tmp, JSON.stringify(record))
    fs.renameSync(tmp, file)
  }
  process.stdout.write(probeLine(a.parser, record) + '\n')
  process.exit(0)
}

if (require.main === module) main()

module.exports = { PARSERS, buildRecord, probeLine }
