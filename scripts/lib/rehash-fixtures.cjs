#!/usr/bin/env node
'use strict'
// Re-records the probe `cmd=` digests of recorded fixtures after an engine change that alters the text of a probe
// command (a flag renamed, a path spelled differently). The engine accepts a recorded PROBE line only when its `cmd=`
// equals the digest of the command it composes now, so such a change turns every coupled fixture red.
//
//   node scripts/lib/rehash-fixtures.cjs --from <engine before> [--fp <engine after>] <fixtures dir | fixture.json>
//
// For each fixture: replay with the engine BEFORE and mark the probe entries whose `cmd=` is the digest of the command
// parsed from the prompt (coupled); replay with the engine AFTER and rewrite each coupled entry to the digest of the
// command it composes now, until the replay asks for nothing more (8 passes at most); then replace in the file TEXT each
// old digest by its final one. A multi-run fixture is replayed run by run, `carry` applied from the previous replay of
// the same engine. A digest that was never the digest of a composed command (a deliberately wrong one) is left alone.
// `--fp` defaults to workflows/deliver-pipeline.js. No model call, no network.
//
// Last stdout line: `[rehash] status=ok files=<n> hashes=<m>`. Exit 0 ok, 1 error, 2 usage.

const fs = require('fs')
const path = require('path')
const crypto = require('crypto')
const { stripExports, buildPipelineRunner, replayFixture, commandOfPrompt, firstCommandHash, setCommandHash } = require('../run-offline.cjs')

const MAX_PASSES = 8
const DEFAULT_ENGINE = 'workflows/deliver-pipeline.js'

const sha256 = (text) => crypto.createHash('sha256').update(text, 'utf8').digest('hex')
const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value)
const clone = (value) => (value === null || typeof value !== 'object' ? value : JSON.parse(JSON.stringify(value)))

function parseCli(argv) {
  const options = { from: null, fp: DEFAULT_ENGINE, targets: [] }
  for (let index = 0; index < argv.length; index++) {
    if (argv[index] === '--from') options.from = argv[++index]
    else if (argv[index] === '--fp') options.fp = argv[++index]
    else options.targets.push(argv[index])
  }
  return options
}

function listJson(target) {
  const stat = fs.statSync(target)
  if (stat.isFile()) return [target]
  return fs.readdirSync(target).sort().flatMap((name) => listJson(path.join(target, name))).filter((file) => file.endsWith('.json'))
}

function loadRun(file) {
  return buildPipelineRunner(stripExports(fs.readFileSync(path.resolve(file), 'utf-8')))
}

// The entry a call label and its occurrence number point at: { key, entry } (an array label is addressed by index).
function entryAt(store, label, occurrence) {
  const array = Array.isArray(store[label])
  return { key: array ? `${label}[${occurrence}]` : label, entry: array ? store[label][occurrence] : store[label] }
}

// Walks the calls of a replay in order, once per (label, occurrence): visit({ key, entry, prompt }).
function eachProbeCall(calls, store, visit) {
  const counts = new Map()
  for (const call of calls) {
    if (typeof call.label !== 'string' || !call.label.startsWith('probe-')) continue
    const occurrence = counts.get(call.label) || 0
    counts.set(call.label, occurrence + 1)
    const { key, entry } = entryAt(store, call.label, occurrence)
    if (isObject(entry) && typeof entry.line === 'string') visit({ key, entry, prompt: call.prompt })
  }
}

// The keys whose recorded digest is the digest of the command the BEFORE engine composed.
function coupledKeys(calls, store) {
  const verdicts = new Map()
  eachProbeCall(calls, store, ({ key, entry, prompt }) => {
    const command = commandOfPrompt(prompt)
    const good = command !== null && firstCommandHash(entry.line) === sha256(command)
    verdicts.set(key, (verdicts.has(key) ? verdicts.get(key) : true) && good)
  })
  return new Set([...verdicts].filter(([, good]) => good).map(([key]) => key))
}

// One rewrite pass over the calls the AFTER engine asked for; returns true when an entry changed.
function rewritePass(calls, store, coupled) {
  let changed = false
  const done = new Set()
  eachProbeCall(calls, store, ({ key, entry, prompt }) => {
    if (!coupled.has(key) || done.has(key)) return
    done.add(key)
    const command = commandOfPrompt(prompt)
    const current = firstCommandHash(entry.line)
    if (command === null || current === null || current === sha256(command)) return
    const want = sha256(command)
    entry.line = setCommandHash(entry.line, want)
    if (typeof entry.verify === 'string' && firstCommandHash(entry.verify) === current) entry.verify = setCommandHash(entry.verify, want)
    changed = true
  })
  return changed
}

