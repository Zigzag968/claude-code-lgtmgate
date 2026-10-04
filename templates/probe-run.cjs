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
// --no-reuse (#83): never reuse a stored record, always re-execute and overwrite. For probes of LIVE
// state (preflight reads: git-dir writable, plan-stale list, open sub-issues, branchPrefix; pr-state reads
// (#84): head sha, body digest, mergeability, commit count, review comments, open issues) where a
// stored exit-0 record from an earlier launch would be a stale read. Default behaviour is unchanged.
// --expect-cmd <sha256 hex> (#212): the digest of the command the caller composed. The command is copied by a
// model, so before it runs the script hashes the --cmd it was typed; a different digest means the copy is not the
// composed command and NOTHING is executed: the record gets exit -1 and stderr `expect-cmd-mismatch`, and the PROBE
// line is printed as usual. Its cmd= is the digest of `refused:` + the typed text, which can never equal the digest the
// caller wanted, so the engine always names a refusal `cmd-mismatch` and can retry (the typed text stays in the record).
// The digest is compared in lowercase; a malformed one (not 64 hex characters) is a REFUSAL, not a usage error. A write
// parser (WRITE_PARSERS) with no --expect-cmd at all is refused the same way: a dropped flag never gives an unchecked write.
// Exec mode only (with --verify: usage).
// Output (exactly one line, exit 0 whenever it is printed):
//   PROBE name=<parser> exit=<cmd exit> sha=<sha256 of record.stdout> cmd=<sha256 of the executed --cmd> json=<compact JSON>
// Exit 2 + usage on stderr for an invalid invocation. No network, nothing read outside --out.
//
// Verify mode (#82): node probe-run.cjs --verify --label L --round N --out /abs/dir --parser NAME
//   --attest /abs/probe-attest.jsonl
// Does NOT re-run the command. Prints ONE line (exit 0):
//   VERIFY ok line=<PROBE line>                      the record exists and the attestation file
//                                                    holds an entry equal to that recomputed line,
//                                                    attested for the SAME label and round (#83)
//   Binding to the agent (#83): when the matching entries carry an agent_id, the MOST RECENT entry
//   (file order) for this label/round must equal the recomputed line AND have ts >= the record's ts
//   (floored to the second: the hook stamps whole seconds), i.e. it was written after this call's own
//   execution. Bound: this call's attestation is the latest one and postdates the record, so an
//   attestation left by an earlier run/agent cannot satisfy it. NOT bound: WHICH agent wrote it (any
//   lgtmgate:probe agent_id passes; ids are not given to the engine), nor entries without agent_id
//   (legacy files: any equal entry counts). Failure reason: stale-attestation.
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
  "usage: node probe-run.cjs --label L --round N --out /abs/dir --parser NAME [--model M] [--no-reuse] [--expect-cmd SHA256 (required by write parsers)] --cmd '<shell cmd>'\n" +
  '       node probe-run.cjs --verify --label L --round N --out /abs/dir --parser NAME --attest /abs/file.jsonl\n'

