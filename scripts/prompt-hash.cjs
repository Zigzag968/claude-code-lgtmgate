#!/usr/bin/env node
// prompt-hash: prove that a change leaves every agent prompt byte-identical (#262; #265 reuses it).
// Replays every fixture with prompts retained and prints one hash per fixture, then a total.
//
// Usage:
//   node scripts/prompt-hash.cjs [--dir fixtures] [--harness scripts/run-offline.cjs]
// `--harness` lets a base copy of run-offline be compared with the branch one, e.g.
//   git show origin/main:scripts/run-offline.cjs > "$TMPDIR/ro-base.cjs"
//   node scripts/prompt-hash.cjs --harness "$TMPDIR/ro-base.cjs" > before.txt
//   node scripts/prompt-hash.cjs > after.txt && diff before.txt after.txt
// Deterministic: the hashed data holds only call labels and prompt hashes (no time, no path).
// Last line: `[prompt-hash] fixtures=<n> total=<16 hex>`. Writes no file.

const fs = require('fs')
const path = require('path')
const crypto = require('crypto')

const argv = process.argv.slice(2)
let dir = 'fixtures'
let harness = path.join(__dirname, 'run-offline.cjs')
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === '--dir') dir = argv[++i]
  else if (argv[i] === '--harness') harness = argv[++i]
  else { process.stderr.write(`unknown argument ${argv[i]}\n`); process.exit(2) }
}
// Resolve against the caller's cwd BEFORE moving to the repo root.
dir = path.resolve(dir)
harness = path.resolve(harness)
const root = path.join(__dirname, '..')
process.chdir(root)

const sha = (s) => crypto.createHash('sha256').update(s).digest('hex')

function listJson(d) {
  const out = []
  for (const name of fs.readdirSync(d).sort()) {
    const p = path.join(d, name)
    if (fs.statSync(p).isDirectory()) out.push(...listJson(p))
    else if (name.endsWith('.json')) out.push(p)
  }
  return out
}

async function main() {
  const h = require(harness)
  const src = h.stripExports(fs.readFileSync(path.join(root, 'workflows', 'deliver-pipeline.js'), 'utf-8'))
  const hashes = []
  for (const file of listJson(dir)) {
    const fixture = JSON.parse(fs.readFileSync(file, 'utf-8'))
    if (!fixture.name) fixture.name = path.basename(file, '.json')
    const specs = fixture.runs !== undefined ? fixture.runs : [fixture]
    const lines = []
    let prev = null
    for (const spec of specs) {
      const run = h.buildPipelineRunner(src)
      const args = JSON.parse(JSON.stringify(spec.args || {}))
      if (spec.carry && prev && prev.result) {
        for (const [argName, field] of Object.entries(spec.carry)) {
          if (prev.result[field] !== undefined) args[argName] = JSON.parse(JSON.stringify(prev.result[field]))
        }
      }
      const r = await h.replayFixture({ name: fixture.name, args, calls: spec.calls, expect: spec.expect }, run, { prompts: true })
      for (const c of r.calls) lines.push(`${c.label}:${sha(String(c.prompt))}`)
      prev = r
    }
    const fh = sha(lines.join('\n')).slice(0, 16)
    hashes.push(fh)
    process.stdout.write(`${fh} ${path.relative(root, file)}\n`)
  }
  process.stdout.write(`[prompt-hash] fixtures=${hashes.length} total=${sha(hashes.join('\n')).slice(0, 16)}\n`)
}

main().catch((e) => { process.stderr.write(`${e && e.stack ? e.stack : e}\n`); process.exit(1) })
