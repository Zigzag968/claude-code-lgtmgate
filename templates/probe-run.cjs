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
// Reuse rule: an existing record is reused (command NOT re-run) ONLY for an identical, successful
// replay (record.cmd === --cmd AND record.exit === 0). A different --cmd, or a stored failure
// (exit != 0), is rebuilt and overwritten: a Lead who fixes the cause and relaunches on the same
// worktree must never get the old failed record back.
// Output (exactly one line, exit 0 whenever it is printed):
//   PROBE name=<parser> exit=<cmd exit> sha=<sha256 of record.stdout> json=<compact JSON>
// Exit 2 + usage on stderr for an invalid invocation. No network, nothing read outside --out.
//
// Verify mode (#82): node probe-run.cjs --verify --label L --round N --out /abs/dir --parser NAME
//   --attest /abs/probe-attest.jsonl
// Does NOT re-run the command. Prints ONE line (exit 0):
//   VERIFY ok line=<PROBE line>                      the record exists and the attestation file
//                                                    holds an entry equal to that recomputed line
//   VERIFY fail reason=no-record|no-attestation|sha-mismatch
// The engine has no filesystem, so this is how it learns the copied PROBE line is the one the
// script printed (hooks/PostToolUse-probe-attest.sh wrote the attestation).

const fs = require('fs')
const path = require('path')
const crypto = require('crypto')
const { spawnSync } = require('child_process')

const MAX_BYTES = 65536
const TOKEN = /^[A-Za-z0-9._-]+$/
const USAGE =
  "usage: node probe-run.cjs --label L --round N --out /abs/dir --parser NAME [--model M] --cmd '<shell cmd>'\n" +
  '       node probe-run.cjs --verify --label L --round N --out /abs/dir --parser NAME --attest /abs/file.jsonl\n'

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
  // provision_worktree.sh output (#82). Independent of exit: the call site merges stderr (2>&1).
  // No PROVISION-VERSION line = v1; 1 and 2 are accepted, anything else is an error.
  provision(stdout) {
    const text = String(stdout)
    const vm = text.match(/^PROVISION-VERSION:(\S*)$/m)
    const version = vm ? vm[1] : '1'
    if (version !== '1' && version !== '2') return { error: 'unknown-version' }
    const linked = [...text.matchAll(/^LINKED\s+(\S+)\s+->/gm)].map((m) => m[1])
    const missing = [...text.matchAll(/^MISSING-SRC\s+(\S+)/gm)].map((m) => m[1])
    const skipped = /^PROVISION-SKIPPED-NO-SCRIPT/m.test(text)
    return { version: Number(version), linked, missing, skipped }
  },
  // Last PROVISION-FRESHNESS:<ffwd|fresh|stale>:<behind>[:<own>] line (#40).
  'provision-freshness'(stdout) {
    const ls = String(stdout).split('\n').map((l) => l.trim()).reverse()
    for (const l of ls) {
      const m = l.match(/^PROVISION-FRESHNESS:(ffwd|fresh|stale):(\d+)(?::(\d+))?$/)
      if (m) return { state: m[1], behind: Number(m[2]), own: m[3] === undefined ? null : Number(m[3]) }
    }
    return { error: 'bad-freshness' }
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

// Pure: record (or null) + attestation entries [{line}] -> {ok:true,line} | {ok:false,reason} (#82).
function verifyRecord(parser, record, entries) {
  if (!record) return { ok: false, reason: 'no-record' }
  const prefix = `PROBE name=${parser} `
  const mine = (entries || []).filter((e) => e && typeof e.line === 'string' && e.line.startsWith(prefix))
  if (mine.length === 0) return { ok: false, reason: 'no-attestation' }
  const line = probeLine(parser, record)
  return mine.some((e) => e.line === line) ? { ok: true, line } : { ok: false, reason: 'sha-mismatch' }
}

function readJsonl(file) {
  let text = ''
  try { text = fs.readFileSync(file, 'utf8') } catch (_) { return [] }
  const out = []
  for (const l of text.split('\n')) {
    if (!l.trim()) continue
    try { out.push(JSON.parse(l)) } catch (_) { /* skip a torn line */ }
  }
  return out
}

function parseArgs(argv) {
  const out = {}
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i]
    if (k === '--verify') out.verify = true
    else if (['--label', '--round', '--out', '--parser', '--model', '--cmd', '--attest'].includes(k) && i + 1 < argv.length) {
      out[k.slice(2)] = argv[++i]
    } else return null
  }
  return out
}

function readRecord(file) {
  if (!fs.existsSync(file)) return null
  try { return JSON.parse(fs.readFileSync(file, 'utf8')) } catch (_) { return null }
}

// Pure: may a stored record answer this invocation without re-running? (identical cmd AND success)
function canReuse(record, cmd) {
  return !!record && record.cmd === cmd && record.exit === 0
}

function main() {
  const a = parseArgs(process.argv.slice(2))
  const common = a && a.label && a.parser && a.out && a.round !== undefined &&
    TOKEN.test(a.label) && TOKEN.test(a.parser) && /^\d+$/.test(a.round) && path.isAbsolute(a.out)
  const bad = !common || (a.verify ? (!a.attest || !path.isAbsolute(a.attest) || a.cmd !== undefined) : a.cmd === undefined)
  if (bad) {
    process.stderr.write(USAGE)
    process.exit(2)
  }
  const file = path.join(a.out, `${a.label}-r${Number(a.round)}.json`)
  if (a.verify) {
    const v = verifyRecord(a.parser, readRecord(file), readJsonl(a.attest))
    process.stdout.write((v.ok ? `VERIFY ok line=${v.line}` : `VERIFY fail reason=${v.reason}`) + '\n')
    process.exit(0)
  }
  let record = readRecord(file)
  if (!canReuse(record, a.cmd)) {
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

module.exports = { PARSERS, canReuse, buildRecord, probeLine, verifyRecord }