// #239: the cause of a failed `gh` read, as templates/gh-read-class.sh names it. A closed set: a script prints a class,
// never the stderr text, and a parser keeps one only when it is in the set.
const READ_CLASSES = ['tls', 'auth', 'rate-limit', 'not-found', 'other']
const readClass = (x) => (typeof x === 'string' && READ_CLASSES.includes(x) ? x : null)

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
  // preflight.sh output (E2.4, #83): ONE JSON object, mode dev|branch. Fields that could not be read are
  // null; a malformed field is normalised to null, never trusted. No regex.
  preflight(stdout) {
    let v
    try { v = JSON.parse(String(stdout)) } catch (_) { return { error: 'bad-json' } }
    if (v === null || typeof v !== 'object' || Array.isArray(v)) return { error: 'bad-json' }
    const strArr = (x) => (Array.isArray(x) && x.every((i) => typeof i === 'string') ? x : null)
    const str = (x) => (typeof x === 'string' && x.length > 0 ? x : null)
    if (v.mode === 'dev') {
      return {
        mode: 'dev',
        planStale: strArr(v.planStale),
        openSubIssues: strArr(v.openSubIssues),
        gitDir: str(v.gitDir),
        writable: typeof v.writable === 'boolean' ? v.writable : null,
      }
    }
    if (v.mode === 'branch') {
      // #239: `readFailed` (the named cause of a failed PR read) only from the closed set, no key when absent.
      return { mode: 'branch', headRef: str(v.headRef), branchPrefix: typeof v.branchPrefix === 'string' ? v.branchPrefix : null, ...(readClass(v.readFailed) ? { readFailed: v.readFailed } : {}) }
    }
    return { error: 'bad-mode' }
  },
  // pr-state.sh output (E2.5, #84): ONE JSON object. Fields that could not be read are null; a malformed
  // field is normalised to null, never trusted (one malformed openIssues entry nulls the whole list). No regex.
  'pr-state'(stdout) {
    let v
    try { v = JSON.parse(String(stdout)) } catch (_) { return { error: 'bad-json' } }
    if (v === null || typeof v !== 'object' || Array.isArray(v)) return { error: 'bad-json' }
    const str = (x) => (typeof x === 'string' && x.length > 0 ? x : null)
    const strArr = (x) => (Array.isArray(x) && x.every((i) => typeof i === 'string') ? x : null)
    const idArr = (x) => (Array.isArray(x) && x.every((i) => Number.isInteger(i) && i >= 1) ? x : null)
    const issues = (x) => {
      if (!Array.isArray(x)) return null
      const out = []
      for (const i of x) {
        if (i === null || typeof i !== 'object' || !Number.isInteger(i.number) || typeof i.createdAt !== 'string') return null
        out.push({ number: i.number, createdAt: i.createdAt, url: str(i.url) })
      }
      return out
    }
    const ciChecksMap = (x) => {
      if (x === null || typeof x !== 'object' || Array.isArray(x)) return null
      const out = {}
      for (const k of Object.keys(x)) {
        if (k === '__proto__' || k === 'constructor') continue
        if (x[k] === 'green' || x[k] === 'failing' || x[k] === 'pending') out[k] = x[k]
      }
      return out
    }
    return {
      now: str(v.now),
      headRefName: str(v.headRefName),
      headRefOid: str(v.headRefOid),
      bodyDigest: str(v.bodyDigest),
      acceptanceChecked: idArr(v.acceptanceChecked),
      decisionLog: strArr(v.decisionLog),
      mergeable: str(v.mergeable),
      mergeStateStatus: str(v.mergeStateStatus),
      lastCommitDate: str(v.lastCommitDate),
      commitCount: Number.isInteger(v.commitCount) && v.commitCount >= 0 ? v.commitCount : null,
      // #184: the CI state of the PR head as pr-state.sh derived it; anything else (absent, unknown) is null.
      ciState: ['green', 'failing', 'pending', 'none'].includes(v.ciState) ? v.ciState : null,
      // #184: the same classification per check name, {"<name>": green|failing|pending}; kept only as a plain object, and
      // only the entries whose value is in that set (a dropped entry reads as an absent check: pending for the engine);
      // a non-object or an absent field -> null; a __proto__ / constructor key is dropped, never copied.
      ciChecks: ciChecksMap(v.ciChecks),
      reviewCommentIds: strArr(v.reviewCommentIds),
      openIssues: issues(v.openIssues),
      openIssuesTruncated: typeof v.openIssuesTruncated === 'boolean' ? v.openIssuesTruncated : false,
    }
  },
  // pr-write.sh output (E2.6a, #85): ONE JSON object {op, result, reason, bytes}. result must be one of
  // written|skipped|failed, anything else is an error; a malformed op/reason/bytes is normalised to null. No regex.
  // #239: `detail` (the named cause of a failed read) is kept only from the closed set, and the key is absent otherwise.
  'pr-write'(stdout) {
    let v
    try { v = JSON.parse(String(stdout)) } catch (_) { return { error: 'bad-json' } }
    if (v === null || typeof v !== 'object' || Array.isArray(v)) return { error: 'bad-json' }
    if (v.result !== 'written' && v.result !== 'skipped' && v.result !== 'failed') return { error: 'bad-result' }
    const str = (x) => (typeof x === 'string' && x.length > 0 ? x : null)
    return {
      op: str(v.op),
      result: v.result,
      reason: str(v.reason),
      bytes: Number.isInteger(v.bytes) && v.bytes >= 0 ? v.bytes : null,
      ...(readClass(v.detail) ? { detail: v.detail } : {}),
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
  return `PROBE name=${parser} exit=${record.exit} sha=${sha256(record.stdout)} cmd=${sha256(String(record.cmd))} json=${JSON.stringify(json)}`
}

// Pure: record (or null) + attestation entries [{line,label,round}] (+ optional bind {label,round})
// -> {ok:true,line} | {ok:false,reason} (#82). With bind, only entries attested for the same call
// (same label and round) count (#83).
function verifyRecord(parser, record, entries, bind) {
  if (!record) return { ok: false, reason: 'no-record' }
  const prefix = `PROBE name=${parser} `
  const mine = (entries || []).filter((e) => e && typeof e.line === 'string' && e.line.startsWith(prefix) &&
    (!bind || (e.label === bind.label && e.round === bind.round)))
  if (mine.length === 0) return { ok: false, reason: 'no-attestation' }
  const line = probeLine(parser, record)
  const withAgent = mine.filter((e) => typeof e.agent_id === 'string' && e.agent_id !== '')
  if (withAgent.length === 0) return mine.some((e) => e.line === line) ? { ok: true, line } : { ok: false, reason: 'sha-mismatch' }
  // #83: bind to the call — the latest entry must match and postdate the record (second resolution).
  const last = withAgent[withAgent.length - 1]
  if (last.line !== line) return { ok: false, reason: 'sha-mismatch' }
  const floor = Math.floor(Date.parse(record.ts) / 1000) * 1000
  const at = Date.parse(last.ts)
  if (!Number.isFinite(floor) || !Number.isFinite(at) || at < floor) return { ok: false, reason: 'stale-attestation' }
  return { ok: true, line }
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
    else if (k === '--no-reuse') out.noReuse = true
    else if (['--label', '--round', '--out', '--parser', '--model', '--cmd', '--attest', '--expect-cmd'].includes(k) && i + 1 < argv.length) {
      out[k.slice(2)] = argv[++i]
    } else return null
  }
  return out
}

