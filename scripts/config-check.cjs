#!/usr/bin/env node
'use strict'

// Warns when a project's .claude/pipeline.config.json is out of date for this engine (#398).
// Single source of truth for "which keys are recommended, which are retired": the SessionStart hook and
// /lgtmgate:deliver step 1 both run this script and show its output unchanged.
// Read-only, stdlib only, no network, no model call, ALWAYS exit 0 (a failure is a warn line, never a throw).
//
// Usage: node scripts/config-check.cjs <path to .claude/pipeline.config.json>
// Stdout: zero or more `warn: ...` lines, then the last line
//         [config-check] status=ok|warn retired=<n> missing=<n>

const fs = require('fs')

// Keys the engine ignores today, with what replaces them.
const RETIRED = [{ key: 'conventionsRule', replacement: 'agentContext["*"]' }]

// Keys init writes and the README documents as the way to feed project conventions / refuse an old engine.
// `anyOf` : one present key is enough (both turn the same injection on).
const RECOMMENDED = [
  { anyOf: ['agentContext', 'projectSpecifics'], label: 'agentContext or projectSpecifics', effect: 'no project conventions reach the agents' },
  { anyOf: ['minPluginVersion'], label: 'minPluginVersion', effect: 'an older engine is not refused' }
]

function present(config, key) {
  const v = config[key]
  if (key === 'agentContext') return v !== null && typeof v === 'object' && !Array.isArray(v) && Object.keys(v).length > 0
  return typeof v === 'string' && v.trim() !== ''
}

function check(file) {
  let config
  try {
    config = JSON.parse(fs.readFileSync(file, 'utf8'))
    if (config === null || typeof config !== 'object' || Array.isArray(config)) throw new Error('not a JSON object')
  } catch (error) {
    return { lines: [`warn: ${file} is absent or not a readable JSON object (${error.message}); run /lgtmgate:init`], retired: 0, missing: 0 }
  }
  const lines = []
  let retired = 0
  let missing = 0
  for (const r of RETIRED) {
    if (Object.prototype.hasOwnProperty.call(config, r.key)) {
      retired++
      lines.push(`warn: retired key ${r.key} is ignored by the engine; replace it with ${r.replacement} (list the rule file there)`)
    }
  }
  for (const r of RECOMMENDED) {
    if (!r.anyOf.some((k) => present(config, k))) {
      missing++
      lines.push(`warn: recommended key missing: ${r.label} (${r.effect})`)
    }
  }
  if (retired + missing > 0) lines.push('warn: run /lgtmgate:init and choose "complete" to add them (an existing config is never overwritten)')
  return { lines, retired, missing }
}

function main() {
  let result
  try {
    const file = process.argv[2]
    result = file ? check(file) : { lines: ['warn: no config path given; usage: node scripts/config-check.cjs <path to .claude/pipeline.config.json>'], retired: 0, missing: 0 }
  } catch (error) {
    result = { lines: [`warn: config check failed (${error && error.message})`], retired: 0, missing: 0 }
  }
  const status = result.lines.length ? 'warn' : 'ok'
  process.stdout.write(result.lines.concat(`[config-check] status=${status} retired=${result.retired} missing=${result.missing}`).join('\n') + '\n')
  process.exitCode = 0
}

main()
