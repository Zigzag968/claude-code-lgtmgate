#!/usr/bin/env node
// Read-only: first-request token count of lgtmgate:probe agents, per day, from existing transcripts.
// Usage: node docs/bench/probe-first-request.cjs [projectsDir]   (default: ~/.claude/projects)
'use strict'
const fs = require('fs')
const os = require('os')
const path = require('path')

const root = process.argv[2] || path.join(os.homedir(), '.claude', 'projects')
const perDay = new Map()
let metaCount = 0

function walk(directory) {
  let entries
  try {
    entries = fs.readdirSync(directory, { withFileTypes: true })
  } catch {
    return
  }
  for (const entry of entries) {
    const entryPath = path.join(directory, entry.name)
    if (entry.isDirectory()) walk(entryPath)
    else if (/^agent-.*\.meta\.json$/.test(entry.name)) probe(entryPath)
  }
}

function firstRequest(jsonlPath) {
  let text
  try {
    text = fs.readFileSync(jsonlPath, 'utf8')
  } catch {
    return null
  }
  for (const line of text.split('\n')) {
    if (!line.includes('"type":"assistant"')) continue
    let record
    try {
      record = JSON.parse(line)
    } catch {
      continue
    }
    const usage = record.message && record.message.usage
    if (record.type !== 'assistant' || !usage) continue
    const tokens = (usage.input_tokens || 0) + (usage.cache_creation_input_tokens || 0) + (usage.cache_read_input_tokens || 0)
    return { day: String(record.timestamp || '').slice(0, 10), tokens }
  }
  return null
}

function probe(metaPath) {
  let meta
  try {
    meta = JSON.parse(fs.readFileSync(metaPath, 'utf8'))
  } catch {
    return
  }
  if (meta.agentType !== 'lgtmgate:probe') return
  metaCount++
  const first = firstRequest(metaPath.replace(/\.meta\.json$/, '.jsonl'))
  if (!first || !first.day) return
  if (!perDay.has(first.day)) perDay.set(first.day, [])
  perDay.get(first.day).push(first.tokens)
}

function median(values) {
  const sorted = [...values].sort((left, right) => left - right)
  const middle = sorted.length >> 1
  return sorted.length % 2 ? sorted[middle] : Math.round((sorted[middle - 1] + sorted[middle]) / 2)
}

walk(root)
console.log('day\tcalls\tmedian\tmin\tmax')
for (const day of [...perDay.keys()].sort()) {
  const tokens = perDay.get(day)
  console.log([day, tokens.length, median(tokens), Math.min(...tokens), Math.max(...tokens)].join('\t'))
}
console.log('probe meta files: ' + metaCount + ', days with a first request: ' + perDay.size)