// Pure: a sha256 as printed by hex digests: 64 lowercase hex characters (no regex).
const isSha256Hex = (s) => typeof s === 'string' && s.length === 64 && [...s].every((c) => '0123456789abcdef'.includes(c))

// Parsers of probes that WRITE: their command must carry --expect-cmd or it is refused (a small named set).
const WRITE_PARSERS = new Set(['pr-write'])

// Pure: must this exec invocation be refused (nothing run)? expect = the --expect-cmd value or undefined.
function mustRefuse(parser, cmd, expect) {
  if (expect === undefined) return WRITE_PARSERS.has(parser)
  const want = String(expect).toLowerCase()
  return !isSha256Hex(want) || sha256(cmd) !== want
}

// Pure: the record of a command that was NOT run (its copy misses the expected digest, or the digest is missing or
// malformed). cmd keeps the received text visible but never hashes to the digest that was wanted.
function refusedRecord({ label, cmd, model }) {
  return { label, cmd: `refused:${cmd}`, exit: -1, stdout: '', stderr: 'expect-cmd-mismatch', ts: new Date().toISOString(), model: model || null, truncated: false }
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
  const bad = !common || (a.verify
    ? (!a.attest || !path.isAbsolute(a.attest) || a.cmd !== undefined || a.noReuse || a['expect-cmd'] !== undefined)
    : a.cmd === undefined)
  if (bad) {
    process.stderr.write(USAGE)
    process.exit(2)
  }
  const file = path.join(a.out, `${a.label}-r${Number(a.round)}.json`)
  if (a.verify) {
    const v = verifyRecord(a.parser, readRecord(file), readJsonl(a.attest), { label: a.label, round: Number(a.round) })
    process.stdout.write((v.ok ? `VERIFY ok line=${v.line}` : `VERIFY fail reason=${v.reason}`) + '\n')
    process.exit(0)
  }
  let record = readRecord(file)
  const refuse = mustRefuse(a.parser, a.cmd, a['expect-cmd'])
  if (refuse || a.noReuse || !canReuse(record, a.cmd)) {
    record = refuse ? refusedRecord({ label: a.label, cmd: a.cmd, model: a.model }) : buildRecord({ label: a.label, cmd: a.cmd, model: a.model })
    fs.mkdirSync(a.out, { recursive: true })
    const tmp = `${file}.${process.pid}.tmp`
    fs.writeFileSync(tmp, JSON.stringify(record))
    fs.renameSync(tmp, file)
  }
  process.stdout.write(probeLine(a.parser, record) + '\n')
  process.exit(0)
}

if (require.main === module) main()

module.exports = { PARSERS, canReuse, buildRecord, probeLine, verifyRecord, mustRefuse, refusedRecord }