function argumentsWithCarry(unit, previous) {
  const args = clone(unit.args || {})
  if (!isObject(unit.carry) || !previous) return args
  for (const [name, field] of Object.entries(unit.carry)) {
    if (previous[field] !== undefined) args[name] = clone(previous[field])
  }
  return args
}

// Replays the working copy with the AFTER engine, rewriting coupled digests until none changes.
async function settle(label, args, work, coupled, after) {
  for (let pass = 0; pass < MAX_PASSES; pass++) {
    const replay = await replayFixture({ name: label, args, calls: work }, after, { prompts: true })
    if (!rewritePass(replay.calls, work, coupled)) return replay
  }
  throw new Error(`${label}: the digests do not settle in ${MAX_PASSES} passes`)
}

// The `cmd=` digest of every recorded PROBE line, by entry key.
function lineHashes(store) {
  const found = new Map()
  for (const name of Object.keys(store)) {
    const array = Array.isArray(store[name])
    ;(array ? store[name] : [store[name]]).forEach((entry, occurrence) => {
      if (isObject(entry) && typeof entry.line === 'string') found.set(array ? `${name}[${occurrence}]` : name, firstCommandHash(entry.line))
    })
  }
  return found
}

// old digest -> new digest for one unit (a single fixture or one run of a chain); `pairs` collects across units.
function collectPairs(original, work, coupled, pairs, label) {
  const olds = lineHashes(original)
  const news = lineHashes(work)
  for (const key of coupled) {
    const oldHash = olds.get(key)
    const newHash = news.get(key)
    if (!oldHash || !newHash || oldHash === newHash) continue
    if (pairs.has(oldHash) && pairs.get(oldHash) !== newHash) throw new Error(`${label}: digest ${oldHash} maps to two new digests`)
    pairs.set(oldHash, newHash)
  }
}

async function digestPairs(fixture, before, after, name) {
  const pairs = new Map()
  const units = Array.isArray(fixture.runs) ? fixture.runs : [fixture]
  let previousBefore = null
  let previousAfter = null
  for (let index = 0; index < units.length; index++) {
    const unit = units[index]
    const label = units.length > 1 ? `${name}#${index + 1}` : name
    const replayBefore = await replayFixture({ name: label, args: argumentsWithCarry(unit, previousBefore), calls: unit.calls }, before, { prompts: true })
    const coupled = coupledKeys(replayBefore.calls, unit.calls)
    const work = clone(unit.calls)
    const replayAfter = await settle(label, argumentsWithCarry(unit, previousAfter), work, coupled, after)
    collectPairs(unit.calls, work, coupled, pairs, label)
    previousBefore = replayBefore.result
    previousAfter = replayAfter.result
  }
  return pairs
}

async function rehashFile(file, before, after) {
  const text = fs.readFileSync(file, 'utf-8')
  const fixture = JSON.parse(text)
  const pairs = await digestPairs(fixture, before, after, path.basename(file, '.json'))
  let rewritten = text
  for (const [oldHash, newHash] of pairs) rewritten = rewritten.split(oldHash).join(newHash)
  if (rewritten !== text) fs.writeFileSync(file, rewritten)
  return pairs.size
}

async function main() {
  const options = parseCli(process.argv.slice(2))
  if (!options.from || options.targets.length === 0) {
    process.stderr.write('usage: node scripts/lib/rehash-fixtures.cjs --from <engine before> [--fp <engine after>] <fixtures dir | fixture.json>\n')
    process.exitCode = 2
    return
  }
  try {
    const before = loadRun(options.from)
    const after = loadRun(options.fp)
    const files = options.targets.flatMap((target) => listJson(path.resolve(target)))
    let hashes = 0
    for (const file of files) hashes += await rehashFile(file, before, after)
    process.stdout.write(`[rehash] status=ok files=${files.length} hashes=${hashes}\n`)
  } catch (error) {
    process.stderr.write(`[rehash] ${error && error.message ? error.message : error}\n`)
    process.stdout.write('[rehash] status=error files=0 hashes=0\n')
    process.exitCode = 1
  }
}

main()
